import 'dart:ui' show Rect;

/// 识别精度等级。
///
/// - [fast]：牺牲部分精度换取速度（macOS：Vision `.fast`；Windows：WinRT 无该
///   概念，忽略此参数）。
/// - [accurate]：默认，精度优先（macOS：Vision `.accurate`）。
enum OcrLevel {
  fast,
  accurate;

  String get nativeValue => this == OcrLevel.fast ? 'fast' : 'accurate';
}

/// OCR 引擎信息，用于自检与能力探测。
class OcrEngineInfo {
  const OcrEngineInfo({
    required this.engine,
    required this.version,
    required this.isAvailable,
    this.languageTag,
    this.supportedLanguages = const <String>[],
  });

  /// 引擎名称，例如 `apple.vision.text` / `windows.media.ocr`。
  final String engine;

  /// 引擎/系统版本描述。
  final String version;

  /// 当前设备是否有可用的 OCR 能力（Windows 需要已安装对应语言的 OCR 语言包）。
  final bool isAvailable;

  /// 当前默认识别语言标签（BCP-47），例如 `zh-Hans`、`en-US`。
  final String? languageTag;

  /// 引擎支持的识别语言标签列表。
  final List<String> supportedLanguages;

  factory OcrEngineInfo.fromMap(Map<dynamic, dynamic> map) {
    return OcrEngineInfo(
      engine: (map['engine'] as String?) ?? 'unknown',
      version: (map['version'] as String?) ?? '',
      isAvailable: (map['isAvailable'] as bool?) ?? false,
      languageTag: map['languageTag'] as String?,
      supportedLanguages:
          (map['supportedLanguages'] as List<dynamic>?)
              ?.map((dynamic e) => e as String)
              .toList(growable: false) ??
          const <String>[],
    );
  }

  @override
  String toString() =>
      'OcrEngineInfo(engine: $engine, available: $isAvailable, '
      'language: $languageTag, supported: ${supportedLanguages.length})';
}

/// 词级识别结果。
class OcrWord {
  const OcrWord({
    required this.text,
    required this.normalizedBox,
    required this.pixelBox,
    this.confidence = -1,
  });

  final String text;

  /// 归一化坐标：左上角为原点，取值 0~1，相对整图宽高。
  final Rect normalizedBox;

  /// 像素坐标：左上角为原点，基于 [OcrResult.imageWidth] / [OcrResult.imageHeight]。
  final Rect pixelBox;

  /// 置信度 0~1；引擎不提供时为 -1（Windows WinRT OCR 即如此）。
  final double confidence;
}

/// 行级识别结果。
class OcrLine {
  const OcrLine({
    required this.text,
    required this.normalizedBox,
    required this.pixelBox,
    this.confidence = -1,
    this.words = const <OcrWord>[],
    this.characters = const <OcrWord>[],
  });

  final String text;

  /// 归一化坐标：左上角为原点，取值 0~1。
  final Rect normalizedBox;

  /// 像素坐标：左上角为原点。
  final Rect pixelBox;

  /// 行置信度，取该行词级置信度的平均值；引擎不提供时为 -1。
  final double confidence;

  final List<OcrWord> words;
  final List<OcrWord> characters;
}

/// 一次 OCR 的完整结果。
class OcrResult {
  const OcrResult({
    required this.text,
    required this.lines,
    required this.imageWidth,
    required this.imageHeight,
    required this.engine,
    this.elapsedMs = 0,
  });

  /// 全文（按原生引擎给出的行序拼接，行间以 `\n` 分隔）。
  final String text;

  final List<OcrLine> lines;

  final int imageWidth;
  final int imageHeight;

  /// 产出该结果的引擎名称。
  final String engine;

  /// 原生侧耗时（毫秒），不含 Dart 侧图片读取。
  final int elapsedMs;

  bool get isEmpty => lines.isEmpty;

  factory OcrResult.fromMap(Map<dynamic, dynamic> map) {
    final imageWidth = (map['imageWidth'] as num?)?.toInt() ?? 0;
    final imageHeight = (map['imageHeight'] as num?)?.toInt() ?? 0;

    Rect buildRect(Map<dynamic, dynamic> box) {
      final double x = (box['x'] as num?)?.toDouble() ?? 0;
      final double y = (box['y'] as num?)?.toDouble() ?? 0;
      final double w = (box['w'] as num?)?.toDouble() ?? 0;
      final double h = (box['h'] as num?)?.toDouble() ?? 0;
      return Rect.fromLTWH(x, y, w, h);
    }

    Rect toPixels(Rect normalized) => Rect.fromLTWH(
      normalized.left * imageWidth,
      normalized.top * imageHeight,
      normalized.width * imageWidth,
      normalized.height * imageHeight,
    );

    final List<OcrLine> lines = <OcrLine>[];
    final List<dynamic>? rawLines = map['lines'] as List<dynamic>?;
    for (final dynamic rawLine in rawLines ?? const <dynamic>[]) {
      final Map<dynamic, dynamic> lineMap = rawLine as Map<dynamic, dynamic>;
      final List<OcrWord> words = <OcrWord>[];
      final List<dynamic>? rawWords = lineMap['words'] as List<dynamic>?;
      for (final dynamic rawWord in rawWords ?? const <dynamic>[]) {
        final Map<dynamic, dynamic> wordMap = rawWord as Map<dynamic, dynamic>;
        final Rect normalized = buildRect(wordMap);
        words.add(
          OcrWord(
            text: (wordMap['text'] as String?) ?? '',
            normalizedBox: normalized,
            pixelBox: toPixels(normalized),
            confidence: (wordMap['confidence'] as num?)?.toDouble() ?? -1,
          ),
        );
      }
      final Rect normalized = buildRect(lineMap);
      lines.add(
        OcrLine(
          text: (lineMap['text'] as String?) ?? '',
          normalizedBox: normalized,
          pixelBox: toPixels(normalized),
          confidence: (lineMap['confidence'] as num?)?.toDouble() ?? -1,
          words: words,
          characters: [
            for (final raw
                in lineMap['characters'] as List<dynamic>? ?? const [])
              OcrWord(
                text: raw['text'] as String? ?? '',
                normalizedBox: buildRect(raw as Map<dynamic, dynamic>),
                pixelBox: toPixels(buildRect(raw)),
              ),
          ],
        ),
      );
    }

    return OcrResult(
      text:
          (map['text'] as String?) ??
          lines.map((OcrLine l) => l.text).join('\n'),
      lines: lines,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      engine: (map['engine'] as String?) ?? 'unknown',
      elapsedMs: (map['elapsedMs'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'OcrResult(lines: ${lines.length}, ${imageWidth}x$imageHeight, '
      'engine: $engine, ${elapsedMs}ms)';
}
