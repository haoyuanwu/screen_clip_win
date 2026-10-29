# Argos 中英本地翻译

本地渠道默认启用并选中，在线渠道仍默认关闭，已有明确保存的渠道和开关选择会保留。首次翻译缺少语言包时直接提示下载，下载后保存继续原来的翻译；也可以进入翻译渠道 → 本地翻译 · Argos → 配置预先准备。截图工具栏的“翻译语言”展开源/目标选择及交换，本地渠道仅提供中英选项。

文字翻译、选区 OCR 图上译文、对照阅读共用本地翻译通道。图片和原文不上传，翻译不联网，无 API Key；首次语言包准备需要网络。当前仅中英双向，自动模式按文字区域识别中英文，其他语言应选择在线渠道。采用 Argos 1.9 语言包和 CTranslate2 CPU int8 推理，使用有界标点切分，未引入完整 Python Argos 的 Stanza/PyTorch 管线。质量应以实际文案验收，专业术语可切换在线渠道。

## 构建与双平台验证

需 Python 3.12、对应平台的编译环境。引擎以 PyInstaller onedir 打包，最终用户无需安装 Python。

Windows：
```
python tools/argos/build.py --destination build/windows/x64/runner/Release/argos
python tools/argos/smoke.py --worker build/windows/x64/runner/Release/argos/screenclip_argos.exe --data-dir build/argos-models --download
```

macOS：分别在 arm64 和 x86_64 Python 环境中运行，不能使用 Windows 构建交叉打包。
```
python3 tools/argos/build.py --destination build/argos-helper
python3 tools/argos/smoke.py --worker build/argos-helper/screenclip_argos --data-dir build/argos-models --download
```

macOS 打包脚本将引擎放入 `Contents/Helpers/argos`，检查所有 Mach-O 的目标架构、签名嵌套二进制，再给 helper 签署沙盒继承权限；不关闭应用沙盒。需要分别提供已验收的辅助进程目录时使用 `ARGOS_HELPER_ARM64` 和 `ARGOS_HELPER_X64` 环境变量。完整 macOS 应用还需在本机验收沙盒内启动、下载、实际翻译与取消，单独运行 helper 不能代替这项检查。

Windows 打包脚本构建 helper 并带入安装包及便携包。未包含 helper 的开发构建在设置中显示明确提示，不静默回退到云端。

## 数据与故障处理

语言包存于原生 `dataDirectory()/argos`：Windows 是 LocalAppData/ScreenClip，macOS 是应用可写 Application Support/ScreenClip 目录。原文与译文通过 stdin/stdout 内存管道传递，不写文件、不保存历史。关闭窗口、取消或超时会终止本次子进程。

模型为两个固定版本 ZIP；下载使用 HTTPS 并检查 SHA-256，限制下载与解压大小、防止目录穿越，只有完整校验后才进入已安装目录。模型内的说明和许可文件保留。下载取消可能留下临时下载目录，不会被当成有效模型；再次准备可重试。

## 本次验证（2026-10-28）

- 静态分析及 130 项 Flutter 测试通过（另有 2 项原有平台测试跳过）。
- Windows x64 Release 编译、自包含辅助进程构建、真实中英双向模型推理通过；示例 Hello world! → 哈罗世界!、你好，世界！ → Hello, world!。
- Flutter → 已打包辅助进程的完整验收通过，包含截图文字分段、空段落保留、取消及不创建云端 HTTP 客户端。
- 官方真实模型 SHA-256 校验通过；生产安装函数使用相同真实归档验证校验、解压和安装。下载测试曾遇到网络超时，通过官方源范围请求完成测试模型下载；普通下载的进度与取消仍由生产工作进程处理。
- 禁止 Python 网络连接后双向推理通过。验证不代表专业术语翻译质量已全面验收。
- 确认 CTranslate2 4.6.0 / SentencePiece 0.2.1 提供 Windows x64、macOS x64 和 arm64 的 Python 3.12 官方轮子。
- **macOS 尚未真机编译或运行验收**。已接入辅助进程路径、按架构打包、Mach-O 校验和沙盒继承签名；需在 Mac 上执行下列验收，不能仅凭 Windows 测试认定 macOS 可用。

Flutter 到真实引擎的通用验收：设置 `SCREENCLIP_ARGOS_WORKER` 为对应平台的已打包辅助进程绝对路径，设置 `SCREENCLIP_ARGOS_MODELS` 为已准备的语言包绝对路径，再执行：
```
flutter test tools/argos_bridge_smoke_test.dart
```

macOS 还需安装实际 DMG，从渠道设置完成首次下载与取消，并在沙盒应用中验证中英互译、选区图上译文和对照阅读。
