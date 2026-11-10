import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:screen_clip_win/src/ui/scroll_capture.dart';
import 'package:screen_clip_win/src/workspace.dart';

class PreviewBridge extends DesktopBridge {
  PreviewBridge(this.bytes);
  final Uint8List bytes;
  @override
  Future<void> updateScrollCaptureMarker({
    required bool paused,
    required bool horizontal,
    double? fraction,
  }) async {}
  int dismissed = 0, captures = 0, scrolls = 0;
  @override
  Future<void> dismiss() async {
    dismissed++;
  }

  @override
  Future<void> present(String panel) async {}
  @override
  Future<void> beginScrollCapture(Rect rect) async {
    scrolls++;
  }

  @override
  Future<bool> captureFrameReady(Size viewport) async => true;
  @override
  Future<Map<Object?, Object?>?> capture(String mode) async {
    captures++;
    return {'bytes': bytes};
  }

  @override
  Future<Uint8List> scrollCaptureFrame() async => bytes;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('preview renders and resets direction in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(260, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Uint8List bytes;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.white, BlendMode.src);
        for (var i = 0; i < 12; i++) {
          canvas.drawRect(
            Rect.fromLTWH(15, i * 40 + 10, 160, 20),
            Paint()..color = Colors.blue.withValues(alpha: .1 + i * .06),
          );
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 500);
        bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
      });
      final controller = ClipController(bridge: PreviewBridge(bytes));
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: screenClipTheme(brightness),
          home: Material(
            child: RepaintBoundary(
              key: key,
              child: ScrollCapture(
                controller: controller,
                onCancel: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      expect(find.text('纵向'), findsOneWidget);
      expect(find.text('横向'), findsOneWidget);
      expect(find.text('滚动速率'), findsOneWidget);
      expect(find.text('安全'), findsOneWidget);
      expect(
        tester.getRect(find.byType(ScrollRateIndicator)).top,
        greaterThan(tester.getRect(find.byType(RawImage)).bottom),
      );
      expect(find.text('200 × 500'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('/tmp/screen-clip-scroll-${brightness.name}.png')
            .writeAsBytes(png.buffer.asUint8List());
        image.dispose();
      });
      final original = tester.widget<RawImage>(find.byType(RawImage)).image;
      await tester.tap(find.text('横向'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        isNot(same(original)),
      );
      final horizontalButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '横向'),
      );
      expect(
        horizontalButton.style!.foregroundColor!.resolve({}),
        screenClipTheme(brightness).colorScheme.onPrimaryContainer,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      controller.dispose();
    });
  }
  testWidgets(
    'cancel scroll capture discards session and allows a new capture',
    (tester) async {
      late Uint8List bytes;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(800, 600);
        picture.dispose();
        bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
        image.dispose();
      });
      final bridge = PreviewBridge(bytes);
      final c = ClipController(bridge: bridge)..ready = true;
      addTearDown(c.dispose);
      await tester.runAsync(() => c.loadBytes(bytes, mode: 'screen'));
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: c,
            builder: (_, _) => Workspace(controller: c),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('长截图'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(bridge.scrolls, 1);
      await tester.tap(find.byTooltip('取消长截图'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await tester.pumpAndSettle();
      expect(c.clip, isNull);
      expect(c.panel, 'palette');
      expect(bridge.dismissed, 1);
      expect(find.byType(ScrollCapture), findsNothing);
      await tester.runAsync(() => c.capture('region'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(bridge.captures, 1);
      expect(c.clip, isNotNull);
      expect(c.busy, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('paused meter shows recovery instruction', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            child: ScrollRateIndicator(level: 1, paused: true),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 90));
    final midway = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;
    expect(midway, greaterThan(0));
    expect(midway, lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('回到已采集区域后自动继续'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1,
    );
  });
}
