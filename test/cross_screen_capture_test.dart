import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/controls.dart';
import 'package:screen_clip_win/src/workspace.dart';
import 'package:screen_clip_win/src/ui/capture_mirrors.dart';
import 'package:screen_clip_win/src/ui/color_preview.dart';

import 'widget_test.dart' show FakeBridge;

class FrameBridge extends FakeBridge {
  FrameBridge() : super('unused');
  int readyFrames = 0;
  bool rejectNextFrame = false;
  Size? viewport;
  @override
  Future<bool> captureFrameReady(Size viewport) async {
    readyFrames++;
    this.viewport = viewport;
    if (rejectNextFrame) {
      rejectNextFrame = false;
      return false;
    }
    return true;
  }
}

void main() {
  for (final mode in ['region', 'color']) {
    testWidgets(
      'Hidden $mode capture renders without pointer input and retries a stale viewport',
      (tester) async {
        final bridge = FrameBridge()..rejectNextFrame = true;
        final controller = ClipController(bridge: bridge)..ready = true;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => Workspace(controller: controller),
            ),
          ),
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..drawColor(Colors.red, BlendMode.src);
          canvas.drawRect(
            const Rect.fromLTWH(400, 0, 400, 600),
            Paint()..color = Colors.green,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(800, 600);
          picture.dispose();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await controller.loadBytes(
            data!.buffer.asUint8List(),
            mode: mode,
            windows: const [
              Rect.fromLTWH(0, 0, 400, 600),
              Rect.fromLTWH(400, 0, 400, 600),
            ],
          );
          // No pump, click, key, or lifecycle resume: the capture must wake itself.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(bridge.readyFrames, 2);
          for (final x in [100.0, 600.0, 100.0]) {
            dispatchCapturePointer({
              'x': x,
              'y': 100.0,
              'time': x + 1000,
              'buttons': 0,
              'type': 'pointer',
            });
            // Occlusion must not freeze hover or samples until the next click.
            await Future<void>.delayed(const Duration(milliseconds: 80));
            if (mode == 'region') {
              final painter = tester
                  .widgetList<CustomPaint>(find.byType(CustomPaint))
                  .map((w) => w.painter)
                  .whereType<SelectionPainter>()
                  .single;
              expect(
                painter.region,
                Rect.fromLTWH(x < 400 ? 0 : 400, 0, 400, 600),
              );
            } else {
              final card = tester.widget<ColorPreviewCard>(
                find.byType(ColorPreviewCard),
              );
              expect(
                card.sample.hex,
                x < 400 ? '#F44336' : '#4CAF50',
                reason:
                    'Live sample at x=$x while the backing window is hidden',
              );
            }
          }
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byType(CaptureEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Cross-screen drag preserves pixels, exports both displays and waits for decoded frame',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FrameBridge();
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.red, BlendMode.src);
        canvas.drawRect(
          const Rect.fromLTWH(500, 0, 500, 600),
          Paint()..color = Colors.green,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(1000, 600);
        picture.dispose();
        clip = Clip(
          bytes: (await image.toByteData(format: ui.ImageByteFormat.png))!
              .buffer
              .asUint8List(),
          width: 1000,
          height: 600,
          screens: const [
            Rect.fromLTWH(0, 0, 500, 600),
            Rect.fromLTWH(500, 0, 500, 600),
          ],
        );
        image.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(clip: clip, controller: controller),
        ),
      );
      expect(bridge.readyFrames, 0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(bridge.readyFrames, 1);
      expect(bridge.viewport, const Size(1000, 600));
      SelectionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SelectionPainter>()
          .single;
      expect(painter().image, isNotNull);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(200, 80));
      await mouse.moveTo(const Offset(210, 80));
      await tester.pumpAndSettle();
      expect(painter().region, const Rect.fromLTWH(0, 0, 500, 600));
      await mouse.moveTo(const Offset(700, 80));
      await tester.pumpAndSettle();
      expect(painter().region, const Rect.fromLTWH(500, 0, 500, 600));
      await tester.tapAt(const Offset(700, 80));
      await tester.pumpAndSettle();
      expect(
        painter().region,
        const Rect.fromLTWH(500, 0, 500, 600),
        reason: 'Clicking desktop must select only that monitor',
      );
      await mouse.removePointer();
      await tester.dragFrom(const Offset(400, 80), const Offset(300, 200));
      await tester.pumpAndSettle();
      expect(painter().region, const Rect.fromLTWH(400, 80, 300, 200));
      final toolbar = tester.getRect(find.byType(GlassPanel).last);
      expect(toolbar.left, greaterThanOrEqualTo(500));
      expect(toolbar.right, lessThanOrEqualTo(1000));
      final p = painter();
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          await renderCapture(p.image!, p.marks, p.region),
        );
        final image = (await codec.getNextFrame()).image;
        codec.dispose();
        expect(image.width, 300);
        expect(image.height, 200);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        expect(bytes.sublist((50 * 300 + 20) * 4, (50 * 300 + 20) * 4 + 4), [
          244,
          67,
          54,
          255,
        ]);
        expect(bytes.sublist((50 * 300 + 200) * 4, (50 * 300 + 200) * 4 + 4), [
          76,
          175,
          80,
          255,
        ]);
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
  );
}
