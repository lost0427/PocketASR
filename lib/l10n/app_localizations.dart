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

  /// No description provided for @settingsNotPersisted.
  ///
  /// In en, this message translates to:
  /// **'Theme and language reset on restart for now.'**
  String get settingsNotPersisted;

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
