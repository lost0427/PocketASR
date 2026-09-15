// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

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
  String get metricTokensPerSec => 'tokens/s';

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
  String get metricUnavailable => '—';

  @override
  String get queueTitle => 'Queue';

  @override
  String get queueBody =>
      'Line up several files at once, reorder them, and watch each one finish in turn.';

  @override
  String get historyTitle => 'History';

  @override
  String get historyBody =>
      'Every transcript is stored locally, so you can search it, copy it again, or restore it from the trash.';

  @override
  String get modelsTitle => 'Models';

  @override
  String get modelsBody =>
      'Manage the speech models kept on the device, with size and quantization shown before you download.';

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
  String get settingsModelFamily => 'Model family';

  @override
  String get settingsQuantization => 'Quantization';

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
  String get settingsAudio => 'Audio';

  @override
  String get settingsLoudness => 'Loudness normalization';

  @override
  String get settingsLoudnessHint =>
      'Lifts quiet recordings to the target level before transcription. This is loudness, not peak.';

  @override
  String get settingsLoudnessTarget => 'Target loudness';

  @override
  String get settingsLoudnessUnit => 'LUFS';

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
  String get settingsNotPersisted => 'Settings reset on restart for now.';

  @override
  String get benchTitle => 'Benchmark';

  @override
  String get benchIntro =>
      'Runs the same fixed sample across the CPU matrix so the numbers stay comparable. Each cell uses the same metrics as the transcribe page.';

  @override
  String get benchUnavailableTitle => 'Nothing can run in this build';

  @override
  String get benchUnavailableEngine =>
      'The native speech engine is not bundled, so no run could produce real numbers.';

  @override
  String benchUnavailableSample(String asset) {
    return 'The fixed sample $asset is missing, so runs would not be comparable.';
  }

  @override
  String get benchHonesty =>
      'No performance figure is shown until a real run produces one.';

  @override
  String get benchMatrix => 'CPU matrix';

  @override
  String get benchCpuOnly => 'CPU only — GPU and NPU are deferred.';

  @override
  String get benchFamily => 'Family';

  @override
  String get benchQuant => 'Quant';

  @override
  String get benchStatus => 'Status';

  @override
  String get benchStatusUnavailable => 'Unavailable';

  @override
  String get benchStatusNotRun => 'Not run';

  @override
  String get benchResults => 'Results';

  @override
  String get benchRun => 'Run benchmark';

  @override
  String get benchNoResultsTitle => 'No results yet';

  @override
  String get benchNoResultsBody =>
      'A run fills this table with load time, wall clock, RTF, tokens/s and peak memory. Until then it stays empty.';

  @override
  String get benchExitHint => 'Tap the title seven times to leave.';

  @override
  String get comingSoon => 'Coming soon';
}
