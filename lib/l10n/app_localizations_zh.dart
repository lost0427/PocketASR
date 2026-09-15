// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'PocketASR';

  @override
  String get navTranscribe => '转录';

  @override
  String get navQueue => '队列';

  @override
  String get navHistory => '历史';

  @override
  String get navModels => '模型';

  @override
  String get navSettings => '设置';

  @override
  String get transcribeTitle => '转录';

  @override
  String get transcribeBody => '选择音频文件，用设备上的引擎转成文字，并可一键复制。全程不联网。';

  @override
  String get queueTitle => '队列';

  @override
  String get queueBody => '一次排入多个文件，自由调整顺序，逐个查看进度。';

  @override
  String get historyTitle => '历史';

  @override
  String get historyBody => '每条转录都保存在本地，可以搜索、再次复制，也能从回收站恢复。';

  @override
  String get modelsTitle => '模型';

  @override
  String get modelsBody => '管理设备上的语音模型，下载前先看清体积与量化档。';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsAppearance => '外观';

  @override
  String get settingsLanguage => '语言';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => '中文';

  @override
  String get settingsNotPersisted => '主题与语言暂不持久化，重启后恢复默认。';

  @override
  String get comingSoon => '即将推出';
}
