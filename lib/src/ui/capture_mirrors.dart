import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../platform_bridge.dart';
import 'color_preview.dart' show liveColorPreviewKey;

bool _captureReady = false;
void scheduleCaptureFrame() {
  final binding = WidgetsBinding.instance;
  if (binding.framesEnabled) {
    binding.scheduleFrame();
  } else {
    // Separate display panels can occlude the backing Flutter window. Input
    // still arrives, but the normal hidden-lifecycle scheduler drops redraws.
    binding.scheduleWarmUpFrame();
  }
}

void markCaptureMirrorsReady() {
  _captureReady = true;
  scheduleCaptureFrame();
}

void resetCaptureMirrors() {
  _captureReady = false;
  resetCapturePointer();
}

// macOS clips a window to one display when displays have separate Spaces.
// Other displays present crops of the same editor layer in native panels.
// Cropping the retained layer avoids rasterizing the whole desktop again.
class CaptureMirrors extends StatefulWidget {
  const CaptureMirrors({
    super.key,
    required this.active,
    required this.revision,
    required this.child,
    this.colorOnly = false,
  });
  final bool active;
  final int revision;
  final Widget child;
  final bool colorOnly;
  @override
  State<CaptureMirrors> createState() => _CaptureMirrorsState();
}

class _CaptureMirrorsState extends State<CaptureMirrors> {
  final boundary = GlobalKey();
  List<Map> layouts = [];
  int generation = 0;
  Object? session;
  bool copying = false;
  bool dirty = false;
  Timer? trailing;
  DateTime lastCopy = DateTime(2000);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      if (mounted && widget.active && layouts.isNotEmpty) {
        dirty = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => copyFrame());
      }
    });
    configure();
  }

  @override
  void didUpdateWidget(CaptureMirrors oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active ||
        widget.revision != oldWidget.revision) {
      configure();
    }
  }

  Future<void> configure() async {
    final epoch = ++generation;
    layouts = [];
    trailing?.cancel();
    if (!widget.active || !Platform.isMacOS) return;
    try {
      final data = await DesktopBridge.channel
          .invokeMapMethod<Object?, Object?>('captureMirrorLayouts');
      if (!mounted || epoch != generation || data == null) return;
      session = data['session'];
      layouts = (data['screens'] as List).cast<Map>();
      WidgetsBinding.instance.scheduleWarmUpFrame();
    } catch (_) {
      /* Windows and test bridges don't use native mirrors. */
    }
  }

  Future<void> copyFrame() async {
    if (!mounted ||
        !widget.active ||
        !_captureReady ||
        layouts.isEmpty ||
        copying) {
      return;
    }
    final elapsed = DateTime.now().difference(lastCopy);
    final interval = widget.colorOnly ? 16 : 33;
    if (elapsed.inMilliseconds < interval) {
      trailing?.cancel();
      trailing = Timer(
        Duration(milliseconds: interval - elapsed.inMilliseconds),
        () {
          if (!mounted || !widget.active) return;
          WidgetsBinding.instance.addPostFrameCallback((_) => copyFrame());
          scheduleCaptureFrame();
        },
      );
      return;
    }
    final render = boundary.currentContext?.findRenderObject();
    if (render is! _CaptureBoundaryRender) {
      return;
    }
    final epoch = generation;
    copying = true;
    dirty = false;
    trailing?.cancel();
    lastCopy = DateTime.now();
    try {
      Rect? preview;
      if (widget.colorOnly) {
        final box = liveColorPreviewKey.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return;
        preview = (box.localToGlobal(Offset.zero) & box.size).inflate(24);
      }
      for (final screen in layouts) {
        final display = Rect.fromLTWH(
          (screen['x'] as num).toDouble(),
          (screen['y'] as num).toDouble(),
          (screen['width'] as num).toDouble(),
          (screen['height'] as num).toDouble(),
        );
        if (preview != null && !display.contains(preview.center)) continue;
        final rect = preview == null ? display : preview.intersect(display);
        final image = await render.capture(
          rect,
          pixelRatio: (screen['scale'] as num).toDouble(),
        );
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final width = image.width, height = image.height;
        image.dispose();
        if (!mounted || generation != epoch) return;
        if (bytes != null) {
          await DesktopBridge.channel.invokeMethod<void>(
            'updateCaptureMirror',
            {
              'session': session,
              'displayId': screen['displayId'],
              'bytes': bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
              'width': width,
              'height': height,
              if (preview != null) ...{
                'overlay': true,
                'left': rect.left - display.left,
                'top': rect.top - display.top,
                'logicalWidth': rect.width,
                'logicalHeight': rect.height,
              },
            },
          );
        }
      }
    } catch (_) {
      /* A capture may close while its frame is being copied. */
    } finally {
      copying = false;
      if (mounted && widget.active && dirty) {
        scheduleCaptureFrame();
      }
    }
  }

  @override
  void dispose() {
    generation++;
    trailing?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _CaptureBoundary(key: boundary, child: widget.child);
}

class _CaptureBoundary extends SingleChildRenderObjectWidget {
  const _CaptureBoundary({super.key, required super.child});
  @override
  _CaptureBoundaryRender createRenderObject(BuildContext context) =>
      _CaptureBoundaryRender();
}

class _CaptureBoundaryRender extends RenderRepaintBoundary {
  Future<ui.Image> capture(Rect rect, {required double pixelRatio}) =>
      (layer! as OffsetLayer).toImage(rect, pixelRatio: pixelRatio);
}

int _buttons = 0;
bool _added = false;
Offset _position = Offset.zero;
const _device = 7001;
void dispatchCapturePointer(Map args) {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return;
  final binding = GestureBinding.instance;
  final p = Offset(
    (args['x'] as num).toDouble(),
    (args['y'] as num).toDouble(),
  );
  final delta = p - _position;
  _position = p;
  final time = Duration(
    microseconds: ((args['time'] as num) * 1000000).round(),
  );
  if (!_added) {
    binding.handlePointerEvent(
      PointerAddedEvent(
        viewId: view.viewId,
        device: _device,
        kind: PointerDeviceKind.mouse,
        position: p,
        timeStamp: time,
      ),
    );
    _added = true;
  }
  final buttons = (args['buttons'] as num).toInt();
  final type = args['type'];
  PointerEvent event;
  if (type == 'scroll') {
    event = PointerScrollEvent(
      viewId: view.viewId,
      device: _device,
      kind: PointerDeviceKind.mouse,
      position: p,
      timeStamp: time,
      scrollDelta: Offset(
        (args['scrollX'] as num).toDouble(),
        (args['scrollY'] as num).toDouble(),
      ),
    );
  } else if (_buttons == 0 && buttons != 0) {
    event = PointerDownEvent(
      viewId: view.viewId,
      pointer: _device,
      device: _device,
      kind: PointerDeviceKind.mouse,
      position: p,
      buttons: buttons,
      timeStamp: time,
    );
  } else if (_buttons != 0 && buttons == 0) {
    event = PointerUpEvent(
      viewId: view.viewId,
      pointer: _device,
      device: _device,
      kind: PointerDeviceKind.mouse,
      position: p,
      timeStamp: time,
    );
  } else if (buttons != 0) {
    event = PointerMoveEvent(
      viewId: view.viewId,
      pointer: _device,
      device: _device,
      kind: PointerDeviceKind.mouse,
      position: p,
      delta: delta,
      buttons: buttons,
      timeStamp: time,
    );
  } else {
    event = PointerHoverEvent(
      viewId: view.viewId,
      device: _device,
      kind: PointerDeviceKind.mouse,
      position: p,
      delta: delta,
      timeStamp: time,
    );
  }
  if (type != 'scroll') _buttons = buttons;
  binding.handlePointerEvent(event);
  scheduleCaptureFrame();
}

void resetCapturePointer() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (_added && view != null) {
    if (_buttons != 0) {
      GestureBinding.instance.handlePointerEvent(
        PointerCancelEvent(
          viewId: view.viewId,
          pointer: _device,
          device: _device,
          kind: PointerDeviceKind.mouse,
          position: _position,
        ),
      );
    }
    GestureBinding.instance.handlePointerEvent(
      PointerRemovedEvent(
        viewId: view.viewId,
        device: _device,
        kind: PointerDeviceKind.mouse,
        position: _position,
      ),
    );
  }
  _added = false;
  _buttons = 0;
}
