import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../src/platform_bridge.dart';
import 'models.dart';

class ArgosOperation {
  ArgosOperation(this.future, this.cancel);
  final Future<Map<String, dynamic>> future;
  final void Function() cancel;
}

/// Same pipe protocol on Windows and macOS; never uses a shell or text files.
class ArgosEngine {
  ArgosEngine({
    this.executable,
    this.directory,
    this.prefixArguments = const [],
  });
  final String? executable, directory;
  final List<String> prefixArguments;
  final Set<void Function()> _cancellations = {};
  static String bundledExecutable(String appExecutable, {required bool macOS}) {
    final parent = File(appExecutable).parent;
    return macOS
        ? '${parent.parent.path}/Helpers/argos/screenclip_argos'
        : '${parent.path}/argos/screenclip_argos.exe';
  }

  ArgosOperation run(
    Map<String, Object?> request, {
    void Function(String, double?)? onProgress,
    Duration timeout = const Duration(minutes: 3),
  }) {
    Process? process;
    var cancelled = false;
    final cancellation = Completer<Map<String, dynamic>>();
    void cancel() {
      if (cancelled) return;
      cancelled = true;
      process?.kill();
      if (!cancellation.isCompleted) {
        cancellation.completeError(const TranslationCancelled());
      }
    }

    _cancellations.add(cancel);
    Future<Map<String, dynamic>> execute() async {
      final executablePath =
          executable ??
          bundledExecutable(
            Platform.resolvedExecutable,
            macOS: Platform.isMacOS,
          );
      if (!await File(executablePath).exists()) {
        throw const TranslationException('此安装包未包含本地翻译引擎，请安装带本地翻译的定格T');
      }
      final data =
          directory ?? '${await DesktopBridge().dataDirectory()}/argos';
      if (cancelled) throw const TranslationCancelled();
      try {
        process = await Process.start(executablePath, [
          ...prefixArguments,
          '--data-dir',
          data,
        ], runInShell: false);
        if (cancelled) {
          process!.kill();
          throw const TranslationCancelled();
        }
        // Drain native diagnostics without retaining the original text or logs.
        final errors = process!.stderr.drain<void>();
        final lines = process!.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        process!.stdin.write(jsonEncode(request));
        await process!.stdin.close();
        Map<String, dynamic>? result;
        var outputBytes = 0;
        await for (final line in lines) {
          outputBytes += line.length;
          if (outputBytes > 2 * 1024 * 1024) {
            throw const TranslationException('本地引擎返回内容过大');
          }
          final event = jsonDecode(line) as Map<String, dynamic>;
          switch (event['event']) {
            case 'progress':
              onProgress?.call(
                event['message'] as String,
                (event['progress'] as num?)?.toDouble(),
              );
            case 'result':
              result = event;
            case 'error':
              throw TranslationException(event['message'] as String);
          }
        }
        final code = await process!.exitCode;
        await errors;
        if (cancelled) throw const TranslationCancelled();
        if (code != 0 || result == null) {
          throw const TranslationException('本地引擎未返回结果，请重新准备语言包');
        }
        return result;
      } on ProcessException {
        throw const TranslationException('无法启动本地引擎，请检查系统架构和安装包');
      } on FormatException {
        throw const TranslationException('本地引擎返回格式错误');
      } finally {
        process?.kill();
      }
    }

    final future = Future.any([execute(), cancellation.future])
        .timeout(
          timeout,
          onTimeout: () {
            cancel();
            throw const TranslationException('本地操作超时，请重试');
          },
        )
        .whenComplete(() => _cancellations.remove(cancel));
    return ArgosOperation(future, cancel);
  }

  void dispose() {
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
  }
}
