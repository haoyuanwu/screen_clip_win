import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/controls.dart';
import 'package:screen_clip_win/src/ui/ocr_overlay.dart';

import 'widget_test.dart' show FakeBridge, sample;

void main() {
  for (final outcome in ['text', 'empty', 'error', 'cancel']) {
    testWidgets(
      'OCR recognizes selected PNG and handles $outcome without finishing capture',
      (tester) async {
        tester.view.physicalSize = const Size(640, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = FakeBridge('unused');
        final controller = ClipController(bridge: bridge)..ready = true;
        addTearDown(controller.dispose);
        late Clip clip;
        await tester.runAsync(() async {
          final image = await sample(width: 640, height: 480);
          clip = Clip(
            bytes: (await image.toByteData(format: ui.ImageByteFormat.png))!
                .buffer
                .asUint8List(),
            width: 640,
            height: 480,
          );
          image.dispose();
        });
        controller.clip = clip;
        var result = Completer<Map<String, Object>>();
        Uint8List? received;
        var calls = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('desktop_vision'),
          (call) async {
            expect(call.method, 'recognizeBytes');
            final args = call.arguments as Map;
            expect(args['languages'], ['zh-Hans', 'en-US']);
            expect(args['level'], 'accurate');
            received = args['bytes'] as Uint8List;
            calls++;
            return result.future;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('desktop_vision'),
            null,
          ),
        );
        String? copied;
        bool failCopy = false;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (failCopy) throw PlatformException(code: 'clipboard');
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: CaptureEditor(clip: clip, controller: controller),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        await tester.dragFrom(const Offset(60, 60), const Offset(440, 200));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('识别文字 · OCR'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump();
        expect(calls, 1);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(OcrScanOverlay), findsOneWidget);
        double scanProgress() => tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((p) => p.painter)
            .whereType<OcrScanPainter>()
            .single
            .progress;
        final initialProgress = scanProgress();
        await tester.pump(const Duration(milliseconds: 200));
        expect(scanProgress(), isNot(initialProgress));
        final button = tester.widget<ToolButton>(
          find
              .ancestor(
                of: find.byTooltip('识别文字 · OCR'),
                matching: find.byType(ToolButton),
              )
              .first,
        );
        expect(button.onPressed, isNull);
        await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(received!);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, 440);
          expect(frame.image.height, 200);
          frame.image.dispose();
          codec.dispose();
        });
        if (outcome == 'cancel') {
          final stale = result;
          await tester.tap(find.byTooltip('取消文字识别'));
          await tester.pumpAndSettle();
          expect(find.byType(OcrScanOverlay), findsNothing);
          result = Completer<Map<String, Object>>();
          await tester.tap(find.byTooltip('识别文字 · OCR'));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump();
          expect(calls, 2);
          stale.complete({'lines': <Object>[], 'text': 'stale'});
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(OcrScanOverlay), findsOneWidget);
          expect(find.byType(OcrTextOverlay), findsNothing);
          result.complete({'lines': <Object>[], 'text': ''});
          await tester.pumpAndSettle();
          expect(find.byType(OcrScanOverlay), findsNothing);
          expect(find.byType(OcrTextOverlay), findsOneWidget);
          expect(controller.clip, same(clip));
          expect(bridge.hidden, false);
          return;
        }
        if (outcome == 'error') {
          result.completeError(
            PlatformException(code: 'ocr_failed', message: '系统缺少 OCR 语言组件'),
          );
        } else {
          result.complete({
            'text': outcome == 'text' ? '截图文字\nScreen Clip 123' : '',
            'lines': outcome == 'text'
                ? <Object>[
                    {
                      'text': '截图文字',
                      'x': .1,
                      'y': .2,
                      'w': .4,
                      'h': .2,
                      'characters': [
                        for (final (i, char) in ['截', '图', '文', '字'].indexed)
                          {
                            'text': char,
                            'x': .1 + i * .1,
                            'y': .2,
                            'w': .1,
                            'h': .2,
                          },
                      ],
                    },
                    {
                      'text': 'Screen Clip 123',
                      'x': .1,
                      'y': .6,
                      'w': .75,
                      'h': .2,
                      'words': [
                        {'text': 'Screen', 'x': .1, 'y': .6, 'w': .3, 'h': .2},
                        {'text': 'Clip', 'x': .45, 'y': .6, 'w': .18, 'h': .2},
                        {'text': '123', 'x': .7, 'y': .6, 'w': .15, 'h': .2},
                      ],
                    },
                  ]
                : <Object>[],
            'imageWidth': 440,
            'imageHeight': 200,
            'engine': 'test',
          });
        }
        await tester.pumpAndSettle();
        expect(copied, isNull);
        expect(controller.clip, same(clip));
        expect(bridge.hidden, false);
        expect(find.byType(OcrScanOverlay), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        if (outcome == 'error') {
          expect(find.textContaining('系统缺少 OCR 语言组件'), findsOneWidget);
          expect(find.byType(OcrTextOverlay), findsNothing);
        } else {
          expect(find.byType(OcrTextOverlay), findsOneWidget);
          if (outcome == 'text') {
            final drag = await tester.startGesture(const Offset(104, 120));
            await drag.moveTo(const Offset(280, 120));
            await drag.up();
            await tester.pumpAndSettle();
            final overlay = tester.widget<OcrTextOverlay>(
              find.byType(OcrTextOverlay),
            );
            expect(overlay.selection.selectedText, '截图文字');
            expect(overlay.selection.highlights, hasLength(1));
            failCopy = true;
            await tester.tap(find.byTooltip('复制选中文字'));
            await tester.pumpAndSettle();
            expect(find.text('复制失败，请重试'), findsOneWidget);
            failCopy = false;
            await tester.tap(find.byTooltip('复制选中文字'));
            await tester.pumpAndSettle();
            expect(copied, '截图文字');
            expect(find.text('已复制'), findsOneWidget);
            // Reverse drag crosses lines and preserves spaces/newlines.
            final reverse = await tester.startGesture(const Offset(435, 200));
            await reverse.moveTo(const Offset(104, 120));
            await reverse.up();
            await tester.pumpAndSettle();
            expect(overlay.selection.selectedText, '截图文字\nScreen Clip 123');
            expect(overlay.selection.highlights, hasLength(2));
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pumpAndSettle();
            expect(copied, '截图文字\nScreen Clip 123');
            // OCR highlights are UI only, never pixels in a saved/copied shot.
            final capture = tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((p) => p.painter)
                .whereType<SelectionPainter>()
                .single;
            await tester.runAsync(() async {
              final exported = await renderCapture(
                capture.image!,
                capture.marks,
                capture.region,
                mosaic: capture.mosaic,
              );
              expect(exported, orderedEquals(received!));
            });
          } else {
            expect(find.textContaining('未识别到文字'), findsOneWidget);
            expect(find.byTooltip('复制选中文字'), findsNothing);
            expect(find.byTooltip('重试文字识别'), findsOneWidget);
          }
          tester.view.physicalSize = const Size(400, 300);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('退出文字识别'));
          await tester.pumpAndSettle();
          expect(find.byType(OcrTextOverlay), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
