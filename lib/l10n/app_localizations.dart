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

  /// No description provided for @recordStart.
  ///
  /// In en, this message translates to:
  /// **'Record audio'**
  String get recordStart;

  /// No description provided for @recordStop.
  ///
  /// In en, this message translates to:
  /// **'Stop and use recording'**
  String get recordStop;

  /// No description provided for @recordDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard recording'**
  String get recordDiscard;

  /// No description provided for @recordEmpty.
  ///
  /// In en, this message translates to:
  /// **'No audio was recorded. Cancel and try again.'**
  String get recordEmpty;

  /// No description provided for @recordPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone access was denied. Enable it in system settings and try again.'**
  String get recordPermissionDenied;

  /// No description provided for @recordElapsed.
  ///
  /// In en, this message translates to:
  /// **'Recording · {seconds}s'**
  String recordElapsed(int seconds);

  /// No description provided for @modelsParameterCount.
  ///
  /// In en, this message translates to:
  /// **'{count}M parameters'**
  String modelsParameterCount(String count);

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

  /// No description provided for @fileTypeAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get fileTypeAudio;

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

  /// No description provided for @transcribeChooseModel.
  ///
  /// In en, this message translates to:
  /// **'Choose downloaded model'**
  String get transcribeChooseModel;

  /// No description provided for @transcribeChangeModel.
  ///
  /// In en, this message translates to:
  /// **'Change model'**
  String get transcribeChangeModel;

  /// No description provided for @transcribeModelRequired.
  ///
  /// In en, this message translates to:
  /// **'Select a downloaded speech model before starting.'**
  String get transcribeModelRequired;

  /// No description provided for @modelNeedsDecoder.
  ///
  /// In en, this message translates to:
  /// **'The selected model bundle is incomplete. Download it again from Models.'**
  String get modelNeedsDecoder;

  /// No description provided for @modelSelectionMissing.
  ///
  /// In en, this message translates to:
  /// **'The downloaded model selected last time is no longer on this device. Choose another one.'**
  String get modelSelectionMissing;

  /// No description provided for @modelPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose speech model'**
  String get modelPickerTitle;

  /// No description provided for @modelPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No downloaded speech models. Download one from Models first.'**
  String get modelPickerEmpty;

  /// No description provided for @modelPickerManage.
  ///
  /// In en, this message translates to:
  /// **'Open Models'**
  String get modelPickerManage;

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

  /// No description provided for @queueAddAudio.
  ///
  /// In en, this message translates to:
  /// **'Add audio'**
  String get queueAddAudio;

  /// No description provided for @queueChooseModel.
  ///
  /// In en, this message translates to:
  /// **'Choose model'**
  String get queueChooseModel;

  /// No description provided for @queueRun.
  ///
  /// In en, this message translates to:
  /// **'Run queue'**
  String get queueRun;

  /// No description provided for @queueEmpty.
  ///
  /// In en, this message translates to:
  /// **'Queue is empty'**
  String get queueEmpty;

  /// No description provided for @queueModelRequired.
  ///
  /// In en, this message translates to:
  /// **'Select a downloaded speech model before running.'**
  String get queueModelRequired;

  /// No description provided for @queueStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get queueStatusPending;

  /// No description provided for @queueStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get queueStatusRunning;

  /// No description provided for @queueStatusCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancelling'**
  String get queueStatusCancelling;

  /// No description provided for @queueStatusDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get queueStatusDone;

  /// No description provided for @queueStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get queueStatusFailed;

  /// No description provided for @queueStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get queueStatusCancelled;

  /// No description provided for @queueCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get queueCancel;

  /// No description provided for @queueRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get queueRetry;

  /// No description provided for @queueRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get queueRemove;

  /// No description provided for @queueMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get queueMoveUp;

  /// No description provided for @queueMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get queueMoveDown;

  /// No description provided for @engineBusyNote.
  ///
  /// In en, this message translates to:
  /// **'Another transcription is running. Wait for it to finish first.'**
  String get engineBusyNote;

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

  /// No description provided for @historySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search transcripts'**
  String get historySearchHint;

  /// No description provided for @historyScopeHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyScopeHistory;

  /// No description provided for @historyScopeTrash.
  ///
  /// In en, this message translates to:
  /// **'Trash'**
  String get historyScopeTrash;

  /// No description provided for @historyEmpty.
  ///
  /// In en, this message translates to:
  /// **'No transcripts'**
  String get historyEmpty;

  /// No description provided for @historyTrashEmpty.
  ///
  /// In en, this message translates to:
  /// **'Trash is empty'**
  String get historyTrashEmpty;

  /// No description provided for @historyCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get historyCopy;

  /// No description provided for @historyCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get historyCopied;

  /// No description provided for @historyMoveToTrash.
  ///
  /// In en, this message translates to:
  /// **'Move to trash'**
  String get historyMoveToTrash;

  /// No description provided for @historyRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get historyRestore;

  /// No description provided for @historyDeletePermanently.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get historyDeletePermanently;

  /// No description provided for @historyDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently?'**
  String get historyDeleteConfirmTitle;

  /// No description provided for @historyDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This transcript will be erased from this device and cannot be recovered.'**
  String get historyDeleteConfirmBody;

  /// No description provided for @historyDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Transcript'**
  String get historyDetailTitle;

  /// No description provided for @historyDetailCreated.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get historyDetailCreated;

  /// No description provided for @historyDetailAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get historyDetailAudio;

  /// No description provided for @historySearchLiteral.
  ///
  /// In en, this message translates to:
  /// **'Literal'**
  String get historySearchLiteral;

  /// No description provided for @historySearchSemantic.
  ///
  /// In en, this message translates to:
  /// **'Semantic'**
  String get historySearchSemantic;

  /// No description provided for @historySearchHybrid.
  ///
  /// In en, this message translates to:
  /// **'Hybrid'**
  String get historySearchHybrid;

  /// No description provided for @historySearchSemanticOff.
  ///
  /// In en, this message translates to:
  /// **'Select a downloaded embedding model to enable semantic search.'**
  String get historySearchSemanticOff;

  /// No description provided for @historyIndexing.
  ///
  /// In en, this message translates to:
  /// **'Indexing transcripts…'**
  String get historyIndexing;

  /// No description provided for @historyIndexFailed.
  ///
  /// In en, this message translates to:
  /// **'Indexing failed'**
  String get historyIndexFailed;

  /// No description provided for @historyIndexRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get historyIndexRetry;

  /// No description provided for @historyIndexRebuild.
  ///
  /// In en, this message translates to:
  /// **'Rebuild index'**
  String get historyIndexRebuild;

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

  /// No description provided for @modelsAsrSection.
  ///
  /// In en, this message translates to:
  /// **'Speech models'**
  String get modelsAsrSection;

  /// No description provided for @modelsEmbeddingSection.
  ///
  /// In en, this message translates to:
  /// **'Embedding models'**
  String get modelsEmbeddingSection;

  /// No description provided for @modelsEmbeddingNote.
  ///
  /// In en, this message translates to:
  /// **'Embedding models power semantic search in History. They cannot transcribe audio.'**
  String get modelsEmbeddingNote;

  /// No description provided for @modelsEmbeddingError.
  ///
  /// In en, this message translates to:
  /// **'Could not load the embedding model:'**
  String get modelsEmbeddingError;

  /// No description provided for @modelsUse.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get modelsUse;

  /// No description provided for @modelsInUse.
  ///
  /// In en, this message translates to:
  /// **'In use'**
  String get modelsInUse;

  /// No description provided for @modelsBusyNote.
  ///
  /// In en, this message translates to:
  /// **'A transcription is running. Stop it before switching models.'**
  String get modelsBusyNote;

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

  /// No description provided for @settingsActiveModel.
  ///
  /// In en, this message translates to:
  /// **'Active model'**
  String get settingsActiveModel;

  /// No description provided for @settingsActiveModelNone.
  ///
  /// In en, this message translates to:
  /// **'None selected'**
  String get settingsActiveModelNone;

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

  /// No description provided for @settingsChunking.
  ///
  /// In en, this message translates to:
  /// **'Chunking'**
  String get settingsChunking;

  /// No description provided for @settingsChunkMode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get settingsChunkMode;

  /// No description provided for @settingsChunkFixed.
  ///
  /// In en, this message translates to:
  /// **'Fixed length'**
  String get settingsChunkFixed;

  /// No description provided for @settingsChunkEnergy.
  ///
  /// In en, this message translates to:
  /// **'Energy detection'**
  String get settingsChunkEnergy;

  /// No description provided for @settingsChunkSeconds.
  ///
  /// In en, this message translates to:
  /// **'Chunk length'**
  String get settingsChunkSeconds;

  /// No description provided for @settingsChunkSecondsValue.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String settingsChunkSecondsValue(int seconds);

  /// No description provided for @settingsEnergyThreshold.
  ///
  /// In en, this message translates to:
  /// **'Energy threshold'**
  String get settingsEnergyThreshold;

  /// No description provided for @settingsSpeechPad.
  ///
  /// In en, this message translates to:
  /// **'Speech padding'**
  String get settingsSpeechPad;

  /// No description provided for @settingsSpeechPadValue.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms'**
  String settingsSpeechPadValue(int ms);

  /// No description provided for @settingsChunkHint.
  ///
  /// In en, this message translates to:
  /// **'Energy detection is a loudness gate over the audio, not a neural VAD. Overlap stays off: this build does not merge repeated text at chunk seams.'**
  String get settingsChunkHint;

  /// No description provided for @settingsChunkReset.
  ///
  /// In en, this message translates to:
  /// **'Reset chunking'**
  String get settingsChunkReset;

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
  /// **'Saved on this device; the thread count resets on restart.'**
  String get settingsNotPersisted;

  /// No description provided for @benchTitle.
  ///
  /// In en, this message translates to:
  /// **'Benchmark'**
  String get benchTitle;

  /// No description provided for @benchIntro.
  ///
  /// In en, this message translates to:
  /// **'Runs every downloaded speech model three times on one audio file you pick, so the numbers stay comparable. Each row uses the same engine path and metrics as the transcribe page.'**
  String get benchIntro;

  /// No description provided for @benchUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing can run in this build'**
  String get benchUnavailableTitle;

  /// No description provided for @benchUnavailableEngine.
  ///
  /// In en, this message translates to:
  /// **'The native speech engine is not available, so no run could produce real numbers.'**
  String get benchUnavailableEngine;

  /// No description provided for @benchHonesty.
  ///
  /// In en, this message translates to:
  /// **'No performance figure is shown until a real run produces one.'**
  String get benchHonesty;

  /// No description provided for @benchSample.
  ///
  /// In en, this message translates to:
  /// **'Fixed input'**
  String get benchSample;

  /// No description provided for @benchNoAudio.
  ///
  /// In en, this message translates to:
  /// **'No audio selected'**
  String get benchNoAudio;

  /// No description provided for @benchSampleHint.
  ///
  /// In en, this message translates to:
  /// **'One file is used for the whole matrix so the rows can be compared. No tracking model ever runs.'**
  String get benchSampleHint;

  /// No description provided for @benchChooseAudio.
  ///
  /// In en, this message translates to:
  /// **'Choose audio'**
  String get benchChooseAudio;

  /// No description provided for @benchChangeAudio.
  ///
  /// In en, this message translates to:
  /// **'Change audio'**
  String get benchChangeAudio;

  /// No description provided for @benchAudioRequired.
  ///
  /// In en, this message translates to:
  /// **'Choose an audio file before running.'**
  String get benchAudioRequired;

  /// No description provided for @benchMatrix.
  ///
  /// In en, this message translates to:
  /// **'CPU matrix'**
  String get benchMatrix;

  /// No description provided for @benchCpuOnly.
  ///
  /// In en, this message translates to:
  /// **'CPU only — this build benchmarks no GPU or NPU.'**
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

  /// No description provided for @benchStatusNotRun.
  ///
  /// In en, this message translates to:
  /// **'Not run'**
  String get benchStatusNotRun;

  /// No description provided for @benchStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get benchStatusRunning;

  /// No description provided for @benchStatusDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get benchStatusDone;

  /// No description provided for @benchStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get benchStatusFailed;

  /// No description provided for @benchStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get benchStatusCancelled;

  /// No description provided for @benchNoModelsTitle.
  ///
  /// In en, this message translates to:
  /// **'No downloaded speech models'**
  String get benchNoModelsTitle;

  /// No description provided for @benchNoModelsBody.
  ///
  /// In en, this message translates to:
  /// **'Download a speech model in the Models tab first; only models already on this device are benchmarked.'**
  String get benchNoModelsBody;

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

  /// No description provided for @benchCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get benchCancel;

  /// No description provided for @benchRuns.
  ///
  /// In en, this message translates to:
  /// **'Successful runs'**
  String get benchRuns;

  /// No description provided for @benchNoResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No results yet'**
  String get benchNoResultsTitle;

  /// No description provided for @benchNoResultsBody.
  ///
  /// In en, this message translates to:
  /// **'A run fills this list with the median wall clock, RTF and tokens/s of three runs per model. Until then it stays empty.'**
  String get benchNoResultsBody;

  /// No description provided for @benchExportJson.
  ///
  /// In en, this message translates to:
  /// **'Export JSON'**
  String get benchExportJson;

  /// No description provided for @benchExportCsv.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get benchExportCsv;

  /// No description provided for @benchExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed'**
  String get benchExportFailed;

  /// No description provided for @benchExitHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the title seven times to leave.'**
  String get benchExitHint;

  /// No description provided for @settingsChunkNeural.
  ///
  /// In en, this message translates to:
  /// **'Neural VAD'**
  String get settingsChunkNeural;

  /// No description provided for @settingsVadHint.
  ///
  /// In en, this message translates to:
  /// **'Neural VAD runs a real Silero model on a separate sherpa-onnx worker, so speech is cut by what the model hears, not by loudness. It is not the ASR model.'**
  String get settingsVadHint;

  /// No description provided for @settingsVadModel.
  ///
  /// In en, this message translates to:
  /// **'VAD model'**
  String get settingsVadModel;

  /// No description provided for @settingsVadModelNone.
  ///
  /// In en, this message translates to:
  /// **'None selected'**
  String get settingsVadModelNone;

  /// No description provided for @settingsVadThreshold.
  ///
  /// In en, this message translates to:
  /// **'Speech threshold'**
  String get settingsVadThreshold;

  /// No description provided for @settingsVadMinSilence.
  ///
  /// In en, this message translates to:
  /// **'Min silence'**
  String get settingsVadMinSilence;

  /// No description provided for @settingsVadMinSpeech.
  ///
  /// In en, this message translates to:
  /// **'Min speech'**
  String get settingsVadMinSpeech;

  /// No description provided for @settingsVadMaxSeconds.
  ///
  /// In en, this message translates to:
  /// **'Max speech'**
  String get settingsVadMaxSeconds;

  /// No description provided for @settingsVadSecondsValue.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String settingsVadSecondsValue(String seconds);

  /// No description provided for @vadModelRequired.
  ///
  /// In en, this message translates to:
  /// **'Select a downloaded VAD model in the Models tab to use neural VAD.'**
  String get vadModelRequired;

  /// No description provided for @modelsVadSection.
  ///
  /// In en, this message translates to:
  /// **'VAD models'**
  String get modelsVadSection;

  /// No description provided for @modelsVadNote.
  ///
  /// In en, this message translates to:
  /// **'A VAD model detects speech boundaries for the neural chunking mode. It cannot transcribe audio.'**
  String get modelsVadNote;

  /// No description provided for @vadPreview.
  ///
  /// In en, this message translates to:
  /// **'Speech preview'**
  String get vadPreview;

  /// No description provided for @vadPreviewRun.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get vadPreviewRun;

  /// No description provided for @vadPreviewAgain.
  ///
  /// In en, this message translates to:
  /// **'Preview again'**
  String get vadPreviewAgain;

  /// No description provided for @vadPreviewing.
  ///
  /// In en, this message translates to:
  /// **'Analysing speech…'**
  String get vadPreviewing;

  /// No description provided for @vadPreviewSummary.
  ///
  /// In en, this message translates to:
  /// **'{windows} window(s), {speech} s of speech'**
  String vadPreviewSummary(int windows, String speech);

  /// No description provided for @vadPreviewWindow.
  ///
  /// In en, this message translates to:
  /// **'Window {index}'**
  String vadPreviewWindow(int index);

  /// No description provided for @vadPreviewSegment.
  ///
  /// In en, this message translates to:
  /// **'{start} – {end} s'**
  String vadPreviewSegment(String start, String end);

  /// No description provided for @vadPreviewStale.
  ///
  /// In en, this message translates to:
  /// **'Settings changed since this preview. Preview again.'**
  String get vadPreviewStale;

  /// No description provided for @transcribeCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get transcribeCancel;

  /// No description provided for @transcribeCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancelling…'**
  String get transcribeCancelling;

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
