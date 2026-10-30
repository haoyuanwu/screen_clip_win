import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Estimate flat screenshot surfaces and foreground ink without uploading pixels.
({Color background, Color ink}) sourceAppearance(
  ByteData pixels,
  int width,
  int height,
  Rect rect,
) {
  Color pixel(int x, int y) {
    final offset = (y.clamp(0, height - 1) * width + x.clamp(0, width - 1)) * 4;
    return Color.fromARGB(
      255,
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
    );
  }

  final colors = <int, (int, Color)>{};
  void add(Color c) {
    final key =
        ((c.r * 255).toInt() ~/ 16 << 8) |
        ((c.g * 255).toInt() ~/ 16 << 4) |
        ((c.b * 255).toInt() ~/ 16);
    colors[key] = ((colors[key]?.$1 ?? 0) + 1, c);
  }

  final step = math.max(1, rect.width ~/ 100);
  for (int x = rect.left.floor(); x <= rect.right.ceil(); x += step) {
    add(pixel(x, rect.top.floor() - 2));
    add(pixel(x, rect.bottom.ceil() + 2));
  }
  for (int y = rect.top.floor(); y <= rect.bottom.ceil(); y++) {
    add(pixel(rect.left.floor() - 2, y));
    add(pixel(rect.right.ceil() + 2, y));
  }
  final bg = colors.values.reduce((a, b) => a.$1 >= b.$1 ? a : b).$2;
  colors.clear();
  for (int y = rect.top.floor(); y < rect.bottom.ceil(); y += 2) {
    for (int x = rect.left.floor(); x < rect.right.ceil(); x += 2) {
      final c = pixel(x, y);
      if ((c.computeLuminance() - bg.computeLuminance()).abs() > .18) add(c);
    }
  }
  final ink = colors.isEmpty
      ? (bg.computeLuminance() > .5 ? Colors.black : Colors.white)
      : colors.values.reduce((a, b) => a.$1 >= b.$1 ? a : b).$2;
  return (background: bg, ink: ink);
}
