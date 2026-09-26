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
// 2.5D 纸片宠物 · 动作库（20 个）
// 每个动作 = 一个 t∈[0,1] 的变换函数；t=1 时回到单位矩阵，动作结束干净归位
// ============================================================

typedef PetTransform = Matrix4 Function(double t);

class PetAction {
  const PetAction(this.name, this.icon, this.transform);
  final String name;
  final IconData icon;
  final PetTransform transform;
}

Matrix4 _m() => Matrix4.identity();

const List<PetAction> kPetActions = [
  PetAction('摇尾巴', Icons.pets, _aWag),
  PetAction('打滚', Icons.autorenew, _aRoll),
  PetAction('扑跳', Icons.flash_on, _aPounce),
  PetAction('撒娇', Icons.favorite, _aCute),
  PetAction('伸懒腰', Icons.landscape, _aStretch),
  PetAction('歪头', Icons.face_retouching_natural, _aTilt),
  PetAction('点头', Icons.keyboard_arrow_down, _aNod),
  PetAction('蹦跳', Icons.celebration, _aHop),
  PetAction('转圈', Icons.rotate_90_degrees_ccw, _aSpin),
  PetAction('坐下', Icons.chair, _aSit),
  PetAction('趴下', Icons.horizontal_rule, _aLie),
  PetAction('摇身', Icons.swap_horiz, _aShake),
  PetAction('卖萌', Icons.emoji_emotions, _aMoe),
  PetAction('好奇', Icons.visibility, _aCurious),
  PetAction('开心', Icons.sentiment_very_satisfied, _aHappy),
  PetAction('委屈', Icons.sentiment_dissatisfied, _aSad),
  PetAction('兴奋', Icons.whatshot, _aExcited),
  PetAction('召唤', Icons.campaign, _aCome),
  PetAction('飞吻', Icons.favorite_border, _aKiss),
  PetAction('转头', Icons.rotate_right, _aTurn),
];

Matrix4 _aWag(double t) => _m()..rotateZ(sin(t * 2 * pi * 3) * 0.18);
Matrix4 _aRoll(double t) => _m()..rotateZ(t * 2 * pi);
Matrix4 _aPounce(double t) =>
    (_m()..translate(0.0, -sin(pi * t) * 130.0))..scale(1.0 + 0.12 * sin(pi * t));
Matrix4 _aCute(double t) => (_m()
  ..rotateZ(sin(pi * t * 2) * 0.12))
  ..scale(1.0 + 0.06 * sin(pi * t * 2), 1.0 - 0.04 * sin(pi * t * 2));
Matrix4 _aStretch(double t) =>
    _m()..scale(1.0 - 0.12 * sin(pi * t), 1.0 + 0.22 * sin(pi * t));
Matrix4 _aTilt(double t) => _m()..rotateZ(-0.35 * sin(pi * t));
Matrix4 _aNod(double t) => _m()..rotateX(0.3 * sin(pi * t));
Matrix4 _aHop(double t) => _m()..translate(0.0, -sin(pi * t * 2).abs() * 90.0);
Matrix4 _aSpin(double t) => _m()..rotateY(t * 2 * pi * 2);
Matrix4 _aSit(double t) =>
    (_m()..translate(0.0, 10.0 * sin(pi * t)))..scale(1.0, 1.0 - 0.18 * sin(pi * t));
Matrix4 _aLie(double t) => _m()..scale(1.0, 1.0 - 0.32 * sin(pi * t));
Matrix4 _aShake(double t) => _m()..translate(sin(pi * t * 6) * 22.0, 0.0);
Matrix4 _aMoe(double t) => _m()..scale(1.0 + 0.16 * sin(pi * t));
Matrix4 _aCurious(double t) =>
    (_m()..rotateZ(0.12 * sin(pi * t)))..scale(1.0 + 0.08 * sin(pi * t));
Matrix4 _aHappy(double t) =>
    (_m()..translate(0.0, -sin(pi * t * 3).abs() * 70.0))
    ..rotateZ(sin(pi * t * 3) * 0.1);
Matrix4 _aSad(double t) =>
    (_m()..translate(0.0, 8.0 * sin(pi * t)))..rotateZ(-0.08 * sin(pi * t));
Matrix4 _aExcited(double t) =>
    (_m()..translate(0.0, -sin(pi * t * 4).abs() * 100.0))
    ..scale(1.0 + 0.08 * sin(pi * t * 4));
Matrix4 _aCome(double t) => _m()..scale(1.0 + 0.2 * sin(pi * t));
Matrix4 _aKiss(double t) =>
    (_m()..rotateZ(0.1 * sin(pi * t)))..scale(1.0 + 0.14 * sin(pi * t));
Matrix4 _aTurn(double t) => _m()..rotateY(sin(pi * t) * 0.7);

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
    if (mounted) setState(() {});
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
        title: Text('宠了么 · 1.4.0 · $_petName'),
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

  /// 20 个动作按钮（横向滚动）
  Widget _buildActionBar() {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: kPetActions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = kPetActions[i];
          return InkWell(
            onTap: () => _stageKey.currentState?.playAction(a),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
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
                  Icon(a.icon, size: 20, color: Colors.brown.shade600),
                  const SizedBox(height: 2),
                  Text(a.name,
                      style: TextStyle(fontSize: 11, color: Colors.brown.shade700)),
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
// 2.5D 纸片宠物舞台
// 拖动转视角 + 呼吸 + 落影 + 点击摸头 + 20 动作 + 喂食
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
  // 呼吸
  late final AnimationController _breathCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat(reverse: true);
  late final CurvedAnimation _breath =
      CurvedAnimation(parent: _breathCtrl, curve: Curves.easeInOut);

  // 动作播放（单次）
  late final AnimationController _actionCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  PetAction? _currentAction;

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
        setState(() => _currentAction = null);
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

  void playAction(PetAction action) {
    setState(() => _currentAction = action);
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
    _actionCtrl.dispose();
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
            // 落影（宠物跳起时影子留在地上）
            SizedBox(width: imgW, height: imgH, child: _buildGroundShadow()),
            // 宠物本体（可拖动转视角、点击摸头）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _poke,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: AnimatedBuilder(
                animation: Listenable.merge([_breath, _jumpCtrl, _actionCtrl]),
                builder: (context, child) {
                  final dragRot = _dragCtrl.isAnimating
                      ? _dragFrom * (1 - _dragCtrl.value)
                      : _dragRotY;
                  final actionM = _currentAction?.transform(_actionCtrl.value) ??
                      Matrix4.identity();
                  final lift = -sin(pi * _jumpCtrl.value) * 64.0;
                  final breath = 1.0 + 0.025 * _breath.value;

                  final m = Matrix4.identity()..setEntry(3, 2, -0.0018);
                  m.multiply(Matrix4.rotationY(dragRot));
                  m.multiply(actionM);
                  m.translate(0.0, lift);
                  m.multiply(Matrix4.diagonal3Values(1.0, breath, 1.0));

                  return Transform(
                    alignment: Alignment.bottomCenter,
                    transform: m,
                    child: child,
                  );
                },
                child: SizedBox(
                  width: imgW,
                  height: imgH,
                  child: _buildPetImage(),
                ),
              ),
            ),
            // 喂食动画
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
            // 叫声 / 喂食气泡
            Positioned(
              top: stageH * 0.04,
              child: _buildBubble(),
            ),
            // 摸头爱心
            ..._buildHearts(stageH),
            // 状态提示
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

  Widget _buildPetImage() {
    final item = widget.item;
    if (item.status == PetItemStatus.done && item.cutoutPath != null) {
      return Image.file(
        File(item.cutoutPath!),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image_outlined, size: 48),
      );
    }
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
        text = '${widget.petName} 已生成 · 点它摸头 · 拖动可转视角 · 下方选动作';
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
