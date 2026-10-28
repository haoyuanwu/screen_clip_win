import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

String? validateTmtEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      !RegExp(r'^tmt(?:\.[a-z0-9-]+)?\.tencentcloudapi\.com$')
          .hasMatch(uri.host)) {
    return '请填写腾讯云 TMT 域名，例如 https://tmt.tencentcloudapi.com';
  }
  return null;
}

/// TC3 signs the exact UTF-8 payload sent on the wire, with a UTC date.
Map<String, String> tmtSignedHeaders({
  required TranslationChannel channel,
  required String body,
  required DateTime now,
}) {
  final timestamp = now.toUtc().millisecondsSinceEpoch ~/ 1000;
  final date = DateTime.fromMillisecondsSinceEpoch(
    timestamp * 1000,
    isUtc: true,
  ).toIso8601String().substring(0, 10);
  final host = Uri.parse(channel.baseUrl.trim()).host;
  const contentType = 'application/json; charset=utf-8';
  const signed = 'content-type;host;x-tc-action';
  final canonical =
      'POST\n/\n\ncontent-type:$contentType\nhost:$host\nx-tc-action:texttranslate\n\n$signed\n${sha256.convert(utf8.encode(body))}';
  final scope = '$date/tmt/tc3_request';
  final toSign =
      'TC3-HMAC-SHA256\n$timestamp\n$scope\n${sha256.convert(utf8.encode(canonical))}';
  List<int> hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;
  final dateKey = hmac(utf8.encode('TC3${channel.apiKey.trim()}'), date);
  final serviceKey = hmac(dateKey, 'tmt');
  final signingKey = hmac(serviceKey, 'tc3_request');
  final signature = Hmac(sha256, signingKey).convert(utf8.encode(toSign));
  return {
    'Content-Type': contentType,
    'Host': host,
    'X-TC-Action': 'TextTranslate',
    'X-TC-Version': '2018-03-21',
    'X-TC-Region': channel.region.trim(),
    'X-TC-Timestamp': '$timestamp',
    'Authorization':
        'TC3-HMAC-SHA256 Credential=${channel.secretId.trim()}/$scope, SignedHeaders=$signed, Signature=$signature',
  };
}

/// Bound by UTF-16 units (conservative for the API's 2,000-character limit)
/// without separating a Unicode scalar. Prefer existing paragraph boundaries.
List<String> tmtChunks(String text) {
  final chunks = <String>[];
  var remaining = text;
  while (remaining.length > 2000) {
    var end = 2000;
    final unit = remaining.codeUnitAt(end - 1);
    if (unit >= 0xd800 && unit <= 0xdbff) end--;
    final newline = remaining.lastIndexOf('\n', end - 1);
    if (newline >= end ~/ 2) end = newline + 1;
    chunks.add(remaining.substring(0, end));
    remaining = remaining.substring(end);
  }
  if (remaining.isNotEmpty) chunks.add(remaining);
  return chunks;
}

String tmtErrorMessage(String code) {
  if (code.startsWith('AuthFailure')) {
    return '腾讯云认证失败，请检查 SecretId、SecretKey、密钥权限与系统时间';
  }
  if (code.contains('UserNotRegistered')) return '腾讯云机器翻译尚未开通，请先在 TMT 控制台开通服务';
  if (code.contains('NoFreeAmount') ||
      code.contains('ServiceIsolate') ||
      code.contains('NoBalance')) {
    return '腾讯云翻译额度不足或已停服，请检查账户余额与资源包';
  }
  if (code.startsWith('LimitExceeded') ||
      code.startsWith('RequestLimitExceeded')) {
    return '腾讯云请求频率受限，请稍后重试';
  }
  if (code.contains('TextTooLong')) return '腾讯云文本超过单次限制，请缩短原文后重试';
  if (code.contains('UnsupportedLanguage')) return '腾讯云不支持当前语言组合，请更换源语言或目标语言';
  if (code.contains('InvalidRegion')) return '腾讯云地域无效，请检查 Region 配置';
  if (code.startsWith('UnauthorizedOperation')) return '腾讯云密钥无机器翻译权限，请检查账号授权';
  return '腾讯云翻译失败，请检查服务开通状态、地域及项目配置';
}

Future<TranslationResult> translateTmt({
  required http.Client client,
  required Future<void> abort,
  required String text,
  required TranslationLanguage from,
  required TranslationLanguage to,
  required TranslationChannel channel,
  required DateTime Function() now,
  List<String>? segments,
}) async {
  final invalid = validateTmtEndpoint(channel.baseUrl);
  if (invalid != null) throw TranslationException(invalid);
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$')
          .hasMatch(channel.region.trim()) ||
      channel.projectId < 0) {
    throw const TranslationException('请填写有效地域和非负项目 ID');
  }
  final watch = Stopwatch()..start();
  var cancelled = false;
  unawaited(abort.then((_) => cancelled = true));
  var requests = 0;
  final outputs = <String>[];
  try {
    for (final source in segments ?? [text]) {
      final translated = StringBuffer();
      for (final chunk in tmtChunks(source)) {
        if (cancelled) throw const TranslationCancelled();
        if (chunk.trim().isEmpty) {
          translated.write(chunk);
          continue;
        }
        if (requests++ > 0) {
          // Space requests; a cancellation must not launch another API call.
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 220)),
            abort,
          ]);
          if (cancelled) throw const TranslationCancelled();
        }
        final leading = RegExp(r'^\s*').stringMatch(chunk)!;
        final trailing = RegExp(r'\s*$').firstMatch(chunk)!.group(0)!;
        final body = jsonEncode({
          'SourceText': chunk.trim(),
          'Source': from.name,
          'Target': to.name,
          'ProjectId': channel.projectId,
        });
        final request =
            http.AbortableRequest(
                'POST',
                Uri.parse(
                  '${channel.baseUrl.trim().replaceFirst(RegExp(r'/$'), '')}/',
                ),
                abortTrigger: abort,
              )
              ..followRedirects = false
              ..headers.addAll(
                tmtSignedHeaders(channel: channel, body: body, now: now()),
              )
              ..bodyBytes = utf8.encode(body);
        final response = await client.send(request);
        final buffer = BytesBuilder(copy: false);
        await for (final bytes in response.stream) {
          if (buffer.length + bytes.length > 2 * 1024 * 1024) {
            throw const TranslationException('腾讯云返回内容过大，请缩短原文后重试');
          }
          buffer.add(bytes);
        }
        if (response.statusCode != 200) {
          throw TranslationException(switch (response.statusCode) {
            401 || 403 => '腾讯云认证失败，请检查密钥及机器翻译权限',
            429 => '腾讯云请求频率受限，请稍后重试',
            >= 500 => '腾讯云翻译暂不可用，请稍后重试',
            _ => '腾讯云请求失败，请检查服务地址和网络',
          });
        }
        final envelope = jsonDecode(utf8.decode(buffer.takeBytes())) as Map;
        final data = envelope['Response'] as Map;
        if (data['Error'] is Map) {
          throw TranslationException(
            tmtErrorMessage((data['Error'] as Map)['Code'] as String? ?? ''),
          );
        }
        final target = data['TargetText'];
        if (target is! String || target.trim().isEmpty) {
          throw const TranslationException('腾讯云未返回有效译文');
        }
        translated
          ..write(leading)
          ..write(target.trim())
          ..write(trailing);
      }
      outputs.add(translated.toString());
    }
  } on TranslationException {
    rethrow;
  } on TranslationCancelled {
    rethrow;
  } on http.RequestAbortedException {
    throw const TranslationCancelled();
  } on SocketException {
    throw const TranslationException('无法连接腾讯云，请检查网络');
  } on http.ClientException {
    throw const TranslationException('腾讯云连接失败，请检查网络和服务地址');
  } on FormatException {
    throw const TranslationException('腾讯云返回格式错误，请稍后重试');
  } on TypeError {
    throw const TranslationException('腾讯云返回结构不兼容，请检查 TMT 服务');
  }
  return TranslationResult(
    originalText: text,
    translatedText: segments == null ? outputs.single : jsonEncode(outputs),
    channelName: channel.name,
    from: from,
    to: to,
    duration: watch.elapsed,
  );
}
