import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/controls.dart';

Future<void> mount(WidgetTester tester, Size viewport) async {
  tester.view.physicalSize = viewport;
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
    final image = await picture.toImage(1000, 750);
    picture.dispose();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    clip = Clip(bytes: bytes, width: 1000, height: 750, mode: 'screen');
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
}

SelectionPainter painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<SelectionPainter>()
    .single;

Future<void> press(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip(label));
  await tester.pumpAndSettle();
}

void main() {
  for (final viewport in [const Size(800, 600), const Size(400, 300)]) {
    testWidgets(
      'Clicks and tiny closed shapes are ignored in logical pixels at $viewport',
      (tester) async {
        await mount(tester, viewport);
        for (final (index, label) in ['矩形 · R', '圆形标注', '椭圆标注'].indexed) {
          await press(tester, label);
          final count = painter(tester).marks.length;
          await tester.tapAt(const Offset(40, 40));
          await tester.pumpAndSettle();
          expect(painter(tester).marks, hasLength(count));
          expect(find.byKey(const ValueKey('shape-text-prompt')), findsNothing);
          await tester.dragFrom(const Offset(40, 40), const Offset(100, 4));
          await tester.pumpAndSettle();
          expect(painter(tester).marks, hasLength(count));
          await tester.dragFrom(const Offset(40, 40), const Offset(100, 24));
          await tester.pumpAndSettle();
          expect(painter(tester).marks, hasLength(count + 1));
          final accepted = painter(tester).marks.last;
          await press(tester, '撤销');
          await tester.tapAt(const Offset(40, 40));
          await tester.pumpAndSettle();
          await press(tester, '重做');
          expect(painter(tester).marks.last, accepted);
          expect(painter(tester).marks, hasLength(index + 1));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Toolbar measures its content and caps width when the viewport narrows',
    (tester) async {
      await mount(tester, const Size(1200, 800));
      Rect toolbar() => tester.getRect(find.byType(GlassPanel).last);
      final selectWidth = toolbar().width;
      expect(selectWidth, lessThan(1200 - 24));
      await press(tester, '文字 · T');
      final textWidth = toolbar().width;
      // More main-row tools can now be wider than the text inspector.
      expect(textWidth, greaterThanOrEqualTo(selectWidth));
      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();
      expect(toolbar().width, greaterThanOrEqualTo(textWidth));
      await press(tester, '完成文字');
      await press(tester, '调整选区 · V');
      expect(toolbar().width, closeTo(selectWidth, .01));
      tester.view.physicalSize = const Size(440, 600);
      await tester.pumpAndSettle();
      expect(toolbar().width, lessThanOrEqualTo(440 - 24));
      expect(toolbar().left, greaterThanOrEqualTo(0));
      expect(toolbar().right, lessThanOrEqualTo(440));
      await press(tester, '文字 · T');
      await press(tester, '文字背景颜色');
      expect(toolbar().right, lessThanOrEqualTo(440));
      expect(toolbar().bottom, lessThanOrEqualTo(600));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(toolbar().right, lessThanOrEqualTo(440));
      expect(toolbar().bottom, lessThanOrEqualTo(600));
      expect(tester.takeException(), isNull);
    },
  );
}
