import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_zxing/flutter_zxing.dart' as zxing;

class QrCode {
  const QrCode(this.content, this.corners);
  final String content;

  /// Coordinates relative to the scanned selection, in the range 0–1.
  final List<ui.Offset> corners;
  ui.Offset get center =>
      corners.reduce((a, b) => a + b) / corners.length.toDouble();
  Uri? get link => browserLink(content);
}

Uri? browserLink(String content) {
  final value = content.trim();
  if (value.isEmpty || RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) return null;
  var uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (!uri.hasScheme && value.contains('.')) {
    uri = Uri.tryParse('https://$value');
  }
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

class QrPixels {
  const QrPixels(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width, height;
}

/// Runs ZXing off the UI thread. Raw RGBA avoids files and lossy resizing.
List<QrCode> decodeQrPixels(QrPixels pixels) {
  final result = zxing.zx.readBarcodes(
    pixels.bytes,
    zxing.DecodeParams(
      imageFormat: zxing.ImageFormat.rgba,
      width: pixels.width,
      height: pixels.height,
      format: zxing.Format.qrCode,
      tryHarder: true,
      tryRotate: true,
      tryInverted: true,
      tryDownscale: true,
      maxNumberOfSymbols: 255,
    ),
  );
  return qrResults(result);
}

List<QrCode> qrResults(zxing.Codes result) {
  final codes = <QrCode>[];
  for (final code in result.codes) {
    final p = code.position;
    if (!code.isValid ||
        code.text == null ||
        code.text!.isEmpty ||
        p == null ||
        p.imageWidth <= 0 ||
        p.imageHeight <= 0) {
      continue;
    }
    ui.Offset point(int x, int y) => ui.Offset(
      (x / p.imageWidth).clamp(0, 1),
      (y / p.imageHeight).clamp(0, 1),
    );
    final corners = [
      point(p.topLeftX, p.topLeftY),
      point(p.topRightX, p.topRightY),
      point(p.bottomRightX, p.bottomRightY),
      point(p.bottomLeftX, p.bottomLeftY),
    ];
    if (corners.toSet().length < 3) continue;
    codes.add(QrCode(code.text!, corners));
  }
  // Keep identical contents at separate positions as separate buttons.
  codes.sort((a, b) {
    final vertical = a.center.dy.compareTo(b.center.dy);
    return vertical == 0 ? a.center.dx.compareTo(b.center.dx) : vertical;
  });
  return codes;
}

Future<List<QrCode>> scanQrImage(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('无法读取二维码图片');
    return await compute(
      decodeQrPixels,
      QrPixels(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
      ),
    );
  } finally {
    image.dispose();
  }
}
