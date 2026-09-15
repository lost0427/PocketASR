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
  String get settingsNotPersisted =>
      'Theme and language reset on restart for now.';

  @override
  String get comingSoon => 'Coming soon';
}
