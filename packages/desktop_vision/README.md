# desktop_vision

Flutter 桌面端（macOS / Windows）**本地 OCR** 插件，全部离线运行，返回行级与词级边界框。

- **macOS**：Apple Vision `VNRecognizeTextRequest`（revision 3）
- **Windows**：`Windows.Media.Ocr`（WinRT，需要系统已安装 OCR 语言包）

无模型文件、无第三方原生依赖、不上传图片。

## 用法

```yaml
dependencies:
  desktop_vision:
    path: ../desktop_vision
```

```dart
import 'package:desktop_vision/desktop_vision.dart';

// 能力探测（Windows 未安装 OCR 语言包时 isAvailable = false）
final info = await DesktopVision.engineInfo();
debugPrint('${info.engine} / ${info.languageTag}');

// 识别图片文件
final result = await DesktopVision.recognizeFile(
  '/path/to/image.png',
  languages: const ['zh-Hans', 'en-US'],
);

// 或识别内存字节（截图、剪贴板）
final fromBytes = await DesktopVision.recognizeBytes(pngBytes);

debugPrint(result.text);
for (final line in result.lines) {
  // 归一化坐标，左上原点，0~1
  debugPrint('${line.text} -> ${line.normalizedBox}');
}
```

画框：

```dart
canvas.drawRect(
  DesktopVision.toPaintRect(line.normalizedBox, size),
  paint,
);
```

## 返回结构

| 类型 | 字段 |
| --- | --- |
| `OcrResult` | `text` / `lines` / `imageWidth` / `imageHeight` / `engine` / `elapsedMs` |
| `OcrLine` | `text` / `normalizedBox` / `pixelBox` / `confidence` / `words` |
| `OcrWord` | `text` / `normalizedBox` / `pixelBox` / `confidence` |

> Windows 端不提供置信度，`confidence` 恒为 `-1`；`OcrLevel` 在 Windows 被忽略。

## 二维码

Windows 系统层没有图片级条码解码 API，二维码请配套 `flutter_zxing`（返回角点坐标）：

```dart
final codes = zx.readBarcodeImagePathString(path);
print(codes.first.text);
print(codes.first.points);
```

## 平台要求

- macOS 10.15+（中文推荐 macOS 13+）
- Windows 10 1809+，并安装对应语言的「光学字符识别」可选功能

## 验证状态

- `flutter analyze`：通过
- `flutter test`：7/7 通过
- macOS Swift OCR 服务：`swiftc -typecheck` 通过
- Windows C++：尚未在 Windows 上编译验证，首次接入请先 `flutter run -d windows`
