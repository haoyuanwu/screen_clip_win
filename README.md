# 定格T

一款轻巧的常驻截图工具。没有主页，也不保存截图历史；框选、标注、复制，在同一个截图界面里完成。

[下载 Windows 安装版](https://github.com/haoyuanwu/screen_clip_win/releases/download/v1.0.0/ScreenClip-1.0.0-Windows-x64-Setup.exe) · [下载便携版](https://github.com/haoyuanwu/screen_clip_win/releases/download/v1.0.0/ScreenClip-1.0.0-Windows-x64-Portable.zip) · [查看发布版本](https://github.com/haoyuanwu/screen_clip_win/releases)

## 截图，只需几步

1. 按 **Ctrl + Shift + X** 唤起截图。
2. 拖动框选区域，直接添加需要的标注。
3. 点击 **✓** 或按 **Enter**，图片即复制到剪贴板。

启动后驻留系统托盘，不弹出主页。按 **Esc** 取消截图，不改变剪贴板；需要文件时可主动保存 PNG。

## 功能

- **默认开机启动**：登录后驻留托盘，可在偏好设置中关闭。
- **多种截图方式**：区域、窗口、全屏，以及 0 / 3 / 5 / 10 秒延时。
- **截图前完成标注**：箭头、方框、自由画笔、文字与序号。
- **隐私画笔**：单个图标切换模糊／马赛克，连续涂抹，滑块调整粗细，白色圆圈预览范围。
- **局部擦除**：支持橡皮擦、撤销与重做。
- **灵活的文字样式**：输入框随内容伸缩，支持文字颜色、背景颜色、字号、粗体、斜体和下划线。
- **紧凑毛玻璃工具栏**：自动调整位置，保持在单块显示器内，配合按压和状态切换动画。
- **三种主题**：跟随系统、浅色、深色。
- **默认复制，不保存记录**：图片仅在内存中处理，仅主动保存时写入文件。

## 安装与使用

**Windows 安装版**：下载 Setup.exe，运行安装向导，安装完成后启动定格T。

**Windows 便携版**：完整解压到固定目录，运行 `screen_clip_win.exe`。请勿直接在压缩包内运行；启用开机启动后请保持程序目录不变。

首次运行默认启用开机启动。看不到主窗口是正常现象，可从系统托盘或全局快捷键进入。升级前，请先从托盘退出旧版本。

当前提供 Windows 64 位安装版和便携版。项目采用 Flutter 共享界面架构；macOS 原生实现尚未完成真机编译验收，暂不提供 macOS 安装包。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 唤起截图 | Ctrl + Shift + X |
| 复制截图 | Enter / Ctrl + C |
| 保存 PNG | Ctrl + S |
| 取消 | Esc |
| 撤销 / 重做 | Ctrl + Z / Ctrl + Shift + Z |
| 选择 / 箭头 / 方框 / 画笔 / 文字 | V / A / R / P / T |
| 隐私画笔 / 橡皮擦 | B / E |

## 源码与开发

项目采用 Flutter 共享截图编辑界面，Windows 使用 Win32 托盘、全局快捷键和截图服务；macOS 使用菜单栏与 ScreenCaptureKit。

使用 `.fvmrc` 指定的 Flutter 版本：

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
```

Windows 安装脚本为 `packaging/windows.iss`，使用 Inno Setup 编译。分发时需包含整个 Release 目录及匹配的 Microsoft Visual C++ 运行库。

在 Mac 上可执行 `flutter run -d macos` 或 `flutter build macos --release`。macOS 原生代码尚未完成真机编译验收。

详细说明：[产品设计](docs/product-design.md)、[设计系统](design-system/screenclip/MASTER.md)、[发布说明](docs/releases/1.0.0.md)。
