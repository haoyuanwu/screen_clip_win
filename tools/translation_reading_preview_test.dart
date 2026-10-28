import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:screen_clip_win/translation/service.dart';
import 'package:screen_clip_win/translation/ui/reading_panel.dart';

import '../test/translation_test.dart' show configured;
import '../test/translation_reading_test.dart' show ReadingOcrBridge;

void main() {
  setUpAll(() async {
    for (final family in ['Microsoft YaHei', 'PingFang SC', 'SF Pro Text']) {
      final file = File('/System/Library/Fonts/Hiragino Sans GB.ttc');
      if (!file.existsSync()) continue;
      await (FontLoader(
        family,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
    for (final entry in {
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  for (final dark in [false, true]) {
    for (final position in ['full', 'left', 'right']) {
      testWidgets(
        'Translation linked reading visual dark=$dark position=$position',
        (tester) async {
          tester.view.physicalSize = const Size(1000, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final selection = position == 'full'
              ? const Rect.fromLTWH(0, 0, 1000, 700)
              : Rect.fromLTWH(position == 'left' ? 70 : 520, 70, 400, 420);
          final suffix = position == 'full' ? '' : '-selection-$position';
          final service = TranslationService(
            clientFactory: () => MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'content': jsonEncode([
                          '保留原文，逐段阅读。通过段落对照，可以在截图与翻译之间快速找到对应内容。',
                          '将鼠标移到原文段落，译文窗口就会定位到相应译文。两侧以相同底色标识当前段落，便于继续阅读与复制。',
                        ]),
                      },
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            ),
          );
          final controller = ClipController(
            bridge: ReadingOcrBridge(),
            translation: await configured(service: service),
          )..ready = true;
          addTearDown(controller.dispose);
          late Clip clip;
          await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawColor(
              dark ? const Color(0xff20242d) : const Color(0xfff6f5f2),
              BlendMode.src,
            );
            for (final i in [0, 1]) {
              final text = position != 'full'
                  ? (i == 0
                        ? 'Keep the source.\nRead in context.'
                        : 'Point to a paragraph.\nThe translation follows.')
                  : i == 0
                  ? 'Keep the source. Read in context.\nLink each paragraph to its translation.'
                  : 'Point to an original paragraph.\nThe matching translation follows.';
              final painter = TextPainter(
                text: TextSpan(
                  text: text,
                  style: TextStyle(
                    fontFamily: 'PingFang SC',
                    fontSize: position == 'full' ? 19 : 12,
                    height: 1.6,
                    color: dark ? Colors.white : const Color(0xff24282f),
                  ),
                ),
                textDirection: TextDirection.ltr,
              )..layout(maxWidth: selection.width * .4);
              painter.paint(
                canvas,
                Offset(
                  selection.left + selection.width * .1,
                  selection.top + selection.height * (.15 + i * .45),
                ),
              );
              painter.dispose();
            }
            final picture = recorder.endRecording();
            final image = await picture.toImage(1000, 700);
            picture.dispose();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            clip = Clip(
              bytes: data!.buffer.asUint8List(),
              width: 1000,
              height: 700,
              mode: position == 'full' ? 'screen' : 'region',
            );
            image.dispose();
          });
          final boundary = GlobalKey();
          final theme = screenClipTheme(
            dark ? Brightness.dark : Brightness.light,
          );
          double contrast(Color a, Color b) {
            final x = a.computeLuminance(), y = b.computeLuminance();
            return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
          }

          final glass = Color.alphaBlend(
            (dark ? const Color(0xff262629) : const Color(0xfffafafa))
                .withValues(alpha: dark ? .90 : .92),
            dark ? Colors.white : Colors.black,
          );
          expect(
            contrast(theme.colorScheme.onSurface, glass),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(
              theme.colorScheme.onPrimaryContainer,
              theme.colorScheme.primaryContainer,
            ),
            greaterThanOrEqualTo(4.5),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: RepaintBoundary(
                key: boundary,
                child: DefaultTextStyle(
                  style: theme.textTheme.bodyMedium!,
                  child: CaptureEditor(clip: clip, controller: controller),
                ),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          if (position != 'full') {
            await tester.dragFrom(
              selection.bottomRight,
              selection.topLeft - selection.bottomRight,
            );
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('翻译选区文字'));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          if (find.byType(TranslationReadingPanel).evaluate().isEmpty) {
            await tester.tap(find.byTooltip('对照阅读'));
          }
          await tester.pumpAndSettle();
          final mouse = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          final target = Offset(
            selection.left + selection.width * .2,
            selection.top + selection.height * .65,
          );
          await mouse.addPointer(location: target);
          await mouse.moveTo(target + const Offset(1, 1));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = Directory('build/translation-previews')
              ..createSync(recursive: true);
            await File(
              '${output.path}/reading-${dark ? 'dark' : 'light'}$suffix.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          expect(tester.takeException(), isNull);
          await mouse.removePointer();
          await tester.tap(find.byTooltip('关闭对照阅读'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('文字 · T'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('文字背景颜色'));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/translation-previews/text-toolbar-${dark ? 'dark' : 'light'}$suffix.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
