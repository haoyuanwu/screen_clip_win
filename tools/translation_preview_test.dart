import 'package:screen_clip_win/translation/ui/channel_settings.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:screen_clip_win/translation/ui/translation_panel.dart';
import 'package:screen_clip_win/src/theme.dart';

import '../test/translation_test.dart' show configured;

void main() {
  setUpAll(() async {
    final fonts = {
      'SF Pro Text': '/System/Library/Fonts/SFNS.ttf',
      'PingFang SC': '/System/Library/Fonts/Hiragino Sans GB.ttc',
    };
    for (final entry in fonts.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      final loader = FontLoader(
        entry.key,
      )..addFont(file.readAsBytes().then((data) => ByteData.sublistView(data)));
      await loader.load();
    }
    for (final entry in {
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  for (final dark in [false, true]) {
    for (final compact in [false, true]) {
      testWidgets(
        'Translation visual ${dark ? 'dark' : 'light'} ${compact ? 'compact' : 'wide'}',
        (tester) async {
          final size = compact ? const Size(440, 660) : const Size(900, 660);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = await configured();
          addTearDown(c.dispose);
          c.setSource(
            'Hello world.\nKeep your words, keep your meaning.\n\nTranslate this screenshot into Chinese.',
            label: '来自截图选区 · 可编辑',
          );
          await c.translate();
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: screenClipTheme(dark ? Brightness.dark : Brightness.light),
              home: RepaintBoundary(
                key: key,
                child: TranslationPanel(
                  controller: c,
                  onClose: () {},
                  openUrl: (_) async {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final path =
                'build/translation-previews/${dark ? 'dark' : 'light'}-${compact ? 'compact' : 'wide'}.png';
            await File(path).parent.create(recursive: true);
            await File(path).writeAsBytes(data!.buffer.asUint8List());
          });
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(1.6),
                disableAnimations: true,
              ),
              child: MaterialApp(
                theme: screenClipTheme(
                  dark ? Brightness.dark : Brightness.light,
                ),
                builder: (_, child) => MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: const TextScaler.linear(1.6),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: TranslationPanel(
                  controller: c,
                  onClose: () {},
                  openUrl: (_) async {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final dark in [false, true]) {
    testWidgets('Translation key validation form visual dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(530, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await configured();
      addTearDown(c.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: screenClipTheme(dark ? Brightness.dark : Brightness.light),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: ChannelEditor(
                channel: c.channels.first,
                controller: c,
                onBack: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final verify = find.widgetWithText(OutlinedButton, '验证 API Key');
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(find.text('验证通过，当前 Key 与模型可用'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('build/translation-previews')
          ..createSync(recursive: true);
        await File(
          '${output.path}/key-validation-${dark ? 'dark' : 'light'}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    });
  }
}
