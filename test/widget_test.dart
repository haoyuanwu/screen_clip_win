import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';
import 'package:screen_clip_win/src/workspace.dart';
import 'package:screen_clip_win/src/ui/controls.dart';
import 'package:screen_clip_win/src/ui/toolbar_layout.dart';

class FakeBridge extends DesktopBridge {
  FakeBridge(this.directory);
  final String directory;
  bool hidden = false, failCopy = false;
  bool startupEnabled = false, failStartup = false;
  int startupWrites = 0;
  @override
  Future<String> launchAtLoginStatus() async =>
      startupEnabled ? 'enabled' : 'disabled';
  @override
  Future<String> setLaunchAtLogin(bool enabled) async {
    startupWrites++;
    if (failStartup) throw PlatformException(code: 'startup');
    startupEnabled = enabled;
    return launchAtLoginStatus();
  }

  String? savePath;
  Uint8List? copied, pinned;
  Map<String, double>? pinnedRect;
  bool? pinnedAnimate;
  bool failPin = false;
  @override
  Future<void> pin(
    Uint8List bytes,
    Map<String, double> rect,
    bool animate,
  ) async {
    if (failPin) throw PlatformException(code: 'pin', message: '图钉创建失败');
    pinned = bytes;
    pinnedRect = rect;
    pinnedAnimate = animate;
  }

  @override
  Future<String> dataDirectory() async => directory;
  @override
  Future<bool> registerHotkey() async => true;
  @override
  Future<void> present(String panel) async {
    hidden = false;
  }

  @override
  Future<void> notifyCopied() async {}
  @override
  Future<void> dismiss() async {
    hidden = true;
  }

  @override
  Future<void> copy(Uint8List bytes) async {
    if (failCopy) {
      throw PlatformException(code: 'busy', message: 'Clipboard busy');
    }
    copied = bytes;
  }

  @override
  Future<String?> save(Uint8List bytes, String name) async => savePath;
}

Future<ui.Image> sample({int width = 40, int height = 30}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Startup defaults on once and respects disabled state and failures',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'screenclip-startup-',
      );
      final bridge = FakeBridge(directory.path);
      try {
        final first = ClipController(bridge: bridge);
        await first.initialize();
        expect(first.ready, isTrue);
        expect(first.launchAtLogin, isTrue);
        expect(bridge.startupWrites, 1);
        await first.setLaunchAtLogin(false);
        expect(first.launchAtLogin, isFalse);
        first.dispose();
        final next = ClipController(bridge: bridge);
        await next.initialize();
        expect(next.launchAtLogin, isFalse);
        expect(bridge.startupWrites, 2);
        bridge.failStartup = true;
        await next.setLaunchAtLogin(true);
        expect(next.launchAtLogin, isFalse);
        expect(next.ready, isTrue);
        expect(next.error, contains('开机启动设置失败'));
        next.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('Circle and ellipse are foreground annotations; crop stays rectangular and eraser works', () async {
    final image = await sample(width: 100, height: 80);
    try {
      for (final tool in [MarkTool.circle, MarkTool.ellipse]) {
        final mark = Mark(tool, Colors.red, 3, [
          const Offset(20, 20),
          const Offset(80, 60),
        ]);
        final box = annotationBounds(mark);
        expect(box.width == box.height, tool == MarkTool.circle);
        final reverse = Mark(tool, Colors.red, 3, [
          const Offset(80, 60),
          const Offset(20, 20),
        ]);
        expect(annotationBounds(reverse).width, box.width);
        final marks = [
          mark,
          Mark(MarkTool.redact, Colors.white, 12, [
            const Offset(10, 40),
            const Offset(90, 40),
          ]),
        ];
        Future<ByteData> pixels() async {
          final png = await renderCapture(
            image,
            marks,
            const Rect.fromLTWH(10, 10, 80, 60),
          );
          final codec = await ui.instantiateImageCodec(png);
          final frame = await codec.getNextFrame();
          codec.dispose();
          expect(frame.image.width, 80);
          expect(frame.image.height, 60);
          final data = (await frame.image.toByteData())!;
          frame.image.dispose();
          return data;
        }

        final before = await pixels();
        expect(
          before.getUint8(3),
          255,
        ); // Rectangular screenshot retains its corners.
        final strokePixel =
            ((box.topCenter.dy.toInt() - 10) * 80 +
                box.topCenter.dx.toInt() -
                10) *
            4;
        expect(
          before.getUint8(strokePixel),
          (Colors.red.toARGB32() >> 16) & 255,
        );
        expect(
          before.getUint8(strokePixel + 1),
          lessThan(100),
        ); // Shape stays above blur.
        marks.add(Mark(MarkTool.erase, Colors.white, 2, [box.topCenter]));
        final erased = await pixels();
        expect(erased.getUint8(strokePixel + 1), 255);
      }
    } finally {
      image.dispose();
    }
  });
  test('Pin preserves clipboard, supports reduced motion and retains failed session', () async {
    final bridge = FakeBridge('unused');
    final controller = ClipController(bridge: bridge)..ready = true;
    final image = await sample();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    try {
      await controller.loadBytes(bytes);
      bridge.failPin = true;
      await controller.pin(
        bytes,
        const Rect.fromLTWH(2, 3, 20, 15),
        animate: true,
      );
      expect(controller.clip, isNotNull);
      expect(controller.error, '图钉创建失败');
      bridge.failPin = false;
      await controller.pin(
        bytes,
        const Rect.fromLTWH(2, 3, 20, 15),
        animate: false,
      );
      expect(bridge.pinned, bytes);
      expect(bridge.pinnedRect, {
        'x': 2.0,
        'y': 3.0,
        'width': 20.0,
        'height': 15.0,
      });
      expect(bridge.pinnedAnimate, isFalse);
      expect(bridge.copied, isNull);
      expect(controller.clip, isNull);
      expect(bridge.hidden, isTrue);
    } finally {
      controller.dispose();
    }
  });
  testWidgets(
    'Circle and ellipse annotate without changing rectangle selection or pinned dimensions',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge('unused');
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        final image = await sample(width: 1024, height: 768);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        await controller.loadBytes(bytes);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('圆形框选'), findsNothing);
      await tester.dragFrom(const Offset(100, 100), const Offset(400, 240));
      await tester.pumpAndSettle();
      SelectionPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SelectionPainter>()
          .single;
      final rectangle = painter().region;
      await tester.tap(find.byTooltip('矩形 · R'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('圆形标注'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(150, 150), const Offset(150, 90));
      await tester.pumpAndSettle();
      expect(painter().marks.last.tool, MarkTool.circle);
      final circle = annotationBounds(painter().marks.last);
      expect(circle.width, circle.height);
      expect(painter().region, rectangle);
      await tester.tap(find.byTooltip('椭圆标注'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(310, 180), const Offset(170, 60));
      await tester.pumpAndSettle();
      expect(painter().marks.last.tool, MarkTool.ellipse);
      expect(painter().region, rectangle);
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(painter().marks.length, 1);
      await tester.tap(find.byTooltip('重做'));
      await tester.pumpAndSettle();
      expect(painter().marks.length, 2);
      expect(painter().region, rectangle);
      await tester.tap(find.byTooltip('图钉暂存 · F'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 70)),
      );
      await tester.pumpAndSettle();
      expect(bridge.pinned, isNotNull);
      expect(bridge.copied, isNull);
      expect(controller.clip, isNull);
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bridge.pinned!);
        final frame = await codec.getNextFrame();
        codec.dispose();
        expect(frame.image.width, rectangle!.width.toInt());
        expect(frame.image.height, rectangle.height.toInt());
        expect((await frame.image.toByteData())!.getUint8(3), 255);
        frame.image.dispose();
      });
    },
  );
  test(
    'Blur is local and always under arrows, rectangles and text backgrounds',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 60, 80),
        Paint()..color = Colors.black,
      );
      final picture = recorder.endRecording();
      final source = await picture.toImage(120, 80);
      picture.dispose();
      final marks = [
        Mark(MarkTool.arrow, Colors.red, 4, [
          const Offset(20, 40),
          const Offset(95, 40),
        ]),
        Mark(MarkTool.rectangle, Colors.blue, 3, [
          const Offset(30, 20),
          const Offset(90, 60),
        ]),
        Mark(
          MarkTool.text,
          Colors.green,
          3,
          [const Offset(45, 8)],
          text: 'A',
          fontSize: 18,
          background: Colors.yellow,
          padding: 10,
        ),
        Mark(MarkTool.redact, Colors.black, 4, [
          const Offset(60, 8),
          const Offset(60, 70),
        ]),
      ];
      final bytes = await renderCapture(source, marks, null);
      source.dispose();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final pixels = (await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      List<int> pixel(int x, int y) =>
          pixels.sublist((y * 120 + x) * 4, (y * 120 + x) * 4 + 4);
      expect(pixel(60, 68)[0], inInclusiveRange(30, 225));
      expect(pixel(5, 70), [0, 0, 0, 255]);
      expect(pixel(110, 70), [255, 255, 255, 255]);
      expect(pixel(85, 40), [244, 67, 54, 255]);
      expect(pixel(60, 60), [33, 150, 243, 255]);
      expect(pixel(47, 11), [255, 235, 59, 255]);
      frame.image.dispose();
      codec.dispose();
    },
  );
  test('No capture history: all image data stays in memory and close clears session', () async {
    final directory = await Directory.systemTemp.createTemp('screenclip-test-');
    final bridge = FakeBridge(directory.path);
    final controller = ClipController(bridge: bridge);
    try {
      await controller.initialize();
      await controller.settings(seconds: 3);
      final image = await sample();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      await controller.loadBytes(bytes);
      await controller.discard();
      expect(controller.clip, isNull);
      expect(bridge.hidden, true);
      final names = await directory
          .list()
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(names, ['preferences.json']);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });
  test('Cancel save and clipboard failure preserve editable session; success clears it', () async {
    final directory = await Directory.systemTemp.createTemp('screenclip-test-');
    final bridge = FakeBridge(directory.path);
    final controller = ClipController(bridge: bridge);
    try {
      await controller.initialize();
      final image = await sample();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      await controller.loadBytes(bytes);
      await controller.finish(bytes, save: true);
      expect(controller.clip, isNotNull);
      bridge.failCopy = true;
      await controller.finish(bytes, save: false);
      expect(controller.clip, isNotNull);
      expect(controller.error, 'Clipboard busy');
      bridge.failCopy = false;
      await controller.finish(bytes, save: false);
      expect(bridge.copied, isNotNull);
      expect(controller.clip, isNull);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });
  test('Capture stays in selection state until confirmed, then defaults to clipboard', () async {
    final directory = await Directory.systemTemp.createTemp('screenclip-test-');
    final bridge = FakeBridge(directory.path);
    final controller = ClipController(bridge: bridge);
    try {
      await controller.initialize();
      final image = await sample();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      await controller.loadBytes(bytes);
      expect(bridge.copied, isNull);
      expect(controller.panel, 'capture');
      expect(controller.clip, isNotNull);
      await controller.finish(bytes, save: false);
      expect(bridge.copied, isNotEmpty);
      expect(bridge.hidden, true);
      expect(controller.clip, isNull);
      expect(
        await directory
            .list()
            .map((f) => f.path.split(Platform.pathSeparator).last)
            .toList(),
        ['preferences.json'],
      );
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });
  testWidgets(
    'Select and annotate in the same overlay; confirmation alone copies',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge('unused');
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        final im = await sample();
        final bytes = (await im.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        im.dispose();
        await controller.loadBytes(bytes);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(bridge.copied, isNull);
      await tester.dragFrom(const Offset(80, 100), const Offset(420, 300));
      await tester.pumpAndSettle();
      expect(find.byTooltip('复制到剪贴板 · Enter'), findsOneWidget);
      expect(bridge.copied, isNull);
      await tester.tap(find.byTooltip('隐私画笔 · B'));
      await tester.pump();
      await tester.dragFrom(const Offset(150, 150), const Offset(150, 80));
      await tester.pump();
      SelectionPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) => w is CustomPaint && w.painter is SelectionPainter,
                    ),
                  )
                  .painter!
              as SelectionPainter;
      expect(painter().marks.length, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(painter().marks, isEmpty);
      await tester.tap(find.byTooltip('重做'));
      await tester.pump();
      expect(painter().marks.length, 1);
      await tester.tap(find.byTooltip('复制到剪贴板 · Enter'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(bridge.copied, isNotEmpty);
      expect(controller.clip, isNull);
      expect(bridge.hidden, true);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Inline text grows, supports styles, reopens and undoes edits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = FakeBridge('unused');
    final controller = ClipController(bridge: bridge)..ready = true;
    addTearDown(controller.dispose);
    await tester.runAsync(() async {
      final im = await sample(width: 1024, height: 768);
      final bytes = (await im.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      im.dispose();
      await controller.loadBytes(bytes);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Workspace(controller: controller),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(80, 100), const Offset(820, 400));
    await tester.pumpAndSettle();
    expect(find.byTooltip('精确调整选区'), findsNothing);
    expect(find.byTooltip('精确选区'), findsNothing);
    await tester.tap(find.byTooltip('文字 · T'));
    await tester.pump();
    await tester.tapAt(const Offset(150, 180));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('inline-annotation-text'));
    expect(input, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.enterText(input, '短字');
    await tester.pump();
    final initial = tester.getSize(input);
    await tester.enterText(input, '这是一段随文字增长的就地输入内容');
    await tester.pump();
    expect(tester.getSize(input).width, greaterThan(initial.width));
    await tester.enterText(input, '第一行\n第二行');
    await tester.pump();
    expect(tester.getSize(input).height, greaterThan(initial.height));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(bridge.copied, isNull);
    expect(controller.clip, isNotNull);
    for (int i = 0; i < 8; i++) {
      await tester.tap(find.byTooltip('增大字号'));
      await tester.pump();
    }
    await tester.tap(find.byTooltip('标注颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('标注颜色：#2459DF'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文字背景颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('背景颜色：#FFFFFF'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    await tester.tap(find.byTooltip('斜体'));
    await tester.pump();
    await tester.tap(find.byTooltip('下划线'));
    await tester.pump();
    await tester.enterText(input, '第一行\n第二行');
    await tester.tap(find.byTooltip('完成文字'));
    await tester.pump();
    SelectionPainter painter() =>
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (w) => w is CustomPaint && w.painter is SelectionPainter,
                  ),
                )
                .painter!
            as SelectionPainter;
    expect(painter().marks.single.fontSize, 48);
    expect(painter().marks.single.color, const Color(0xff2459df));
    expect(painter().marks.single.background, Colors.white);
    expect(painter().marks.single.padding, 10);
    expect(painter().marks.single.bold, true);
    expect(painter().marks.single.italic, true);
    expect(painter().marks.single.underline, true);
    await tester.tapAt(const Offset(155, 185));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(input).controller.text, '第一行\n第二行');
    await tester.enterText(input, '修改后的文字');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(painter().marks.single.text, '修改后的文字');
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(painter().marks.single.text, '第一行\n第二行');
    expect(tester.takeException(), isNull);
  });
  testWidgets('Custom slider changes continuously and supports arrow keys', (
    tester,
  ) async {
    double value = 3;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 220,
            child: StatefulBuilder(
              builder: (context, set) => FineSlider(
                label: '线条粗细',
                value: value,
                min: 1,
                max: 12,
                onChanged: (v) => set(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tapAt(
      tester.getCenter(find.byType(FineSlider)) + const Offset(60, 0),
    );
    await tester.pump();
    expect(value, greaterThan(6));
    final clickedValue = value;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value, clickedValue - .5);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Custom inspector stays within compact screens as colors and styles expand',
    (tester) async {
      final bridge = FakeBridge('unused');
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(620, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final im = await sample(width: 620, height: 480);
        final bytes = (await im.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        im.dispose();
        await controller.loadBytes(bytes, mode: 'screen');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      final compactToolbar = tester.getRect(find.byType(GlassPanel).last);
      expect(compactToolbar.width, lessThanOrEqualTo(480));
      expect(compactToolbar.height, lessThan(100));
      for (final label in ['箭头 · A', '文字 · T', '隐私画笔 · B', '矩形 · R']) {
        await tester.tap(find.byTooltip(label));
        await tester.pump(const Duration(milliseconds: 35));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文字 · T'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文字背景颜色'));
      await tester.pumpAndSettle();
      final surface = find.byType(GlassPanel).last;
      final rect = tester.getRect(surface);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(620));
      expect(rect.bottom, lessThanOrEqualTo(480));
      expect(find.byType(DropdownButton<double>), findsNothing);
      expect(find.byType(PopupMenuButton<Color>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Colored circular cursors match every brush and disappear outside selection',
    (tester) async {
      tester.view.physicalSize = const Size(620, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge('unused');
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        final im = await sample(width: 620, height: 480);
        final bytes = (await im.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        im.dispose();
        await controller.loadBytes(bytes);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(50, 70), const Offset(500, 240));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      addTearDown(mouse.removePointer);
      List<BrushCursorPainter> painters() => tester
          .widgetList<CustomPaint>(
            find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is BrushCursorPainter,
            ),
          )
          .map((w) => w.painter! as BrushCursorPainter)
          .toList();
      for (final entry in [
        ('画笔 · P', 3.0),
        ('箭头 · A', 4.8),
        ('矩形 · R', 4.8),
        ('隐私画笔 · B', 27.0),
        ('橡皮擦 · E', 27.0),
        ('序号', 36.0),
      ]) {
        await tester.tap(find.byTooltip(entry.$1));
        await tester.pumpAndSettle();
        await mouse.moveTo(const Offset(200, 180));
        await tester.pump();
        expect(painters().length, 2);
        expect(painters().first.diameter, closeTo(entry.$2, .001));
        expect(
          painters().first.color,
          entry.$1 == '隐私画笔 · B' || entry.$1 == '橡皮擦 · E'
              ? Colors.white
              : const Color(0xffd92d3e),
        );
        await mouse.moveTo(const Offset(10, 20));
        await tester.pump();
        expect(painters().length, 1);
      }
      await tester.tap(find.byTooltip('画笔 · P'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('标注颜色'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('标注颜色：#2459DF'));
      await tester.pumpAndSettle();
      final slider = find.byWidgetPredicate(
        (w) => w is FineSlider && w.label == '线条粗细',
      );
      await tester.tapAt(tester.getCenter(slider) + const Offset(30, 0));
      await tester.pumpAndSettle();
      await mouse.moveTo(const Offset(210, 180));
      await tester.pump();
      expect(painters().first.color, const Color(0xff2459df));
      expect(painters().first.diameter, greaterThan(3));
      expect(tester.takeException(), isNull);
    },
  );
  test('Eraser restores source pixels across blur and foreground, without masking future drawing', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 60, 80),
      Paint()..color = Colors.black,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(120, 80);
    picture.dispose();
    final marks = [
      Mark(MarkTool.pen, Colors.red, 5, [
        const Offset(15, 40),
        const Offset(100, 40),
      ]),
      Mark(MarkTool.rectangle, Colors.blue, 3, [
        const Offset(25, 15),
        const Offset(95, 60),
      ]),
      Mark(
        MarkTool.text,
        Colors.green,
        3,
        [const Offset(45, 10)],
        text: 'X',
        fontSize: 20,
        background: Colors.yellow,
      ),
      Mark(MarkTool.redact, Colors.white, 4, [
        const Offset(60, 0),
        const Offset(60, 79),
      ]),
      Mark(MarkTool.erase, Colors.white, 2, [
        const Offset(60, 0),
        const Offset(60, 79),
      ]),
    ];
    Future<List<int>> pixel(int x, int y) async {
      final bytes = await renderCapture(image, marks, null);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final pixels = (await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      final value = pixels.sublist((y * 120 + x) * 4, (y * 120 + x) * 4 + 4);
      frame.image.dispose();
      codec.dispose();
      return value;
    }

    expect(await pixel(60, 40), [255, 255, 255, 255]);
    expect(await pixel(60, 20), [255, 255, 255, 255]);
    expect(await pixel(60, 60), [255, 255, 255, 255]);
    expect(await pixel(60, 70), [255, 255, 255, 255]);
    expect(await pixel(85, 40), [244, 67, 54, 255]);
    expect(await pixel(85, 60), [33, 150, 243, 255]);
    marks.add(
      Mark(MarkTool.pen, Colors.green, 4, [
        const Offset(60, 35),
        const Offset(60, 45),
      ]),
    );
    expect(await pixel(60, 40), [76, 175, 80, 255]);
    image.dispose();
  });
  test('Brush circle center remains transparent', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const BrushCursorPainter(
      center: Offset(20, 20),
      diameter: 28,
      color: Colors.white,
    ).paint(canvas, const Size(40, 40));
    final picture = recorder.endRecording();
    final image = await picture.toImage(40, 40);
    picture.dispose();
    final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    expect(pixels[(20 * 40 + 20) * 4 + 3], 0);
    image.dispose();
  });
  testWidgets(
    'Dragging eraser previews local removal and supports undo and redo',
    (tester) async {
      tester.view.physicalSize = const Size(620, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ClipController(bridge: FakeBridge('unused'))
        ..ready = true;
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        final image = await sample(width: 620, height: 480);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        await controller.loadBytes(bytes);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(50, 70), const Offset(500, 240));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('画笔 · P'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(130, 180), const Offset(240, 0));
      await tester.pump();
      SelectionPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) => w is CustomPaint && w.painter is SelectionPainter,
                    ),
                  )
                  .painter!
              as SelectionPainter;
      Future<List<int>> centerPixel() async {
        late List<int> value;
        await tester.runAsync(() async {
          final p = painter();
          final bytes = await renderCapture(p.image!, p.marks, p.region);
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          final pixels = (await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final index = (110 * frame.image.width + 150) * 4;
          value = pixels.sublist(index, index + 4);
          frame.image.dispose();
          codec.dispose();
        });
        return value;
      }

      expect(await centerPixel(), [217, 45, 62, 255]);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 140), const Offset(0, 80));
      await tester.pump();
      expect(painter().marks.last.tool, MarkTool.erase);
      expect(painter().marks.last.points.length, greaterThan(1));
      expect(await centerPixel(), [255, 255, 255, 255]);
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(await centerPixel(), [217, 45, 62, 255]);
      await tester.tap(find.byTooltip('重做'));
      await tester.pump();
      expect(await centerPixel(), [255, 255, 255, 255]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Toolbar keeps its dimensions and all four edges within each monitor',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ClipController(bridge: FakeBridge('unused'))
        ..ready = true;
      addTearDown(controller.dispose);
      late Uint8List bytes;
      await tester.runAsync(() async {
        final image = await sample(width: 1240, height: 600);
        bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
        image.dispose();
      });
      final screens = [
        const Rect.fromLTWH(0, 0, 620, 600),
        const Rect.fromLTWH(620, 0, 620, 600),
      ];
      Size? previous;
      for (final screen in screens) {
        for (final corner in [
          screen.topLeft + const Offset(2, 2),
          screen.topRight + const Offset(-162, 2),
          screen.bottomLeft + const Offset(2, -182),
          screen.bottomRight + const Offset(-162, -182),
        ]) {
          final window = Rect.fromLTWH(corner.dx, corner.dy, 160, 180);
          await tester.runAsync(
            () => controller.loadBytes(
              bytes,
              mode: 'window',
              windows: [window],
              screens: screens,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Workspace(controller: controller),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pumpAndSettle();
          await tester.tapAt(window.center);
          await tester.pumpAndSettle();
          Rect toolbar() => tester.getRect(find.byType(GlassPanel).last);
          void contained() {
            final r = toolbar();
            expect(r.left, greaterThanOrEqualTo(screen.left));
            expect(r.top, greaterThanOrEqualTo(screen.top));
            expect(r.right, lessThanOrEqualTo(screen.right));
            expect(r.bottom, lessThanOrEqualTo(screen.bottom));
          }

          contained();
          previous ??= toolbar().size;
          expect(toolbar().size, previous);
          await tester.tap(find.byTooltip('文字 · T'));
          await tester.pump();
          contained();
          await tester.pump(const Duration(milliseconds: 65));
          contained();
          await tester.pumpAndSettle();
          contained();
          await tester.tap(find.byTooltip('文字背景颜色'));
          await tester.pump();
          contained();
          await tester.pump(const Duration(milliseconds: 65));
          contained();
          await tester.pumpAndSettle();
          contained();
          expect(tester.takeException(), isNull);
        }
      }
    },
  );
  test('Cross-monitor selection chooses one monitor and supports portrait or offset displays', () {
    const viewport = Rect.fromLTWH(0, 0, 2400, 1500);
    final monitors = [
      const Rect.fromLTWH(0, 300, 1200, 900),
      const Rect.fromLTWH(1200, 0, 900, 1500),
    ];
    expect(
      toolbarScreen(
        const Rect.fromLTWH(1100, 400, 600, 700),
        monitors,
        viewport,
      ),
      monitors[1],
    );
    for (final monitor in monitors) {
      for (final selected in [
        monitor,
        Rect.fromCenter(center: monitor.topLeft, width: 100, height: 100),
        Rect.fromCenter(center: monitor.bottomRight, width: 100, height: 100),
      ]) {
        final layout = ToolbarLayout(selection: selected, screen: monitor);
        final constraints = layout.getConstraintsForChild(
          BoxConstraints.tight(viewport.size),
        );
        final child = Size(constraints.maxWidth, 240);
        final point = layout.getPositionForChild(viewport.size, child);
        expect(monitor.contains(point), true);
        expect(point.dx + child.width, lessThanOrEqualTo(monitor.right));
        expect(point.dy + child.height, lessThanOrEqualTo(monitor.bottom));
      }
    }
  });
  test(
    'Mosaic is local, blocky, below annotations and can be erased',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (int x = 0; x < 126; x++) {
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), 0, 1, 84),
          Paint()..color = Color.fromARGB(255, x * 2, x * 2, x * 2),
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(126, 84);
      picture.dispose();
      final small = await makeMosaicImage(image);
      final marks = [
        Mark(MarkTool.mosaic, Colors.white, 4, [
          const Offset(63, 15),
          const Offset(63, 75),
        ]),
      ];
      Future<List<int>> pixels({bool cached = false}) async {
        final bytes = await renderCapture(
          image,
          marks,
          null,
          mosaic: cached ? small : null,
        );
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final data = (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List().toList();
        frame.image.dispose();
        codec.dispose();
        return data;
      }

      List<int> at(List<int> p, int x, int y) =>
          p.sublist((y * 126 + x) * 4, (y * 126 + x) * 4 + 4);
      final first = await pixels();
      expect(at(first, 59, 40), at(first, 63, 40));
      expect(at(first, 5, 5), [10, 10, 10, 255]);
      expect(first, await pixels(cached: true));
      marks.insert(
        0,
        Mark(MarkTool.arrow, Colors.red, 4, [
          const Offset(20, 50),
          const Offset(100, 50),
        ]),
      );
      final foreground = await pixels();
      expect(at(foreground, 65, 50), [244, 67, 54, 255]);
      marks.add(
        Mark(MarkTool.erase, Colors.white, 1, [
          const Offset(60, 20),
          const Offset(60, 70),
        ]),
      );
      final erased = await pixels();
      expect(at(erased, 60, 40), [120, 120, 120, 255]);
      expect(at(erased, 60, 50), [120, 120, 120, 255]);
      small.dispose();
      image.dispose();
    },
  );
  testWidgets(
    'One privacy icon switches modes, preserves brush interaction and undo',
    (tester) async {
      tester.view.physicalSize = const Size(620, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ClipController(bridge: FakeBridge('unused'))
        ..ready = true;
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        final image = await sample(width: 620, height: 480);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        await controller.loadBytes(bytes);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Workspace(controller: controller),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(50, 70), const Offset(500, 240));
      await tester.pumpAndSettle();
      expect(find.byTooltip('隐私画笔 · B'), findsOneWidget);
      await tester.tap(find.byTooltip('隐私画笔 · B'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('模糊画笔'), findsOneWidget);
      expect(find.byTooltip('马赛克画笔'), findsOneWidget);
      await tester.tap(find.byTooltip('马赛克画笔'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(130, 180), const Offset(240, 0));
      await tester.pump();
      SelectionPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) => w is CustomPaint && w.painter is SelectionPainter,
                    ),
                  )
                  .painter!
              as SelectionPainter;
      expect(painter().marks.last.tool, MarkTool.mosaic);
      expect(painter().marks.last.points.length, greaterThan(1));
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(painter().marks, isEmpty);
      await tester.tap(find.byTooltip('重做'));
      await tester.pump();
      expect(painter().marks.last.tool, MarkTool.mosaic);
      await tester.tap(find.byTooltip('画笔 · P'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();
      final button = tester.widget<ToolButton>(
        find
            .ancestor(
              of: find.byTooltip('马赛克画笔'),
              matching: find.byType(ToolButton),
            )
            .first,
      );
      expect(button.selected, true);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 200));
      await mouse.moveTo(const Offset(201, 200));
      await tester.pump();
      final cursor =
          tester
                  .widgetList<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is CustomPaint && w.painter is BrushCursorPainter,
                    ),
                  )
                  .first
                  .painter!
              as BrushCursorPainter;
      expect(cursor.color, Colors.white);
      expect(cursor.diameter, 27);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Reduced motion keeps state transitions immediate and buttons usable',
    (tester) async {
      bool selected = false;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatefulBuilder(
              builder: (context, set) => Center(
                child: StateTransition(
                  child: ToolButton(
                    key: ValueKey(selected),
                    label: '切换状态',
                    selected: selected,
                    onPressed: () => set(() => selected = !selected),
                    icon: Icons.check,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('切换状态'));
      await tester.pump();
      expect(selected, true);
      expect(tester.widget<ToolButton>(find.byType(ToolButton)).selected, true);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'System theme persists and legacy explicit theme settings are preserved',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'screenclip-theme-',
      );
      try {
        final file = File('${directory.path}/preferences.json');
        await file.writeAsString(jsonEncode({'dark': true, 'delay': 3}));
        final old = ClipController(bridge: FakeBridge(directory.path));
        await old.initialize();
        expect(old.themeMode, ThemeMode.dark);
        expect(old.delay, 3);
        await old.settings(appearance: ThemeMode.system);
        old.dispose();
        final fresh = ClipController(bridge: FakeBridge(directory.path));
        await fresh.initialize();
        expect(fresh.themeMode, ThemeMode.system);
        expect(fresh.delay, 3);
        fresh.dispose();
        expect(
          (jsonDecode(await file.readAsString()) as Map)['appearance'],
          'system',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'System appearance responds live, while explicit light remains fixed',
    (tester) async {
      final controller = ClipController(bridge: FakeBridge('unused'))
        ..ready = true
        ..panel = 'settings';
      addTearDown(controller.dispose);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            themeMode: controller.themeMode,
            theme: screenClipTheme(Brightness.light),
            darkTheme: screenClipTheme(Brightness.dark),
            home: Workspace(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Brightness brightness() =>
          Theme.of(tester.element(find.byType(Preferences))).brightness;
      expect(brightness(), Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);
      await tester.tap(find.byTooltip('浅色外观'));
      await tester.pumpAndSettle();
      expect(controller.themeMode, ThemeMode.light);
      expect(brightness(), Brightness.light);
      await tester.tap(find.byTooltip('跟随系统外观'));
      await tester.pumpAndSettle();
      expect(controller.themeMode, ThemeMode.system);
      expect(brightness(), Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
    },
  );
  testWidgets(
    'Capture strip remains usable on compact and large desktop surfaces',
    (tester) async {
      final bridge = FakeBridge('unused');
      final controller = ClipController(bridge: bridge)..ready = true;
      addTearDown(controller.dispose);
      for (final size in [
        const Size(440, 300),
        const Size(620, 280),
        const Size(1024, 768),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(home: Workspace(controller: controller)),
        );
        await tester.pump();
        expect(find.text('区域截图'), findsOneWidget);
        expect(find.text('窗口截图'), findsOneWidget);
        expect(find.text('全屏截图'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}
