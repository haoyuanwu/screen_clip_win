import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';
import 'service.dart';
import 'argos_engine.dart';

abstract class ChannelStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureChannelStorage implements ChannelStorage {
  // The non-sharing macOS Keychain works with locally signed desktop builds;
  // data-protection keychain would require a distribution provisioning profile.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _key = 'screenclip.translation.settings.v1';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

class TranslationController extends ChangeNotifier {
  TranslationController({ChannelStorage? storage, TranslationService? service})
    : storage = storage ?? SecureChannelStorage(),
      service = service ?? TranslationService();
  final ChannelStorage storage;
  final TranslationService service;
  List<TranslationChannel> _channels = defaultTranslationChannels();
  List<TranslationChannel> get channels => List.unmodifiable(_channels);
  String activeId = 'argos_local';
  bool needsLocalModels = false;
  ArgosOperation? _localProbe;
  TranslationChannel? get activeChannel =>
      _channels.where((c) => c.id == activeId).firstOrNull;
  TranslationLanguage from = TranslationLanguage.auto,
      to = TranslationLanguage.zh;
  bool initialized = false,
      initializing = false,
      saving = false,
      translating = false,
      extracting = false;
  String sourceText = '', sourceLabel = '输入文字', status = '';
  String? error, configError;
  TranslationResult? result;
  TranslationTask? _task;
  int _request = 0;
  bool _disposed = false;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (initialized || initializing) return;
    initializing = true;
    configError = null;
    changed();
    try {
      final raw = await storage.read();
      if (_disposed) return;
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final savedChannels = data['channels'] as List;
        final channels = savedChannels
            .where((v) => (v as Map)['id'] != 'tencent_tmt')
            .map(
              (v) => TranslationChannel.fromJson(
                Map<String, dynamic>.from(v as Map),
              ),
            )
            .toList();
        if (channels.map((c) => c.id).toSet().length != channels.length) {
          throw const FormatException();
        }
        // Append newly shipped presets without replacing saved user settings.
        final ids = channels.map((c) => c.id).toSet();
        _channels = [
          ...channels,
          ...defaultTranslationChannels().where((c) => !ids.contains(c.id)),
        ];
        activeId = data['activeId'] as String? ?? 'argos_local';
        if (!_channels.any((c) => c.id == activeId)) {
          activeId = 'argos_local';
        }
        from =
            TranslationLanguage.values
                .where((v) => v.name == data['from'])
                .firstOrNull ??
            TranslationLanguage.auto;
        to =
            TranslationLanguage.values
                .where(
                  (v) => v.name == data['to'] && v != TranslationLanguage.auto,
                )
                .firstOrNull ??
            TranslationLanguage.zh;
      }
      initialized = true;
    } catch (_) {
      configError = '无法读取翻译安全配置，请确认系统钥匙串可用后重试。未覆盖原配置。';
    } finally {
      initializing = false;
      changed();
    }
  }

  Future<bool> _save(
    List<TranslationChannel> channels,
    String active,
    TranslationLanguage source,
    TranslationLanguage target,
  ) async {
    if (saving) return false;
    if (!initialized) {
      configError = '请先重新读取安全配置，再保存更改';
      changed();
      return false;
    }
    saving = true;
    configError = null;
    changed();
    try {
      await storage.write(
        jsonEncode({
          'version': 1,
          'channels': channels.map((c) => c.toJson()).toList(),
          'activeId': active,
          'from': source.name,
          'to': target.name,
        }),
      );
      if (_disposed) return false;
      cancel(notify: false);
      _channels = channels;
      activeId = active;
      from = source;
      to = target;
      result = null;
      needsLocalModels = false;
      error = null;
      status = '';
      return true;
    } catch (_) {
      configError = '保存失败：无法写入系统安全存储，更改尚未保存，请重试';
      return false;
    } finally {
      saving = false;
      changed();
    }
  }

  Future<bool> saveChannel(TranslationChannel channel) async {
    final next = [..._channels];
    final index = next.indexWhere((c) => c.id == channel.id);
    if (index < 0) {
      next.add(channel);
    } else {
      next[index] = channel;
    }
    return _save(
      next,
      activeId.isEmpty || activeChannel?.configured != true
          ? channel.id
          : activeId,
      from,
      to,
    );
  }

  Future<bool> removeChannel(String id) async {
    final next = _channels.where((c) => c.id != id).toList();
    final active = id == activeId
        ? next.where((c) => c.configured && c.isEnabled).firstOrNull?.id ??
              next.firstOrNull?.id ??
              ''
        : activeId;
    return _save(next, active, from, to);
  }

  Future<bool> selectChannel(String id) => _save(_channels, id, from, to);
  Future<bool> languages(
    TranslationLanguage source,
    TranslationLanguage target,
  ) => _save(_channels, activeId, source, target);
  void setSource(String text, {String? label}) {
    cancel(notify: false);
    sourceText = text;
    sourceLabel = label ?? sourceLabel;
    result = null;
    error = null;
    status = '';
    changed();
  }

  Future<void> extract(Future<String> Function() action) async {
    cancel(notify: false);
    final request = ++_request;
    extracting = true;
    error = null;
    result = null;
    sourceText = '';
    sourceLabel = '截图选区 · 可编辑';
    changed();
    try {
      final text = await action();
      if (_disposed || request != _request) return;
      if (text.trim().isEmpty) {
        throw const TranslationException('选区中没有识别到文字，可重新框选或直接输入');
      }
      sourceText = text;
    } catch (_) {
      if (!_disposed && request == _request) error = '无法提取选区文字，请重新框选或直接输入原文';
    } finally {
      if (request == _request) extracting = false;
      changed();
    }
  }

  Future<void> translate({List<String>? segments}) async {
    if (translating || extracting) return;
    final channel = activeChannel;
    if (channel?.isLocal == true && !channel!.configured && channel.isEnabled) {
      needsLocalModels = true;
      error = '尚未下载中英语言包，下载后即可离线翻译';
      changed();
      return;
    }
    if (channel == null || !channel.configured || !channel.isEnabled) {
      error = '请先配置并启用翻译渠道';
      changed();
      return;
    }
    if (sourceText.trim().isEmpty || sourceText.length > 12000) {
      error = '请输入 1–12,000 个字符的原文';
      changed();
      return;
    }
    final request = ++_request;
    translating = true;
    error = null;
    result = null;
    status = '正在通过 ${channel.name} 翻译';
    changed();
    try {
      if (channel.isLocal) {
        final probe = _localProbe = service.argos.run({'command': 'status'});
        final state = await probe.future;
        _localProbe = null;
        if (_disposed || request != _request) return;
        if (state['ready'] != true) {
          needsLocalModels = true;
          throw const TranslationException('语言包不存在，请先下载中英语言包');
        }
      }
      final task = _task = service.start(
        text: sourceText,
        from: from,
        to: to,
        channel: channel,
        segments: segments,
      );
      final translated = await task.future;
      if (_disposed || request != _request) return;
      result = translated;
      status = '翻译完成';
    } on TranslationCancelled {
      if (request == _request) status = '已取消，可继续编辑原文';
    } on TranslationException catch (e) {
      if (request == _request) error = e.message;
    } catch (_) {
      if (request == _request) error = '翻译失败，请检查网络与渠道配置后重试';
    } finally {
      if (request == _request) {
        translating = false;
        _task = null;
      }
      changed();
    }
  }

  void cancel({bool notify = true}) {
    _request++;
    _localProbe?.cancel();
    _localProbe = null;
    _task?.cancel();
    _task = null;
    if (translating || extracting) status = '已取消，可继续编辑原文';
    translating = false;
    extracting = false;
    if (notify) changed();
  }

  void clear() {
    setSource('', label: '输入文字');
  }

  @override
  void dispose() {
    _disposed = true;
    service.dispose();
    cancel(notify: false);
    super.dispose();
  }
}
