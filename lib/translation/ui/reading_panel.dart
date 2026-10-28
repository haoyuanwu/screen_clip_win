import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

import '../../src/ui/controls.dart';
import '../../src/ui/capture_mirrors.dart' show scheduleCaptureFrame;

/// Source coordinates remain tied to the OCR crop even if a translated
/// annotation is moved or edited later.
class TranslationPassage {
  const TranslationPassage({
    required this.id,
    required this.source,
    required this.translation,
    required this.box,
  });
  final int id;
  final String source, translation;
  final Rect box;
}

const translationMatchBackground = Color(0xffffedc7);
const translationMatchForeground = Color(0xff302719);

bool prefersTranslationReading(
  Size logicalSelection, {
  Iterable<double> textSizes = const [],
}) =>
    logicalSelection.width < 300 ||
    logicalSelection.height < 160 ||
    textSizes.any((size) => size < 12);

Rect clampTranslationReadingRect(Rect rect, Rect screen) {
  final safe = screen.deflate(8);
  final width = math.min(rect.width, safe.width),
      height = math.min(rect.height, safe.height);
  return Rect.fromLTWH(
    rect.left.clamp(safe.left, safe.right - width),
    rect.top.clamp(safe.top, safe.bottom - height),
    width,
    height,
  );
}

Rect translationReadingRect(Rect selection, Rect screen, {Rect? toolbar}) {
  final safe = screen.deflate(8);
  final width = math.min(360.0, safe.width);
  final height = math.min(380.0, safe.height);
  Rect fit(double x, double y, double w) => Rect.fromLTWH(
    x.clamp(safe.left, math.max(safe.left, safe.right - w)),
    y.clamp(safe.top, math.max(safe.top, safe.bottom - height)),
    w,
    height,
  );
  const gap = 8.0;
  final right = safe.right - selection.right - gap;
  final left = selection.left - safe.left - gap;
  final candidates = <Rect>[];
  for (final y in [
    selection.top,
    selection.center.dy - height / 2,
    selection.bottom - height,
    if (toolbar != null) ...[toolbar.bottom + gap, toolbar.top - height - gap],
  ]) {
    if (right >= 240) {
      candidates.add(fit(selection.right + gap, y, math.min(width, right)));
    }
    if (left >= 240) {
      final w = math.min(width, left);
      candidates.add(fit(selection.left - gap - w, y, w));
    }
  }
  candidates.addAll([
    fit(selection.right + gap, selection.top, width),
    fit(selection.left - width - gap, selection.top, width),
    fit(selection.left, selection.bottom + gap, width),
    fit(selection.right - width, selection.bottom + gap, width),
    fit(selection.left, selection.top - height - gap, width),
    fit(selection.right - width, selection.top - height - gap, width),
  ]);
  double area(Rect a, Rect b) {
    final r = a.intersect(b);
    return r.isEmpty ? 0 : r.width * r.height;
  }

  double score(Rect r) {
    final dx = math.max(
      0.0,
      math.max(selection.left - r.right, r.left - selection.right),
    );
    final dy = math.max(
      0.0,
      math.max(selection.top - r.bottom, r.top - selection.bottom),
    );
    return area(r, selection) +
        (toolbar == null ? 0 : area(r, toolbar) * 4) +
        math.sqrt(dx * dx + dy * dy) * 100;
  }

  return candidates.reduce((a, b) => score(b) < score(a) ? b : a);
}

class TranslationReadingPanel extends StatefulWidget {
  const TranslationReadingPanel({
    super.key,
    required this.passages,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    this.onDragStart,
    this.onDragUpdate,
  });
  final List<TranslationPassage> passages;
  final int? activeId;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragUpdate;
  @override
  State<TranslationReadingPanel> createState() =>
      _TranslationReadingPanelState();
}

class _TranslationReadingPanelState extends State<TranslationReadingPanel> {
  final anchors = <int, GlobalKey>{};
  String? copied;
  @override
  void initState() {
    super.initState();
    reveal();
  }

  @override
  void didUpdateWidget(TranslationReadingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeId != widget.activeId) reveal();
  }

  void reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final context = anchors[widget.activeId]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: .25,
        duration:
            MediaQuery.disableAnimationsOf(context) ||
                !WidgetsBinding.instance.framesEnabled
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
      scheduleCaptureFrame();
    }
  });
  void step(int delta) {
    final current = widget.passages.indexWhere((p) => p.id == widget.activeId);
    final index = (math.max(0, current) + delta).clamp(
      0,
      widget.passages.length - 1,
    );
    widget.onSelect(widget.passages[index].id);
  }

  Future<void> copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: widget.passages.map((p) => p.translation).join('\n\n'),
        ),
      );
      if (mounted) setState(() => copied = '已复制');
    } catch (_) {
      if (mounted) setState(() => copied = '复制失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => step(-1),
      },
      child: Focus(
        child: Material(
          color: cs.surface,
          elevation: 8,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: MouseRegion(
                        cursor: widget.onDragUpdate == null
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.grab,
                        child: Tooltip(
                          message: '拖动标题移动译文窗口',
                          child: GestureDetector(
                            key: const ValueKey(
                              'translation-reading-drag-handle',
                            ),
                            dragStartBehavior: DragStartBehavior.down,
                            behavior: HitTestBehavior.opaque,
                            onPanStart: widget.onDragUpdate == null
                                ? null
                                : (_) => widget.onDragStart?.call(),
                            onPanUpdate: widget.onDragUpdate == null
                                ? null
                                : (event) => widget.onDragUpdate!(event.delta),
                            child: SizedBox(
                              height: 32,
                              child: Row(
                                children: [
                                  const Icon(
                                    CupertinoIcons.text_alignleft,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      '译文对照',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ToolButton(
                      label: '复制全部译文',
                      onPressed: copy,
                      child: Text(
                        copied ?? '复制',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    ToolButton(
                      label: '关闭对照阅读',
                      icon: CupertinoIcons.xmark,
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '拖动标题移动 · 指向原文定位 · ${widget.passages.length} 段',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    ToolButton(
                      label: '上一段译文',
                      icon: CupertinoIcons.chevron_up,
                      onPressed: () => step(-1),
                    ),
                    ToolButton(
                      label: '下一段译文',
                      icon: CupertinoIcons.chevron_down,
                      onPressed: () => step(1),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: cs.outlineVariant),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, passage) in widget.passages.indexed)
                        Padding(
                          key: anchors.putIfAbsent(passage.id, GlobalKey.new),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: MouseRegion(
                            child: GestureDetector(
                              onTap: () => widget.onSelect(passage.id),
                              child: Semantics(
                                selected: passage.id == widget.activeId,
                                label: '第 ${index + 1} 段译文',
                                child: AnimatedContainer(
                                  key: ValueKey(
                                    'translation-passage-${passage.id}',
                                  ),
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 140),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: passage.id == widget.activeId
                                        ? translationMatchBackground
                                        : cs.surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${index + 1}${passage.id == widget.activeId ? ' · 正在对照' : ''}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: passage.id == widget.activeId
                                              ? translationMatchForeground
                                              : cs.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SelectableText(
                                        passage.translation,
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.6,
                                          color: passage.id == widget.activeId
                                              ? translationMatchForeground
                                              : cs.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TranslationSourceHighlight extends CustomPainter {
  TranslationSourceHighlight(this.passages, this.activeId, this.crop);
  final List<TranslationPassage> passages;
  final int? activeId;
  final Rect crop;
  @override
  void paint(Canvas canvas, Size size) {
    for (final passage in passages) {
      final box = passage.box;
      final rect = Rect.fromLTWH(
        (box.left - crop.left) / crop.width * size.width,
        (box.top - crop.top) / crop.height * size.height,
        box.width / crop.width * size.width,
        box.height / crop.height * size.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(2), const Radius.circular(3)),
        Paint()
          ..color = translationMatchBackground.withValues(
            alpha: passage.id == activeId ? .42 : .08,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(TranslationSourceHighlight old) =>
      old.activeId != activeId || old.passages != passages || old.crop != crop;
}
