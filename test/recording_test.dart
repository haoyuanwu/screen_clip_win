import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/recording.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:flutter/foundation.dart';

import 'adaptive_toolbar_test.dart' as editor_test;

import 'package:screen_clip_win/src/ui/recording_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ScreenRecording.channel, (call) async {
          calls.add(call.method);
          if (call.method == 'prepareRecording') return true;
          if (call.method == 'stopRecording') return '/tmp/test.mp4';
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ScreenRecording.channel, null),
  );
  test('start and stop completes file lifecycle', () async {
    final r = ScreenRecording(demo: false);
    await r.start();
    expect(r.active, isTrue);
    await r.stop();
    expect(r.active, isFalse);
    expect(r.savedPath, '/tmp/test.mp4');
    expect(calls, [
      'prepareRecording',
      'dismiss',
      'startRecording',
      'stopRecording',
    ]);
    r.dispose();
  });
  test('menu bar stop shares recording state without stopping twice', () async {
    var exited = false;
    final r = ScreenRecording(demo: false, onExit: () async => exited = true);
    addTearDown(r.dispose);
    await r.start();
    r.beginNativeStop();
    expect(r.busy, isTrue);
    await r.stop();
    expect(calls, isNot(contains('stopRecording')));
    await r.finishStop(path: '/tmp/menu-bar.mp4');
    expect(r.engaged, isFalse);
    expect(r.savedPath, '/tmp/menu-bar.mp4');
    expect(exited, isTrue);
  });

  testWidgets('countdown can be cancelled before native capture starts', (
    tester,
  ) async {
    final r = ScreenRecording(demo: false)..delay = 3;
    final pending = r.start();
    await tester.pump();
    expect(r.remaining, 3);
    r.cancelCountdown();
    await tester.pump(const Duration(seconds: 1));
    await pending;
    expect(calls, ['prepareRecording', 'cancelPreparedRecording']);
    expect(r.engaged, isFalse);
    r.dispose();
  });
  testWidgets(
    'settings fit compact toolbar and expose formats and frame rates',
    (tester) async {
      tester.view.physicalSize = const Size(440, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = ScreenRecording(demo: false);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: key,
                child: RecordingControls(recording: r),
              ),
            ),
          ),
        ),
      );
      expect(find.text('立即 · MP4 · 60 fps'), findsOneWidget);
      expect(find.text('延迟'), findsNothing);
      expect(find.text('开始录制'), findsOneWidget);
      expect(find.text('60 fps'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('/tmp/dingge-recording-controls.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      r.dispose();
    },
  );

  testWidgets(
    'recording uses selected region and format/frame choices work inside editor',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await editor_test.mount(tester, const Size(1200, 900));
      final editor = tester.widget<CaptureEditor>(find.byType(CaptureEditor));
      expect(find.text('录屏'), findsOneWidget);
      await tester.tap(find.byTooltip('录屏'));
      await tester.pumpAndSettle();
      expect(
        editor.controller.recording.region,
        const Rect.fromLTWH(0, 0, 1000, 750),
      );
      await tester.tap(find.byTooltip('展开录制规格'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MOV'));
      await tester.pumpAndSettle();
      expect(editor.controller.recording.format, 'mov');
      await tester.tap(find.text('120 fps'));
      await tester.pumpAndSettle();
      expect(editor.controller.recording.fps, 120);
      await tester.tap(find.text('3s'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起录制规格'));
      await tester.pumpAndSettle();
      expect(find.text('3s 延迟 · MOV · 120 fps'), findsOneWidget);
      expect(find.text('帧率'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'debug UI demo does not invoke permission or native recording methods',
    () async {
      final r = ScreenRecording(demo: true);
      await r.start();
      expect(r.active, isTrue);
      await r.stop();
      expect(calls, [
        'dismiss',
        'setDemoRecordingIndicator',
        'setDemoRecordingIndicator',
      ]);
      expect(r.savedPath, isNull);
      expect(r.notice, contains('未生成视频'));
      r.dispose();
    },
  );
}
