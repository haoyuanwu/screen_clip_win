import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/workspace.dart';
import 'package:screen_clip_win/translation/controller.dart';
import 'package:screen_clip_win/translation/service.dart';
import 'package:screen_clip_win/translation/ui/channel_settings.dart';
import 'package:screen_clip_win/translation/ui/translation_panel.dart';

import 'translation_test.dart' show configured, MemoryChannels;
import 'translation_reading_test.dart' show ReadingOcrBridge;
import 'widget_test.dart' show sample;

Finder input(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
http.Response reply(String text) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': text},
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  for (final mode in ['success', 'stored', 'unauthorized', 'cancel']) {
    testWidgets('Key validation uses unsaved input and handles $mode', (
      tester,
    ) async {
      var requests = 0;
      final pending = Completer<http.Response>();
      final c = await configured(
        service: TranslationService(
          clientFactory: () => MockClient((request) async {
            requests++;
            expect(
              request.headers['Authorization'],
              mode == 'stored'
                  ? 'Bearer test-secret-1234'
                  : 'Bearer unsaved-key',
            );
            final body = jsonDecode(request.body);
            expect(body['max_tokens'], 64);
            expect(body['messages'][1]['content'], contains('Hello'));
            if (mode == 'cancel') return pending.future;
            if (mode == 'unauthorized') {
              return http.Response('sensitive server body', 401);
            }
            return reply('你好');
          }),
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelEditor(
              channel: c.channels.first,
              controller: c,
              onBack: () {},
            ),
          ),
        ),
      );
      if (mode != 'stored') {
        await tester.enterText(input('API Key'), 'unsaved-key');
      }
      final verify = find.widgetWithText(OutlinedButton, '验证 API Key');
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pump();
      if (mode == 'cancel') {
        expect(find.text('验证中…'), findsOneWidget);
        await tester.ensureVisible(input('API Key'));
        await tester.enterText(input('API Key'), 'changed-key');
        pending.complete(reply('你好'));
        await tester.pumpAndSettle();
        expect(find.text('验证通过，当前 Key 与模型可用'), findsNothing);
      } else {
        await tester.pumpAndSettle();
        expect(
          find.textContaining(mode == 'unauthorized' ? '认证失败' : '验证通过'),
          findsOneWidget,
        );
        expect(find.textContaining('sensitive server body'), findsNothing);
        if (mode == 'success') {
          await tester.ensureVisible(input('模型名称 / 接入点 ID'));
          await tester.enterText(input('模型名称 / 接入点 ID'), 'another-model');
          await tester.pumpAndSettle();
          expect(find.text('验证通过，当前 Key 与模型可用'), findsNothing);
        }
      }
      expect(
        c.channels.first.apiKey,
        'test-secret-1234',
        reason: 'Verification does not save or replace the stored key',
      );
      expect(c.result, isNull);
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Configuring and validating from capture preserves crop and resumes translation after save',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      final storage = MemoryChannels();
      final translation = TranslationController(
        storage: storage,
        service: TranslationService(
          clientFactory: () => MockClient((request) async {
            requests++;
            final body = jsonDecode(request.body);
            return reply(
              body['max_tokens'] == 64 ? '你好' : jsonEncode(['第一段', '第二段']),
            );
          }),
        ),
      );
      await translation.initialize();
      await translation.selectChannel('zhipu');
      final bridge = ReadingOcrBridge();
      final c = ClipController(bridge: bridge, translation: translation)
        ..ready = true
        ..panel = 'capture';
      addTearDown(c.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final image = await sample(width: 1000, height: 700);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        clip = Clip(
          bytes: bytes!.buffer.asUint8List(),
          width: 1000,
          height: 700,
          mode: 'screen',
        );
      });
      c.clip = clip;
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Workspace(controller: c),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      SelectionPainter capture() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SelectionPainter>()
          .first;
      await tester.tap(find.byTooltip('画笔 · P'));
      await tester.dragFrom(const Offset(40, 40), const Offset(80, 60));
      await tester.pumpAndSettle();
      final originalMark = capture().marks.single;
      final selection = capture().region;
      await tester.tap(find.byTooltip('翻译选区文字'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('翻译语言'), findsNothing);
      expect(find.byTooltip('切换翻译目标语言'), findsOneWidget);
      await tester.tap(find.byTooltip('按当前语言翻译'));
      await tester.pumpAndSettle();
      expect(c.panel, 'capture');
      expect(identical(c.clip, clip), isTrue);
      expect(capture().region, selection);
      expect(
        translation.channels
            .where((c) => !c.isLocal)
            .every((c) => !c.isEnabled),
        isTrue,
      );
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置').first);
      await tester.pumpAndSettle();
      await tester.enterText(input('API Key'), 'new-capture-key');
      final verify = find.widgetWithText(OutlinedButton, '验证 API Key');
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(find.text('验证通过，当前 Key 与模型可用'), findsOneWidget);
      expect(bridge.recognized, 0);
      expect(capture().region, selection);
      final save = find.widgetWithText(FilledButton, '保存并继续截图');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TranslationPanel), findsNothing);
      expect(c.panel, 'capture');
      expect(identical(c.clip, clip), isTrue);
      expect(capture().region, selection);
      expect(identical(capture().marks.first, originalMark), isTrue);
      expect(
        capture().marks
            .where((m) => m.translationId != null)
            .map((m) => m.text),
        ['第一段', '第二段'],
      );
      expect(bridge.hidden, isFalse);
      expect(requests, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
