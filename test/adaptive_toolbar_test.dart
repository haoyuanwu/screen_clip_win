import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/controls.dart';
import 'package:screen_clip_win/src/ui/toolbar_layout.dart';

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
  testWidgets(
    'Toolbar drag moves tools without changing selection and preserves position through menus',
    (tester) async {
      await mount(tester, const Size(1200, 800));
      final primary = find.byKey(const ValueKey('capture-primary-tools'));
      final handle = find.byKey(const ValueKey('capture-toolbar-drag-handle'));
      final original = tester.getRect(primary);
      final selection = painter(tester).region;
      await tester.drag(handle, const Offset(-150, -100));
      await tester.pumpAndSettle();
      final moved = tester.getRect(primary);
      expect(
        (moved.topLeft - original.topLeft - const Offset(-150, -100)).distance,
        lessThan(.01),
      );
      expect(painter(tester).region, selection);
      expect(painter(tester).marks, isEmpty);
      await press(tester, '文字 · T');
      await press(tester, '文字背景颜色');
      expect(
        (tester.getRect(primary).topLeft - moved.topLeft).distance,
        lessThan(.01),
      );
      await press(tester, '文字背景颜色');
      await press(tester, '调整选区 · V');
      expect(
        (tester.getRect(primary).topLeft - moved.topLeft).distance,
        lessThan(.01),
      );
      await tester.drag(handle, const Offset(-2000, -2000));
      await tester.pumpAndSettle();
      final clamped = tester.getRect(find.byType(GlassPanel).last);
      expect(clamped.left, greaterThanOrEqualTo(12));
      expect(clamped.top, greaterThanOrEqualTo(12));
      expect(painter(tester).region, selection);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'Expanded footprint selects a stable side before the inspector opens',
    () {
      const screen = Rect.fromLTWH(0, 0, 1000, 800);
      const bottomSelection = Rect.fromLTWH(200, 420, 300, 200);
      final above = chooseToolbarSide(
        bottomSelection,
        screen,
        const Size(650, 240),
      );
      expect(above, ToolbarSide.above);
      final layout = ToolbarLayout(
        selection: bottomSelection,
        screen: screen,
        side: above,
        reservedHeight: 240,
      );
      final collapsed = layout.getPositionForChild(
        screen.size,
        const Size(650, 60),
      );
      final expanded = layout.getPositionForChild(
        screen.size,
        const Size(650, 220),
      );
      expect(
        collapsed.dy + 60,
        expanded.dy + 220,
        reason:
            'The primary tools keep their bottom anchor as menus expand upward',
      );
      const topSelection = Rect.fromLTWH(200, 100, 300, 200);
      final below = chooseToolbarSide(
        topSelection,
        screen,
        const Size(650, 240),
      );
      expect(below, ToolbarSide.below);
      final downLayout = ToolbarLayout(
        selection: topSelection,
        screen: screen,
        side: below,
        reservedHeight: 240,
      );
      expect(
        downLayout.getPositionForChild(screen.size, const Size(650, 60)).dy,
        downLayout.getPositionForChild(screen.size, const Size(650, 220)).dy,
      );
    },
  );
  for (final viewport in [const Size(1200, 800), const Size(440, 600)]) {
    testWidgets(
      'Primary toolbar remains anchored during secondary menu animation at $viewport',
      (tester) async {
        await mount(tester, viewport);
        final primary = find.byKey(const ValueKey('capture-primary-tools'));
        final original = tester.getRect(primary);
        await tester.tap(find.byTooltip('文字 · T'));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          expect(
            (tester.getRect(primary).topLeft - original.topLeft).distance,
            lessThan(.01),
          );
        }
        await tester.tap(find.byTooltip('文字背景颜色'));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          expect(
            (tester.getRect(primary).topLeft - original.topLeft).distance,
            lessThan(.01),
          );
        }
        await press(tester, '文字背景颜色');
        await press(tester, '调整选区 · V');
        expect(
          (tester.getRect(primary).topLeft - original.topLeft).distance,
          lessThan(.01),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
