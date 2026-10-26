import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';

import 'widget_test.dart' show FakeBridge, sample;

void main() {
  testWidgets(
    'Text grows without internal scrolling, wraps and expands upward at the bottom edge',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ClipController(bridge: FakeBridge('unused'))..ready = true;
      addTearDown(c.dispose);
      late Clip clip;
      await tester.runAsync(() async {
        final im = await sample(width: 800, height: 600);
        clip = Clip(
          bytes: (await im.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
          width: 800,
          height: 600,
          mode: 'screen',
        );
        im.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CaptureEditor(clip: clip, controller: c),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文字 · T'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(100, 120));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('inline-annotation-text'));
      ScrollPosition scroll() => tester
          .state<ScrollableState>(
            find.descendant(of: input, matching: find.byType(Scrollable)).first,
          )
          .position;
      await tester.enterText(input, 'Hi');
      await tester.pumpAndSettle();
      final shortWidth = tester.getSize(input).width;
      await tester.enterText(input, 'abcdefghij');
      await tester.pumpAndSettle();
      expect(tester.getSize(input).width, greaterThan(shortWidth));
      expect(scroll().pixels, 0);
      expect(scroll().maxScrollExtent, lessThanOrEqualTo(.1));
      final oneLineHeight = tester.getSize(input).height;
      await tester.enterText(input, List.filled(18, 'word').join(' '));
      await tester.pumpAndSettle();
      expect(tester.getSize(input).height, greaterThan(oneLineHeight));
      expect(tester.getRect(input).right, lessThanOrEqualTo(800));
      expect(scroll().pixels, 0);
      expect(scroll().maxScrollExtent, lessThanOrEqualTo(.1));
      await tester.tap(find.byTooltip('完成文字'));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(CaptureEditor));
      state.addText(const Offset(100, 500), createNew: true);
      await tester.pumpAndSettle();
      await tester.enterText(input, 'one\ntwo\nthree\nfour');
      await tester.pumpAndSettle();
      expect(scroll().pixels, 0);
      expect(scroll().maxScrollExtent, lessThanOrEqualTo(.1));
      final rect = tester.getRect(input);
      expect(rect.top, lessThan(500));
      expect(rect.bottom, lessThanOrEqualTo(600));
      await tester.tap(find.byTooltip('完成文字'));
      await tester.pumpAndSettle();
      final mark = (state.marks as List<Mark>).last;
      expect(
        mark.points.first.dy + mark.textBoxSize.height,
        lessThanOrEqualTo(600),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
