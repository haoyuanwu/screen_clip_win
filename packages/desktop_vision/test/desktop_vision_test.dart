import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:desktop_vision/desktop_vision.dart';
import 'package:desktop_vision/desktop_vision_method_channel.dart';
import 'package:desktop_vision/desktop_vision_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockDesktopVisionPlatform
    with MockPlatformInterfaceMixin
    implements DesktopVisionPlatform {
  List<String>? lastLanguages;

  @override
  Future<String?> getPlatformVersion() => Future<String?>.value('42');

  @override
  Future<bool> isSupported() => Future<bool>.value(true);

  @override
  Future<OcrEngineInfo> getEngineInfo() async {
    return const OcrEngineInfo(
      engine: 'mock.ocr',
      version: 'mock-1.0',
      isAvailable: true,
      languageTag: 'zh-Hans',
      supportedLanguages: <String>['zh-Hans', 'en-US'],
    );
  }

  @override
  Future<OcrResult> recognizeBytes({
    required Uint8List bytes,
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) async {
    lastLanguages = languages;
    return OcrResult.fromMap(<String, dynamic>{
      'text': 'hello',
      'engine': 'mock.ocr',
      'imageWidth': 100,
      'imageHeight': 50,
      'elapsedMs': 7,
      'lines': <dynamic>[
        <String, dynamic>{
          'text': 'hello',
          'x': 0.1,
          'y': 0.2,
          'w': 0.3,
          'h': 0.4,
          'confidence': 0.9,
          'words': <dynamic>[
            <String, dynamic>{
              'text': 'hello',
              'x': 0.1,
              'y': 0.2,
              'w': 0.3,
              'h': 0.4,
              'confidence': 0.9,
            },
          ],
        },
      ],
    });
  }

  @override
  Future<OcrResult> recognizeFile({
    required String path,
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) {
    return recognizeBytes(bytes: Uint8List(0));
  }
}

void main() {
  final DesktopVisionPlatform initialPlatform = DesktopVisionPlatform.instance;

  test('$MethodChannelDesktopVision is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelDesktopVision>());
  });

  test('getPlatformVersion', () async {
    DesktopVisionPlatform.instance = MockDesktopVisionPlatform();
    expect(await DesktopVision.getPlatformVersion(), '42');
  });

  test('recognizeBytes 透传参数并解析坐标', () async {
    final MockDesktopVisionPlatform fakePlatform = MockDesktopVisionPlatform();
    DesktopVisionPlatform.instance = fakePlatform;

    final OcrResult result = await DesktopVision.recognizeBytes(
      Uint8List(4),
      languages: const <String>['zh-Hans'],
    );

    expect(fakePlatform.lastLanguages, <String>['zh-Hans']);
    expect(result.text, 'hello');
    expect(result.lines, hasLength(1));

    final OcrLine line = result.lines.first;
    expect(line.words, hasLength(1));
    // 归一化 → 像素：100x50 的图，0.1/0.2/0.3/0.4 → 10/10/30/20
    expect(line.pixelBox.left, closeTo(10, 1e-6));
    expect(line.pixelBox.top, closeTo(10, 1e-6));
    expect(line.pixelBox.width, closeTo(30, 1e-6));
    expect(line.pixelBox.height, closeTo(20, 1e-6));
  });

  test('toPaintRect 按展示尺寸缩放', () {
    final Rect rect = DesktopVision.toPaintRect(
      const Rect.fromLTWH(0.25, 0.5, 0.5, 0.25),
      const Size(400, 200),
    );
    expect(rect.left, 100);
    expect(rect.top, 100);
    expect(rect.width, 200);
    expect(rect.height, 50);
  });
}
