// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get recordStart => 'Record audio';

  @override
  String get recordStop => 'Stop and use recording';

  @override
  String get recordDiscard => 'Discard recording';

  @override
  String get recordEmpty => 'No audio was recorded. Cancel and try again.';

  @override
  String get recordPermissionDenied =>
      'Microphone access was denied. Enable it in system settings and try again.';

  @override
  String recordElapsed(int seconds) {
    return 'Recording · ${seconds}s';
  }

  @override
  String modelsParameterCount(String count) {
    return '${count}M parameters';
  }

  @override
  String get appTitle => 'PocketASR';

  @override
  String get navTranscribe => 'Transcribe';

  @override
  String get navQueue => 'Queue';

  @override
  String get navHistory => 'History';

  @override
  String get navModels => 'Models';

  @override
  String get navSettings => 'Settings';

  @override
  String get transcribeTitle => 'Transcribe';

  @override
  String get transcribeBody =>
      'Pick an audio file, run it through the on-device engine, and copy the text out. Nothing leaves the device.';

  @override
  String get transcribeChooseFile => 'Choose audio file';

  @override
  String get transcribeChangeFile => 'Change file';

  @override
  String get transcribeNoFile => 'No audio selected';

  @override
  String get transcribeFileHint => 'WAV · M4A · MP3, decoded on-device';

  @override
  String get fileTypeAudio => 'Audio';

  @override
  String get transcribePickerUnavailable => 'File picking is not wired up yet.';

  @override
  String get transcribeEngineUnavailableTitle => 'On-device engine unavailable';

  @override
  String get transcribeEngineUnavailableBody =>
      'This build ships without the native speech engine, so transcription cannot run yet. Nothing is faked and no audio leaves the device.';

  @override
  String get transcribeEngineSection => 'Engine';

  @override
  String get transcribeModel => 'Model';

  @override
  String get transcribeModelNone => 'Not selected';

  @override
  String get transcribeBackend => 'Backend';

  @override
  String get transcribeBackendCpu => 'CPU';

  @override
  String get transcribeStart => 'Start transcription';

  @override
  String get transcribeStartUnavailable =>
      'Transcription is not available in this build.';

  @override
  String get transcribeProgress => 'Progress';

  @override
  String get transcribeProgressIdle => 'Waiting to start';

  @override
  String get transcribeStageDecoding => 'Decoding audio';

  @override
  String get transcribeStageAnalyzing => 'Preparing audio';

  @override
  String get transcribeStageSegmenting => 'Segmenting audio';

  @override
  String get transcribeStageLoadingModel => 'Loading model';

  @override
  String get transcribeStageTranscribing => 'Transcribing';

  @override
  String get transcribeStageFinalizing => 'Finalizing';

  @override
  String get transcribeMetrics => 'Live metrics';

  @override
  String get transcribeResult => 'Result';

  @override
  String get transcribeResultEmpty => 'The transcript will appear here.';

  @override
  String get transcribeCopy => 'Copy';

  @override
  String get transcribeCopied => 'Copied to clipboard';

  @override
  String get transcribeChooseModel => 'Choose downloaded model';

  @override
  String get transcribeChangeModel => 'Change model';

  @override
  String get transcribeModelRequired =>
      'Select a downloaded speech model before starting.';

  @override
  String get modelNeedsDecoder =>
      'The selected model bundle is incomplete. Download it again from Models.';

  @override
  String get modelSelectionMissing =>
      'The downloaded model selected last time is no longer on this device. Choose another one.';

  @override
  String get modelPickerTitle => 'Choose speech model';

  @override
  String get modelPickerEmpty =>
      'No downloaded speech models. Download one from Models first.';

  @override
  String get modelPickerManage => 'Open Models';

  @override
  String get metricCharsPerSec => 'chars/s';

  @override
  String get metricRtf => 'RTF';

  @override
  String get metricElapsed => 'Elapsed';

  @override
  String get metricCpu => 'CPU';

  @override
  String get metricMemory => 'Memory';

  @override
  String get metricDecoder => 'Decoder';

  @override
  String get decoderHardware => 'Hardware';

  @override
  String get decoderSoftware => 'Software';

  @override
  String get decoderUnknown => 'Unknown';

  @override
  String get metricUnavailable => '—';

  @override
  String get queueTitle => 'Queue';

  @override
  String get queueBody =>
      'Line up several files at once, reorder them, and watch each one finish in turn.';

  @override
  String get queueAddAudio => 'Add audio';

  @override
  String get queueChooseModel => 'Choose model';

  @override
  String get queueRun => 'Run queue';

  @override
  String get queueEmpty => 'Queue is empty';

  @override
  String get queueModelRequired =>
      'Select a downloaded speech model before running.';

  @override
  String get queueStatusPending => 'Pending';

  @override
  String get queueStatusRunning => 'Running';

  @override
  String get queueStatusCancelling => 'Cancelling';

  @override
  String get queueStatusDone => 'Done';

  @override
  String get queueStatusFailed => 'Failed';

  @override
  String get queueStatusCancelled => 'Cancelled';

  @override
  String get queueCancel => 'Cancel';

  @override
  String get queueRetry => 'Retry';

  @override
  String get queueRemove => 'Remove';

  @override
  String get queueMoveUp => 'Move up';

  @override
  String get queueMoveDown => 'Move down';

  @override
  String get engineBusyNote =>
      'Another transcription is running. Wait for it to finish first.';

  @override
  String get historyTitle => 'History';

  @override
  String get historyBody =>
      'Every transcript is stored locally, so you can search it, copy it again, or restore it from the trash.';

  @override
  String get historySearchHint => 'Search transcripts';

  @override
  String get historyScopeHistory => 'History';

  @override
  String get historyScopeTrash => 'Trash';

  @override
  String get historyEmpty => 'No transcripts';

  @override
  String get historyTrashEmpty => 'Trash is empty';

  @override
  String get historyCopy => 'Copy';

  @override
  String get historyCopied => 'Copied to clipboard';

  @override
  String historySelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      one: '1 selected',
    );
    return '$_temp0';
  }

  @override
  String get historySelectAll => 'Select all';

  @override
  String get historyDeselectAll => 'Deselect all';

  @override
  String historyCopiedMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copied $count transcripts to clipboard',
      one: 'Copied 1 transcript to clipboard',
    );
    return '$_temp0';
  }

  @override
  String get historyMoveToTrash => 'Move to trash';

  @override
  String get historyRestore => 'Restore';

  @override
  String get historyDeletePermanently => 'Delete permanently';

  @override
  String get historyDeleteConfirmTitle => 'Delete permanently?';

  @override
  String get historyDeleteConfirmBody =>
      'This transcript will be erased from this device and cannot be recovered.';

  @override
  String historyDeleteManyConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'These $count transcripts will be erased from this device and cannot be recovered.',
      one: 'This transcript will be erased from this device and cannot be recovered.',
    );
    return '$_temp0';
  }

  @override
  String get historyDetailTitle => 'Transcript';

  @override
  String get historyDetailCreated => 'Created';

  @override
  String get historyDetailAudio => 'Audio';

  @override
  String get historySearchLiteral => 'Literal';

  @override
  String get historySearchSemantic => 'Semantic';

  @override
  String get historySearchHybrid => 'Hybrid';

  @override
  String get historySearchSemanticOff =>
      'Select a downloaded embedding model to enable semantic search.';

  @override
  String get historyIndexing => 'Indexing transcripts…';

  @override
  String get historyIndexFailed => 'Indexing failed';

  @override
  String get historyIndexRetry => 'Retry';

  @override
  String get historyIndexRebuild => 'Rebuild index';

  @override
  String historyIndexChunks(int done, int total) {
    return '$done/$total chunks';
  }

  @override
  String historyIndexSpeed(int rate) {
    return '$rate chars/s';
  }

  @override
  String historyIndexEta(String clock) {
    return '~$clock left';
  }

  @override
  String get modelsTitle => 'Models';

  @override
  String get modelsBody =>
      'Manage the speech models kept on the device, with size and quantization shown before you download.';

  @override
  String get modelsDownload => 'Download';

  @override
  String get modelsDownloading => 'Downloading';

  @override
  String get modelsCancel => 'Cancel';

  @override
  String get modelsNotDownloadable => 'Not available for download';

  @override
  String get modelsDownloaded => 'Downloaded';

  @override
  String get modelsNotDownloaded => 'Not downloaded';

  @override
  String get modelsDelete => 'Delete';

  @override
  String get modelsDeleteConfirmTitle => 'Delete downloaded model?';

  @override
  String modelsDeleteConfirmBody(String name) {
    return '$name will be removed from this device. You can download it again later.';
  }

  @override
  String get modelsDownloadFailed => 'Download failed';

  @override
  String get modelsTotalUsage => 'On this device';

  @override
  String get modelsNoModels => 'No models available';

  @override
  String get modelsAsrSection => 'Speech models';

  @override
  String get modelsEmbeddingSection => 'Embedding models';

  @override
  String get modelsEmbeddingNote =>
      'Embedding models power semantic search in History. They cannot transcribe audio.';

  @override
  String get modelsEmbeddingError => 'Could not load the embedding model:';

  @override
  String get modelsUse => 'Use';

  @override
  String get modelsInUse => 'In use';

  @override
  String get modelsBusyNote =>
      'A transcription is running. Stop it before switching models.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get languageSystem => 'System';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => '中文';

  @override
  String get settingsModel => 'Model';

  @override
  String get settingsActiveModel => 'Active model';

  @override
  String get settingsActiveModelNone => 'None selected';

  @override
  String get settingsPerformance => 'Performance';

  @override
  String get settingsThreads => 'Threads';

  @override
  String settingsThreadsValue(int used, int max) {
    return '$used of $max';
  }

  @override
  String get settingsThreadsHint => 'Defaults to half the CPU cores.';

  @override
  String get settingsDecoderPreference => 'Audio decoder';

  @override
  String get decoderPreferenceAutomatic => 'Automatic';

  @override
  String get decoderPreferenceHardware => 'Prefer hardware';

  @override
  String get decoderPreferenceSoftware => 'Prefer software';

  @override
  String get settingsDecoderPreferenceHint =>
      'Applies only to the formats Android\'s MediaCodec handles, such as AAC/M4A. MP3, WAV and FLAC use the built-in decoders. The codec actually used is shown after decoding.';

  @override
  String get settingsChunking => 'Chunking';

  @override
  String get settingsChunkMode => 'Mode';

  @override
  String get settingsChunkFixed => 'Fixed length';

  @override
  String get settingsChunkEnergy => 'Energy detection';

  @override
  String get settingsChunkSeconds => 'Chunk length';

  @override
  String settingsChunkSecondsValue(int seconds) {
    return '$seconds s';
  }

  @override
  String get settingsEnergyThreshold => 'Energy threshold';

  @override
  String get settingsSpeechPad => 'Speech padding';

  @override
  String settingsSpeechPadValue(int ms) {
    return '$ms ms';
  }

  @override
  String get settingsChunkHint =>
      'Energy detection is a loudness gate over the audio, not a neural VAD. Overlap stays off: this build does not merge repeated text at chunk seams.';

  @override
  String get settingsChunkReset => 'Reset chunking';

  @override
  String get settingsAbout => 'About';

  @override
  String settingsVersion(String version) {
    return 'Version $version';
  }

  @override
  String get settingsAboutHint =>
      'Runs entirely on the device. Nothing is uploaded.';

  @override
  String get settingsNotPersisted =>
      'Saved on this device; the thread count resets on restart.';

  @override
  String get benchTitle => 'Benchmark';

  @override
  String get benchIntro =>
      'Runs every downloaded speech model three times on one audio file you pick, so the numbers stay comparable. Each row uses the same engine path and metrics as the transcribe page.';

  @override
  String get benchUnavailableTitle => 'Nothing can run in this build';

  @override
  String get benchUnavailableEngine =>
      'The native speech engine is not available, so no run could produce real numbers.';

  @override
  String get benchHonesty =>
      'No performance figure is shown until a real run produces one.';

  @override
  String get benchSample => 'Fixed input';

  @override
  String get benchNoAudio => 'No audio selected';

  @override
  String get benchSampleHint =>
      'One file is used for the whole matrix so the rows can be compared. No tracking model ever runs.';

  @override
  String get benchChooseAudio => 'Choose audio';

  @override
  String get benchChangeAudio => 'Change audio';

  @override
  String get benchAudioRequired => 'Choose an audio file before running.';

  @override
  String get benchMatrix => 'CPU matrix';

  @override
  String get benchCpuOnly => 'CPU only — this build benchmarks no GPU or NPU.';

  @override
  String get benchFamily => 'Family';

  @override
  String get benchQuant => 'Quant';

  @override
  String get benchStatus => 'Status';

  @override
  String get benchStatusNotRun => 'Not run';

  @override
  String get benchStatusRunning => 'Running';

  @override
  String get benchStatusDone => 'Done';

  @override
  String get benchStatusFailed => 'Failed';

  @override
  String get benchStatusCancelled => 'Cancelled';

  @override
  String get benchNoModelsTitle => 'No downloaded speech models';

  @override
  String get benchNoModelsBody =>
      'Download a speech model in the Models tab first; only models already on this device are benchmarked.';

  @override
  String get benchResults => 'Results';

  @override
  String get benchRun => 'Run benchmark';

  @override
  String get benchCancel => 'Cancel';

  @override
  String get benchRuns => 'Successful runs';

  @override
  String get benchNoResultsTitle => 'No results yet';

  @override
  String get benchNoResultsBody =>
      'A run fills this list with the median wall clock, RTF and chars/s of three runs per model. Until then it stays empty.';

  @override
  String get benchExportJson => 'Export JSON';

  @override
  String get benchExportCsv => 'Export CSV';

  @override
  String get benchExportFailed => 'Export failed';

  @override
  String get benchDecodeTitle => 'Decode speed';

  @override
  String get benchDecodeHint =>
      'Decodes the same file three times with the built-in and the platform decoder and reports the median. No speech model runs.';

  @override
  String get benchDecodeRun => 'Compare decoders';

  @override
  String get benchDecodeBuiltin => 'Built-in (dr_libs)';

  @override
  String get benchDecodePlatform => 'Platform (MediaCodec)';

  @override
  String get benchDecodeElapsed => 'Decode';

  @override
  String get benchDecodeRealtime => 'Speed';

  @override
  String get benchDecodeAudioRequired =>
      'Choose an audio file before comparing.';

  @override
  String get benchExitHint => 'Tap the title seven times to leave.';

  @override
  String get settingsChunkNeural => 'Neural VAD';

  @override
  String get settingsVadHint =>
      'Neural VAD runs the selected VAD model on a separate sherpa-onnx worker, so speech is cut by what the model hears, not by loudness. It is not the ASR model.';

  @override
  String get settingsVadModel => 'VAD model';

  @override
  String get settingsVadModelNone => 'None selected';

  @override
  String get settingsVadThreshold => 'Speech threshold';

  @override
  String get settingsVadMinSilence => 'Min silence';

  @override
  String get settingsVadMinSpeech => 'Min speech';

  @override
  String get settingsVadMaxSeconds => 'Max speech';

  @override
  String settingsVadSecondsValue(String seconds) {
    return '$seconds s';
  }

  @override
  String get vadModelRequired =>
      'Select a downloaded VAD model in the Models tab to use neural VAD.';

  @override
  String get modelsVadSection => 'VAD models';

  @override
  String get modelsVadNote =>
      'A VAD model detects speech boundaries for the neural chunking mode. It cannot transcribe audio.';

  @override
  String get vadPreview => 'Speech preview';

  @override
  String get vadPreviewRun => 'Preview';

  @override
  String get vadPreviewAgain => 'Preview again';

  @override
  String get vadPreviewing => 'Analysing speech…';

  @override
  String vadPreviewSummary(int windows, String speech) {
    return '$windows window(s), $speech s of speech';
  }

  @override
  String vadPreviewWindow(int index) {
    return 'Window $index';
  }

  @override
  String vadPreviewSegment(String start, String end) {
    return '$start – $end s';
  }

  @override
  String get vadPreviewStale =>
      'Settings changed since this preview. Preview again.';

  @override
  String get transcribeCancel => 'Cancel';

  @override
  String get transcribeCancelling => 'Cancelling…';

  @override
  String get comingSoon => 'Coming soon';
}
