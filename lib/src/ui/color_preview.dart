import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/services.dart';

import '../color_picker.dart';
import 'controls.dart';

final liveColorPreviewKey = GlobalKey(debugLabel: 'liveColorPreview');

/// A standalone color popup whose native window follows the card's content.
class FixedColorPreview extends StatefulWidget {
  const FixedColorPreview({
    super.key,
    required this.sample,
    required this.onSizeChanged,
    this.onClose,
    this.onResample,
  });
  final SampledColor sample;
  final ValueChanged<Size> onSizeChanged;
  final VoidCallback? onClose, onResample;
  @override
  State<FixedColorPreview> createState() => _FixedColorPreviewState();
}

class _FixedColorPreviewState extends State<FixedColorPreview> {
  final cardKey = GlobalKey();
  Size? lastSize;
  bool measuring = false;
  @override
  void initState() {
    super.initState();
    measure();
  }

  void measure() {
    if (measuring) return;
    measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      measuring = false;
      if (!mounted) return;
      final size = cardKey.currentContext?.size;
      if (size == null || size.isEmpty || size == lastSize) return;
      lastSize = size;
      widget.onSizeChanged(size);
    });
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        measure();
        return false;
      },
      child: SingleChildScrollView(
        child: SizeChangedLayoutNotifier(
          child: ColorPreviewCard(
            key: cardKey,
            sample: widget.sample,
            fixed: true,
            onClose: widget.onClose,
            onResample: widget.onResample,
          ),
        ),
      ),
    ),
  );
}

class ColorPreviewCard extends StatefulWidget {
  const ColorPreviewCard({
    super.key,
    required this.sample,
    required this.fixed,
    this.onClose,
    this.onResample,
  });
  final SampledColor sample;
  final bool fixed;
  final VoidCallback? onClose, onResample;
  @override
  State<ColorPreviewCard> createState() => _ColorPreviewCardState();
}

class _ColorPreviewCardState extends State<ColorPreviewCard> {
  String? copied, error;
  @override
  void didUpdateWidget(covariant ColorPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sample.hex != widget.sample.hex ||
        oldWidget.fixed != widget.fixed) {
      copied = null;
      error = null;
    }
  }

  Future<void> copy(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) {
        setState(() {
          copied = value;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget valueRow((String, String) entry) => Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            entry.$1,
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            entry.$2,
            style: const TextStyle(
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (widget.fixed)
          Icon(
            copied == entry.$2
                ? Icons.check_rounded
                : Icons.content_copy_rounded,
            size: 13,
          ),
      ],
    );
    return GlassPanel(
      shadow: !widget.fixed,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.colorize_rounded, size: 16),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.fixed ? '已固定颜色' : '屏幕取色',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (widget.onClose != null)
                ToolButton(
                  size: 24,
                  label: '关闭取色预览',
                  icon: Icons.close_rounded,
                  onPressed: widget.onClose,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.sample.neighborhood case final ColorPixels pixels)
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: CustomPaint(
                    key: const ValueKey('color-pixel-magnifier'),
                    size: const Size(104, 104),
                    painter: ColorMagnifierPainter(pixels),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 60,
                        decoration: BoxDecoration(
                          color: widget.sample.color,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: cs.outline.withValues(alpha: .25),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '中心像素',
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      if (widget.sample.position case final Offset point)
                        Text(
                          '${point.dx.toInt()}, ${point.dy.toInt()}',
                          style: TextStyle(
                            fontSize: 10,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            )
          else
            Container(
              height: 42,
              decoration: BoxDecoration(
                color: widget.sample.color,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: cs.outline.withValues(alpha: .25)),
              ),
            ),
          const SizedBox(height: 8),
          for (final entry in [
            ('HEX', widget.sample.hex),
            ('sRGB · 0–255', widget.sample.rgb),
          ])
            widget.fixed
                ? ToolButton(
                    size: 30,
                    label: '复制 ${entry.$1} 色值',
                    onPressed: () => copy(entry.$2),
                    child: valueRow(entry),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 7,
                    ),
                    child: valueRow(entry),
                  ),
          const SizedBox(height: 5),
          Text(
            error ??
                (copied != null
                    ? '已复制 $copied'
                    : widget.fixed
                    ? '点击色值即可复制'
                    : '移动鼠标取色 · 点击固定 · Esc 取消'),
            style: TextStyle(
              fontSize: 10,
              color: error != null ? cs.error : cs.onSurfaceVariant,
            ),
          ),
          if (widget.fixed && widget.onResample != null)
            Align(
              alignment: Alignment.centerRight,
              child: ToolButton(
                label: '重新取色',
                size: 28,
                onPressed: widget.onResample,
                child: const Text('重新取色', style: TextStyle(fontSize: 11)),
              ),
            ),
        ],
      ),
    );
  }
}

class ColorPickerOverlay extends StatelessWidget {
  const ColorPickerOverlay({
    super.key,
    required this.picker,
    required this.onClose,
    required this.onPicked,
    this.screens = const [],
  });
  final ScreenColorPicker picker;
  final VoidCallback onClose;
  final ValueChanged<SampledColor> onPicked;
  final List<Rect> screens;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      Offset source(Offset point) => Offset(
        point.dx / constraints.maxWidth * picker.pixels.width,
        point.dy / constraints.maxHeight * picker.pixels.height,
      );
      void move(Offset local) {
        final point = source(local);
        if (screens.isEmpty || screens.any((r) => r.contains(point))) {
          picker.move(point);
        }
      }

      return ListenableBuilder(
        listenable: picker,
        builder: (context, _) {
          final x =
              picker.position.dx / picker.pixels.width * constraints.maxWidth;
          final y =
              picker.position.dy / picker.pixels.height * constraints.maxHeight;
          final viewport = Offset.zero & constraints.biggest;
          final displays = screens
              .map(
                (r) => Rect.fromLTWH(
                  r.left / picker.pixels.width * constraints.maxWidth,
                  r.top / picker.pixels.height * constraints.maxHeight,
                  r.width / picker.pixels.width * constraints.maxWidth,
                  r.height / picker.pixels.height * constraints.maxHeight,
                ),
              )
              .toList();
          final display = colorPickerScreen(Offset(x, y), displays, viewport);
          return Stack(
            children: [
              Positioned.fill(
                child: MouseRegion(
                  cursor: picker.fixed
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.precise,
                  onHover: (e) => move(e.localPosition),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      if (e.buttons == kPrimaryMouseButton && !picker.fixed) {
                        final point = source(e.localPosition);
                        if (screens.isNotEmpty &&
                            !screens.any((r) => r.contains(point))) {
                          return;
                        }
                        picker.move(point);
                        picker.freeze();
                        onPicked(picker.sample);
                      }
                    },
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: CustomSingleChildLayout(
                  delegate: ColorPreviewLayout(
                    screen: display,
                    pointer: Offset(x, y),
                  ),
                  child: IgnorePointer(
                    key: liveColorPreviewKey,
                    ignoring: !picker.fixed,
                    child: SingleChildScrollView(
                      child: ColorPreviewCard(
                        sample: picker.sample,
                        fixed: picker.fixed,
                        onClose: onClose,
                        onResample: picker.fixed ? picker.resume : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

Rect colorPickerScreen(Offset point, List<Rect> screens, Rect viewport) {
  final available = screens
      .map((r) => r.intersect(viewport))
      .where((r) => !r.isEmpty)
      .toList();
  for (final screen in available) {
    if (screen.contains(point)) return screen;
  }
  if (available.isEmpty) return viewport;
  double distance(Rect r) =>
      (Offset(
                point.dx.clamp(r.left, r.right),
                point.dy.clamp(r.top, r.bottom),
              ) -
              point)
          .distanceSquared;
  return available.reduce((a, b) => distance(a) <= distance(b) ? a : b);
}

/// Use the measured card height, including larger fonts, to avoid screen seams.
class ColorPreviewLayout extends SingleChildLayoutDelegate {
  ColorPreviewLayout({required this.screen, required this.pointer});
  final Rect screen;
  final Offset pointer;
  Rect get safe =>
      screen.deflate(math.min(10, math.min(screen.width, screen.height) / 4));
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: math.min(280, safe.width),
        maxWidth: math.min(280, safe.width),
        maxHeight: safe.height,
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = pointer.dx + 20 + childSize.width <= safe.right
        ? pointer.dx + 20
        : pointer.dx - childSize.width - 20;
    final y = pointer.dy + 20 + childSize.height <= safe.bottom
        ? pointer.dy + 20
        : pointer.dy - childSize.height - 20;
    return Offset(
      x.clamp(safe.left, math.max(safe.left, safe.right - childSize.width)),
      y.clamp(safe.top, math.max(safe.top, safe.bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(covariant ColorPreviewLayout oldDelegate) =>
      screen != oldDelegate.screen || pointer != oldDelegate.pointer;
}

/// Nearest-neighbor pixel preview shares the exact sRGB sampling buffer.
class ColorMagnifierPainter extends CustomPainter {
  const ColorMagnifierPainter(this.pixels);
  final ColorPixels pixels;
  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = size.width / pixels.width,
        cellHeight = size.height / pixels.height;
    canvas.clipRect(Offset.zero & size);
    for (int y = 0; y < pixels.height; y++) {
      for (int x = 0; x < pixels.width; x++) {
        canvas.drawRect(
          Rect.fromLTWH(x * cellWidth, y * cellHeight, cellWidth, cellHeight),
          Paint()
            ..isAntiAlias = false
            ..color = pixels.at(Offset(x.toDouble(), y.toDouble())).color,
        );
      }
    }
    final center = Rect.fromLTWH(
      (pixels.width ~/ 2) * cellWidth,
      (pixels.height ~/ 2) * cellHeight,
      cellWidth,
      cellHeight,
    );
    canvas.drawRect(
      center,
      Paint()
        ..color = const Color(0xe6222222)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRect(
      center,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant ColorMagnifierPainter oldDelegate) =>
      pixels != oldDelegate.pixels;
}
