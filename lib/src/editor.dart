import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'ui/controls.dart';
import 'ui/toolbar_layout.dart';
import 'ocr_selection.dart';
import 'ui/ocr_overlay.dart';
import 'ui/ocr_status.dart';
import 'qr_scan.dart';
import 'ui/qr_overlay.dart';
import 'color_picker.dart';
import 'ui/color_preview.dart';
import '../translation/ui/translation_panel.dart';
import '../translation/models.dart';
import '../translation/ui/reading_panel.dart';
import 'ui/capture_mirrors.dart'
    show markCaptureMirrorsReady, scheduleCaptureFrame;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'controller.dart' hide Clip;
import 'controller.dart' as model show Clip;

enum MarkTool {
  select,
  pen,
  arrow,
  line,
  rectangle,
  circle,
  ellipse,
  text,
  number,
  redact,
  mosaic,
  crop,
}

enum PrivacyInteraction { brush, rectangle }

/// Diameter in source pixels, shared by stroke rendering and cursor feedback.
double brushDiameter(MarkTool tool, double width) => switch (tool) {
  MarkTool.line ||
  MarkTool.arrow ||
  MarkTool.rectangle ||
  MarkTool.circle ||
  MarkTool.ellipse => width * 1.6,
  MarkTool.redact || MarkTool.mosaic => width * 9,
  MarkTool.number => width * 4 + 24,
  _ => width,
};
bool hasBrushCursor(MarkTool tool) => const [
  MarkTool.pen,
  MarkTool.arrow,
  MarkTool.line,
  MarkTool.rectangle,
  MarkTool.circle,
  MarkTool.ellipse,
  MarkTool.redact,
  MarkTool.mosaic,
  MarkTool.number,
].contains(tool);

bool isPrivacyBrush(MarkTool tool) =>
    tool == MarkTool.redact || tool == MarkTool.mosaic;

/// A cached, screen-aligned low-resolution image; nearest-neighbor upscaling
/// makes square mosaic blocks without recomputing them on every pointer move.
Future<ui.Image> makeMosaicImage(ui.Image image) async {
  final width = (image.width / 14).ceil(), height = (image.height / 14).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.low,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

class Mark {
  Mark(
    this.tool,
    this.color,
    this.width,
    this.points, {
    this.text = '',
    this.number = 1,
    this.fontSize = 32,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.maxTextWidth = double.infinity,
    this.minTextWidth = 0,
    this.background = Colors.transparent,
    this.translationId,
    this.padding = 10,
    this.textFrame,
    this.rotation = 0,
    this.textAlign = TextAlign.left,
    this.privacyInteraction = PrivacyInteraction.brush,
  });
  final PrivacyInteraction privacyInteraction;
  final MarkTool tool;
  final Color color;
  final double width;
  final List<Offset> points;
  final String text;
  final int number;
  final double fontSize, maxTextWidth, minTextWidth;
  final bool bold, italic, underline;
  final Color background;
  final int? translationId;
  final double padding;
  final Size? textFrame;
  final double rotation;
  final TextAlign textAlign;
  Size get textBoxSize =>
      textFrame ??
      Size(textPainter.width + padding * 2, textPainter.height + padding * 2);
  Mark copyText({
    Offset? position,
    Size? frame,
    double? angle,
    double? size,
    double? inset,
    TextAlign? alignment,
    Color? background,
  }) => Mark(
    tool,
    color,
    width,
    [position ?? points.first],
    text: text,
    fontSize: size ?? fontSize,
    bold: bold,
    italic: italic,
    underline: underline,
    maxTextWidth: maxTextWidth,
    minTextWidth: minTextWidth,
    background: background ?? this.background,
    translationId: translationId,
    padding: inset ?? padding,
    textFrame: frame ?? textFrame,
    rotation: angle ?? rotation,
    textAlign: alignment ?? textAlign,
  );
  TextStyle get textStyle => TextStyle(
    color: color,
    fontSize: fontSize,
    height: 1.3,
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    decoration: underline ? TextDecoration.underline : TextDecoration.none,
    decorationColor: color,
    fontFamily: 'Microsoft YaHei',
    fontFamilyFallback: const ['PingFang SC'],
  );
  TextPainter get textPainter =>
      TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: TextDirection.ltr,
        textAlign: textAlign,
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout(
        minWidth: textFrame == null
            ? math.min(minTextWidth, maxTextWidth)
            : math.max(1, textFrame!.width - padding * 2),
        maxWidth: textFrame == null
            ? maxTextWidth
            : math.max(1, textFrame!.width - padding * 2),
      );
}

/// Translation is a normal editable annotation, so exports and undo share
/// exactly the same layout and background as the screenshot preview.
Mark imageTranslationMark(String text, Rect target, {int? translationId}) {
  final padding = math.min(3.0, math.min(target.width, target.height) / 8);
  double low = .1, high = math.max(1, target.height / 1.3);
  for (var i = 0; i < 18; i++) {
    final size = (low + high) / 2;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          height: 1.3,
          fontFamily: 'Microsoft YaHei',
          fontFamilyFallback: const ['PingFang SC'],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, target.width - padding * 2));
    final fits = painter.height <= target.height - padding * 2;
    painter.dispose();
    if (fits) {
      low = size;
    } else {
      high = size;
    }
  }
  return Mark(
    MarkTool.text,
    const Color(0xff302719),
    1,
    [target.topLeft],
    text: text,
    fontSize: low,
    padding: padding,
    textFrame: target.size,
    background: const Color(0xffffedc7),
    translationId: translationId,
  );
}

Offset rotateTextVector(Offset point, double angle) => Offset(
  point.dx * math.cos(angle) - point.dy * math.sin(angle),
  point.dx * math.sin(angle) + point.dy * math.cos(angle),
);
Offset textToWorld(Mark mark, Offset local) {
  final half = Offset(mark.textBoxSize.width / 2, mark.textBoxSize.height / 2);
  return mark.points.first +
      half +
      rotateTextVector(local - half, mark.rotation);
}

Offset textToLocal(Mark mark, Offset world) {
  final half = Offset(mark.textBoxSize.width / 2, mark.textBoxSize.height / 2);
  return half +
      rotateTextVector(world - mark.points.first - half, -mark.rotation);
}

List<Offset> textHandles(Mark mark) {
  final rect = Offset.zero & mark.textBoxSize;
  return [
    rect.topLeft,
    rect.topCenter,
    rect.topRight,
    rect.centerRight,
    rect.bottomRight,
    rect.bottomCenter,
    rect.bottomLeft,
    rect.centerLeft,
  ];
}

Mark resizeTextMark(
  Mark mark,
  int handle,
  Offset point, {
  required bool proportional,
}) {
  final size = mark.textBoxSize;
  final handles = textHandles(mark);
  final anchor = handles[(handle + 4) % 8];
  final fixed = textToWorld(mark, anchor);
  final delta = rotateTextVector(point - fixed, -mark.rotation);
  final original = handles[handle] - anchor;
  double width = size.width, height = size.height, factor = 1;
  if (proportional && handle.isEven) {
    factor =
        ((delta.dx * original.dx + delta.dy * original.dy) /
                original.distanceSquared)
            .clamp(.1, 20.0);
    width *= factor;
    height *= factor;
  } else {
    final minimum = math.max(24.0, mark.padding * 2 + 1);
    if (original.dx != 0) {
      width = math.max(minimum, delta.dx * original.dx.sign);
    }
    if (original.dy != 0) {
      height = math.max(minimum, delta.dy * original.dy.sign);
    }
  }
  final half = Offset(width / 2, height / 2);
  final newAnchor = Offset(
    anchor.dx / size.width * width,
    anchor.dy / size.height * height,
  );
  final center = fixed - rotateTextVector(newAnchor - half, mark.rotation);
  return mark.copyText(
    position: center - half,
    frame: Size(width, height),
    size: mark.fontSize * factor,
    inset: mark.padding * factor,
  );
}

bool isShapeTool(MarkTool tool) => const [
  MarkTool.rectangle,
  MarkTool.circle,
  MarkTool.ellipse,
].contains(tool);

Rect annotationBounds(Mark mark) {
  final first = mark.points.first, last = mark.points.last;
  if (mark.tool != MarkTool.circle) return Rect.fromPoints(first, last);
  final delta = last - first;
  final side = math.min(delta.dx.abs(), delta.dy.abs());
  return Rect.fromPoints(
    first,
    first + Offset(side * delta.dx.sign, side * delta.dy.sign),
  );
}

Rect shapeActionBounds(Mark mark) {
  var rect = annotationBounds(mark);
  if (mark.tool == MarkTool.arrow && mark.points.length > 1) {
    final delta = mark.points.last - mark.points.first;
    final length = math.max(14.0, mark.width * 4);
    final heads = [
      for (final offset in [-.5, .5])
        mark.points.last -
            Offset(
                  math.cos(delta.direction + offset),
                  math.sin(delta.direction + offset),
                ) *
                length,
    ];
    rect = rect.expandToInclude(Rect.fromPoints(heads.first, heads.last));
  }
  return rect.inflate(brushDiameter(mark.tool, mark.width) / 2);
}

/// All positions are stored in source-image pixels, independent of UI scaling.
void drawMark(Canvas canvas, Mark mark) {
  if (mark.points.isEmpty) return;
  final first = mark.points.first, last = mark.points.last;
  final paint = Paint()
    ..color = mark.color
    ..strokeWidth = brushDiameter(mark.tool, mark.width)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final rect = annotationBounds(mark);
  switch (mark.tool) {
    case MarkTool.pen:
      if (mark.points.length == 1) {
        canvas.drawCircle(
          first,
          mark.width / 2,
          paint..style = PaintingStyle.fill,
        );
        break;
      }
      final path = Path()..moveTo(first.dx, first.dy);
      for (final p in mark.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    case MarkTool.line:
      if ((last - first).distance >= 1) canvas.drawLine(first, last, paint);
    case MarkTool.arrow:
      if ((last - first).distance < 1) break;
      canvas.drawLine(first, last, paint);
      final angle = math.atan2(last.dy - first.dy, last.dx - first.dx),
          length = math.max(14.0, mark.width * 4);
      canvas.drawLine(
        last,
        last -
            Offset(
              math.cos(angle - .5) * length,
              math.sin(angle - .5) * length,
            ),
        paint,
      );
      canvas.drawLine(
        last,
        last -
            Offset(
              math.cos(angle + .5) * length,
              math.sin(angle + .5) * length,
            ),
        paint,
      );
    case MarkTool.rectangle:
      canvas.drawRect(rect, paint);
    case MarkTool.circle:
    case MarkTool.ellipse:
      canvas.drawOval(rect, paint);
    case MarkTool.redact:
    case MarkTool.mosaic:
      break; // Blur is composited beneath every annotation by paintCapture.
    case MarkTool.text:
      final size = mark.textBoxSize;
      canvas.save();
      canvas.translate(first.dx + size.width / 2, first.dy + size.height / 2);
      canvas.rotate(mark.rotation);
      canvas.translate(-size.width / 2, -size.height / 2);
      canvas.clipRect(Offset.zero & size);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
        Paint()..color = mark.background,
      );
      mark.textPainter.paint(canvas, Offset(mark.padding, mark.padding));
      canvas.restore();
    case MarkTool.number:
      final radius = mark.width * 2 + 12;
      canvas.drawCircle(first, radius, Paint()..color = mark.color);
      final tp = TextPainter(
        text: TextSpan(
          text: '${mark.number}',
          style: TextStyle(
            color: mark.color.computeLuminance() > .5
                ? const Color(0xff171b24)
                : Colors.white,
            fontSize: radius * 1.2,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, first - Offset(tp.width / 2, tp.height / 2));
    case MarkTool.select:
    case MarkTool.crop:
      break;
  }
}

/// A brush or rectangular privacy mask; later privacy modes replace earlier overlap.
void paintPrivacyMaskStroke(Canvas canvas, Mark mark, {bool clear = false}) {
  final brush = Paint()
    ..color = Colors.white
    ..blendMode = clear ? BlendMode.clear : BlendMode.srcOver
    ..strokeWidth = brushDiameter(mark.tool, mark.width)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  if (mark.privacyInteraction == PrivacyInteraction.rectangle) {
    if (mark.points.length > 1) {
      canvas.drawRect(
        Rect.fromPoints(mark.points.first, mark.points.last),
        brush..style = PaintingStyle.fill,
      );
    }
    return;
  }
  if (mark.points.length == 1) {
    canvas.drawCircle(
      mark.points.first,
      brushDiameter(mark.tool, mark.width) / 2,
      brush..style = PaintingStyle.fill,
    );
  } else if (mark.points.isNotEmpty) {
    final path = Path()..moveTo(mark.points.first.dx, mark.points.first.dy);
    for (final p in mark.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, brush);
  }
}

/// Fixed visual layers: source, privacy effects, pen, then other annotations.
void paintCapture(
  Canvas canvas,
  ui.Image image,
  List<Mark> marks, {
  ui.Image? mosaic,
}) {
  final bounds = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  canvas.drawImage(image, Offset.zero, Paint());
  for (final effect in [MarkTool.redact, MarkTool.mosaic]) {
    if (!marks.any((m) => m.tool == effect)) continue;
    canvas.saveLayer(bounds, Paint());
    if (effect == MarkTool.mosaic) {
      final pixels = mosaic ?? image;
      canvas.drawImageRect(
        pixels,
        Rect.fromLTWH(0, 0, pixels.width.toDouble(), pixels.height.toDouble()),
        bounds,
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      canvas.drawImage(
        image,
        Offset.zero,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: 14,
            sigmaY: 14,
            tileMode: TileMode.clamp,
          ),
      );
    }
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
    for (final mark in marks) {
      if (isPrivacyBrush(mark.tool)) {
        paintPrivacyMaskStroke(canvas, mark, clear: mark.tool != effect);
      }
    }
    canvas.restore();
    canvas.restore();
  }
  for (final penLayer in [true, false]) {
    canvas.saveLayer(bounds, Paint());
    for (final mark in marks) {
      if (!isPrivacyBrush(mark.tool) &&
          (mark.tool == MarkTool.pen) == penLayer) {
        drawMark(canvas, mark);
      }
    }
    canvas.restore();
  }
}

/// Original-resolution PNG export using the same layer compositing as preview.
Future<Uint8List> renderCapture(
  ui.Image image,
  List<Mark> marks,
  Rect? crop, {
  ui.Image? mosaic,
}) async {
  final bounds = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  final area = (crop ?? bounds).intersect(bounds);
  if (area.width < 1 || area.height < 1) throw StateError('裁剪区域过小');
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.translate(-area.left, -area.top);
  canvas.clipRect(area);
  final ownMosaic =
      mosaic == null && marks.any((m) => m.tool == MarkTool.mosaic)
      ? await makeMosaicImage(image)
      : null;
  paintCapture(canvas, image, marks, mosaic: mosaic ?? ownMosaic);
  final picture = recorder.endRecording();
  final output = await picture.toImage(area.width.ceil(), area.height.ceil());
  picture.dispose();
  try {
    return (await output.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
  } finally {
    output.dispose();
    ownMosaic?.dispose();
  }
}

class CaptureEditor extends StatefulWidget {
  const CaptureEditor({
    super.key,
    required this.clip,
    required this.controller,
  });
  final model.Clip clip;
  final ClipController controller;
  @override
  State<CaptureEditor> createState() => _CaptureEditorState();
}

class _CaptureEditorState extends State<CaptureEditor> {
  bool translationOpen = false;
  void closeTranslation() {
    widget.controller.translation.cancel();
    setState(() => translationOpen = false);
    focus.requestFocus();
    final channel = widget.controller.translation.activeChannel;
    if (channel?.configured == true && channel?.isEnabled == true) {
      unawaited(openTranslation());
    }
  }

  bool translationReading = false;
  Rect? translationReadingPosition;
  int nextTranslationId = 0;
  int? activeTranslationId;
  List<TranslationPassage> translationPassages = [];
  List<TranslationPassage> get readingPassages {
    final translated = {
      for (final m in marks)
        if (m.translationId != null) m.translationId!: m,
    };
    return [
      for (final p in translationPassages)
        if (translated[p.id] case final Mark mark)
          TranslationPassage(
            id: p.id,
            source: p.source,
            translation: mark.text,
            box: p.box,
          ),
    ];
  }

  bool get readingActive => translationReading && readingPassages.isNotEmpty;
  List<Mark> get visibleMarks {
    if (!readingActive) return marks;
    final ids = translationPassages.map((p) => p.id).toSet();
    return marks.where((m) => !ids.contains(m.translationId)).toList();
  }

  void selectTranslationPassage(int id) {
    if (activeTranslationId == id) return;
    setState(() => activeTranslationId = id);
    scheduleCaptureFrame();
  }

  void toggleTranslationReading() {
    commitText();
    setState(() {
      translationReading = !translationReading;
      selectedTextIndex = null;
      activeTranslationId ??= readingPassages.firstOrNull?.id;
    });
    scheduleCaptureFrame();
    focus.requestFocus();
  }

  bool translatingImage = false;
  int imageTranslationRequest = 0;
  String? imageTranslationStatus, imageTranslationFailure;

  void cancelImageTranslation() {
    imageTranslationRequest++;
    widget.controller.translation.cancel();
    translatingImage = false;
    imageTranslationStatus = null;
    imageTranslationFailure = null;
  }

  Future<void> openTranslation() async {
    if (locked || image == null || region == null) return;
    final c = widget.controller.translation;
    final request = ++imageTranslationRequest;
    commitText();
    dismissTextPrompt();
    setState(() {
      translatingImage = true;
      translationReading = false;
      imageTranslationFailure = null;
      imageTranslationStatus = '正在准备翻译';
    });
    scheduleCaptureFrame();
    await c.initialize();
    if (!mounted || request != imageTranslationRequest) return;
    if (!c.initialized ||
        c.activeChannel?.configured != true ||
        c.activeChannel?.isEnabled != true) {
      setState(() {
        translatingImage = false;
        imageTranslationStatus = null;
        translationOpen = true;
      });
      scheduleCaptureFrame();
      return;
    }
    OcrSelection? temporary;
    try {
      setState(() => imageTranslationStatus = '正在识别选区文字');
      scheduleCaptureFrame();
      var selection = ocrSelection;
      if (selection == null) {
        final bytes = await renderCapture(
          image!,
          marks.where((m) => m.translationId == null).toList(),
          region,
          mosaic: mosaic,
        );
        if (!mounted || request != imageTranslationRequest) return;
        final recognized = await widget.controller.bridge.recognizeText(bytes);
        if (!mounted || request != imageTranslationRequest) return;
        selection = temporary = OcrSelection(recognized);
      }
      final groups = <int, List<OcrGlyph>>{};
      for (final glyph in selection.glyphs) {
        if (!selection.selection.isCollapsed &&
            (glyph.end <= selection.selection.start ||
                glyph.start >= selection.selection.end)) {
          continue;
        }
        groups.putIfAbsent(glyph.line, () => []).add(glyph);
      }
      if (groups.isEmpty) throw const FormatException('选区中没有识别到文字');
      final texts = <String>[];
      final boxes = <Rect>[];
      for (final glyphs in groups.values) {
        texts.add(
          selection.text.substring(glyphs.first.start, glyphs.last.end),
        );
        boxes.add(
          glyphs.map((g) => g.box).reduce((a, b) => a.expandToInclude(b)),
        );
      }
      c.setSource(texts.join('\n'), label: '截图选区');
      setState(() => imageTranslationStatus = '正在翻译 ${texts.length} 处文字');
      scheduleCaptureFrame();
      await c.translate(segments: texts);
      if (!mounted || request != imageTranslationRequest) return;
      if (c.result == null) throw FormatException(c.error ?? '翻译已取消');
      final decoded = jsonDecode(c.result!.translatedText);
      if (decoded is! List ||
          decoded.length != texts.length ||
          decoded.any((v) => v is! String || v.trim().isEmpty)) {
        throw const FormatException('服务商返回的译文区域不匹配，请重试或切换模型');
      }
      final result = c.result!;
      c.result = TranslationResult(
        originalText: result.originalText,
        translatedText: decoded.join('\n'),
        channelName: result.channelName,
        from: result.from,
        to: result.to,
        tokensUsed: result.tokensUsed,
        duration: result.duration,
      );
      final before = List<Mark>.of(marks);
      final selectedBefore = selectedTextIndex;
      final translated = <Mark>[];
      final passages = <TranslationPassage>[];
      for (var i = 0; i < boxes.length; i++) {
        final box = boxes[i];
        final target = Rect.fromLTWH(
          region!.left + box.left * region!.width,
          region!.top + box.top * region!.height,
          box.width * region!.width,
          box.height * region!.height,
        ).intersect(region!);
        if (target.isEmpty) continue;
        final id = nextTranslationId++;
        passages.add(
          TranslationPassage(
            id: id,
            source: texts[i],
            translation: decoded[i] as String,
            box: target,
          ),
        );
        translated.add(
          imageTranslationMark(decoded[i] as String, target, translationId: id),
        );
      }
      setState(() {
        clearOcr(cancelTranslation: false);
        commit();
        marks.removeWhere(
          (m) => translationPassages.any((p) => p.id == m.translationId),
        );
        marks.addAll(translated);
        translationPassages = passages;
        final viewport = viewportKey.currentContext?.findRenderObject();
        final sx = viewport is RenderBox && viewport.hasSize
            ? viewport.size.width / widget.clip.width
            : 1.0;
        final sy = viewport is RenderBox && viewport.hasSize
            ? viewport.size.height / widget.clip.height
            : 1.0;
        translationReading = prefersTranslationReading(
          Size(region!.width * sx, region!.height * sy),
          textSizes: translated.map((m) => m.fontSize * sy),
        );
        translationReadingPosition = null;
        activeTranslationId = passages.firstOrNull?.id;
        selectedTextIndex = null;
        markListUndo.add((
          before: before,
          after: List<Mark>.of(marks),
          selectedBefore: selectedBefore,
          selectedAfter: null,
        ));
        operations.add(3);
        tool = MarkTool.select;
        imageTranslationStatus = '已翻译 ${translated.length} 处 · 可拖动编辑，支持撤销';
      });
    } catch (e) {
      if (mounted && request == imageTranslationRequest) {
        setState(() {
          imageTranslationStatus = null;
          imageTranslationFailure = e is FormatException
              ? e.message
              : '翻译失败，请检查网络或渠道配置后重试';
        });
      }
    } finally {
      temporary?.dispose();
      if (mounted && request == imageTranslationRequest) {
        setState(() => translatingImage = false);
        focus.requestFocus();
        scheduleCaptureFrame();
      }
    }
  }

  ui.Image? image;
  ui.Image? mosaic;
  MarkTool privacyTool = MarkTool.redact;
  PrivacyInteraction privacyInteraction = PrivacyInteraction.brush;
  String? loadError;
  MarkTool tool = MarkTool.select;

  Color color = const Color(0xffd92d3e);
  double stroke = 3;
  Rect? region, hovered;
  final List<Mark> marks = [], redo = [];
  final List<Rect?> selectionUndo = [], selectionRedo = [];
  final List<int> operations = [], redoOperations = [];
  final List<({int index, Mark before, Mark after})> textUndo = [],
      textRedo = [];
  final List<
    ({
      List<Mark> before,
      List<Mark> after,
      int? selectedBefore,
      int? selectedAfter,
    })
  > markListUndo = [],
      markListRedo = [];
  final textInput = TextEditingController();
  final textFocus = FocusNode();
  Offset? textAnchor;
  int? editingTextIndex;
  int? selectedTextIndex, transformingTextIndex;
  Mark? textBeforeTransform;
  Offset? textDragStart;
  int textDragHandle = -1;
  String textDragKind = 'move';
  double fontSize = 32;
  TextAlign textAlign = TextAlign.left;
  Color textBackground = Colors.transparent;
  String? colorPanel;
  bool bold = false, italic = false, underline = false;

  Mark? active;
  bool draggingLine = false;
  Mark? textPromptShape;
  bool textPromptVisible = false,
      textPromptHovered = false,
      textPromptFocused = false;
  Timer? textPromptTimer;
  final toolbarKey = GlobalKey(), viewportKey = GlobalKey();
  ToolbarSide? toolbarSide;
  Offset? toolbarManualAnchor;

  void startToolbarDrag() {
    final box = toolbarKey.currentContext?.findRenderObject();
    final viewport = viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return;
    final p = box.localToGlobal(Offset.zero, ancestor: viewport);
    toolbarManualAnchor = toolbarSide == ToolbarSide.above
        ? p + Offset(0, box.size.height)
        : p;
  }

  void moveToolbar(Offset delta) {
    if (toolbarManualAnchor == null) return;
    final box = toolbarKey.currentContext?.findRenderObject();
    final screen = toolbarAnchorScreen;
    if (box is! RenderBox || screen == null) return;
    final safe = screen.deflate(12);
    final next = toolbarManualAnchor! + delta;
    final y = toolbarSide == ToolbarSide.above
        ? next.dy - box.size.height
        : next.dy;
    final top = y.clamp(
      safe.top,
      math.max(safe.top, safe.bottom - box.size.height),
    );
    setState(
      () => toolbarManualAnchor = Offset(
        next.dx.clamp(
          safe.left,
          math.max(safe.left, safe.right - box.size.width),
        ),
        (toolbarSide == ToolbarSide.above ? top + box.size.height : top)
            .toDouble(),
      ),
    );
    scheduleCaptureFrame();
  }

  Rect? toolbarAnchorSelection, toolbarAnchorScreen;
  Rect? measuredToolbar;
  bool measuringToolbar = false;
  Offset? dragStart;
  Offset? cursor;
  Future<void> cursorNudges = Future.value();
  Rect? dragRegion;
  String dragKind = 'new';
  int handle = -1;
  bool rendering = false;
  bool recognizingText = false;
  OcrSelection? ocrSelection;
  String? ocrFailure;
  int ocrRequest = 0;
  bool scanningQr = false;
  List<QrCode>? qrCodes;
  String? qrFailure;
  int qrRequest = 0;
  int? openingQr;
  ScreenColorPicker? colorPicker;
  bool preparingColor = false;
  int colorRequest = 0;
  bool preparingSmartSelection = false, focusedCaptureWindow = false;
  int imageLoadEpoch = 0;
  final focus = FocusNode();
  Rect get bounds => Rect.fromLTWH(
    0,
    0,
    widget.clip.width.toDouble(),
    widget.clip.height.toDouble(),
  );
  bool get locked =>
      translationOpen ||
      translatingImage ||
      rendering ||
      recognizingText ||
      scanningQr ||
      preparingColor ||
      openingQr != null ||
      preparingSmartSelection ||
      widget.controller.busy;
  @override
  void initState() {
    super.initState();
    if (widget.clip.mode == 'screen') region = bounds;
    load();
  }

  Future<void> load([Uint8List? bytes]) async {
    final epoch = ++imageLoadEpoch;
    try {
      final ui.Image decoded;
      if (bytes == null && widget.clip.rgbaPixels != null) {
        decoded = await ColorPixels(
          widget.clip.rgbaPixels!,
          widget.clip.width,
          widget.clip.height,
        ).toImage();
      } else {
        final codec = await ui.instantiateImageCodec(
          bytes ?? widget.clip.bytes,
        );
        decoded = (await codec.getNextFrame()).image;
        codec.dispose();
      }
      final pixels = widget.clip.mode == 'color'
          ? null
          : await makeMosaicImage(decoded);
      if (!mounted || epoch != imageLoadEpoch) {
        pixels?.dispose();
        decoded.dispose();
        return;
      }
      setState(() {
        loadError = null;
        image?.dispose();
        mosaic?.dispose();
        image = decoded;
        mosaic = pixels;
      });
      notifyCaptureFrameReady(epoch);
      if (widget.clip.mode == 'color') startColorPicker(automatic: true);
    } catch (e) {
      if (mounted && epoch == imageLoadEpoch) {
        setState(() => loadError = '屏幕载入失败：$e');
        notifyCaptureFrameReady(epoch);
      }
    }
  }

  void notifyCaptureFrameReady(int epoch) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || epoch != imageLoadEpoch) return;
      try {
        final accepted = await widget.controller.bridge.captureFrameReady(
          context.size ?? Size.zero,
        );
        // A frame painted before the native resize still has the old viewport.
        // Keep the snapshot cover until the desktop-sized frame has been built.
        if (!accepted && mounted && epoch == imageLoadEpoch) {
          notifyCaptureFrameReady(epoch);
        } else if (accepted && mounted && epoch == imageLoadEpoch) {
          markCaptureMirrorsReady();
        }
      } catch (_) {}
    });
    WidgetsBinding.instance.scheduleWarmUpFrame();
  }

  @override
  void dispose() {
    textPromptVisible = false;
    textPromptTimer?.cancel();
    image?.dispose();
    mosaic?.dispose();
    focus.dispose();
    textInput.dispose();
    textFocus.dispose();
    clearOcr();
    super.dispose();
  }

  void commit() {
    redo.clear();
    selectionRedo.clear();
    redoOperations.clear();
    textRedo.clear();
    markListRedo.clear();
  }

  void clearQr() {
    qrRequest++;
    qrCodes = null;
    qrFailure = null;
    scanningQr = false;
    openingQr = null;
  }

  void exitQr() => setState(clearQr);

  void clearColorPicker() {
    colorRequest++;
    colorPicker?.dispose();
    colorPicker = null;
    preparingColor = false;
  }

  void closeColorPicker() {
    if (widget.clip.mode == 'color') {
      widget.controller.discard();
    } else {
      setState(clearColorPicker);
    }
  }

  Future<void> startColorPicker({bool automatic = false}) async {
    if (image == null || (locked && !automatic)) return;
    if (colorPicker != null) {
      closeColorPicker();
      return;
    }
    dismissTextPrompt();
    commitText();
    setState(() {
      clearOcr();
      preparingColor = true;
    });
    final request = ++colorRequest;
    try {
      final pixels = marks.isEmpty
          ? widget.clip.rgbaPixels != null
                ? ColorPixels(
                    widget.clip.rgbaPixels!,
                    widget.clip.width,
                    widget.clip.height,
                  )
                : await ColorPixels.fromImage(image!)
          : await ColorPixels.fromPng(
              await renderCapture(image!, visibleMarks, bounds, mosaic: mosaic),
            );
      if (!mounted || request != colorRequest) return;
      final picker = ScreenColorPicker(pixels)..move(cursor ?? bounds.center);
      try {
        picker.move(await widget.controller.bridge.nudgeCursor(0, 0));
      } catch (_) {}
      if (!mounted || request != colorRequest) {
        picker.dispose();
        return;
      }
      setState(() {
        colorPicker = picker;
        preparingColor = false;
      });
      focus.requestFocus();
    } catch (_) {
      if (mounted && request == colorRequest) {
        setState(() => loadError = '取色准备失败，请重试');
      }
    } finally {
      if (mounted && request == colorRequest) {
        setState(() => preparingColor = false);
        scheduleCaptureFrame();
      }
    }
  }

  void clearOcr({bool cancelTranslation = true}) {
    if (cancelTranslation) {
      cancelImageTranslation();
      translationReading = false;
    }
    clearColorPicker();
    clearQr();
    ocrFailure = null;
    ocrSelection?.removeListener(ocrChanged);
    ocrSelection?.dispose();
    ocrSelection = null;
  }

  void ocrChanged() {
    if (mounted) setState(() {});
  }

  void exitOcr() => setState(clearOcr);
  void copyOrFinish() {
    if (ocrSelection != null) {
      ocrSelection!.copy();
    } else {
      finish(false);
    }
  }

  void selectAllTextOrRegion() {
    if (locked) return;
    if (ocrSelection != null) {
      ocrSelection!.selectAll();
    } else {
      setState(() => changeRegion(bounds));
    }
  }

  void changeRegion(Rect? next) {
    clearOcr();
    selectionUndo.add(region);
    operations.add(1);
    commit();
    region = next;
  }

  void undoOne() {
    if (locked) return;
    if (ocrSelection != null || qrCodes != null || qrFailure != null) exitOcr();
    dismissTextPrompt();
    if (active?.tool == MarkTool.line) {
      cancelLine();
      return;
    }
    commitText();
    if (operations.isEmpty || locked) return;
    setState(() {
      final selection = operations.removeLast();
      redoOperations.add(selection);
      if (selection == 3) {
        final edit = markListUndo.removeLast();
        marks
          ..clear()
          ..addAll(edit.before);
        selectedTextIndex = edit.selectedBefore;
        markListRedo.add(edit);
      } else if (selection == 2) {
        final edit = textUndo.removeLast();
        marks[edit.index] = edit.before;
        textRedo.add(edit);
      } else if (selection == 1) {
        selectionRedo.add(region);
        region = selectionUndo.removeLast();
      } else {
        redo.add(marks.removeLast());
      }
    });
  }

  void redoOne() {
    if (locked) return;
    if (ocrSelection != null || qrCodes != null || qrFailure != null) exitOcr();
    dismissTextPrompt();
    if (active?.tool == MarkTool.line) {
      cancelLine();
      return;
    }
    commitText();
    if (redoOperations.isEmpty || locked) return;
    setState(() {
      final selection = redoOperations.removeLast();
      operations.add(selection);
      if (selection == 3) {
        final edit = markListRedo.removeLast();
        marks
          ..clear()
          ..addAll(edit.after);
        selectedTextIndex = edit.selectedAfter;
        markListUndo.add(edit);
      } else if (selection == 2) {
        final edit = textRedo.removeLast();
        marks[edit.index] = edit.after;
        textUndo.add(edit);
      } else if (selection == 1) {
        selectionUndo.add(region);
        region = selectionRedo.removeLast();
      } else {
        marks.add(redo.removeLast());
      }
    });
  }

  Future<void> finish(bool save, {bool pin = false}) async {
    if (image == null ||
        locked ||
        region == null ||
        active?.tool == MarkTool.line) {
      return;
    }
    dismissTextPrompt();
    commitText();
    setState(() => rendering = true);
    try {
      final bytes = await renderCapture(
        image!,
        visibleMarks,
        region,
        mosaic: mosaic,
      );
      if (!mounted) return;
      if (pin) {
        await widget.controller.pin(
          bytes,
          region!,
          animate: !MediaQuery.disableAnimationsOf(context),
        );
      } else {
        await widget.controller.finish(bytes, save: save);
      }
    } catch (e) {
      if (mounted) setState(() => loadError = '生成图片失败：$e');
    } finally {
      if (mounted) setState(() => rendering = false);
    }
  }

  void cancelOcr() {
    ocrRequest++;
    setState(() => recognizingText = false);
  }

  Future<void> retryOcr() async {
    setState(clearOcr);
    await recognizeText();
  }

  Future<void> recognizeText() async {
    if (ocrSelection != null) {
      exitOcr();
      return;
    }
    if (locked || image == null || region == null || active != null) return;
    dismissTextPrompt();
    commitText();
    clearQr();
    final request = ++ocrRequest;
    setState(() {
      recognizingText = true;
      loadError = null;
      ocrFailure = null;
    });
    try {
      final bytes = await renderCapture(
        image!,
        visibleMarks,
        region,
        mosaic: mosaic,
      );
      if (!mounted || request != ocrRequest) return;
      final result = await widget.controller.bridge.recognizeText(bytes);
      if (!mounted || request != ocrRequest) return;
      final selection = OcrSelection(result)..addListener(ocrChanged);
      setState(() {
        ocrSelection = selection;
        recognizingText = false;
      });
      focus.requestFocus();
    } on PlatformException catch (e) {
      if (mounted && request == ocrRequest) {
        setState(() => ocrFailure = e.message ?? '请稍后重试');
      }
    } catch (_) {
      if (mounted && request == ocrRequest) {
        setState(() => ocrFailure = '请稍后重试，或重新框选文字区域');
      }
    } finally {
      if (mounted && request == ocrRequest) {
        setState(() => recognizingText = false);
      }
    }
  }

  Future<void> scanQr() async {
    if (locked || image == null || region == null || active != null) return;
    if (qrCodes != null) {
      exitQr();
      return;
    }
    dismissTextPrompt();
    commitText();
    setState(() {
      clearOcr();
      scanningQr = true;
    });
    final request = ++qrRequest;
    try {
      final bytes = await renderCapture(
        image!,
        visibleMarks,
        region,
        mosaic: mosaic,
      );
      if (!mounted || request != qrRequest) return;
      final result = await widget.controller.bridge.scanQrCodes(bytes);
      if (!mounted || request != qrRequest) return;
      setState(() => qrCodes = result);
    } catch (_) {
      if (mounted && request == qrRequest) {
        setState(() => qrFailure = '二维码扫描失败，请重试');
      }
    } finally {
      if (mounted && request == qrRequest) setState(() => scanningQr = false);
    }
  }

  Future<void> retryQr() async {
    setState(clearQr);
    await scanQr();
  }

  Future<void> openQr(int index, {bool inspect = false}) async {
    if (locked || qrCodes == null || index >= qrCodes!.length) return;
    final code = qrCodes![index];
    final request = qrRequest;
    setState(() {
      openingQr = index;
      qrFailure = null;
    });
    try {
      if (!inspect && code.link != null) {
        await widget.controller.bridge.openBrowser(code.link!);
        // This completes a navigation action, without exporting an image or
        // changing the clipboard.
        if (mounted && request == qrRequest) await widget.controller.discard();
      } else {
        setState(() => openingQr = null);
        final copy = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            constraints: const BoxConstraints(maxWidth: 420),
            title: const Text('二维码内容'),
            content: SizedBox(
              width: 360,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .4,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(code.content),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('关闭'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('复制内容'),
              ),
            ],
          ),
        );
        if (copy == true) {
          await Clipboard.setData(ClipboardData(text: code.content));
        }
      }
    } catch (_) {
      if (mounted && request == qrRequest) {
        setState(() => qrFailure = '内容打开失败，请重试或复制链接');
        try {
          await widget.controller.bridge.present('capture');
        } catch (_) {}
      }
    } finally {
      if (mounted && request == qrRequest) setState(() => openingQr = null);
    }
  }

  Mark draftText() {
    final previous = editingTextIndex == null ? null : marks[editingTextIndex!];
    final inset = previous?.padding ?? 10.0;
    final viewport = viewportKey.currentContext?.findRenderObject();
    final sx = viewport is RenderBox && viewport.hasSize
        ? viewport.size.width / widget.clip.width
        : 1.0;
    // RenderEditable reserves cursorWidth + 1px. Give the editor that space
    // separately so its wrapping matches the exported TextPainter exactly.
    final caretSpace = 3 / sx;
    final available = math.max(
      1.0,
      region!.right - textAnchor!.dx - inset * 2 - caretSpace,
    );
    Mark mark(Offset position, Size? frame) => Mark(
      MarkTool.text,
      color,
      stroke,
      [position],
      text: textInput.text,
      fontSize: fontSize,
      bold: bold,
      italic: italic,
      underline: underline,
      textAlign: textAlign,
      maxTextWidth: available,
      minTextWidth: previous?.minTextWidth ?? 80,
      background: textBackground,
      translationId: previous?.translationId,
      textFrame: frame,
      rotation: previous?.rotation ?? 0,
      padding: inset,
    );
    final natural = mark(textAnchor!, null);
    final tp = natural.textPainter;
    final oldFrame = previous?.textFrame;
    final frame = oldFrame == null
        ? null
        : Size(
            math.min(
              available + inset * 2,
              math.max(oldFrame.width, tp.width + inset * 2),
            ),
            math.max(oldFrame.height, tp.height + inset * 2),
          );
    final draft = mark(textAnchor!, frame);
    final position = Offset(
      textAnchor!.dx,
      math.max(
        region!.top,
        math.min(textAnchor!.dy, region!.bottom - draft.textBoxSize.height),
      ),
    );
    return mark(position, frame);
  }

  void commitText() {
    if (textAnchor == null) return;
    final draft = draftText();
    final index = editingTextIndex;
    setState(() {
      if (draft.text.trim().isEmpty) {
        if (index != null) {
          final before = List<Mark>.of(marks);
          final selectedBefore = selectedTextIndex;
          commit();
          marks.removeAt(index);
          selectedTextIndex = null;
          markListUndo.add((
            before: before,
            after: List<Mark>.of(marks),
            selectedBefore: selectedBefore,
            selectedAfter: null,
          ));
          operations.add(3);
        }
      } else {
        if (index == null) {
          marks.add(draft);
          selectedTextIndex = marks.length - 1;
          operations.add(0);
          commit();
        } else {
          final previous = marks[index];
          if (previous.text != draft.text ||
              previous.color != draft.color ||
              previous.fontSize != draft.fontSize ||
              previous.bold != draft.bold ||
              previous.italic != draft.italic ||
              previous.underline != draft.underline ||
              previous.textAlign != draft.textAlign ||
              previous.background != draft.background ||
              previous.maxTextWidth != draft.maxTextWidth ||
              previous.textFrame != draft.textFrame ||
              previous.points.first != draft.points.first) {
            commit();
            textUndo.add((index: index, before: previous, after: draft));
            marks[index] = draft;
            operations.add(2);
          }
        }
      }
      textAnchor = null;
      editingTextIndex = null;
      textInput.clear();
    });
    focus.requestFocus();
  }

  void cancelText() {
    setState(() {
      textAnchor = null;
      editingTextIndex = null;
      textInput.clear();
    });
    focus.requestFocus();
  }

  void addText(Offset point, {bool createNew = false}) {
    if (textAnchor != null) {
      commitText();
      return;
    }
    int? index;
    for (int i = marks.length - 1; !createNew && i >= 0; i--) {
      final mark = marks[i];
      if (mark.tool == MarkTool.text &&
          (Offset.zero & mark.textBoxSize).contains(textToLocal(mark, point))) {
        index = i;
        break;
      }
    }
    setState(() {
      editingTextIndex = index;
      selectedTextIndex = index;
      if (index != null) {
        final mark = marks[index];
        textAnchor = mark.points.first;
        textInput.text = mark.text;
        fontSize = mark.fontSize;
        bold = mark.bold;
        italic = mark.italic;
        underline = mark.underline;
        textAlign = mark.textAlign;
        color = mark.color;
        textBackground = mark.background;
      } else {
        textAnchor = Offset(
          point.dx.clamp(
            region!.left,
            math.max(region!.left, region!.right - 100),
          ),
          point.dy.clamp(
            region!.top,
            math.max(region!.top, region!.bottom - fontSize * 1.3 - 24),
          ),
        );
        textInput.clear();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) textFocus.requestFocus();
    });
  }

  void chooseTool(MarkTool next) {
    if (locked) return;
    clearOcr();
    dismissTextPrompt();
    commitText();
    setState(() {
      if (active?.tool == MarkTool.line) active = null;
      draggingLine = false;
      tool = next;
      if (isPrivacyBrush(next)) privacyTool = next;
      colorPanel = null;
    });
  }

  void textStyleChanged(VoidCallback update) {
    setState(update);
    if (textAnchor != null) textFocus.requestFocus();
  }

  void chooseTextAlignment(TextAlign alignment) {
    if (locked) return;
    if (textAnchor != null) {
      textStyleChanged(() => textAlign = alignment);
      return;
    }
    setState(() {
      textAlign = alignment;
      final mark = selectedText;
      if (mark != null && mark.textAlign != alignment) {
        final index = selectedTextIndex!;
        final next = mark.copyText(alignment: alignment);
        commit();
        textUndo.add((index: index, before: mark, after: next));
        marks[index] = next;
        operations.add(2);
      }
    });
    focus.requestFocus();
  }

  void chooseTextBackground(Color background) {
    if (locked) return;
    if (textAnchor != null) {
      textStyleChanged(() => textBackground = background);
      return;
    }
    setState(() {
      textBackground = background;
      final mark = selectedText;
      if (mark != null && mark.background != background) {
        final index = selectedTextIndex!;
        final next = mark.copyText(background: background);
        commit();
        textUndo.add((index: index, before: mark, after: next));
        marks[index] = next;
        operations.add(2);
      }
    });
    focus.requestFocus();
  }

  Mark? get selectedText {
    final index = selectedTextIndex;
    if (textAnchor != null ||
        region == null ||
        (tool != MarkTool.text && tool != MarkTool.select) ||
        index == null ||
        index >= marks.length ||
        marks[index].tool != MarkTool.text) {
      return null;
    }
    return marks[index];
  }

  ({int index, String kind, int handle})? textHit(
    Offset point,
    double tolerance,
  ) {
    if (readingActive) return null;
    if (textAnchor != null ||
        region == null ||
        (tool != MarkTool.text && tool != MarkTool.select)) {
      return null;
    }
    final selected = selectedText;
    if (selected != null) {
      final rotationPoint = textToWorld(
        selected,
        Offset(selected.textBoxSize.width / 2, -tolerance * 2.6),
      );
      if ((rotationPoint - point).distance <= tolerance) {
        return (index: selectedTextIndex!, kind: 'rotate', handle: -1);
      }
      final handles = textHandles(selected);
      for (int i = 0; i < handles.length; i++) {
        if ((textToWorld(selected, handles[i]) - point).distance <= tolerance) {
          return (index: selectedTextIndex!, kind: 'resize', handle: i);
        }
      }
    }
    for (int i = marks.length - 1; i >= 0; i--) {
      final mark = marks[i];
      if (mark.tool == MarkTool.text &&
          (Offset.zero & mark.textBoxSize).contains(textToLocal(mark, point))) {
        return (index: i, kind: 'move', handle: -1);
      }
    }
    return null;
  }

  void cancelTextTransform() {
    if (transformingTextIndex != null) {
      marks[transformingTextIndex!] = textBeforeTransform!;
      transformingTextIndex = null;
      textBeforeTransform = null;
      textDragStart = null;
    }
  }

  MouseCursor textCursor(({int index, String kind, int handle}) hit) {
    final kind = transformingTextIndex == null ? hit.kind : textDragKind;
    if (kind == 'rotate') {
      return transformingTextIndex == null
          ? SystemMouseCursors.grab
          : SystemMouseCursors.grabbing;
    }
    if (kind == 'move') {
      return transformingTextIndex == null
          ? SystemMouseCursors.move
          : SystemMouseCursors.grabbing;
    }
    final mark = marks[hit.index];
    final index = transformingTextIndex == null ? hit.handle : textDragHandle;
    final size = mark.textBoxSize;
    final direction =
        textHandles(mark)[index] - Offset(size.width / 2, size.height / 2);
    final angle = direction.direction + mark.rotation;
    return [
      SystemMouseCursors.resizeLeftRight,
      SystemMouseCursors.resizeUpLeftDownRight,
      SystemMouseCursors.resizeUpDown,
      SystemMouseCursors.resizeUpRightDownLeft,
    ][(angle / (math.pi / 4)).round() % 4];
  }

  List<Offset> handles(Rect r) => [
    r.topLeft,
    r.topCenter,
    r.topRight,
    r.centerRight,
    r.bottomRight,
    r.bottomCenter,
    r.bottomLeft,
    r.centerLeft,
  ];

  Offset linePoint(Offset p) => Offset(
    p.dx.clamp(region!.left, region!.right),
    p.dy.clamp(region!.top, region!.bottom),
  );

  void cancelLine() {
    if (active?.tool != MarkTool.line) return;
    setState(() {
      active = null;
      draggingLine = false;
    });
  }

  void completeLine() {
    final line = active;
    if (line?.tool != MarkTool.line) return;
    draggingLine = false;
    if ((line!.points.last - line.points.first).distance < 1) return;
    final completed = Mark(
      MarkTool.line,
      color,
      stroke,
      List<Offset>.of(line.points),
    );
    setState(() {
      marks.add(completed);
      operations.add(0);
      commit();
      active = null;
    });
    offerShapeText(completed);
  }

  void tapLine(Offset p) {
    dismissTextPrompt();
    if (region == null || !region!.contains(p)) return;
    focus.requestFocus();
    if (active?.tool == MarkTool.line) {
      setState(() => active!.points[1] = p);
      completeLine();
    } else {
      setState(() => active = Mark(MarkTool.line, color, stroke, [p, p]));
    }
  }

  void escape() {
    if (readingActive) {
      toggleTranslationReading();
      return;
    }
    if (translatingImage ||
        imageTranslationFailure != null ||
        imageTranslationStatus != null) {
      setState(cancelImageTranslation);
      return;
    }
    if (colorPicker != null || preparingColor) {
      closeColorPicker();
      return;
    }
    if (scanningQr) {
      exitQr();
      return;
    }
    if (qrCodes != null || qrFailure != null) {
      if (!locked) exitQr();
      return;
    }
    if (recognizingText) {
      cancelOcr();
      return;
    }
    if (locked) return;
    if (ocrSelection != null) {
      exitOcr();
      return;
    }
    if (active?.tool == MarkTool.line) {
      cancelLine();
      return;
    }
    widget.controller.discard();
  }

  void enter() {
    if (locked) return;
    if (active?.tool == MarkTool.line) {
      completeLine();
      return;
    }
    finish(false);
  }

  void begin(Offset p, double tolerance) {
    if (locked) return;
    dismissTextPrompt();
    cursor = p;
    focus.requestFocus();
    if (textAnchor != null) {
      commitText();
      return;
    }
    final hit = textHit(p, tolerance);
    if (hit != null) {
      setState(() {
        selectedTextIndex = transformingTextIndex = hit.index;
        textBeforeTransform = marks[hit.index];
        textDragStart = p;
        textDragKind = hit.kind;
        textDragHandle = hit.handle;
      });
      return;
    }
    selectedTextIndex = null;
    if (tool != MarkTool.text) commitText();
    if (tool == MarkTool.select || tool == MarkTool.crop || region == null) {
      if (widget.clip.mode == 'window' && region == null) {
        selectSmartRegion(p);
        return;
      }
      dragStart = p;
      dragRegion = region;
      handle = -1;
      if (region != null) {
        handle = handles(region!)
            .indexWhere((h) => (h - p).distance < tolerance);
      }
      dragKind = handle >= 0
          ? 'resize'
          : region?.contains(p) == true
          ? 'move'
          : 'new';
      if (dragKind == 'new') setState(() => region = Rect.fromPoints(p, p));
      return;
    }
    if (!region!.contains(p)) return;
    if (tool == MarkTool.line) {
      setState(() {
        if (active?.tool != MarkTool.line) {
          active = Mark(MarkTool.line, color, stroke, [p, p]);
        }
        draggingLine = true;
      });
      return;
    }
    if (tool == MarkTool.text) {
      addText(p);
      return;
    }
    if (tool == MarkTool.number) {
      setState(() {
        marks.add(
          Mark(tool, color, stroke, [
            p,
          ], number: marks.where((m) => m.tool == MarkTool.number).length + 1),
        );
        operations.add(0);
        commit();
      });
      return;
    }
    setState(
      () => active = Mark(tool, color, stroke, [
        p,
      ], privacyInteraction: privacyInteraction),
    );
  }

  void update(Offset p) {
    cursor = p;
    if (transformingTextIndex != null) {
      final before = textBeforeTransform!;
      setState(() {
        if (textDragKind == 'move') {
          marks[transformingTextIndex!] = before.copyText(
            position: before.points.first + p - textDragStart!,
          );
        } else if (textDragKind == 'rotate') {
          final center =
              before.points.first +
              Offset(
                before.textBoxSize.width / 2,
                before.textBoxSize.height / 2,
              );
          marks[transformingTextIndex!] = before.copyText(
            angle:
                before.rotation +
                (p - center).direction -
                (textDragStart! - center).direction,
          );
        } else {
          final handle = textHandles(before)[textDragHandle];
          marks[transformingTextIndex!] = resizeTextMark(
            before,
            textDragHandle,
            textToWorld(before, handle) + p - textDragStart!,
            proportional: HardwareKeyboard.instance.isShiftPressed,
          );
        }
      });
      return;
    }
    if (dragStart != null) {
      setState(() {
        if (dragKind == 'new') {
          region = Rect.fromPoints(dragStart!, p).intersect(bounds);
        } else if (dragKind == 'move') {
          final r = dragRegion!, delta = p - dragStart!;
          final dx = delta.dx.clamp(-r.left, bounds.right - r.right),
              dy = delta.dy.clamp(-r.top, bounds.bottom - r.bottom);
          region = r.shift(Offset(dx, dy));
        } else {
          final r = dragRegion!;
          double left = r.left, top = r.top, right = r.right, bottom = r.bottom;
          if ([0, 6, 7].contains(handle)) left = p.dx.clamp(0, right - 2);
          if ([0, 1, 2].contains(handle)) top = p.dy.clamp(0, bottom - 2);
          if ([2, 3, 4].contains(handle)) {
            right = p.dx.clamp(left + 2, bounds.right);
          }
          if ([4, 5, 6].contains(handle)) {
            bottom = p.dy.clamp(top + 2, bounds.bottom);
          }
          region = Rect.fromLTRB(left, top, right, bottom);
        }
      });
      return;
    }
    if (active == null) return;
    if (active!.tool == MarkTool.line) {
      setState(
        () => active = Mark(MarkTool.line, color, stroke, [
          active!.points.first,
          linePoint(p),
        ]),
      );
      return;
    }
    setState(() {
      if (active!.tool == MarkTool.pen ||
          (isPrivacyBrush(active!.tool) &&
              active!.privacyInteraction == PrivacyInteraction.brush) ||
          active!.points.length == 1) {
        active!.points.add(p);
      } else {
        active!.points[active!.points.length - 1] = p;
      }
    });
  }

  void end() {
    if (transformingTextIndex != null) {
      setState(() {
        final index = transformingTextIndex!;
        final before = textBeforeTransform!;
        if (marks[index] != before) {
          commit();
          textUndo.add((index: index, before: before, after: marks[index]));
          operations.add(2);
        }
        transformingTextIndex = null;
        textBeforeTransform = null;
        textDragStart = null;
      });
      return;
    }
    if (dragStart != null) {
      setState(() {
        if (region == null || region!.width < 2 || region!.height < 2) {
          region = dragRegion;
        } else if (region != dragRegion) {
          final r = region!;
          region = Rect.fromLTRB(
            r.left.roundToDouble(),
            r.top.roundToDouble(),
            r.right.roundToDouble(),
            r.bottom.roundToDouble(),
          ).intersect(bounds);
          selectionUndo.add(dragRegion);
          operations.add(1);
          commit();
        }
        dragStart = null;
        dragRegion = null;
      });
      return;
    }
    if (active == null) return;
    if (isShapeTool(active!.tool) ||
        (isPrivacyBrush(active!.tool) &&
            active!.privacyInteraction == PrivacyInteraction.rectangle)) {
      // Reject clicks and pointer jitter in displayed pixels, regardless of DPI.
      final rect = annotationBounds(active!);
      final viewport = viewportKey.currentContext?.findRenderObject();
      final sx = viewport is RenderBox && viewport.hasSize
          ? viewport.size.width / widget.clip.width
          : 1.0;
      final sy = viewport is RenderBox && viewport.hasSize
          ? viewport.size.height / widget.clip.height
          : 1.0;
      if (rect.width * sx < 8 || rect.height * sy < 8) {
        setState(() => active = null);
        return;
      }
    }
    if (active!.tool == MarkTool.line) {
      if (draggingLine) completeLine();
      return;
    }
    final completed = active!;
    setState(() {
      marks.add(completed);
      operations.add(0);
      commit();
      active = null;
    });
    offerShapeText(completed);
  }

  void dismissTextPrompt() {
    textPromptTimer?.cancel();
    textPromptTimer = null;
    if (textPromptVisible) setState(() => textPromptVisible = false);
  }

  void armTextPrompt(Duration duration) {
    textPromptTimer?.cancel();
    if (!mounted ||
        !textPromptVisible ||
        textPromptHovered ||
        textPromptFocused) {
      return;
    }
    textPromptTimer = Timer(duration, () {
      if (mounted) dismissTextPrompt();
    });
  }

  void offerShapeText(Mark shape) {
    if (isShapeTool(shape.tool) && annotationBounds(shape).isEmpty) return;
    if (!const [
          MarkTool.arrow,
          MarkTool.line,
          MarkTool.rectangle,
          MarkTool.circle,
          MarkTool.ellipse,
        ].contains(shape.tool) ||
        (shape.points.last - shape.points.first).distance < 2) {
      return;
    }
    setState(() {
      textPromptShape = shape;
      textPromptVisible = true;
      textPromptHovered = textPromptFocused = false;
    });
    armTextPrompt(const Duration(seconds: 5));
  }

  void addShapeText(Mark shape) {
    if (locked || !textPromptVisible || !marks.contains(shape)) return;
    final anchor =
        annotationBounds(shape).intersect(region ?? bounds).bottomRight +
        const Offset(10, 10);
    chooseTool(MarkTool.text);
    addText(anchor, createNew: true);
  }

  void measureToolbarForOverlays() {
    if (measuringToolbar) return;
    measuringToolbar = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      measuringToolbar = false;
      if (!mounted ||
          (!textPromptVisible &&
              !readingActive &&
              toolbarManualAnchor == null)) {
        return;
      }
      final toolbar = toolbarKey.currentContext?.findRenderObject();
      final viewport = viewportKey.currentContext?.findRenderObject();
      if (toolbar is RenderBox &&
          viewport is RenderBox &&
          toolbar.hasSize &&
          viewport.hasSize) {
        final next =
            toolbar.localToGlobal(Offset.zero, ancestor: viewport) &
            toolbar.size;
        if (next != measuredToolbar) {
          setState(() => measuredToolbar = next);
          scheduleCaptureFrame();
        }
      }
    });
  }

  Widget buildShapeTextPrompt(BuildContext context, Mark shape) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !textPromptVisible || locked,
      child: ExcludeSemantics(
        excluding: !textPromptVisible || locked,
        child: TweenAnimationBuilder<double>(
          key: ValueKey(shape),
          tween: Tween(begin: reduced ? 1 : 0, end: textPromptVisible ? 1 : 0),
          duration: reduced
              ? Duration.zero
              : Duration(milliseconds: textPromptVisible ? 120 : 80),
          curve: Curves.easeOutCubic,
          onEnd: () {
            if (textPromptVisible) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !textPromptVisible && textPromptShape == shape) {
                setState(() => textPromptShape = null);
              }
            });
          },
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.scale(scale: .96 + .04 * value, child: child),
          ),
          child: MouseRegion(
            onEnter: (_) {
              textPromptHovered = true;
              armTextPrompt(const Duration(seconds: 2));
            },
            onExit: (_) {
              textPromptHovered = false;
              armTextPrompt(const Duration(seconds: 2));
            },
            child: Focus(
              skipTraversal: true,
              onFocusChange: (value) {
                textPromptFocused = value;
                armTextPrompt(const Duration(seconds: 2));
              },
              child: Material(
                key: const ValueKey('shape-text-prompt'),
                color: Theme.of(context).colorScheme.primary,
                elevation: 4,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: ToolButton(
                  label: '给形状添加文字',
                  primary: true,
                  onPressed: () => addShapeText(shape),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.text_bubble, size: 16),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text('添加文字', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Rect? windowAt(Offset p) {
    for (final r in widget.clip.windows) {
      if (r.contains(p)) return r.intersect(bounds);
    }
    for (final screen in widget.clip.screens) {
      if (screen.contains(p)) return screen.intersect(bounds);
    }
    return widget.clip.screens.isEmpty && bounds.contains(p) ? bounds : null;
  }

  Future<void> selectSmartRegion(Offset point) async {
    if (locked) return;
    final target = windowAt(point);
    if (target == null) return;
    final index = widget.clip.windows.indexWhere((r) => r.contains(point));
    setState(() => changeRegion(target));
    if (index < 0 && !focusedCaptureWindow) return;
    setState(() => preparingSmartSelection = true);
    try {
      final frame = await widget.controller.bridge.focusCaptureWindow(index);
      focusedCaptureWindow = index >= 0;
      if (!mounted) return;
      if (frame?['bytes'] case final Uint8List bytes) await load(bytes);
    } catch (e) {
      if (mounted) setState(() => loadError = '窗口画面获取失败：$e');
    } finally {
      if (mounted) {
        try {
          await widget.controller.bridge.present('capture');
        } catch (e) {
          if (mounted) setState(() => loadError = '截图界面恢复失败：$e');
        } finally {
          if (mounted) setState(() => preparingSmartSelection = false);
        }
      }
    }
  }

  void hoverAt(Offset p) {
    final viewport = viewportKey.currentContext?.findRenderObject();
    final sx = viewport is RenderBox && viewport.hasSize
        ? viewport.size.width / widget.clip.width
        : 1.0;
    setState(() {
      cursor = p;
      if (active?.tool == MarkTool.line && !locked) {
        active = Mark(MarkTool.line, color, stroke, [
          active!.points.first,
          linePoint(p),
        ]);
      }
      final hit = textHit(p, 10 / sx);
      if (hit != null) selectedTextIndex = hit.index;
      if (region == null && !locked) hovered = windowAt(p);
    });
  }

  void nudgeCursor(int dx, int dy) {
    // Serialize key repeats so every step uses the last native cursor position.
    cursorNudges = cursorNudges.then((_) async {
      if (!mounted || locked || textAnchor != null) return;
      try {
        final point = await widget.controller.bridge.nudgeCursor(dx, dy);
        if (!mounted || locked || textAnchor != null) return;
        final p = Offset(
          point.dx.clamp(0, bounds.right - 1),
          point.dy.clamp(0, bounds.bottom - 1),
        );
        if (loadError == '光标微调失败，请重试') {
          loadError = null;
        }
        if (colorPicker != null) {
          if (widget.clip.screens.isEmpty ||
              widget.clip.screens.any((r) => r.contains(p))) {
            colorPicker!.move(p);
          }
          return;
        }
        if (ocrSelection != null && region != null) {
          setState(() => cursor = p);
          if (ocrSelection!.dragging) {
            ocrSelection!.extend(
              Offset(
                (p.dx - region!.left) / region!.width,
                (p.dy - region!.top) / region!.height,
              ),
            );
          }
          return;
        }
        if (dragStart != null ||
            transformingTextIndex != null ||
            (active != null &&
                (active!.tool != MarkTool.line || draggingLine))) {
          update(p);
        } else {
          hoverAt(p);
        }
      } catch (_) {
        if (mounted) setState(() => loadError = '光标微调失败，请重试');
      }
    });
  }

  void moveSelection(int dx, int dy) {
    if (locked || region == null) return;
    final r = region!;
    final next = r.shift(
      Offset(
        dx.toDouble().clamp(-r.left, bounds.right - r.right),
        dy.toDouble().clamp(-r.top, bounds.bottom - r.bottom),
      ),
    );
    if (next != r) setState(() => changeRegion(next));
  }

  Widget buildToolbar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentAlignment = textAnchor == null
        ? selectedText?.textAlign ?? textAlign
        : textAlign;
    final currentBackground = textAnchor == null
        ? selectedText?.background ?? textBackground
        : textBackground;
    Widget separator() => Container(
      width: 1,
      height: 17,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: cs.outline.withValues(alpha: .28),
    );
    Widget toolGroup(
      String label,
      List<Widget> children, {
      bool divided = true,
    }) => Semantics(
      container: true,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (divided) separator(),
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(width: 2),
            child,
          ],
        ],
      ),
    );
    Widget annotationButton((MarkTool, IconData, String) entry) => ToolButton(
      size: 28,
      label: entry.$3,
      icon: entry.$2,
      selected:
          tool == entry.$1 ||
          (entry.$1 == MarkTool.rectangle && isShapeTool(tool)),
      onPressed: locked ? null : () => chooseTool(entry.$1),
    );
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      ValueChanged<double> onChanged, {
      double step = .5,
    }) => SizedBox(
      width: 144,
      height: 30,
      child: FineSlider(
        label: label,
        value: value,
        min: min,
        max: max,
        step: step,
        onChanged: locked ? null : onChanged,
      ),
    );
    final inspector =
        (readingPassages.isNotEmpty &&
                (tool == MarkTool.select || readingActive)) ||
            translatingImage ||
            imageTranslationStatus != null ||
            imageTranslationFailure != null
        ? ToolbarWrap(
            children: [
              OcrStatus(
                title: translatingImage
                    ? imageTranslationStatus!
                    : imageTranslationFailure != null
                    ? '翻译未完成'
                    : '翻译完成',
                detail:
                    imageTranslationFailure ??
                    (readingActive
                        ? '图上译文已隐藏 · 指向原文定位译文'
                        : translatingImage
                        ? '仅发送文字 · Esc 取消'
                        : imageTranslationStatus ?? '指向原文段落，对照阅读译文'),
                icon: CupertinoIcons.globe,
                attention: imageTranslationFailure != null,
              ),
              if (!translatingImage && readingPassages.isNotEmpty)
                ToolButton(
                  label: '对照阅读',
                  selected: readingActive,
                  icon: CupertinoIcons.book,
                  onPressed: toggleTranslationReading,
                  child: const Text('对照阅读'),
                ),
              if (imageTranslationFailure != null) ...[
                ToolButton(
                  label: '重试翻译',
                  onPressed: openTranslation,
                  child: const Text('重试'),
                ),
                ToolButton(
                  label: '配置翻译渠道',
                  onPressed: () => setState(() => translationOpen = true),
                  child: const Text('渠道设置'),
                ),
              ],
              if (translatingImage ||
                  imageTranslationFailure != null ||
                  readingPassages.isEmpty)
                ToolButton(
                  label: translatingImage ? '取消翻译' : '收起翻译提示',
                  child: Text(translatingImage ? '取消' : '收起'),
                  onPressed: () => setState(cancelImageTranslation),
                ),
            ],
          )
        : scanningQr
        ? ToolbarWrap(
            key: const ValueKey('qr-loading-inspector'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const OcrStatus(
                title: '正在扫描二维码',
                detail: '本机识别 · 支持多个二维码',
                icon: Icons.qr_code_scanner_rounded,
              ),
              ToolButton(
                label: '取消二维码扫描',
                onPressed: exitQr,
                child: const Text('取消扫描'),
              ),
            ],
          )
        : qrCodes != null || qrFailure != null
        ? ToolbarWrap(
            key: const ValueKey('qr-inspector'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OcrStatus(
                title: qrFailure != null
                    ? '操作未完成'
                    : qrCodes!.isEmpty
                    ? '未发现二维码'
                    : '找到 ${qrCodes!.length} 个二维码',
                detail:
                    qrFailure ??
                    (qrCodes!.isEmpty ? '重新框选，或再试一次' : '点击二维码中心按钮打开内容'),
                icon: Icons.qr_code_rounded,
                attention: qrFailure != null,
              ),
              ToolButton(
                label: '重新扫描二维码',
                onPressed: openingQr != null ? null : retryQr,
                child: const Text('重新扫描'),
              ),
              ToolButton(
                label: '退出二维码扫描',
                onPressed: openingQr != null ? null : exitQr,
                child: const Text('返回标注'),
              ),
            ],
          )
        : recognizingText
        ? ToolbarWrap(
            key: const ValueKey('ocr-loading-inspector'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const OcrStatus(
                title: '正在识别文字',
                detail: '本机处理 · 图片不会上传',
                icon: Icons.document_scanner_outlined,
              ),
              ToolButton(
                label: '取消文字识别',
                onPressed: cancelOcr,
                child: const Text('取消识别'),
              ),
            ],
          )
        : ocrFailure != null
        ? ToolbarWrap(
            key: const ValueKey('ocr-failed-inspector'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OcrStatus(
                title: '识别未完成',
                detail: ocrFailure!,
                icon: Icons.error_outline,
                attention: true,
              ),
              ToolButton(
                label: '重试文字识别',
                onPressed: retryOcr,
                child: const Text('重试'),
              ),
              ToolButton(
                label: '退出文字识别',
                onPressed: exitOcr,
                child: const Text('返回标注'),
              ),
            ],
          )
        : ocrSelection != null
        ? ToolbarWrap(
            key: const ValueKey('ocr-inspector'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OcrStatus(
                title: !ocrSelection!.hasText
                    ? '未识别到文字'
                    : ocrSelection!.error != null
                    ? '复制未完成'
                    : ocrSelection!.copying
                    ? '正在复制'
                    : ocrSelection!.copied
                    ? '已复制选中文字'
                    : ocrSelection!.selectedText.isEmpty
                    ? '找到 ${ocrSelection!.glyphs.map((g) => g.line).toSet().length} 行文字'
                    : '已选 ${ocrSelection!.selectedText.characters.length} 字',
                detail: !ocrSelection!.hasText
                    ? '换个选区，或再试一次'
                    : ocrSelection!.error ??
                          (ocrSelection!.copied
                              ? '可继续拖选，或返回标注'
                              : '拖动选择 · Ctrl/⌘+C 复制'),
                icon: !ocrSelection!.hasText
                    ? Icons.search_off
                    : ocrSelection!.copied
                    ? Icons.check_circle_outline
                    : Icons.text_fields,
                attention: ocrSelection!.error != null,
              ),
              if (ocrSelection!.hasText) ...[
                ToolButton(
                  label: '全选识别文字',
                  onPressed: ocrSelection!.selectAll,
                  child: const Text('全选'),
                ),
                ToolButton(
                  label: '复制选中文字',
                  onPressed:
                      ocrSelection!.selectedText.isEmpty ||
                          ocrSelection!.copying
                      ? null
                      : ocrSelection!.copy,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        ocrSelection!.copied
                            ? Icons.check_rounded
                            : Icons.content_copy_rounded,
                        size: 13,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        ocrSelection!.copying
                            ? '复制中…'
                            : ocrSelection!.copied
                            ? '已复制'
                            : '复制文字',
                      ),
                    ],
                  ),
                ),
              ] else
                ToolButton(
                  label: '重试文字识别',
                  onPressed: retryOcr,
                  child: const Text('重试'),
                ),
              ToolButton(
                label: '退出文字识别',
                onPressed: exitOcr,
                child: const Text('返回标注'),
              ),
            ],
          )
        : tool == MarkTool.text
        ? ToolbarWrap(
            key: const ValueKey('text-inspector'),
            spacing: 16,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              ToolbarOptionGroup(
                label: '字号',
                children: [
                  slider(
                    '字号',
                    fontSize,
                    12,
                    144,
                    (v) => textStyleChanged(() => fontSize = v),
                    step: 1,
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${fontSize.round()}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  // Step controls also provide a precise keyboard/pointer alternative.
                  ToolButton(
                    label: '减小字号',
                    icon: CupertinoIcons.minus,
                    size: 26,
                    onPressed: locked
                        ? null
                        : () => textStyleChanged(
                            () => fontSize = math.max(12, fontSize - 2),
                          ),
                  ),
                  ToolButton(
                    label: '增大字号',
                    icon: CupertinoIcons.plus,
                    size: 26,
                    onPressed: locked
                        ? null
                        : () => textStyleChanged(
                            () => fontSize = math.min(144, fontSize + 2),
                          ),
                  ),
                ],
              ),
              ToolbarOptionGroup(
                label: '样式',
                children: [
                  ToolButton(
                    label: '加粗',
                    icon: CupertinoIcons.bold,
                    selected: bold,
                    onPressed: locked
                        ? null
                        : () => textStyleChanged(() => bold = !bold),
                  ),
                  ToolButton(
                    label: '斜体',
                    icon: CupertinoIcons.italic,
                    selected: italic,
                    onPressed: locked
                        ? null
                        : () => textStyleChanged(() => italic = !italic),
                  ),
                  ToolButton(
                    label: '下划线',
                    icon: CupertinoIcons.underline,
                    selected: underline,
                    onPressed: locked
                        ? null
                        : () => textStyleChanged(() => underline = !underline),
                  ),
                  ToolButton(
                    label: '文字背景颜色',
                    selected: colorPanel == 'background',
                    onPressed: locked
                        ? null
                        : () => setState(
                            () => colorPanel = colorPanel == 'background'
                                ? null
                                : 'background',
                          ),
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        color: currentBackground,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: cs.outline),
                      ),
                    ),
                  ),
                ],
              ),
              ToolbarOptionGroup(
                label: '对齐',
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in [
                        (
                          TextAlign.left,
                          CupertinoIcons.text_alignleft,
                          '文字左对齐',
                        ),
                        (
                          TextAlign.center,
                          CupertinoIcons.text_aligncenter,
                          '文字居中对齐',
                        ),
                        (
                          TextAlign.right,
                          CupertinoIcons.text_alignright,
                          '文字右对齐',
                        ),
                      ])
                        ToolButton(
                          label: entry.$3,
                          icon: entry.$2,
                          selected: currentAlignment == entry.$1,
                          onPressed: locked
                              ? null
                              : () => chooseTextAlignment(entry.$1),
                        ),
                    ],
                  ),
                ],
              ),
              if (textAnchor != null)
                ToolButton(
                  label: '完成文字',
                  icon: CupertinoIcons.check_mark,
                  onPressed: locked ? null : commitText,
                ),
            ],
          )
        : tool == MarkTool.select
        ? const SizedBox.shrink(key: ValueKey('no-inspector'))
        : Column(
            key: ValueKey(
              isPrivacyBrush(tool) ? 'privacy-inspector' : 'stroke-inspector',
            ),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isPrivacyBrush(tool))
                ToolbarWrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    ToolbarOptionGroup(
                      label: '处理效果',
                      children: [
                        ToolButton(
                          label: '模糊画笔',
                          selected: tool == MarkTool.redact,
                          onPressed: locked
                              ? null
                              : () => chooseTool(MarkTool.redact),
                          child: const Text('模糊'),
                        ),
                        ToolButton(
                          label: '马赛克画笔',
                          selected: tool == MarkTool.mosaic,
                          onPressed: locked
                              ? null
                              : () => chooseTool(MarkTool.mosaic),
                          child: const Text('马赛克'),
                        ),
                      ],
                    ),
                    ToolbarOptionGroup(
                      label: '操作方式',
                      children: [
                        for (final entry in [
                          (
                            PrivacyInteraction.brush,
                            '画笔',
                            CupertinoIcons.paintbrush,
                          ),
                          (PrivacyInteraction.rectangle, '框选', Icons.crop_free),
                        ])
                          ToolButton(
                            label: '隐私${entry.$2}模式',
                            selected: privacyInteraction == entry.$1,
                            onPressed: locked
                                ? null
                                : () => setState(() {
                                    active = null;
                                    privacyInteraction = entry.$1;
                                  }),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(entry.$3, size: 16),
                                const SizedBox(width: 4),
                                Text(entry.$2),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              if (isShapeTool(tool))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ToolbarOptionGroup(
                    label: '形状',
                    children: [
                      for (final entry in [
                        (MarkTool.rectangle, '方框标注', CupertinoIcons.square),
                        (MarkTool.circle, '圆形标注', CupertinoIcons.circle),
                        (MarkTool.ellipse, '椭圆标注', CupertinoIcons.circle),
                      ])
                        ToolButton(
                          size: 28,
                          label: entry.$2,
                          selected: tool == entry.$1,
                          onPressed: locked ? null : () => chooseTool(entry.$1),
                          child: Transform.scale(
                            scaleY: entry.$1 == MarkTool.ellipse ? .65 : 1,
                            child: Icon(entry.$3, size: 16),
                          ),
                        ),
                    ],
                  ),
                ),
              if (isPrivacyBrush(tool) &&
                  privacyInteraction == PrivacyInteraction.rectangle)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 7,
                  ),
                  child: Text(
                    '拖动框选需要处理的区域',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                )
              else
                Row(
                  children: [
                    Text(
                      isPrivacyBrush(tool) ? '笔刷范围' : '线条粗细',
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        width: 140,
                        height: 30,
                        child: FineSlider(
                          label: '线条粗细',
                          value: stroke,
                          min: 1,
                          max: 12,
                          onChanged: locked
                              ? null
                              : (v) => setState(() => stroke = v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Tooltip(
                        message:
                            '笔刷直径 ${brushDiameter(tool, stroke).toStringAsFixed(1)} px',
                        child: CustomPaint(
                          size: const Size(28, 28),
                          painter: BrushCursorPainter(
                            center: const Offset(14, 14),
                            diameter: brushDiameter(tool, stroke).clamp(2, 24),
                            color: isPrivacyBrush(tool) ? cs.onSurface : color,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '${brushDiameter(tool, stroke).toStringAsFixed(1)} px',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 10,
                          fontFeatures: [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          );
    final mainHeader = Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Tooltip(
              message: '拖动此处移动工具栏',
              child: GestureDetector(
                key: const ValueKey('capture-toolbar-drag-handle'),
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (_) => startToolbarDrag(),
                onPanUpdate: (event) => moveToolbar(event.delta),
                child: SizedBox(
                  height: 24,
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.line_horizontal_3,
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      const SizedBox(width: 3),
                      Text(
                        '${region!.width.round()} × ${region!.height.round()}',
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 100),
                            child: Text(
                              textAnchor == null
                                  ? tool == MarkTool.line
                                        ? (active?.tool == MarkTool.line
                                              ? '点击终点 · Enter 完成 · Esc 取消直线'
                                              : '点击两点画直线 · G')
                                        : 'WASD 微调 · Enter 复制'
                                  : 'Enter 换行 · Ctrl/⌘+Enter 完成',
                              key: ValueKey(textAnchor != null),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        ToolButton(
          label: '重新框选',
          icon: CupertinoIcons.arrow_2_squarepath,
          size: 24,
          onPressed: locked
              ? null
              : () {
                  commitText();
                  setState(() {
                    changeRegion(null);
                    dismissTextPrompt();
                    if (active?.tool == MarkTool.line) active = null;
                    draggingLine = false;
                    tool = MarkTool.select;
                  });
                },
        ),
      ],
    );
    final mainTools = ToolbarWrap(
      key: const ValueKey('capture-primary-tools'),
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        toolGroup('常用标注', [
          for (final entry in [
            (MarkTool.select, CupertinoIcons.move, '调整选区 · V'),
            (MarkTool.arrow, CupertinoIcons.arrow_up_right, '箭头 · Q'),
            (MarkTool.rectangle, CupertinoIcons.square, '矩形 · R'),
            (MarkTool.pen, CupertinoIcons.pencil, '画笔 · P'),
            (MarkTool.text, CupertinoIcons.textformat, '文字 · T'),
          ])
            annotationButton(entry),
        ], divided: false),
        toolGroup('补充标注', [
          annotationButton((MarkTool.line, CupertinoIcons.minus, '直线 · G')),
          annotationButton((MarkTool.number, CupertinoIcons.list_number, '序号')),
        ]),
        toolGroup('隐私与识别', [
          ToolButton(
            size: 28,
            label: '翻译选区文字',
            icon: CupertinoIcons.globe,
            onPressed:
                locked || image == null || region == null || active != null
                ? null
                : openTranslation,
          ),
          annotationButton((
            privacyTool,
            CupertinoIcons.shield_lefthalf_fill,
            '隐私画笔 · B',
          )),
          ToolButton(
            size: 28,
            label: '识别文字 · OCR',
            selected: ocrSelection != null,
            onPressed:
                locked || image == null || region == null || active != null
                ? null
                : recognizeText,
            child: recognizingText
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.document_scanner_outlined, size: 17),
          ),
          ToolButton(
            size: 28,
            label: '扫描二维码',
            selected: qrCodes != null,
            onPressed:
                locked || image == null || region == null || active != null
                ? null
                : scanQr,
            child: scanningQr
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.qr_code_scanner_rounded, size: 17),
          ),
          ToolButton(
            size: 28,
            label: '屏幕取色 · I',
            selected: colorPicker != null,
            onPressed: locked || image == null || active != null
                ? null
                : () => startColorPicker(),
            icon: Icons.colorize_rounded,
          ),
        ]),
        toolGroup('样式与撤销', [
          ToolButton(
            size: 28,
            label: '标注颜色',
            selected: colorPanel == 'foreground',
            onPressed: locked
                ? null
                : () => setState(
                    () => colorPanel = colorPanel == 'foreground'
                        ? null
                        : 'foreground',
                  ),
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: cs.outline.withValues(alpha: .3)),
              ),
            ),
          ),
          ToolButton(
            size: 28,
            label: '撤销',
            icon: CupertinoIcons.arrow_uturn_left,
            onPressed:
                (operations.isEmpty && active?.tool != MarkTool.line) || locked
                ? null
                : undoOne,
          ),
          ToolButton(
            size: 28,
            label: '重做',
            icon: CupertinoIcons.arrow_uturn_right,
            onPressed: redoOperations.isEmpty || locked ? null : redoOne,
          ),
        ]),
        toolGroup('输出操作', [
          ToolButton(
            size: 28,
            label: '取消 · Esc',
            icon: CupertinoIcons.xmark,
            onPressed: locked ? null : widget.controller.discard,
          ),
          ToolButton(
            size: 28,
            label: '保存到文件',
            icon: CupertinoIcons.square_arrow_down,
            onPressed: locked || active?.tool == MarkTool.line
                ? null
                : () => finish(true),
          ),
          ToolButton(
            size: 28,
            label: '图钉暂存 · F',
            icon: CupertinoIcons.pin,
            onPressed: locked || image == null || active?.tool == MarkTool.line
                ? null
                : () => finish(false, pin: true),
          ),
          ToolButton(
            size: 28,
            label: '复制到剪贴板 · Enter',
            icon: CupertinoIcons.check_mark,
            primary: true,
            onPressed: locked || image == null || active?.tool == MarkTool.line
                ? null
                : () => finish(false),
          ),
        ]),
      ],
    );
    final inspectorSection = StateTransition(
      child: inspector is SizedBox
          ? inspector
          : ToolbarInspectorSurface(
              key: ValueKey(
                scanningQr
                    ? 'qr-loading'
                    : qrCodes != null || qrFailure != null
                    ? 'qr'
                    : recognizingText
                    ? 'ocr-loading'
                    : ocrFailure != null
                    ? 'ocr-failure'
                    : ocrSelection != null
                    ? 'ocr'
                    : tool == MarkTool.text
                    ? 'text'
                    : tool == MarkTool.select
                    ? 'select'
                    : isPrivacyBrush(tool)
                    ? 'privacy'
                    : 'stroke',
              ),
              child: inspector,
            ),
    );
    final colorSection = StateTransition(
      child: colorPanel == null
          ? const SizedBox.shrink(key: ValueKey('closed-colors'))
          : ToolbarInspectorSurface(
              key: ValueKey(colorPanel),
              title: colorPanel == 'background' ? '文字背景' : '标注颜色',
              child: ColorRow(
                label: colorPanel == 'background' ? '背景颜色' : '标注颜色',
                value: colorPanel == 'background' ? currentBackground : color,
                clear: colorPanel == 'background',
                onChanged: (v) {
                  if (colorPanel == 'background') {
                    chooseTextBackground(v);
                  } else {
                    textStyleChanged(() => color = v);
                  }
                },
              ),
            ),
    );
    return GlassPanel(
      key: toolbarKey,
      tintOpacity: Theme.of(context).brightness == Brightness.dark ? .90 : .92,
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (toolbarSide == ToolbarSide.above) ...[
            inspectorSection,
            colorSection,
          ],
          mainHeader,
          mainTools,
          if (toolbarSide != ToolbarSide.above) ...[
            inspectorSection,
            colorSection,
          ],
          if (loadError != null || widget.controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                loadError ?? widget.controller.error!,
                style: TextStyle(color: cs.error, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: textAnchor != null || translationOpen
          ? {}
          : {
              const SingleActivator(LogicalKeyboardKey.keyI): () =>
                  startColorPicker(),
              const SingleActivator(LogicalKeyboardKey.keyF): () =>
                  finish(false, pin: true),
              const SingleActivator(LogicalKeyboardKey.escape): escape,
              const SingleActivator(LogicalKeyboardKey.enter): enter,
              const SingleActivator(LogicalKeyboardKey.keyC, control: true):
                  copyOrFinish,
              const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
                  copyOrFinish,
              const SingleActivator(
                LogicalKeyboardKey.keyS,
                control: true,
              ): () =>
                  finish(true),
              const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
                  finish(true),
              const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                  undoOne,
              const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
                  undoOne,
              const SingleActivator(
                LogicalKeyboardKey.keyZ,
                control: true,
                shift: true,
              ): redoOne,
              const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                shift: true,
              ): redoOne,
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  moveSelection(-1, 0),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  moveSelection(1, 0),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  moveSelection(0, -1),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  moveSelection(0, 1),
              const SingleActivator(
                LogicalKeyboardKey.arrowLeft,
                shift: true,
              ): () =>
                  moveSelection(-10, 0),
              const SingleActivator(
                LogicalKeyboardKey.arrowRight,
                shift: true,
              ): () =>
                  moveSelection(10, 0),
              const SingleActivator(
                LogicalKeyboardKey.arrowUp,
                shift: true,
              ): () =>
                  moveSelection(0, -10),
              const SingleActivator(
                LogicalKeyboardKey.arrowDown,
                shift: true,
              ): () =>
                  moveSelection(0, 10),
              const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                  selectAllTextOrRegion,
              const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
                  selectAllTextOrRegion,
              for (final shift in [false, true])
                for (final entry in {
                  LogicalKeyboardKey.keyW: const Offset(0, -1),
                  LogicalKeyboardKey.keyA: const Offset(-1, 0),
                  LogicalKeyboardKey.keyS: const Offset(0, 1),
                  LogicalKeyboardKey.keyD: const Offset(1, 0),
                }.entries)
                  SingleActivator(entry.key, shift: shift): () => nudgeCursor(
                    entry.value.dx.toInt(),
                    entry.value.dy.toInt(),
                  ),
              for (final entry in {
                LogicalKeyboardKey.keyV: MarkTool.select,
                LogicalKeyboardKey.keyQ: MarkTool.arrow,
                LogicalKeyboardKey.keyG: MarkTool.line,
                LogicalKeyboardKey.keyP: MarkTool.pen,
                LogicalKeyboardKey.keyR: MarkTool.rectangle,
                LogicalKeyboardKey.keyO: MarkTool.circle,
                LogicalKeyboardKey.keyL: MarkTool.ellipse,
                LogicalKeyboardKey.keyT: MarkTool.text,
                LogicalKeyboardKey.keyB: privacyTool,
              }.entries)
                SingleActivator(entry.key): () => chooseTool(entry.value),
            },
      child: Focus(
        focusNode: focus,
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shownMarks = visibleMarks.toSet();
            final sx = constraints.maxWidth / widget.clip.width,
                sy = constraints.maxHeight / widget.clip.height;
            Offset point(Offset p) => Offset(
              (p.dx / sx).clamp(0, bounds.right),
              (p.dy / sy).clamp(0, bounds.bottom),
            );
            final showBrushCursor =
                cursor != null &&
                region != null &&
                region!.contains(cursor!) &&
                hasBrushCursor(tool) &&
                ocrSelection == null &&
                colorPicker == null &&
                qrCodes == null &&
                !(isPrivacyBrush(tool) &&
                    privacyInteraction == PrivacyInteraction.rectangle) &&
                !locked &&
                textAnchor == null;
            final selected =
                colorPicker != null ||
                    preparingColor ||
                    widget.clip.mode == 'color'
                ? bounds
                : region ?? hovered;
            final preview = active?.tool == MarkTool.line
                ? Mark(MarkTool.line, color, stroke, active!.points)
                : active;
            final textPointerHit = transformingTextIndex != null
                ? (
                    index: transformingTextIndex!,
                    kind: textDragKind,
                    handle: textDragHandle,
                  )
                : cursor == null
                ? null
                : textHit(cursor!, 10 / sx);
            final screenRect = selected == null
                ? null
                : Rect.fromLTRB(
                    selected.left * sx,
                    selected.top * sy,
                    selected.right * sx,
                    selected.bottom * sy,
                  );
            final viewport = Offset.zero & constraints.biggest;
            final prompt = textPromptShape;
            final promptBounds = prompt == null
                ? null
                : shapeActionBounds(prompt).intersect(region ?? bounds);
            final promptRect = promptBounds == null
                ? null
                : Rect.fromLTRB(
                    promptBounds.left * sx,
                    promptBounds.top * sy,
                    promptBounds.right * sx,
                    promptBounds.bottom * sy,
                  );
            if (textPromptVisible ||
                readingActive ||
                toolbarManualAnchor != null) {
              measureToolbarForOverlays();
            }
            final displayRects = widget.clip.screens
                .map(
                  (r) => Rect.fromLTRB(
                    r.left * sx,
                    r.top * sy,
                    r.right * sx,
                    r.bottom * sy,
                  ),
                )
                .toList();
            final currentScreen = toolbarScreen(
              screenRect ?? viewport,
              displayRects,
              viewport,
            );
            final reservedToolbarHeight = math.min(
              currentScreen.height - 24,
              (currentScreen.width < 600 ? 320.0 : 240.0) *
                  math.max(1, MediaQuery.textScalerOf(context).scale(12) / 12),
            );
            if (screenRect != null &&
                (toolbarAnchorSelection != screenRect ||
                    toolbarAnchorScreen != currentScreen)) {
              toolbarSide = chooseToolbarSide(
                screenRect,
                currentScreen,
                Size(
                  math.min(650, currentScreen.width - 24),
                  reservedToolbarHeight,
                ),
              );
              if (toolbarAnchorSelection != screenRect) {
                toolbarManualAnchor = null;
              }
              toolbarAnchorSelection = screenRect;
              toolbarAnchorScreen = currentScreen;
            }
            // Native bridges return the primary display first. The session hint
            // stays there even when the pointer or selection moves to another screen.
            final hintScreen = displayRects.isEmpty
                ? viewport
                : displayRects.first.intersect(viewport);
            final readingRect = readingActive && screenRect != null
                ? translationReadingPosition == null
                      ? translationReadingRect(
                          screenRect,
                          currentScreen,
                          toolbar: measuredToolbar,
                        )
                      : clampTranslationReadingRect(
                          translationReadingPosition!,
                          currentScreen,
                        )
                : null;
            return Stack(
              key: viewportKey,
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerCancel: (_) {
                      if (active?.tool == MarkTool.line) cancelLine();
                      if (transformingTextIndex != null) {
                        setState(cancelTextTransform);
                      }
                    },
                    child: MouseRegion(
                      cursor: textPointerHit != null
                          ? textCursor(textPointerHit)
                          : showBrushCursor
                          ? SystemMouseCursors.none
                          : tool == MarkTool.select
                          ? SystemMouseCursors.precise
                          : tool == MarkTool.text
                          ? SystemMouseCursors.text
                          : SystemMouseCursors.precise,
                      onExit: (_) => setState(() {
                        cursor = null;
                        hovered = null;
                      }),
                      onHover: (e) => hoverAt(point(e.localPosition)),
                      child: GestureDetector(
                        dragStartBehavior: DragStartBehavior.down,
                        onPanStart: locked
                            ? null
                            : (d) => begin(point(d.localPosition), 10 / sx),
                        onPanUpdate: locked
                            ? null
                            : (d) => update(point(d.localPosition)),
                        onPanEnd: locked ? null : (_) => end(),
                        onPanCancel: () {
                          // A completed tap also rejects the pan recognizer.
                          // Preserve the first endpoint while that tap commits.
                          if (active?.tool == MarkTool.line && !draggingLine) {
                            return;
                          }
                          setState(() {
                            cancelTextTransform();
                            if (dragStart != null) region = dragRegion;
                            dragStart = null;
                            active = null;
                            draggingLine = false;
                          });
                        },
                        onTapUp: locked
                            ? null
                            : (d) {
                                final p = point(d.localPosition);
                                dismissTextPrompt();
                                if (textAnchor != null) {
                                  commitText();
                                  return;
                                }
                                if (tool == MarkTool.line && region != null) {
                                  tapLine(p);
                                  return;
                                }
                                final hit = textHit(p, 10 / sx);
                                if (hit != null) {
                                  setState(() => selectedTextIndex = hit.index);
                                  if (hit.kind != 'rotate' &&
                                      (Offset.zero &
                                              marks[hit.index].textBoxSize)
                                          .contains(
                                            textToLocal(marks[hit.index], p),
                                          )) {
                                    tool = MarkTool.text;
                                    addText(p);
                                  }
                                  return;
                                }
                                final target = region == null
                                    ? windowAt(p)
                                    : null;
                                if (target != null) {
                                  focus.requestFocus();
                                  selectSmartRegion(p);
                                  return;
                                }
                                begin(p, 10 / sx);
                                end();
                              },
                        onSecondaryTap: locked
                            ? null
                            : widget.controller.discard,
                        child: CustomPaint(
                          painter: SelectionPainter(
                            image,
                            [
                              for (int i = 0; i < marks.length; i++)
                                if (i != editingTextIndex &&
                                    shownMarks.contains(marks[i]))
                                  marks[i],
                            ],
                            preview,
                            selected,
                            region != null && tool == MarkTool.select,
                            mosaic: mosaic,
                            showSelection:
                                colorPicker == null &&
                                !preparingColor &&
                                widget.clip.mode != 'color',
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
                if (region != null && translatingImage)
                  Positioned.fromRect(
                    rect: Rect.fromLTWH(
                      region!.left * sx,
                      region!.top * sy,
                      region!.width * sx,
                      region!.height * sy,
                    ),
                    child: ClipRect(
                      child: OcrScanOverlay(
                        label: imageTranslationStatus ?? '正在翻译',
                      ),
                    ),
                  ),
                if (region != null &&
                    !translatingImage &&
                    (recognizingText || ocrSelection != null))
                  Positioned(
                    left: region!.left * sx,
                    top: region!.top * sy,
                    width: region!.width * sx,
                    height: region!.height * sy,
                    child: ClipRect(
                      child: recognizingText
                          ? const OcrScanOverlay(key: ValueKey('ocr-scan'))
                          : OcrTextOverlay(
                              key: const ValueKey('ocr-text-overlay'),
                              selection: ocrSelection!,
                            ),
                    ),
                  ),
                if (region != null && (scanningQr || qrCodes != null))
                  Positioned(
                    left: region!.left * sx,
                    top: region!.top * sy,
                    width: region!.width * sx,
                    height: region!.height * sy,
                    child: ClipRect(
                      child: scanningQr
                          ? const OcrScanOverlay(label: '正在扫描选区二维码')
                          : QrOverlay(
                              codes: qrCodes!,
                              opening: openingQr,
                              onOpen: openQr,
                              onInspect: (index) =>
                                  openQr(index, inspect: true),
                            ),
                    ),
                  ),
                if (colorPicker != null)
                  Positioned.fill(
                    child: ColorPickerOverlay(
                      picker: colorPicker!,
                      screens: widget.clip.screens,
                      onClose: closeColorPicker,
                      onPicked: (sample) {
                        if (widget.clip.mode == 'color') {
                          widget.controller.fixScreenColor(sample);
                        }
                      },
                    ),
                  ),
                if (active?.tool == MarkTool.line)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        key: const ValueKey('line-start-anchor'),
                        painter: BrushCursorPainter(
                          center: Offset(
                            active!.points.first.dx * sx,
                            active!.points.first.dy * sy,
                          ),
                          diameter: 7,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                if (selectedText != null &&
                    ocrSelection == null &&
                    qrCodes == null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: TextTransformPainter(
                          selectedText!,
                          sx,
                          sy,
                          rotationDistance: 26 / sx,
                        ),
                      ),
                    ),
                  ),
                if (screenRect != null &&
                    dragStart == null &&
                    !MediaQuery.disableAnimationsOf(context))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey((screenRect, region != null)),
                          tween: Tween(begin: 0, end: 1),
                          duration: Duration(
                            milliseconds: region == null ? 120 : 180,
                          ),
                          curve: Curves.easeOutCubic,
                          builder: (context, progress, _) => CustomPaint(
                            painter: SelectionFeedbackPainter(
                              rect: screenRect,
                              progress: progress,
                              confirmed: region != null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (showBrushCursor)
                  Positioned.fromRect(
                    rect: Rect.fromLTRB(
                      region!.left * sx,
                      region!.top * sy,
                      region!.right * sx,
                      region!.bottom * sy,
                    ),
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: ClipRect(
                          child: CustomPaint(
                            painter: BrushCursorPainter(
                              center: Offset(
                                (cursor!.dx - region!.left) * sx,
                                (cursor!.dy - region!.top) * sy,
                              ),
                              diameter:
                                  brushDiameter(
                                    preview?.tool ?? tool,
                                    preview?.width ?? stroke,
                                  ) *
                                  sx,
                              verticalDiameter:
                                  brushDiameter(
                                    preview?.tool ?? tool,
                                    preview?.width ?? stroke,
                                  ) *
                                  sy,
                              color: isPrivacyBrush(tool)
                                  ? Colors.white
                                  : preview?.color ?? color,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (image != null &&
                    cursor != null &&
                    widget.clip.mode != 'window' &&
                    (hovered == null || region != null) &&
                    (region == null || dragStart != null))
                  Positioned(
                    left: (cursor!.dx * sx + 24)
                        .clamp(8.0, math.max(8.0, constraints.maxWidth - 148))
                        .toDouble(),
                    top: (cursor!.dy * sy + 24)
                        .clamp(8.0, math.max(8.0, constraints.maxHeight - 180))
                        .toDouble(),
                    child: IgnorePointer(
                      child: Material(
                        color: const Color(0xff202636),
                        borderRadius: BorderRadius.circular(10),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CustomPaint(
                              size: const Size(132, 132),
                              painter: LoupePainter(image!, cursor!),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                '${cursor!.dx.round()}, ${cursor!.dy.round()}${region == null ? '' : ' · ${region!.width.round()}×${region!.height.round()}'}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (textAnchor != null && region != null)
                  Positioned.fromRect(
                    rect: Rect.fromLTRB(
                      region!.left * sx,
                      region!.top * sy,
                      region!.right * sx,
                      region!.bottom * sy,
                    ),
                    child: ClipRect(
                      child: LayoutBuilder(
                        builder: (context, _) {
                          final draft = draftText();
                          final tp = draft.textPainter;
                          final available = math.max(
                            1.0,
                            (region!.right - textAnchor!.dx) * sx,
                          );
                          final width = math.min(
                            available,
                            draft.textBoxSize.width * sx + 3,
                          );
                          final height =
                              math.max(
                                draft.textBoxSize.height,
                                tp.height + draft.padding * 2,
                              ) *
                              sy;
                          return Stack(
                            children: [
                              Positioned(
                                left:
                                    (draft.points.first.dx - region!.left) * sx,
                                top: (draft.points.first.dy - region!.top) * sy,
                                width: width,
                                height: height,
                                child: Transform(
                                  alignment: Alignment.center,
                                  transform: Matrix4.identity()
                                    ..setEntry(0, 0, math.cos(draft.rotation))
                                    ..setEntry(
                                      0,
                                      1,
                                      -math.sin(draft.rotation) * sx / sy,
                                    )
                                    ..setEntry(
                                      1,
                                      0,
                                      math.sin(draft.rotation) * sy / sx,
                                    )
                                    ..setEntry(1, 1, math.cos(draft.rotation)),
                                  child: CallbackShortcuts(
                                    bindings: {
                                      const SingleActivator(
                                        LogicalKeyboardKey.escape,
                                      ): cancelText,
                                      const SingleActivator(
                                        LogicalKeyboardKey.enter,
                                        control: true,
                                      ): commitText,
                                      const SingleActivator(
                                        LogicalKeyboardKey.enter,
                                        meta: true,
                                      ): commitText,
                                    },
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: textBackground,
                                        border: Border.all(
                                          color: const Color(0xff4d84ff),
                                        ),
                                      ),
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: draft.padding * sx,
                                          vertical: draft.padding * sy,
                                        ),
                                        child: EditableText(
                                          key: const ValueKey(
                                            'inline-annotation-text',
                                          ),
                                          controller: textInput,
                                          focusNode: textFocus,
                                          maxLines: null,
                                          minLines: 1,
                                          cursorWidth: 2,
                                          scrollPhysics:
                                              const NeverScrollableScrollPhysics(),
                                          scrollPadding: EdgeInsets.zero,
                                          textAlign: textAlign,
                                          style: draft.textStyle.copyWith(
                                            fontSize: fontSize * sy,
                                          ),
                                          cursorColor: color,
                                          backgroundCursorColor: Colors.grey,
                                          textScaler: TextScaler.noScaling,
                                          selectionColor: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: .25),
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                if (readingActive && region != null && !translationOpen) ...[
                  Positioned.fromRect(
                    rect: screenRect!,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.text,
                      onHover: (event) {
                        final p = Offset(
                          region!.left + event.localPosition.dx / sx,
                          region!.top + event.localPosition.dy / sy,
                        );
                        for (final passage in readingPassages) {
                          if (passage.box.contains(p)) {
                            selectTranslationPassage(passage.id);
                            break;
                          }
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (event) {
                          final p = Offset(
                            region!.left + event.localPosition.dx / sx,
                            region!.top + event.localPosition.dy / sy,
                          );
                          for (final passage in readingPassages) {
                            if (passage.box.contains(p)) {
                              selectTranslationPassage(passage.id);
                              break;
                            }
                          }
                        },
                        onPanStart: (_) {},
                        child: ClipRect(
                          child: CustomPaint(
                            painter: TranslationSourceHighlight(
                              readingPassages,
                              activeTranslationId,
                              region!,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (translationOpen) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () {},
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: .2),
                      ),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: currentScreen.deflate(16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 780,
                          maxHeight: 660,
                        ),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) => Opacity(
                            opacity: value,
                            child: Transform.scale(
                              scale: .99 + .01 * value,
                              child: child,
                            ),
                          ),
                          child: TranslationPanel(
                            controller: widget.controller.translation,
                            settingsInitially: true,
                            onConfigured: closeTranslation,
                            onClose: closeTranslation,
                            openUrl: widget.controller.bridge.openServiceUrl,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (image == null)
                  const Center(child: CircularProgressIndicator()),
                if (region == null &&
                    colorPicker == null &&
                    !preparingColor &&
                    widget.clip.mode != 'color')
                  Positioned(
                    top: hintScreen.top + 24,
                    left: hintScreen.left + 16,
                    right: viewport.right - hintScreen.right + 16,
                    child: Center(
                      child: GlassPanel(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          children: [
                            Text(
                              widget.clip.mode == 'window'
                                  ? '点击窗口或桌面，随后标注或确认'
                                  : '点击智能选区或拖动框选 · Enter 复制 · Esc 取消',
                              style: const TextStyle(fontSize: 12),
                            ),
                            ToolButton(
                              label: '取消 · Esc',
                              icon: CupertinoIcons.xmark,
                              onPressed: widget.controller.discard,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (region != null &&
                    dragStart == null &&
                    !translationOpen &&
                    colorPicker == null &&
                    !preparingColor)
                  Positioned.fill(
                    child: CustomSingleChildLayout(
                      delegate: ToolbarLayout(
                        selection: screenRect!,
                        screen: currentScreen,
                        side: toolbarSide,
                        reservedHeight: reservedToolbarHeight,
                        manualAnchor: toolbarManualAnchor,
                      ),
                      child: SingleChildScrollView(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 140),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) =>
                              Opacity(opacity: value, child: child),
                          child: IntrinsicWidth(child: buildToolbar(context)),
                        ),
                      ),
                    ),
                  ),
                if (readingActive && region != null && !translationOpen)
                  Positioned.fromRect(
                    rect: readingRect!,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) =>
                          Opacity(opacity: value, child: child),
                      child: TranslationReadingPanel(
                        passages: readingPassages,
                        activeId: activeTranslationId,
                        onSelect: selectTranslationPassage,
                        onClose: toggleTranslationReading,
                        onDragStart: () =>
                            translationReadingPosition = readingRect,
                        onDragUpdate: (delta) {
                          setState(
                            () => translationReadingPosition =
                                clampTranslationReadingRect(
                                  (translationReadingPosition ?? readingRect)
                                      .shift(delta),
                                  currentScreen,
                                ),
                          );
                          scheduleCaptureFrame();
                        },
                      ),
                    ),
                  ),
                if (prompt != null && promptRect != null && region != null)
                  Positioned.fill(
                    child: CustomSingleChildLayout(
                      delegate: ShapeTextPromptLayout(
                        shape: promptRect,
                        screen: toolbarScreen(
                          promptRect,
                          displayRects,
                          viewport,
                        ),
                        toolbar: measuredToolbar,
                      ),
                      child: buildShapeTextPrompt(context, prompt),
                    ),
                  ),
                if (region == null && loadError != null)
                  Center(
                    child: Material(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(loadError!),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class TextTransformPainter extends CustomPainter {
  const TextTransformPainter(
    this.mark,
    this.sx,
    this.sy, {
    required this.rotationDistance,
  });
  final Mark mark;
  final double sx, sy, rotationDistance;

  @override
  void paint(Canvas canvas, Size size) {
    Offset display(Offset p) {
      final world = textToWorld(mark, p);
      return Offset(world.dx * sx, world.dy * sy);
    }

    final handles = textHandles(mark).map(display).toList();
    final outline = Paint()
      ..color = const Color(0xff4d84ff)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(handles[0].dx, handles[0].dy);
    for (final i in [2, 4, 6]) {
      path.lineTo(handles[i].dx, handles[i].dy);
    }
    path.close();
    canvas.drawPath(path, outline);
    final knob = display(Offset(mark.textBoxSize.width / 2, -rotationDistance));
    canvas.drawLine(handles[1], knob, outline);
    for (final point in handles) {
      final rect = Rect.fromCenter(center: point, width: 7, height: 7);
      canvas.drawRect(rect, Paint()..color = Colors.white);
      canvas.drawRect(rect, outline);
    }
    canvas.drawCircle(knob, 5, Paint()..color = Colors.white);
    canvas.drawCircle(knob, 5, outline);
  }

  @override
  bool shouldRepaint(covariant TextTransformPainter oldDelegate) =>
      mark != oldDelegate.mark ||
      sx != oldDelegate.sx ||
      sy != oldDelegate.sy ||
      rotationDistance != oldDelegate.rotationDistance;
}

class SelectionPainter extends CustomPainter {
  SelectionPainter(
    this.image,
    this.marks,
    this.active,
    this.region,
    this.showHandles, {
    this.mosaic,
    this.showSelection = true,
  });
  final ui.Image? image, mosaic;
  final List<Mark> marks;
  final Mark? active;
  final Rect? region;
  final bool showHandles;
  final bool showSelection;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xff111521), BlendMode.src);
    final im = image;
    if (im == null) return;
    final sx = size.width / im.width, sy = size.height / im.height;
    canvas.save();
    canvas.scale(sx, sy);
    canvas.drawImage(im, Offset.zero, Paint());
    if (region != null) {
      canvas.save();
      canvas.clipRect(region!);
      paintCapture(canvas, im, [...marks, ?active], mosaic: mosaic);
      canvas.restore();
    } else {
      canvas.drawImage(im, Offset.zero, Paint());
    }
    canvas.restore();
    // Editing feedback only: the exported privacy region has no outline.
    final draft = active;
    if (region != null &&
        draft != null &&
        isPrivacyBrush(draft.tool) &&
        draft.privacyInteraction == PrivacyInteraction.rectangle &&
        draft.points.length > 1) {
      final area = Rect.fromPoints(draft.points.first, draft.points.last);
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          region!.left * sx,
          region!.top * sy,
          region!.right * sx,
          region!.bottom * sy,
        ),
      );
      final preview = Rect.fromLTRB(
        area.left * sx,
        area.top * sy,
        area.right * sx,
        area.bottom * sy,
      );
      canvas.drawRect(
        preview,
        Paint()
          ..color = Colors.black.withValues(alpha: .6)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke,
      );
      canvas.drawRect(
        preview,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
      canvas.restore();
    }
    if (!showSelection) return;
    final rect = region == null
        ? null
        : Rect.fromLTRB(
            region!.left * sx,
            region!.top * sy,
            region!.right * sx,
            region!.bottom * sy,
          );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (rect != null) path.addRect(rect);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: .4));
    if (rect != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xff4d84ff)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
      if (showHandles) {
        for (final point in [
          rect.topLeft,
          rect.topCenter,
          rect.topRight,
          rect.centerRight,
          rect.bottomRight,
          rect.bottomCenter,
          rect.bottomLeft,
          rect.centerLeft,
        ]) {
          canvas.drawRect(
            Rect.fromCenter(center: point, width: 7, height: 7),
            Paint()..color = Colors.white,
          );
          canvas.drawRect(
            Rect.fromCenter(center: point, width: 7, height: 7),
            Paint()
              ..color = const Color(0xff315cec)
              ..style = PaintingStyle.stroke,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) => true;
}

/// Transient feedback stays outside the exact, immediately updated selection.
class SelectionFeedbackPainter extends CustomPainter {
  const SelectionFeedbackPainter({
    required this.rect,
    required this.progress,
    required this.confirmed,
  });

  final Rect rect;
  final double progress;
  final bool confirmed;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress >= 1) return;
    canvas.drawRect(
      rect.inflate(3),
      Paint()
        ..color = const Color(0xff4d84ff)
            .withValues(alpha: (confirmed ? .65 : .4) * (1 - progress))
        ..strokeWidth = confirmed ? 3 : 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant SelectionFeedbackPainter oldDelegate) =>
      rect != oldDelegate.rect ||
      progress != oldDelegate.progress ||
      confirmed != oldDelegate.confirmed;
}

class LoupePainter extends CustomPainter {
  LoupePainter(this.image, this.point);
  final ui.Image image;
  final Offset point;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff202636),
    );
    canvas.drawImageRect(
      image,
      Rect.fromCenter(center: point, width: 17, height: 17),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
    final pen = Paint()
      ..color = const Color(0xff4885ff)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      pen,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      pen,
    );
    canvas.drawRect(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width / 17,
        height: size.height / 17,
      ),
      pen..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant LoupePainter oldDelegate) =>
      oldDelegate.point != point;
}

/// Editor feedback only; never passed to the PNG compositor.
class BrushCursorPainter extends CustomPainter {
  const BrushCursorPainter({
    required this.center,
    required this.diameter,
    required this.color,
    this.verticalDiameter,
  });
  final Offset center;
  final double diameter;
  final double? verticalDiameter;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(
      center: center,
      width: math.max(2, diameter),
      height: math.max(2, verticalDiameter ?? diameter),
    );
    // A contrasting halo keeps both white and black brush colors visible.
    canvas.drawOval(
      oval,
      Paint()
        ..color = color.computeLuminance() > .45
            ? const Color(0xcc141416)
            : const Color(0xe6ffffff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6,
    );
    canvas.drawOval(
      oval,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant BrushCursorPainter old) =>
      old.center != center ||
      old.diameter != diameter ||
      old.verticalDiameter != verticalDiameter ||
      old.color != color;
}
