import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;

import '../ocr_selection.dart';

abstract final class OcrColors {
  static const scan = Color(0xffffdfab);
  static const discovered = Color(0xffffcc66);
  static const selected = Color(0xff31b99d);
}

class OcrTextOverlay extends StatefulWidget {
  const OcrTextOverlay({super.key, required this.selection});
  final OcrSelection selection;

  @override
  State<OcrTextOverlay> createState() => _OcrTextOverlayState();
}

class _OcrTextOverlayState extends State<OcrTextOverlay>
    with SingleTickerProviderStateMixin {
  late final reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  Timer? staticHint;
  bool dismissed = false;
  bool? reduced;
  late List<Rect> regions = recognizedRegions();
  OcrSelection get selection => widget.selection;

  List<Rect> recognizedRegions() {
    final lines = <int, Rect>{};
    for (final glyph in selection.glyphs) {
      lines.update(
        glyph.line,
        (box) => box.expandToInclude(glyph.box),
        ifAbsent: () => glyph.box,
      );
    }
    return lines.values.toList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MediaQuery.disableAnimationsOf(context);
    if (next == reduced) return;
    reduced = next;
    staticHint?.cancel();
    if (dismissed) return;
    if (next) {
      reveal.stop();
      staticHint = Timer(const Duration(milliseconds: 1400), dismissReveal);
    } else {
      reveal.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant OcrTextOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != selection) {
      regions = recognizedRegions();
      dismissed = false;
      staticHint?.cancel();
      if (reduced == true) {
        staticHint = Timer(const Duration(milliseconds: 1400), dismissReveal);
      } else {
        reveal.forward(from: 0);
      }
    }
  }

  void dismissReveal() {
    staticHint?.cancel();
    reveal.stop();
    if (mounted && !dismissed) setState(() => dismissed = true);
  }

  double get revealOpacity {
    if (dismissed || !selection.selection.isCollapsed) return 0;
    if (reduced == true) return 1;
    final t = reveal.value;
    if (t >= 1) return 0;
    if (t < .15) return Curves.easeOut.transform(t / .15);
    if (t < .55) return 1;
    return 1 - Curves.easeInOut.transform((t - .55) / .45);
  }

  @override
  void dispose() {
    staticHint?.cancel();
    reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      Offset point(Offset p) =>
          Offset(p.dx / constraints.maxWidth, p.dy / constraints.maxHeight);
      return Semantics(
        label: '在图片文字上拖动选择，按 Control 或 Command 加 C 复制',
        child: MouseRegion(
          cursor: selection.hasText
              ? SystemMouseCursors.text
              : SystemMouseCursors.basic,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              if (e.buttons == kPrimaryMouseButton) {
                dismissReveal();
                selection.begin(point(e.localPosition));
              }
            },
            onPointerMove: (e) {
              if (e.buttons == kPrimaryMouseButton) {
                selection.extend(point(e.localPosition));
              }
            },
            onPointerUp: (_) => selection.end(),
            onPointerCancel: (_) => selection.end(),
            child: ListenableBuilder(
              listenable: Listenable.merge([selection, reveal]),
              builder: (context, _) => CustomPaint(
                painter: OcrHighlightPainter(
                  selection.highlights,
                  OcrColors.selected,
                  regions: regions,
                  revealOpacity: revealOpacity,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class OcrHighlightPainter extends CustomPainter {
  const OcrHighlightPainter(
    this.boxes,
    this.color, {
    this.regions = const [],
    this.revealOpacity = 0,
  });
  final List<Rect> boxes;
  final Color color;
  final List<Rect> regions;
  final double revealOpacity;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    if (revealOpacity > 0) {
      for (final box in regions) {
        final rect = Rect.fromLTRB(
          box.left * size.width,
          box.top * size.height,
          box.right * size.width,
          box.bottom * size.height,
        );
        final frame = RRect.fromRectAndRadius(
          rect.inflate(2),
          const Radius.circular(3),
        );
        canvas.drawRRect(
          frame,
          Paint()
            ..shader = LinearGradient(
              colors: [
                OcrColors.discovered.withValues(alpha: .13 * revealOpacity),
                OcrColors.discovered.withValues(alpha: .26 * revealOpacity),
                OcrColors.discovered.withValues(alpha: .16 * revealOpacity),
              ],
            ).createShader(rect),
        );
      }
    }
    for (final box in boxes) {
      final rect = Rect.fromLTRB(
        box.left * size.width,
        box.top * size.height,
        box.right * size.width,
        box.bottom * size.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(1), const Radius.circular(2)),
        Paint()..color = color.withValues(alpha: .3),
      );
    }
  }

  @override
  bool shouldRepaint(covariant OcrHighlightPainter oldDelegate) =>
      boxes != oldDelegate.boxes ||
      color != oldDelegate.color ||
      regions != oldDelegate.regions ||
      revealOpacity != oldDelegate.revealOpacity;
}

class OcrScanOverlay extends StatefulWidget {
  const OcrScanOverlay({super.key, this.label = '正在识别选区文字'});
  final String label;
  @override
  State<OcrScanOverlay> createState() => _OcrScanOverlayState();
}

class _OcrScanOverlayState extends State<OcrScanOverlay>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool reduced = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      animation.stop();
    } else if (!animation.isAnimating) {
      animation.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Semantics(
      liveRegion: true,
      label: widget.label,
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) => CustomPaint(
                painter: OcrScanPainter(
                  reduced ? .5 : animation.value,
                  OcrColors.scan,
                  reduced: reduced,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class OcrScanPainter extends CustomPainter {
  const OcrScanPainter(this.progress, this.color, {required this.reduced});
  final double progress;
  final Color color;
  final bool reduced;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.clipRect(rect);
    if (reduced) {
      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: .06));
      return;
    }
    final y = (size.height + 80) * progress - 40;
    final glow = Rect.fromLTWH(0, y - 40, size.width, 80);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .16),
            color.withValues(alpha: 0),
          ],
        ).createShader(glow),
    );
    final beam = Rect.fromLTWH(0, y - .75, size.width, 1.5);
    canvas.drawRect(
      beam,
      Paint()
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .65),
            Colors.white.withValues(alpha: .75),
            color.withValues(alpha: .65),
            color.withValues(alpha: 0),
          ],
        ).createShader(beam),
    );
  }

  @override
  bool shouldRepaint(covariant OcrScanPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      color != oldDelegate.color ||
      reduced != oldDelegate.reduced;
}
