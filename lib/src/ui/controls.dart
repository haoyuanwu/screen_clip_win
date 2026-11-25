import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderWrap;
import 'package:flutter/services.dart';

import '../theme.dart';

/// Wrap's default intrinsic width omits spacing. Include it when a toolbar
/// measures its natural width, so the final control is not forced to wrap.
class ToolbarWrap extends Wrap {
  const ToolbarWrap({
    super.key,
    super.spacing = 4,
    super.runSpacing = 4,
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

class FlatPanel extends StatelessWidget {
  const FlatPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(10),
    this.color,
    this.shadow = true,
    this.floating = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final bool shadow, floating;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: AppStyle.panel(
      context,
      color: color,
      shadow: shadow,
      floating: floating,
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// A short reveal for panels that open without moving the primary actions.
class PanelReveal extends StatelessWidget {
  const PanelReveal({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppStyle.motion(context, 180);
    if (duration == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: AppStyle.motionCurve,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 4 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}

/// Secondary controls share one inset surface, distinct from the main tools.
class ToolbarInspectorSurface extends StatelessWidget {
  const ToolbarInspectorSurface({super.key, required this.child, this.title});
  final Widget child;
  final String? title;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
          ],
          child,
        ],
      ),
    );
  }
}

class ToolbarOptionGroup extends StatelessWidget {
  const ToolbarOptionGroup({
    super.key,
    required this.label,
    required this.children,
  });
  final String label;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 4),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(width: 4),
            child,
          ],
        ],
      ),
    ],
  );
}

class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.label,
    this.icon,
    this.title,
    this.child,
    this.onPressed,
    this.selected = false,
    this.primary = false,
    this.size = 32,
  });
  final String label;
  final String? title;
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
              scale:
                  pressed &&
                      widget.onPressed != null &&
                      !MediaQuery.disableAnimationsOf(context)
                  ? .97
                  : 1,
              duration: AppStyle.motion(context, 100),
              curve: AppStyle.motionCurve,
              child: AnimatedContainer(
                duration: AppStyle.motion(context, 140),
                curve: AppStyle.motionCurve,
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
                      ? (pressed || hover
                            ? Color.alphaBlend(
                                c.onPrimary.withValues(
                                  alpha: pressed ? .18 : .10,
                                ),
                                c.primary,
                              )
                            : c.primary)
                      : widget.selected
                      ? c.primaryContainer
                      : pressed
                      ? c.surfaceContainerHigh
                      : hover
                      ? c.surfaceContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppStyle.controlRadius),
                  border: Border.all(
                    color: focused
                        ? (widget.primary ? c.onPrimary : c.primary)
                        : widget.selected
                        ? c.primary.withValues(alpha: .60)
                        : Colors.transparent,
                  ),
                ),
                child: Align(
                  alignment: Alignment.center,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Opacity(
                    opacity: widget.onPressed == null ? .42 : 1,
                    child: IconTheme(
                      data: IconThemeData(
                        size: 18,
                        color: widget.primary
                            ? c.onPrimary
                            : widget.selected
                            ? c.onPrimaryContainer
                            : c.onSurface,
                      ),
                      child: DefaultTextStyle(
                        style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          fontSize: 12,
                          color: widget.primary
                              ? c.onPrimary
                              : widget.selected
                              ? c.onPrimaryContainer
                              : c.onSurface,
                        ),
                        child: widget.title == null
                            ? widget.child ?? Icon(widget.icon)
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: widget.size < 30 ? 16 : 20,
                                    child: Center(
                                      child: widget.child ?? Icon(widget.icon),
                                    ),
                                  ),
                                  SizedBox(height: widget.size < 30 ? 2 : 4),
                                  Text(
                                    widget.title!,
                                    style: TextStyle(
                                      fontSize: widget.size < 30 ? 9.5 : 11,
                                      height: 1.1,
                                    ),
                                  ),
                                ],
                              ),
                      ),
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
    final duration = AppStyle.motion(context, 190);
    if (duration == Duration.zero) return child;
    return AnimatedSize(
      duration: duration,
      curve: AppStyle.motionCurve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppStyle.motion(context, 140),
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

/// Error details may contain commands and paths; keep the complete text available.
class CopyableMessage extends StatefulWidget {
  const CopyableMessage({super.key, required this.message, this.style});
  final String message;
  final TextStyle? style;
  @override
  State<CopyableMessage> createState() => _CopyableMessageState();
}

class _CopyableMessageState extends State<CopyableMessage> {
  bool copied = false;
  @override
  void didUpdateWidget(CopyableMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) copied = false;
  }

  Future<void> copy() async {
    final message = widget.message;
    try {
      await Clipboard.setData(ClipboardData(text: message));
      if (mounted && message == widget.message) setState(() => copied = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('复制失败，请选中文字后复制')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height * .42).clamp(72, 240),
          ),
          child: SingleChildScrollView(
            child: SelectableText(widget.message, style: widget.style),
          ),
        ),
      ),
      const SizedBox(width: 6),
      ToolButton(
        label: copied ? '已复制提示' : '复制提示',
        icon: copied ? Icons.check_rounded : Icons.content_copy_rounded,
        onPressed: copy,
      ),
    ],
  );
}

/// Floats above the page without changing the page's available layout space.
class FloatingErrorNotification extends StatelessWidget {
  const FloatingErrorNotification({
    super.key,
    required this.message,
    required this.onDismiss,
  });
  final String message;
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        type: MaterialType.transparency,
        child: FlatPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.error_outline_rounded,
                      color: cs.onErrorContainer,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '操作未完成',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ToolButton(
                    label: '关闭提示',
                    icon: Icons.close_rounded,
                    onPressed: onDismiss,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              CopyableMessage(
                message: message,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
