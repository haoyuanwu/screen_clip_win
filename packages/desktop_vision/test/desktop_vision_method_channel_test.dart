import 'package:desktop_vision/desktop_vision_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelDesktopVision platform = MethodChannelDesktopVision();
  const MethodChannel channel = MethodChannel('desktop_vision');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '42';
        });
    expect(await platform.getPlatformVersion(), '42');
  });

  test('recognizeBytes 解析原生返回结构', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          expect(methodCall.method, 'recognizeBytes');
          final Map<Object?, Object?> args =
              methodCall.arguments as Map<Object?, Object?>;
          expect(args['level'], 'accurate');
          expect(args['languages'], <String>['zh-Hans']);
          return <String, dynamic>{
            'text': '你好\nworld',
            'engine': 'test.ocr',
            'imageWidth': 200,
            'imageHeight': 100,
            'elapsedMs': 12,
            'lines': <dynamic>[
              <String, dynamic>{
                'text': '你好',
                'x': 0.0,
                'y': 0.0,
                'w': 0.5,
                'h': 0.5,
                'confidence': 0.95,
                'words': <dynamic>[
                  <String, dynamic>{
                    'text': '你好',
                    'x': 0.0,
                    'y': 0.0,
                    'w': 0.5,
                    'h': 0.5,
                    'confidence': 0.95,
                  },
                ],
              },
              <String, dynamic>{
                'text': 'world',
                'x': 0.0,
                'y': 0.5,
                'w': 0.5,
                'h': 0.5,
                'confidence': -1,
                'words': <dynamic>[],
              },
            ],
          };
        });

    final result = await platform.recognizeBytes(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      languages: const <String>['zh-Hans'],
    );

    expect(result.engine, 'test.ocr');
    expect(result.imageWidth, 200);
    expect(result.elapsedMs, 12);
    expect(result.lines, hasLength(2));
    expect(result.lines.first.text, '你好');
    expect(result.lines.first.pixelBox.width, closeTo(100, 1e-6));
  });

  test('isSupported 原生返回 null 时视为不支持', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return null;
        });
    expect(await platform.isSupported(), isFalse);
  });
}
