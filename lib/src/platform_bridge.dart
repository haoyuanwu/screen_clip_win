import 'package:flutter/services.dart';
import 'package:desktop_vision/desktop_vision.dart';

import 'qr_scan.dart';
import 'ocr_selection.dart';

class DesktopBridge {
  Future<void> recognizePinnedText(Object id, Uint8List bytes) async {
    Map<String, Object?> payload;
    try {
      final result = await recognizeText(bytes);
      final selection = OcrSelection(result);
      payload = {
        'id': id,
        'text': selection.text,
        'status': selection.hasText ? 'ready' : 'empty',
        'glyphs': [
          for (final g in selection.glyphs)
            {
              'start': g.start,
              'end': g.end,
              'line': g.line,
              'x': g.box.left,
              'y': g.box.top,
              'width': g.box.width,
              'height': g.box.height,
            },
        ],
      };
      selection.dispose();
    } catch (_) {
      payload = {'id': id, 'text': '', 'status': 'error', 'glyphs': <Object>[]};
    }
    // Pins may have been closed while recognition was running.
    try {
      await channel.invokeMethod<void>('pinOcrResult', payload);
    } catch (_) {}
  }

  Future<List<QrCode>> scanQrCodes(Uint8List bytes) => scanQrImage(bytes);
  Future<void> openBrowser(Uri url) =>
      channel.invokeMethod('openBrowser', url.toString());
  Future<OcrResult> recognizeText(Uint8List bytes) =>
      DesktopVision.recognizeBytes(
        bytes,
        languages: const ['zh-Hans', 'en-US'],
      );
  static const channel = MethodChannel('screenclip/desktop');
  Future<String> launchAtLoginStatus() async =>
      await channel.invokeMethod<String>('launchAtLoginStatus') ?? 'disabled';
  Future<String> setLaunchAtLogin(bool enabled) async =>
      await channel.invokeMethod<String>('setLaunchAtLogin', enabled) ??
      'disabled';
  Future<String> dataDirectory() async =>
      (await channel.invokeMethod<String>('dataDirectory'))!;
  Future<Map<Object?, Object?>?> capture(String mode) =>
      channel.invokeMapMethod<Object?, Object?>('capture', mode);
  Future<Map<Object?, Object?>?> focusCaptureWindow(int index) =>
      channel.invokeMapMethod<Object?, Object?>('focusCaptureWindow', index);
  Future<Offset> nudgeCursor(int dx, int dy) async {
    final point = await channel.invokeMapMethod<Object?, Object?>(
      'nudgeCursor',
      {'dx': dx, 'dy': dy},
    );
    if (point?['x'] is! num || point?['y'] is! num) {
      throw PlatformException(code: 'cursor', message: '无法获取光标位置');
    }
    return Offset(
      (point!['x'] as num).toDouble(),
      (point['y'] as num).toDouble(),
    );
  }

  Future<String?> save(Uint8List bytes, String name) =>
      channel.invokeMethod<String>('save', {'bytes': bytes, 'name': name});
  Future<void> pin(Uint8List bytes, Map<String, double> rect, bool animate) =>
      channel.invokeMethod('pin', {
        'bytes': bytes,
        ...rect,
        'animate': animate,
      });
  Future<void> copy(Uint8List bytes) => channel.invokeMethod('copy', bytes);
  Future<void> permissions() => channel.invokeMethod('permissions');
  Future<void> present(String panel) => channel.invokeMethod('present', panel);
  Future<bool> captureFrameReady(Size viewport) async =>
      await channel.invokeMethod<bool>('captureFrameReady', {
        'width': viewport.width,
        'height': viewport.height,
      }) ??
      true;
  Future<void> notifyCopied() => channel.invokeMethod('copied');
  Future<void> dismiss() => channel.invokeMethod('dismiss');
  Future<bool> registerHotkey() async =>
      await channel.invokeMethod<bool>('registerHotkey') ?? false;
  Future<bool> registerColorHotkey() async =>
      await channel.invokeMethod<bool>('registerColorHotkey') ?? false;
}
