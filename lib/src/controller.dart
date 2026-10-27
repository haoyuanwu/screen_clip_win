import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'platform_bridge.dart';
import 'color_picker.dart';
import 'ui/capture_mirrors.dart'
    show dispatchCapturePointer, resetCaptureMirrors, scheduleCaptureFrame;

class Clip {
  const Clip({
    required this.bytes,
    required this.width,
    required this.height,
    this.mode = 'region',
    this.windows = const [],
    this.screens = const [],
    this.rgbaPixels,
  });
  final Uint8List bytes;
  final Uint8List? rgbaPixels;
  final int width, height;
  final String mode;
  // Screen rectangles use source pixels; the primary display is first.
  final List<ui.Rect> windows, screens;
}

/// One frozen screen, edited before confirmation. No capture history or files.
class ClipController extends ChangeNotifier {
  ClipController({DesktopBridge? bridge}) : bridge = bridge ?? DesktopBridge();
  final DesktopBridge bridge;
  String? directory, error;
  String panel = 'palette';
  Clip? clip;
  int revision = 0, delay = 0, countdown = 0;
  bool busy = false, ready = false, hotkey = false;
  bool colorHotkey = false;
  SampledColor? sampledColor;
  String launchAtLoginStatus = 'disabled';
  bool startupBusy = false;
  bool get launchAtLogin => launchAtLoginStatus == 'enabled';
  bool _startupConfigured = false;
  ThemeMode themeMode = ThemeMode.system;
  bool _disposed = false, _cancelled = false;
  Timer? _timer;
  Completer<void>? _waiting;
  Future<void> _writes = Future.value();
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    DesktopBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'captureWake' && clip != null && panel == 'capture') {
        scheduleCaptureFrame();
        return;
      }
      if (call.method == 'capturePointer' &&
          clip != null &&
          panel == 'capture') {
        dispatchCapturePointer(call.arguments as Map);
        return;
      }
      if (call.method == 'pinCreated') {
        final args = call.arguments as Map;
        final id = args['id'];
        if (id != null && args['bytes'] is Uint8List) {
          unawaited(bridge.recognizePinnedText(id, args['bytes'] as Uint8List));
        }
      }
      if (call.method == 'captureRequested' && !busy && ready) {
        await capture(call.arguments as String? ?? 'region');
      }
      if (call.method == 'openPanel' && !busy) {
        panel = clip != null
            ? 'capture'
            : call.arguments as String? ?? 'palette';
        changed();
        await bridge.present(panel);
      }
      if (call.method == 'dismissed') await discard(hide: false);
    });
    try {
      hotkey = await bridge.registerHotkey();
      try {
        colorHotkey = await bridge.registerColorHotkey();
      } catch (_) {
        colorHotkey = false;
      }
      directory = await bridge.dataDirectory();
      await Directory(directory!).create(recursive: true);
      final preferences = File('$directory/preferences.json');
      if (await preferences.exists()) {
        try {
          final j = jsonDecode(
            await preferences.readAsString(),
          ) as Map<String, dynamic>;
          _startupConfigured = j['startupConfigured'] == true;
          themeMode = switch (j['appearance']) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            'system' => ThemeMode.system,
            _ =>
              j['dark'] is bool
                  ? (j['dark'] == true ? ThemeMode.dark : ThemeMode.light)
                  : ThemeMode.system,
          };
          delay = const [0, 3, 5, 10].contains(j['delay'])
              ? j['delay'] as int
              : 0;
        } catch (_) {
          /* Invalid preferences use safe defaults; never block capture. */
        }
      }
      ready = true;
      try {
        launchAtLoginStatus = _startupConfigured
            ? await bridge.launchAtLoginStatus()
            : await bridge.setLaunchAtLogin(true);
        _startupConfigured = true;
        await settings();
      } catch (e) {
        error = '开机启动设置未完成，可在偏好设置中重试：$e';
      }
    } catch (e) {
      error = '初始化失败：$e';
    }
    changed();
  }

  Future<void> settings({ThemeMode? appearance, int? seconds}) async {
    themeMode = appearance ?? themeMode;
    delay = seconds ?? delay;
    changed();
    if (directory == null) return;
    final content = jsonEncode({
      'appearance': themeMode.name,
      'delay': delay,
      'startupConfigured': _startupConfigured,
    });
    _writes = _writes
        .catchError((Object _) {})
        .then(
          (_) =>
              File('$directory/preferences.json')
                  .writeAsString(content, flush: true)
                  .then((_) {}),
        );
    try {
      await _writes;
    } catch (e) {
      error = '设置保存失败：$e';
      changed();
    }
  }

  Future<void> setLaunchAtLogin(bool enabled) async {
    if (startupBusy) return;
    startupBusy = true;
    error = null;
    changed();
    try {
      launchAtLoginStatus = await bridge.setLaunchAtLogin(enabled);
      _startupConfigured = true;
      await settings();
    } catch (e) {
      error = '开机启动设置失败：$e';
    } finally {
      startupBusy = false;
      changed();
    }
  }

  Future<void> perform(Future<void> Function() operation) async {
    if (busy) return;
    busy = true;
    error = null;
    changed();
    try {
      await operation();
    } on PlatformException catch (e) {
      error = e.message ?? '系统操作失败，请重试';
      if (e.code == 'permission' && clip == null) {
        sampledColor = null;
        panel = 'palette';
      }
      await bridge.present(panel);
    } catch (e) {
      error = '操作未完成：$e';
      await bridge.present(panel);
    } finally {
      busy = false;
      countdown = 0;
      changed();
    }
  }

  Future<void> capture(String mode) => perform(() async {
    if (!ready) return;
    _cancelled = false;
    if (delay > 0 && mode != 'color') {
      countdown = delay;
      panel = 'palette';
      await bridge.present('palette');
      changed();
      _waiting = Completer<void>();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        countdown--;
        changed();
        if (countdown <= 0) {
          timer.cancel();
          _waiting?.complete();
          _waiting = null;
        }
      });
      await _waiting!.future;
      if (_cancelled) return;
    }
    final frame = await bridge.capture(mode);
    if (frame == null) return;
    final windows = (frame['windows'] as List? ?? []).map((v) {
      final r = Map<Object?, Object?>.from(v as Map);
      return ui.Rect.fromLTWH(
        (r['x'] as num).toDouble(),
        (r['y'] as num).toDouble(),
        (r['width'] as num).toDouble(),
        (r['height'] as num).toDouble(),
      );
    }).toList();
    final screens = (frame['screens'] as List? ?? []).map((v) {
      final r = Map<Object?, Object?>.from(v as Map);
      return ui.Rect.fromLTWH(
        (r['x'] as num).toDouble(),
        (r['y'] as num).toDouble(),
        (r['width'] as num).toDouble(),
        (r['height'] as num).toDouble(),
      );
    }).toList();
    if (mode == 'color' && frame['pixels'] is Uint8List) {
      final pixels = frame['pixels'] as Uint8List;
      final width = (frame['width'] as num).toInt();
      final height = (frame['height'] as num).toInt();
      if (width <= 0 ||
          height <= 0 ||
          width * height > 100000000 ||
          pixels.length != width * height * 4) {
        throw StateError('取色像素数据无效或屏幕像素过大');
      }
      await _presentClip(
        Clip(
          bytes: Uint8List(0),
          width: width,
          height: height,
          mode: mode,
          windows: windows,
          screens: screens,
          rgbaPixels: pixels,
        ),
      );
    } else {
      await loadBytes(
        frame['bytes'] as Uint8List,
        mode: mode,
        windows: windows,
        screens: screens,
      );
    }
  });
  Future<void> fixScreenColor(SampledColor sample) async {
    resetCaptureMirrors();
    sampledColor = sample;
    clip = null;
    panel = 'color';
    changed();
    await bridge.present('color');
  }

  void cancelCountdown() {
    _cancelled = true;
    _timer?.cancel();
    _waiting?.complete();
    _waiting = null;
    countdown = 0;
    changed();
  }

  Future<void> loadBytes(
    Uint8List bytes, {
    String mode = 'region',
    List<ui.Rect> windows = const [],
    List<ui.Rect> screens = const [],
  }) async {
    final descriptor = await ui.ImmutableBuffer.fromUint8List(bytes);
    final image = await ui.ImageDescriptor.encoded(descriptor);
    try {
      if (image.width * image.height > 100000000) {
        throw StateError('屏幕像素过大，请降低显示器分辨率后重试');
      }
      await _presentClip(
        Clip(
          bytes: bytes,
          width: image.width,
          height: image.height,
          mode: mode,
          windows: windows,
          screens: screens,
        ),
      );
    } finally {
      image.dispose();
      descriptor.dispose();
    }
  }

  Future<void> _presentClip(Clip next) async {
    resetCaptureMirrors();
    clip = next;
    revision++;
    panel = 'capture';
    changed();
    await bridge.present('capture');
    // A resident window may have no vsync while hidden.
    if (!_disposed && hasListeners) {
      WidgetsBinding.instance.scheduleWarmUpFrame();
    }
  }

  Future<void> discard({bool hide = true}) async {
    resetCaptureMirrors();
    cancelCountdown();
    clip = null;
    revision++;
    panel = 'palette';
    sampledColor = null;
    error = null;
    if (hide) await bridge.dismiss();
    changed();
  }

  Future<void> pin(Uint8List bytes, ui.Rect rect, {required bool animate}) =>
      perform(() async {
        await bridge.pin(bytes, {
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
        }, animate);
        await discard();
      });

  Future<void> finish(
    Uint8List bytes, {
    required bool save,
  }) => perform(() async {
    if (save) {
      final name =
          '定格T-${DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first}.png';
      if (await bridge.save(bytes, name) == null) return;
    } else {
      await bridge.copy(bytes);
      try {
        await bridge.notifyCopied();
      } catch (_) {}
    }
    await discard();
  });
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _waiting?.complete();
    DesktopBridge.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
