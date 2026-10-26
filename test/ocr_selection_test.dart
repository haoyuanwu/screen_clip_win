import 'package:desktop_vision/desktop_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/ocr_selection.dart';
import 'package:screen_clip_win/src/ui/ocr_overlay.dart';

void main() {
  test(
    'OCR selection preserves spaces, repeated words and grapheme boundaries',
    () {
      final result = OcrResult.fromMap({
        'imageWidth': 1000,
        'imageHeight': 500,
        'lines': [
          {
            'text': 'Hello  Hello',
            'x': .1,
            'y': .1,
            'w': .7,
            'h': .1,
            'words': [
              {'text': 'Hello', 'x': .1, 'y': .1, 'w': .2, 'h': .1},
              {'text': 'Hello', 'x': .5, 'y': .1, 'w': .2, 'h': .1},
            ],
          },
          {'text': '中文👩‍💻', 'x': .1, 'y': .5, 'w': .4, 'h': .1},
        ],
      });
      final selection = OcrSelection(result);
      addTearDown(selection.dispose);
      expect(selection.text, 'Hello  Hello\n中文👩‍💻');
      selection.begin(const Offset(.099, .15));
      selection.extend(const Offset(.701, .15));
      expect(selection.selectedText, 'Hello  Hello');
      expect(selection.highlights, hasLength(1));
      selection.selectAll();
      expect(selection.selectedText, selection.text);
      expect(selection.highlights, hasLength(2));
      final emoji = selection.glyphs.last;
      expect(selection.text.substring(emoji.start, emoji.end), '👩‍💻');
      selection.begin(Offset(emoji.box.left, emoji.box.center.dy));
      selection.extend(Offset(emoji.box.right, emoji.box.center.dy));
      expect(selection.selectedText, '👩‍💻');
    },
  );

  test('Duplicate Vision character boxes fall back to word positioning', () {
    final result = OcrResult.fromMap({
      'lines': [
        {
          'text': 'AB',
          'x': .2,
          'y': .1,
          'w': .4,
          'h': .1,
          'words': [
            {'text': 'AB', 'x': .2, 'y': .1, 'w': .4, 'h': .1},
          ],
          'characters': [
            {'text': 'A', 'x': .2, 'y': .1, 'w': .4, 'h': .1},
            {'text': 'B', 'x': .2, 'y': .1, 'w': .4, 'h': .1},
          ],
        },
      ],
    });
    final selection = OcrSelection(result);
    addTearDown(selection.dispose);
    expect(
      selection.glyphs[0].box.right,
      closeTo(selection.glyphs[1].box.left, .0001),
    );
    selection.begin(const Offset(.2, .15));
    selection.extend(Offset(selection.glyphs.first.box.right, .15));
    expect(selection.selectedText, 'A');
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'OCR reveals all copyable lines once and dismisses on selection (reduced: $reduced)',
      (tester) async {
        OcrSelection create() => OcrSelection(
          OcrResult.fromMap({
            'lines': [
              {'text': 'Hello', 'x': .1, 'y': .1, 'w': .5, 'h': .1},
              {'text': '文字', 'x': .2, 'y': .5, 'w': .4, 'h': .1},
            ],
          }),
        );
        final selection = create();
        addTearDown(selection.dispose);
        Future<void> mount(OcrSelection controller) => tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Center(
                child: SizedBox(
                  width: 400,
                  height: 200,
                  child: OcrTextOverlay(selection: controller),
                ),
              ),
            ),
          ),
        );
        OcrHighlightPainter painter() => tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((p) => p.painter)
            .whereType<OcrHighlightPainter>()
            .single;
        await mount(selection);
        expect(painter().regions, hasLength(2));
        expect(painter().boxes, isEmpty);
        await tester.pump(const Duration(milliseconds: 240));
        expect(painter().revealOpacity, greaterThan(.95));
        await tester.pump(const Duration(milliseconds: 1500));
        expect(painter().revealOpacity, 0);
        await tester.pump(const Duration(seconds: 2));
        expect(painter().revealOpacity, 0);
        final next = create();
        addTearDown(next.dispose);
        await mount(next);
        await tester.pump(const Duration(milliseconds: 240));
        expect(painter().revealOpacity, greaterThan(.95));
        final origin = tester.getTopLeft(find.byType(OcrTextOverlay));
        final drag = await tester.startGesture(origin + const Offset(40, 30));
        await drag.moveTo(origin + const Offset(240, 30));
        await tester.pump();
        expect(painter().revealOpacity, 0);
        expect(next.selectedText, 'Hello');
        expect(painter().boxes, hasLength(1));
        await drag.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'OCR scan follows reduced motion and keeps progress inside its bounds',
    (tester) async {
      bool reduced = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return MediaQuery(
                data: MediaQueryData(disableAnimations: reduced),
                child: const Center(
                  child: SizedBox(
                    width: 320,
                    height: 200,
                    child: OcrScanOverlay(),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      OcrScanPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<OcrScanPainter>()
          .single;
      expect(painter().progress, greaterThan(0));
      expect(painter().reduced, false);
      expect(tester.getSize(find.byType(OcrScanOverlay)), const Size(320, 200));
      update(() => reduced = true);
      await tester.pumpAndSettle();
      expect(painter().reduced, true);
      final progress = painter().progress;
      await tester.pump(const Duration(seconds: 2));
      expect(painter().progress, progress);
      expect(find.bySemanticsLabel('正在识别选区文字'), findsOneWidget);
    },
  );
}
