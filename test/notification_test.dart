import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/theme.dart';
import 'package:screen_clip_win/src/ui/controls.dart';
import 'package:screen_clip_win/src/workspace.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'floating notification preserves layout and copies complete details in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(440, 320);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final c = ClipController()..ready = true;
        addTearDown(c.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: screenClipTheme(brightness),
            home: RepaintBoundary(
              key: key,
              child: ListenableBuilder(
                listenable: c,
                builder: (_, _) => Workspace(controller: c),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final original = tester.getTopLeft(find.byTooltip('偏好设置'));
        final message =
            '系统拒绝当前应用的屏幕录制访问。\n${List.filled(8, '请完全退出应用，再重新打开并截图授权。').join('\n')}\ntccutil reset ScreenCapture com.example.screenClipWin\n当前运行位置：/Users/why/Documents/Project/screen_clip/build/macos/Build/Products/Debug/screen_clip_win.app';
        c.error = message;
        c.changed();
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byTooltip('偏好设置')), original);
        expect(find.byType(SelectableText), findsOneWidget);
        final card = tester.getRect(find.byType(FloatingErrorNotification));
        expect(card.right, 428);
        expect(card.top, 12);
        expect(card.bottom, lessThan(320));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File('/tmp/screen-clip-notification-${brightness.name}.png')
              .writeAsBytes(png.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.byTooltip('复制提示'));
        await tester.pumpAndSettle();
        expect(clipboard, message);
        expect(find.byTooltip('已复制提示'), findsOneWidget);
        await tester.pump(const Duration(seconds: 10));
        expect(find.byType(FloatingErrorNotification), findsOneWidget);
        await tester.tap(find.byTooltip('关闭提示'));
        await tester.pumpAndSettle();
        expect(c.error, isNull);
        expect(find.byType(FloatingErrorNotification), findsNothing);
      },
    );
  }
}
