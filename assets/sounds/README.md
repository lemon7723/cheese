# 叫声音频目录

把宠物的原声文件命名为 `meow.mp3` 放在本目录（或 dog.mp3 等），
然后在 `pubspec.yaml` 里 `assets:` 已声明 `assets/sounds/`，`flutter pub get` 后即可生效。

没有音频文件时，App 会自动用系统提示音代替，不会崩溃。
（本 .gitkeep / README 仅用于保证目录存在，构建时会被忽略。）
