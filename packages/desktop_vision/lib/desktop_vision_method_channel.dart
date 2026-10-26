import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_vision_platform_interface.dart';
import 'src/models.dart';

/// An implementation of [DesktopVisionPlatform] that uses method channels.
class MethodChannelDesktopVision extends DesktopVisionPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('desktop_vision');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<bool> isSupported() async {
    final supported = await methodChannel.invokeMethod<bool>('isSupported');
    return supported ?? false;
  }

  @override
  Future<OcrEngineInfo> getEngineInfo() async {
    final map = await methodChannel.invokeMapMethod<dynamic, dynamic>(
      'getEngineInfo',
    );
    if (map == null) {
      throw PlatformException(
        code: 'no_result',
        message: 'getEngineInfo 未返回有效数据',
      );
    }
    return OcrEngineInfo.fromMap(map);
  }

  @override
  Future<OcrResult> recognizeFile({
    required String path,
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) async {
    final map = await methodChannel.invokeMapMethod<dynamic, dynamic>(
      'recognizeFile',
      <String, dynamic>{
        'path': path,
        'languages': languages,
        'level': level.nativeValue,
      },
    );
    if (map == null) {
      throw PlatformException(
        code: 'no_result',
        message: 'recognizeFile 未返回有效数据',
      );
    }
    return OcrResult.fromMap(map);
  }

  @override
  Future<OcrResult> recognizeBytes({
    required Uint8List bytes,
    List<String> languages = const <String>[],
    OcrLevel level = OcrLevel.accurate,
  }) async {
    final map = await methodChannel.invokeMapMethod<dynamic, dynamic>(
      'recognizeBytes',
      <String, dynamic>{
        'bytes': bytes,
        'languages': languages,
        'level': level.nativeValue,
      },
    );
    if (map == null) {
      throw PlatformException(
        code: 'no_result',
        message: 'recognizeBytes 未返回有效数据',
      );
    }
    return OcrResult.fromMap(map);
  }
}
