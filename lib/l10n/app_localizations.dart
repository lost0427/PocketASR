import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'PocketASR'**
  String get appTitle;

  /// No description provided for @navTranscribe.
  ///
  /// In en, this message translates to:
  /// **'Transcribe'**
  String get navTranscribe;

  /// No description provided for @navQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get navQueue;

  /// No description provided for @navHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get navHistory;

  /// No description provided for @navModels.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get navModels;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @transcribeTitle.
  ///
  /// In en, this message translates to:
  /// **'Transcribe'**
  String get transcribeTitle;

  /// No description provided for @transcribeBody.
  ///
  /// In en, this message translates to:
  /// **'Pick an audio file, run it through the on-device engine, and copy the text out. Nothing leaves the device.'**
  String get transcribeBody;

  /// No description provided for @transcribeChooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose audio file'**
  String get transcribeChooseFile;

  /// No description provided for @transcribeChangeFile.
  ///
  /// In en, this message translates to:
  /// **'Change file'**
  String get transcribeChangeFile;

  /// No description provided for @transcribeNoFile.
  ///
  /// In en, this message translates to:
  /// **'No audio selected'**
  String get transcribeNoFile;

  /// No description provided for @transcribeFileHint.
  ///
  /// In en, this message translates to:
  /// **'WAV · M4A · MP3, decoded on-device'**
  String get transcribeFileHint;

  /// No description provided for @transcribePickerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'File picking is not wired up yet.'**
  String get transcribePickerUnavailable;

  /// No description provided for @transcribeEngineUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'On-device engine unavailable'**
  String get transcribeEngineUnavailableTitle;

  /// No description provided for @transcribeEngineUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'This build ships without the native speech engine, so transcription cannot run yet. Nothing is faked and no audio leaves the device.'**
  String get transcribeEngineUnavailableBody;

  /// No description provided for @transcribeEngineSection.
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get transcribeEngineSection;

  /// No description provided for @transcribeModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get transcribeModel;

  /// No description provided for @transcribeModelNone.
  ///
  /// In en, this message translates to:
  /// **'Not selected'**
  String get transcribeModelNone;

  /// No description provided for @transcribeBackend.
  ///
  /// In en, this message translates to:
  /// **'Backend'**
  String get transcribeBackend;

  /// No description provided for @transcribeBackendCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get transcribeBackendCpu;

  /// No description provided for @transcribeStart.
  ///
  /// In en, this message translates to:
  /// **'Start transcription'**
  String get transcribeStart;

  /// No description provided for @transcribeStartUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Transcription is not available in this build.'**
  String get transcribeStartUnavailable;

  /// No description provided for @transcribeProgress.
  ///
  /// In en, this message translates to:
  /// **'Progress'**
  String get transcribeProgress;

  /// No description provided for @transcribeProgressIdle.
  ///
  /// In en, this message translates to:
  /// **'Waiting to start'**
  String get transcribeProgressIdle;

  /// No description provided for @transcribeMetrics.
  ///
  /// In en, this message translates to:
  /// **'Live metrics'**
  String get transcribeMetrics;

  /// No description provided for @transcribeResult.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get transcribeResult;

  /// No description provided for @transcribeResultEmpty.
  ///
  /// In en, this message translates to:
  /// **'The transcript will appear here.'**
  String get transcribeResultEmpty;

  /// No description provided for @transcribeCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get transcribeCopy;

  /// No description provided for @transcribeCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get transcribeCopied;

  /// No description provided for @metricTokensPerSec.
  ///
  /// In en, this message translates to:
  /// **'tokens/s'**
  String get metricTokensPerSec;

  /// No description provided for @metricCharsPerSec.
  ///
  /// In en, this message translates to:
  /// **'chars/s'**
  String get metricCharsPerSec;

  /// No description provided for @metricRtf.
  ///
  /// In en, this message translates to:
  /// **'RTF'**
  String get metricRtf;

  /// No description provided for @metricElapsed.
  ///
  /// In en, this message translates to:
  /// **'Elapsed'**
  String get metricElapsed;

  /// No description provided for @metricCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get metricCpu;

  /// No description provided for @metricMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get metricMemory;

  /// No description provided for @metricUnavailable.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get metricUnavailable;

  /// No description provided for @queueTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get queueTitle;

  /// No description provided for @queueBody.
  ///
  /// In en, this message translates to:
  /// **'Line up several files at once, reorder them, and watch each one finish in turn.'**
  String get queueBody;

  /// No description provided for @historyTitle.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyTitle;

  /// No description provided for @historyBody.
  ///
  /// In en, this message translates to:
  /// **'Every transcript is stored locally, so you can search it, copy it again, or restore it from the trash.'**
  String get historyBody;

  /// No description provided for @modelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get modelsTitle;

  /// No description provided for @modelsBody.
  ///
  /// In en, this message translates to:
  /// **'Manage the speech models kept on the device, with size and quantization shown before you download.'**
  String get modelsBody;

  /// No description provided for @modelsDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get modelsDownload;

  /// No description provided for @modelsDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get modelsDownloading;

  /// No description provided for @modelsCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get modelsCancel;

  /// No description provided for @modelsNotDownloadable.
  ///
  /// In en, this message translates to:
  /// **'Not available for download'**
  String get modelsNotDownloadable;

  /// No description provided for @modelsDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get modelsDownloaded;

  /// No description provided for @modelsNotDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded'**
  String get modelsNotDownloaded;

  /// No description provided for @modelsDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get modelsDelete;

  /// No description provided for @modelsDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete downloaded model?'**
  String get modelsDeleteConfirmTitle;

  /// No description provided for @modelsDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'{name} will be removed from this device. You can download it again later.'**
  String modelsDeleteConfirmBody(String name);

  /// No description provided for @modelsDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get modelsDownloadFailed;

  /// No description provided for @modelsTotalUsage.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get modelsTotalUsage;

  /// No description provided for @modelsNoModels.
  ///
  /// In en, this message translates to:
  /// **'No models available'**
  String get modelsNoModels;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get languageChinese;

  /// No description provided for @settingsModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get settingsModel;

  /// No description provided for @settingsModelFamily.
  ///
  /// In en, this message translates to:
  /// **'Model family'**
  String get settingsModelFamily;

  /// No description provided for @settingsQuantization.
  ///
  /// In en, this message translates to:
  /// **'Quantization'**
  String get settingsQuantization;

  /// No description provided for @settingsPerformance.
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get settingsPerformance;

  /// No description provided for @settingsThreads.
  ///
  /// In en, this message translates to:
  /// **'Threads'**
  String get settingsThreads;

  /// No description provided for @settingsThreadsValue.
  ///
  /// In en, this message translates to:
  /// **'{used} of {max}'**
  String settingsThreadsValue(int used, int max);

  /// No description provided for @settingsThreadsHint.
  ///
  /// In en, this message translates to:
  /// **'Defaults to half the CPU cores.'**
  String get settingsThreadsHint;

  /// No description provided for @settingsAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get settingsAudio;

  /// No description provided for @settingsLoudness.
  ///
  /// In en, this message translates to:
  /// **'Loudness normalization'**
  String get settingsLoudness;

  /// No description provided for @settingsLoudnessHint.
  ///
  /// In en, this message translates to:
  /// **'Lifts quiet recordings to the target level before transcription. This is loudness, not peak.'**
  String get settingsLoudnessHint;

  /// No description provided for @settingsLoudnessTarget.
  ///
  /// In en, this message translates to:
  /// **'Target loudness'**
  String get settingsLoudnessTarget;

  /// No description provided for @settingsLoudnessUnit.
  ///
  /// In en, this message translates to:
  /// **'LUFS'**
  String get settingsLoudnessUnit;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String settingsVersion(String version);

  /// No description provided for @settingsAboutHint.
  ///
  /// In en, this message translates to:
  /// **'Runs entirely on the device. Nothing is uploaded.'**
  String get settingsAboutHint;

  /// No description provided for @settingsNotPersisted.
  ///
  /// In en, this message translates to:
  /// **'Settings reset on restart for now.'**
  String get settingsNotPersisted;

  /// No description provided for @benchTitle.
  ///
  /// In en, this message translates to:
  /// **'Benchmark'**
  String get benchTitle;

  /// No description provided for @benchIntro.
  ///
  /// In en, this message translates to:
  /// **'Runs the same fixed sample across the CPU matrix so the numbers stay comparable. Each cell uses the same metrics as the transcribe page.'**
  String get benchIntro;

  /// No description provided for @benchUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing can run in this build'**
  String get benchUnavailableTitle;

  /// No description provided for @benchUnavailableEngine.
  ///
  /// In en, this message translates to:
  /// **'The native speech engine is not bundled, so no run could produce real numbers.'**
  String get benchUnavailableEngine;

  /// No description provided for @benchUnavailableSample.
  ///
  /// In en, this message translates to:
  /// **'The fixed sample {asset} is missing, so runs would not be comparable.'**
  String benchUnavailableSample(String asset);

  /// No description provided for @benchHonesty.
  ///
  /// In en, this message translates to:
  /// **'No performance figure is shown until a real run produces one.'**
  String get benchHonesty;

  /// No description provided for @benchMatrix.
  ///
  /// In en, this message translates to:
  /// **'CPU matrix'**
  String get benchMatrix;

  /// No description provided for @benchCpuOnly.
  ///
  /// In en, this message translates to:
  /// **'CPU only — GPU and NPU are deferred.'**
  String get benchCpuOnly;

  /// No description provided for @benchFamily.
  ///
  /// In en, this message translates to:
  /// **'Family'**
  String get benchFamily;

  /// No description provided for @benchQuant.
  ///
  /// In en, this message translates to:
  /// **'Quant'**
  String get benchQuant;

  /// No description provided for @benchStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get benchStatus;

  /// No description provided for @benchStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get benchStatusUnavailable;

  /// No description provided for @benchStatusNotRun.
  ///
  /// In en, this message translates to:
  /// **'Not run'**
  String get benchStatusNotRun;

  /// No description provided for @benchResults.
  ///
  /// In en, this message translates to:
  /// **'Results'**
  String get benchResults;

  /// No description provided for @benchRun.
  ///
  /// In en, this message translates to:
  /// **'Run benchmark'**
  String get benchRun;

  /// No description provided for @benchNoResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No results yet'**
  String get benchNoResultsTitle;

  /// No description provided for @benchNoResultsBody.
  ///
  /// In en, this message translates to:
  /// **'A run fills this table with load time, wall clock, RTF, tokens/s and peak memory. Until then it stays empty.'**
  String get benchNoResultsBody;

  /// No description provided for @benchExitHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the title seven times to leave.'**
  String get benchExitHint;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
