import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';

class SmartSelectionBridge extends DesktopBridge {
  final focused = <int>[];
  final presented = <String>[];
  Uint8List? refreshed, copied;
  bool temporaryTopmost = false, failFocus = false, isolated = false;
  int dismissals = 0;
  @override
  Future<Map<Object?, Object?>?> focusCaptureWindow(int index) async {
    focused.add(index);
    if (failFocus) throw PlatformException(code: 'window', message: '窗口已关闭');
    temporaryTopmost = index >= 0 && !isolated;
    return refreshed == null ? null : {'bytes': refreshed};
  }

  @override
  Future<void> present(String panel) async {
    presented.add(panel);
  }

  @override
  Future<void> copy(Uint8List bytes) async {
    copied = bytes;
  }

  @override
  Future<void> notifyCopied() async {}
  @override
  Future<void> dismiss() async {
    temporaryTopmost = false;
    dismissals++;
  }
}

void main() {
  for (final (mode, reducedMotion) in [
    ('region', false),
    ('window', false),
    ('region', true),
  ]) {
    testWidgets('$mode clear preview and feedback (reduced: $reducedMotion)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = SmartSelectionBridge();
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(800, 600);
        picture.dispose();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        clip = Clip(
          bytes: data!.buffer.asUint8List(),
          width: 800,
          height: 600,
          mode: mode,
          windows: const [
            Rect.fromLTWH(100, 100, 300, 300),
            Rect.fromLTWH(50, 50, 600, 450),
          ],
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              disableAnimations: reducedMotion,
            ),
            child: CaptureEditor(clip: clip, controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      SelectionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<SelectionPainter>()
          .single;
      SelectionFeedbackPainter? feedback() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<SelectionFeedbackPainter>()
          .singleOrNull;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(750, 550));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(200, 200));
      await tester.pump();
      if (reducedMotion) {
        expect(feedback(), isNull);
      } else {
        expect(feedback()!.progress, 0);
        await tester.pump(const Duration(milliseconds: 40));
        expect(feedback()!.progress, inExclusiveRange(0, 1));
      }
      expect(painter().region, clip.windows.first);
      expect(painter().showHandles, isFalse);
      expect(
        find.byType(CustomPaint).evaluate().where((element) {
          return (element.widget as CustomPaint).painter is LoupePainter;
        }),
        isEmpty,
      );

      // Verify interior pixels during feedback, including non-uniform scaling.
      final preview = painter();
      final highlight = feedback();
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        preview.paint(canvas, const Size(400, 600));
        if (highlight != null) {
          canvas.save();
          canvas.scale(.5, 1);
          highlight.paint(canvas, const Size(800, 600));
          canvas.restore();
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 600);
        picture.dispose();
        final pixels = (await image.toByteData())!;
        expect(pixels.getUint8((200 * 400 + 100) * 4), 255);
        expect(pixels.getUint8((550 * 400 + 375) * 4), 153);
        image.dispose();
      });

      // Replacing an in-flight highlight updates the clear area immediately.
      await mouse.moveTo(const Offset(600, 450));
      await tester.pump();
      expect(painter().region, clip.windows.last);
      if (!reducedMotion) expect(feedback()!.progress, 0);
      await mouse.moveTo(const Offset(750, 550));
      await tester.pumpAndSettle();
      expect(painter().region, const Rect.fromLTWH(0, 0, 800, 600));
      if (!reducedMotion) {
        expect(feedback()!.rect, const Rect.fromLTWH(0, 0, 800, 600));
      }
      await tester.tapAt(const Offset(750, 550));
      await tester.pumpAndSettle();
      expect(painter().region, const Rect.fromLTWH(0, 0, 800, 600));
      expect(painter().showHandles, isTrue);
      expect(bridge.focused, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      if (mode == 'region') {
        await mouse.moveTo(const Offset(200, 200));
        await tester.pump();
        await tester.dragFrom(const Offset(200, 200), const Offset(80, 100));
        await tester.pumpAndSettle();
        expect(painter().region, const Rect.fromLTRB(200, 200, 280, 300));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(painter().showHandles, isFalse);
      }

      await tester.tapAt(const Offset(200, 200));
      await tester.pump();
      if (!reducedMotion) expect(feedback()!.confirmed, isTrue);
      await tester.pumpAndSettle();
      expect(painter().region, clip.windows.first);
      expect(painter().showHandles, isTrue);
      expect(bridge.focused, [0]);
      await mouse.moveTo(const Offset(600, 450));
      await tester.pumpAndSettle();
      expect(painter().region, clip.windows.first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(750, 550));
      await tester.pumpAndSettle();
      expect(bridge.focused, [0, -1]);
      expect(painter().region, const Rect.fromLTWH(0, 0, 800, 600));
    });
  }
  for (final outcome in ['copy', 'cancel', 'failure', 'isolated']) {
    testWidgets(
      'Smart selection refreshes pixels and keeps $outcome recoverable',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = SmartSelectionBridge()
          ..failFocus = outcome == 'failure'
          ..isolated = outcome == 'isolated';
        final controller = ClipController(bridge: bridge)..ready = true;
        addTearDown(controller.dispose);
        late Clip clip;
        await tester.runAsync(() async {
          Future<Uint8List> frame(Color color) async {
            final recorder = ui.PictureRecorder();
            Canvas(recorder).drawColor(color, BlendMode.src);
            final picture = recorder.endRecording();
            final image = await picture.toImage(800, 600);
            picture.dispose();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            image.dispose();
            return bytes;
          }

          bridge.refreshed = await frame(Colors.blue);
          clip = Clip(
            bytes: await frame(Colors.white),
            width: 800,
            height: 600,
            windows: const [Rect.fromLTWH(100, 100, 300, 300)],
          );
          controller.clip = clip;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: CaptureEditor(clip: clip, controller: controller),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(250, 250));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<SelectionPainter>()
            .single;
        expect(painter.region, clip.windows.first);
        expect(bridge.focused, [0]);
        await tester.runAsync(() async {
          final pixel = (await painter.image!.toByteData())!;
          expect(
            pixel.getUint8(0),
            outcome == 'failure' ? 255 : (Colors.blue.toARGB32() >> 16) & 255,
          );
        });
        if (outcome == 'copy') {
          expect(bridge.temporaryTopmost, isTrue);
          await tester.tap(find.byTooltip('复制到剪贴板 · Enter'));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pumpAndSettle();
          expect(bridge.copied, isNotNull);
          expect(controller.clip, isNull);
        } else {
          if (outcome == 'failure') {
            expect(find.textContaining('窗口画面获取失败'), findsOneWidget);
            expect(bridge.temporaryTopmost, isFalse);
          } else {
            expect(bridge.temporaryTopmost, outcome != 'isolated');
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        expect(bridge.dismissals, 1);
        expect(bridge.temporaryTopmost, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
