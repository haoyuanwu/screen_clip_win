import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/color_picker.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/workspace.dart';
import 'package:screen_clip_win/src/ui/color_preview.dart';

import 'widget_test.dart' show FakeBridge;

class PickerBridge extends FakeBridge {
  PickerBridge() : super('unused');
  final panels = <String>[];
  String? capturedMode;
  @override
  Future<Offset> nudgeCursor(int dx, int dy) async => const Offset(40, 40);
  @override
  Future<void> present(String panel) async {
    panels.add(panel);
  }

  @override
  Future<Map<Object?, Object?>?> capture(String mode) async {
    capturedMode = mode;
    return null;
  }
}

void main() {
  test('Magnifier centers the sampled pixel, clamps screen edges and freezes with the color', () {
    final bytes = Uint8List(3 * 3 * 4);
    for (int y = 0; y < 3; y++) {
      for (int x = 0; x < 3; x++) {
        final i = (y * 3 + x) * 4;
        bytes[i] = x * 50;
        bytes[i + 1] = y * 60;
        bytes[i + 3] = 255;
      }
    }
    final picker = ScreenColorPicker(ColorPixels(bytes, 3, 3))
      ..move(const Offset(1, 1));
    final patch = picker.sample.neighborhood!;
    expect(patch.width, 17);
    expect(patch.at(const Offset(8, 8)).hex, picker.sample.hex);
    expect(patch.at(Offset.zero).hex, '#000000');
    expect(patch.at(const Offset(16, 16)).hex, '#647800');
    picker.freeze();
    picker.move(const Offset(2, 2));
    expect(picker.sample.neighborhood, same(patch));
    expect(picker.sample.hex, '#323C00');
    picker.resume();
    picker.move(const Offset(2, 2));
    expect(picker.sample.neighborhood, isNot(same(patch)));
    expect(picker.sample.neighborhood!.at(const Offset(8, 8)).hex, '#647800');
    picker.dispose();
  });
  test('sRGB sampling clamps coordinates and formats exact RGB/HEX values', () {
    final pixels = ColorPixels(
      Uint8List.fromList([12, 34, 56, 255, 200, 100, 50, 255]),
      2,
      1,
    );
    expect(pixels.at(const Offset(-10, -1)).hex, '#0C2238');
    expect(pixels.at(const Offset(99, 10)).rgb, 'rgb(200, 100, 50)');
    final picker = ScreenColorPicker(pixels)..move(const Offset(1, 0));
    picker.freeze();
    picker.move(Offset.zero);
    expect(picker.sample.hex, '#C86432');
    picker.resume();
    picker.move(Offset.zero);
    expect(picker.sample.hex, '#0C2238');
    picker.dispose();
  });
  test('Global color capture bypasses screenshot countdown', () async {
    final bridge = PickerBridge();
    final c = ClipController(bridge: bridge)
      ..ready = true
      ..delay = 10;
    await c.capture('color');
    expect(bridge.capturedMode, 'color');
    expect(c.countdown, 0);
    c.dispose();
  });
  for (final global in [true, false]) {
    testWidgets('Eyedropper live sample, pin and copy work (global: $global)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = PickerBridge();
      final c = ClipController(bridge: bridge)
        ..ready = true
        ..panel = 'capture';
      addTearDown(c.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        canvas.drawColor(const Color(0xff0c2238), BlendMode.src);
        canvas.drawRect(
          const Rect.fromLTWH(400, 0, 400, 600),
          Paint()..color = const Color(0xffc86432),
        );
        final picture = rec.endRecording();
        final im = await picture.toImage(800, 600);
        picture.dispose();
        clip = Clip(
          bytes: (await im.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
          width: 800,
          height: 600,
          mode: global ? 'color' : 'screen',
        );
        im.dispose();
      });
      c.clip = clip;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
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
          home: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Workspace(controller: c),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      if (!global) {
        await tester.tap(find.byTooltip('屏幕取色 · I'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }
      final dynamic currentEditor = tester.state(find.byType(CaptureEditor));
      expect(currentEditor.loadError, isNull);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      for (int step = 0; step < 8 && currentEditor.preparingColor; step++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
      }
      expect(currentEditor.preparingColor, false);
      expect(find.byType(ColorPickerOverlay), findsOneWidget);
      if (global) {
        final state = tester.state(find.byType(CaptureEditor)) as dynamic;
        expect(state.region, isNull);
      }
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(40, 40));
      await mouse.moveTo(const Offset(50, 50));
      await tester.pump();
      expect(find.text('#0C2238'), findsOneWidget);
      await mouse.moveTo(const Offset(650, 80));
      await tester.pump();
      expect(find.text('#C86432'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('color-pixel-magnifier')),
        findsOneWidget,
      );
      await mouse.down(const Offset(650, 80));
      await mouse.up();
      await tester.pumpAndSettle();
      if (global) {
        expect(c.panel, 'color');
        expect(c.clip, isNull);
        expect(bridge.panels.last, 'color');
        tester.view.physicalSize = const Size(300, 320);
        await tester.pumpAndSettle();
      }
      expect(find.text('已固定颜色'), findsOneWidget);
      await mouse.moveTo(const Offset(30, 30));
      await tester.pumpAndSettle();
      expect(find.text('#C86432'), findsOneWidget);
      await tester.tap(find.byTooltip('复制 HEX 色值'));
      await tester.pumpAndSettle();
      expect(copied, '#C86432');
      await tester.tap(find.byTooltip('复制 sRGB · 0–255 色值'));
      await tester.pumpAndSettle();
      expect(copied, 'rgb(200, 100, 50)');
      await tester.tap(find.byTooltip('关闭取色预览'));
      await tester.pumpAndSettle();
      if (!global) {
        expect(c.clip, same(clip));
        expect(find.byType(ColorPickerOverlay), findsNothing);
      }
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });
  }
}
