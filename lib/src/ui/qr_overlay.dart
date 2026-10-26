import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../qr_scan.dart';
import 'controls.dart';

class QrOverlay extends StatelessWidget {
  const QrOverlay({
    super.key,
    required this.codes,
    required this.onOpen,
    required this.onInspect,
    this.opening,
  });
  final List<QrCode> codes;
  final ValueChanged<int> onOpen, onInspect;
  final int? opening;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = math.min(
        36.0,
        math.min(constraints.maxWidth, constraints.maxHeight),
      );
      return Stack(
        children: [
          // This is a reading mode, so a stray drag does not edit the image below.
          const Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              child: SizedBox.expand(),
            ),
          ),
          for (final (index, code) in codes.indexed)
            Positioned(
              left: (code.center.dx * constraints.maxWidth - side / 2).clamp(
                0,
                constraints.maxWidth - side,
              ),
              top: (code.center.dy * constraints.maxHeight - side / 2).clamp(
                0,
                constraints.maxHeight - side,
              ),
              width: side,
              height: side,
              child: GestureDetector(
                onSecondaryTap: opening != null ? null : () => onInspect(index),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: code.link != null
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ToolButton(
                    key: ValueKey('qr-open-$index'),
                    size: side,
                    primary: code.link != null,
                    label:
                        '${code.link != null ? '打开二维码' : '查看二维码'} ${index + 1}：${code.content}',
                    onPressed: opening != null ? null : () => onOpen(index),
                    child: Center(
                      child: opening == index
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: code.link != null
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : null,
                              ),
                            )
                          : Icon(
                              code.link != null
                                  ? Icons.arrow_outward_rounded
                                  : Icons.text_snippet_outlined,
                              size: 16,
                            ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
