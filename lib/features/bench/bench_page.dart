import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/app_state.dart';
import '../../core/audio/audio_picker.dart';
import '../../core/audio/audio_source.dart';
import '../../core/text/token_counter.dart';
import '../../engine/asr_engine.dart';
import '../../engine/model_catalog.dart';
import '../../features/transcribe/transcription_service.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/model_selection_localizations.dart';
import 'benchmark_runner.dart';
import 'seven_tap.dart';

typedef BenchmarkEngineFactory = AsrEngine Function(String engineId);
typedef BenchmarkServiceFactory = TranscriptionService Function(
  AsrEngine engine,
);

/// Runs one decode through a pinned backend; production uses
/// [FileAudioSource.decodeProbe].
typedef BenchmarkDecodeProbe = Future<DecodeProbe> Function(
  String path,
  Directory directory,
  AudioDecoderBackend backend,
);

/// Embeds one text through the production embedder; production uses
/// [AppState.embedder], tests inject a fake. The page owns the timing.
typedef BenchmarkEmbedProbe = Future<void> Function(String text);

/// Hidden benchmark page (requirement 15), reached by tapping the version row
/// seven times in Settings and left the same way on this page's title.
///
/// Runs the *real* [BenchmarkRunner] over every speech bundle actually present
/// on disk, on one audio file the user picks, and reports the median of three
/// runs per bundle. This build bundles no fixed sample — there is no licensed
/// audio to ship — so the user supplies the input; every row in one matrix uses
/// that same file, which is what keeps the numbers comparable. A row whose runs
/// all fail shows the failure, never a fabricated figure.
class BenchPage extends StatefulWidget {
  const BenchPage({
    super.key,
    this.engine = const UnavailableAsrEngine(),
    this.service,
    this.engineFactory,
    this.serviceFactory,
    this.entries,
    this.store,
    this.state,
    this.pickAudio,
    this.exportFile,
    this.decodeProbe,
    this.embedProbe,
  }) : assert(engineFactory == null || service == null),
       assert(engineFactory != null || serviceFactory == null);

  /// Single engine used when [engineFactory] is absent, primarily for tests.
  final AsrEngine engine;

  /// Single-engine service seam used when [engineFactory] is absent.
  final TranscriptionService? service;

  /// Builds the matching engine for each catalog entry in a production run.
  final BenchmarkEngineFactory? engineFactory;

  /// Optional test seam for services built around [engineFactory] results.
  final BenchmarkServiceFactory? serviceFactory;

  /// Catalog seam; production reads the allowlist asset.
  final List<ModelEntry>? entries;

  /// Local file facts seam; production resolves the app-private models dir.
  final ModelStore? store;

  /// App-wide chunking/VAD settings, so a benchmark cuts audio exactly like the
  /// transcribe and queue flows. Null in tests that do not care.
  final AppState? state;

  /// Picks the fixed input audio; production uses [AudioPicker].
  final Future<String?> Function()? pickAudio;

  /// Writes an export; production asks the user where to save it.
  final Future<void> Function(String suggestedName, String contents)?
  exportFile;

  /// Decode-comparison seam; production probes through [FileAudioSource].
  /// Its presence also enables the section on the desktop test host.
  final BenchmarkDecodeProbe? decodeProbe;

  /// Embedding-speed seam; production embeds through [AppState.embedder]. Its
  /// presence enables the section without a loaded model, for tests.
  final BenchmarkEmbedProbe? embedProbe;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  static const int _repeats = 3;

  late final Future<_BenchSetup> _setup = _loadSetup();

  String? _audioPath;
  String? _audioName;

  final Map<String, _Cell> _cells = {};
  bool _running = false;
  bool _cancelRequested = false;
  AsrEngine? _activeEngine;
  List<BenchmarkResult> _results = const [];

  bool _decodeRunning = false;
  List<_DecodeRow> _decodeRows = const [];

  bool _embedRunning = false;
  List<_EmbedRow> _embedRows = const [];

  /// Input sizes the embedding section measures, in estimated tokens. 512 is
  /// the indexer's default budget; the neighbours show what it costs to read
  /// more context and what a smaller budget buys.
  static const List<int> _embedTiers = [200, 512, 1024];

  Future<_BenchSetup> _loadSetup() async {
    var engineAvailable = widget.engineFactory != null;
    String? engineReason;
    if (widget.engineFactory == null) {
      try {
        final caps = await widget.engine.capabilities();
        engineAvailable = caps.available;
        engineReason = caps.unavailableReason;
      } catch (error) {
        engineReason = error.toString();
      }
    }

    var downloaded = const <ModelEntry>[];
    ModelStore? store;
    try {
      final entries = widget.entries ?? await loadModelAllowlist();
      store = widget.store ?? await _resolveStore();
      if (store != null) {
        downloaded = [
          for (final entry in entries)
            // VAD and embedding bundles are not speech recognizers; a matrix
            // cell must be an ASR bundle or the numbers would be meaningless.
            if (entry.type != 'embedding' &&
                entry.type != 'vad' &&
                store.isDownloaded(entry))
              entry,
        ];
      }
    } catch (_) {
      // No catalog or no directory: the page says "nothing to run" rather than
      // inventing rows.
    }

    return _BenchSetup(
      engineAvailable: engineAvailable,
      engineReason: engineReason,
      downloaded: downloaded,
      store: store,
    );
  }

  Future<ModelStore?> _resolveStore() async {
    try {
      final base = await getApplicationSupportDirectory();
      return LocalModelStore(
        Directory('${base.path}${Platform.pathSeparator}models'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickAudio() async {
    if (_running) return;
    final injectedPicker = widget.pickAudio;
    final PickedAudio? audio;
    if (injectedPicker == null) {
      audio = await const AudioPicker().pickOne(
        typeLabel: AppLocalizations.of(context).fileTypeAudio,
      );
    } else {
      final path = await injectedPicker();
      audio = path == null
          ? null
          : PickedAudio(source: path, name: path.split(RegExp(r'[\\/]')).last);
    }
    final selected = audio;
    if (!mounted || selected == null) return;
    setState(() {
      _audioPath = selected.source;
      _audioName = selected.name;
    });
  }

  Future<void> _run(List<ModelEntry> downloaded, ModelStore store) async {
    final audioPath = _audioPath;
    if (_running || audioPath == null || (widget.state?.engineBusy ?? false)) {
      return;
    }
    final state = widget.state;
    final l10n = AppLocalizations.of(context);
    state?.resetVadEngine(); // a previous cancel must not poison this run
    AsrEngine? ownedEngine;
    String? ownedEngineId;
    BenchmarkRunner? ownedRunner;
    Future<void> disposeOwnedEngine() async {
      final engine = ownedEngine;
      ownedEngine = null;
      ownedEngineId = null;
      ownedRunner = null;
      if (identical(_activeEngine, engine)) _activeEngine = null;
      if (engine == null) return;
      try {
        await engine.dispose();
      } catch (_) {
        // Cleanup failure must not replace completed benchmark results.
      }
    }

    final singleRunner = widget.engineFactory == null
        ? BenchmarkRunner(
            widget.engine,
            widget.service ??
                TranscriptionService(
                  engine: widget.engine,
                  vadEngine: state?.activeVadEngine,
                  decoderPreference:
                      state?.audioDecoderPreference ??
                      AudioDecoderPreference.automatic,
                ),
            chunkSettings: state?.chunkSettings,
            neuralVad: state?.neuralVadSettings,
          )
        : null;

    state?.engineBusy = true;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _results = const [];
      _cells.clear();
    });

    final collected = <BenchmarkResult>[];
    final runOrder = <ModelEntry>[];
    if (widget.engineFactory == null) {
      runOrder.addAll(downloaded);
    } else {
      final groups = <String, List<ModelEntry>>{};
      for (final entry in downloaded) {
        final engineId =
            entry.engine ?? AppState.engineIdForModelFile(store.pathFor(entry));
        groups.putIfAbsent(engineId, () => []).add(entry);
      }
      for (final group in groups.values) {
        runOrder.addAll(group);
      }
    }
    try {
      for (final entry in runOrder) {
        if (_cancelRequested) break;
        final model = store.specFor(entry);
        final engineId =
            entry.engine ?? AppState.engineIdForModelFile(model.path);
        final caseSpec = BenchmarkCase(id: entry.id, model: model);
        setState(() => _cells[entry.id] = const _Cell(_CellStatus.running));
        late BenchmarkResult result;
        try {
          final selectionProblem = AppState.selectionProblemFor(
            engineId: engineId,
            spec: model,
          );
          if (selectionProblem != null) {
            throw EngineUnavailableException(
              l10n.messageForModelSelectionProblem(selectionProblem),
            );
          }
          final BenchmarkRunner runner;
          if (singleRunner != null) {
            runner = singleRunner;
          } else {
            if (ownedEngineId != engineId || ownedRunner == null) {
              await disposeOwnedEngine();
              if (_cancelRequested) {
                throw const EngineCancelledException('Benchmark cancelled.');
              }
              final engine = widget.engineFactory!(engineId);
              ownedEngine = engine;
              ownedEngineId = engineId;
              final service =
                  widget.serviceFactory?.call(engine) ??
                  TranscriptionService(
                    engine: engine,
                    vadEngine: state?.activeVadEngine,
                    decoderPreference:
                        state?.audioDecoderPreference ??
                        AudioDecoderPreference.automatic,
                  );
              ownedRunner = BenchmarkRunner(
                engine,
                service,
                chunkSettings: state?.chunkSettings,
                neuralVad: state?.neuralVadSettings,
              );
            }
            runner = ownedRunner!;
          }
          _activeEngine = runner.engine;
          result = await runner.run(
            caseSpec,
            audioPath,
            repeats: _repeats,
            isCancelled: () => _cancelRequested,
          );
        } on EngineCancelledException {
          rethrow;
        } catch (error) {
          result = BenchmarkResult(
            caseSpec: caseSpec,
            engine: engineId,
            backend: Backend.cpu,
            attempts: _repeats,
            failures: _repeats,
            error: error.toString(),
          );
        }
        collected.add(result);
        if (!mounted) return;
        setState(
          () => _cells[entry.id] = _Cell(
            result.isFailure ? _CellStatus.failed : _CellStatus.done,
            result: result,
          ),
        );
      }
    } on EngineCancelledException {
      // A cancel is not a failure cell: the in-flight row is marked cancelled.
    } finally {
      _activeEngine = null;
      await disposeOwnedEngine();
      state?.engineBusy = false;
      if (mounted) {
        setState(() {
          _running = false;
          _results = collected;
          for (final entry in _cells.keys.toList()) {
            if (_cells[entry]!.status == _CellStatus.running) {
              _cells[entry] = const _Cell(_CellStatus.cancelled);
            }
          }
        });
      }
    }
  }

  /// Probes the two decode backends on the picked file, median of [_repeats].
  /// A backend that cannot decode the format reports its failure, never a number.
  Future<void> _runDecodeCompare() async {
    final audioPath = _audioPath;
    if (_decodeRunning || _running || audioPath == null) return;
    final probe =
        widget.decodeProbe ??
        (path, directory, backend) => const FileAudioSource().decodeProbe(
          path,
          directory,
          backend: backend,
        );
    setState(() {
      _decodeRunning = true;
      _decodeRows = const [];
    });

    final rows = <_DecodeRow>[];
    Directory? directory;
    try {
      // Sync so the widget test host is not blocked on real async IO.
      directory = Directory.systemTemp.createTempSync('pocket_asr_decode_');
      for (final backend in const [
        AudioDecoderBackend.builtin,
        AudioDecoderBackend.platform,
      ]) {
        rows.add(await _probeDecode(probe, audioPath, directory, backend));
        if (!mounted) return;
        setState(() => _decodeRows = List.of(rows));
      }
    } catch (error) {
      rows.add(_DecodeRow(backend: null, error: error.toString()));
    } finally {
      if (directory != null) {
        try {
          directory.deleteSync(recursive: true);
        } on FileSystemException {
          // Best effort, like the decoder's own temp file cleanup.
        }
      }
      if (mounted) {
        setState(() {
          _decodeRunning = false;
          _decodeRows = List.of(rows);
        });
      }
    }
  }

  Future<_DecodeRow> _probeDecode(
    BenchmarkDecodeProbe probe,
    String audioPath,
    Directory directory,
    AudioDecoderBackend backend,
  ) async {
    final samples = <Duration>[];
    DecodeProbe? last;
    try {
      for (var i = 0; i < _repeats; i++) {
        last = await probe(audioPath, directory, backend);
        samples.add(last.elapsed);
      }
    } catch (error) {
      return _DecodeRow(backend: backend, error: error.toString());
    }
    samples.sort();
    return _DecodeRow(
      backend: backend,
      elapsed: samples[samples.length ~/ 2],
      probe: last,
      runs: samples.length,
    );
  }

  /// Measures the loaded embedding model at each tier, median of [_repeats].
  ///
  /// This is the per-chunk cost the History index pays, at the same input sizes
  /// a chunk budget can pick; a tier that cannot embed reports its failure,
  /// never a figure. No transcript is touched.
  Future<void> _runEmbedCompare() async {
    final embedder = widget.state?.embedder;
    final probe =
        widget.embedProbe ??
        (embedder == null
            ? null
            : (String text) async => embedder.embedDocument(text));
    if (_embedRunning || _running || _decodeRunning || probe == null) return;
    setState(() {
      _embedRunning = true;
      _embedRows = const [];
    });

    final rows = <_EmbedRow>[];
    var tokens = _embedTiers.first;
    try {
      for (var tierIndex = 0; tierIndex < _embedTiers.length; tierIndex++) {
        tokens = _embedTiers[tierIndex];
        rows.add(await _probeEmbed(probe, tokens, tierIndex));
        if (!mounted) return;
        setState(() => _embedRows = List.of(rows));
      }
    } catch (error) {
      rows.add(_EmbedRow(tokens: tokens, error: error.toString()));
    } finally {
      if (mounted) {
        setState(() {
          _embedRunning = false;
          _embedRows = List.of(rows);
        });
      }
    }
  }

  /// Median wall clock of [_repeats] encodes of a sample of [tokens] estimated
  /// tokens, each [tierIndex] starting the sample somewhere else. Failures
  /// propagate: one broken model fails every tier, so the caller records a
  /// single error row rather than retrying each size.
  Future<_EmbedRow> _probeEmbed(
    BenchmarkEmbedProbe probe,
    int tokens,
    int tierIndex,
  ) async {
    final samples = <({Duration elapsed, String text})>[];
    for (var i = 0; i < _repeats; i++) {
      final text = _embedSample(tierIndex * _repeats + i, tokens);
      final clock = Stopwatch()..start();
      await probe(text);
      clock.stop();
      samples.add((elapsed: clock.elapsed, text: text));
    }
    samples.sort((a, b) => a.elapsed.compareTo(b.elapsed));
    final median = samples[samples.length ~/ 2];
    return _EmbedRow(
      tokens: tokens,
      elapsed: median.elapsed,
      charsPerSecond: graphemesPerSecond(median.text, median.elapsed),
      runs: samples.length,
    );
  }

  /// Deterministic sample for one measurement: Chinese prose trimmed to
  /// [tokens] estimated tokens, starting at sentence [start] of
  /// [_embedSentences]. Generated rather than shipped (no licensed text is
  /// bundled) and identical on every device, so the rows stay comparable.
  ///
  /// [start] differs for every one of the 9 measurements, which is what makes
  /// each a cold encode: no sample is a prefix of another. The engine caches
  /// the KV of a shared token prefix between calls, so a repeated or nested
  /// input would be served from that cache and report a suffix encode as if it
  /// were the whole tier.
  static String _embedSample(int start, int tokens) {
    final buffer = StringBuffer();
    for (var i = 0; buffer.length < tokens; i++) {
      buffer.write(_embedSentences[(start + i) % _embedSentences.length]);
    }
    final text = buffer.toString();
    return text.length <= tokens ? text : text.substring(0, tokens);
  }

  /// Sentence pool behind [_embedSample]. Every sentence opens with a different
  /// character, so samples starting at different sentences share no first
  /// token and no sample can be a prefix of another.
  static const List<String> _embedSentences = <String>[
    '我们先回顾上次的结论，然后讨论本季度的进展和下一步的人员安排。',
    '另外需要确认时间表是否与客户那边的排期冲突，避免临时调整方案。',
    '如果预算允许，我建议把培训提前到三季度，这样能赶在旺季前完成。',
    '技术方案已经评审过两轮，剩下的分歧集中在存储成本和运维复杂度。',
    '现场测试的反馈整体不错，只是夜间功耗偏高，还需要再压一压。',
    '合同条款里关于违约责任的表述比较模糊，法务建议重新拟定一份。',
    '人员的招聘进度落后于计划，主要是候选人对出差频率有所顾虑。',
    '供应商那边承诺下周一给答复，届时再决定是否启动备选方案。',
    '文档整理得差不多了，还需要补一份面向新同事的速查手册。',
  ];

  void _cancel() {
    if (!_running || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    final engine = _activeEngine ?? widget.engine;
    if (engine is CancellableAsrEngine) engine.cancel();
    // Neural VAD plans on its own worker, so the cancel must reach that too.
    widget.state?.cancelVad();
  }

  Future<void> _export(bool asJson) async {
    if (_results.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final saver = widget.exportFile ?? _defaultExport;
    final contents = asJson
        ? BenchmarkRunner.toJson(_results)
        : BenchmarkRunner.toCsv(_results);
    try {
      await saver(
        asJson ? 'pocketasr_benchmark.json' : 'pocketasr_benchmark.csv',
        contents,
      );
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${l10n.benchExportFailed}: $error')),
        );
    }
  }

  Future<void> _defaultExport(String suggestedName, String contents) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return;
    await File(location.path).writeAsString(contents);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: SevenTapGate(
          onTriggered: () => Navigator.of(context).maybePop(),
          child: Text(l10n.benchTitle),
        ),
      ),
      body: FutureBuilder<_BenchSetup>(
        future: _setup,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final setup = snapshot.data!;
          return _buildBody(l10n, setup);
        },
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n, _BenchSetup setup) {
    final store = setup.store;
    final state = widget.state;
    // Neural mode without a real VAD model cannot run, exactly like the pages.
    final needsVad =
        (state?.chunkStrategy ?? ChunkStrategy.fixed) == ChunkStrategy.neural &&
        !(state?.neuralVadReady ?? false);
    final canRun =
        setup.engineAvailable &&
        _audioName != null &&
        setup.downloaded.isNotEmpty &&
        store != null &&
        !_running &&
        !_decodeRunning &&
        !_embedRunning &&
        !(state?.engineBusy ?? false) &&
        !needsVad;

    // The embedding section needs the production embedder or an injected probe;
    // it runs on generated text, so it is independent of the audio file.
    final embedReady =
        widget.embedProbe != null || (state?.embeddingReady ?? false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _Muted(l10n.benchIntro, height: 1.5),
        if (!setup.engineAvailable) ...[
          const SizedBox(height: 16),
          _UnavailableBanner(
            title: l10n.benchUnavailableTitle,
            lines: [
              setup.engineReason == null
                  ? l10n.benchUnavailableEngine
                  : '${l10n.benchUnavailableEngine} (${setup.engineReason})',
            ],
            honesty: l10n.benchHonesty,
          ),
        ],
        const SizedBox(height: 20),
        _SectionLabel(l10n.benchSample),
        const SizedBox(height: 8),
        _Card(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _audioName ?? l10n.benchNoAudio,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.benchSampleHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _running ? null : _pickAudio,
                child: Text(
                  _audioName == null
                      ? l10n.benchChooseAudio
                      : l10n.benchChangeAudio,
                ),
              ),
            ],
          ),
        ),
        if (widget.decodeProbe != null || Platform.isAndroid) ...[
          const SizedBox(height: 24),
          _SectionLabel(l10n.benchDecodeTitle),
          const SizedBox(height: 8),
          _Muted(l10n.benchDecodeHint, height: 1.45),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: !_decodeRunning && !_running && _audioPath != null
                      ? _runDecodeCompare
                      : null,
                  icon: const Icon(Icons.compare_arrows, size: 18),
                  label: Text(l10n.benchDecodeRun),
                ),
              ),
              if (_decodeRunning) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (_audioName == null) ...[
            const SizedBox(height: 8),
            _Muted(l10n.benchDecodeAudioRequired),
          ],
          for (final row in _decodeRows) ...[
            const SizedBox(height: 12),
            _DecodeRowCard(row: row),
          ],
        ],
        const SizedBox(height: 24),
        _SectionLabel(l10n.benchEmbedTitle),
        const SizedBox(height: 8),
        _Muted(l10n.benchEmbedHint, height: 1.45),
        const SizedBox(height: 12),
        if (!embedReady)
          _Muted(l10n.benchEmbedUnavailable)
        else
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: !_embedRunning && !_running && !_decodeRunning
                      ? _runEmbedCompare
                      : null,
                  icon: const Icon(Icons.speed_rounded, size: 18),
                  label: Text(l10n.benchEmbedRun),
                ),
              ),
              if (_embedRunning) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        for (final row in _embedRows) ...[
          const SizedBox(height: 12),
          _EmbedRowCard(row: row),
        ],
        const SizedBox(height: 24),
        _SectionLabel(l10n.benchMatrix),
        const SizedBox(height: 8),
        _Muted(l10n.benchCpuOnly),
        const SizedBox(height: 12),
        if (setup.downloaded.isEmpty)
          _EmptyResults(
            title: l10n.benchNoModelsTitle,
            body: l10n.benchNoModelsBody,
          )
        else
          _MatrixCard(downloaded: setup.downloaded, cells: _cells),
        const SizedBox(height: 24),
        _SectionLabel(l10n.benchResults),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: canRun ? () => _run(setup.downloaded, store) : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.benchRun),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ),
            if (_running) ...[
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _cancelRequested ? null : _cancel,
                child: Text(l10n.benchCancel),
              ),
            ],
          ],
        ),
        if (_audioName == null) ...[
          const SizedBox(height: 8),
          _Muted(l10n.benchAudioRequired),
        ],
        if (needsVad) ...[
          const SizedBox(height: 8),
          _Muted(l10n.vadModelRequired),
        ],
        const SizedBox(height: 16),
        if (_results.isEmpty)
          _EmptyResults(
            title: l10n.benchNoResultsTitle,
            body: l10n.benchNoResultsBody,
          )
        else ...[
          for (final result in _results) _ResultCard(result: result),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _export(true),
                  icon: const Icon(Icons.data_object, size: 18),
                  label: Text(l10n.benchExportJson),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _export(false),
                  icon: const Icon(Icons.table_chart_outlined, size: 18),
                  label: Text(l10n.benchExportCsv),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        _Muted(l10n.benchExitHint),
      ],
    );
  }
}

/// The two facts the page needs before it may claim anything.
class _BenchSetup {
  const _BenchSetup({
    required this.engineAvailable,
    required this.downloaded,
    required this.store,
    this.engineReason,
  });

  final bool engineAvailable;
  final String? engineReason;

  /// Speech bundles actually on disk; only these can run.
  final List<ModelEntry> downloaded;
  final ModelStore? store;
}

enum _CellStatus { running, done, failed, cancelled }

class _Cell {
  const _Cell(this.status, {this.result});
  final _CellStatus status;
  final BenchmarkResult? result;
}

/// One decoder's median decode time, or the reason it could not run.
class _DecodeRow {
  const _DecodeRow({
    required this.backend,
    this.elapsed,
    this.probe,
    this.runs = 0,
    this.error,
  });

  final AudioDecoderBackend? backend;
  final Duration? elapsed;
  final DecodeProbe? probe;
  final int runs;
  final String? error;
}

/// One measured embedding input size: the median wall clock of [_repeats]
/// encodes of a sample of that size, and the characters-per-second it implies.
class _EmbedRow {
  const _EmbedRow({
    required this.tokens,
    this.elapsed,
    this.charsPerSecond,
    this.runs = 0,
    this.error,
  });

  /// Estimated input tokens of the sample this row measured.
  final int tokens;

  final Duration? elapsed;
  final double? charsPerSecond;
  final int runs;
  final String? error;
}

/// Rounded card matching the models/transcribe surfaces.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _MatrixCard extends StatelessWidget {
  const _MatrixCard({required this.downloaded, required this.cells});

  final List<ModelEntry> downloaded;
  final Map<String, _Cell> cells;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(flex: 4, child: Text(l10n.benchFamily, style: style)),
              Expanded(flex: 2, child: Text(l10n.benchQuant, style: style)),
              Expanded(
                flex: 2,
                child: Text(l10n.transcribeBackend, style: style),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  l10n.benchStatus,
                  textAlign: TextAlign.right,
                  style: style,
                ),
              ),
            ],
          ),
          Divider(height: 20, color: scheme.outlineVariant),
          for (var i = 0; i < downloaded.length; i++) ...[
            _MatrixRow(entry: downloaded[i], cell: cells[downloaded[i].id]),
            if (i != downloaded.length - 1)
              Divider(height: 20, color: scheme.outlineVariant),
          ],
        ],
      ),
    );
  }
}

class _MatrixRow extends StatelessWidget {
  const _MatrixRow({required this.entry, required this.cell});

  final ModelEntry entry;
  final _Cell? cell;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final (String label, bool blocked) = switch (cell?.status) {
      _CellStatus.running => (l10n.benchStatusRunning, false),
      _CellStatus.done => (l10n.benchStatusDone, false),
      _CellStatus.failed => (l10n.benchStatusFailed, true),
      _CellStatus.cancelled => (l10n.benchStatusCancelled, true),
      null => (l10n.benchStatusNotRun, false),
    };

    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Text(
            entry.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        Expanded(flex: 2, child: Text(entry.quant ?? '—', style: muted)),
        Expanded(flex: 2, child: Text(l10n.transcribeBackendCpu, style: muted)),
        Expanded(
          flex: 4,
          child: Align(
            alignment: Alignment.centerRight,
            child: _StatusPill(label: label, blocked: blocked),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.blocked});

  final String label;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: blocked ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: blocked
              ? scheme.onErrorContainer
              : scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One finished cell: the medians it really measured, or the failure.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final BenchmarkResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${result.caseSpec.family} · ${result.caseSpec.quant}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (result.isFailure)
              Text(
                '${l10n.benchStatusFailed}: ${result.error ?? ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              )
            else ...[
              _metric(context, l10n.metricElapsed, _ms(result.elapsed)),
              _metric(
                context,
                l10n.metricRtf,
                result.rtf?.toStringAsFixed(2) ?? l10n.metricUnavailable,
              ),
              _metric(
                context,
                l10n.metricCharsPerSec,
                result.charsPerSecond?.toStringAsFixed(1) ??
                    l10n.metricUnavailable,
              ),
            ],
            // The real success count is shown for a failure too: it is a fact,
            // not a performance number.
            _metric(
              context,
              l10n.benchRuns,
              '${result.attempts - result.failures}/${result.attempts}',
            ),
            if (!result.isFailure && result.error != null)
              Text(
                result.error!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }

  static String _ms(Duration? value) {
    if (value == null) return '—';
    final ms = value.inMilliseconds;
    return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(2)}s';
  }
}

/// One backend's median decode time, or its failure — never a guess.
class _DecodeRowCard extends StatelessWidget {
  const _DecodeRowCard({required this.row});

  final _DecodeRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = switch (row.backend) {
      AudioDecoderBackend.builtin => l10n.benchDecodeBuiltin,
      AudioDecoderBackend.platform => l10n.benchDecodePlatform,
      _ => l10n.benchStatusFailed,
    };
    final name = row.probe?.decoder?.name;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
              if (name != null)
                Text(
                  name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (row.error != null)
            Text(
              row.error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            )
          else ...[
            _line(
              context,
              l10n.benchDecodeElapsed,
              _ResultCard._ms(row.elapsed),
            ),
            _line(
              context,
              l10n.benchDecodeRealtime,
              _realtime(row.elapsed, row.probe?.audioDuration),
            ),
          ],
          _line(
            context,
            l10n.benchRuns,
            '${row.runs}/${_BenchPageState._repeats}',
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }

  /// Higher is faster: seconds of audio decoded per real second.
  static String _realtime(Duration? elapsed, Duration? audio) {
    if (elapsed == null || audio == null || elapsed.inMicroseconds <= 0) {
      return '—';
    }
    return '${(audio.inMicroseconds / elapsed.inMicroseconds).toStringAsFixed(1)}×';
  }
}

/// One input size's median embed time and speed, or its failure.
class _EmbedRowCard extends StatelessWidget {
  const _EmbedRowCard({required this.row});

  final _EmbedRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.benchEmbedTier(row.tokens),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (row.error != null)
            Text(
              row.error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            )
          else ...[
            _line(context, l10n.metricElapsed, _ResultCard._ms(row.elapsed)),
            _line(
              context,
              l10n.metricCharsPerSec,
              row.charsPerSecond?.toStringAsFixed(1) ?? l10n.metricUnavailable,
            ),
          ],
          _line(
            context,
            l10n.benchRuns,
            '${row.runs}/${_BenchPageState._repeats}',
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const _UnavailableBanner({
    required this.title,
    required this.lines,
    required this.honesty,
  });

  final String title;
  final List<String> lines;
  final String honesty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final line in lines) ...[
                  const SizedBox(height: 6),
                  Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  honesty,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontStyle: FontStyle.italic,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state: the shape of the result table, with no invented values.
class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(Icons.speed_outlined, size: 36, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text, {this.height});

  final String text;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: height,
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    );
  }
}
