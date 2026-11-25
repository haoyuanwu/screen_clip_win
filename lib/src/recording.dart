import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenRecording extends ChangeNotifier {
  ScreenRecording({this.onExit, this.demo = kDebugMode});
  final bool demo;
  String? notice;
  final Future<void> Function()? onExit;
  Rect? region;
  static const channel = MethodChannel('screenclip/desktop');
  bool open = false, busy = false, active = false;
  int delay = 0, fps = 60, remaining = 0, _epoch = 0;
  String format = 'mp4';
  String? error, savedPath;
  Timer? _timer;
  bool _disposed = false, _polling = false;
  bool get engaged => busy || active || remaining > 0;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (engaged) return;
    final epoch = ++_epoch;
    var captureHidden = false;
    busy = true;
    error = savedPath = notice = null;
    changed();
    try {
      final accepted = demo
          ? true
          : await channel.invokeMethod<bool>('prepareRecording', {
              'format': format,
              'fps': fps,
              if (region != null)
                'region': {
                  'x': region!.left,
                  'y': region!.top,
                  'width': region!.width,
                  'height': region!.height,
                },
            });
      if (_disposed || epoch != _epoch || accepted != true) return;
      busy = false;
      remaining = delay;
      changed();
      while (remaining > 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (_disposed || epoch != _epoch) return;
        remaining--;
        changed();
      }
      busy = true;
      changed();
      await channel.invokeMethod<void>('dismiss');
      captureHidden = true;
      if (_disposed) return;
      if (demo) {
        await channel.invokeMethod<void>('setDemoRecordingIndicator', true);
      } else {
        await channel.invokeMethod<void>('startRecording');
      }
      active = true;
      if (demo) return;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_polling) {
          _polling = true;
          channel
              .invokeMethod<String>('recordingStatus')
              .then((value) {
                if (!_disposed && active && value != null) {
                  error = '录制中断：$value，请停止并保存已有内容';
                  changed();
                }
              })
              .catchError((Object _) {})
              .whenComplete(() => _polling = false);
        }
      });
    } catch (e) {
      error = e is PlatformException ? e.message : '$e';
      if (captureHidden) {
        open = false;
        busy = false;
        await onExit?.call();
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> cancelCountdown() async {
    if (remaining == 0) return;
    _epoch++;
    remaining = 0;
    changed();
    if (!demo) await channel.invokeMethod<void>('cancelPreparedRecording');
  }

  Future<void> stop() async {
    if (!active || busy) return;
    busy = true;
    changed();
    _timer?.cancel();
    try {
      if (demo) {
        await channel.invokeMethod<void>('setDemoRecordingIndicator', false);
        notice = '演示录制已结束，未生成视频';
      } else {
        savedPath = await channel.invokeMethod<String>('stopRecording');
      }
    } catch (e) {
      error = e is PlatformException ? e.message : '$e';
    } finally {
      await finishStop();
    }
  }

  void beginNativeStop() {
    if (!active || _disposed) return;
    busy = true;
    _timer?.cancel();
    changed();
  }

  Future<void> finishStop({String? path, String? failure}) async {
    if (_disposed) return;
    _timer?.cancel();
    savedPath = path ?? savedPath;
    error = failure ?? error;
    if (savedPath != null) error = null;
    active = false;
    busy = false;
    open = false;
    changed();
    await onExit?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }
}
