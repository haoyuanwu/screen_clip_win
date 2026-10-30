import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../src/ui/controls.dart';
import '../../src/ui/capture_mirrors.dart' show scheduleCaptureFrame;
import '../controller.dart';
import '../models.dart';

class TranslationLanguages extends StatefulWidget {
  const TranslationLanguages({
    super.key,
    required this.controller,
    this.disabled = false,
    this.onChanged,
  });
  final TranslationController controller;
  final bool disabled;
  final VoidCallback? onChanged;
  @override
  State<TranslationLanguages> createState() => _TranslationLanguagesState();
}

class _TranslationLanguagesState extends State<TranslationLanguages> {
  bool? source;
  void choose(bool value) {
    setState(() => source = source == value ? null : value);
    scheduleCaptureFrame();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final disabled = widget.disabled || c.saving || c.translating;
      final languages = c.activeChannel?.isLocal == true
          ? [
              TranslationLanguage.auto,
              TranslationLanguage.zh,
              TranslationLanguage.en,
            ]
          : TranslationLanguage.values;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 250),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ToolButton(
                  label: '切换翻译源语言',
                  selected: source == true,
                  onPressed: disabled ? null : () => choose(true),
                  child: Text(c.from.label),
                ),
                ToolButton(
                  label: '交换翻译语言',
                  icon: CupertinoIcons.arrow_right_arrow_left,
                  size: 28,
                  onPressed: disabled
                      ? null
                      : () async {
                          final success = await c.languages(
                            c.to,
                            c.from == TranslationLanguage.auto
                                ? (c.to == TranslationLanguage.zh
                                      ? TranslationLanguage.en
                                      : TranslationLanguage.zh)
                                : c.from,
                          );
                          if (mounted && success) widget.onChanged?.call();
                          scheduleCaptureFrame();
                        },
                ),
                ToolButton(
                  label: '切换翻译目标语言',
                  selected: source == false,
                  onPressed: disabled ? null : () => choose(false),
                  child: Text(c.to.label),
                ),
              ],
            ),
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              alignment: Alignment.topLeft,
              child: source == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final language in languages.where(
                            (v) =>
                                source == true || v != TranslationLanguage.auto,
                          ))
                            ToolButton(
                              label:
                                  '${source == true ? '源语言' : '目标语言'}：${language.label}',
                              selected:
                                  (source == true ? c.from : c.to) == language,
                              onPressed: disabled
                                  ? null
                                  : () async {
                                      final success = await c.languages(
                                        source == true ? language : c.from,
                                        source == false ? language : c.to,
                                      );
                                      if (mounted && success) {
                                        setState(() => source = null);
                                        widget.onChanged?.call();
                                      }
                                      scheduleCaptureFrame();
                                    },
                              child: Text(language.label),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}
