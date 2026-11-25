import 'package:flutter/material.dart';

import '../theme.dart';

/// One quiet status surface for the whole OCR flow; the screenshot stays clear.
class OcrStatus extends StatelessWidget {
  const OcrStatus({
    super.key,
    required this.title,
    required this.detail,
    required this.icon,
    this.attention = false,
  });
  final String title, detail;
  final IconData icon;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: '$title，$detail',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: attention ? cs.errorContainer : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppStyle.controlRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: attention ? cs.onErrorContainer : cs.primary,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: AppStyle.motion(context, 140),
                      child: Text(
                        title,
                        key: ValueKey(title),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: attention ? cs.onErrorContainer : cs.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.3,
                        color: attention
                            ? cs.onErrorContainer
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
