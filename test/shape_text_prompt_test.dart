import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ui/toolbar_layout.dart';

final bubble = find.byKey(const ValueKey('shape-text-prompt'));
final input = find.byKey(const ValueKey('inline-annotation-text'));

Future<void> mountEditor(WidgetTester tester, {bool reduced = false}) async {
  tester.view.physicalSize = const Size(800, 600);
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
    final image = await picture.toImage(800, 600);
    picture.dispose();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    clip = Clip(bytes: bytes, width: 800, height: 600, mode: 'screen');
  });
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          disableAnimations: reduced,
        ),
        child: CaptureEditor(clip: clip, controller: controller),
      ),
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

Future<void> tool(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip(label));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'Shape text actions remain on their monitor and avoid the editing toolbar',
    () {
      const size = Size(100, 36);
      final normal = ShapeTextPromptLayout(
        shape: const Rect.fromLTWH(100, 100, 200, 100),
        screen: const Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(
        normal.getPositionForChild(const Size(800, 600), size),
        const Offset(308, 208),
      );
      for (final screen in [
        const Rect.fromLTWH(0, 0, 800, 600),
        const Rect.fromLTWH(800, 0, 800, 600),
      ]) {
        final toolbar = Rect.fromLTWH(
          screen.right - 480,
          screen.bottom - 150,
          468,
          138,
        );
        final layout = ShapeTextPromptLayout(
          shape: Rect.fromLTWH(screen.right - 70, screen.bottom - 50, 60, 40),
          screen: screen,
          toolbar: toolbar,
        );
        final rect =
            layout.getPositionForChild(const Size(1600, 600), size) & size;
        expect(rect.left, greaterThanOrEqualTo(screen.left));
        expect(rect.right, lessThanOrEqualTo(screen.right));
        expect(rect.top, greaterThanOrEqualTo(screen.top));
        expect(rect.bottom, lessThanOrEqualTo(screen.bottom));
        expect(rect.overlaps(toolbar), isFalse);
      }
    },
  );

  for (final (kind, label) in [
    (MarkTool.arrow, '箭头 · Q'),
    (MarkTool.rectangle, '矩形 · R'),
    (MarkTool.circle, '圆形标注'),
    (MarkTool.ellipse, '椭圆标注'),
    (MarkTool.line, '直线 · G'),
  ]) {
    testWidgets(
      '$kind offers text at the lower-right and creates one independent label',
      (tester) async {
        await mountEditor(tester);
        if (isShapeTool(kind) && kind != MarkTool.rectangle) {
          await tool(tester, '矩形 · R');
        }
        await tool(tester, label);
        await tester.dragFrom(const Offset(100, 100), const Offset(200, 120));
        await tester.pumpAndSettle();
        final shape = painter(tester).marks.single;
        expect(shape.tool, kind);
        expect(bubble, findsOneWidget);
        final bounds = annotationBounds(shape);
        final rect = tester.getRect(bubble);
        expect(rect.left, greaterThan(bounds.right));
        expect(rect.top, greaterThan(bounds.bottom));
        await tester.tap(find.text('添加文字'));
        await tester.pumpAndSettle();
        expect(bubble, findsNothing);
        expect(input, findsOneWidget);
        expect(painter(tester).marks, hasLength(1));
        await tester.enterText(input, '形状说明');
        await tester.tapAt(const Offset(700, 80));
        await tester.pumpAndSettle();
        expect(painter(tester).marks, hasLength(2));
        final text = painter(tester).marks.last;
        expect(text.tool, MarkTool.text);
        expect(text.text, '形状说明');
        expect(text.points.first, bounds.bottomRight + const Offset(10, 10));
        await tool(tester, '撤销');
        expect(painter(tester).marks.single, shape);
        expect(bubble, findsNothing);
      },
    );
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'Prompt expires, pauses while hovered and dismisses on new work (reduced: $reduced)',
      (tester) async {
        await mountEditor(tester, reduced: reduced);
        await tool(tester, '箭头 · Q');
        await tester.dragFrom(const Offset(100, 100), const Offset(200, 120));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        expect(bubble, findsOneWidget);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(700, 80));
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(bubble));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(bubble, findsOneWidget);
        await mouse.moveTo(const Offset(700, 80));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 2200));
        await tester.pumpAndSettle();
        expect(bubble, findsNothing);
        await tester.dragFrom(const Offset(150, 150), const Offset(150, 100));
        await tester.pumpAndSettle();
        expect(bubble, findsOneWidget);
        await tool(tester, '撤销');
        expect(bubble, findsNothing);
        await tool(tester, '画笔 · P');
        await tester.dragFrom(const Offset(100, 300), const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(bubble, findsNothing);
      },
    );
  }

  testWidgets(
    'Text bubble always creates a new label when another label is near the anchor',
    (tester) async {
      await mountEditor(tester);
      await tool(tester, '文字 · T');
      await tester.tapAt(const Offset(310, 230));
      await tester.pumpAndSettle();
      await tester.enterText(input, '原文字');
      await tester.tapAt(const Offset(700, 80));
      await tester.pumpAndSettle();
      await tool(tester, '箭头 · Q');
      await tester.dragFrom(const Offset(100, 100), const Offset(200, 120));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加文字'));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(input).controller.text, isEmpty);
      await tester.enterText(input, '新说明');
      await tester.tapAt(const Offset(700, 80));
      await tester.pumpAndSettle();
      expect(
        painter(tester).marks
            .where((m) => m.tool == MarkTool.text)
            .map((m) => m.text),
        ['原文字', '新说明'],
      );
      expect(tester.takeException(), isNull);
    },
  );
}
