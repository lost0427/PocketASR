import 'package:material_ui/material_ui.dart';

class TimelineStrip extends StatelessWidget {
  const TimelineStrip({super.key, required this.progress, this.total});

  /// 0..1, or null when no run has started.
  final double? progress;

  /// Audio length, when it is actually known.
  final Duration? total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = progress?.clamp(0.0, 1.0).toDouble();
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'Consolas',
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('00:00', style: mono),
            const Spacer(),
            Text(total == null ? '--:--' : _clock(total!), style: mono),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 24,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 11,
                    child: Container(height: 1, color: scheme.outlineVariant),
                  ),
                  for (var i = 0; i <= 20; i++)
                    Positioned(
                      left: (width * i / 20).clamp(0.0, width - 1),
                      top: i % 5 == 0 ? 6 : 8,
                      child: Container(
                        width: 1,
                        height: i % 5 == 0 ? 12 : 8,
                        color: scheme.outlineVariant,
                      ),
                    ),
                  if (value != null) ...[
                    Positioned(
                      left: 0,
                      top: 10,
                      width: width * value,
                      child: Container(height: 3, color: scheme.primary),
                    ),
                    Positioned(
                      left: (width * value - 5).clamp(0.0, width - 10),
                      top: 4,
                      child: Container(
                        width: 10,
                        height: 15,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  static String _clock(Duration value) {
    final minutes = value.inMinutes.toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
