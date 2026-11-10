import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/scroll_stitcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const w = 90, h = 120;
  final random = Random(8);
  final document = Uint8List.fromList(
    List.generate(400 * 400 * 4, (i) => i % 4 == 3 ? 255 : random.nextInt(256)),
  );
  Uint8List viewport(int x, int y) {
    final out = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      out.setRange(
        row * w * 4,
        (row + 1) * w * 4,
        document,
        ((y + row) * 400 + x) * 4,
      );
    }
    return out;
  }

  Future<ui.Image> image(int x, int y) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(viewport(x, y));
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = (await codec.getNextFrame()).image;
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame;
  }

  test('registers vertical and horizontal scrolling in both directions', () {
    final a = viewport(40, 80);
    expect(ScrollStitcher.displacement(a, viewport(40, 113), w, h), 33);
    expect(ScrollStitcher.displacement(a, viewport(40, 47), w, h), -33);
    expect(
      ScrollStitcher.displacement(a, viewport(67, 80), w, h, horizontal: true),
      27,
    );
    expect(
      ScrollStitcher.displacement(a, viewport(13, 80), w, h, horizontal: true),
      -27,
    );
    expect(ScrollStitcher.displacement(a, a, w, h), 0);
    expect(ScrollStitcher.displacement(a, viewport(200, 200), w, h), isNull);
  });
  test(
    'reverse scrolling extends only unseen content above and below',
    () async {
      final s = ScrollStitcher();
      var tick = 0;
      for (final y in [80, 113, 80, 47, 80, 113]) {
        final f = await image(40, y);
        await s.add(f, capturedAt: Duration(seconds: ++tick));
        f.dispose();
      }
      expect(s.image!.width, w);
      expect(s.image!.height, h + 66);
      expect(s.position, 33);
      expect(s.start, -33);
      final data = (await s.image!.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final actual = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      for (var row = 0; row < h + 66; row++) {
        final source = ((47 + row) * 400 + 40) * 4;
        expect(
          actual.sublist(row * w * 4, (row + 1) * w * 4),
          document.sublist(source, source + w * 4),
        );
      }
      s.dispose();
    },
  );
  test(
    'horizontal reverse scrolling deduplicates and reset starts empty',
    () async {
      final s = ScrollStitcher(horizontal: true);
      var tick = 0;
      for (final x in [80, 107, 80, 53, 80]) {
        final f = await image(x, 40);
        await s.add(f, capturedAt: Duration(seconds: ++tick));
        f.dispose();
      }
      expect(s.image!.width, w + 54);
      expect(s.image!.height, h);
      s.dispose();
      final reset = ScrollStitcher();
      expect(reset.image, isNull);
      expect(reset.position, 0);
      final f = await image(80, 40);
      await reset.add(f);
      f.dispose();
      expect(reset.image!.width, w);
      expect(reset.image!.height, h);
      reset.dispose();
    },
  );
  test(
    'out-of-frame reference pauses until a collected viewport is recovered',
    () async {
      final s = ScrollStitcher();
      Future<void> feed(int y, int ms) async {
        final f = await image(40, y);
        await s.add(f, capturedAt: Duration(milliseconds: ms));
        f.dispose();
      }

      await feed(80, 0);
      await feed(90, 1000);
      final accepted = s.image;
      await feed(160, 1100);
      expect(s.paused, isTrue);
      expect(s.image, same(accepted));
      expect(s.position, 10);
      expect(s.pausedPosition, 10);
      expect(s.pauseMarkerFraction, closeTo(.5 - 70 / h, .001));
      await feed(
        160,
        3000,
      ); // Slowing down away from the anchor is insufficient.
      expect(s.paused, isTrue);
      expect(s.image, same(accepted));
      await feed(90, 4000);
      expect(s.paused, isFalse);
      expect(s.pauseMarkerFraction, isNull);
      await feed(90, 4300);
      expect(s.paused, isFalse);
      await feed(110, 5300);
      expect(s.position, 30);
      expect(s.image!.height, h + 30);
      s.dispose();
    },
  );
  test(
    'missing overlap pauses and does not poison the registration anchor',
    () async {
      final s = ScrollStitcher(horizontal: true);
      for (final (x, ms) in [(40, 0), (200, 500), (40, 1000), (40, 1300)]) {
        final f = await image(x, 40);
        await s.add(f, capturedAt: Duration(milliseconds: ms));
        f.dispose();
        if (x == 200) {
          expect(s.paused, isTrue);
          expect(s.position, 0);
        }
      }
      expect(s.paused, isFalse);
      expect(s.image!.width, w);
      s.dispose();
    },
  );
  test(
    'preview texture stays bounded while export keeps full resolution',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final frame = await picture.toImage(1000, 2000);
      picture.dispose();
      final s = ScrollStitcher();
      await s.add(frame);
      frame.dispose();
      expect(s.image!.width, 1000);
      expect(s.image!.height, 2000);
      expect(s.preview!.width, lessThanOrEqualTo(480));
      expect(s.preview!.height, lessThanOrEqualTo(960));
      expect(s.preview!.width / s.preview!.height, closeTo(.5, .01));
      s.dispose();
    },
  );
  test(
    'recovery accepts distance tolerance and the start of a long capture',
    () async {
      for (final horizontal in [false, true]) {
        final s = ScrollStitcher(horizontal: horizontal);
        var tick = 0;
        Future<void> feed(int offset) async {
          final frame = await image(
            horizontal ? 20 + offset : 40,
            horizontal ? 40 : 20 + offset,
          );
          await s.add(frame, capturedAt: Duration(seconds: ++tick));
          frame.dispose();
        }

        for (final offset in [0, 20, 40, 60, 80, 100, 120]) {
          await feed(offset);
        }
        s.pause();
        final existing = s.image;
        await feed(5); // Far from the last viewport, near the start checkpoint.
        expect(s.paused, isFalse);
        expect(s.position, 5);
        expect(s.image, same(existing));
        s.pause();
        await feed(-5); // Small overshoot inside the 12% recovery tolerance.
        expect(s.paused, isFalse);
        expect(s.position, -5);
        s.dispose();
      }
    },
  );
  test(
    'normal wheel steps can advance 30 percent per 200ms without pausing',
    () async {
      for (final horizontal in [false, true]) {
        final s = ScrollStitcher(horizontal: horizontal);
        final step = horizontal ? 27 : 36;
        for (var i = 0; i < 4; i++) {
          final frame = await image(
            horizontal ? 40 + i * step : 40,
            horizontal ? 40 : 40 + i * step,
          );
          await s.add(frame, capturedAt: Duration(milliseconds: i * 200));
          frame.dispose();
          expect(s.paused, isFalse);
          expect(s.position, i * step);
        }
        s.dispose();
      }
    },
  );
  test('preview publishes at viewport distance and flushes partial distance on idle', () async {
    for (final horizontal in [false, true]) {
      final s = ScrollStitcher(horizontal: horizontal);
      final step = horizontal ? 30 : 40;
      Future<void> feed(int index) async {
        final f = await image(
          horizontal ? 40 + index * step : 40,
          horizontal ? 40 : 40 + index * step,
        );
        await s.add(f, capturedAt: Duration(seconds: index));
        f.dispose();
      }

      await feed(0);
      final initial = s.preview;
      await feed(1);
      await feed(2);
      expect(s.preview, same(initial));
      expect(
        horizontal ? s.image!.width : s.image!.height,
        (horizontal ? w : h) + 2 * step,
      );
      await feed(3);
      expect(s.preview, isNot(same(initial)));
      final full = s.preview;
      await feed(4);
      expect(s.preview, same(full));
      await s.refreshPreview(force: true);
      expect(s.preview, isNot(same(full)));
      expect(s.preview!.width, s.image!.width);
      expect(s.preview!.height, s.image!.height);
      s.dispose();
    }
  });
  test(
    'fast steps correct alignment while the reference remains in the frame',
    () async {
      for (final horizontal in [false, true]) {
        for (final sign in [-1, 1]) {
          final s = ScrollStitcher(horizontal: horizontal);
          final step = sign * (horizontal ? 35 : 50);
          final first = await image(100, 100);
          await s.add(first, capturedAt: Duration.zero);
          first.dispose();
          final next = await image(
            horizontal ? 100 + step : 100,
            horizontal ? 100 : 100 + step,
          );
          await s.add(next, capturedAt: const Duration(milliseconds: 50));
          next.dispose();
          expect(s.rateLevel, 1);
          expect(s.paused, isFalse);
          expect(s.position, step);
          expect(
            horizontal ? s.image!.width : s.image!.height,
            (horizontal ? w : h) + step.abs(),
          );
          expect(s.status, contains('修正对齐'));
          s.dispose();
        }
      }
    },
  );
  test('reference visibility includes both viewport edges', () {
    expect(ScrollStitcher.referenceVisible(60, 120), isTrue);
    expect(ScrollStitcher.referenceVisible(-60, 120), isTrue);
    expect(ScrollStitcher.referenceVisible(61, 120), isFalse);
    expect(ScrollStitcher.referenceVisible(-61, 120), isFalse);
  });
}
