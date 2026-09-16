import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_state.dart';
import 'app/theme.dart';
import 'data/db.dart';
import 'features/models/models_page.dart';
import 'features/models/model_library.dart';
import 'features/history/history_page.dart';
import 'features/queue/queue_page.dart';
import 'features/settings/settings_page.dart';
import 'features/transcribe/transcribe_page.dart';
import 'l10n/app_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await getApplicationDocumentsDirectory();
  runApp(
    PocketAsrApp(
      database: AppDatabase.open(
        path: '${directory.path}${Platform.pathSeparator}pocket_asr.sqlite',
      ),
    ),
  );
}

/// Root of the app. Owns the single [AppState] and hands it to the tree.
class PocketAsrApp extends StatefulWidget {
  const PocketAsrApp({super.key, this.database, this.modelLibrary});

  final AppDatabase? database;
  final ModelLibrary? modelLibrary;

  @override
  State<PocketAsrApp> createState() => _PocketAsrAppState();
}

class _PocketAsrAppState extends State<PocketAsrApp> {
  late final AppState _state = AppState(database: widget.database);

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: _state,
      child: _LocalizedApp(modelLibrary: widget.modelLibrary),
    );
  }
}

/// Sits below [AppStateScope], so a theme or locale change rebuilds the app.
class _LocalizedApp extends StatelessWidget {
  const _LocalizedApp({this.modelLibrary});

  final ModelLibrary? modelLibrary;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Platform.isWindows
          ? ExcludeSemantics(child: child ?? const SizedBox.shrink())
          : child ?? const SizedBox.shrink(),
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: state.themeMode,
      locale: state.locale, // null = follow the system language
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomeShell(modelLibrary: modelLibrary),
    );
  }
}

/// Bottom navigation shell. [IndexedStack] keeps every page alive, so state
/// survives tab switches.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.modelLibrary});

  final ModelLibrary? modelLibrary;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final ModelLibrary _modelLibrary =
      widget.modelLibrary ?? ModelLibrary.local();

  void _openModels() => setState(() => _index = 3);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Production selects the real engine from AppState (sherpa by default);
    // the page asks it what it can do and stays honest when it cannot run.
    final state = AppStateScope.of(context);
    final engine = state.engine;

    // Real feature pages replace the placeholders in later phases.
    final sections = <_Section>[
      _Section(
        navIcon: Icons.mic_none,
        selectedNavIcon: Icons.mic,
        label: l10n.navTranscribe,
        page: TranscribePage(
          engine: engine,
          state: state,
          transcriptRepo: state.transcriptRepo,
          modelLibrary: _modelLibrary,
          onManageModels: _openModels,
        ),
      ),
      _Section(
        navIcon: Icons.list_alt_outlined,
        selectedNavIcon: Icons.list_alt,
        label: l10n.navQueue,
        page: QueuePage(
          engine: engine,
          state: state,
          transcriptRepo: state.transcriptRepo,
          modelLibrary: _modelLibrary,
          onManageModels: _openModels,
        ),
      ),
      _Section(
        navIcon: Icons.history,
        selectedNavIcon: Icons.history,
        label: l10n.navHistory,
        page: HistoryPage(
          repo: state.transcriptRepo,
          search: state.searchRepo,
          indexer: state.indexer,
        ),
      ),
      _Section(
        navIcon: Icons.layers_outlined,
        selectedNavIcon: Icons.layers,
        label: l10n.navModels,
        page: ModelsPage(state: state, library: _modelLibrary),
      ),
      _Section(
        navIcon: Icons.settings_outlined,
        selectedNavIcon: Icons.settings,
        label: l10n.navSettings,
        page: SettingsPage(
          modelLibrary: _modelLibrary,
          onManageModels: _openModels,
        ),
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
