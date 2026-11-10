import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../scroll_stitcher.dart';
import 'controls.dart';

class ScrollCapture extends StatefulWidget {
  const ScrollCapture({
    super.key,
    required this.controller,
    required this.onCancel,
  });
  final ClipController controller;
  final Future<void> Function() onCancel;
  @override
  State<ScrollCapture> createState() => _ScrollCaptureState();
}

class _ScrollCaptureState extends State<ScrollCapture> {
  ScrollStitcher stitcher = ScrollStitcher();
  bool stopped = false, saving = false;
  int epoch = 0;
  Future<void>? runner, finalization;
  String? error;
  Timer? previewIdle;
  void scheduleIdlePreview(ScrollStitcher target, int request) {
    previewIdle?.cancel();
    previewIdle = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted || request != epoch) return;
      await target.refreshPreview(force: true);
      if (mounted && request == epoch) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    runner = collect();
  }

  Future<void> collect() async {
    while (mounted && !stopped) {
      final cycle = Stopwatch()..start();
      final request = epoch;
      final target = stitcher;
      ui.Image? frame;
      try {
        final bytes = await widget.controller.bridge.scrollCaptureFrame();
        if (!mounted) return;
        final codec = await ui.instantiateImageCodec(bytes);
        frame = (await codec.getNextFrame()).image;
        codec.dispose();
        if (request == epoch) {
          final previousPosition = target.position;
          await target.add(frame);
          if (target.position != previousPosition) {
            scheduleIdlePreview(target, request);
          }
          if (mounted && request == epoch) {
            await widget.controller.bridge.updateScrollCaptureMarker(
              paused: target.paused,
              horizontal: target.horizontal,
              fraction: target.pauseMarkerFraction,
            );
          }
          if (mounted && request == epoch) setState(() => error = null);
        }
      } catch (e) {
        if (mounted) setState(() => error = '采集失败：$e');
      } finally {
        frame?.dispose();
      }
      // Target start-to-start cadence rather than adding latency after processing.
      final period = stitcher.paused ? 280 : 200;
      final delay = (period - cycle.elapsedMilliseconds).clamp(40, period);
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
  }

  Future<void> direction(bool horizontal) async {
    if (saving || horizontal == stitcher.horizontal) return;
    setState(() {
      saving = true;
      stopped = true;
    });
    epoch++;
    previewIdle?.cancel();
    await runner;
    if (!mounted) return;
    await widget.controller.bridge.updateScrollCaptureMarker(
      paused: false,
      horizontal: horizontal,
    );
    if (!mounted) return;
    stitcher.dispose();
    setState(() {
      stitcher = ScrollStitcher(horizontal: horizontal);
      error = null;
      saving = false;
      stopped = false;
    });
    runner = collect();
  }

  Future<void> finish(bool save) {
    if (saving || stitcher.image == null) return Future<void>.value();
    return finalization = finishCapture(save);
  }

  Future<void> finishCapture(bool save) async {
    setState(() {
      saving = true;
      stopped = true;
    });
    await runner;
    if (!mounted) return;
    try {
      // A failed final read must not prevent saving already collected pixels.
      try {
        final finalBytes = await widget.controller.bridge.scrollCaptureFrame();
        if (!mounted) return;
        final codec = await ui.instantiateImageCodec(finalBytes);
        final frame = (await codec.getNextFrame()).image;
        codec.dispose();
        try {
          if (mounted) await stitcher.add(frame);
        } finally {
          frame.dispose();
        }
      } catch (_) {}
      if (!mounted) return;
      final bytes = await stitcher.image!.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null) throw StateError('图片编码失败');
      await widget.controller.finish(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        save: save,
        presentOnError: false,
      );
      if (mounted && widget.controller.error != null) {
        setState(() => error = widget.controller.error);
      }
    } catch (e) {
      if (mounted) setState(() => error = '保存失败：$e');
    }
    if (mounted) {
      setState(() {
        saving = false;
        stopped = false;
      });
      runner = collect();
    }
  }

  Future<void> cancel() async {
    if (saving) return;
    setState(() {
      saving = true;
      stopped = true;
    });
    await runner;
    if (!mounted) return;
    try {
      await widget.onCancel();
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          stopped = false;
          error = '退出失败：$e';
        });
        runner = collect();
      }
    }
  }

  @override
  void dispose() {
    previewIdle?.cancel();
    stopped = true;
    epoch++;
    final old = stitcher;
    unawaited(Future.wait([?runner, ?finalization]).whenComplete(old.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (!saving) cancel();
      },
      const SingleActivator(LogicalKeyboardKey.enter): () => finish(false),
    },
    child: Focus(
      autofocus: true,
      child: GlassPanel(
        tintOpacity: 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ToolButton(
                  label: '长截图',
                  icon: CupertinoIcons.rectangle_expand_vertical,
                  selected: true,
                ),
                const SizedBox(width: 6),
                const Expanded(child: Text('长截图')),
                ToolButton(
                  label: '取消长截图',
                  icon: CupertinoIcons.xmark,
                  onPressed: saving ? null : cancel,
                ),
              ],
            ),
            ToolbarInspectorSurface(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final horizontal in [false, true])
                    Expanded(
                      child: TextButton.icon(
                        onPressed: saving ? null : () => direction(horizontal),
                        style: TextButton.styleFrom(
                          foregroundColor: stitcher.horizontal == horizontal
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : Theme.of(context).colorScheme.onSurface,
                          backgroundColor: stitcher.horizontal == horizontal
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Colors.transparent,
                        ),
                        icon: Icon(
                          horizontal
                              ? CupertinoIcons.arrow_left_right
                              : CupertinoIcons.arrow_up_down,
                          size: 16,
                        ),
                        label: Text(horizontal ? '横向' : '纵向'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error ?? stitcher.status,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ClipRect(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: stitcher.image == null
                      ? const Center(child: CircularProgressIndicator())
                      : SmoothScrollPreview(
                          image: stitcher.preview ?? stitcher.image!,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ScrollRateIndicator(
              level: stitcher.rateLevel,
              paused: stitcher.paused,
            ),
            const SizedBox(height: 8),
            Text(
              stitcher.image == null
                  ? '准备采集…'
                  : '${stitcher.image!.width} × ${stitcher.image!.height}',
              textAlign: TextAlign.center,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ToolButton(
                  label: '保存长截图',
                  icon: CupertinoIcons.square_arrow_down,
                  onPressed: saving || stitcher.image == null
                      ? null
                      : () => finish(true),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: saving || stitcher.image == null
                      ? null
                      : () => finish(false),
                  child: Text(saving ? '处理中…' : '完成并复制'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// The text and icon communicate danger independently of the meter's color.
class ScrollRateIndicator extends StatelessWidget {
  const ScrollRateIndicator({
    super.key,
    required this.level,
    required this.paused,
  });
  final double level;
  final bool paused;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final warning = paused || level >= .7;
    final color = warning ? cs.error : cs.primary;
    final label = paused
        ? '滚动过快 · 已暂停'
        : (level >= 1 ? '滚动较快 · 正在修正' : (warning ? '滚动较快 · 请减速' : '滚动速率 · 安全'));
    return Semantics(
      liveRegion: paused,
      label: label,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: warning ? cs.errorContainer : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: warning ? cs.error : cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  warning
                      ? Icons.warning_amber_rounded
                      : CupertinoIcons.speedometer,
                  size: 18,
                  color: warning ? cs.onErrorContainer : cs.onSurface,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '滚动速率',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: warning ? cs.onErrorContainer : cs.onSurface,
                    ),
                  ),
                ),
                Text(
                  paused
                      ? '已暂停'
                      : (level >= 1 ? '修正中' : (warning ? '请减速' : '安全')),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: warning ? cs.onErrorContainer : cs.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: paused ? 1 : level.clamp(0, 1)),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  minHeight: 10,
                  value: value,
                  color: color,
                  backgroundColor: warning
                      ? cs.surface
                      : cs.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              paused ? '回到已采集区域后自动继续' : '过快先修正 · 位置移出取景框才暂停',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: warning ? cs.onErrorContainer : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SmoothScrollPreview extends StatelessWidget {
  const SmoothScrollPreview({super.key, required this.image});
  final ui.Image image;
  @override
  Widget build(BuildContext context) {
    final aspect = image.width / image.height;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) => TweenAnimationBuilder<double>(
          tween: Tween(begin: aspect, end: aspect),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          builder: (context, ratio, _) {
            final width = (constraints.maxHeight * ratio).clamp(
              0.0,
              constraints.maxWidth,
            );
            return Center(
              child: RawImage(
                image: image,
                width: width,
                height: width / ratio,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
              ),
            );
          },
        ),
      ),
    );
  }
}
