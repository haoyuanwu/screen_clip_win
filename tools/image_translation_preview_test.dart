import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/translation/source_appearance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Image translation preserves positions and export backgrounds',
    () async {
      for (final family in ['Microsoft YaHei', 'PingFang SC']) {
        final font = File('/System/Library/Fonts/Hiragino Sans GB.ttc');
        if (!font.existsSync()) continue;
        final bytes = await font.readAsBytes();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xff20242d), BlendMode.src);
      final boxes = [
        const Rect.fromLTWH(32, 45, 470, 40),
        const Rect.fromLTWH(32, 140, 520, 54),
      ];
      final originals = [
        'Capture a moment. Keep meaning.',
        'Select text in the image and translate it.',
      ];
      for (var i = 0; i < boxes.length; i++) {
        final painter = TextPainter(
          text: TextSpan(
            text: originals[i],
            style: const TextStyle(
              fontFamily: 'PingFang SC',
              fontSize: 24,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: boxes[i].width);
        painter.paint(canvas, boxes[i].topLeft);
        painter.dispose();
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(600, 240);
      picture.dispose();
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final texts = ['定格瞬间，保留原意。', '选择图片中的文字并翻译。'];
      final marks = layoutTranslationMarks(
        [
          for (var i = 0; i < boxes.length; i++)
            imageTranslationMark(texts[i], boxes[i]).copyText(
              size: 24,
              ink: sourceAppearance(pixels, 600, 240, boxes[i]).ink,
              sourceRestoration: [
                (
                  boxes[i],
                  sourceAppearance(pixels, 600, 240, boxes[i]).background,
                ),
              ],
            ),
        ],
        const Rect.fromLTWH(0, 0, 600, 240),
        mimicSource: true,
      );
      final output = Directory('build/translation-previews')
        ..createSync(recursive: true);
      expect(marks.every((m) => m.background.a == 0), true);
      expect(marks.every((m) => m.fontSize == 24), true);
      expect(
        marks.every(
          (m) => m.sourceRestoration.single.$2 == const Color(0xff20242d),
        ),
        true,
      );
      await File('${output.path}/image-original.png')
          .writeAsBytes(await renderCapture(image, [], null));
      await File('${output.path}/image-translated.png')
          .writeAsBytes(await renderCapture(image, marks, null));
      image.dispose();
    },
  );
}
