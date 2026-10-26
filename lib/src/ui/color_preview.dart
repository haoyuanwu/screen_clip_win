import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/services.dart';

import '../color_picker.dart';
import 'controls.dart';

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
  });
  final ScreenColorPicker picker;
  final VoidCallback onClose;
  final ValueChanged<SampledColor> onPicked;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      Offset source(Offset point) => Offset(
        point.dx / constraints.maxWidth * picker.pixels.width,
        point.dy / constraints.maxHeight * picker.pixels.height,
      );
      return ListenableBuilder(
        listenable: picker,
        builder: (context, _) {
          final width = math.min(280.0, constraints.maxWidth - 20);
          final x =
              picker.position.dx / picker.pixels.width * constraints.maxWidth;
          final y =
              picker.position.dy / picker.pixels.height * constraints.maxHeight;
          final left =
              (x + 20 + width <= constraints.maxWidth ? x + 20 : x - width - 20)
                  .clamp(
                    10.0,
                    math.max(10.0, constraints.maxWidth - width - 10),
                  );
          final height = picker.fixed ? 300.0 : 272.0;
          final top =
              (y + 20 + height <= constraints.maxHeight
                      ? y + 20
                      : y - height - 20)
                  .clamp(
                    10.0,
                    math.max(10.0, constraints.maxHeight - height - 10),
                  );
          return Stack(
            children: [
              Positioned.fill(
                child: MouseRegion(
                  cursor: picker.fixed
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.precise,
                  onHover: (e) => picker.move(source(e.localPosition)),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      if (e.buttons == kPrimaryMouseButton && !picker.fixed) {
                        picker.move(source(e.localPosition));
                        picker.freeze();
                        onPicked(picker.sample);
                      }
                    },
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned(
                left: left.toDouble(),
                top: top.toDouble(),
                width: width,
                child: IgnorePointer(
                  ignoring: !picker.fixed,
                  child: ColorPreviewCard(
                    sample: picker.sample,
                    fixed: picker.fixed,
                    onClose: onClose,
                    onResample: picker.fixed ? picker.resume : null,
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
