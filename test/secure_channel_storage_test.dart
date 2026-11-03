import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/translation/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final calls = <MethodCall>[];
  String? current, legacy;
  bool denied = false;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    calls.clear();
    current = null;
    legacy = null;
    denied = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final options = (call.arguments as Map)['options'] as Map;
          final modern = options['accountName'] == '定格T';
          if (call.method == 'read') {
            if (!modern && denied) throw PlatformException(code: 'denied');
            return modern ? current : legacy;
          }
          if (call.method == 'write') {
            current = (call.arguments as Map)['value'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('New entries use the app service and label', () async {
    await SecureChannelStorage().write('synthetic config');
    final options = (calls.single.arguments as Map)['options'] as Map;
    expect(options['accountName'], '定格T');
    expect(options['label'], '定格T');
  });
  test(
    'Existing credentials migrate once without deleting the old entry',
    () async {
      legacy = 'synthetic existing config';
      final storage = SecureChannelStorage();
      expect(await storage.read(), legacy);
      expect(current, legacy);
      expect(calls.map((c) => c.method), ['read', 'read', 'write']);
      calls.clear();
      expect(await storage.read(), legacy);
      expect(calls.map((c) => c.method), ['read']);
    },
  );
  test(
    'Denied migration does not write or erase existing credentials',
    () async {
      denied = true;
      await expectLater(
        SecureChannelStorage().read(),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.every((c) => c.method == 'read'), true);
      expect(current, isNull);
    },
  );
}
