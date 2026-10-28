import 'dart:convert';
import 'dart:ui' as ui;

import 'package:desktop_vision/desktop_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:screen_clip_win/src/ui/controls.dart';
import 'package:screen_clip_win/translation/service.dart';
import 'package:screen_clip_win/translation/ui/reading_panel.dart';

import 'translation_test.dart' show configured, TranslateOcrBridge;
import 'widget_test.dart' show sample;

class ReadingOcrBridge extends TranslateOcrBridge {
  @override
  Future<OcrResult> recognizeText(Uint8List bytes) async {
    recognized++;
    return OcrResult(
      text: 'First paragraph\nSecond paragraph',
      imageWidth: 1000,
      imageHeight: 700,
      engine: 'test',
      lines: [
        for (var i = 0; i < 2; i++)
          OcrLine(
            text: i == 0 ? 'First paragraph' : 'Second paragraph',
            normalizedBox: Rect.fromLTWH(.1, .15 + i * .45, .4, .1),
            pixelBox: Rect.fromLTWH(100, 105 + i * 315, 400, 70),
          ),
      ],
    );
  }
}

List<TranslationPassage> samplePassages() => [
  for (var i = 0; i < 20; i++)
    TranslationPassage(
      id: i,
      source: 'Source $i',
      translation: '第 $i 段译文。长文本可以换行，滚动定位后保留上下文。',
      box: Rect.fromLTWH(100, i * 50, 300, 40),
    ),
];

void main() {
  test(
    'Compact selections and unreadably scaled translations prefer reading mode',
    () {
      expect(prefersTranslationReading(const Size(240, 180)), isTrue);
      expect(prefersTranslationReading(const Size(500, 100)), isTrue);
      expect(
        prefersTranslationReading(const Size(500, 300), textSizes: [10]),
        isTrue,
      );
      expect(
        prefersTranslationReading(const Size(500, 300), textSizes: [16]),
        isFalse,
      );
      const screen = Rect.fromLTWH(-1200, 100, 1200, 800);
      final moved = clampTranslationReadingRect(
        const Rect.fromLTWH(-1600, -200, 360, 380),
        screen,
      );
      expect(moved.left, screen.left + 8);
      expect(moved.top, screen.top + 8);
    },
  );

  test('Reading window stays on its owning screen and avoids selection and toolbar', () {
    const screen = Rect.fromLTWH(-1400, 200, 1400, 900);
    const selection = Rect.fromLTWH(-1300, 260, 600, 420);
    const toolbar = Rect.fromLTWH(-1250, 700, 500, 100);
    final panel = translationReadingRect(selection, screen, toolbar: toolbar);
    expect(screen.contains(panel.topLeft), isTrue);
    expect(screen.contains(panel.bottomRight), isTrue);
    expect(panel.overlaps(selection), isFalse);
    expect(panel.overlaps(toolbar), isFalse);
    const small = Rect.fromLTWH(0, 0, 320, 240);
    final compact = translationReadingRect(small, small);
    expect(small.contains(compact.topLeft), isTrue);
    expect(small.contains(compact.bottomRight), isTrue);
  });

  test(
    'Reading popup follows selection to either side at an eight pixel gap',
    () {
      const screen = Rect.fromLTWH(0, 0, 1400, 900);
      const leftSelection = Rect.fromLTWH(40, 100, 300, 400);
      final rightPanel = translationReadingRect(leftSelection, screen);
      expect(rightPanel.left - leftSelection.right, 8);
      const rightSelection = Rect.fromLTWH(950, 100, 300, 400);
      final leftPanel = translationReadingRect(rightSelection, screen);
      expect(rightSelection.left - leftPanel.right, 8);
      const wideSelection = Rect.fromLTWH(40, 40, 1320, 300);
      final bottomPanel = translationReadingRect(wideSelection, screen);
      expect(bottomPanel.top - wideSelection.bottom, 8);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'Reading panel scrolls to linked passage and supports compact text scaling dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var active = 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: screenClipTheme(dark ? Brightness.dark : Brightness.light),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return TranslationReadingPanel(
                    passages: samplePassages(),
                    activeId: active,
                    onSelect: (id) => setState(() => active = id),
                    onClose: () {},
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        update(() => active = 18);
        await tester.pumpAndSettle();
        final highlighted = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('translation-passage-18')),
        );
        expect(
          (highlighted.decoration as BoxDecoration).color,
          translationMatchBackground,
        );
        expect(find.text('19 · 正在对照').hitTestable(), findsOneWidget);
        expect(
          tester
                  .widget<Scrollable>(find.byType(Scrollable).first)
                  .controller
                  ?.offset ??
              tester
                  .state<ScrollableState>(find.byType(Scrollable).first)
                  .position
                  .pixels,
          greaterThan(0),
        );
        await tester.tap(find.byTooltip('下一段译文'));
        await tester.pumpAndSettle();
        expect(active, 19);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Hovering original OCR passages locates matching translation without another request',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      final service = TranslationService(
        clientFactory: () => MockClient((request) async {
          requests++;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode(['第一段译文', '第二段译文']),
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final translation = await configured(service: service);
      final bridge = ReadingOcrBridge();
      final controller = ClipController(
        bridge: bridge,
        translation: translation,
      )..ready = true;
      addTearDown(controller.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final image = await sample(width: 1000, height: 700);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        clip = Clip(
          bytes: data!.buffer.asUint8List(),
          width: 1000,
          height: 700,
          mode: 'screen',
        );
        image.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(clip: clip, controller: controller),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻译选区文字'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('对照阅读'));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(120, 120));
      await mouse.moveTo(const Offset(200, 450));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TranslationReadingPanel>(
              find.byType(TranslationReadingPanel),
            )
            .activeId,
        1,
      );
      final source = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<TranslationSourceHighlight>()
          .single;
      expect(source.activeId, 1);
      expect(source.passages[1].source, 'Second paragraph');
      await mouse.moveTo(const Offset(200, 130));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TranslationReadingPanel>(
              find.byType(TranslationReadingPanel),
            )
            .activeId,
        0,
      );

      final panelFinder = find.byType(TranslationReadingPanel);
      final originalPanel = tester.getRect(panelFinder);
      await tester.drag(
        find.byKey(const ValueKey('translation-reading-drag-handle')),
        const Offset(-120, 90),
      );
      await tester.pumpAndSettle();
      final movedPanel = tester.getRect(panelFinder);
      expect(movedPanel.left, closeTo(originalPanel.left - 120, 1));
      expect(movedPanel.top, closeTo(originalPanel.top + 90, 1));
      await mouse.moveTo(const Offset(200, 450));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(panelFinder),
        movedPanel,
        reason: 'Hovering source text must preserve the dragged position',
      );
      // Move over the toolbar: the reading window must remain the hit target.
      await tester.drag(
        find.byKey(const ValueKey('translation-reading-drag-handle')),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      final popup = tester.getRect(panelFinder);
      final toolbar = tester.getRect(find.byType(GlassPanel).last);
      final overlap = popup.intersect(toolbar);
      expect(overlap.isEmpty, isFalse);
      final hit = tester.hitTestOnBinding(overlap.center);
      final panelRender = tester.renderObject(panelFinder);
      expect(
        hit.path.any((entry) => identical(entry.target, panelRender)),
        isTrue,
        reason: 'The popup paints and receives input above the editing toolbar',
      );
      tester.view.physicalSize = const Size(900, 650);
      await tester.pumpAndSettle();
      final resizedPanel = tester.getRect(panelFinder);
      await tester.drag(
        find.byKey(const ValueKey('translation-reading-drag-handle')),
        const Offset(-20, -20),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(panelFinder).topLeft,
        resizedPanel.topLeft - const Offset(20, 20),
        reason: 'Dragging after a display resize starts from the visible, clamped position',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TranslationReadingPanel), findsNothing);
      expect(requests, 1);
      expect(bridge.recognized, 1);
      final marks = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<SelectionPainter>()
          .first
          .marks;
      expect(marks.map((m) => m.text), ['第一段译文', '第二段译文']);
      await tester.tap(find.byTooltip('对照阅读'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(bridge.copied, isNotNull);
      await tester.runAsync(() async {
        Future<Uint8List> decode(Uint8List data) async {
          final codec = await ui.instantiateImageCodec(data);
          final image = (await codec.getNextFrame()).image;
          codec.dispose();
          final raw = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return raw!.buffer.asUint8List();
        }

        expect(
          listEquals(await decode(bridge.copied!), await decode(clip.bytes)),
          isTrue,
          reason: 'Hidden translations, reading window and source highlights must not appear in exported pixels',
        );
      });

      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    },
  );
  testWidgets(
    'Small selected crop automatically opens a draggable reading window',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = TranslationService(
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode(['第一段', '第二段']),
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
        final image = await sample(width: 1000, height: 700);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        clip = Clip(
          bytes: data!.buffer.asUint8List(),
          width: 1000,
          height: 700,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(clip: clip, controller: controller),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(50, 100), const Offset(240, 120));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻译选区文字'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TranslationReadingPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('translation-reading-drag-handle')),
        findsOneWidget,
      );
      List<Mark> visibleMarks() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SelectionPainter>()
          .first
          .marks;
      expect(visibleMarks(), isEmpty);
      await tester.tap(find.byTooltip('关闭对照阅读'));
      await tester.pumpAndSettle();
      expect(visibleMarks(), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}
