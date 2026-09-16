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
  String get transcribeChooseFile => '选择音频文件';

  @override
  String get transcribeChangeFile => '更换文件';

  @override
  String get transcribeNoFile => '尚未选择音频';

  @override
  String get transcribeFileHint => 'WAV · M4A · MP3，本地解码';

  @override
  String get transcribePickerUnavailable => '文件选择功能尚未接入。';

  @override
  String get transcribeEngineUnavailableTitle => '本地引擎不可用';

  @override
  String get transcribeEngineUnavailableBody =>
      '当前构建未包含本地语音引擎，暂时无法转录。不会伪造结果，也不会把音频传出设备。';

  @override
  String get transcribeEngineSection => '引擎';

  @override
  String get transcribeModel => '模型';

  @override
  String get transcribeModelNone => '未选择';

  @override
  String get transcribeBackend => '后端';

  @override
  String get transcribeBackendCpu => 'CPU';

  @override
  String get transcribeStart => '开始转录';

  @override
  String get transcribeStartUnavailable => '当前构建无法进行转录。';

  @override
  String get transcribeProgress => '进度';

  @override
  String get transcribeProgressIdle => '等待开始';

  @override
  String get transcribeMetrics => '实时指标';

  @override
  String get transcribeResult => '结果';

  @override
  String get transcribeResultEmpty => '转录文本会显示在这里。';

  @override
  String get transcribeCopy => '复制';

  @override
  String get transcribeCopied => '已复制到剪贴板';

  @override
  String get metricTokensPerSec => 'tokens/s';

  @override
  String get metricCharsPerSec => '字/s';

  @override
  String get metricRtf => 'RTF';

  @override
  String get metricElapsed => '耗时';

  @override
  String get metricCpu => 'CPU';

  @override
  String get metricMemory => '内存';

  @override
  String get metricUnavailable => '—';

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
  String get modelsDownload => '下载';

  @override
  String get modelsDownloading => '下载中';

  @override
  String get modelsCancel => '取消';

  @override
  String get modelsNotDownloadable => '不可下载';

  @override
  String get modelsDownloaded => '已下载';

  @override
  String get modelsNotDownloaded => '未下载';

  @override
  String get modelsDelete => '删除';

  @override
  String get modelsDeleteConfirmTitle => '删除已下载的模型？';

  @override
  String modelsDeleteConfirmBody(String name) {
    return '$name 将从本机删除，之后可以重新下载。';
  }

  @override
  String get modelsDownloadFailed => '下载失败';

  @override
  String get modelsTotalUsage => '本机占用';

  @override
  String get modelsNoModels => '没有可用模型';

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
  String get settingsModel => '模型';

  @override
  String get settingsModelFamily => '模型家族';

  @override
  String get settingsQuantization => '量化档';

  @override
  String get settingsPerformance => '性能';

  @override
  String get settingsThreads => '线程数';

  @override
  String settingsThreadsValue(int used, int max) {
    return '$used / $max';
  }

  @override
  String get settingsThreadsHint => '默认使用一半的 CPU 核心。';

  @override
  String get settingsAudio => '音频';

  @override
  String get settingsLoudness => '响度归一';

  @override
  String get settingsLoudnessHint => '转录前把偏小的声音抬到目标响度。这是响度，不是峰值。';

  @override
  String get settingsLoudnessTarget => '目标响度';

  @override
  String get settingsLoudnessUnit => 'LUFS';

  @override
  String get settingsAbout => '关于';

  @override
  String settingsVersion(String version) {
    return '版本 $version';
  }

  @override
  String get settingsAboutHint => '完全在本机运行，不会上传任何内容。';

  @override
  String get settingsNotPersisted => '设置暂不持久化，重启后恢复默认。';

  @override
  String get benchTitle => '性能基准';

  @override
  String get benchIntro => '对同一段固定素材跑完整个 CPU 矩阵，数字才可比较。每格都复用转录页的同一套指标口径。';

  @override
  String get benchUnavailableTitle => '当前构建无法运行';

  @override
  String get benchUnavailableEngine => '未打包本地语音引擎，因此无法产生真实数据。';

  @override
  String benchUnavailableSample(String asset) {
    return '缺少固定素材 $asset，跑出来的结果无法比较。';
  }

  @override
  String get benchHonesty => '没有真实运行之前，不显示任何性能数字。';

  @override
  String get benchMatrix => 'CPU 矩阵';

  @override
  String get benchCpuOnly => '仅 CPU——GPU 与 NPU 暂缓。';

  @override
  String get benchFamily => '家族';

  @override
  String get benchQuant => '量化';

  @override
  String get benchStatus => '状态';

  @override
  String get benchStatusUnavailable => '不可用';

  @override
  String get benchStatusNotRun => '未运行';

  @override
  String get benchResults => '结果';

  @override
  String get benchRun => '运行基准测试';

  @override
  String get benchNoResultsTitle => '暂无结果';

  @override
  String get benchNoResultsBody => '运行后会填上加载耗时、墙钟、RTF、tokens/s 与峰值内存。在此之前保持为空。';

  @override
  String get benchExitHint => '连续点击标题七次可退出。';

  @override
  String get comingSoon => '即将推出';
}
