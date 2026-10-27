# 定格T

一款轻巧的常驻截图工具。没有主页，也不保存截图历史；框选、标注、复制，在同一个截图界面里完成。

[下载 macOS Apple Silicon](https://github.com/haoyuanwu/screen_clip_win/releases/download/v1.1.2/ScreenClip-1.1.2-macOS-arm64.dmg) · [下载 macOS Intel](https://github.com/haoyuanwu/screen_clip_win/releases/download/v1.1.2/ScreenClip-1.1.2-macOS-x64.dmg) · [下载 Windows 安装版](https://github.com/haoyuanwu/screen_clip_win/releases/download/v1.1.1/ScreenClip-1.1.1-Windows-x64-Setup.exe) · [下载便携版](https://github.com/haoyuanwu/screen_clip_win/releases/download/v1.1.1/ScreenClip-1.1.1-Windows-x64-Portable.zip) · [查看发布版本](https://github.com/haoyuanwu/screen_clip_win/releases)

## 截图，只需几步

1. 按 **Ctrl + Shift + X** 唤起截图。
2. 拖动框选区域，直接添加需要的标注。
3. 点击 **✓** 或按 **Enter**，图片即复制到剪贴板。

启动后驻留系统托盘，不弹出主页。按 **Esc** 取消截图，不改变剪贴板；需要文件时可主动保存 PNG。

## 功能

- **图形标注**：方框、圆形和椭圆须拖动创建，忽略单击和微小误触；共用颜色与粗细设置，支持撤销／重做。截图选区始终为矩形。
- **自适应工具栏**：宽度随内容调整，窄屏自动换行，始终保持在当前显示器内。
- **形状说明**：画完箭头、直线或图形后，右下角临时显示“添加文字”气泡，点击即可在附近输入说明。
- **直线标注**：按 G，依次点击起点和终点绘制直线，移动鼠标可预览；也支持拖动绘制、调整颜色与粗细、撤销／重做。
- **图钉暂存**：按 F 或点击图钉将图片暂存在屏幕顶层，带过渡动画；支持拖动、滚轮缩放、复制和关闭，多张图钉只在当前会话中保留。暂存后自动 OCR，可直接拖选图片文字，按 Ctrl/⌘+C 复制；Ctrl/⌘+A 全选，顶部文字按钮复制选中内容（无选中时复制全部），图片按钮仍复制图片。空白处拖动图钉，Option/Alt 可从文字上拖动。


- **默认开机启动**：登录后驻留托盘，可在偏好设置中关闭。
- **常驻菜单栏入口**：macOS 禁用拖出移除状态栏图标；收起窗口后仍保留图标。系统或第三方菜单栏管理工具的收纳由其自身设置控制。
- **多种截图方式**：区域、窗口、全屏，以及 0 / 3 / 5 / 10 秒延时。Windows 与 macOS 均支持跨显示器框选，适配负坐标、上下排列和混合缩放；macOS 每块显示器原位呈现对应快照，兼容独立桌面空间，以原生快照承接编辑首帧，减少唤起闪烁。
- **完整窗口抓取**：macOS 智能选取窗口时使用 ScreenCaptureKit 独立抓取，获取被遮挡的窗口内容，并在原位置显示；无需辅助功能权限，不改变真实窗口层级。改选桌面恢复最初快照，仅需要已有的屏幕录制权限。Windows 保留临时置顶并在完成或取消后恢复。
- **截图前完成标注**：箭头、直线、方框、自由画笔、文字与序号。
- **二维码扫描**：使用 `flutter_zxing: ^3.1.0` 本地扫描当前选区，多个二维码分别在中心显示彩色背景箭头；点击用默认浏览器打开网页链接并退出截图，不改变剪贴板，右键可查看与复制内容，纯文本二维码直接查看。按钮不会进入导出。
- **屏幕取色器**：全局 `Ctrl + Shift + C` 直接进入多屏桌面取色，可跨屏移动鼠标，不需要框选，也不等待截图延时；截图工具栏内按 `I` 取色。移动鼠标显示像素放大图、色块、sRGB 0–255 与 HEX，点击后固定卡片与放大图，点击数值复制；全局取色固定后回到桌面悬浮卡片，截图内取色关闭后继续编辑。实时卡片保持在鼠标所在显示器内，支持不同屏幕排列与缩放比例。
- **隐私画笔**：单个图标切换模糊／马赛克，支持画笔／框选切换，默认画笔；画笔连续涂抹并调整粗细，框选拖动矩形处理整块区域。
- **多渠道文字翻译**：从常驻工具条打开翻译，或在截图选区点击翻译并本地提取文字。支持智谱 AI、DeepSeek、通义千问、Kimi、豆包、OpenAI 与自定义兼容接口，原文可编辑、语言可切换、可取消重试及复制译文。请在“翻译渠道与 API Key”中配置自己的 Key 和已开通的模型；只有主动翻译才发送原文，不上传图片，密钥保存在系统安全存储，不保存翻译历史。
- **OCR 文字识别**：工具栏点击「识别文字」，离线识别当前选区，识别时在选区内显示扫描动画，完成后直接在图片文字上拖动选择，支持跨行、全选与 Ctrl/⌘+C 复制；退出识别即可继续标注。使用项目内的 `packages/desktop_vision`（来自提供的 flutter-desktop-ocr），macOS 使用 Apple Vision，Windows 使用系统 OCR 语言组件。识别基于当前画面，包含标注与隐私处理，不上传图片。
- **灵活的文字样式**：输入框随内容自动增宽，到边缘换行增高，不在文字框内部滚动；支持文字颜色、背景颜色、字号、粗体、斜体和下划线。
- **紧凑毛玻璃工具栏**：自动调整位置，保持在单块显示器内，配合按压和状态切换动画。
- **三种主题**：跟随系统、浅色、深色。
- **默认复制，不保存记录**：图片仅在内存中处理，仅主动保存时写入文件。

## 安装与使用

**Windows 安装版**：下载 Setup.exe，运行安装向导，安装完成后启动定格T。

**Windows 便携版**：完整解压到固定目录，运行 `screen_clip_win.exe`。请勿直接在压缩包内运行；启用开机启动后请保持程序目录不变。

首次运行默认启用开机启动。看不到主窗口是正常现象，可从系统托盘或全局快捷键进入。升级前，请先从托盘退出旧版本。

macOS v1.1.2 分别提供 Apple Silicon（arm64）和 Intel（x64）DMG，要求 macOS 14.0 及以上。打开后将“定格T.app”拖入 Applications，退出旧版本后再启动。此包使用本地临时签名，尚未经过 Apple Developer ID 签名与公证。首次截图或取色需要屏幕录制权限。

Windows 安装版和便携版仍使用 v1.1.1；本次 macOS 更新没有生成新的 Windows 二进制包。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 唤起截图 | Ctrl + Shift + X |
| 复制截图 | Enter / Ctrl + C |
| 保存 PNG | Ctrl + S |
| 取消 | Esc |
| 撤销 / 重做 | Ctrl + Z / Ctrl + Shift + Z |
| 选择 / 箭头 / 方框 / 画笔 / 文字 | V / Q / R / P / T |
| 隐私画笔 | B |
| 取色器（截图内） | I |
| 全局屏幕取色 | Ctrl + Shift + C |
| 光标逐像素微调 | W / A / S / D（上 / 左 / 下 / 右；支持鼠标按住拖动时使用） |
| 图钉暂存 | F |
| 圆形标注 / 椭圆标注 | O / L |
| 直线标注 | G（点击两点或拖动；Enter 完成当前直线，Esc 取消当前直线） |

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

在 Mac 上可执行 `flutter run -d macos` 或 `flutter build macos --release`。已在 Apple Silicon 双屏环境检查截图、取色与启动流程；Intel 运行需要另行真机验证。

详细说明：[产品设计](docs/product-design.md)、[设计系统](design-system/screenclip/MASTER.md)、[发布说明](docs/releases/1.0.0.md)。
