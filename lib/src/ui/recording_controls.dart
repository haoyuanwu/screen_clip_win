import 'package:flutter/material.dart';

import '../recording.dart';
import '../theme.dart';
import 'controls.dart';

class RecordingControls extends StatefulWidget {
  const RecordingControls({super.key, required this.recording});
  final ScreenRecording recording;

  @override
  State<RecordingControls> createState() => _RecordingControlsState();
}

class _RecordingControlsState extends State<RecordingControls> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.recording,
    builder: (context, _) => _buildControls(context),
  );

  Widget _buildControls(BuildContext context) {
    final r = widget.recording;
    final cs = Theme.of(context).colorScheme;
    final action = r.busy
        ? '处理中…'
        : r.remaining > 0
        ? '取消 · ${r.remaining}s'
        : '开始录制';

    return ToolbarInspectorSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.fiber_manual_record,
                color: r.active ? cs.error : cs.primary,
                size: 12,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: r.engaged
                    ? Text(
                        r.active ? '请在菜单栏停止录制' : '录制选区',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Semantics(
                          expanded: _expanded,
                          child: ToolButton(
                            label: _expanded ? '收起录制规格' : '展开录制规格',
                            size: 28,
                            onPressed: () => setState(() {
                              _expanded = !_expanded;
                            }),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    '${r.delay == 0 ? '立即' : '${r.delay}s 延迟'} · '
                                    '${r.format.toUpperCase()} · ${r.fps} fps',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                AnimatedRotation(
                                  turns: _expanded ? .5 : 0,
                                  duration: AppStyle.motion(context),
                                  curve: AppStyle.motionCurve,
                                  child: const Icon(
                                    Icons.expand_more,
                                    size: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              ToolButton(
                label: action,
                size: 28,
                primary: true,
                onPressed: r.busy || r.active
                    ? null
                    : r.remaining > 0
                    ? r.cancelCountdown
                    : () {
                        setState(() => _expanded = false);
                        r.start();
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Text(action),
                ),
              ),
              if (!r.engaged)
                ToolButton(
                  label: '收起录屏设置',
                  icon: Icons.close,
                  size: 28,
                  onPressed: () {
                    r.open = false;
                    r.changed();
                  },
                ),
            ],
          ),
          if (_expanded && !r.engaged) ...[
            Divider(height: 12, color: cs.outlineVariant),
            PanelReveal(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 5,
                children: [
                  _RecordingChoices<int>(
                    title: '延迟',
                    value: r.delay,
                    options: const {0: '立即', 3: '3s', 5: '5s', 10: '10s'},
                    onChanged: (value) {
                      r.delay = value;
                      r.changed();
                    },
                  ),
                  _RecordingChoices<String>(
                    title: '格式',
                    value: r.format,
                    options: const {'mp4': 'MP4', 'mov': 'MOV'},
                    onChanged: (value) {
                      r.format = value;
                      r.changed();
                    },
                  ),
                  _RecordingChoices<int>(
                    title: '帧率',
                    value: r.fps,
                    options: const {30: '30 fps', 60: '60 fps', 120: '120 fps'},
                    onChanged: (value) {
                      r.fps = value;
                      r.changed();
                    },
                  ),
                ],
              ),
            ),
          ],
          if (r.demo)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Debug 演示 · 不读取屏幕，不生成视频',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ),
          if (r.error != null)
            CopyableMessage(
              message: r.error!,
              style: TextStyle(color: cs.error),
            ),
          if (r.savedPath != null)
            CopyableMessage(message: '已保存：${r.savedPath}'),
        ],
      ),
    );
  }
}

class _RecordingChoices<T> extends StatelessWidget {
  const _RecordingChoices({
    required this.title,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 40,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(
        child: ToolbarWrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final option in options.entries)
              ToolButton(
                label: '$title ${option.value}',
                size: 28,
                selected: option.key == value,
                onPressed: () => onChanged(option.key),
                child: Text(option.value),
              ),
          ],
        ),
      ),
    ],
  );
}
