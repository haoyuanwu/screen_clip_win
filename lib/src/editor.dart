import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'ui/controls.dart';
import 'ui/toolbar_layout.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'controller.dart' hide Clip;
import 'controller.dart' as model show Clip;

enum MarkTool {
  select,
  pen,
  arrow,
  rectangle,
  circle,
  ellipse,
  text,
  number,
  redact,
  mosaic,
  erase,
  crop,
}

/// Diameter in source pixels, shared by stroke rendering and cursor feedback.
double brushDiameter(MarkTool tool, double width) => switch (tool) {
  MarkTool.arrow ||
  MarkTool.rectangle ||
  MarkTool.circle ||
  MarkTool.ellipse => width * 1.6,
  MarkTool.redact || MarkTool.mosaic || MarkTool.erase => width * 9,
  MarkTool.number => width * 4 + 24,
  _ => width,
};
bool hasBrushCursor(MarkTool tool) => const [
  MarkTool.pen,
  MarkTool.arrow,
  MarkTool.rectangle,
  MarkTool.circle,
  MarkTool.ellipse,
  MarkTool.redact,
  MarkTool.mosaic,
  MarkTool.erase,
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
    this.background = Colors.transparent,
    this.padding = 10,
  });
  final MarkTool tool;
  final Color color;
  final double width;
  final List<Offset> points;
  final String text;
  final int number;
  final double fontSize, maxTextWidth;
  final bool bold, italic, underline;
  final Color background;
  final double padding;
  Size get textBoxSize =>
      Size(textPainter.width + padding * 2, textPainter.height + padding * 2);
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
  TextPainter get textPainter => TextPainter(
    text: TextSpan(text: text, style: textStyle),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxTextWidth);
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
    case MarkTool.erase:
      break; // Blur is composited beneath every annotation by paintCapture.
    case MarkTool.text:
      final size = mark.textBoxSize;
      canvas.drawRRect(
        RRect.fromRectAndRadius(first & size, const Radius.circular(4)),
        Paint()..color = mark.background,
      );
      mark.textPainter.paint(
        canvas,
        first + Offset(mark.padding, mark.padding),
      );
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

/// A swept round brush; erase strokes clear only the currently isolated layer.
void paintMaskStroke(Canvas canvas, Mark mark, {bool erase = false}) {
  final brush = Paint()
    ..color = Colors.white
    ..blendMode = erase ? BlendMode.clear : BlendMode.srcOver
    ..strokeWidth = brushDiameter(mark.tool, mark.width)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
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

/// Fixed visual layers with chronological erasure in each layer. Erasing restores
/// the original screen; later annotations can be drawn over an erased area.
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
      if (isPrivacyBrush(mark.tool) || mark.tool == MarkTool.erase) {
        paintMaskStroke(canvas, mark, erase: mark.tool != effect);
      }
    }
    canvas.restore();
    canvas.restore();
  }
  for (final penLayer in [true, false]) {
    canvas.saveLayer(bounds, Paint());
    for (final mark in marks) {
      if (mark.tool == MarkTool.erase) {
        paintMaskStroke(canvas, mark, erase: true);
      } else if (!isPrivacyBrush(mark.tool) &&
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
  ui.Image? image;
  ui.Image? mosaic;
  MarkTool privacyTool = MarkTool.redact;
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
  final textInput = TextEditingController();
  final textFocus = FocusNode();
  Offset? textAnchor;
  int? editingTextIndex;
  double fontSize = 32;
  Color textBackground = Colors.transparent;
  String? colorPanel;
  bool bold = false, italic = false, underline = false;

  Mark? active;
  Offset? dragStart;
  Offset? cursor;
  Rect? dragRegion;
  String dragKind = 'new';
  int handle = -1;
  bool rendering = false;
  final focus = FocusNode();
  Rect get bounds => Rect.fromLTWH(
    0,
    0,
    widget.clip.width.toDouble(),
    widget.clip.height.toDouble(),
  );
  bool get locked => rendering || widget.controller.busy;
  @override
  void initState() {
    super.initState();
    if (widget.clip.mode == 'screen') region = bounds;
    load();
  }

  Future<void> load() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.clip.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final pixels = await makeMosaicImage(frame.image);
      if (!mounted) {
        pixels.dispose();
        frame.image.dispose();
        return;
      }
      setState(() {
        image = frame.image;
        mosaic = pixels;
      });
    } catch (e) {
      if (mounted) setState(() => loadError = '屏幕载入失败：$e');
    }
  }

  @override
  void dispose() {
    image?.dispose();
    mosaic?.dispose();
    focus.dispose();
    textInput.dispose();
    textFocus.dispose();
    super.dispose();
  }

  void commit() {
    redo.clear();
    selectionRedo.clear();
    redoOperations.clear();
    textRedo.clear();
  }

  void changeRegion(Rect? next) {
    selectionUndo.add(region);
    operations.add(1);
    commit();
    region = next;
  }

  void undoOne() {
    if (locked) return;
    commitText();
    if (operations.isEmpty || locked) return;
    setState(() {
      final selection = operations.removeLast();
      redoOperations.add(selection);
      if (selection == 2) {
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
    commitText();
    if (redoOperations.isEmpty || locked) return;
    setState(() {
      final selection = redoOperations.removeLast();
      operations.add(selection);
      if (selection == 2) {
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
    if (image == null || locked || region == null) return;
    commitText();
    setState(() => rendering = true);
    try {
      final bytes = await renderCapture(image!, marks, region, mosaic: mosaic);
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

  Mark draftText() => Mark(
    MarkTool.text,
    color,
    stroke,
    [textAnchor!],
    text: textInput.text,
    fontSize: fontSize,
    bold: bold,
    italic: italic,
    underline: underline,
    maxTextWidth: math.max(1, region!.right - textAnchor!.dx - 20),
    background: textBackground,
  );
  void commitText() {
    if (textAnchor == null) return;
    final draft = draftText();
    final index = editingTextIndex;
    setState(() {
      if (draft.text.trim().isNotEmpty || index != null) {
        if (index == null) {
          marks.add(draft);
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
              previous.background != draft.background ||
              previous.maxTextWidth != draft.maxTextWidth) {
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

  void addText(Offset point) {
    commitText();
    int? index;
    for (int i = marks.length - 1; i >= 0; i--) {
      final mark = marks[i];
      if (mark.tool == MarkTool.text &&
          (mark.points.first & mark.textBoxSize).inflate(6).contains(point)) {
        index = i;
        break;
      }
    }
    setState(() {
      editingTextIndex = index;
      if (index != null) {
        final mark = marks[index];
        textAnchor = mark.points.first;
        textInput.text = mark.text;
        fontSize = mark.fontSize;
        bold = mark.bold;
        italic = mark.italic;
        underline = mark.underline;
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
    commitText();
    setState(() {
      tool = next;
      if (isPrivacyBrush(next)) privacyTool = next;
      colorPanel = null;
    });
  }

  void textStyleChanged(VoidCallback update) {
    setState(update);
    if (textAnchor != null) textFocus.requestFocus();
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
  void begin(Offset p, double tolerance) {
    if (locked) return;
    cursor = p;
    focus.requestFocus();
    if (tool != MarkTool.text) commitText();
    if (tool == MarkTool.select || tool == MarkTool.crop || region == null) {
      if (widget.clip.mode == 'window' && region == null) {
        final target = windowAt(p);
        if (target != null) setState(() => changeRegion(target));
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
    setState(() => active = Mark(tool, color, stroke, [p]));
  }

  void update(Offset p) {
    cursor = p;
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
    setState(() {
      if (active!.tool == MarkTool.pen ||
          isPrivacyBrush(active!.tool) ||
          active!.tool == MarkTool.erase ||
          active!.points.length == 1) {
        active!.points.add(p);
      } else {
        active!.points[active!.points.length - 1] = p;
      }
    });
  }

  void end() {
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
    setState(() {
      marks.add(active!);
      operations.add(0);
      commit();
      active = null;
    });
  }

  Rect? windowAt(Offset p) {
    for (final r in widget.clip.windows) {
      if (r.contains(p)) return r.intersect(bounds);
    }
    return null;
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
    Widget separator() => Container(
      width: 1,
      height: 17,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      color: cs.outline.withValues(alpha: .18),
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
      child: FineSlider(
        label: label,
        value: value,
        min: min,
        max: max,
        step: step,
        onChanged: locked ? null : onChanged,
      ),
    );
    final inspector = tool == MarkTool.text
        ? Wrap(
            key: const ValueKey('text-inspector'),
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 3,
            runSpacing: 3,
            children: [
              Text(
                '字号',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
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
              separator(),
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
                    color: textBackground,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: cs.outline),
                  ),
                ),
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
        : Row(
            key: ValueKey(
              isPrivacyBrush(tool)
                  ? 'privacy-inspector'
                  : tool == MarkTool.erase
                  ? 'erase-inspector'
                  : 'stroke-inspector',
            ),
            children: [
              if (isShapeTool(tool)) ...[
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
                const SizedBox(width: 4),
              ],
              if (isPrivacyBrush(tool)) ...[
                ToolButton(
                  label: '模糊画笔',
                  selected: tool == MarkTool.redact,
                  onPressed: locked ? null : () => chooseTool(MarkTool.redact),
                  child: const Text('模糊'),
                ),
                ToolButton(
                  label: '马赛克画笔',
                  selected: tool == MarkTool.mosaic,
                  onPressed: locked ? null : () => chooseTool(MarkTool.mosaic),
                  child: const Text('马赛克'),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                isPrivacyBrush(tool)
                    ? '笔刷范围'
                    : tool == MarkTool.erase
                    ? '擦除范围'
                    : '线条粗细',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FineSlider(
                  label: '线条粗细',
                  value: stroke,
                  min: 1,
                  max: 12,
                  onChanged: locked ? null : (v) => setState(() => stroke = v),
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
                      color: isPrivacyBrush(tool) || tool == MarkTool.erase
                          ? Colors.white
                          : color,
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
          );
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(width: 3),
              Text(
                '${region!.width.round()} × ${region!.height.round()}',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 100),
                child: Text(
                  textAnchor == null
                      ? 'Enter 复制'
                      : 'Enter 换行 · Ctrl/⌘+Enter 完成',
                  key: ValueKey(textAnchor != null),
                  style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
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
                          tool = MarkTool.select;
                        });
                      },
              ),
            ],
          ),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in [
                (MarkTool.select, CupertinoIcons.move, '调整选区 · V'),
                (MarkTool.arrow, CupertinoIcons.arrow_up_right, '箭头 · A'),
                (MarkTool.rectangle, CupertinoIcons.square, '矩形 · R'),
                (MarkTool.pen, CupertinoIcons.pencil, '画笔 · P'),
                (MarkTool.text, CupertinoIcons.textformat, '文字 · T'),
                (MarkTool.number, CupertinoIcons.list_number, '序号'),
                (privacyTool, CupertinoIcons.shield_lefthalf_fill, '隐私画笔 · B'),
                (MarkTool.erase, CupertinoIcons.pencil_slash, '橡皮擦 · E'),
              ])
                ToolButton(
                  size: 28,
                  label: entry.$3,
                  icon: entry.$2,
                  selected:
                      tool == entry.$1 ||
                      (entry.$1 == MarkTool.rectangle && isShapeTool(tool)),
                  onPressed: locked ? null : () => chooseTool(entry.$1),
                ),
              separator(),
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
                onPressed: operations.isEmpty || locked ? null : undoOne,
              ),
              ToolButton(
                size: 28,
                label: '重做',
                icon: CupertinoIcons.arrow_uturn_right,
                onPressed: redoOperations.isEmpty || locked ? null : redoOne,
              ),
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
                onPressed: locked ? null : () => finish(true),
              ),
              ToolButton(
                size: 28,
                label: '图钉暂存 · F',
                icon: CupertinoIcons.pin,
                onPressed: locked || image == null
                    ? null
                    : () => finish(false, pin: true),
              ),
              ToolButton(
                size: 28,
                label: '复制到剪贴板 · Enter',
                icon: CupertinoIcons.check_mark,
                primary: true,
                onPressed: locked || image == null ? null : () => finish(false),
              ),
            ],
          ),
          StateTransition(
            child: Padding(
              key: ValueKey(
                tool == MarkTool.text
                    ? 'text'
                    : tool == MarkTool.select
                    ? 'select'
                    : isPrivacyBrush(tool)
                    ? 'privacy'
                    : 'stroke',
              ),
              padding: EdgeInsets.only(top: tool == MarkTool.select ? 0 : 3),
              child: inspector,
            ),
          ),
          StateTransition(
            child: colorPanel == null
                ? const SizedBox.shrink(key: ValueKey('closed-colors'))
                : Padding(
                    key: ValueKey(colorPanel),
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            colorPanel == 'background' ? '背景' : '颜色',
                            style: TextStyle(
                              fontSize: 10,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: ColorRow(
                            label: colorPanel == 'background' ? '背景颜色' : '标注颜色',
                            value: colorPanel == 'background'
                                ? textBackground
                                : color,
                            clear: colorPanel == 'background',
                            onChanged: (v) => textStyleChanged(() {
                              if (colorPanel == 'background') {
                                textBackground = v;
                              } else {
                                color = v;
                              }
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
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
      bindings: textAnchor != null
          ? {}
          : {
              const SingleActivator(LogicalKeyboardKey.keyF): () =>
                  finish(false, pin: true),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  locked ? null : widget.controller.discard(),
              const SingleActivator(LogicalKeyboardKey.enter): () =>
                  finish(false),
              const SingleActivator(
                LogicalKeyboardKey.keyC,
                control: true,
              ): () =>
                  finish(false),
              const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
                  finish(false),
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
              const SingleActivator(
                LogicalKeyboardKey.keyA,
                control: true,
              ): () =>
                  setState(() => changeRegion(bounds)),
              const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
                  setState(() => changeRegion(bounds)),
              for (final entry in {
                LogicalKeyboardKey.keyV: MarkTool.select,
                LogicalKeyboardKey.keyA: MarkTool.arrow,
                LogicalKeyboardKey.keyP: MarkTool.pen,
                LogicalKeyboardKey.keyR: MarkTool.rectangle,
                LogicalKeyboardKey.keyO: MarkTool.circle,
                LogicalKeyboardKey.keyL: MarkTool.ellipse,
                LogicalKeyboardKey.keyT: MarkTool.text,
                LogicalKeyboardKey.keyB: privacyTool,
                LogicalKeyboardKey.keyE: MarkTool.erase,
              }.entries)
                SingleActivator(entry.key): () => chooseTool(entry.value),
            },
      child: Focus(
        focusNode: focus,
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
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
                !locked &&
                textAnchor == null;
            final selected = region ?? hovered;
            final screenRect = selected == null
                ? null
                : Rect.fromLTRB(
                    selected.left * sx,
                    selected.top * sy,
                    selected.right * sx,
                    selected.bottom * sy,
                  );
            final viewport = Offset.zero & constraints.biggest;
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
            return Stack(
              children: [
                Positioned.fill(
                  child: MouseRegion(
                    cursor: showBrushCursor
                        ? SystemMouseCursors.none
                        : tool == MarkTool.select
                        ? SystemMouseCursors.precise
                        : tool == MarkTool.text
                        ? SystemMouseCursors.text
                        : SystemMouseCursors.precise,
                    onExit: (_) => setState(() => cursor = null),
                    onHover: (e) {
                      setState(() {
                        cursor = point(e.localPosition);
                        if (region == null && widget.clip.mode == 'window') {
                          hovered = windowAt(cursor!);
                        }
                      });
                    },
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
                        setState(() {
                          if (dragStart != null) region = dragRegion;
                          dragStart = null;
                          active = null;
                        });
                      },
                      onTapUp: locked
                          ? null
                          : (d) {
                              begin(point(d.localPosition), 10 / sx);
                              end();
                            },
                      onSecondaryTap: locked ? null : widget.controller.discard,
                      child: CustomPaint(
                        painter: SelectionPainter(
                          image,
                          [
                            for (int i = 0; i < marks.length; i++)
                              if (i != editingTextIndex) marks[i],
                          ],
                          active,
                          selected,
                          region != null && tool == MarkTool.select,
                          mosaic: mosaic,
                        ),
                        child: const SizedBox.expand(),
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
                                    active?.tool ?? tool,
                                    active?.width ?? stroke,
                                  ) *
                                  sx,
                              verticalDiameter:
                                  brushDiameter(
                                    active?.tool ?? tool,
                                    active?.width ?? stroke,
                                  ) *
                                  sy,
                              color:
                                  isPrivacyBrush(tool) || tool == MarkTool.erase
                                  ? Colors.white
                                  : active?.color ?? color,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (image != null &&
                    cursor != null &&
                    widget.clip.mode != 'window' &&
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
                            math.max(
                              math.min(100.0, available),
                              (tp.width + 26) * sx,
                            ),
                          );
                          final height = math.min(
                            (math.max(fontSize * 1.3, tp.height) + 24) * sy,
                            math.max(
                              1.0,
                              (region!.bottom - textAnchor!.dy) * sy,
                            ),
                          );
                          return Stack(
                            children: [
                              Positioned(
                                left: (textAnchor!.dx - region!.left) * sx,
                                top: (textAnchor!.dy - region!.top) * sy,
                                width: width,
                                height: height,
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
                                        horizontal: 10 * sx,
                                        vertical: 10 * sy,
                                      ),
                                      child: EditableText(
                                        key: const ValueKey(
                                          'inline-annotation-text',
                                        ),
                                        controller: textInput,
                                        focusNode: textFocus,
                                        maxLines: null,
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
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                if (image == null)
                  const Center(child: CircularProgressIndicator()),
                if (region == null)
                  Positioned(
                    top: 24,
                    left: 16,
                    right: 16,
                    child: Center(
                      child: GlassPanel(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          children: [
                            Text(
                              widget.clip.mode == 'window'
                                  ? '点击窗口，随后标注或确认'
                                  : '拖动框选 · Enter 复制 · Esc 取消',
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
                if (region != null && dragStart == null)
                  Positioned.fill(
                    child: CustomSingleChildLayout(
                      delegate: ToolbarLayout(
                        selection: screenRect!,
                        screen: currentScreen,
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
                          child: buildToolbar(context),
                        ),
                      ),
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

class SelectionPainter extends CustomPainter {
  SelectionPainter(
    this.image,
    this.marks,
    this.active,
    this.region,
    this.showHandles, {
    this.mosaic,
  });
  final ui.Image? image, mosaic;
  final List<Mark> marks;
  final Mark? active;
  final Rect? region;
  final bool showHandles;
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
          ..strokeWidth = 1.5
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
