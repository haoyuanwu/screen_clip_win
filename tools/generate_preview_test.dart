import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/platform_bridge.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:screen_clip_win/src/workspace.dart';
import 'package:screen_clip_win/src/ui/controls.dart';

class PreviewBridge extends DesktopBridge {
  @override
  Future<void> present(String panel) async {}
  @override
  Future<void> dismiss() async {}
}

void main() {
  testWidgets('Render synthetic selection surfaces for visual inspection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final originalShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = originalShadows);
    final output = Directory('docs/previews');
    late Uint8List bytes;
    await tester.runAsync(() async {
      await output.create(recursive: true);
      final config = jsonDecode(
        await File('.dart_tool/package_config.json').readAsString(),
      ) as Map<String, dynamic>;
      final material = FontLoader('MaterialIcons');
      material.addFont(
        File.fromUri(
          Uri.parse("${config['flutterRoot']}/").resolve(
            'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ).readAsBytes().then(ByteData.sublistView),
      );
      await material.load();
      final packages = config['packages'] as List;
      final cupertino =
          packages.firstWhere((p) => p['name'] == 'cupertino_icons') as Map;
      final icons = FontLoader('packages/cupertino_icons/CupertinoIcons');
      icons.addFont(
        File.fromUri(
          Uri.parse('${cupertino['rootUri']}/')
              .resolve('assets/CupertinoIcons.ttf'),
        ).readAsBytes().then(ByteData.sublistView),
      );
      await icons.load();
      final loader = FontLoader('PreviewFont');
      loader.addFont(
        File('C:/Windows/Fonts/msyh.ttc')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
      await loader.load();
      final annotationFont = FontLoader('Microsoft YaHei');
      annotationFont.addFont(
        File('C:/Windows/Fonts/msyh.ttc')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
      await annotationFont.load();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xfff3f5f9), BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 210, 800),
        Paint()..color = const Color(0xff19243b),
      );
      void text(
        String value,
        double x,
        double y,
        double size,
        Color color, {
        FontWeight weight = FontWeight.normal,
      }) {
        final painter = TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: 'PreviewFont',
              fontSize: size,
              color: color,
              fontWeight: weight,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, Offset(x, y));
      }

      text('设计协作空间', 28, 36, 21, Colors.white, weight: FontWeight.bold);
      text('项目概览', 28, 130, 15, const Color(0xffdae3f4));
      text('团队文档', 28, 182, 15, const Color(0xffaebdd5));
      text('工作计划', 28, 234, 15, const Color(0xffaebdd5));
      text(
        '产品体验评审',
        260,
        40,
        28,
        const Color(0xff202c43),
        weight: FontWeight.bold,
      );
      text('项目文档  /  交互设计', 260, 88, 13, const Color(0xff58667f));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(260, 150, 950, 490),
          const Radius.circular(16),
        ),
        Paint()..color = Colors.white,
      );
      text(
        '让沟通，更直观一点。',
        300,
        184,
        26,
        const Color(0xff263550),
        weight: FontWeight.bold,
      );
      text('把重要信息留在画面里，把多余步骤交给工具。', 300, 234, 16, const Color(0xff65718a));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(300, 300, 860, 70),
          const Radius.circular(10),
        ),
        Paint()..color = const Color(0xffedf2ff),
      );
      text(
        '01   框选之后，直接在选区内标注',
        324,
        321,
        18,
        const Color(0xff315cec),
        weight: FontWeight.w600,
      );
      text('02   确认之后，图片默认进入剪贴板', 324, 409, 18, const Color(0xff35435b));
      text('03   关闭即清理，不生成任何截图记录', 324, 489, 18, const Color(0xff35435b));
      text('示例内容 · 仅用于界面验证', 300, 590, 12, const Color(0xff748097));
      final picture = recorder.endRecording();
      final im = await picture.toImage(1280, 800);
      picture.dispose();
      bytes = (await im.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
      im.dispose();
    });
    for (final dark in [false, true]) {
      final controller = ClipController(bridge: PreviewBridge())..ready = true;
      await tester.runAsync(() => controller.loadBytes(bytes));
      final key = GlobalKey();
      final base = screenClipTheme(dark ? Brightness.dark : Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'PreviewFont'),
          ),
          home: RepaintBoundary(
            key: key,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => Workspace(controller: controller),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(270, 160), const Offset(900, 450));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('箭头 · Q'));
      await tester.pump();
      await tester.dragFrom(const Offset(1060, 260), const Offset(-250, 70));
      await tester.pump();
      await tester.tap(find.byTooltip('矩形 · R'));
      await tester.pump();
      await tester.dragFrom(const Offset(310, 308), const Offset(450, 58));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/overlay-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.byTooltip('矩形 · R'));
      await tester.pumpAndSettle();
      for (final entry in [('圆形标注', 'circle'), ('椭圆标注', 'ellipse')]) {
        await tester.tap(find.byTooltip(entry.$1));
        await tester.pumpAndSettle();
        await tester.dragFrom(
          const Offset(830, 385),
          entry.$2 == 'circle'
              ? const Offset(140, 140)
              : const Offset(260, 130),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${output.path}/${entry.$2}-${dark ? 'dark' : 'light'}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.byTooltip('撤销'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('矩形 · R'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文字 · T'));
      await tester.pump();
      await tester.tapAt(const Offset(340, 440));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inline-annotation-text')),
        '选区内直接输入\n文字样式随时修改',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('加粗'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文字背景颜色'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('背景颜色：#FFFFFF'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/text-inline-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.byTooltip('完成文字'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('隐私画笔 · B'));
      await tester.pumpAndSettle();
      final slider = find.byWidgetPredicate(
        (w) => w is FineSlider && w.label == '线条粗细',
      );
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1000, 430));
      await mouse.moveTo(const Offset(1001, 430));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/brush-cursor-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await mouse.removePointer();
      await tester.tap(find.byTooltip('马赛克画笔'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(670, 280), const Offset(160, 100));
      await tester.pumpAndSettle();
      final mosaicMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mosaicMouse.addPointer(location: const Offset(850, 370));
      await mosaicMouse.moveTo(const Offset(851, 370));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/mosaic-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await mosaicMouse.removePointer();

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDisableShadows = originalShadows;
  });
}
