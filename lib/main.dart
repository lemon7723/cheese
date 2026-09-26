import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const PocketKittyApp());
}

class PocketKittyApp extends StatelessWidget {
  const PocketKittyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '宠了么',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC96442)),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
// 原生桥接：Android TFLite / 抠图（MethodChannel 契约不可改）
// ============================================================

class SegmentationService {
  static const MethodChannel _channel =
      MethodChannel('pet_segmentation/segment');

  /// 原生端构建标识。首页底部会显示；如果看不到它，说明装的是旧包
  static Future<String> nativeVersion() async {
    try {
      return await _channel.invokeMethod<String>('buildVersion') ?? 'unknown';
    } catch (_) {
      return 'old-apk';
    }
  }

  /// 查询当前实际生效的抠图模型（首次抠图后才可知）。
  static Future<Map<Object?, Object?>> modelInfo() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('modelInfo');
    return r ?? {};
  }

  /// 输入原图路径，返回抠好背景（透明 PNG）的文件路径。
  /// [maskSource] 选择模型 7 路侧输出之一（0~6）。
  static Future<String> removeBackground(String path,
      {int maskSource = 0}) async {
    try {
      final out = await _channel.invokeMethod<String>(
          'removeBackground', {'path': path, 'maskSource': maskSource});
      if (out == null || out.isEmpty) {
        throw const SegmentationException('原生端没有返回结果');
      }
      return out;
    } on PlatformException catch (e) {
      throw SegmentationException(e.message ?? '抠图失败（${e.code}）');
    } on MissingPluginException {
      throw const SegmentationException('原生桥接未注册');
    }
  }
}

class SegmentationException implements Exception {
  const SegmentationException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ============================================================
// 数据模型
// ============================================================

enum PetItemStatus { processing, done, failed }

class PetItem {
  PetItem({
    required this.originalPath,
    this.cutoutPath,
    this.status = PetItemStatus.processing,
    this.error,
  });

  final String originalPath;
  String? cutoutPath;
  PetItemStatus status;
  String? error;
}

// ============================================================
// ============================================================
// P1 · 可动 2.5D 骨骼宠物（头 / 身 / 尾 三层 + 可枚举姿态）
// 纯 Dart/Flutter 实现：不新增依赖、不接原生渲染器、不接 DragonBones
// 贴图直接复用真实抠图结果（Image.file(cutoutPath)），不 AI 重绘
// ============================================================

/// 单层（头 / 身 / 尾）的姿态参数
class PartPose {
  final double rotZ; // 绕自身锚点 Z 旋转（弧度）
  final double rotY; // 绕 Y 旋转（轻微转体）
  final double dx; // 水平位移（逻辑像素，正=右）
  final double dy; // 垂直位移（逻辑像素，正=下）
  final double scaleX;
  final double scaleY;

  const PartPose({
    this.rotZ = 0,
    this.rotY = 0,
    this.dx = 0,
    this.dy = 0,
    this.scaleX = 1,
    this.scaleY = 1,
  });

  PartPose lerp(PartPose o, double k) => PartPose(
        rotZ: rotZ + (o.rotZ - rotZ) * k,
        rotY: rotY + (o.rotY - rotY) * k,
        dx: dx + (o.dx - dx) * k,
        dy: dy + (o.dy - dy) * k,
        scaleX: scaleX + (o.scaleX - scaleX) * k,
        scaleY: scaleY + (o.scaleY - scaleY) * k,
      );
}

/// 一个完整姿态 = 头 / 身 / 尾 三层的参数
class PoseSpec {
  final PartPose head;
  final PartPose body;
  final PartPose tail;

  const PoseSpec({
    this.head = const PartPose(),
    this.body = const PartPose(),
    this.tail = const PartPose(),
  });

  PoseSpec lerp(PoseSpec o, double k) => PoseSpec(
        head: head.lerp(o.head, k),
        body: body.lerp(o.body, k),
        tail: tail.lerp(o.tail, k),
      );
}

/// 可枚举姿态（点按后保持）
enum Pose { idle, sit, lie, stretch, tilt, look }

/// 各姿态的目标参数
const Map<Pose, PoseSpec> kPoseSpecs = {
  Pose.idle: PoseSpec(), // 站立 / 呼吸（呼吸在渲染层叠加）
  Pose.sit: PoseSpec(
    body: PartPose(scaleY: 0.82, dy: 20),
    head: PartPose(dy: -10, scaleY: 1.06),
    tail: PartPose(dy: 8),
  ),
  Pose.lie: PoseSpec(
    body: PartPose(scaleY: 0.58, dy: 46),
    head: PartPose(dy: 26, scaleY: 1.12, rotZ: 0.12),
    tail: PartPose(dy: 30, rotZ: -0.2),
  ),
  Pose.stretch: PoseSpec(
    body: PartPose(scaleY: 1.2, dy: -16),
    head: PartPose(dy: -20, rotZ: 0.16),
    tail: PartPose(rotZ: 0.22),
  ),
  Pose.tilt: PoseSpec(
    head: PartPose(rotZ: -0.42, dy: -4),
  ),
  Pose.look: PoseSpec(
    head: PartPose(rotY: 0.5, dy: -2),
    body: PartPose(rotY: 0.18),
  ),
};

/// 动作栏条目：姿态（保持）或 动态动作（一次性 / 循环）
class PetButton {
  final String name;
  final IconData icon;
  final Pose? pose; // 非 null = 点按切换到该姿态并保持
  final String? action; // 非 null = 触发一次性 / 循环动态动作
  const PetButton.pose(this.name, this.icon, this.pose) : action = null;
  const PetButton.action(this.name, this.icon, this.action) : pose = null;
}

const List<PetButton> kPetButtons = [
  PetButton.pose('站立', Icons.accessibility, Pose.idle),
  PetButton.pose('坐下', Icons.chair, Pose.sit),
  PetButton.pose('趴下', Icons.horizontal_rule, Pose.lie),
  PetButton.pose('伸懒腰', Icons.landscape, Pose.stretch),
  PetButton.pose('歪头', Icons.face_retouching_natural, Pose.tilt),
  PetButton.pose('远眺', Icons.visibility, Pose.look),
  PetButton.action('摇尾巴', Icons.pets, 'wag'),
  PetButton.action('转圈', Icons.rotate_90_degrees_ccw, 'spin'),
  PetButton.action('打滚', Icons.autorenew, 'roll'),
  PetButton.action('蹦跳', Icons.celebration, 'hop'),
];



// ============================================================
// 首页：选照片 → 抠图 → 2.5D 纸片宠物舞台
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final List<PetItem> _items = [];
  int _selected = 0;
  bool _picking = false;
  int _maskSource = 0;

  late final Future<String> _nativeVersion =
      SegmentationService.nativeVersion();
  String? _activeModel;

  /// 宠物名字（可改名并持久化）
  String _petName = '毛孩';
  /// 自定义背景图路径
  String? _backgroundPath;
  /// 定时撒娇开关
  bool _coquetryOn = false;

  /// P1 知情确认（仅首次展示「2.5D 非真 3D」说明）
  bool _signedOffV1_5 = false;

  final GlobalKey<_PetStageState> _stageKey = GlobalKey<_PetStageState>();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  Timer? _coquetryTimer;

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _initNotifications();
  }

  Future<void> _initPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _petName = prefs.getString('petName') ?? '毛孩';
    _backgroundPath = prefs.getString('backgroundPath');
    _coquetryOn = prefs.getBool('coquetry') ?? false;
    if (_coquetryOn) _startCoquetry();
    _signedOffV1_5 = prefs.getBool('signedOffV1_5') ?? false;
    if (!_signedOffV1_5) {
      await prefs.setBool('signedOffV1_5', true);
      _signedOffV1_5 = true;
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showSignOff());
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _showSignOff() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('用「真实宠物照片」做一个会动的数字宠物'),
        content: const Text(
          '你上传的宠物照片会在手机本地被抠掉背景，生成一只「会动的数字毛孩」。\n\n'
          '需要提前说明：当前版本是【可动 2.5D 立绘】——它由「头 / 身 / 尾」三层拼成，'
          '能坐、能趴、能摇尾巴、能转头，但还不是真正的 3D 模型（不能 360° 任意转）。'
          '后续版本会进阶到真 3D。\n\n'
          '所有处理都在你的手机上离线完成，照片不会上传。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('开始制作 ❤'),
          ),
        ],
      ),
    );
  }

  Future<void> _initNotifications() async {
    const android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const init = InitializationSettings(android: android);
    await _notifications.initialize(init);
    try {
      await _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {
      // 老版本系统无需请求，忽略
    }
  }

  void _startCoquetry() {
    _coquetryTimer?.cancel();
    _coquetryTimer = Timer.periodic(
      const Duration(hours: 2),
      (_) => _fireCoquetry(),
    );
  }

  Future<void> _fireCoquetry() async {
    const androidDetails = AndroidNotificationDetails(
      'coquetry',
      '撒娇提醒',
      channelDescription: '你的毛孩想你了',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _notifications.show(
      DateTime.now().millisecond,
      '$_petName 想你了',
      '陪陪它、摸摸它吧～',
      details,
    );
  }

  Future<void> _toggleCoquetry(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('coquetry', on);
    setState(() => _coquetryOn = on);
    if (on) {
      _startCoquetry();
      _fireCoquetry();
    } else {
      _coquetryTimer?.cancel();
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _petName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('给毛孩起个名字'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 12,
          decoration: const InputDecoration(hintText: '例如：豆豆'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('petName', name);
      setState(() => _petName = name);
    }
  }

  Future<void> _pickBackground() async {
    final img = await _picker.pickImage(source: ImageSource.gallery);
    if (img == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backgroundPath', img.path);
    setState(() => _backgroundPath = img.path);
  }

  Future<void> _reprocessCurrent() async {
    if (_items.isEmpty) return;
    final item = _items[_selected.clamp(0, _items.length - 1)];
    setState(() {
      item
        ..cutoutPath = null
        ..status = PetItemStatus.processing;
    });
    try {
      final out = await SegmentationService.removeBackground(item.originalPath,
          maskSource: _maskSource);
      if (!mounted) return;
      setState(() {
        item
          ..cutoutPath = out
          ..status = PetItemStatus.done;
      });
      _refreshModelInfo();
    } on SegmentationException catch (e) {
      if (!mounted) return;
      setState(() {
        item
          ..status = PetItemStatus.failed
          ..error = e.message;
      });
    }
  }

  Future<void> _pickAndProcess() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final pics = await _picker.pickMultiImage();
      if (pics == null || pics.isEmpty) return;
      final start = _items.length;
      setState(() {
        for (final p in pics) {
          _items.add(PetItem(originalPath: p.path));
        }
        _selected = start;
      });
      for (var i = start; i < _items.length; i++) {
        final item = _items[i];
        try {
          final out = await SegmentationService.removeBackground(item.originalPath,
              maskSource: _maskSource);
          if (!mounted) return;
          setState(() {
            item
              ..cutoutPath = out
              ..status = PetItemStatus.done;
          });
        } on SegmentationException catch (e) {
          if (!mounted) return;
          setState(() {
            item
              ..status = PetItemStatus.failed
              ..error = e.message;
          });
        }
      }
      _refreshModelInfo();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _refreshModelInfo() async {
    try {
      final info = await SegmentationService.modelInfo();
      if (!mounted) return;
      final name = (info['activeModel'] as String?) ?? '未知';
      final note = (info['fallbackNote'] as String?) ?? '';
      setState(() {
        _activeModel = note.isEmpty ? name : '$name$note';
      });
    } catch (_) {
      // 旧包未实现 modelInfo 通道：忽略，徽章只显示版本
    }
  }

  @override
  void dispose() {
    _coquetryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF8F1),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('宠了么 · 1.5.0 · $_petName'),
        actions: [
          if (_picking)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(
              tooltip: '选择照片',
              onPressed: _pickAndProcess,
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
          IconButton(
            tooltip: '改名',
            onPressed: _rename,
            icon: const Icon(Icons.edit_note_outlined),
          ),
          IconButton(
            tooltip: '换背景',
            onPressed: _pickBackground,
            icon: const Icon(Icons.wallpaper_outlined),
          ),
          IconButton(
            tooltip: '喂食',
            onPressed: () => _stageKey.currentState?.feed(),
            icon: const Icon(Icons.fastfood_outlined),
          ),
          PopupMenuButton<void>(
            itemBuilder: (ctx) => [
              CheckedPopupMenuItem(
                value: null,
                checked: _coquetryOn,
                child: const Text('每 2 小时撒娇提醒'),
                onTap: () => Future(() => _toggleCoquetry(!_coquetryOn)),
              ),
            ],
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: _items.isEmpty ? _buildEmpty() : _buildStage(),
    );
  }

  Widget _versionBadge() {
    return FutureBuilder<String>(
      future: _nativeVersion,
      builder: (context, snap) {
        final base = '原生端 ${snap.data ?? "…"}';
        final model = _activeModel != null ? ' · 模型: $_activeModel' : '';
        return Text(
          base + model,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: Colors.brown.shade200),
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pets, size: 72, color: Colors.brown.shade300),
            const SizedBox(height: 16),
            Text('先生成你的数字毛孩',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '选 2-3 张清晰照片（不同角度），\n自动抠除背景，保留真实的它。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.brown.shade400, height: 1.6),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _pickAndProcess,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('选择本地照片'),
            ),
            const SizedBox(height: 16),
            _versionBadge(),
          ],
        ),
      ),
    );
  }

  Widget _buildStage() {
    final item = _items[_selected.clamp(0, _items.length - 1)];
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: PetStage(
              key: _stageKey,
              item: item,
              petName: _petName,
              backgroundPath: _backgroundPath,
            ),
          ),
          _buildActionBar(),
          _buildMaskSourceChips(),
          _buildThumbs(),
          const SizedBox(height: 2),
          _versionBadge(),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// P1 动作栏：可枚举姿态（点按保持）+ 动态动作（转圈/打滚/蹦跳/摇尾）
  Widget _buildActionBar() {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: kPetButtons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final b = kPetButtons[i];
          final active = b.pose != null &&
              _stageKey.currentState?.activePose == b.pose;
          return InkWell(
            onTap: () {
              if (b.pose != null) {
                _stageKey.currentState?.setPose(b.pose!);
              } else if (b.action != null) {
                _stageKey.currentState?.triggerAction(b.action!);
              }
            },
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.brown.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.brown.withOpacity(0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(b.icon,
                      size: 20,
                      color: active ? Colors.white : Colors.brown.shade600),
                  const SizedBox(height: 2),
                  Text(b.name,
                      style: TextStyle(
                          fontSize: 11,
                          color: active
                              ? Colors.white
                              : Colors.brown.shade700)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 边缘源调试芯片：d1~d7 对应模型 7 路侧输出
  Widget _buildMaskSourceChips() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Text('边缘源', style: TextStyle(fontSize: 11, color: Colors.brown.shade400)),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: 7,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final selected = i == _maskSource;
                return GestureDetector(
                  onTap: () {
                    if (_maskSource == i) return;
                    setState(() => _maskSource = i);
                    _reprocessCurrent();
                  },
                  child: Container(
                    width: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.brown.shade200,
                      ),
                    ),
                    child: Text(
                      'd${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? Colors.white : Colors.brown.shade500,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _buildThumbs() {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final item = _items[i];
          final selected = i == _selected;
          return GestureDetector(
            onTap: () => setState(() => _selected = i),
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.brown.shade100,
                  width: selected ? 2 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.brown.withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: item.status == PetItemStatus.processing
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.file(
                        File(item.cutoutPath ?? item.originalPath),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// ============================================================
// P1 · 可动 2.5D 骨骼宠物舞台（头/身/尾分层 + 可枚举姿态）
// 纯 Dart/Flutter，不新增依赖、不接原生渲染器、不接 DragonBones
// ============================================================

class PetStage extends StatefulWidget {
  const PetStage({
    super.key,
    required this.item,
    required this.petName,
    this.backgroundPath,
  });

  final PetItem item;
  final String petName;
  final String? backgroundPath;

  @override
  State<PetStage> createState() => _PetStageState();
}

class _PetStageState extends State<PetStage> with TickerProviderStateMixin {
  // 呼吸（叠加在身体上）
  late final AnimationController _breathCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat(reverse: true);
  late final CurvedAnimation _breath =
      CurvedAnimation(parent: _breathCtrl, curve: Curves.easeInOut);

  // 姿态切换（坐/趴/站/歪头… 平滑过渡并保持）
  late final AnimationController _poseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..addListener(() => setState(() {}));
  PoseSpec _fromSpec = kPoseSpecs[Pose.idle]!;
  Pose _pose = Pose.idle;
  Pose get activePose => _pose;

  // 一次性动态动作（转圈/打滚/蹦跳）
  late final AnimationController _actionCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  String? _activeAction;

  // 摇尾巴（循环，仅在用户点「摇尾巴」时启动）
  late final AnimationController _wagCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _wagging = false;

  // 点击跳跃
  late final AnimationController _jumpCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );

  // 拖动转视角回弹
  late final AnimationController _dragCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  double _dragRotY = 0.0;
  double _dragFrom = 0.0;

  // 喂食
  late final AnimationController _feedCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _showFood = false;

  // 分层切割比例（首次进入可拖动微调，让宠物更像原图）
  double _headSplit = 0.34; // 头/身分界（占高度比例，自上而下）
  double _tailSplit = 0.82; // 身/尾分界
  bool _adjusting = false;

  final AudioPlayer _player = AudioPlayer();
  final Random _random = Random();
  Timer? _hideBubbleTimer;
  bool _showBubble = false;
  String _bubbleText = '喵～';
  final List<String> _hearts = [];

  static const List<String> _meows = ['喵～', '喵呜～', '喵嗷！', '喵？', '咕噜咕噜…'];

  @override
  void initState() {
    super.initState();
    _player.setVolume(0.9);
    _dragCtrl.addListener(() => setState(() {}));
    _actionCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _activeAction = null);
      }
    });
    _feedCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _showFood = false);
        _showBubble = true;
        _bubbleText = '好吃！';
        _scheduleBubbleHide();
      }
    });
  }

  PoseSpec _liveSpec() => _fromSpec.lerp(kPoseSpecs[_pose]!, _poseCtrl.value);

  void setPose(Pose p) {
    _fromSpec = _liveSpec();
    _pose = p;
    _stopDynamic();
    _poseCtrl.forward(from: 0);
  }

  void _stopDynamic() {
    if (_activeAction != null) {
      _activeAction = null;
      _actionCtrl.stop();
    }
    if (_wagging) {
      _wagging = false;
      _wagCtrl.stop();
    }
  }

  void triggerAction(String id) {
    if (id == 'wag') {
      _wagging = !_wagging;
      if (_wagging) {
        _activeAction = null;
        _actionCtrl.stop();
        _wagCtrl.repeat();
      } else {
        _wagCtrl.stop();
      }
      setState(() {});
      return;
    }
    _wagging = false;
    _wagCtrl.stop();
    setState(() => _activeAction = id);
    _actionCtrl.forward(from: 0);
  }

  void feed() {
    setState(() {
      _showFood = true;
      _showBubble = false;
    });
    _feedCtrl.forward(from: 0);
  }

  @override
  void dispose() {
    _breathCtrl.dispose();
    _poseCtrl.dispose();
    _actionCtrl.dispose();
    _wagCtrl.dispose();
    _jumpCtrl.dispose();
    _dragCtrl.dispose();
    _feedCtrl.dispose();
    _hideBubbleTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _scheduleBubbleHide() {
    _hideBubbleTimer?.cancel();
    _hideBubbleTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showBubble = false);
    });
  }

  Future<void> _poke() async {
    if (!_jumpCtrl.isAnimating) _jumpCtrl.forward(from: 0);
    setState(() {
      _bubbleText = _meows[_random.nextInt(_meows.length)];
      _showBubble = true;
      _hearts.add('❤');
      if (_hearts.length > 6) _hearts.removeAt(0);
    });
    _scheduleBubbleHide();
    _playMeow();
  }

  Future<void> _playMeow() async {
    var played = false;
    try {
      await _player.setPlaybackRate(0.9 + _random.nextDouble() * 0.3);
      await _player.play(AssetSource('sounds/meow.mp3'));
      played = true;
    } catch (_) {
      // assets 未配置，尝试原生提示音
    }
    if (!played) {
      try {
        await const MethodChannel('pet_segmentation/segment')
            .invokeMethod('clickSound');
      } catch (_) {
        // 都失败就只显示气泡
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _dragRotY = (_dragRotY + d.delta.dx * 0.008).clamp(-0.7, 0.7);
    setState(() {});
  }

  void _onPanEnd(DragEndDetails _) {
    _dragFrom = _dragRotY;
    _dragCtrl.forward(from: 0).then((_) => _dragRotY = 0.0);
  }

  PartPose _add(PartPose a, PartPose b) => PartPose(
        rotZ: a.rotZ + b.rotZ,
        rotY: a.rotY + b.rotY,
        dx: a.dx + b.dx,
        dy: a.dy + b.dy,
        scaleX: a.scaleX * b.scaleX,
        scaleY: a.scaleY * b.scaleY,
      );

  PoseSpec _dynamicDelta() {
    if (_wagging) {
      final w = sin(_wagCtrl.value * 2 * pi * 4) * 0.5;
      return PoseSpec(tail: PartPose(rotZ: w));
    }
    if (_activeAction == 'spin') {
      final r = sin(_actionCtrl.value * pi) * 2 * pi;
      final p = PartPose(rotY: r);
      return PoseSpec(head: p, body: p, tail: p);
    }
    if (_activeAction == 'roll') {
      final r = sin(_actionCtrl.value * pi) * 2 * pi;
      final p = PartPose(rotZ: r);
      return PoseSpec(head: p, body: p, tail: p);
    }
    if (_activeAction == 'hop') {
      final d = -sin(_actionCtrl.value * 2 * pi).abs() * 90.0;
      final p = PartPose(dy: d);
      return PoseSpec(head: p, body: p, tail: p);
    }
    return const PoseSpec();
  }

  Matrix4 _partMatrix(PartPose p, double pivotY) {
    final m = Matrix4.identity();
    m.setEntry(3, 2, -0.001);
    m.translate(0.0, pivotY);
    m.multiply(Matrix4.rotationZ(p.rotZ));
    m.multiply(Matrix4.rotationY(p.rotY));
    m.multiply(Matrix4.diagonal3Values(p.scaleX, p.scaleY, 1.0));
    m.translate(p.dx, p.dy);
    m.translate(0.0, -pivotY);
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stageH = constraints.maxHeight;
        final stageW = constraints.maxWidth;
        final imgW = min<double>(stageW * 0.72, 340);
        final imgH = stageH * 0.58;

        return Stack(
          alignment: Alignment.center,
          children: [
            if (widget.backgroundPath != null)
              Positioned.fill(
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    Colors.black.withOpacity(0.12),
                    BlendMode.darken,
                  ),
                  child: Image.file(
                    File(widget.backgroundPath!),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            SizedBox(width: imgW, height: imgH, child: _buildGroundShadow()),
            // 宠物本体（头/身/尾三层 + 拖动转视角 + 点击摸头）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _poke,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _breath,
                  _poseCtrl,
                  _actionCtrl,
                  _wagCtrl,
                  _jumpCtrl,
                  _dragCtrl,
                ]),
                builder: (context, _) {
                  final dragRot = _dragCtrl.isAnimating
                      ? _dragFrom * (1 - _dragCtrl.value)
                      : _dragRotY;
                  final lift = -sin(pi * _jumpCtrl.value) * 64.0;
                  final breath = 1.0 + 0.025 * _breath.value;

                  final base = _liveSpec();
                  final dyn = _dynamicDelta();
                  final head = _add(base.head, dyn.head);
                  final body = _add(base.body, dyn.body);
                  final tail = _add(base.tail, dyn.tail);

                  final global = Matrix4.identity()..setEntry(3, 2, -0.0018);
                  global.multiply(Matrix4.rotationY(dragRot));
                  global.translate(0.0, lift);
                  global.multiply(Matrix4.diagonal3Values(1.0, breath, 1.0));

                  return Transform(
                    alignment: Alignment.bottomCenter,
                    transform: global,
                    child: _buildLayeredPet(imgW, imgH, head, body, tail),
                  );
                },
              ),
            ),
            if (_showFood)
              AnimatedBuilder(
                animation: _feedCtrl,
                builder: (context, child) {
                  final drop = _feedCtrl.value;
                  return Positioned(
                    top: 8 + drop * (stageH * 0.42),
                    child: Opacity(
                      opacity: 1 - drop * 0.2,
                      child: const Text('🍖', style: TextStyle(fontSize: 34)),
                    ),
                  );
                },
              ),
            Positioned(top: stageH * 0.04, child: _buildBubble()),
            ..._buildHearts(stageH),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: Icon(
                  _adjusting ? Icons.check : Icons.tune,
                  color: Colors.white,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.brown.withOpacity(0.55),
                ),
                tooltip: _adjusting ? '完成微调' : '微调头/身/尾分界',
                onPressed: () => setState(() => _adjusting = !_adjusting),
              ),
            ),
            if (_adjusting) _buildSplitHandles(imgW, imgH),
            Positioned(
              left: 16,
              right: 16,
              bottom: 6,
              child: _buildStatusLine(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLayeredPet(
    double imgW,
    double imgH,
    PartPose head,
    PartPose body,
    PartPose tail,
  ) {
    final item = widget.item;
    if (item.status != PetItemStatus.done || item.cutoutPath == null) {
      return _buildBusyPet(imgW, imgH);
    }
    final file = File(item.cutoutPath!);
    final pivotHead = (_headSplit - 0.5) * imgH;
    final pivotBody = (_headSplit - 0.5) * imgH;
    final pivotTail = (_tailSplit - 0.5) * imgH;

    Widget layer(PartPose p, double topF, double botF, double pivotY) {
      final m = _partMatrix(p, pivotY);
      return Transform(
        alignment: Alignment.topLeft,
        transform: m,
        child: ClipRect(
          clipper: _BandClipper(topF, botF),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            width: imgW,
            height: imgH,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image_outlined, size: 48),
          ),
        ),
      );
    }

    return SizedBox(
      width: imgW,
      height: imgH,
      child: Stack(
        children: [
          layer(tail, _tailSplit, 1.0, pivotTail),
          layer(body, _headSplit, _tailSplit, pivotBody),
          layer(head, 0.0, _headSplit, pivotHead),
        ],
      ),
    );
  }

  Widget _buildBusyPet(double imgW, double imgH) {
    final item = widget.item;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.brown.withOpacity(0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(item.originalPath),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_outlined, size: 48),
            ),
            if (item.status == PetItemStatus.processing)
              Container(
                color: Colors.black.withOpacity(0.25),
                alignment: Alignment.center,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 10),
                    Text('正在抠图…', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitHandles(double imgW, double imgH) {
    Widget handle(double frac, void Function(double) onUpdate, Color color) {
      return Positioned(
        top: frac * imgH - 14,
        left: 0,
        right: 0,
        child: GestureDetector(
          onPanUpdate: (d) => onUpdate(
              ((frac * imgH + d.delta.dy) / imgH).clamp(0.1, 0.9)),
          child: Container(
            height: 28,
            decoration: BoxDecoration(
              color: color.withOpacity(0.85),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.drag_handle, color: Colors.white, size: 18),
          ),
        ),
      );
    }

    return SizedBox(
      width: imgW,
      height: imgH,
      child: Stack(
        children: [
          handle(_headSplit, (v) => setState(() => _headSplit = v), Colors.orange),
          handle(_tailSplit, (v) => setState(() => _tailSplit = v), Colors.green),
        ],
      ),
    );
  }

  List<Widget> _buildHearts(double stageH) {
    return _hearts.asMap().entries.map((e) {
      final i = e.key;
      return Positioned(
        right: 24 + i * 18,
        top: stageH * 0.12 + i * 6,
        child: const Text('❤', style: TextStyle(fontSize: 20, color: Colors.red)),
      );
    }).toList();
  }

  Widget _buildGroundShadow() {
    final item = widget.item;
    if (item.status == PetItemStatus.done && item.cutoutPath != null) {
      return Transform.translate(
        offset: const Offset(0, 14),
        child: Opacity(
          opacity: 0.22,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: ColorFiltered(
              colorFilter: const ColorFilter.mode(
                  Color(0xFF3B2A1A), BlendMode.srcATop),
              child: Image.file(
                File(item.cutoutPath!),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: 180,
        height: 22,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3B2A1A).withOpacity(0.18),
              blurRadius: 18,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble() {
    return AnimatedOpacity(
      opacity: _showBubble ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      child: AnimatedScale(
        scale: _showBubble ? 1 : 0.6,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.brown.withOpacity(0.12),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            _bubbleText,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF5A4634),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusLine() {
    final item = widget.item;
    String text;
    Color color;
    switch (item.status) {
      case PetItemStatus.processing:
        text = 'AI 正在把它从背景里抱出来…';
        color = Colors.brown;
        break;
      case PetItemStatus.done:
        text =
            '${widget.petName} 已生成 · 点它摸头 · 拖动转视角 · 下方选姿态/动作 · 右上角可微调';
        color = Colors.green.shade700;
        break;
      case PetItemStatus.failed:
        text = '抠图失败：${item.error ?? '未知原因'}';
        color = Colors.red.shade600;
        break;
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12, color: color),
    );
  }
}

/// 垂直分带裁剪：只显示图像 [topF, botF] 区间（占高度比例）
class _BandClipper extends CustomClipper<Rect> {
  final double topF;
  final double botF;
  const _BandClipper(this.topF, this.botF);
  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, topF * size.height, size.width, botF * size.height);
  @override
  bool shouldReclip(_BandClipper old) =>
      old.topF != topF || old.botF != botF;
}
