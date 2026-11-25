import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';

import 'controller.dart';
import 'editor.dart';
import 'theme.dart';
import 'ui/controls.dart';
import 'ui/color_preview.dart';
import 'ui/capture_mirrors.dart';
import '../translation/ui/translation_panel.dart';

/// Transient app-owned surfaces. Native hosts supply only tray and OS services.
class Workspace extends StatelessWidget {
  const Workspace({super.key, required this.controller});
  final ClipController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    // A hidden desktop window can report zero size before its first presentation.
    if (MediaQuery.sizeOf(context).isEmpty) return const SizedBox.shrink();
    final surface = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (c.recording.remaining > 0) {
            c.recording.cancelCountdown();
          } else if (c.countdown > 0) {
            c.cancelCountdown();
          } else if (c.panel == 'capture' || !c.busy) {
            c.discard();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          if (!c.busy) c.capture('region');
        },
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () {
          if (!c.busy) c.capture('region');
        },
      },
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!,
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: c.panel == 'color'
                ? Colors.transparent
                : Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              top: c.panel != 'capture',
              bottom: c.panel != 'capture',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    reverseDuration: Duration.zero,
                    duration:
                        (MediaQuery.disableAnimationsOf(context) ||
                            c.panel == 'capture' ||
                            c.panel == 'color')
                        ? Duration.zero
                        : AppStyle.motion(context, 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    child: c.panel == 'capture' && c.clip != null
                        ? CaptureEditor(
                            key: ValueKey(c.revision),
                            clip: c.clip!,
                            controller: c,
                          )
                        : c.panel == 'color' && c.sampledColor != null
                        ? Platform.isWindows
                              ? FixedColorPreview(
                                  sample: c.sampledColor!,
                                  onClose: c.discard,
                                  onResample: () => c.capture('color'),
                                  onSizeChanged: (size) {
                                    c.bridge
                                        .resizeColorCard(size)
                                        .catchError((Object _) {});
                                  },
                                )
                              : Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Center(
                                    child: ColorPreviewCard(
                                      sample: c.sampledColor!,
                                      fixed: true,
                                      onClose: c.discard,
                                      onResample: () => c.capture('color'),
                                    ),
                                  ),
                                )
                        : c.panel == 'translation'
                        ? TranslationPanel(
                            controller: c.translation,
                            settingsInitially: c.translationSettingsInitially,
                            onClose: c.closeTranslation,
                            openUrl: c.bridge.openServiceUrl,
                          )
                        : c.panel == 'settings'
                        ? Preferences(
                            key: const ValueKey('settings'),
                            controller: c,
                          )
                        : CaptureStrip(
                            key: const ValueKey('palette'),
                            controller: c,
                          ),
                  ),
                  if (c.error != null && c.panel != 'capture')
                    Positioned(
                      top: 12,
                      right: 12,
                      width: (MediaQuery.sizeOf(context).width - 24).clamp(
                        0,
                        460,
                      ),
                      child: PanelReveal(
                        child: FloatingErrorNotification(
                          message: c.error!,
                          onDismiss: () {
                            c.error = null;
                            c.changed();
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return CaptureMirrors(
      active: c.panel == 'capture' && c.clip != null,
      revision: c.revision,
      colorOnly: c.clip?.mode == 'color',
      child: surface,
    );
  }
}

class CaptureStrip extends StatelessWidget {
  const CaptureStrip({super.key, required this.controller});
  final ClipController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canCapture = c.ready && !c.busy && !c.recording.engaged;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(AppStyle.controlRadius),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Icon(
                    CupertinoIcons.crop,
                    color: cs.onPrimary,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '定格',
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ToolButton(
                label: '文字翻译',
                title: '翻译',
                icon: CupertinoIcons.globe,
                onPressed: c.busy ? null : c.openTranslation,
              ),
              ToolButton(
                label: '屏幕取色 · Ctrl+Shift+C',
                title: '取色',
                icon: Icons.colorize_rounded,
                onPressed: c.busy ? null : () => c.capture('color'),
              ),
              ToolButton(
                label: '偏好设置',
                title: '设置',
                icon: CupertinoIcons.slider_horizontal_3,
                onPressed: c.busy
                    ? null
                    : () {
                        c.panel = 'settings';
                        c.changed();
                        c.bridge.present('settings');
                      },
              ),
              ToolButton(
                label: '收起 · Esc',
                icon: CupertinoIcons.xmark,
                onPressed: c.busy ? null : c.discard,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (c.countdown > 0)
            FlatPanel(
              floating: false,
              padding: const EdgeInsets.all(14),
              child: Row(
                spacing: 12,
                children: [
                  AnimatedSwitcher(
                    duration: AppStyle.motion(context),
                    child: Text(
                      '${c.countdown}',
                      key: ValueKey(c.countdown),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: cs.primary,
                      ),
                    ),
                  ),
                  const Expanded(child: Text('秒后开始截图')),
                  ToolButton(
                    label: '取消倒计时',
                    onPressed: c.cancelCountdown,
                    child: const Text('取消'),
                  ),
                ],
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
                final count = constraints.maxWidth >= 380 * scale ? 3 : 1;
                final width = (constraints.maxWidth - (count - 1) * 10) / count;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final item in const [
                      ('region', CupertinoIcons.crop, '区域截图', '拖动选取'),
                      ('window', CupertinoIcons.rectangle, '窗口截图', '点击窗口'),
                      (
                        'screen',
                        CupertinoIcons.desktopcomputer,
                        '全屏截图',
                        '确认整屏',
                      ),
                    ])
                      SizedBox(
                        width: width,
                        child: FlatPanel(
                          padding: EdgeInsets.zero,
                          floating: false,
                          color: item.$1 == 'region'
                              ? cs.primaryContainer
                              : cs.surface,
                          child: ToolButton(
                            label: item.$3,
                            onPressed: canCapture
                                ? () => c.capture(item.$1)
                                : null,
                            child: SizedBox(
                              width: double.infinity,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      item.$2,
                                      color: item.$1 == 'region'
                                          ? cs.onPrimaryContainer
                                          : cs.primary,
                                      size: 22,
                                    ),
                                    const SizedBox(height: 9),
                                    Text(
                                      item.$3,
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      item.$4,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
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
                );
              },
            ),
          const SizedBox(height: 14),
          FlatPanel(
            floating: false,
            shadow: false,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              spacing: 10,
              runSpacing: 4,
              children: [
                Text(
                  c.hotkey
                      ? (Platform.isMacOS
                            ? '⌃ ⇧ X  随时截图'
                            : 'Ctrl + Shift + X  随时截图')
                      : '全局快捷键不可用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 3,
                  children: [
                    Text(
                      '延时',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    for (final seconds in [0, 3, 5, 10])
                      ToolButton(
                        label: seconds == 0 ? '无延时' : '延时 $seconds 秒',
                        size: 28,
                        selected: c.delay == seconds,
                        onPressed: c.busy
                            ? null
                            : () => c.settings(seconds: seconds),
                        child: Text(seconds == 0 ? '立即' : '${seconds}s'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (c.recording.notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                c.recording.notice!,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (c.recording.savedPath != null)
            CopyableMessage(message: '录屏已保存：${c.recording.savedPath}'),
          if (c.recording.error != null)
            CopyableMessage(message: c.recording.error!),
        ],
      ),
    );
  }
}

class Preferences extends StatelessWidget {
  const Preferences({super.key, required this.controller});
  final ClipController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ToolButton(
                label: '打开截图工具条',
                icon: CupertinoIcons.chevron_left,
                onPressed: () {
                  c.panel = c.clip == null ? 'palette' : 'capture';
                  c.changed();
                  c.bridge.present(c.panel);
                },
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('偏好设置', style: theme.textTheme.titleLarge)),
              ToolButton(
                label: '收起 · Esc',
                icon: CupertinoIcons.xmark,
                onPressed: c.busy ? null : c.discard,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: '截图与录屏',
            children: [
              _SettingRow(
                icon: CupertinoIcons.timer,
                title: '截图延时',
                action: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final seconds in [0, 3, 5, 10])
                      ToolButton(
                        label: seconds == 0 ? '立即截图' : '延时 $seconds 秒',
                        size: 30,
                        selected: c.delay == seconds,
                        onPressed: () => c.settings(seconds: seconds),
                        child: Text(seconds == 0 ? '立即' : '${seconds}s'),
                      ),
                  ],
                ),
              ),
              if (Platform.isMacOS)
                _SettingRow(
                  icon: CupertinoIcons.folder,
                  title: '录屏保存位置',
                  details: c.recordingFolder ?? '桌面 · 等待授权',
                  action: ToolButton(
                    label: '更改录屏保存位置',
                    onPressed: c.busy || c.recording.engaged
                        ? null
                        : c.changeRecordingFolder,
                    child: const Text('更改…'),
                  ),
                ),
              _SettingRow(
                icon: CupertinoIcons.command,
                title: '全局快捷键',
                details:
                    '${Platform.isMacOS ? '⌃ ⇧' : 'Ctrl + Shift +'} X  截图${c.hotkey ? '' : '（不可用）'}\n'
                    '${Platform.isMacOS ? '⌃ ⇧' : 'Ctrl + Shift +'} C  取色${c.colorHotkey ? '' : '（不可用）'}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: '应用',
            children: [
              _SettingRow(
                icon: CupertinoIcons.circle_lefthalf_fill,
                title: '外观',
                action: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final option in const [
                      (ThemeMode.system, '跟随系统外观', '跟随系统'),
                      (ThemeMode.light, '浅色外观', '浅色'),
                      (ThemeMode.dark, '深色外观', '深色'),
                    ])
                      ToolButton(
                        label: option.$2,
                        selected: c.themeMode == option.$1,
                        onPressed: () => c.settings(appearance: option.$1),
                        child: Text(option.$3),
                      ),
                  ],
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.power,
                title: '开机启动',
                details: c.launchAtLoginStatus == 'requiresApproval'
                    ? '请在系统设置中允许定格启动'
                    : '登录后在菜单栏或系统托盘运行',
                action: ToolButton(
                  label: '开机启动',
                  selected: c.launchAtLogin,
                  onPressed: c.startupBusy
                      ? null
                      : () => c.setLaunchAtLogin(
                          !c.launchAtLogin,
                          openSettings: Platform.isMacOS && !c.launchAtLogin,
                        ),
                  child: Text(
                    c.startupBusy
                        ? '设置中…'
                        : c.launchAtLoginStatus == 'requiresApproval'
                        ? '待系统允许'
                        : c.launchAtLogin
                        ? '已开启'
                        : '已关闭',
                  ),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.globe,
                title: '翻译 API Key',
                details: '管理翻译服务商、模型与密钥',
                action: ToolButton(
                  label: '配置翻译 API Key',
                  onPressed: c.busy
                      ? null
                      : () => c.openTranslation(settings: true),
                  child: const Text('配置'),
                ),
              ),
            ],
          ),
          if (Platform.isMacOS) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ToolButton(
                  label: '打开屏幕录制权限设置',
                  onPressed: () => c.perform(c.bridge.permissions),
                  child: const Text('屏幕录制权限…'),
                ),
                ToolButton(
                  label: '在访达中显示当前应用',
                  onPressed: () => c.perform(c.bridge.revealApplication),
                  child: const Text('定位当前应用'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '截图在内存中处理。使用在线翻译时，原文会发送至所选渠道。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 7),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      FlatPanel(
        floating: false,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          children: [
            for (final (index, child) in children.indexed) ...[
              if (index > 0) const Divider(height: 1),
              child,
            ],
          ],
        ),
      ),
    ],
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    this.details,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? details;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 340 ||
              MediaQuery.textScalerOf(context).scale(13) > 17;
          return Row(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(icon, size: 17, color: cs.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.labelLarge),
                          if (details != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              details!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (compact && action != null) ...[
                            const SizedBox(height: 6),
                            action!,
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!compact && action != null) ...[
                const SizedBox(width: 8),
                action!,
              ],
            ],
          );
        },
      ),
    );
  }
}
