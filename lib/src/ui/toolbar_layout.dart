import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Pick one physical display, never the virtual desktop's surrounding rectangle.
Rect toolbarScreen(Rect selection, List<Rect> screens, Rect viewport) {
  final available = screens
      .map((r) => r.intersect(viewport))
      .where((r) => r.width > 0 && r.height > 0)
      .toList();
  if (available.isEmpty) return viewport;
  var best = available.first;
  double bestArea = -1;
  for (final screen in available) {
    final overlap = screen.intersect(selection);
    final area = overlap.isEmpty ? 0.0 : overlap.width * overlap.height;
    if (area > bestArea ||
        (area == bestArea && screen.contains(selection.center))) {
      best = screen;
      bestArea = area;
    }
  }
  return best;
}

/// Constraints are independent of how close the selection is to an edge.
/// Position is computed with the child's actual size during the same layout pass.
class ToolbarLayout extends SingleChildLayoutDelegate {
  ToolbarLayout({
    required this.selection,
    required this.screen,
    this.margin = 12,
    this.gap = 10,
  });
  final Rect selection, screen;
  final double margin, gap;
  Rect get safe => screen.deflate(
    math.min(margin, math.min(screen.width, screen.height) / 4),
  );
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final bounds = safe;
    // Let the content choose its width; only the active display limits it.
    return BoxConstraints(maxWidth: bounds.width, maxHeight: bounds.height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = safe;
    bool fits(Offset p) =>
        p.dx >= bounds.left &&
        p.dy >= bounds.top &&
        p.dx + childSize.width <= bounds.right &&
        p.dy + childSize.height <= bounds.bottom;
    final rightAligned = (selection.right - childSize.width).clamp(
      bounds.left,
      math.max(bounds.left, bounds.right - childSize.width),
    );
    final centeredY = (selection.center.dy - childSize.height / 2).clamp(
      bounds.top,
      math.max(bounds.top, bounds.bottom - childSize.height),
    );
    final candidates = [
      Offset(rightAligned.toDouble(), selection.bottom + gap),
      Offset(rightAligned.toDouble(), selection.top - gap - childSize.height),
      Offset(selection.right + gap, centeredY.toDouble()),
      Offset(selection.left - gap - childSize.width, centeredY.toDouble()),
    ];
    for (final position in candidates) {
      if (fits(position)) return position;
    }
    // No outside slot is large enough: overlap the selection, keeping the panel
    // dimensions unchanged and its four edges inside the chosen display.
    return Offset(
      rightAligned.toDouble(),
      (selection.bottom + gap)
          .clamp(
            bounds.top,
            math.max(bounds.top, bounds.bottom - childSize.height),
          )
          .toDouble(),
    );
  }

  @override
  bool shouldRelayout(covariant ToolbarLayout old) =>
      old.selection != selection ||
      old.screen != screen ||
      old.margin != margin ||
      old.gap != gap;
}

/// Keep the temporary text action near a shape's lower-right corner, without
/// obscuring the editing toolbar or escaping the display that owns the shape.
class ShapeTextPromptLayout extends SingleChildLayoutDelegate {
  ShapeTextPromptLayout({
    required this.shape,
    required this.screen,
    this.toolbar,
  });
  final Rect shape, screen;
  final Rect? toolbar;
  Rect get safe =>
      screen.deflate(math.min(8, math.min(screen.width, screen.height) / 4));

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(200, safe.width),
        maxHeight: safe.height,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = safe;
    Offset clamp(Offset p) => Offset(
      p.dx.clamp(
        bounds.left,
        math.max(bounds.left, bounds.right - childSize.width),
      ),
      p.dy.clamp(
        bounds.top,
        math.max(bounds.top, bounds.bottom - childSize.height),
      ),
    );
    double overlap(Offset p) {
      if (toolbar == null) return 0;
      final intersection = (p & childSize).intersect(toolbar!.inflate(4));
      return intersection.isEmpty
          ? 0
          : intersection.width * intersection.height;
    }

    final positions = [
      Offset(shape.right + 8, shape.bottom + 8),
      Offset(shape.right - childSize.width, shape.bottom + 8),
      Offset(shape.right + 8, shape.bottom - childSize.height),
      Offset(
        shape.right - childSize.width,
        shape.bottom - childSize.height - 8,
      ),
      if (toolbar != null)
        Offset(
          shape.right - childSize.width,
          toolbar!.top - childSize.height - 8,
        ),
    ].map(clamp).toList();
    var best = positions.first;
    for (final p in positions) {
      if (overlap(p) == 0) return p;
      if (overlap(p) < overlap(best)) best = p;
    }
    return best;
  }

  @override
  bool shouldRelayout(covariant ShapeTextPromptLayout oldDelegate) =>
      shape != oldDelegate.shape ||
      screen != oldDelegate.screen ||
      toolbar != oldDelegate.toolbar;
}
