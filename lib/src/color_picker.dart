import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Offset;

class SampledColor {
  const SampledColor(
    this.red,
    this.green,
    this.blue, {
    this.neighborhood,
    this.position,
  });
  final int red, green, blue;
  final ColorPixels? neighborhood;
  final Offset? position;
  Color get color => Color.fromARGB(255, red, green, blue);
  String get hex =>
      '#${[red, green, blue].map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
  String get rgb => 'rgb($red, $green, $blue)';
}

class ColorPixels {
  const ColorPixels(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width, height;
  Future<ui.Image> toImage() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      rowBytes: width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  static Future<ColorPixels> fromPng(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    try {
      return await fromImage(image);
    } finally {
      image.dispose();
    }
  }

  static Future<ColorPixels> fromImage(ui.Image image) async {
    // rawRgba produces 8-bit sRGB channels, independent of the screen's DPI.
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('无法读取屏幕颜色');
    return ColorPixels(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      image.width,
      image.height,
    );
  }

  ColorPixels neighborhood(Offset point, {int radius = 8}) {
    final side = radius * 2 + 1;
    final patch = Uint8List(side * side * 4);
    for (int row = 0; row < side; row++) {
      for (int col = 0; col < side; col++) {
        final x = (point.dx.floor() + col - radius).clamp(0, width - 1);
        final y = (point.dy.floor() + row - radius).clamp(0, height - 1);
        final source = (y * width + x) * 4;
        final target = (row * side + col) * 4;
        patch.setRange(target, target + 4, bytes, source);
      }
    }
    return ColorPixels(patch, side, side);
  }

  SampledColor at(Offset point, {bool includeNeighborhood = false}) {
    final x = point.dx.floor().clamp(0, width - 1),
        y = point.dy.floor().clamp(0, height - 1);
    final i = (y * width + x) * 4;
    final alpha = bytes[i + 3];
    // Screen pixels are normally opaque; transparent annotation edges are
    // composited over white for a useful RGB-only swatch.
    int channel(int offset) => (bytes[i + offset] + 255 - alpha).clamp(0, 255);
    return SampledColor(
      channel(0),
      channel(1),
      channel(2),
      position: Offset(x.toDouble(), y.toDouble()),
      neighborhood: includeNeighborhood ? neighborhood(point) : null,
    );
  }
}

class ScreenColorPicker extends ChangeNotifier {
  ScreenColorPicker(this.pixels) {
    sample = pixels.at(position, includeNeighborhood: true);
  }
  final ColorPixels pixels;
  Offset position = Offset.zero;
  late SampledColor sample;
  bool fixed = false;
  void move(Offset point) {
    if (fixed) return;
    position = Offset(
      point.dx.clamp(0, pixels.width - 1),
      point.dy.clamp(0, pixels.height - 1),
    );
    sample = pixels.at(position, includeNeighborhood: true);
    notifyListeners();
  }

  void freeze() {
    fixed = true;
    notifyListeners();
  }

  void resume() {
    fixed = false;
    notifyListeners();
  }
}
