import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../src/ui/controls.dart';
import '../../src/ui/capture_mirrors.dart' show scheduleCaptureFrame;
import '../argos_engine.dart';
import '../controller.dart';
import '../models.dart';

class ArgosSettings extends StatefulWidget {
  const ArgosSettings({
    super.key,
    required this.controller,
    required this.channel,
    required this.onBack,
    this.onSaved,
  });
  final TranslationController controller;
  final TranslationChannel channel;
  final VoidCallback onBack;
  final VoidCallback? onSaved;
  @override
  State<ArgosSettings> createState() => _ArgosSettingsState();
}

class _ArgosSettingsState extends State<ArgosSettings> {
  ArgosOperation? operation;
  bool ready = false, busy = false;
  String status = '正在检查本地语言包';
  double? progress;
  @override
  void initState() {
    super.initState();
    run(false);
  }

  Future<void> run(bool download) async {
    setState(() {
      busy = true;
      progress = null;
      status = download ? '正在准备中英语言包' : '正在检查本地语言包';
    });
    scheduleCaptureFrame();
    final job = operation = widget.controller.service.argos.run(
      {'command': download ? 'install' : 'status'},
      timeout: download
          ? const Duration(minutes: 30)
          : const Duration(seconds: 30),
      onProgress: (message, value) {
        if (!mounted) return;
        setState(() {
          status = message;
          progress = value?.clamp(0, 1);
        });
        scheduleCaptureFrame();
      },
    );
    try {
      final data = await job.future;
      if (!mounted) return;
      setState(() {
        ready = data['ready'] == true;
        status = ready ? '中英语言包已准备，可离线翻译' : '尚未下载中英语言包';
      });
    } on TranslationCancelled {
      if (mounted) setState(() => status = '已取消，可重新准备语言包');
    } on TranslationException catch (e) {
      if (mounted) setState(() => status = e.message);
    } catch (_) {
      if (mounted) setState(() => status = '本地语言包准备失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          operation = null;
        });
        scheduleCaptureFrame();
      }
    }
  }

  Future<void> save() async {
    setState(() => busy = true);
    final success = await widget.controller.saveChannel(
      widget.channel.copyWith(model: ready ? 'ready' : ''),
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (!success) status = widget.controller.configError ?? '保存失败，请重试';
    });
    if (success) (widget.onSaved ?? widget.onBack)();
  }

  @override
  void dispose() {
    operation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
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
          Text('本地翻译 · Argos', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
      const SizedBox(height: 16),
      const Text(
        '无需 Key · 中英离线互译',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Windows 与 macOS 均在本机处理文字。首次准备需要联网下载英译中和中译英语言包，之后翻译无需联网。下载完成后保存，即可继续刚才的翻译。',
        style: TextStyle(height: 1.6),
      ),
      const SizedBox(height: 12),
      const Text('当前支持简体中文与英文。“自动检测”区分中英文段落；其他语言请切换在线渠道。'),
      const SizedBox(height: 18),
      Semantics(liveRegion: true, child: Text(status)),
      const SizedBox(height: 8),
      if (busy) LinearProgressIndicator(value: progress),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ToolButton(
            label: ready ? '重新检查语言包' : '下载中英语言包',
            icon: CupertinoIcons.arrow_down_circle,
            onPressed: busy ? null : () => run(!ready),
            child: Text(ready ? '重新检查' : '下载中英语言包'),
          ),
          if (busy)
            ToolButton(
              label: '取消准备',
              onPressed: () => operation?.cancel(),
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
}
