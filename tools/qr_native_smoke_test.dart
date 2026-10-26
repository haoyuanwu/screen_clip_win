// ignore_for_file: implementation_imports
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zxing/flutter_zxing.dart' as zx;
import 'package:flutter_zxing/src/logic/zxing.dart' as native;
import 'package:screen_clip_win/src/qr_scan.dart';

void main() {
  test('Actual ZXing library decodes multiple in-memory QR codes', () {
    final path =
        '${Directory.current.path}/build/macos/Build/Products/Debug/PackageFrameworks/flutter-zxing.framework/Versions/A/flutter-zxing';
    expect(
      File(path).existsSync(),
      true,
      reason: 'Run flutter build macos --debug first',
    );
    native.dylib = DynamicLibrary.open(path);
    const width = 800, height = 400;
    final rgba = Uint8List(width * height * 4)
      ..fillRange(0, width * height * 4, 255);
    for (final (index, text) in [
      'https://example.com/one',
      'https://example.com/two',
    ].indexed) {
      final encoded = zx.zx.encodeBarcode(
        contents: text,
        params: zx.EncodeParams(width: 240, height: 240, margin: 4),
      );
      expect(encoded.isValid, true);
      for (int y = 0; y < encoded.height!; y++) {
        for (int x = 0; x < encoded.width!; x++) {
          final target = ((y + 40) * width + x + 30 + index * 400) * 4;
          final value = encoded.data![y * encoded.width! + x];
          rgba[target] = value;
          rgba[target + 1] = value;
          rgba[target + 2] = value;
        }
      }
    }
    final codes = decodeQrPixels(QrPixels(rgba, width, height));
    expect(codes.map((c) => c.content).toSet(), {
      'https://example.com/one',
      'https://example.com/two',
    });
    expect(codes[0].center.dx, closeTo(.1875, .03));
    expect(codes[1].center.dx, closeTo(.6875, .03));
  }, skip: !Platform.isMacOS);
}
