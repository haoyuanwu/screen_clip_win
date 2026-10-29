import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/workspace.dart';

import 'widget_test.dart' show FakeBridge, sample;

class CursorBridge extends FakeBridge {
  CursorBridge() : super('unused');
  Offset position = const Offset(100, 100);
  final moves = <Offset>[];
  bool fail = false;
  final inputModes = <bool>[];
  @override
  Future<void> setTextInputActive(bool active) async {
    inputModes.add(active);
  }

  @override
  Future<bool> captureFrameReady(Size viewport) async => true;
  @override
  Future<Offset> nudgeCursor(int dx, int dy) async {
    moves.add(Offset(dx.toDouble(), dy.toDouble()));
    if (fail) throw PlatformException(code: 'cursor');
    position = Offset(
      (position.dx + dx).clamp(0, 799),
      (position.dy + dy).clamp(0, 599),
    );
    return position;
  }
}

Future<CursorBridge> mount(
  WidgetTester tester, {
  bool selected = true,
  Size view = const Size(800, 600),
}) async {
  tester.view.physicalSize = view;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = CursorBridge();
  final controller = ClipController(bridge: bridge)..ready = true;
  addTearDown(controller.dispose);
  late Clip clip;
  await tester.runAsync(() async {
    final image = await sample(width: 800, height: 600);
    clip = Clip(
      bytes: (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List(),
      width: 800,
      height: 600,
      mode: selected ? 'screen' : 'region',
      windows: const [Rect.fromLTWH(100, 100, 200, 200)],
    );
    image.dispose();
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
  return bridge;
}

SelectionPainter painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<SelectionPainter>()
    .single;
dynamic editor(WidgetTester tester) => tester.state(find.byType(CaptureEditor));
Future<void> key(WidgetTester tester, LogicalKeyboardKey value) async {
  await tester.sendKeyEvent(value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Resident palette focus transfers to capture; WASD and Esc work before clicking',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = CursorBridge();
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image = await sample(width: 800, height: 600);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        await controller.loadBytes(png);
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      expect(editor(tester).focus.hasFocus, isTrue);
      await key(tester, LogicalKeyboardKey.keyD);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(bridge.moves, [const Offset(1, 0)]);
      await key(tester, LogicalKeyboardKey.escape);
      expect(controller.clip, isNull);
      expect(bridge.hidden, isTrue);
    },
  );
  testWidgets(
    'WASD nudges in source pixels at scaled size, repeats, clamps and updates smart hover',
    (tester) async {
      final bridge = await mount(
        tester,
        selected: false,
        view: const Size(400, 300),
      );
      bridge.position = const Offset(99, 150);
      await key(tester, LogicalKeyboardKey.keyD);
      expect(editor(tester).cursor, const Offset(100, 150));
      expect(painter(tester).region, const Rect.fromLTWH(100, 100, 200, 200));
      await key(tester, LogicalKeyboardKey.keyW);
      await key(tester, LogicalKeyboardKey.keyA);
      await key(tester, LogicalKeyboardKey.keyS);
      expect(bridge.position, const Offset(99, 150));
      expect(painter(tester).region, const Rect.fromLTWH(0, 0, 800, 600));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(bridge.position.dx, 102);
      bridge.position = Offset.zero;
      await key(tester, LogicalKeyboardKey.keyA);
      await key(tester, LogicalKeyboardKey.keyW);
      expect(editor(tester).cursor, Offset.zero);
      bridge.position = const Offset(799, 599);
      await key(tester, LogicalKeyboardKey.keyD);
      await key(tester, LogicalKeyboardKey.keyS);
      expect(editor(tester).cursor, const Offset(799, 599));
      bridge.fail = true;
      await key(tester, LogicalKeyboardKey.keyW);
      expect(editor(tester).loadError, '光标微调失败，请重试');
      bridge.fail = false;
      await key(tester, LogicalKeyboardKey.keyW);
      expect(editor(tester).cursor, const Offset(799, 598));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Held selection and shape drags include WASD in one undo step', (
    tester,
  ) async {
    final bridge = await mount(tester, selected: false);
    final drag = await tester.startGesture(const Offset(100, 100));
    await drag.moveTo(const Offset(200, 180));
    bridge.position = const Offset(200, 180);
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyW);
    expect(painter(tester).region, const Rect.fromLTRB(100, 100, 201, 179));
    await drag.up();
    await tester.pumpAndSettle();
    expect(editor(tester).operations, hasLength(1));
    await tester.tap(find.byTooltip('矩形 · R'));
    await tester.pumpAndSettle();
    final shape = await tester.startGesture(const Offset(120, 120));
    await shape.moveTo(const Offset(170, 150));
    bridge.position = const Offset(170, 150);
    await key(tester, LogicalKeyboardKey.keyD);
    await key(tester, LogicalKeyboardKey.keyS);
    expect(painter(tester).active!.points.last, const Offset(171, 151));
    await shape.up();
    await tester.pumpAndSettle();
    expect(painter(tester).marks.single.points.last, const Offset(171, 151));
    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    expect(painter(tester).marks, isEmpty);
    expect(painter(tester).region, const Rect.fromLTRB(100, 100, 201, 179));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Text drag and Shift resizing use WASD; editing text never moves the cursor',
    (tester) async {
      final bridge = await mount(tester);
      await key(tester, LogicalKeyboardKey.keyT);
      await tester.tapAt(const Offset(120, 120));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'Text');
      expect(bridge.inputModes.last, isTrue);
      final movesBeforeTyping = bridge.moves.length;
      for (final value in [
        LogicalKeyboardKey.keyW,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyS,
        LogicalKeyboardKey.keyD,
      ]) {
        await key(tester, value);
      }
      expect(bridge.moves.length, movesBeforeTyping);
      await tester.tap(find.byTooltip('完成文字'));
      await tester.pumpAndSettle();
      expect(bridge.inputModes.last, isFalse);
      await key(tester, LogicalKeyboardKey.keyV);
      final before = painter(tester).marks.single;
      final center = textToWorld(
        before,
        Offset(before.textBoxSize.width / 2, before.textBoxSize.height / 2),
      );
      final drag = await tester.startGesture(center);
      await drag.moveTo(center + const Offset(30, 20));
      bridge.position = center + const Offset(30, 20);
      await key(tester, LogicalKeyboardKey.keyD);
      await key(tester, LogicalKeyboardKey.keyS);
      expect(
        painter(tester).marks.single.points.first,
        before.points.first + const Offset(31, 21),
      );
      await drag.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(painter(tester).marks.single, same(before));
      final corner = textToWorld(before, textHandles(before)[4]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final resize = await tester.startGesture(corner);
      await resize.moveTo(corner + const Offset(24, 24));
      bridge.position = corner + const Offset(24, 24);
      final priorSize = painter(tester).marks.single.textBoxSize;
      await key(tester, LogicalKeyboardKey.keyD);
      final scaled = painter(tester).marks.single;
      expect(scaled.textBoxSize.width, greaterThan(priorSize.width));
      expect(
        scaled.textBoxSize.aspectRatio,
        closeTo(before.textBoxSize.aspectRatio, .0001),
      );
      await resize.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.keyQ);
      expect(editor(tester).tool, MarkTool.arrow);
      await key(tester, LogicalKeyboardKey.keyG);
      expect(editor(tester).tool, MarkTool.line);
      await tester.tapAt(const Offset(300, 200));
      bridge.position = const Offset(350, 220);
      await key(tester, LogicalKeyboardKey.keyD);
      expect(painter(tester).active!.points.last, const Offset(351, 220));
      await key(tester, LogicalKeyboardKey.escape);
      expect(tester.takeException(), isNull);
    },
  );
}
