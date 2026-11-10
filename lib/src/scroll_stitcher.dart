import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

int? _register((Uint8List, Uint8List, int, int, bool) request) =>
    ScrollStitcher.displacement(
      request.$1,
      request.$2,
      request.$3,
      request.$4,
      horizontal: request.$5,
    );

int? _recover(
  (List<(int, Uint8List)>, Uint8List, int, int, bool, int, int) request,
) {
  final length = request.$5 ? request.$3 : request.$4;
  final tolerance = (length * ScrollStitcher.recoveryFraction).round();
  for (final anchor in request.$1.reversed) {
    final delta = ScrollStitcher.displacement(
      anchor.$2,
      request.$2,
      request.$3,
      request.$4,
      horizontal: request.$5,
    );
    if (delta == null) continue;
    final position = anchor.$1 + delta;
    // Resume inside the collected interval (or a small overlap margin).
    if (position >= request.$6 - tolerance &&
        position + length <= request.$7 + tolerance) {
      return position;
    }
  }
  return null;
}

/// Registers consecutive viewports in document coordinates. Reversing direction
/// moves the viewport inside the existing image rather than appending duplicates.
class ScrollStitcher {
  ScrollStitcher({this.horizontal = false});
  final bool horizontal;
  // Warn above 1.8 viewports/second; speed alone does not pause capture.
  static const maxViewportRate = 1.8;

  /// Same center reference used by the in-frame pause marker. A reliable match
  /// can correct a fast step while this point is still visible in the viewport.
  static bool referenceVisible(int delta, int length) =>
      length > 0 && delta.abs() <= length / 2;
  final Stopwatch _clock = Stopwatch()..start();
  Duration? _acceptedAt;
  bool paused = false;
  int? pausedPosition, observedPosition;
  double? get pauseMarkerFraction {
    final length = horizontal ? width : height;
    if (!paused ||
        length == 0 ||
        observedPosition == null ||
        pausedPosition == null) {
      return null;
    }
    return .5 + (pausedPosition! - observedPosition!) / length;
  }

  double rateLevel = 0;
  static const recoveryFraction = .12;
  final List<(int, Uint8List)> _anchors = [];
  void remember(Uint8List pixels, int length) {
    if (_anchors.any(
      (a) => (a.$1 - position).abs() < math.max(1, (length * .15).round()),
    )) {
      return;
    }
    _anchors.add((position, pixels));
    // Keep the starting viewport plus recent checkpoints within a bounded budget.
    if (_anchors.length > 48) _anchors.removeAt(1);
  }

  static const pausedMessage = '滚动过快，已暂停。请滚回已采集区域，进入恢复范围后自动继续';

  void pause() {
    if (!paused) pausedPosition = position;
    paused = true;
    rateLevel = 1;
    status = pausedMessage;
  }

  Uint8List? _previous;
  int width = 0, height = 0, position = 0, start = 0, end = 0;
  ui.Image? image, preview;
  int _previewTravel = 0;
  bool _previewDirty = false, _disposed = false;
  int _previewRequest = 0;

  /// Capture continues at full cadence; only publish a thumbnail after one
  /// viewport of travel, or when the UI's 300ms idle debounce expires.
  Future<void> refreshPreview({bool force = false}) async {
    final source = image;
    final length = horizontal ? width : height;
    if (_disposed ||
        source == null ||
        !_previewDirty ||
        (!force && preview != null && _previewTravel < length)) {
      return;
    }
    final request = ++_previewRequest;
    final snapshot = source.clone();
    final scale = math.min(
      1.0,
      math.min(480 / snapshot.width, 960 / snapshot.height),
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(scale);
    canvas.drawImage(snapshot, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    try {
      final next = await picture.toImage(
        math.max(1, (snapshot.width * scale).round()),
        math.max(1, (snapshot.height * scale).round()),
      );
      if (_disposed || request != _previewRequest) {
        next.dispose();
        return;
      }
      preview?.dispose();
      preview = next;
      // A concurrent capture may already contain newer pixels; keep it dirty.
      if (identical(image, source)) {
        _previewDirty = false;
        _previewTravel = 0;
      }
    } finally {
      picture.dispose();
      snapshot.dispose();
    }
  }

  String status = '在选区内缓慢滚动，支持反向滚动';

  static int? displacement(
    Uint8List a,
    Uint8List b,
    int w,
    int h, {
    bool horizontal = false,
  }) {
    final length = horizontal ? w : h;
    final cross = horizontal ? h : w;
    if (length < 32 || cross < 16) return null;
    final margin = math.max(3, (length * .12).round());
    final limit = (length * .70).floor();
    double score(int shift, {bool bounded = true}) {
      final lo = math.max(margin, margin - shift);
      final hi = math.min(length - margin, length - margin - shift);
      if (hi - lo < length * .16) return double.infinity;
      var error = 0.0, count = 0;
      final step = math.max(1, ((hi - lo) / 36).floor());
      final crossStart = (cross * .08).round();
      final crossEnd = (cross * .92).ceil();
      final crossStep = math.max(1, (cross / 28).floor());
      final samples =
          ((hi - lo + step - 1) ~/ step) *
          ((crossEnd - crossStart + crossStep - 1) ~/ crossStep) *
          3;
      // Once even perfect remaining samples cannot pass the acceptance or
      // ambiguity thresholds, stop evaluating this unrelated displacement.
      final errorBudget = samples * 15;
      for (var p = lo; p < hi; p += step) {
        for (
          var c = (cross * .08).round();
          c < cross * .92;
          c += math.max(1, (cross / 28).floor())
        ) {
          final x = horizontal ? p : c, y = horizontal ? c : p;
          final xx = horizontal ? p + shift : c;
          final yy = horizontal ? c : p + shift;
          final i = (yy * w + xx) * 4, j = (y * w + x) * 4;
          for (var k = 0; k < 3; k++) {
            error += (a[i + k] - b[j + k]).abs();
          }
          count += 3;
        }
        if (bounded && error > errorBudget) return double.infinity;
      }
      return error / count;
    }

    final still = score(0, bounded: false);
    if (still < 1.0) return 0;
    // Pixel registration runs in an isolate, keeping the live preview responsive.
    // Wheel deltas cannot establish distance with acceleration or browser zoom.
    var best = double.infinity, offset = 0;
    final scores = <int, double>{};
    for (var d = -limit; d <= limit; d++) {
      final s = score(d);
      scores[d] = s;
      if (s < best) {
        best = s;
        offset = d;
      }
    }
    if (best > 13 || best > still * .65) return null;
    // Repetitive surfaces cannot establish an unambiguous document position.
    for (final entry in scores.entries) {
      if ((entry.key - offset).abs() > 6 && entry.value <= best + .8) {
        return null;
      }
    }
    return offset;
  }

  Future<bool> add(ui.Image frame, {Duration? capturedAt}) async {
    final now = capturedAt ?? _clock.elapsed;
    if (frame.width * frame.height > 40000000 ||
        frame.width > 30000 ||
        frame.height > 30000) {
      status = '选区过大，请缩小范围后重新开始';
      return false;
    }
    final data = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return false;
    final raw = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    // Preserve every pixel along the scrolling axis, but send only 24 stripes
    // across it to the worker. A Retina viewport no longer crosses isolates in full.
    const stripes = 24;
    final matchWidth = horizontal ? frame.width : stripes;
    final matchHeight = horizontal ? stripes : frame.height;
    final pixels = Uint8List(matchWidth * matchHeight * 4);
    for (var y = 0; y < matchHeight; y++) {
      for (var x = 0; x < matchWidth; x++) {
        final sx = horizontal ? x : x * frame.width ~/ stripes;
        final sy = horizontal ? y * frame.height ~/ stripes : y;
        final source = (sy * frame.width + sx) * 4;
        final dest = (y * matchWidth + x) * 4;
        pixels.setRange(dest, dest + 4, raw, source);
      }
    }
    final length = horizontal ? frame.width : frame.height;
    var nextPosition = position;
    if (_previous == null) {
      width = frame.width;
      height = frame.height;
      start = position = 0;
      end = length;
      _acceptedAt = now;
    } else {
      if (frame.width != width || frame.height != height) {
        status = '屏幕尺寸已变化，请重新开始';
        return false;
      }
      int delta;
      if (paused) {
        final recovered = await compute(_recover, (
          _anchors,
          pixels,
          matchWidth,
          matchHeight,
          horizontal,
          start,
          end,
        ));
        if (recovered == null) {
          final distance = await compute(_register, (
            _previous!,
            pixels,
            matchWidth,
            matchHeight,
            horizontal,
          ));
          if (distance != null) {
            final candidate = position + distance;
            observedPosition = candidate;
            final tolerance = (length * recoveryFraction).round();
            final below = candidate + length > end + tolerance;
            final remaining = below
                ? candidate + length - end - tolerance
                : start - tolerance - candidate;
            final direction = horizontal
                ? (below ? '左' : '右')
                : (below ? '上' : '下');
            status = '已暂停，请向$direction滚动约${math.max(0, remaining)}像素，回到已采集区域';
          } else {
            observedPosition = null;
            status = pausedMessage;
          }
          return false;
        }
        delta = recovered - position;
        paused = false;
        rateLevel = 0;
      } else {
        final registered = await compute(_register, (
          _previous!,
          pixels,
          matchWidth,
          matchHeight,
          horizontal,
        ));
        if (registered == null) {
          observedPosition = null;
          pause();
          status = '未找到可靠重叠，已暂停。请滚回已采集区域以恢复对齐';
          return false;
        }
        delta = registered;
        observedPosition = position + delta;
        final elapsed = now - (_acceptedAt ?? now);
        final fraction = delta.abs() / length;
        final seconds = math.max(.001, elapsed.inMicroseconds / 1000000);
        rateLevel = (fraction / seconds / maxViewportRate).clamp(0, 1);
        if (!referenceVisible(delta, length)) {
          pause();
          return false;
        }
        // Speed controls the warning meter, not acceptance. Registration has
        // already measured the actual shift, so keep correcting visible content.
      }
      _acceptedAt = now;
      nextPosition += delta;
      status = rateLevel >= 1 ? '滚动较快，正在修正对齐，可适当减速' : '在选区内缓慢滚动，支持反向滚动';
      if (nextPosition >= start && nextPosition + length <= end) {
        _previewTravel += (nextPosition - position).abs();
        position = nextPosition;
        _previous = pixels;
        await refreshPreview();
        remember(pixels, length);
        return false;
      }
    }
    final nextStart = math.min(start, nextPosition);
    final nextEnd = math.max(end, nextPosition + length);
    final outW = horizontal ? nextEnd - nextStart : width;
    final outH = horizontal ? height : nextEnd - nextStart;
    if (outW * outH > 40000000 || outW > 30000 || outH > 30000) {
      status = '已达到长截图尺寸上限，请保存';
      return false;
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint();
    // Paint the new viewport first, preserving previously collected content.
    canvas.drawImage(
      frame,
      horizontal
          ? ui.Offset((nextPosition - nextStart).toDouble(), 0)
          : ui.Offset(0, (nextPosition - nextStart).toDouble()),
      paint,
    );
    if (image != null) {
      canvas.drawImage(
        image!,
        horizontal
            ? ui.Offset((start - nextStart).toDouble(), 0)
            : ui.Offset(0, (start - nextStart).toDouble()),
        paint,
      );
    }
    final picture = recorder.endRecording();
    final ui.Image next;
    try {
      next = await picture.toImage(outW, outH);
    } catch (_) {
      picture.dispose();
      rethrow;
    }
    picture.dispose();
    image?.dispose();
    image = next;
    _previewTravel += (nextPosition - position).abs();
    _previewDirty = true;
    _previous = pixels;
    position = nextPosition;
    start = nextStart;
    end = nextEnd;
    remember(pixels, length);
    await refreshPreview();
    return true;
  }

  void dispose() {
    _disposed = true;
    _previewRequest++;
    image?.dispose();
    image = null;
    preview?.dispose();
    preview = null;
    _previous = null;
    _anchors.clear();
  }
}
