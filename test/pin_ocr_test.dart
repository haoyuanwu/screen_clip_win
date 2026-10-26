import 'dart:async';

import 'package:desktop_vision/desktop_vision.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';

class PinOcrBridge extends DesktopBridge {
  final results = <int, Completer<OcrResult>>{};
  @override
  Future<OcrResult> recognizeText(Uint8List bytes) =>
      results.putIfAbsent(bytes.first, Completer<OcrResult>.new).future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Pin OCR keeps results separate, sends selectable glyphs and never copies automatically', () async {
    final bridge = PinOcrBridge();
    final messages = <Map>[];
    var clipboardWrites = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopBridge.channel, (call) async {
          expect(call.method, 'pinOcrResult');
          messages.add(call.arguments as Map);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') clipboardWrites++;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopBridge.channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final first = bridge.recognizePinnedText(
      'pin-one',
      Uint8List.fromList([1]),
    );
    final second = bridge.recognizePinnedText(
      'pin-two',
      Uint8List.fromList([2]),
    );
    bridge.results[2]!.complete(
      OcrResult.fromMap({
        'lines': [
          {'text': 'Text two', 'x': .1, 'y': .2, 'w': .6, 'h': .1},
        ],
      }),
    );
    await second;
    bridge.results[1]!.completeError(PlatformException(code: 'ocr_failed'));
    await first;
    expect(messages.map((m) => m['id']), ['pin-two', 'pin-one']);
    expect(messages[0]['status'], 'ready');
    expect(messages[0]['text'], 'Text two');
    expect(messages[0]['glyphs'], isNotEmpty);
    final glyph = (messages[0]['glyphs'] as List).first as Map;
    expect(glyph['start'], 0);
    expect(glyph['end'], 1);
    expect(glyph['y'], .2);
    expect(messages[1]['status'], 'error');
    expect(clipboardWrites, 0);
    final empty = bridge.recognizePinnedText(
      'pin-empty',
      Uint8List.fromList([3]),
    );
    bridge.results[3]!.complete(OcrResult.fromMap({'lines': <Object>[]}));
    await empty;
    expect(messages.last['status'], 'empty');
  });
}
