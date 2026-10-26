import 'dart:math' as math;

import 'package:desktop_vision/desktop_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OcrGlyph {
  const OcrGlyph(this.start, this.end, this.box, this.line);
  final int start, end, line;
  final Rect box;
}

/// Text offsets preserve spaces/newlines; rectangles use the cropped image's
/// normalized coordinates so selection stays aligned at any display scale.
class OcrSelection extends ChangeNotifier {
  OcrSelection(OcrResult result) {
    final text = StringBuffer();
    for (final (index, line) in result.lines.indexed) {
      if (index > 0) text.write('\n');
      final base = text.length;
      text.write(line.text);
      // Some Vision revisions return a whole word's box for each character.
      // In that case subdivide the word using shaped text advances instead.
      final preciseCharacters =
          line.characters.isNotEmpty &&
          line.characters.map((c) => c.normalizedBox).toSet().length ==
              line.characters.length;
      final tokens = preciseCharacters ? line.characters : line.words;
      if (tokens.isEmpty) {
        _addToken(line.text, line.normalizedBox, base, index);
      } else {
        int search = 0;
        for (final token in tokens) {
          final offset = line.text.indexOf(token.text, search);
          if (offset < 0 || token.text.isEmpty) continue;
          _addToken(token.text, token.normalizedBox, base + offset, index);
          search = offset + token.text.length;
        }
      }
    }
    this.text = text.toString();
  }

  late final String text;
  final glyphs = <OcrGlyph>[];
  TextSelection selection = const TextSelection.collapsed(offset: 0);
  bool copied = false, copying = false;
  bool dragging = false;
  String? error;
  bool get hasText => glyphs.isNotEmpty && text.isNotEmpty;
  String get selectedText => text.substring(selection.start, selection.end);

  void _addToken(String token, Rect box, int base, int line) {
    if (box.isEmpty || !box.isFinite) return;
    final painter = TextPainter(
      text: TextSpan(text: token, style: const TextStyle(fontSize: 100)),
      textDirection: TextDirection.ltr,
    )..layout();
    int offset = 0;
    for (final character in token.characters) {
      final end = offset + character.length;
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: end),
      );
      if (boxes.isNotEmpty && painter.width > 0) {
        final bounds = boxes
            .map((b) => b.toRect())
            .reduce((a, b) => a.expandToInclude(b));
        glyphs.add(
          OcrGlyph(
            base + offset,
            base + end,
            Rect.fromLTRB(
              box.left + bounds.left / painter.width * box.width,
              box.top,
              box.left + bounds.right / painter.width * box.width,
              box.bottom,
            ),
            line,
          ),
        );
      }
      offset = end;
    }
    painter.dispose();
  }

  int hit(Offset point) {
    if (glyphs.isEmpty) return 0;
    OcrGlyph best = glyphs.first;
    double distance = double.infinity;
    for (final glyph in glyphs) {
      final box = glyph.box;
      final dy = math.max(
        math.max(box.top - point.dy, point.dy - box.bottom),
        0.0,
      );
      final dx = math.max(
        math.max(box.left - point.dx, point.dx - box.right),
        0.0,
      );
      // Prefer the line under the pointer before choosing a character boundary.
      final score = dy * 1000 + dx;
      if (score < distance) {
        distance = score;
        best = glyph;
      }
    }
    return point.dx < best.box.center.dx ? best.start : best.end;
  }

  void begin(Offset point) {
    dragging = true;
    selection = TextSelection.collapsed(offset: hit(point));
    copied = false;
    error = null;
    notifyListeners();
  }

  void extend(Offset point) {
    selection = TextSelection(
      baseOffset: selection.baseOffset,
      extentOffset: hit(point),
    );
    copied = false;
    error = null;
    notifyListeners();
  }

  void end() {
    dragging = false;
  }

  void selectAll() {
    selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    copied = false;
    error = null;
    notifyListeners();
  }

  List<Rect> get highlights {
    final lines = <int, Rect>{};
    for (final glyph in glyphs) {
      if (glyph.start < selection.end && glyph.end > selection.start) {
        lines.update(
          glyph.line,
          (box) => box.expandToInclude(glyph.box),
          ifAbsent: () => glyph.box,
        );
      }
    }
    return lines.values.toList();
  }

  Future<void> copy() async {
    if (selectedText.isEmpty || copying) return;
    final value = selectedText;
    copying = true;
    error = null;
    notifyListeners();
    try {
      await Clipboard.setData(ClipboardData(text: value));
      copied = selectedText == value;
    } catch (_) {
      error = '复制失败，请重试';
    } finally {
      copying = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
