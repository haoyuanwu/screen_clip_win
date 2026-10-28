import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../src/ui/controls.dart';
import '../../src/ui/capture_mirrors.dart' show scheduleCaptureFrame;
import '../service.dart';
import '../tencent_tmt.dart';
import '../controller.dart';
import '../models.dart';

class ChannelSettings extends StatefulWidget {
  const ChannelSettings({
    super.key,
    required this.controller,
    required this.openUrl,
    this.onConfigured,
  });
  final TranslationController controller;
  final Future<void> Function(Uri) openUrl;
  final VoidCallback? onConfigured;
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
        onSaved: widget.onConfigured,
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
                      channel.isTencentTmt
                          ? '文本翻译 · ${channel.region}'
                          : channel.model,
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
                            child: Text(
                              channel.isTencentTmt ? '获取云密钥 ↗' : '获取 Key ↗',
                            ),
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
                                        channel.copyWith(
                                          apiKey: '',
                                          secretId: channel.isTencentTmt
                                              ? ''
                                              : null,
                                        ),
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
    this.onSaved,
  });
  final TranslationChannel? channel;
  final TranslationController controller;
  final VoidCallback onBack;
  final VoidCallback? onSaved;
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
  final secretIdInput = TextEditingController();
  late final regionInput = TextEditingController(
    text: widget.channel?.region ?? 'ap-guangzhou',
  );
  late final projectInput = TextEditingController(
    text: '${widget.channel?.projectId ?? 0}',
  );
  bool get tmt => widget.channel?.isTencentTmt == true;
  String? error, validationStatus;
  bool validating = false, validationPassed = false;
  int validationEpoch = 0;
  TranslationTask? validationTask;

  void invalidateValidation() {
    validationEpoch++;
    validationTask?.cancel();
    validationTask = null;
    if (mounted) {
      setState(() {
        validating = false;
        validationPassed = false;
        validationStatus = null;
        error = null;
      });
    }
    scheduleCaptureFrame();
  }

  Future<void> validateKey() async {
    if (!form.currentState!.validate()) return;
    final epoch = ++validationEpoch;
    setState(() {
      validating = true;
      validationPassed = false;
      validationStatus = tmt ? '正在验证云密钥与 TMT 服务…' : '正在验证 Key 与模型…';
      error = null;
    });
    scheduleCaptureFrame();
    try {
      final channel =
          (widget.channel ??
                  TranslationChannel(
                    id: 'validation',
                    name: name.text,
                    baseUrl: '',
                    model: '',
                  ))
              .copyWith(
                name: name.text.trim(),
                baseUrl: endpoint.text.trim(),
                model: model.text.trim(),
                apiKey: keyInput.text.trim().isEmpty
                    ? widget.channel?.apiKey ?? ''
                    : keyInput.text.trim(),
                secretId: secretIdInput.text.trim().isEmpty
                    ? widget.channel?.secretId ?? ''
                    : secretIdInput.text.trim(),
                region: regionInput.text.trim(),
                projectId: int.tryParse(projectInput.text.trim()) ?? 0,
                isEnabled: true,
              );
      final task = validationTask = widget.controller.service.start(
        text: 'Hello',
        from: TranslationLanguage.en,
        to: TranslationLanguage.zh,
        channel: channel,
        maxTokens: 64,
      );
      await task.future;
      if (mounted && epoch == validationEpoch) {
        setState(() {
          validationPassed = true;
          validationStatus = tmt ? '验证通过，云密钥与 TMT 服务可用' : '验证通过，当前 Key 与模型可用';
        });
      }
    } on TranslationCancelled {
      if (mounted && epoch == validationEpoch) {
        setState(() => validationStatus = '已取消验证');
      }
    } on TranslationException catch (e) {
      if (mounted && epoch == validationEpoch) {
        setState(() => validationStatus = '验证失败：${e.message}');
      }
    } catch (_) {
      if (mounted && epoch == validationEpoch) {
        setState(() => validationStatus = '验证失败，请检查网络和渠道配置');
      }
    } finally {
      if (mounted && epoch == validationEpoch) {
        setState(() {
          validating = false;
          validationTask = null;
        });
        scheduleCaptureFrame();
      }
    }
  }

  @override
  void dispose() {
    validationEpoch++;
    validationTask?.cancel();
    name.dispose();
    endpoint.dispose();
    model.dispose();
    keyInput.dispose();
    secretIdInput.dispose();
    regionInput.dispose();
    projectInput.dispose();
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
        secretId: secretIdInput.text.trim().isEmpty
            ? original.secretId
            : secretIdInput.text.trim(),
        region: regionInput.text.trim(),
        projectId: int.tryParse(projectInput.text.trim()) ?? 0,
        apiKey: keyInput.text.trim().isEmpty
            ? original.apiKey
            : keyInput.text.trim(),
      ),
    );
    if (!mounted) return;
    if (saved) {
      (widget.onSaved ?? widget.onBack)();
    } else {
      setState(() => error = widget.controller.configError ?? '保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, colors = Theme.of(context).colorScheme;
    return Form(
      key: form,
      onChanged: invalidateValidation,
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
            decoration: InputDecoration(
              labelText: 'API 地址',
              hintText: tmt
                  ? 'https://tmt.tencentcloudapi.com'
                  : 'https://example.com/v1/chat/completions',
              helperText: tmt
                  ? 'TMT 使用腾讯云 API 3.0，不需要 Chat Completions 路径'
                  : '填写完整 Chat Completions 地址；本机服务可用 HTTP',
            ),
            validator: (v) => tmt
                ? validateTmtEndpoint(v ?? '')
                : validateTranslationEndpoint(v ?? ''),
          ),
          const SizedBox(height: 14),
          if (tmt) ...[
            Text(
              '腾讯云 TMT 使用 SecretId / SecretKey。文本翻译计划于 2030-12-31 停止服务，后续可迁移至 TokenHub。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: secretIdInput,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'SecretId',
                helperText: widget.channel?.secretId.isNotEmpty == true
                    ? '已安全保存，留空保留；输入新 ID 可替换'
                    : '在腾讯云 API 密钥管理中获取',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty &&
                      widget.channel?.secretId.isNotEmpty != true
                  ? '请输入 SecretId'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: regionInput,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '地域 Region',
                helperText: '默认 ap-guangzhou（广州）',
              ),
              validator: (v) =>
                  RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$')
                      .hasMatch((v ?? '').trim())
                  ? null
                  : '请输入有效地域，例如 ap-guangzhou',
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: projectInput,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '项目 ID',
                helperText: '默认项目填 0',
              ),
              validator: (v) => (int.tryParse((v ?? '').trim()) ?? -1) < 0
                  ? '请输入非负整数项目 ID'
                  : null,
            ),
          ] else
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
              labelText: tmt ? 'SecretKey' : 'API Key',
              helperText: widget.channel?.apiKey.isNotEmpty == true
                  ? '${widget.channel!.keyHint}，留空保留；输入新 Key 可替换'
                  : '仅保存在系统钥匙串 / Windows 安全存储',
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty && widget.channel?.configured != true
                ? tmt
                      ? '请输入 SecretKey'
                      : '请输入 API Key'
                : null,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: c.saving || validating ? null : validateKey,
                icon: validating && !MediaQuery.disableAnimationsOf(context)
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        validationPassed
                            ? CupertinoIcons.checkmark_circle
                            : CupertinoIcons.checkmark_shield,
                        size: 17,
                      ),
                label: Text(
                  validating
                      ? '验证中…'
                      : tmt
                      ? '验证云密钥'
                      : '验证 API Key',
                ),
              ),
              if (validating)
                TextButton(
                  onPressed: () {
                    invalidateValidation();
                    setState(() => validationStatus = '已取消验证');
                  },
                  child: const Text('取消验证'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            tmt
                ? '发送 Hello 文本验证密钥、地域及服务权限，不发送截图内容。'
                : '发送简短测试验证当前 Key、地址和模型，不发送截图内容。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          if (validationStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  validationStatus!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: validating || validationPassed
                        ? colors.onSurface
                        : colors.error,
                  ),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: colors.error)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: c.saving || validating ? null : save,
            icon: c.saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(CupertinoIcons.check_mark, size: 17),
            label: Text(
              c.saving
                  ? '安全保存中…'
                  : widget.onSaved != null
                  ? '保存并继续截图'
                  : '保存渠道',
            ),
          ),
        ],
      ),
    );
  }
}
