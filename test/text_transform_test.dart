import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/controls.dart';

void main() {
  for (final fixedFrame in [false, true]) {
    test(
      'Text alignment matches exported glyph positions (fixed: $fixedFrame)',
      () async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final source = await picture.toImage(400, 200);
        picture.dispose();
        final ink = <int>[], positions = <double>[], sizes = <Size>[];
        try {
          for (final alignment in [
            TextAlign.left,
            TextAlign.center,
            TextAlign.right,
          ]) {
            final mark = Mark(
              MarkTool.text,
              Colors.black,
              3,
              [const Offset(20, 20)],
              text: 'MMMM\nM',
              fontSize: 20,
              textAlign: alignment,
              minTextWidth: 80,
              textFrame: fixedFrame ? const Size(240, 100) : null,
            );
            final tp = mark.textPainter;
            final box = tp
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 5, extentOffset: 6),
                )
                .single;
            final factor = alignment == TextAlign.left
                ? 0
                : alignment == TextAlign.center
                ? .5
                : 1;
            final innerWidth = mark.textBoxSize.width - mark.padding * 2;
            expect(
              box.left,
              closeTo((innerWidth - (box.right - box.left)) * factor, .001),
            );
            positions.add(box.left);
            sizes.add(mark.textBoxSize);
            final bytes = await renderCapture(source, [
              mark,
            ], const Rect.fromLTWH(0, 0, 400, 200));
            final codec = await ui.instantiateImageCodec(bytes);
            final image = (await codec.getNextFrame()).image;
            codec.dispose();
            final pixels = (await image.toByteData())!;
            final line = tp.computeLineMetrics()[1];
            final top = (20 + mark.padding + line.baseline - line.ascent)
                .floor();
            final bottom = (20 + mark.padding + line.baseline + line.descent)
                .ceil();
            int firstInk = 400;
            for (int y = top; y < bottom; y++) {
              for (int x = 0; x < 400; x++) {
                if (pixels.getUint8((y * 400 + x) * 4) < 100) {
                  firstInk = math.min(firstInk, x);
                }
              }
            }
            expect(firstInk, lessThan(400));
            ink.add(firstInk);
            image.dispose();
          }
          expect(sizes.toSet(), hasLength(1));
          expect(ink[1] - ink[0], closeTo(positions[1] - positions[0], 1));
          expect(ink[2] - ink[0], closeTo(positions[2] - positions[0], 1));
        } finally {
          source.dispose();
        }
      },
    );
  }
  test(
    'PNG export preserves rotated text frame and clips its contents',
    () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(200, 200);
      picture.dispose();
      try {
        final mark = Mark(
          MarkTool.text,
          Colors.blue,
          3,
          [const Offset(80, 80)],
          text: 'Rotated text',
          fontSize: 30,
          background: Colors.blue,
          textFrame: const Size(80, 40),
          rotation: math.pi / 2,
        );
        final bytes = await renderCapture(source, [
          mark,
        ], const Rect.fromLTWH(0, 0, 200, 200));
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        codec.dispose();
        final pixels = (await image.toByteData())!;
        int red(int x, int y) => pixels.getUint8((y * 200 + x) * 4);
        expect(red(120, 65), (Colors.blue.toARGB32() >> 16) & 255);
        expect(red(85, 100), 255);
        expect(red(120, 145), 255);
        image.dispose();
      } finally {
        source.dispose();
      }
    },
  );

  test('Resizing rotated text fixes the opposite corner and scales typography only with Shift', () {
    final mark = Mark(
      MarkTool.text,
      Colors.red,
      3,
      [const Offset(100, 100)],
      text: 'one two three four five',
      fontSize: 30,
      textFrame: const Size(200, 100),
      rotation: math.pi / 3,
    );
    final fixed = textToWorld(mark, Offset.zero);
    final point =
        fixed + rotateTextVector(const Offset(300, 150), mark.rotation);
    final resized = resizeTextMark(mark, 4, point, proportional: false);
    expect(resized.textBoxSize.width, closeTo(300, .001));
    expect(resized.textBoxSize.height, closeTo(150, .001));
    expect(resized.fontSize, 30);
    expect(
      (textToWorld(resized, Offset.zero) - fixed).distance,
      closeTo(0, .001),
    );
    final scaled = resizeTextMark(mark, 4, point, proportional: true);
    expect(scaled.textBoxSize.aspectRatio, closeTo(2, .001));
    expect(scaled.fontSize, closeTo(45, .001));
    expect(scaled.padding, closeTo(15, .001));
    expect(
      (textToWorld(scaled, Offset.zero) - fixed).distance,
      closeTo(0, .001),
    );
    expect(
      (textToLocal(scaled, textToWorld(scaled, const Offset(30, 40))) -
              const Offset(30, 40))
          .distance,
      closeTo(0, .001),
    );
  });

  testWidgets(
    'Outside click only commits; idle text transforms, recolors and reopens with undo',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ClipController()..ready = true;
      addTearDown(controller.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1000, 760);
        picture.dispose();
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        image.dispose();
        clip = Clip(
          bytes: data.buffer.asUint8List(),
          width: 1000,
          height: 760,
          mode: 'screen',
        );
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
      Mark mark() => painter().marks.single;
      Future<void> undo() async {
        await tester.tap(find.byTooltip('撤销'));
        await tester.pumpAndSettle();
      }

      Future<void> redo() async {
        await tester.tap(find.byTooltip('重做'));
        await tester.pumpAndSettle();
      }

      final input = find.byKey(const ValueKey('inline-annotation-text'));
      await tester.tap(find.byTooltip('文字 · T'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 150));
      await tester.pumpAndSettle();
      await tester.enterText(input, 'Resize me\nsecond line');
      await tester.pump();
      await tester.tapAt(const Offset(800, 100));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(painter().marks, hasLength(1));
      var original = mark();
      await tester.tap(find.byTooltip('文字居中对齐'));
      await tester.pumpAndSettle();
      expect(mark().textAlign, TextAlign.center);
      await undo();
      expect(mark(), original);
      await redo();
      original = mark();
      expect(original.textAlign, TextAlign.center);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(900, 100));
      addTearDown(mouse.removePointer);
      final body = textToWorld(
        mark(),
        Offset(mark().textBoxSize.width / 2, mark().textBoxSize.height / 2),
      );
      await mouse.moveTo(body);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is TextTransformPainter,
        ),
        findsOneWidget,
      );
      await tester.dragFrom(body, const Offset(60, 40));
      await tester.pumpAndSettle();
      expect(mark().points.first, original.points.first + const Offset(60, 40));
      expect(input, findsNothing);
      await undo();
      expect(mark(), original);
      await redo();
      final moved = mark();

      await tester.dragFrom(
        textToWorld(
          moved,
          Offset(moved.textBoxSize.width, moved.textBoxSize.height),
        ),
        const Offset(100, 50),
      );
      await tester.pumpAndSettle();
      expect(
        mark().textBoxSize.width,
        closeTo(moved.textBoxSize.width + 100, .01),
      );
      expect(
        mark().textBoxSize.height,
        closeTo(moved.textBoxSize.height + 50, .01),
      );
      expect(mark().fontSize, original.fontSize);
      final resized = mark();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.dragFrom(
        textToWorld(
          resized,
          Offset(resized.textBoxSize.width, resized.textBoxSize.height),
        ),
        Offset(resized.textBoxSize.width / 2, resized.textBoxSize.height / 2),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        mark().textBoxSize.aspectRatio,
        closeTo(resized.textBoxSize.aspectRatio, .001),
      );
      expect(mark().fontSize, closeTo(resized.fontSize * 1.5, .01));
      final scaled = mark();
      await undo();
      expect(mark(), resized);
      await redo();
      expect(mark(), scaled);

      final center = textToWorld(
        scaled,
        Offset(scaled.textBoxSize.width / 2, scaled.textBoxSize.height / 2),
      );
      final knob = textToWorld(
        scaled,
        Offset(scaled.textBoxSize.width / 2, -26),
      );
      final right = center + Offset((knob - center).distance, 0);
      await tester.dragFrom(knob, right - knob);
      await tester.pumpAndSettle();
      expect(mark().rotation, closeTo(math.pi / 2, .001));
      var rotated = mark();
      await undo();
      expect(mark(), scaled);
      await redo();
      expect(mark(), rotated);

      await tester.tap(find.byTooltip('文字背景颜色'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('背景颜色：#2459DF'));
      await tester.pumpAndSettle();
      final colored = mark();
      expect(input, findsNothing);
      expect(colored.background, const Color(0xff2459df));
      expect(colored.rotation, rotated.rotation);
      expect(colored.textFrame, rotated.textFrame);
      expect(colored.textAlign, rotated.textAlign);
      expect(colored.points.first, rotated.points.first);
      Color paletteValue() => tester
          .widget<ColorRow>(
            find.byWidgetPredicate((w) => w is ColorRow && w.label == '背景颜色'),
          )
          .value;
      expect(paletteValue(), colored.background);
      await tester.runAsync(() async {
        final p = painter();
        final bytes = await renderCapture(p.image!, p.marks, p.region);
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        codec.dispose();
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        final point = textToWorld(
          colored,
          Offset(colored.textBoxSize.width / 2, 4),
        );
        final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        expect(pixels.sublist(offset, offset + 4), [36, 89, 223, 255]);
        image.dispose();
      });
      await undo();
      expect(mark(), rotated);
      expect(paletteValue(), Colors.transparent);
      await redo();
      expect(mark(), colored);
      await tester.tap(find.byTooltip('背景颜色：透明'));
      await tester.pumpAndSettle();
      expect(mark().background, Colors.transparent);
      expect(paletteValue(), Colors.transparent);
      await undo();
      expect(mark(), colored);
      await redo();
      expect(mark().background, Colors.transparent);
      await undo();
      rotated = mark();
      await tester.tap(find.byTooltip('文字背景颜色'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(30, 20));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(mark(), rotated);
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      expect(tester.widget<EditableText>(input).textAlign, TextAlign.center);
      await tester.enterText(input, 'Edited after rotation');
      await tester.tap(find.byTooltip('文字右对齐'));
      await tester.pump();
      expect(tester.widget<EditableText>(input).textAlign, TextAlign.right);
      await tester.tapAt(const Offset(850, 100));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(mark().rotation, rotated.rotation);
      expect(mark().textFrame, rotated.textFrame);
      expect(mark().padding, rotated.padding);
      expect(mark().text, 'Edited after rotation');
      expect(mark().textAlign, TextAlign.right);
      await undo();
      expect(mark(), rotated);
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      await tester.enterText(input, ' \n\t ');
      await tester.tapAt(const Offset(850, 100));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(painter().marks, isEmpty);
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is TextTransformPainter,
        ),
        findsNothing,
      );
      await undo();
      expect(mark(), rotated);
      await redo();
      expect(painter().marks, isEmpty);
      // New empty boxes (including colored backgrounds) leave no undo entry.
      for (final empty in ['', ' \n ']) {
        await tester.tapAt(center);
        await tester.pumpAndSettle();
        await tester.enterText(input, empty);
        await tester.tapAt(const Offset(850, 100));
        await tester.pumpAndSettle();
        expect(input, findsNothing);
        expect(painter().marks, isEmpty);
      }
      await undo();
      expect(mark(), rotated);
      expect(tester.takeException(), isNull);
    },
  );
}
