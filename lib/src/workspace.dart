import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';

import 'controller.dart';
import 'editor.dart';
import 'ui/controls.dart';

/// Transient app-owned surfaces. Native hosts supply only tray and OS services.
class Workspace extends StatelessWidget {
  const Workspace({super.key, required this.controller});
  final ClipController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (c.countdown > 0) {
            c.cancelCountdown();
          } else if (!c.busy) {
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
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              top: c.panel != 'capture',
              bottom: c.panel != 'capture',
              child: Column(
                children: [
                  if (c.error != null && c.panel != 'capture')
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: GlassPanel(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                c.error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            ToolButton(
                              label: '关闭提示',
                              icon: CupertinoIcons.xmark,
                              onPressed: () {
                                c.error = null;
                                c.changed();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration:
                          (MediaQuery.disableAnimationsOf(context) ||
                              c.panel == 'capture')
                          ? Duration.zero
                          : const Duration(milliseconds: 170),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      child: c.panel == 'capture' && c.clip != null
                          ? CaptureEditor(
                              key: ValueKey(c.revision),
                              clip: c.clip!,
                              controller: c,
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
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CaptureStrip extends StatelessWidget {
  const CaptureStrip({super.key, required this.controller});
  final ClipController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(CupertinoIcons.crop, color: cs.primary, size: 21),
                const SizedBox(width: 10),
                const Text(
                  '定格T',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  'SCREENSHOT',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.6,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                ToolButton(
                  label: '偏好设置',
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
            const SizedBox(height: 18),
            if (c.countdown > 0)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    child: Text(
                      '${c.countdown}',
                      key: ValueKey(c.countdown),
                      style: TextStyle(
                        fontSize: 36,
                        color: cs.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Text('秒后开始截图'),
                  const SizedBox(width: 16),
                  ToolButton(
                    label: '取消倒计时',
                    onPressed: c.cancelCountdown,
                    child: const Text('取消'),
                  ),
                ],
              )
            else
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
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
                        width: (constraints.maxWidth - 20) / 3,
                        child: GlassPanel(
                          padding: EdgeInsets.zero,
                          child: ToolButton(
                            label: item.$3,
                            onPressed: c.ready && !c.busy
                                ? () => c.capture(item.$1)
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(item.$2, size: 24),
                                  const SizedBox(height: 10),
                                  Text(
                                    item.$3,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    item.$4,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            Text(
              c.hotkey
                  ? (Platform.isMacOS ? '⌃ ⇧ X 随时截图' : 'Ctrl + Shift + X 随时截图')
                  : '快捷键被占用，请用托盘菜单',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 3,
              runSpacing: 3,
              alignment: WrapAlignment.center,
              children: [
                for (final seconds in [0, 3, 5, 10])
                  ToolButton(
                    label: seconds == 0 ? '无延时' : '延时 $seconds 秒',
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
    );
  }
}

class Preferences extends StatelessWidget {
  const Preferences({super.key, required this.controller});
  final ClipController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '偏好设置',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                ),
              ),
              ToolButton(
                label: '收起 · Esc',
                icon: CupertinoIcons.xmark,
                onPressed: c.busy ? null : c.discard,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '专注画面，随手完成。',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          GlassPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '截图延时',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '留出展开菜单、切换窗口的时间',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final seconds in [0, 3, 5, 10])
                      ToolButton(
                        label: seconds == 0 ? '立即截图' : '延时 $seconds 秒',
                        selected: c.delay == seconds,
                        onPressed: () => c.settings(seconds: seconds),
                        child: Text(seconds == 0 ? '立即' : '$seconds 秒'),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Container(
                    height: .7,
                    color: Theme.of(context).dividerColor,
                  ),
                ),
                const Text(
                  '外观',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    ToolButton(
                      label: '跟随系统外观',
                      selected: c.themeMode == ThemeMode.system,
                      onPressed: () => c.settings(appearance: ThemeMode.system),
                      child: const Text('跟随系统'),
                    ),
                    ToolButton(
                      label: '浅色外观',
                      selected: c.themeMode == ThemeMode.light,
                      onPressed: () => c.settings(appearance: ThemeMode.light),
                      child: const Text('浅色'),
                    ),
                    ToolButton(
                      label: '深色外观',
                      selected: c.themeMode == ThemeMode.dark,
                      onPressed: () => c.settings(appearance: ThemeMode.dark),
                      child: const Text('深色'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GlassPanel(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '开机启动',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c.launchAtLoginStatus == 'requiresApproval'
                            ? (Platform.isMacOS
                                  ? '请在系统登录项中允许定格T启动'
                                  : '请在系统启动应用中允许定格T启动')
                            : '登录后驻留托盘，随时截图',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                ToolButton(
                  label: '开机启动',
                  selected: c.launchAtLogin,
                  onPressed: c.startupBusy
                      ? null
                      : () => c.setLaunchAtLogin(!c.launchAtLogin),
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
              ],
            ),
          ),
          const SizedBox(height: 16),
          GlassPanel(
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.command,
                  size: 21,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        Platform.isMacOS
                            ? 'Control + Shift + X'
                            : 'Ctrl + Shift + X',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c.hotkey ? '全局区域截图 · Esc 取消' : '快捷键被其他应用占用',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (Platform.isMacOS)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ToolButton(
                label: '打开屏幕录制权限设置',
                onPressed: () => c.perform(c.bridge.permissions),
                child: const Text('屏幕录制权限…'),
              ),
            ),
          const SizedBox(height: 20),
          Text(
            '图片只在内存中处理，不保存历史、不上传。\n确认后复制到剪贴板；仅主动保存时写入文件。',
            style: TextStyle(
              fontSize: 11,
              height: 1.7,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          ToolButton(
            label: '打开截图工具条',
            onPressed: () {
              c.panel = c.clip == null ? 'palette' : 'capture';
              c.changed();
              c.bridge.present(c.panel);
            },
            child: const Text('打开截图工具条'),
          ),
        ],
      ),
    );
  }
}
