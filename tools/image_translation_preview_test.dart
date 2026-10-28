import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/editor.dart';

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
      final marks = [
        imageTranslationMark('定格瞬间，保留原意。', boxes[0]),
        imageTranslationMark('选择图片中的文字并翻译。', boxes[1]),
      ];
      final output = Directory('build/translation-previews')
        ..createSync(recursive: true);
      await File('${output.path}/image-original.png')
          .writeAsBytes(await renderCapture(image, [], null));
      await File('${output.path}/image-translated.png')
          .writeAsBytes(await renderCapture(image, marks, null));
      image.dispose();
    },
  );
}
