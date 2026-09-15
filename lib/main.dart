import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/theme.dart';
import 'features/models/models_page.dart';
import 'features/settings/settings_page.dart';
import 'features/transcribe/transcribe_page.dart';
import 'l10n/app_localizations.dart';

void main() => runApp(const PocketAsrApp());

/// Root of the app. Owns the single [AppState] and hands it to the tree.
class PocketAsrApp extends StatefulWidget {
  const PocketAsrApp({super.key});

  @override
  State<PocketAsrApp> createState() => _PocketAsrAppState();
}
class _PocketAsrAppState extends State<PocketAsrApp> {
  final AppState _state = AppState();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(notifier: _state, child: const _LocalizedApp());
  }
}

/// Sits below [AppStateScope], so a theme or locale change rebuilds the app.
class _LocalizedApp extends StatelessWidget {
  const _LocalizedApp();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: state.themeMode,
      locale: state.locale, // null = follow the system language
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeShell(),
    );
  }
}

/// Bottom navigation shell. [IndexedStack] keeps every page alive, so state
/// survives tab switches.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Production selects the real engine from AppState (sherpa by default);
    // the page asks it what it can do and stays honest when it cannot run.
    final engine = AppStateScope.of(context).engine;

    // Real feature pages replace the placeholders in later phases.
    final sections = <_Section>[
      _Section(
        navIcon: Icons.mic_none,
        selectedNavIcon: Icons.mic,
        label: l10n.navTranscribe,
        page: TranscribePage(engine: engine),
      ),
      _Section(
        navIcon: Icons.list_alt_outlined,
        selectedNavIcon: Icons.list_alt,
        label: l10n.navQueue,
        page: _PlaceholderPage(
          icon: Icons.playlist_play,
          title: l10n.queueTitle,
          body: l10n.queueBody,
          hint: l10n.comingSoon,
        ),
      ),
      _Section(
        navIcon: Icons.history,
        selectedNavIcon: Icons.history,
        label: l10n.navHistory,
        page: _PlaceholderPage(
          icon: Icons.history,
          title: l10n.historyTitle,
          body: l10n.historyBody,
          hint: l10n.comingSoon,
        ),
      ),
      _Section(
        navIcon: Icons.layers_outlined,
        selectedNavIcon: Icons.layers,
        label: l10n.navModels,
        page: const ModelsPage(),
      ),
      _Section(
        navIcon: Icons.settings_outlined,
        selectedNavIcon: Icons.settings,
        label: l10n.navSettings,
        page: const SettingsPage(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(sections[_index].label)),
      body: IndexedStack(
        index: _index,
        children: [for (final section in sections) section.page],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          for (final section in sections)
            NavigationDestination(
              icon: Icon(section.navIcon),
              selectedIcon: Icon(section.selectedNavIcon),
              label: section.label,
            ),
        ],
      ),
    );
  }
}

class _Section {
  const _Section({
    required this.navIcon,
    required this.selectedNavIcon,
    required this.label,
    required this.page,
  });

  final IconData navIcon;
  final IconData selectedNavIcon;
  final String label;
  final Widget page;
}

/// Empty page with enough structure to look intentional: tonal badge, title,
/// one line of context.
class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({
    required this.icon,
    required this.title,
    required this.body,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String body;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 44, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(height: 28),
              Text(
                title,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Chip(
                avatar: const Icon(Icons.schedule, size: 18),
                label: Text(hint),
                side: BorderSide(color: scheme.outlineVariant),
                backgroundColor: Colors.transparent,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

