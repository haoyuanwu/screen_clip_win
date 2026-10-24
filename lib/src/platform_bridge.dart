import 'package:flutter/services.dart';

class DesktopBridge {
  static const channel = MethodChannel('screenclip/desktop');
  Future<String> launchAtLoginStatus() async =>
      await channel.invokeMethod<String>('launchAtLoginStatus') ?? 'disabled';
  Future<String> setLaunchAtLogin(bool enabled) async =>
      await channel.invokeMethod<String>('setLaunchAtLogin', enabled) ??
      'disabled';
  Future<String> dataDirectory() async =>
      (await channel.invokeMethod<String>('dataDirectory'))!;
  Future<Map<Object?, Object?>?> capture(String mode) =>
      channel.invokeMapMethod<Object?, Object?>('capture', mode);
  Future<String?> save(Uint8List bytes, String name) =>
      channel.invokeMethod<String>('save', {'bytes': bytes, 'name': name});
  Future<void> pin(Uint8List bytes, Map<String, double> rect, bool animate) =>
      channel.invokeMethod('pin', {
        'bytes': bytes,
        ...rect,
        'animate': animate,
      });
  Future<void> copy(Uint8List bytes) => channel.invokeMethod('copy', bytes);
  Future<void> permissions() => channel.invokeMethod('permissions');
  Future<void> present(String panel) => channel.invokeMethod('present', panel);
  Future<void> notifyCopied() => channel.invokeMethod('copied');
  Future<void> dismiss() => channel.invokeMethod('dismiss');
  Future<bool> registerHotkey() async =>
      await channel.invokeMethod<bool>('registerHotkey') ?? false;
}
