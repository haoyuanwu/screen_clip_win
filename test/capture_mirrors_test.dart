import 'dart:ui' as ui;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';
import 'package:screen_clip_win/src/ui/capture_mirrors.dart';
import 'package:screen_clip_win/src/ui/color_preview.dart';
import 'package:screen_clip_win/src/color_picker.dart';

import 'widget_test.dart' show FakeBridge;

class DesktopBlocks extends CustomPainter {
  const DesktopBlocks({this.reverse = false});
  final bool reverse;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(reverse ? Colors.green : Colors.red, BlendMode.src);
    canvas.drawRect(
      Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height),
      Paint()..color = reverse ? Colors.red : Colors.green,
    );
  }

  @override
  bool shouldRepaint(covariant DesktopBlocks oldDelegate) =>
      reverse != oldDelegate.reverse;
}

void main() {
  testWidgets(
    'Global eyedropper only transfers the card crop on its active display',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(resetCaptureMirrors);
      final picker = ScreenColorPicker(
        ColorPixels(Uint8List(1200 * 700 * 4), 1200, 700),
      )..move(const Offset(100, 100));
      addTearDown(picker.dispose);
      final packets = <Map>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DesktopBridge.channel,
        (call) async {
          if (call.method == 'captureMirrorLayouts') {
            return {
              'session': 20,
              'screens': [
                {
                  'displayId': 1,
                  'x': 0,
                  'y': 0,
                  'width': 600,
                  'height': 700,
                  'scale': 2,
                },
                {
                  'displayId': 3,
                  'x': 600,
                  'y': 0,
                  'width': 600,
                  'height': 700,
                  'scale': 1,
                },
              ],
            };
          }
          if (call.method == 'updateCaptureMirror') {
            packets.add(call.arguments as Map);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DesktopBridge.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureMirrors(
            active: true,
            revision: 1,
            colorOnly: true,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: const DesktopBlocks()),
                ),
                Positioned.fill(
                  child: ColorPickerOverlay(
                    picker: picker,
                    screens: const [
                      Rect.fromLTWH(0, 0, 600, 700),
                      Rect.fromLTWH(600, 0, 600, 700),
                    ],
                    onClose: () {},
                    onPicked: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      markCaptureMirrorsReady();
      Future<void> waitPacket() async {
        for (int i = 0; i < 50 && packets.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        expect(packets, isNotEmpty);
      }

      await waitPacket();
      expect(
        packets.every((p) => p['overlay'] == true && p['displayId'] == 1),
        true,
      );
      expect(
        (packets.last['bytes'] as Uint8List).length,
        lessThan(600 * 700 * 4 * 4 ~/ 2),
      );
      expect(packets.last['logicalWidth'], lessThan(400));
      packets.clear();
      picker.move(const Offset(950, 350));
      await waitPacket();
      expect(packets.last['displayId'], 3);
      expect(packets.last['overlay'], true);
      expect(
        (packets.last['bytes'] as Uint8List).length,
        lessThan(600 * 700 * 4 ~/ 2),
      );
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isMacOS,
  );
  testWidgets(
    'Native mirror receives its own cropped screen at its backing scale',
    (tester) async {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(resetCaptureMirrors);
      Map? frame;
      final frames = <int, Map>{};
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DesktopBridge.channel,
        (call) async {
          if (call.method == 'captureMirrorLayouts') {
            return {
              'session': 10,
              'screens': [
                {
                  'displayId': 1,
                  'x': 0,
                  'y': 0,
                  'width': 400,
                  'height': 400,
                  'scale': 2,
                },
                {
                  'displayId': 3,
                  'x': 400,
                  'y': 0,
                  'width': 400,
                  'height': 400,
                  'scale': 1,
                },
              ],
            };
          }
          if (call.method == 'updateCaptureMirror') {
            frame = call.arguments as Map;
            frames[frame!['displayId'] as int] = frame!;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DesktopBridge.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: CaptureMirrors(
            active: true,
            revision: 1,
            child: CustomPaint(painter: DesktopBlocks()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        frame,
        isNull,
        reason: 'A not-yet-decoded editor must not replace the native frozen desktop',
      );
      markCaptureMirrorsReady();
      await tester.pump();
      for (int i = 0; i < 50 && frames.length < 2; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(frame, isNotNull);
      expect(frames.keys, containsAll([1, 3]));
      expect(frames[1]!['session'], 10);
      expect(frames[1]!['width'], 800);
      expect(frames[1]!['height'], 800);
      expect(frames[3]!['width'], 400);
      expect(frames[3]!['height'], 400);
      final bytes = frames[1]!['bytes'] as List<int>;
      expect(bytes.sublist((400 * 800 + 400) * 4, (400 * 800 + 400) * 4 + 4), [
        244,
        67,
        54,
        255,
      ]);
      final secondary = frames[3]!['bytes'] as List<int>;
      expect(
        secondary.sublist((200 * 400 + 200) * 4, (200 * 400 + 200) * 4 + 4),
        [76, 175, 80, 255],
      );
      frames.clear();
      // Smart selection refreshes pixels without starting a new capture session.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: CaptureMirrors(
            active: true,
            revision: 1,
            child: CustomPaint(painter: DesktopBlocks(reverse: true)),
          ),
        ),
      );
      for (int i = 0; i < 50 && frames.length < 2; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      expect(frames.keys, containsAll([1, 3]));
      expect(frames[1]!['session'], 10);
      final refreshed = frames[1]!['bytes'] as List<int>;
      expect(
        refreshed.sublist((400 * 800 + 400) * 4, (400 * 800 + 400) * 4 + 4),
        [76, 175, 80, 255],
      );
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isMacOS,
  );

  testWidgets('One native pointer keeps a cross-display drag continuous', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(resetCaptureMirrors);
    final c = ClipController(bridge: FakeBridge('unused'))..ready = true;
    addTearDown(c.dispose);
    late Clip clip;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      DesktopBlocks().paint(Canvas(recorder), const Size(1000, 600));
      final picture = recorder.endRecording();
      final image = await picture.toImage(1000, 600);
      picture.dispose();
      clip = Clip(
        bytes: (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
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
        home: CaptureEditor(clip: clip, controller: c),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    void pointer(double x, double y, int buttons, double time) =>
        dispatchCapturePointer({
          'x': x,
          'y': y,
          'buttons': buttons,
          'time': time,
          'type': 'pointer',
        });
    pointer(400, 80, 0, 1);
    pointer(400, 80, 1, 1.01);
    pointer(550, 180, 1, 1.02);
    pointer(700, 280, 1, 1.03);
    pointer(700, 280, 0, 1.04);
    await tester.pumpAndSettle();
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<SelectionPainter>()
        .single;
    expect(painter.region, const Rect.fromLTWH(400, 80, 300, 200));
    expect(tester.takeException(), isNull);
  });
}
