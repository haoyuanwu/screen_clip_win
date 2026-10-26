import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zxing/flutter_zxing.dart' as zx;
import 'package:screen_clip_win/src/controller.dart';
import 'package:screen_clip_win/src/editor.dart';
import 'package:screen_clip_win/src/qr_scan.dart';
import 'package:screen_clip_win/src/ui/qr_overlay.dart';

import 'widget_test.dart' show FakeBridge, sample;

QrCode code(String content, double x, double y) => QrCode(content, [
  Offset(x - .08, y - .08),
  Offset(x + .08, y - .08),
  Offset(x + .08, y + .08),
  Offset(x - .08, y + .08),
]);

class QrBridge extends FakeBridge {
  QrBridge() : super('unused');
  List<QrCode> results = [
    code('https://example.com/a', .25, .25),
    code('https://example.com/a', .75, .25),
    code('plain text', .5, .7),
  ];
  final opened = <Uri>[];
  Uint8List? scanned;
  bool failScan = false, failOpen = false;
  int dismissals = 0, saves = 0;
  @override
  Future<void> dismiss() async {
    dismissals++;
    await super.dismiss();
  }

  @override
  Future<String?> save(Uint8List bytes, String name) async {
    saves++;
    return null;
  }

  @override
  Future<List<QrCode>> scanQrCodes(Uint8List bytes) async {
    scanned = bytes;
    if (failScan) throw StateError('scan');
    return results;
  }

  @override
  Future<void> openBrowser(Uri url) async {
    if (failOpen) throw PlatformException(code: 'url');
    opened.add(url);
  }
}

void main() {
  test('Multiple QR positions preserve repeated contents and validate browser links', () {
    zx.Code positioned(int x) => zx.Code(
      text: 'https://example.com',
      isValid: true,
      position: zx.Position(400, 200, x, 20, x + 80, 20, x, 100, x + 80, 100),
    );
    final codes = qrResults(
      zx.Codes(
        codes: [
          positioned(20),
          positioned(240),
          zx.Code(text: 'invalid'),
        ],
      ),
    );
    expect(codes, hasLength(2));
    expect(codes[0].center.dx, closeTo(.15, .00001));
    expect(codes[0].center.dy, closeTo(.3, .00001));
    expect(codes[1].center.dx, closeTo(.7, .00001));
    expect(browserLink('www.example.com/path')?.scheme, 'https');
    expect(browserLink('https://example.com/path?q=1#x')?.host, 'example.com');
    for (final text in [
      'hello',
      'javascript:alert(1)',
      'file:///tmp/a',
      'https://bad host',
    ]) {
      expect(browserLink(text), isNull);
    }
  });
  for (final outcome in ['multiple', 'empty', 'error']) {
    testWidgets(
      'QR scanning handles $outcome with correctly placed, independent buttons',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = QrBridge()..failScan = outcome == 'error';
        if (outcome == 'empty') bridge.results = [];
        final c = ClipController(bridge: bridge)..ready = true;
        addTearDown(c.dispose);
        late Clip clip;
        await tester.runAsync(() async {
          final im = await sample(width: 800, height: 600);
          clip = Clip(
            bytes: (await im.toByteData(format: ui.ImageByteFormat.png))!.buffer
                .asUint8List(),
            width: 800,
            height: 600,
            mode: 'screen',
          );
          im.dispose();
        });
        c.clip = clip;
        await tester.pumpWidget(
          MaterialApp(
            home: CaptureEditor(clip: clip, controller: c),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('扫描二维码'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(bridge.scanned, isNotNull);
        expect(bridge.opened, isEmpty);
        if (outcome == 'error') {
          expect(find.text('二维码扫描失败，请重试'), findsOneWidget);
        } else if (outcome == 'empty') {
          expect(find.text('未发现二维码'), findsOneWidget);
        } else {
          expect(find.byType(QrOverlay), findsOneWidget);
          expect(
            tester.getCenter(find.byKey(const ValueKey('qr-open-0'))),
            const Offset(200, 150),
          );
          expect(
            tester.getCenter(find.byKey(const ValueKey('qr-open-1'))),
            const Offset(600, 150),
          );
          bridge.failOpen = true;
          await tester.tap(find.byKey(const ValueKey('qr-open-0')));
          await tester.pumpAndSettle();
          expect(find.textContaining('内容打开失败'), findsOneWidget);
          bridge.failOpen = false;
          await tester.tap(find.byKey(const ValueKey('qr-open-2')));
          await tester.pumpAndSettle();
          expect(find.text('二维码内容'), findsOneWidget);
          expect(find.text('plain text'), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          expect(c.clip, same(clip));
          tester.view.physicalSize = const Size(400, 300);
          await tester.pumpAndSettle();
          expect(
            tester.getCenter(find.byKey(const ValueKey('qr-open-0'))),
            const Offset(100, 75),
          );
          final clipboard = Uint8List.fromList([7, 8, 9]);
          bridge.copied = clipboard;
          await tester.tap(find.byKey(const ValueKey('qr-open-1')));
          await tester.pumpAndSettle();
          expect(bridge.opened.map((u) => u.toString()), [
            'https://example.com/a',
          ]);
          expect(c.clip, isNull);
          expect(c.panel, 'palette');
          expect(bridge.hidden, true);
          expect(bridge.dismissals, 1);
          expect(bridge.copied, same(clipboard));
          expect(bridge.saves, 0);
          expect(tester.takeException(), isNull);
          return;
        }
        await tester.tap(find.byTooltip('退出二维码扫描'));
        await tester.pumpAndSettle();
        expect(find.byType(QrOverlay), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
