import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:screen_clip_win/translation/ui/argos_settings.dart';
import 'package:screen_clip_win/translation/ui/language_controls.dart';
import 'package:screen_clip_win/translation/ui/translation_panel.dart';
import 'package:screen_clip_win/translation/controller.dart';

import 'translation_test.dart' show MemoryChannels;

import 'package:screen_clip_win/translation/argos_engine.dart';
import 'package:screen_clip_win/translation/models.dart';
import 'package:screen_clip_win/translation/service.dart';

class RecordingArgos extends ArgosEngine {
  Map<String, Object?>? request;
  bool cancelled = false;
  @override
  ArgosOperation run(
    Map<String, Object?> request, {
    void Function(String, double?)? onProgress,
    Duration timeout = const Duration(minutes: 3),
  }) {
    this.request = request;
    return ArgosOperation(
      Future.value({
        'text': jsonEncode(['第一段', '第二段']),
      }),
      () => cancelled = true,
    );
  }
}

class ReadyArgos extends ArgosEngine {
  @override
  ArgosOperation run(
    Map<String, Object?> request, {
    void Function(String, double?)? onProgress,
    Duration timeout = const Duration(minutes: 3),
  }) => ArgosOperation(Future.value({'ready': true}), () {});
}

class ProvisionArgos extends ArgosEngine {
  bool ready = false;
  @override
  ArgosOperation run(
    Map<String, Object?> request, {
    void Function(String, double?)? onProgress,
    Duration timeout = const Duration(minutes: 3),
  }) {
    if (request['command'] == 'install') ready = true;
    return ArgosOperation(
      Future.value(
        request['command'] == 'translate' ? {'text': '你好'} : {'ready': ready},
      ),
      () {},
    );
  }
}

class BackgroundArgos extends ProvisionArgos {
  Completer<Map<String, dynamic>>? installation;
  void Function(String, double?)? report;
  int installs = 0;
  bool downloadCancelled = false;
  @override
  ArgosOperation run(
    Map<String, Object?> request, {
    void Function(String, double?)? onProgress,
    Duration timeout = const Duration(minutes: 3),
  }) {
    if (request['command'] != 'install') return super.run(request);
    installs++;
    report = onProgress;
    final pending = installation = Completer<Map<String, dynamic>>();
    return ArgosOperation(pending.future, () {
      downloadCancelled = true;
      if (!pending.isCompleted) {
        pending.completeError(const TranslationCancelled());
      }
    });
  }
}

void main() {
  testWidgets(
    'Download survives settings dismissal, shares progress and enables local translation',
    (tester) async {
      final engine = BackgroundArgos();
      final c = TranslationController(
        storage: MemoryChannels(),
        service: TranslationService(argos: engine),
      );
      addTearDown(c.dispose);
      await c.initialize();
      Widget settings() => MaterialApp(
        home: Scaffold(
          body: ArgosSettings(
            controller: c,
            channel: c.activeChannel!,
            onBack: () {},
          ),
        ),
      );
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载中英语言包'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await c.downloadLocalModels();
      expect(engine.installs, 1);
      expect(engine.downloadCancelled, false);
      expect(c.downloadingLocalModels, true);
      engine.report!('正在下载英译中语言包', .25);
      await tester.pumpWidget(settings());
      await tester.pump();
      expect(find.text('正在下载英译中语言包'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .25,
      );
      engine.ready = true;
      engine.installation!.complete({'ready': true});
      await tester.pumpAndSettle();
      expect(c.activeChannel!.configured, true);
      expect(c.downloadingLocalModels, false);
      c.setSource('Hello');
      await c.translate();
      expect(c.result?.translatedText, '你好');
      expect(tester.takeException(), isNull);
    },
  );

  test('Failed background downloads can retry and cancellation leaves models unconfigured', () async {
    final engine = BackgroundArgos();
    final c = TranslationController(
      storage: MemoryChannels(),
      service: TranslationService(argos: engine),
    );
    addTearDown(c.dispose);
    await c.initialize();
    final failed = c.downloadLocalModels();
    engine.installation!.completeError(const TranslationException('网络不可用'));
    await failed;
    expect(c.localModelStatus, '网络不可用');
    expect(c.downloadingLocalModels, false);
    expect(c.activeChannel!.configured, false);
    final retry = c.downloadLocalModels();
    c.cancelModelDownload();
    await retry;
    expect(engine.installs, 2);
    expect(c.localModelStatus, contains('取消'));
    expect(c.activeChannel!.configured, false);
  });
  testWidgets(
    'Missing models prompt download and completion enables translation without saving',
    (tester) async {
      final engine = ProvisionArgos();
      final c = TranslationController(
        storage: MemoryChannels(),
        service: TranslationService(argos: engine),
      );
      addTearDown(c.dispose);
      await c.initialize();
      c.setSource('Hello');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranslationPanel(
              controller: c,
              onClose: () {},
              openUrl: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '翻译'));
      await tester.pumpAndSettle();
      expect(find.text('下载中英语言包'), findsOneWidget);
      expect(c.sourceText, 'Hello');
      await tester.tap(find.text('下载中英语言包'));
      await tester.pumpAndSettle();
      expect(find.text('保存并返回'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '翻译'));
      await tester.pumpAndSettle();
      expect(c.needsLocalModels, false);
      expect(c.result?.translatedText, '你好');
      expect(c.sourceText, 'Hello');
      expect(tester.takeException(), isNull);
    },
  );

  test('Default local translation requests a download without losing original text', () async {
    final c = TranslationController(
      storage: MemoryChannels(),
      service: TranslationService(argos: ProvisionArgos()),
    );
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.activeId, 'argos_local');
    expect(c.activeChannel!.isEnabled, true);
    c.setSource('Hello');
    await c.translate();
    expect(c.needsLocalModels, true);
    expect(c.sourceText, 'Hello');
    expect(c.error, contains('语言包'));
  });
  testWidgets(
    'Screenshot language controls select local languages and swap them',
    (tester) async {
      final c = TranslationController(storage: MemoryChannels());
      addTearDown(c.dispose);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TranslationLanguages(controller: c)),
        ),
      );
      await tester.tap(find.byTooltip('切换翻译目标语言'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('目标语言：英文'));
      await tester.pumpAndSettle();
      expect(c.to, TranslationLanguage.en);
      await tester.tap(find.byTooltip('交换翻译语言'));
      await tester.pumpAndSettle();
      expect(c.from, TranslationLanguage.en);
      expect(c.to, TranslationLanguage.zh);
    },
  );

  testWidgets(
    'Local settings have no key fields and preparing preserves default local enablement',
    (tester) async {
      final controller = TranslationController(
        storage: MemoryChannels(),
        service: TranslationService(argos: ReadyArgos()),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final channel = controller.channels.singleWhere((c) => c.isLocal);
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArgosSettings(
              controller: controller,
              channel: channel,
              onBack: () {},
              onSaved: () => saved = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('中英语言包已准备，可离线翻译'), findsOneWidget);
      await tester.ensureVisible(find.text('保存并返回'));
      await tester.tap(find.text('保存并返回'));
      await tester.pumpAndSettle();
      final restored = controller.channels.singleWhere((c) => c.isLocal);
      expect(restored.configured, isTrue);
      expect(restored.isEnabled, isTrue);
      expect(saved, isTrue);
    },
  );

  test('Local channel requires preparation, starts enabled and never requires a key', () {
    final channel = defaultTranslationChannels().singleWhere((c) => c.isLocal);
    expect(channel.isEnabled, true);
    expect(channel.configured, false);
    expect(channel.copyWith(model: 'ready').configured, true);
    expect(channel.apiKey, isEmpty);
    expect(
      TranslationChannel.fromJson(channel.copyWith(model: 'ready').toJson())
          .configured,
      true,
    );
  });
  test(
    'OCR segments use local route and return ordered JSON without HTTP',
    () async {
      final engine = RecordingArgos();
      final service = TranslationService(
        argos: engine,
        clientFactory: () => throw StateError('HTTP must not be created'),
      );
      final channel = defaultTranslationChannels().last.copyWith(
        model: 'ready',
        isEnabled: true,
      );
      final result = await service
          .start(
            text: 'first\nsecond',
            from: TranslationLanguage.en,
            to: TranslationLanguage.zh,
            channel: channel,
            segments: ['first', 'second'],
          )
          .future;
      expect(engine.request!['segments'], ['first', 'second']);
      expect(jsonDecode(result.translatedText), ['第一段', '第二段']);
      expect(result.tokensUsed, 0);
      service.dispose();
    },
  );
  test('Unprepared local channel fails without starting inference', () async {
    final engine = RecordingArgos();
    final service = TranslationService(argos: engine);
    await expectLater(
      service
          .start(
            text: 'hello',
            from: TranslationLanguage.en,
            to: TranslationLanguage.zh,
            channel: defaultTranslationChannels().last,
          )
          .future,
      throwsA(isA<TranslationException>()),
    );
    expect(engine.request, isNull);
    service.dispose();
  });
  test('Missing helper reports actionable installation error', () async {
    final engine = ArgosEngine(
      executable: '${Directory.systemTemp.path}/absent-argos-helper',
    );
    await expectLater(
      engine.run({'command': 'status'}).future,
      throwsA(isA<TranslationException>()),
    );
    engine.dispose();
  });
  test('Both platform bundle layouts resolve relative to the application', () {
    expect(
      ArgosEngine.bundledExecutable(
        '/app/Contents/MacOS/main',
        macOS: true,
      ).replaceAll('\\', '/'),
      endsWith('/Contents/Helpers/argos/screenclip_argos'),
    );
    expect(
      ArgosEngine.bundledExecutable(
        '/app/main.exe',
        macOS: false,
      ).replaceAll('\\', '/'),
      endsWith('/app/argos/screenclip_argos.exe'),
    );
  });
}
