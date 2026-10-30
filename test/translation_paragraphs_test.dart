import 'package:desktop_vision/desktop_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/ocr_selection.dart';
import 'package:screen_clip_win/translation/ocr_paragraphs.dart';

OcrLine line(
  String text,
  double x,
  double y,
  double width, {
  double height = 20,
}) {
  final rect = Rect.fromLTWH(x, y, width, height);
  return OcrLine(
    text: text,
    pixelBox: rect,
    normalizedBox: Rect.fromLTWH(
      x / 1000,
      y / 1000,
      width / 1000,
      height / 1000,
    ),
  );
}

List<OcrParagraph> paragraphs(List<OcrLine> lines, {TextSelection? selected}) {
  final selection = OcrSelection(
    OcrResult(
      engine: 'fixture',
      text: lines.map((l) => l.text).join('\n'),
      lines: lines,
      imageWidth: 1000,
      imageHeight: 1000,
    ),
  );
  if (selected != null) selection.selection = selected;
  final result = translationParagraphs(selection, const Size(1000, 1000));
  selection.dispose();
  return result;
}

void main() {
  test('Nearby aligned blocks separated by larger whitespace do not merge', () {
    final result = paragraphs([
      line('First paragraph continues', 30, 20, 400),
      line('on this tightly spaced line', 30, 44, 400),
      line('A separate paragraph begins', 30, 76, 400),
      line('and continues on its own line', 30, 100, 400),
    ]);
    expect(result.map((p) => p.text), [
      'First paragraph continues on this tightly spaced line',
      'A separate paragraph begins and continues on its own line',
    ]);
  });

  test('A sudden spacing increase breaks a previously tight paragraph', () {
    final result = paragraphs([
      line('A paragraph with very tight lines', 30, 20, 400),
      line('continues with the same spacing', 30, 42, 400),
      line('This independently spaced block', 30, 69, 400),
    ]);
    expect(result, hasLength(2));
  });

  test('Closely stacked short interface labels remain independent', () {
    final result = paragraphs([
      line('General', 30, 20, 140),
      line('Privacy', 30, 44, 140),
      line('设置', 30, 100, 80),
      line('语言', 30, 124, 80),
    ]);
    expect(result.map((p) => p.text), ['General', 'Privacy', '设置', '语言']);
  });
  test('Readable translation frames grow and move without overlapping', () {
    final input = [
      imageTranslationMark(
        '这是一整段较长的中文译文，需要扩展原来的文字框，保持足够大的字号。',
        const Rect.fromLTWH(20, 20, 100, 20),
        translationId: 1,
      ),
      imageTranslationMark(
        '第二段译文不能和第一段的文字框重叠。',
        const Rect.fromLTWH(20, 45, 100, 20),
        translationId: 2,
      ),
      imageTranslationMark(
        'Third passage with more readable text.',
        const Rect.fromLTWH(350, 250, 60, 20),
        translationId: 3,
      ),
    ];
    const bounds = Rect.fromLTWH(0, 0, 600, 350);
    final output = layoutTranslationMarks(input, bounds);
    expect(output.map((m) => m.fontSize).toSet(), {20.0});
    expect(output.first.textBoxSize.width, greaterThan(100));
    for (var i = 0; i < output.length; i++) {
      final mark = output[i];
      final rect = mark.points.first & mark.textBoxSize;
      expect(bounds.contains(rect.topLeft), true);
      expect(rect.right, lessThanOrEqualTo(bounds.right));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      final painter = mark.textPainter;
      expect(
        painter.height + mark.padding * 2,
        lessThanOrEqualTo(rect.height + .01),
      );
      painter.dispose();
      for (final previous in output.take(i)) {
        expect(
          rect.overlaps(previous.points.first & previous.textBoxSize),
          false,
        );
      }
    }
    final scaled = layoutTranslationMarks(
      input,
      const Rect.fromLTWH(0, 0, 1200, 700),
      scale: .5,
    );
    expect(scaled.first.fontSize * .5, 20);
  });

  test('Wrapped English and Chinese paragraphs translate together with union boxes', () {
    final result = paragraphs([
      line('This is a paragraph that', 30, 30, 400),
      line('continues on another line.', 30, 56, 350),
      line('这是另一段需要完整', 30, 120, 400),
      line('翻译的中文内容。', 30, 146, 300),
    ]);
    expect(result.map((p) => p.text), [
      'This is a paragraph that continues on another line.',
      '这是另一段需要完整翻译的中文内容。',
    ]);
    expect(result.first.box, const Rect.fromLTWH(.03, .03, .4, .046));
  });

  test(
    'Interleaved columns stay separate and wrap within their own column',
    () {
      final result = paragraphs([
        line('Left column begins', 30, 30, 350),
        line('Right column begins', 550, 30, 350),
        line('and continues here.', 30, 56, 300),
        line('with different text.', 550, 56, 300),
      ]);
      expect(result.map((p) => p.text), [
        'Left column begins and continues here.',
        'Right column begins with different text.',
      ]);
    },
  );

  test('Headings, blank gaps, list entries and short paragraph endings remain separate', () {
    final result = paragraphs([
      line('Heading', 30, 10, 300, height: 32),
      line('Body text', 30, 48, 400),
      line('finishes.', 30, 74, 150),
      line('New paragraph', 30, 100, 400),
      line('• First item', 30, 126, 400),
      line('• Second item', 30, 152, 400),
    ]);
    expect(result.map((p) => p.text), [
      'Heading',
      'Body text finishes.',
      'New paragraph',
      '• First item',
      '• Second item',
    ]);
  });

  test(
    'Only selected lines are grouped and English word wrapping is restored',
    () {
      final result = paragraphs([
        line('Skip this', 30, 0, 400),
        line('Transla-', 30, 50, 400),
        line('tion works.', 30, 76, 300),
      ], selected: const TextSelection(baseOffset: 10, extentOffset: 30));
      expect(result.single.text, 'Translation works.');
    },
  );

  test(
    'Translation annotations share a font size and fit every paragraph frame',
    () {
      final marks = uniformTranslationMarks([
        imageTranslationMark('短译文', const Rect.fromLTWH(0, 0, 250, 80)),
        imageTranslationMark(
          '这是较长的译文，需要在同一个段落框中换行并完整显示。',
          const Rect.fromLTWH(0, 100, 250, 60),
        ),
      ]);
      expect(marks.map((m) => m.fontSize).toSet(), hasLength(1));
      for (final mark in marks) {
        final painter = mark.textPainter;
        expect(
          painter.height + mark.padding * 2,
          lessThanOrEqualTo(mark.textFrame!.height + .01),
        );
        painter.dispose();
      }
    },
  );
}
