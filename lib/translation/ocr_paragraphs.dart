import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/ocr_selection.dart';

class OcrParagraph {
  const OcrParagraph(this.text, this.box);
  final String text;
  final Rect box;
}

/// Group wrapped lines using image-space geometry, keeping columns, headings
/// and list items separate. Return normalized boxes for the capture overlay.
List<OcrParagraph> translationParagraphs(OcrSelection selection, Size image) {
  final lines = <int, List<OcrGlyph>>{};
  for (final glyph in selection.glyphs) {
    if (!selection.selection.isCollapsed &&
        (glyph.end <= selection.selection.start ||
            glyph.start >= selection.selection.end)) {
      continue;
    }
    lines.putIfAbsent(glyph.line, () => []).add(glyph);
  }
  final paragraphs = <_Paragraph>[];
  for (final glyphs in lines.values) {
    final normalized = glyphs
        .map((g) => g.box)
        .reduce((a, b) => a.expandToInclude(b));
    final box = Rect.fromLTWH(
      normalized.left * image.width,
      normalized.top * image.height,
      normalized.width * image.width,
      normalized.height * image.height,
    );
    final text = selection.text
        .substring(glyphs.first.start, glyphs.last.end)
        .trim();
    if (text.isEmpty) continue;
    _Paragraph? previous;
    double nearest = double.infinity;
    for (final p in paragraphs) {
      final last = p.last;
      final height = math.max(last.height, box.height);
      final gap = box.top - last.bottom;
      final overlap =
          math.min(last.right, box.right) - math.max(last.left, box.left);
      final aligned = (box.left - p.box.left).abs() <= height * .8;
      final indentedFirstLine =
          p.count == 1 &&
          box.left < last.left &&
          last.left - box.left <= height * 2.2;
      final sameSize = math.min(last.height, box.height) / height >= .72;
      final continues = last.width >= p.box.width * .65;
      final listItem = RegExp(r'^(?:[•●▪‣]|[-*]\s|\d+[.)、]\s*)').hasMatch(text);
      final normalizedGap = gap / height;
      // Compare whitespace, not just distance between line centers. A larger
      // blank band usually means a new block, even when both left edges align.
      final regularGaps = [...p.gaps]..sort();
      final typicalGap = regularGaps.isEmpty
          ? null
          : regularGaps[regularGaps.length ~/ 2];
      final similarSpacing =
          typicalGap == null || normalizedGap <= typicalGap * 1.5 + .06;
      final separateLabels = _shortLabel(p.lastText) && _shortLabel(text);
      if (!listItem &&
          !separateLabels &&
          sameSize &&
          continues &&
          gap >= -height * .15 &&
          normalizedGap <= .4 &&
          similarSpacing &&
          overlap > math.min(last.width, box.width) * .5 &&
          (aligned || indentedFirstLine) &&
          gap < nearest) {
        previous = p;
        nearest = gap;
      }
    }
    if (previous == null) {
      paragraphs.add(_Paragraph(text, box));
    } else {
      previous.text = _join(previous.text, text);
      previous.gaps.add(
        math.max(
          0,
          (box.top - previous.last.bottom) /
              math.max(previous.last.height, box.height),
        ),
      );
      previous.lastText = text;
      previous.box = previous.box.expandToInclude(box);
      previous.last = box;
      previous.count++;
    }
  }
  return paragraphs
      .map(
        (p) => OcrParagraph(
          p.text,
          Rect.fromLTWH(
            p.box.left / image.width,
            p.box.top / image.height,
            p.box.width / image.width,
            p.box.height / image.height,
          ),
        ),
      )
      .toList();
}

bool _shortLabel(String text) {
  // Close navigation labels and form fields are not wrapped prose. Keep the
  // decision conservative; punctuation/hyphenation may indicate continuation.
  if (RegExp(r'[.!?。！？,，;；:\-]$').hasMatch(text)) return false;
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(text)) return text.length <= 6;
  return text.length <= 16 && text.trim().split(RegExp(r'\s+')).length <= 2;
}

String _join(String first, String next) {
  if (RegExp(r'[A-Za-z]-$').hasMatch(first) &&
      RegExp(r'^[a-z]').hasMatch(next)) {
    return first.substring(0, first.length - 1) + next;
  }
  final cjk = RegExp(r'[\u3400-\u9fff\u3000-\u303f\uff00-\uffef]');
  return '$first${cjk.hasMatch(first[first.length - 1]) && cjk.hasMatch(next[0]) ? '' : ' '}$next';
}

class _Paragraph {
  _Paragraph(this.text, this.box) : last = box, lastText = text;
  String text, lastText;
  Rect box, last;
  int count = 1;
  final gaps = <double>[];
}
