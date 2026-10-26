import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'desktop_vision_method_channel.dart';
import 'src/models.dart';

abstract class DesktopVisionPlatform extends PlatformInterface {
  /// Constructs a DesktopVisionPlatform.
  DesktopVisionPlatform() : super(token: _token);

  static final Object _token = Object();

  static DesktopVisionPlatform _instance = MethodChannelDesktopVision();

  /// The default instance of [DesktopVisionPlatform] to use.
  ///
  /// Defaults to [MethodChannelDesktopVision].
  static DesktopVisionPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [DesktopVisionPlatform] when
  /// they register themselves.
  static set instance(DesktopVisionPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<bool> isSupported() {
    throw UnimplementedError('isSupported() has not been implemented.');
  }

  Future<OcrEngineInfo> getEngineInfo() {
    throw UnimplementedError('getEngineInfo() has not been implemented.');
  }

  Future<OcrResult> recognizeFile({
    required String path,
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) {
    throw UnimplementedError('recognizeFile() has not been implemented.');
  }

  Future<OcrResult> recognizeBytes({
    required Uint8List bytes,
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) {
    throw UnimplementedError('recognizeBytes() has not been implemented.');
  }
}
