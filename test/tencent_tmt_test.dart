import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_clip_win/translation/controller.dart';
import 'package:screen_clip_win/translation/models.dart';
import 'package:screen_clip_win/translation/service.dart';
import 'package:screen_clip_win/translation/tencent_tmt.dart';
import 'package:screen_clip_win/translation/ui/channel_settings.dart';

import 'translation_test.dart' show MemoryChannels;

TranslationChannel tmt() => defaultTranslationChannels()
    .singleWhere((c) => c.isTencentTmt)
    .copyWith(secretId: 'fake-secret-id', apiKey: 'fake-secret-key');
http.Response response(Object data) => http.Response(
  jsonEncode({'Response': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Finder input(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('TC3 request matches independently computed UTF-8 HMAC fixture using UTC date', () {
    final body = jsonEncode({
      'SourceText': 'Hello 世界',
      'Source': 'en',
      'Target': 'zh',
      'ProjectId': 0,
    });
    final headers = tmtSignedHeaders(
      channel: tmt(),
      body: body,
      now: DateTime.fromMillisecondsSinceEpoch(
        1551113065 * 1000,
        isUtc: true,
      ).add(const Duration(hours: 8)).subtract(const Duration(hours: 8)),
    );
    expect(
      headers['Authorization'],
      'TC3-HMAC-SHA256 Credential=fake-secret-id/2019-02-25/tmt/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=d448ce37bb4f4cafdc6efc0a61e2c8822af1057151eb72dc4c65739609bd90f5',
    );
    expect(headers['X-TC-Timestamp'], '1551113065');
    expect(headers['X-TC-Region'], 'ap-guangzhou');
    expect(headers.values.any((v) => v.contains('fake-secret-key')), isFalse);
  });
  test('Long Unicode text is segmented without losing scalar values or paragraph boundaries', () {
    final text = '${'a' * 1999}😀${'b' * 1000}\n${'c' * 2100}';
    final chunks = tmtChunks(text);
    expect(chunks.join(), text);
    expect(chunks.every((c) => c.length <= 2000), isTrue);
    for (final c in chunks) {
      expect(utf8.decode(utf8.encode(c)), c);
    }
    expect(validateTmtEndpoint('https://evil.example'), isNotNull);
    expect(validateTmtEndpoint('https://tmt.tencentcloudapi.com/a'), isNotNull);
    expect(
      validateTmtEndpoint('https://tmt.ap-guangzhou.tencentcloudapi.com'),
      isNull,
    );
  });
  test('TMT signs native payload, maps Japanese and Korean, and preserves OCR array order', () async {
    final calls = <Map>[];
    final service = TranslationService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        calls.add(body);
        expect(request.headers['X-TC-Action'], 'TextTranslate');
        expect(request.headers['X-TC-Version'], '2018-03-21');
        expect(request.headers['Authorization'], startsWith('TC3-HMAC-SHA256'));
        expect(body['Source'], 'ja');
        expect(body['Target'], 'ko');
        expect(body['ProjectId'], 42);
        expect(body.containsKey('model'), isFalse);
        return response({
          'TargetText': '译文${calls.length}',
          'RequestId': 'test',
        });
      }),
    );
    final result = await service
        .start(
          text: 'First\nSecond',
          from: TranslationLanguage.ja,
          to: TranslationLanguage.ko,
          channel: tmt().copyWith(projectId: 42),
          segments: ['First', 'Second'],
        )
        .future;
    expect(jsonDecode(result.translatedText), ['译文1', '译文2']);
    expect(calls.map((v) => v['SourceText']), ['First', 'Second']);
    expect(result.tokensUsed, 0);
  });
  test('Long source translates in bounded chunks and cancellation stops following requests', () async {
    var calls = 0;
    final service = TranslationService(
      clientFactory: () => MockClient((request) async {
        calls++;
        final body = jsonDecode(utf8.decode(request.bodyBytes));
        expect((body['SourceText'] as String).length, lessThanOrEqualTo(2000));
        return response({'TargetText': '译文'});
      }),
    );
    final translated = await service
        .start(
          text: 'a' * 4001,
          from: TranslationLanguage.auto,
          to: TranslationLanguage.zh,
          channel: tmt(),
        )
        .future;
    expect(calls, 3);
    expect(translated.translatedText, '译文译文译文');
    final pending = Completer<http.Response>();
    var cancelCalls = 0;
    final cancelService = TranslationService(
      clientFactory: () => MockClient((_) {
        cancelCalls++;
        return pending.future;
      }),
    );
    final task = cancelService.start(
      text: 'First\nSecond',
      from: TranslationLanguage.auto,
      to: TranslationLanguage.zh,
      channel: tmt(),
      segments: ['First', 'Second'],
    );
    final check = expectLater(
      task.future,
      throwsA(isA<TranslationCancelled>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    task.cancel();
    await check;
    pending.complete(response({'TargetText': 'late'}));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(cancelCalls, 1);
  });
  for (final entry in {
    'AuthFailure.SignatureFailure': '认证失败',
    'FailedOperation.UserNotRegistered': '尚未开通',
    'FailedOperation.ServiceIsolate': '额度不足',
    'RequestLimitExceeded': '频率受限',
    'UnsupportedOperation.UnsupportedLanguage': '语言组合',
  }.entries) {
    test(
      'TMT error ${entry.key} is actionable and hides server secrets',
      () async {
        final service = TranslationService(
          clientFactory: () => MockClient(
            (_) async => response({
              'Error': {
                'Code': entry.key,
                'Message': 'fake-secret-key secret payload',
              },
            }),
          ),
        );
        await expectLater(
          service
              .start(
                text: 'Hello',
                from: TranslationLanguage.auto,
                to: TranslationLanguage.zh,
                channel: tmt(),
              )
              .future,
          throwsA(
            isA<TranslationException>()
                .having((e) => e.message, 'message', contains(entry.value))
                .having(
                  (e) => e.message.contains('fake-secret-key'),
                  'redaction',
                  isFalse,
                ),
          ),
        );
      },
    );
  }

  test('TMT preserves paragraph whitespace and rejects malformed returns or untrusted endpoints', () async {
    var calls = 0;
    final service = TranslationService(
      clientFactory: () => MockClient((_) async {
        calls++;
        return response({'TargetText': '译文'});
      }),
    );
    final text = '${'x' * 1900}\n\n${'y' * 1000}';
    expect(
      (await service
              .start(
                text: text,
                from: TranslationLanguage.en,
                to: TranslationLanguage.zh,
                channel: tmt(),
              )
              .future)
          .translatedText,
      '译文\n\n译文',
    );
    final before = calls;
    await expectLater(
      service
          .start(
            text: 'Hello',
            from: TranslationLanguage.en,
            to: TranslationLanguage.zh,
            channel: tmt().copyWith(baseUrl: 'https://other.example'),
          )
          .future,
      throwsA(isA<TranslationException>()),
    );
    expect(calls, before);
    for (final data in [
      response({'TargetText': ''}),
      http.Response('bad json', 200),
      http.Response('untrusted secret', 503),
    ]) {
      final badService = TranslationService(
        clientFactory: () => MockClient((_) async => data),
      );
      await expectLater(
        badService
            .start(
              text: 'Hello',
              from: TranslationLanguage.en,
              to: TranslationLanguage.zh,
              channel: tmt(),
            )
            .future,
        throwsA(isA<TranslationException>()),
      );
    }
  });
  test('Existing secure settings gain TMT preset and preserve credentials across restart', () async {
    final storage = MemoryChannels()
      ..value = jsonEncode({
        'channels': [
          defaultTranslationChannels().first
              .copyWith(apiKey: 'existing')
              .toJson(),
        ],
        'activeId': 'zhipu',
      });
    final c = TranslationController(storage: storage);
    await c.initialize();
    expect(c.channels.singleWhere((v) => v.isTencentTmt).configured, isFalse);
    expect(c.activeChannel!.apiKey, 'existing');
    await c.saveChannel(tmt().copyWith(region: 'ap-shanghai', projectId: 12));
    await c.selectChannel('tencent_tmt');
    final restored = TranslationController(storage: storage);
    await restored.initialize();
    expect(restored.activeChannel!.secretId, 'fake-secret-id');
    expect(restored.activeChannel!.apiKey, 'fake-secret-key');
    expect(restored.activeChannel!.region, 'ap-shanghai');
    expect(restored.activeChannel!.projectId, 12);
    await restored.saveChannel(
      restored.activeChannel!.copyWith(apiKey: '', secretId: ''),
    );
    expect(restored.activeChannel!.configured, isFalse);
    c.dispose();
    restored.dispose();
  });
  testWidgets(
    'TMT config validates cloud credentials and saves region/project securely',
    (tester) async {
      tester.view.physicalSize = const Size(530, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      final c = TranslationController(
        storage: MemoryChannels(),
        service: TranslationService(
          clientFactory: () => MockClient((request) async {
            requests++;
            expect(
              request.headers['Authorization'],
              contains('Credential=new-secret-id/'),
            );
            expect(request.headers['X-TC-Region'], 'ap-shanghai');
            expect(jsonDecode(utf8.decode(request.bodyBytes))['ProjectId'], 2);
            return response({'TargetText': '你好'});
          }),
        ),
      );
      await c.initialize();
      addTearDown(c.dispose);
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelEditor(
              channel: c.channels.singleWhere((v) => v.isTencentTmt),
              controller: c,
              onBack: () => saved = true,
            ),
          ),
        ),
      );
      expect(input('模型名称 / 接入点 ID'), findsNothing);
      await tester.enterText(input('SecretId'), 'new-secret-id');
      await tester.ensureVisible(input('地域 Region'));
      await tester.enterText(input('地域 Region'), 'ap-shanghai');
      await tester.ensureVisible(input('项目 ID'));
      await tester.enterText(input('项目 ID'), '2');
      await tester.ensureVisible(input('SecretKey'));
      await tester.enterText(input('SecretKey'), 'new-secret-key');
      final verify = find.widgetWithText(OutlinedButton, '验证云密钥');
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(find.text('验证通过，云密钥与 TMT 服务可用'), findsOneWidget);
      final save = find.widgetWithText(FilledButton, '保存渠道');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      final cloud = c.channels.singleWhere((v) => v.isTencentTmt);
      expect(cloud.secretId, 'new-secret-id');
      expect(cloud.apiKey, 'new-secret-key');
      expect(cloud.projectId, 2);
      expect(cloud.region, 'ap-shanghai');
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
