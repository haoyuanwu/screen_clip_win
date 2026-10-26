import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';

class LineBridge extends DesktopBridge {
  Uint8List? copied;
  int dismissals = 0;
  @override
  Future<void> copy(Uint8List bytes) async {
    copied = bytes;
  }

  @override
  Future<void> notifyCopied() async {}
  @override
  Future<void> dismiss() async {
    dismissals++;
  }
}

Future<ui.Image> whiteImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.white, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void main() {
  test(
    'Straight lines export without arrowheads and preserve drawing order',
    () async {
      final image = await whiteImage(120, 100);
      final marks = [
        Mark(MarkTool.line, Colors.red, 3, [
          const Offset(20, 40),
          const Offset(100, 40),
        ]),
      ];
      Future<List<int>> pixel(int x, int y) async {
        final codec = await ui.instantiateImageCodec(
          await renderCapture(image, marks, null),
        );
        final result = (await codec.getNextFrame()).image;
        codec.dispose();
        try {
          final pixels = (await result.toByteData())!.buffer.asUint8List();
          final offset = (y * 120 + x) * 4;
          return pixels.sublist(offset, offset + 4);
        } finally {
          result.dispose();
        }
      }

      try {
        expect(hasBrushCursor(MarkTool.line), isTrue);
        expect(brushDiameter(MarkTool.line, 3), closeTo(4.8, .001));
        expect(await pixel(60, 40), [244, 67, 54, 255]);
        expect(await pixel(89, 34), [255, 255, 255, 255]);
        marks.add(
          Mark(MarkTool.line, Colors.green, 3, [
            const Offset(60, 20),
            const Offset(60, 60),
          ]),
        );
        expect(await pixel(60, 40), [76, 175, 80, 255]);
      } finally {
        image.dispose();
      }
    },
  );

  testWidgets(
    'Two clicks preview and commit one line; drag, cancellation and undo stay consistent',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = LineBridge();
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final image = await whiteImage(800, 600);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        clip = Clip(bytes: bytes, width: 800, height: 600, mode: 'screen');
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
      SelectionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SelectionPainter>()
          .single;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 100));
      addTearDown(mouse.removePointer);
      await tester.tap(find.byTooltip('直线 · G'));
      await tester.pumpAndSettle();
      const start = Offset(120, 120), end = Offset(420, 240);
      await tester.tapAt(start);
      await tester.pumpAndSettle();
      expect(painter().marks, isEmpty);
      expect(find.byKey(const ValueKey('line-start-anchor')), findsOneWidget);
      await mouse.moveTo(const Offset(200, 250));
      await tester.pump();
      await mouse.moveTo(end);
      await tester.pump();
      expect(painter().active!.points, [start, end]);
      expect(painter().marks, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(bridge.copied, isNull);
      expect(painter().active!.points, [start, end]);
      await tester.tapAt(end);
      await tester.pumpAndSettle();
      expect(painter().marks.single.tool, MarkTool.line);
      expect(painter().marks.single.points, [start, end]);
      expect(painter().active, isNull);
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(painter().marks, isEmpty);
      await tester.tap(find.byTooltip('重做'));
      await tester.pumpAndSettle();
      expect(painter().marks, hasLength(1));

      await tester.tapAt(const Offset(150, 300));
      await tester.pump();
      await tester.tapAt(const Offset(150, 300));
      await tester.pump();
      expect(painter().marks, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(painter().active, isNull);
      expect(bridge.dismissals, 0);
      await tester.tapAt(const Offset(150, 300));
      await tester.pump();
      await tester.tap(find.byTooltip('矩形 · R'));
      await tester.pumpAndSettle();
      expect(painter().active, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(100, 320), const Offset(400, 40));
      await tester.pumpAndSettle();
      expect(painter().marks, hasLength(2));
      expect(painter().marks.last.points, [
        const Offset(100, 320),
        const Offset(500, 360),
      ]);
      final cancelled = await tester.startGesture(const Offset(200, 280));
      await cancelled.moveBy(const Offset(100, 0));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(painter().marks, hasLength(2));
      expect(painter().active, isNull);

      await tester.tapAt(const Offset(300, 80));
      await tester.pump();
      await mouse.moveTo(const Offset(450, 80));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(painter().marks, hasLength(3));
      expect(bridge.copied, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      expect(bridge.copied, isNotNull);
      expect(bridge.dismissals, 1);
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bridge.copied!);
        final image = (await codec.getNextFrame()).image;
        codec.dispose();
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        final offset = (80 * image.width + 375) * 4;
        expect(pixels.sublist(offset, offset + 4), [217, 45, 62, 255]);
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
  );
}
