import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_clip_win/translation/models.dart';
import 'package:screen_clip_win/translation/service.dart';
import 'package:screen_clip_win/translation/controller.dart';
import 'package:screen_clip_win/translation/ui/translation_panel.dart';
import 'package:screen_clip_win/translation/ui/reading_panel.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/workspace.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/ocr_overlay.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:desktop_vision/desktop_vision.dart';

import 'widget_test.dart' show FakeBridge, sample;

import 'dart:ui' as ui;

class MemoryChannels implements ChannelStorage {
  String? value;
  bool failWrite = false, failRead = false;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('unavailable');
    return value;
  }

  @override
  Future<void> write(String input) async {
    if (failWrite) throw StateError('unavailable');
    value = input;
  }
}

TranslationChannel readyChannel() =>
    defaultTranslationChannels().first.copyWith(apiKey: 'test-secret-1234');
TranslationService echoService() => TranslationService(
  clientFactory: () => MockClient(
    (request) async => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content':
                  (jsonDecode(request.body)['messages'][0]['content'] as String)
                      .contains('JSON 字符串数组')
                  ? jsonEncode(['你好，世界。'])
                  : '你好，世界。\n保留换行。',
            },
            'finish_reason': 'stop',
          },
        ],
        'usage': {'total_tokens': 42},
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  ),
);
Future<TranslationController> configured({
  TranslationService? service,
  MemoryChannels? store,
}) async {
  final c = TranslationController(
    storage: store ?? MemoryChannels(),
    service: service ?? echoService(),
  );
  await c.initialize();
  await c.saveChannel(readyChannel());
  return c;
}

class TranslateOcrBridge extends FakeBridge {
  TranslateOcrBridge() : super('unused');
  int recognized = 0;
  @override
  Future<OcrResult> recognizeText(Uint8List bytes) async {
    recognized++;
    return OcrResult(
      text: 'Hello world',
      imageWidth: 1000,
      imageHeight: 700,
      engine: 'test',
      lines: [
        OcrLine(
          text: 'Hello world',
          normalizedBox: const Rect.fromLTWH(0, 0, 1, 1),
          pixelBox: const Rect.fromLTWH(0, 0, 1000, 700),
        ),
      ],
    );
  }

  @override
  Future<bool> captureFrameReady(Size viewport) async => true;
}

void main() {
  testWidgets(
    'Settings exposes translation key configuration and returns to settings',
    (tester) async {
      tester.view.physicalSize = const Size(530, 590);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c =
          ClipController(
              bridge: FakeBridge('unused'),
              translation: await configured(),
            )
            ..panel = 'settings'
            ..ready = true;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Workspace(controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('翻译 API Key').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('配置翻译 API Key'));
      await tester.pumpAndSettle();
      expect(c.panel, 'translation');
      expect(find.text('翻译渠道'), findsOneWidget);
      expect(find.text('智谱 AI'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭翻译 · Esc'));
      await tester.pumpAndSettle();
      expect(c.panel, 'settings');
      expect(find.byType(Preferences), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('Image translation mark stays inside its box and fits wrapped text', () {
    final mark = imageTranslationMark(
      '这是多行的译文，需要完整保留并正确换行。',
      const Rect.fromLTWH(100, 50, 200, 44),
    );
    final painter = mark.textPainter;
    expect(mark.points.single, const Offset(100, 50));
    expect(mark.textFrame, const Size(200, 44));
    expect(painter.height + mark.padding * 2, lessThanOrEqualTo(44.01));
    expect(mark.background.a, 1);
    painter.dispose();
  });
  test('Batch translation sends one ordered JSON array request', () async {
    var requests = 0;
    final service = TranslationService(
      clientFactory: () => MockClient((request) async {
        requests++;
        final body = jsonDecode(request.body);
        expect(body['messages'][0]['content'], contains('保持元素数量和顺序'));
        expect(
          body['messages'][1]['content'],
          contains(jsonEncode(['Hello', 'World'])),
        );
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode(['你好', '世界']),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final task = service.start(
      text: 'Hello\nWorld',
      from: TranslationLanguage.auto,
      to: TranslationLanguage.zh,
      channel: readyChannel(),
      segments: ['Hello', 'World'],
    );
    expect(jsonDecode((await task.future).translatedText), ['你好', '世界']);
    expect(requests, 1);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  test('All requested presets and languages are configurable; keys stay in secure storage abstraction', () async {
    final storage = MemoryChannels();
    final c = await configured(store: storage);
    expect(
      c.channels.map((v) => v.id),
      containsAll(['zhipu', 'deepseek', 'qwen', 'kimi', 'doubao', 'openai']),
    );
    expect(TranslationLanguage.values.length, 10);
    expect(c.activeChannel!.keyHint, '已保存 · ••••1234');
    final restored = TranslationController(storage: storage);
    await restored.initialize();
    expect(restored.activeChannel!.apiKey, 'test-secret-1234');
    await restored.saveChannel(
      const TranslationChannel(
        id: 'custom_test',
        name: 'Local',
        baseUrl: 'http://localhost:11434/v1/chat/completions',
        model: 'local',
        apiKey: 'local-token',
        isCustom: true,
      ),
    );
    await restored.selectChannel('custom_test');
    expect(restored.activeId, 'custom_test');
    await restored.removeChannel('custom_test');
    expect(restored.channels.where((v) => v.id == 'custom_test'), isEmpty);
    expect(restored.activeId, 'zhipu');
    await restored.saveChannel(restored.activeChannel!.copyWith(apiKey: ''));
    expect(restored.activeChannel!.configured, false);
    c.dispose();
    restored.dispose();
  });
  test('Storage failure preserves previous channel and key; read failure never overwrites data', () async {
    final storage = MemoryChannels();
    final c = await configured(store: storage);
    final before = storage.value;
    storage.failWrite = true;
    expect(
      await c.saveChannel(c.activeChannel!.copyWith(apiKey: 'replacement')),
      false,
    );
    expect(c.activeChannel!.apiKey, 'test-secret-1234');
    expect(storage.value, before);
    expect(c.configError, isNotNull);
    final broken = TranslationController(
      storage: MemoryChannels()..failRead = true,
    );
    await broken.initialize();
    expect(broken.initialized, false);
    expect(await broken.saveChannel(readyChannel()), false);
    c.dispose();
    broken.dispose();
  });
  test('Request uses direct bearer auth, text-only prompt, target language and preserves UTF-8', () async {
    late http.Request captured;
    final service = TranslationService(
      clientFactory: () => MockClient((r) async {
        captured = r;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '你好\n世界'},
              },
            ],
            'usage': {'total_tokens': 8},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final result = await service
        .start(
          text: 'Hello\nworld',
          from: TranslationLanguage.auto,
          to: TranslationLanguage.zh,
          channel: readyChannel(),
        )
        .future;
    expect(captured.url.host, 'open.bigmodel.cn');
    expect(captured.headers['Authorization'], 'Bearer test-secret-1234');
    final body = jsonDecode(captured.body) as Map;
    expect(body['stream'], false);
    expect(body['temperature'], .3);
    expect(body['model'], 'glm-4-flash');
    expect((body['messages'] as List).last['content'], contains('简体中文'));
    expect(captured.body, isNot(contains('image_url')));
    expect(result.translatedText, '你好\n世界');
    expect(result.tokensUsed, 8);
  });
  for (final status in [401, 403, 404, 429, 503]) {
    test(
      'HTTP $status produces actionable error without leaking credentials or server body',
      () async {
        final service = TranslationService(
          clientFactory: () => MockClient(
            (_) async =>
                http.Response('test-secret-1234 PRIVATE SERVER BODY', status),
          ),
        );
        try {
          await service
              .start(
                text: 'Hello',
                from: TranslationLanguage.en,
                to: TranslationLanguage.zh,
                channel: readyChannel(),
              )
              .future;
          fail('Expected error');
        } on TranslationException catch (e) {
          expect(e.statusCode, status);
          expect(e.message, isNot(contains('test-secret')));
          expect(e.message, isNot(contains('PRIVATE')));
        }
      },
    );
  }
  test('Cancellation finishes promptly and a late response never overwrites edited text', () async {
    final reply = Completer<http.Response>();
    final c = await configured(
      service: TranslationService(
        clientFactory: () => MockClient((_) => reply.future),
      ),
    );
    c.setSource('Original');
    final pending = c.translate();
    await Future<void>.delayed(Duration.zero);
    expect(c.translating, true);
    c.setSource('New text');
    expect(c.translating, false);
    await pending.timeout(const Duration(seconds: 1));
    reply.complete(
      http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Late'},
            },
          ],
        }),
        200,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.result, isNull);
    expect(c.sourceText, 'New text');
    c.dispose();
  });
  test('Malformed, empty and truncated responses fail; network request has timeout', () async {
    for (final body in [
      'not JSON',
      '{"choices":[]}',
      '{"choices":[{"message":{"content":""}}]}',
      '{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}',
    ]) {
      final service = TranslationService(
        clientFactory: () => MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        service
            .start(
              text: 'Hello',
              from: TranslationLanguage.auto,
              to: TranslationLanguage.zh,
              channel: readyChannel(),
            )
            .future,
        throwsA(isA<TranslationException>()),
      );
    }
    final service = TranslationService(
      timeout: const Duration(milliseconds: 15),
      clientFactory: () => MockClient((_) => Completer<http.Response>().future),
    );
    await expectLater(
      service
          .start(
            text: 'Hello',
            from: TranslationLanguage.auto,
            to: TranslationLanguage.zh,
            channel: readyChannel(),
          )
          .future,
      throwsA(isA<TranslationException>()),
    );
    expect(
      validateTranslationEndpoint('http://localhost:11434/v1/chat/completions'),
      isNull,
    );
    expect(
      validateTranslationEndpoint('http://example.com/v1/chat/completions'),
      isNotNull,
    );
  });
  for (final size in [const Size(900, 660), const Size(440, 620)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'Translation workflow at $size dark=$dark has no overflow and copies translation',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = await configured();
          addTearDown(c.dispose);
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: screenClipTheme(dark ? Brightness.dark : Brightness.light),
              home: TranslationPanel(
                controller: c,
                onClose: () {},
                openUrl: (_) async {},
              ),
            ),
          );
          await tester.enterText(
            find.byKey(const ValueKey('translation-source')),
            'Hello world.',
          );
          await tester.pump();
          await tester.tap(find.widgetWithText(FilledButton, '翻译'));
          await tester.pumpAndSettle();
          expect(find.text('你好，世界。\n保留换行。'), findsOneWidget);
          await tester.tap(find.widgetWithText(OutlinedButton, '复制译文'));
          await tester.pumpAndSettle();
          expect(copied, '你好，世界。\n保留换行。');
          expect(find.text('已复制译文'), findsOneWidget);
          await tester.tap(find.byTooltip('翻译渠道设置'));
          await tester.pumpAndSettle();
          expect(find.textContaining('••••1234'), findsOneWidget);
          expect(find.textContaining('test-secret-1234'), findsNothing);
          await tester.tap(find.text('配置').first);
          await tester.pumpAndSettle();
          final keyFields = tester
              .widgetList<TextField>(find.byType(TextField))
              .where((v) => v.obscureText);
          expect(keyFields.single.controller!.text, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final mode in ['success', 'missing', 'malformed', 'cancel']) {
    testWidgets(
      'Screenshot image translation $mode preserves screenshot and handles state',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = TranslateOcrBridge();
        final lateResponse = Completer<http.Response>();
        final translation = mode == 'missing'
            ? TranslationController(storage: MemoryChannels())
            : await configured(
                service: mode == 'cancel'
                    ? TranslationService(
                        clientFactory: () =>
                            MockClient((_) => lateResponse.future),
                      )
                    : mode == 'malformed'
                    ? TranslationService(
                        clientFactory: () => MockClient(
                          (_) async => http.Response(
                            jsonEncode({
                              'choices': [
                                {
                                  'message': {'content': '[]'},
                                },
                              ],
                            }),
                            200,
                          ),
                        ),
                      )
                    : null,
              );
        final c = ClipController(bridge: bridge, translation: translation)
          ..ready = true;
        addTearDown(c.dispose);
        late Clip clip;
        await tester.runAsync(() async {
          final image = await sample(width: 1000, height: 700);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          clip = Clip(
            bytes: data!.buffer.asUint8List(),
            width: 1000,
            height: 700,
            mode: 'screen',
          );
          image.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: CaptureEditor(clip: clip, controller: c),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('翻译选区文字'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        if (mode == 'cancel') {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump(const Duration(milliseconds: 350));
          expect(find.byType(OcrScanOverlay), findsOneWidget);
          await tester.tap(find.byTooltip('取消翻译'));
          lateResponse.complete(
            http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '["late"]'},
                  },
                ],
              }),
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(OcrScanOverlay), findsNothing);
          expect(find.text('翻译完成'), findsNothing);
          expect(tester.takeException(), isNull);
          return;
        }
        await tester.pumpAndSettle();
        if (mode == 'missing') {
          expect(bridge.recognized, 0);
          expect(find.byType(TranslationPanel), findsOneWidget);
          expect(find.text('翻译渠道'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭翻译 · Esc'));
          await tester.pumpAndSettle();
          expect(find.byType(TranslationPanel), findsNothing);
          expect(tester.takeException(), isNull);
          return;
        }
        expect(bridge.recognized, 1);
        expect(translation.sourceText, 'Hello world');
        expect(find.byType(TranslationPanel), findsNothing);
        List<Mark> annotations() => tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<SelectionPainter>()
            .first
            .marks;
        if (mode == 'malformed') {
          expect(annotations(), isEmpty);
          expect(find.text('翻译未完成'), findsOneWidget);
          expect(find.byTooltip('重试翻译'), findsOneWidget);
          expect(tester.takeException(), isNull);
          return;
        }
        expect(annotations().single.text, '你好，世界。');
        expect(annotations().single.background.a, 1);
        expect(annotations().single.tool, MarkTool.text);
        final completed = translation.result;
        await tester.tap(find.byTooltip('对照阅读'));
        await tester.pumpAndSettle();
        expect(find.byType(TranslationReadingPanel), findsOneWidget);
        expect(
          annotations(),
          isEmpty,
          reason: 'Reading mode hides translation annotations from the capture layer',
        );
        expect(identical(translation.result, completed), isTrue);
        expect(bridge.recognized, 1);
        await tester.tap(find.byTooltip('关闭对照阅读'));
        await tester.pumpAndSettle();
        expect(find.byType(TranslationReadingPanel), findsNothing);
        expect(annotations().single.text, '你好，世界。');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
        expect(annotations(), isEmpty);
        expect(find.byType(CaptureEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
