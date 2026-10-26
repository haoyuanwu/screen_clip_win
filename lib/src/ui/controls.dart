import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderWrap;
import 'package:flutter/services.dart';

/// Wrap's default intrinsic width omits spacing. Include it when a toolbar
/// measures its natural width, so the final control is not forced to wrap.
class ToolbarWrap extends Wrap {
  const ToolbarWrap({
    super.key,
    super.spacing,
    super.runSpacing,
    super.alignment,
    super.crossAxisAlignment,
    super.children,
  });

  @override
  RenderWrap createRenderObject(BuildContext context) => _ToolbarRenderWrap(
    spacing: spacing,
    runSpacing: runSpacing,
    alignment: alignment,
    crossAxisAlignment: crossAxisAlignment,
    textDirection: textDirection ?? Directionality.maybeOf(context),
  );
}

class _ToolbarRenderWrap extends RenderWrap {
  _ToolbarRenderWrap({
    super.spacing,
    super.runSpacing,
    super.alignment,
    super.crossAxisAlignment,
    super.textDirection,
  });

  @override
  double computeMaxIntrinsicWidth(double height) =>
      super.computeMaxIntrinsicWidth(height) +
      math.max(0, childCount - 1) * spacing;
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(10),
    this.tintOpacity,
  });
  final Widget child;
  final EdgeInsets padding;
  final double? tintOpacity;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .16),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: (dark ? const Color(0xff262629) : const Color(0xfffafafa))
                  .withValues(
                    alpha: MediaQuery.highContrastOf(context)
                        ? 1
                        : tintOpacity ?? (dark ? .70 : .72),
                  ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: tintOpacity == null || MediaQuery.highContrastOf(context)
                    ? (dark ? const Color(0xff555559) : const Color(0xffdedee2))
                    : (dark ? Colors.white : Colors.black).withValues(
                        alpha: dark ? .20 : .10,
                      ),
                width: .7,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.label,
    this.icon,
    this.child,
    this.onPressed,
    this.selected = false,
    this.primary = false,
    this.size = 32,
  });
  final String label;
  final IconData? icon;
  final Widget? child;
  final VoidCallback? onPressed;
  final bool selected, primary;
  final double size;
  @override
  State<ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<ToolButton> {
  bool hover = false, focused = false, pressed = false;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label,
      button: true,
      selected: widget.selected,
      enabled: widget.onPressed != null,
      child: Tooltip(
        message: widget.label,
        child: FocusableActionDetector(
          enabled: widget.onPressed != null,
          onShowHoverHighlight: (v) => setState(() => hover = v),
          onShowFocusHighlight: (v) => setState(() => focused = v),
          mouseCursor: widget.onPressed == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            onTapDown: widget.onPressed == null
                ? null
                : (_) => setState(() => pressed = true),
            onTapUp: (_) => setState(() => pressed = false),
            onTapCancel: () => setState(() => pressed = false),
            child: AnimatedScale(
              scale: pressed ? .91 : 1,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 110),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 100),
                constraints: BoxConstraints(
                  minWidth: widget.size,
                  minHeight: widget.size,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.size < 30
                      ? 4
                      : widget.child == null
                      ? 5
                      : 7,
                  vertical: widget.size < 30 ? 4 : 5,
                ),
                decoration: BoxDecoration(
                  color: widget.primary
                      ? c.primary
                      : widget.selected
                      ? c.primary.withValues(alpha: .14)
                      : pressed
                      ? c.onSurface.withValues(alpha: .12)
                      : hover
                      ? c.onSurface.withValues(alpha: .07)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: focused ? c.primary : Colors.transparent,
                  ),
                ),
                child: Opacity(
                  opacity: widget.onPressed == null ? .3 : 1,
                  child: IconTheme(
                    data: IconThemeData(
                      size: widget.size < 30 ? 16 : 18,
                      color: widget.primary
                          ? c.onPrimary
                          : widget.selected
                          ? c.primary
                          : c.onSurface,
                    ),
                    child: DefaultTextStyle(
                      style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        fontSize: 12,
                        color: widget.primary ? c.onPrimary : c.onSurface,
                      ),
                      child: widget.child ?? Icon(widget.icon),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FineSlider extends StatefulWidget {
  const FineSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = .5,
  });
  final String label;
  final double value, min, max, step;
  final ValueChanged<double>? onChanged;
  @override
  State<FineSlider> createState() => _FineSliderState();
}

class _FineSliderState extends State<FineSlider> {
  final sliderFocus = FocusNode();
  @override
  void dispose() {
    sliderFocus.dispose();
    super.dispose();
  }

  bool focused = false;
  void change(double v) => widget.onChanged?.call(
    ((v / widget.step).round() * widget.step).clamp(widget.min, widget.max),
  );
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    void at(double x) {
      // Read the assigned width at input time, keeping intrinsic layout pure.
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      sliderFocus.requestFocus();
      change(
        widget.min +
            (widget.max - widget.min) *
                ((x - 9) / math.max(1, box.size.width - 18)).clamp(0, 1),
      );
    }

    return Semantics(
      label: widget.label,
      slider: true,
      enabled: widget.onChanged != null,
      value: widget.value.toStringAsFixed(1),
      increasedValue: (widget.value + widget.step)
          .clamp(widget.min, widget.max)
          .toStringAsFixed(1),
      decreasedValue: (widget.value - widget.step)
          .clamp(widget.min, widget.max)
          .toStringAsFixed(1),
      onIncrease: widget.onChanged == null
          ? null
          : () => change(widget.value + widget.step),
      onDecrease: widget.onChanged == null
          ? null
          : () => change(widget.value - widget.step),
      child: Focus(
        focusNode: sliderFocus,
        canRequestFocus: widget.onChanged != null,
        onFocusChange: (v) => setState(() => focused = v),
        onKeyEvent: (_, e) {
          if (widget.onChanged == null) return KeyEventResult.ignored;
          if (e is KeyDownEvent || e is KeyRepeatEvent) {
            if (e.logicalKey == LogicalKeyboardKey.arrowRight ||
                e.logicalKey == LogicalKeyboardKey.arrowLeft) {
              change(
                widget.value +
                    (e.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1) *
                        widget.step,
              );
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: focused ? c.primary : Colors.transparent),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: widget.onChanged == null
                  ? null
                  : (d) => at(d.localPosition.dx),
              onHorizontalDragUpdate: widget.onChanged == null
                  ? null
                  : (d) => at(d.localPosition.dx),
              child: CustomPaint(
                size: const Size(144, 30),
                painter: _Track(
                  (widget.value - widget.min) / (widget.max - widget.min),
                  c.primary,
                  c.onSurface.withValues(alpha: .15),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Track extends CustomPainter {
  _Track(this.t, this.color, this.track);
  final double t;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final width = math.max(1.0, size.width - 18), y = size.height / 2;
    final pen = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawLine(Offset(9, y), Offset(size.width - 9, y), pen);
    canvas.drawLine(Offset(9, y), Offset(9 + width * t, y), pen..color = color);
    canvas.drawShadow(
      Path()
        ..addOval(Rect.fromCircle(center: Offset(9 + width * t, y), radius: 7)),
      Colors.black26,
      2,
      false,
    );
    canvas.drawCircle(
      Offset(9 + width * t, y),
      7,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _Track old) =>
      old.t != t || old.color != color || old.track != track;
}

const swatches = [
  Colors.transparent,
  Color(0xff1c1c1e),
  Color(0xffffffff),
  Color(0xffd92d3e),
  Color(0xffff9f0a),
  Color(0xffffd60a),
  Color(0xff168049),
  Color(0xff00a5aa),
  Color(0xff2459df),
  Color(0xffaf52de),
];

class ColorRow extends StatelessWidget {
  const ColorRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clear = false,
  });
  final String label;
  final Color value;
  final ValueChanged<Color> onChanged;
  final bool clear;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 2,
    runSpacing: 2,
    children: [
      for (final color in swatches.where(
        (c) => clear || c != Colors.transparent,
      ))
        ToolButton(
          label:
              '$label：${color == Colors.transparent ? '透明' : '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}'}',
          selected: color == value,
          size: 28,
          onPressed: () => onChanged(color),
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color == Colors.transparent ? null : color,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline
                    .withValues(alpha: .5),
              ),
            ),
            child: color == Colors.transparent
                ? const Icon(Icons.close, size: 12)
                : null,
          ),
        ),
    ],
  );
}

/// A bounded fade/size transition that never animates the screenshot pixels.
class StateTransition extends StatelessWidget {
  const StateTransition({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) return child;
    return AnimatedSize(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: reduced ? Duration.zero : const Duration(milliseconds: 130),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, .035),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: child,
      ),
    );
  }
}
