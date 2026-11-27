import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class ShellDestination {
  const ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.page,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Widget page;
}

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.index,
    required this.onSelected,
    required this.destinations,
  });

  final int index;
  final ValueChanged<int> onSelected;
  final List<ShellDestination> destinations;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rail = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void dispose() {
    _rail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < widget.destinations.length && i < 5; i++)
          SingleActivator(
            [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
              LogicalKeyboardKey.digit5,
            ][i],
            control: true,
          ): () => widget.onSelected(i),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              MouseRegion(
                onEnter: (_) => _rail.forward(),
                onExit: (_) => _rail.reverse(),
                child: AnimatedBuilder(
                  animation: _rail,
                  builder: (context, _) {
                    final t = Curves.easeOut.transform(_rail.value);
                    return Container(
                      width: 56 + 128 * t,
                      color: scheme.surfaceContainerLow,
                      child: ClipRect(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Brand(t: t),
                            const SizedBox(height: 4),
                            for (
                              var i = 0;
                              i < widget.destinations.length;
                              i++
                            )
                              _RailItem(
                                destination: widget.destinations[i],
                                selected: i == widget.index,
                                t: t,
                                onTap: () => widget.onSelected(i),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 60,
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: scheme.outlineVariant),
                        ),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.destinations[widget.index].label,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: widget.index,
                        children: [
                          for (final destination in widget.destinations)
                            destination.page,
                        ],
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

class _Brand extends StatelessWidget {
  const _Brand({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(18 - 2 * t, 22, 12, 16),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: 20, color: scheme.primary),
          SizedBox(width: 12 * t),
          SizedBox(
            width: 110 * t,
            child: Opacity(
              opacity: t,
              child: Text(
                'PocketASR',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.t,
    required this.onTap,
  });

  final ShellDestination destination;
  final bool selected;
  final double t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: selected
            ? scheme.onSurface.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: EdgeInsets.only(left: 13 - 5 * t),
              child: Row(
                children: [
                  Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    size: 18,
                    color: foreground,
                  ),
                  SizedBox(width: 12 * t),
                  SizedBox(
                    width: 128 * t,
                    child: Opacity(
                      opacity: t,
                      child: Text(
                        destination.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: selected
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
