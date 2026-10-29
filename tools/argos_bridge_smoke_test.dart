import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/translation/argos_engine.dart';
import 'package:screen_clip_win/translation/models.dart';
import 'package:screen_clip_win/translation/service.dart';

void main() {
  final helper = Platform.environment['SCREENCLIP_ARGOS_WORKER'];
  final directory = Platform.environment['SCREENCLIP_ARGOS_MODELS'];
  if (helper == null || directory == null) {
    throw StateError(
      'Set SCREENCLIP_ARGOS_WORKER and SCREENCLIP_ARGOS_MODELS to run real model acceptance.',
    );
  }
  test('Packaged helper bridges real bidirectional translation, OCR order and cancellation', () async {
    final engine = ArgosEngine(executable: helper, directory: directory);
    final service = TranslationService(
      argos: engine,
      clientFactory: () =>
          throw StateError('Local translation must not create HTTP client'),
    );
    addTearDown(service.dispose);
    expect((await engine.run({'command': 'status'}).future)['ready'], isTrue);
    final channel = defaultTranslationChannels()
        .singleWhere((c) => c.isLocal)
        .copyWith(model: 'ready', isEnabled: true);
    Future<String> translate(
      String text,
      TranslationLanguage from,
      TranslationLanguage to, {
      List<String>? segments,
    }) async =>
        (await service
                .start(
                  text: text,
                  from: from,
                  to: to,
                  channel: channel,
                  segments: segments,
                )
                .future)
            .translatedText;
    final zh = await translate(
      'Hello world!',
      TranslationLanguage.en,
      TranslationLanguage.zh,
    );
    final en = await translate(
      '你好，世界！',
      TranslationLanguage.zh,
      TranslationLanguage.en,
    );
    expect(RegExp(r'[\u3400-\u9fff]').hasMatch(zh), true);
    expect(RegExp(r'[a-zA-Z]').hasMatch(en), true);
    final ordered = jsonDecode(
      await translate(
        'Hello world!\nThank you.',
        TranslationLanguage.en,
        TranslationLanguage.zh,
        segments: ['Hello world!', '', 'Thank you.'],
      ),
    ) as List;
    expect(ordered.length, 3);
    expect(ordered[1], isEmpty);
    expect(ordered[0], zh);
    final cancellation = engine.run({
      'command': 'translate',
      'text': 'Hello world!',
      'from': 'en',
      'to': 'zh',
    });
    final cancelled = expectLater(
      cancellation.future,
      throwsA(isA<TranslationCancelled>()),
    );
    cancellation.cancel();
    await cancelled;
    // Synthetic fixtures only, never user data.
    // ignore: avoid_print
    print(
      'REAL ARGOS ${Platform.operatingSystem}: en→zh=$zh; zh→en=$en; OCR segments=$ordered',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
