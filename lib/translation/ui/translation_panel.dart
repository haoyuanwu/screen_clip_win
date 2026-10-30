import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/ui/controls.dart';
import '../../src/ui/capture_mirrors.dart' show scheduleCaptureFrame;
import '../controller.dart';
import '../models.dart';
import 'argos_settings.dart';
import 'channel_settings.dart';

class TranslationPanel extends StatefulWidget {
  const TranslationPanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.openUrl,
    this.settingsInitially = false,
    this.onConfigured,
  });
  final TranslationController controller;
  final VoidCallback onClose;
  final Future<void> Function(Uri) openUrl;
  final bool settingsInitially;
  final VoidCallback? onConfigured;
  @override
  State<TranslationPanel> createState() => _TranslationPanelState();
}

class _TranslationPanelState extends State<TranslationPanel> {
  late bool settings = widget.settingsInitially;
  final source = TextEditingController();
  final panelFocus = FocusNode();
  String? chooser, copyStatus;
  TranslationResult? copiedResult;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(scheduleCaptureFrame);
    widget.controller.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) panelFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(scheduleCaptureFrame);
    panelFocus.dispose();
    source.dispose();
    super.dispose();
  }

  void close() {
    widget.controller.needsLocalModels = false;
    widget.controller.cancel();
    widget.onClose();
  }

  Widget selectButton(String id, String label) => ToolButton(
    label: label,
    selected: chooser == id,
    onPressed:
        widget.controller.translating ||
            widget.controller.extracting ||
            widget.controller.saving
        ? null
        : () => setState(() => chooser = chooser == id ? null : id),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 5),
        const Icon(CupertinoIcons.chevron_down, size: 11),
      ],
    ),
  );
  Future<void> copy() async {
    final result = widget.controller.result;
    final text = result?.translatedText;
    if (text == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        setState(() {
          copyStatus = '已复制译文';
          copiedResult = result;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          copyStatus = '复制失败，请重试';
          copiedResult = result;
        });
      }
    }
  }

  Widget textSurface({
    required String title,
    required Widget child,
    required ColorScheme colors,
  }) => DecoratedBox(
    decoration: BoxDecoration(
      color: colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: colors.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(child: child),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, colors = Theme.of(context).colorScheme;
      if (source.text != c.sourceText) {
        source.value = TextEditingValue(
          text: c.sourceText,
          selection: TextSelection.collapsed(offset: c.sourceText.length),
        );
      }
      if (c.needsLocalModels && c.activeChannel?.isLocal == true) {
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
          child: Material(
            color: colors.surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Focus(
              autofocus: true,
              focusNode: panelFocus,
              child: ArgosSettings(
                controller: c,
                channel: c.activeChannel!,
                onBack: () {
                  c.needsLocalModels = false;
                  if (widget.onConfigured != null) {
                    widget.onClose();
                  } else {
                    c.changed();
                  }
                },
                onDownloadStarted: () {
                  c.needsLocalModels = false;
                  c.changed();
                },
                onSaved: () {
                  c.needsLocalModels = false;
                  if (widget.onConfigured != null) {
                    widget.onConfigured!();
                  } else {
                    c.changed();
                    c.translate();
                  }
                },
              ),
            ),
          ),
        );
      }
      final ready =
          c.activeChannel?.isEnabled == true &&
          (c.activeChannel?.isLocal == true ||
              c.activeChannel?.configured == true);
      final reduce = MediaQuery.disableAnimationsOf(context);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): close,
          if (!settings)
            const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                c.translate,
          if (!settings)
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                c.translate,
        },
        child: Focus(
          autofocus: true,
          focusNode: panelFocus,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Material(
              color: colors.surface,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        Icon(
                          CupertinoIcons.globe,
                          size: 20,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '翻译',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                settings
                                    ? '本地翻译与在线渠道'
                                    : c.activeChannel?.isLocal == true
                                    ? '本机离线处理 · 不上传文字或图片'
                                    : '文字直达所选渠道 · 不上传图片',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ToolButton(
                          label: settings ? '返回翻译' : '翻译渠道设置',
                          selected: settings,
                          icon: settings
                              ? CupertinoIcons.chevron_left
                              : CupertinoIcons.slider_horizontal_3,
                          onPressed: () {
                            c.cancel();
                            setState(() {
                              settings = !settings;
                              chooser = null;
                            });
                          },
                        ),
                        ToolButton(
                          label: '关闭翻译 · Esc',
                          icon: CupertinoIcons.xmark,
                          onPressed: close,
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: colors.outlineVariant),
                  Expanded(
                    child: settings
                        ? ChannelSettings(
                            controller: c,
                            openUrl: widget.openUrl,
                            onConfigured: widget.onConfigured,
                          )
                        : Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    selectButton('from', c.from.label),
                                    ToolButton(
                                      label: '交换源语言和目标语言',
                                      icon:
                                          CupertinoIcons.arrow_right_arrow_left,
                                      size: 30,
                                      onPressed:
                                          c.from == TranslationLanguage.auto ||
                                              c.translating ||
                                              c.extracting ||
                                              c.saving
                                          ? null
                                          : () async {
                                              final success = await c.languages(
                                                c.to,
                                                c.from,
                                              );
                                              if (mounted &&
                                                  success &&
                                                  c.sourceText
                                                      .trim()
                                                      .isNotEmpty) {
                                                c.translate();
                                              }
                                            },
                                    ),
                                    selectButton('to', c.to.label),
                                    selectButton(
                                      'channel',
                                      c.activeChannel?.name ?? '选择渠道',
                                    ),
                                  ],
                                ),
                                if (chooser != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxHeight: 104,
                                      ),
                                      child: SingleChildScrollView(
                                        child: Wrap(
                                          spacing: 4,
                                          runSpacing: 4,
                                          children: [
                                            if (chooser == 'channel')
                                              for (final channel in c.channels)
                                                TextButton(
                                                  onPressed: !channel.isEnabled
                                                      ? null
                                                      : () async {
                                                          await c.selectChannel(
                                                            channel.id,
                                                          );
                                                          if (mounted) {
                                                            setState(
                                                              () => chooser =
                                                                  null,
                                                            );
                                                          }
                                                        },
                                                  child: Text(
                                                    '${channel.name}${channel.configured ? '' : ' · 未配置'}',
                                                  ),
                                                ),
                                            if (chooser != 'channel')
                                              for (final language
                                                  in TranslationLanguage.values
                                                      .where(
                                                        (v) =>
                                                            chooser == 'from' ||
                                                            v !=
                                                                TranslationLanguage
                                                                    .auto,
                                                      ))
                                                TextButton(
                                                  onPressed: () async {
                                                    final success = await c
                                                        .languages(
                                                          chooser == 'from'
                                                              ? language
                                                              : c.from,
                                                          chooser == 'to'
                                                              ? language
                                                              : c.to,
                                                        );
                                                    if (mounted && success) {
                                                      setState(
                                                        () => chooser = null,
                                                      );
                                                      if (c.sourceText
                                                          .trim()
                                                          .isNotEmpty) {
                                                        c.translate();
                                                      }
                                                    }
                                                  },
                                                  child: Text(language.label),
                                                ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                LocalModelDownloadStatus(controller: c),
                                if (!ready || c.configError != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: colors.primaryContainer
                                            .withValues(alpha: .45),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            CupertinoIcons.lock,
                                            size: 17,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              c.configError ??
                                                  '先准备本地语言包，或配置并启用在线翻译渠道',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                setState(() => settings = true),
                                            child: const Text('去配置'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final input = textSurface(
                                        title: c.sourceLabel,
                                        colors: colors,
                                        child: c.extracting
                                            ? Center(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (!reduce)
                                                      const SizedBox(
                                                        width: 22,
                                                        height: 22,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                            ),
                                                      ),
                                                    const SizedBox(height: 12),
                                                    const Text(
                                                      '正在提取选区文字…',
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              )
                                            : TextField(
                                                key: const ValueKey(
                                                  'translation-source',
                                                ),
                                                controller: source,
                                                expands: true,
                                                maxLines: null,
                                                minLines: null,
                                                maxLength: 12000,
                                                onChanged: (v) {
                                                  copyStatus = null;
                                                  c.setSource(v);
                                                },
                                                decoration:
                                                    const InputDecoration(
                                                      hintText: '输入、粘贴或从截图提取文字',
                                                      border: InputBorder.none,
                                                      enabledBorder:
                                                          InputBorder.none,
                                                      focusedBorder:
                                                          InputBorder.none,
                                                      filled: false,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                    ),
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  height: 1.55,
                                                ),
                                              ),
                                      );
                                      final output = textSurface(
                                        title: '译文 · ${c.to.label}',
                                        colors: colors,
                                        child: c.result != null
                                            ? SingleChildScrollView(
                                                child: SelectableText(
                                                  c.result!.translatedText,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    height: 1.65,
                                                  ),
                                                ),
                                              )
                                            : Center(
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    8,
                                                  ),
                                                  child: Text(
                                                    c.translating
                                                        ? '正在翻译，原文与格式会保留…'
                                                        : '译文将在这里显示',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: colors
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                      );
                                      if (constraints.maxWidth >= 620) {
                                        return Row(
                                          children: [
                                            Expanded(child: input),
                                            const SizedBox(width: 12),
                                            Expanded(child: output),
                                          ],
                                        );
                                      }
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(child: input),
                                          const SizedBox(height: 12),
                                          Expanded(child: output),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  height: 4,
                                  child: c.translating && !reduce
                                      ? LinearProgressIndicator(
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        )
                                      : const SizedBox.expand(),
                                ),
                                const SizedBox(height: 8),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    c.error ??
                                        (c.result != null
                                            ? '${c.result!.channelName} · ${(c.result!.duration.inMilliseconds / 1000).toStringAsFixed(1)}s${c.result!.tokensUsed > 0 ? ' · ${c.result!.tokensUsed} tokens' : ''}'
                                            : c.status),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: c.error == null
                                          ? colors.onSurfaceVariant
                                          : colors.error,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (c.translating || c.extracting)
                                      OutlinedButton(
                                        onPressed: c.cancel,
                                        child: const Text('取消'),
                                      )
                                    else
                                      FilledButton.icon(
                                        onPressed:
                                            ready &&
                                                c.sourceText
                                                    .trim()
                                                    .isNotEmpty &&
                                                !c.saving
                                            ? c.translate
                                            : null,
                                        icon: const Icon(
                                          CupertinoIcons.globe,
                                          size: 17,
                                        ),
                                        label: Text(
                                          c.error != null ? '重试翻译' : '翻译',
                                        ),
                                      ),
                                    OutlinedButton.icon(
                                      onPressed: c.result == null ? null : copy,
                                      icon: const Icon(
                                        CupertinoIcons.doc_on_doc,
                                        size: 16,
                                      ),
                                      label: Text(
                                        identical(copiedResult, c.result)
                                            ? copyStatus ?? '复制译文'
                                            : '复制译文',
                                      ),
                                    ),
                                    TextButton(
                                      onPressed:
                                          c.sourceText.isEmpty ||
                                              c.translating ||
                                              c.extracting
                                          ? null
                                          : c.clear,
                                      child: const Text('清空'),
                                    ),
                                    Text(
                                      '⌘ / Ctrl + Enter',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
