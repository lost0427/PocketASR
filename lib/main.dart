import 'dart:async';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_state.dart';
import 'app/theme.dart';
import 'core/backup/backup_service.dart';
import 'core/update/release_check.dart';
import 'data/db.dart';
import 'features/models/models_page.dart';
import 'features/models/model_library.dart';
import 'features/history/history_page.dart';
import 'features/queue/queue_page.dart';
import 'features/settings/settings_page.dart';
import 'features/transcribe/transcribe_page.dart';
import 'features/update/update_dialog.dart';
import 'l10n/app_delegates.dart';
import 'l10n/app_localizations.dart';
import 'remote/pair_link.dart';

final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  await BackupService.applyPendingRestore(
    documentsDirectory: directory.path,
    supportDirectory: support.path,
  );
  // After restore, so an old backup cannot resurrect retired bundles.
  await retireRemovedModelBundles(support.path);
  runApp(
    PocketAsrApp(
      database: AppDatabase.open(
        path: '${directory.path}${Platform.pathSeparator}$databaseFileName',
      ),
      supportDirectory: support.path,
    ),
  );
}

/// Root of the app. Owns the single [AppState] and hands it to the tree.
class PocketAsrApp extends StatefulWidget {
  const PocketAsrApp({
    super.key,
    this.database,
    this.modelLibrary,
    this.supportDirectory,
  });

  final AppDatabase? database;
  final ModelLibrary? modelLibrary;
  final String? supportDirectory;

  @override
  State<PocketAsrApp> createState() => _PocketAsrAppState();
}

class _PocketAsrAppState extends State<PocketAsrApp>
    with WidgetsBindingObserver {
  late final AppState _state = AppState(
    database: widget.database,
    supportDirectory: widget.supportDirectory,
  );

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.startRemoteOutbox();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_listenForPairLinks()),
    );
    if (Platform.isWindows) {
      _updateTimer = Timer(
        const Duration(seconds: 5),
        () => unawaited(_checkForUpdates()),
      );
    }
  }

  Future<void> _checkForUpdates() async {
    if (!_state.updateCheckStartup) return;
    try {
      final info = await ReleaseChecker(
        currentVersion: settingsAppVersion,
      ).check();
      if (!_state.updateCheckStartup ||
          info == null ||
          info.version == _state.skippedUpdateVersion) {
        return;
      }
      final context = appNavigatorKey.currentState?.overlay?.context;
      if (context == null || !context.mounted) return;
      await handleAvailableUpdate(context, _state, info);
    } on Object {
      // A launch check is best effort; a manual check reports the error.
    }
  }

  Future<void> _listenForPairLinks() async {
    await listenForPairLinks((link) async {
      try {
        await _state.pairWithLink(link);
        _showSnack(
          _l10n?.remotePaired(link.name) ?? 'Paired with ${link.name}',
        );
      } on Object catch (error) {
        _showSnack(
          _l10n?.remotePairFailed('$error') ?? 'Pairing failed: $error',
        );
      }
    });
  }

  AppLocalizations? get _l10n {
    final context = appScaffoldMessengerKey.currentContext;
    return context == null ? null : AppLocalizations.of(context);
  }

  void _showSnack(String text) {
    final messenger = appScaffoldMessengerKey.currentState;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_state.remoteOutbox.tick());
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
      scaffoldMessengerKey: appScaffoldMessengerKey,
      navigatorKey: appNavigatorKey,
      localizationsDelegates: appLocalizationsDelegates,
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
