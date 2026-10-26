import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'desktop_vision_platform_interface.dart';
import 'src/models.dart';

export 'src/models.dart';

/// 桌面端（macOS / Windows）本地 OCR 的统一入口。
///
/// 平台实现：
/// - macOS：Apple Vision（`VNRecognizeTextRequest`），硬件加速，支持中英文等。
/// - Windows：系统 `Windows.Media.Ocr`（WinRT），需要设备已安装对应 OCR 语言包。
///
/// 全部离线运行，不联网、不上传图片。
///
/// 坐标系约定：所有 `normalizedBox` 均以**图片左上角**为原点、取值为 0~1，
/// 与平台原始坐标系（Vision 左下原点、WinRT 像素）的换算已在原生侧完成。
class DesktopVision {
  /// 当前平台是否具备 OCR 能力。
  ///
  /// Windows 上若系统未安装任何 OCR 语言包，会返回 false。
  static Future<bool> isSupported() {
    return DesktopVisionPlatform.instance.isSupported();
  }

  /// 查询引擎信息（引擎名、版本、当前语言、支持语言列表）。
  static Future<OcrEngineInfo> engineInfo() {
    return DesktopVisionPlatform.instance.getEngineInfo();
  }

  /// 识别本地图片文件。
  ///
  /// [path] 图片绝对路径，支持 png / jpg / bmp / heic 等系统可解码格式。
  /// [languages] 期望语言标签（BCP-47，例如 `['zh-Hans', 'en-US']`），
  ///   为空表示使用引擎默认语言。
  static Future<OcrResult> recognizeFile(
    String path, {
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) {
    return DesktopVisionPlatform.instance.recognizeFile(
      path: path,
      languages: languages,
      level: level,
    );
  }

  /// 识别内存中的图片字节（截图、剪贴板、相机帧等场景）。
  static Future<OcrResult> recognizeBytes(
    Uint8List bytes, {
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) {
    return DesktopVisionPlatform.instance.recognizeBytes(
      bytes: bytes,
      languages: languages,
      level: level,
    );
  }

  /// 把归一化坐标换算成"图片按 [displaySize] 展示在屏幕上"时的绘制坐标，
  /// 便于直接用 `CustomPaint` 画框。
  static Rect toPaintRect(Rect normalizedBox, Size displaySize) {
    return Rect.fromLTWH(
      normalizedBox.left * displaySize.width,
      normalizedBox.top * displaySize.height,
      normalizedBox.width * displaySize.width,
      normalizedBox.height * displaySize.height,
    );
  }

  static Future<String?> getPlatformVersion() {
    return DesktopVisionPlatform.instance.getPlatformVersion();
  }
}
