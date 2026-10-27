import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../src/ui/controls.dart';
import '../controller.dart';
import '../models.dart';

class ChannelSettings extends StatefulWidget {
  const ChannelSettings({
    super.key,
    required this.controller,
    required this.openUrl,
  });
  final TranslationController controller;
  final Future<void> Function(Uri) openUrl;
  @override
  State<ChannelSettings> createState() => _ChannelSettingsState();
}

class _ChannelSettingsState extends State<ChannelSettings> {
  TranslationChannel? editing;
  bool adding = false;
  String? confirm, linkError;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller, colors = Theme.of(context).colorScheme;
    if (adding || editing != null) {
      return ChannelEditor(
        key: ValueKey(editing?.id ?? 'new'),
        channel: editing,
        controller: c,
        onBack: () => setState(() {
          adding = false;
          editing = null;
        }),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('翻译渠道', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'API Key 保存在系统安全存储中。配置模型与接口后，原文将直接发送至所选服务商。',
          style: TextStyle(
            color: colors.onSurfaceVariant,
            fontSize: 12,
            height: 1.6,
          ),
        ),
        if (c.configError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(c.configError!, style: TextStyle(color: colors.error)),
          ),
        if (!c.initialized)
          TextButton.icon(
            onPressed: c.initializing ? null : c.initialize,
            icon: const Icon(CupertinoIcons.refresh, size: 16),
            label: const Text('重新读取安全配置'),
          ),
        if (linkError != null)
          Text(linkError!, style: TextStyle(color: colors.error)),
        const SizedBox(height: 12),
        for (final channel in c.channels)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: channel.id == c.activeId
                      ? colors.primary
                      : colors.outlineVariant,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          channel.id == c.activeId
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.globe,
                          color: channel.id == c.activeId
                              ? colors.primary
                              : colors.onSurfaceVariant,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            channel.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          channel.isEnabled ? '已启用' : '已停用',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 32,
                          child: Switch.adaptive(
                            value: channel.isEnabled,
                            onChanged: c.saving || !c.initialized
                                ? null
                                : (value) => c.saveChannel(
                                    channel.copyWith(isEnabled: value),
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      channel.model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      channel.keyHint,
                      style: TextStyle(
                        fontSize: 12,
                        color: channel.configured
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        TextButton(
                          onPressed: c.saving || !c.initialized
                              ? null
                              : () => setState(() => editing = channel),
                          child: const Text('配置'),
                        ),
                        if (channel.id != c.activeId)
                          TextButton(
                            onPressed:
                                c.saving ||
                                    !c.initialized ||
                                    !channel.isEnabled ||
                                    !channel.configured
                                ? null
                                : () => c.selectChannel(channel.id),
                            child: const Text('设为当前'),
                          ),
                        if (channel.keyUrl.isNotEmpty)
                          TextButton(
                            onPressed: () async {
                              try {
                                await widget.openUrl(Uri.parse(channel.keyUrl));
                              } catch (_) {
                                if (mounted) {
                                  setState(() => linkError = '无法打开服务商网站，请稍后重试');
                                }
                              }
                            },
                            child: const Text('获取 Key ↗'),
                          ),
                        if (channel.apiKey.isNotEmpty || channel.isCustom)
                          TextButton(
                            onPressed: c.saving || !c.initialized
                                ? null
                                : () async {
                                    if (confirm != channel.id) {
                                      setState(() => confirm = channel.id);
                                      return;
                                    }
                                    if (channel.isCustom) {
                                      await c.removeChannel(channel.id);
                                    } else {
                                      await c.saveChannel(
                                        channel.copyWith(apiKey: ''),
                                      );
                                    }
                                    if (mounted) setState(() => confirm = null);
                                  },
                            child: Text(
                              confirm == channel.id
                                  ? '确认${channel.isCustom ? '删除渠道' : '清除 Key'}'
                                  : channel.isCustom
                                  ? '删除'
                                  : '清除 Key',
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        if (confirm == channel.id)
                          TextButton(
                            onPressed: () => setState(() => confirm = null),
                            child: const Text('取消'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: c.saving || !c.initialized
              ? null
              : () => setState(() => adding = true),
          icon: const Icon(CupertinoIcons.add, size: 17),
          label: const Text('添加自定义兼容渠道'),
        ),
        const SizedBox(height: 10),
        Text(
          '预置模型可修改。豆包可填写已开通的模型 ID 或 ep- 接入点 ID；不同账号可用模型以服务商控制台为准。',
          style: TextStyle(
            color: colors.onSurfaceVariant,
            fontSize: 12,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

class ChannelEditor extends StatefulWidget {
  const ChannelEditor({
    super.key,
    this.channel,
    required this.controller,
    required this.onBack,
  });
  final TranslationChannel? channel;
  final TranslationController controller;
  final VoidCallback onBack;
  @override
  State<ChannelEditor> createState() => _ChannelEditorState();
}

class _ChannelEditorState extends State<ChannelEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.channel?.name ?? '');
  late final endpoint = TextEditingController(
    text: widget.channel?.baseUrl ?? '',
  );
  late final model = TextEditingController(text: widget.channel?.model ?? '');
  final keyInput = TextEditingController();
  String? error;
  @override
  void dispose() {
    name.dispose();
    endpoint.dispose();
    model.dispose();
    keyInput.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    final original =
        widget.channel ??
        TranslationChannel(
          id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
          name: '',
          model: '',
          baseUrl: '',
          isCustom: true,
          createdAt: DateTime.now(),
        );
    final saved = await widget.controller.saveChannel(
      original.copyWith(
        name: name.text.trim(),
        baseUrl: endpoint.text.trim(),
        model: model.text.trim(),
        apiKey: keyInput.text.trim().isEmpty
            ? original.apiKey
            : keyInput.text.trim(),
      ),
    );
    if (!mounted) return;
    if (saved) {
      widget.onBack();
    } else {
      setState(() => error = widget.controller.configError ?? '保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, colors = Theme.of(context).colorScheme;
    return Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              ToolButton(
                label: '返回渠道列表',
                icon: CupertinoIcons.chevron_left,
                onPressed: c.saving ? null : widget.onBack,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.channel?.name ?? '自定义渠道',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: '渠道名称'),
            validator: (v) => v == null || v.trim().isEmpty ? '请输入名称' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: endpoint,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'API 地址',
              hintText: 'https://example.com/v1/chat/completions',
              helperText: '填写完整 Chat Completions 地址；本机服务可用 HTTP',
            ),
            validator: (v) => validateTranslationEndpoint(v ?? ''),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: model,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '模型名称 / 接入点 ID'),
            validator: (v) =>
                v == null || v.trim().isEmpty ? '请填写已开通的模型名称' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: keyInput,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: widget.channel?.apiKey.isNotEmpty == true
                  ? '${widget.channel!.keyHint}，留空保留；输入新 Key 可替换'
                  : '仅保存在系统钥匙串 / Windows 安全存储',
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty && widget.channel?.configured != true
                ? '请输入 API Key'
                : null,
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: colors.error)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: c.saving ? null : save,
            icon: c.saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(CupertinoIcons.check_mark, size: 17),
            label: Text(c.saving ? '安全保存中…' : '保存渠道'),
          ),
        ],
      ),
    );
  }
}
