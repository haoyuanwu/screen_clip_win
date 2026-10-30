import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../src/ui/controls.dart';
import '../controller.dart';
import '../models.dart';

class ArgosSettings extends StatefulWidget {
  const ArgosSettings({
    super.key,
    required this.controller,
    required this.channel,
    required this.onBack,
    this.onSaved,
    this.onDownloadStarted,
  });
  final TranslationController controller;
  final TranslationChannel channel;
  final VoidCallback onBack;
  final VoidCallback? onSaved, onDownloadStarted;
  @override
  State<ArgosSettings> createState() => _ArgosSettingsState();
}

class _ArgosSettingsState extends State<ArgosSettings> {
  bool saving = false;
  @override
  void initState() {
    super.initState();
    widget.controller.checkLocalModels();
  }

  void download() {
    widget.controller.downloadLocalModels();
    widget.onDownloadStarted?.call();
  }

  Future<void> save() async {
    setState(() => saving = true);
    final success = await widget.controller.saveChannel(
      widget.channel.copyWith(
        model: widget.controller.localModelsReady ? 'ready' : '',
      ),
    );
    if (!mounted) return;
    setState(() {
      saving = false;
      if (!success) {
        widget.controller.localModelStatus =
            widget.controller.configError ?? '保存失败，请重试';
      }
    });
    if (success) (widget.onSaved ?? widget.onBack)();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final ready = c.localModelsReady;
      final busy = c.downloadingLocalModels || saving;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              ToolButton(
                label: '返回渠道列表',
                icon: CupertinoIcons.chevron_left,
                onPressed: widget.onBack,
              ),
              const SizedBox(width: 8),
              Text(
                '本地翻译 · Argos',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '无需 Key · 中英离线互译',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Windows 与 macOS 均在本机处理文字。首次准备需要联网下载英译中和中译英语言包，之后翻译无需联网。点击下载后可返回继续操作，下载将在后台进行；完成后即可离线翻译。',
            style: TextStyle(height: 1.6),
          ),
          const SizedBox(height: 12),
          const Text('当前支持简体中文与英文。“自动检测”区分中英文段落；其他语言请切换在线渠道。'),
          const SizedBox(height: 18),
          Semantics(liveRegion: true, child: Text(c.localModelStatus)),
          const SizedBox(height: 8),
          if (busy) LinearProgressIndicator(value: c.localModelProgress),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ToolButton(
                label: ready ? '重新检查语言包' : '下载中英语言包',
                icon: CupertinoIcons.arrow_down_circle,
                onPressed: busy
                    ? null
                    : ready
                    ? c.checkLocalModels
                    : download,
                child: Text(ready ? '重新检查' : '下载中英语言包'),
              ),
              if (c.downloadingLocalModels)
                ToolButton(
                  label: '取消下载',
                  onPressed: c.cancelModelDownload,
                  child: const Text('取消'),
                ),
              ToolButton(
                label: '保存并返回',
                primary: true,
                onPressed: busy || !ready ? null : save,
                child: const Text('保存并返回'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// Shared progress survives dismissal of the settings page.
class LocalModelDownloadStatus extends StatelessWidget {
  const LocalModelDownloadStatus({super.key, required this.controller});
  final TranslationController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      if (!c.localModelDownloadAttempted) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                c.localModelStatus,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (!c.downloadingLocalModels && !c.localModelsReady)
              TextButton(
                onPressed: c.downloadLocalModels,
                child: const Text('重试下载'),
              ),
            if (c.downloadingLocalModels) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: c.localModelProgress),
              TextButton(
                onPressed: c.cancelModelDownload,
                child: const Text('取消下载'),
              ),
            ],
          ],
        ),
      );
    },
  );
}
