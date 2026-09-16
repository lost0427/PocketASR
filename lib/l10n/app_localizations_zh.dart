// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get recordStart => '录制音频';

  @override
  String get recordStop => '停止并使用录音';

  @override
  String get recordDiscard => '放弃录音';

  @override
  String get recordEmpty => '未录到音频，请放弃本次录音后重试。';

  @override
  String get recordPermissionDenied => '未获得麦克风权限。请在系统设置中允许后重试。';

  @override
  String recordElapsed(int seconds) {
    return '录音中 · $seconds 秒';
  }

  @override
  String modelsParameterCount(String count) {
    return '$count 百万参数';
  }

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
  String get fileTypeAudio => '音频';

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
  String get transcribeChooseModel => '选择已下载模型';

  @override
  String get transcribeChangeModel => '更换模型';

  @override
  String get transcribeModelRequired => '开始前请先选择已下载的语音模型。';

  @override
  String get modelNeedsDecoder => '所选模型包不完整，请前往“模型”页重新下载。';

  @override
  String get modelSelectionMissing => '上次选择的已下载模型已不在本机，请选择其他模型。';

  @override
  String get modelPickerTitle => '选择语音模型';

  @override
  String get modelPickerEmpty => '本机没有已下载的语音模型，请先前往“模型”页下载。';

  @override
  String get modelPickerManage => '打开模型页';

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
  String get queueAddAudio => '添加音频';

  @override
  String get queueChooseModel => '选择模型';

  @override
  String get queueRun => '运行队列';

  @override
  String get queueEmpty => '队列为空';

  @override
  String get queueModelRequired => '运行前请先选择已下载的语音模型。';

  @override
  String get queueStatusPending => '排队中';

  @override
  String get queueStatusRunning => '运行中';

  @override
  String get queueStatusCancelling => '正在取消';

  @override
  String get queueStatusDone => '已完成';

  @override
  String get queueStatusFailed => '失败';

  @override
  String get queueStatusCancelled => '已取消';

  @override
  String get queueCancel => '取消';

  @override
  String get queueRetry => '重试';

  @override
  String get queueRemove => '移除';

  @override
  String get queueMoveUp => '上移';

  @override
  String get queueMoveDown => '下移';

  @override
  String get engineBusyNote => '正在执行另一项转录，请等待其完成。';

  @override
  String get historyTitle => '历史';

  @override
  String get historyBody => '每条转录都保存在本地，可以搜索、再次复制，也能从回收站恢复。';

  @override
  String get historySearchHint => '搜索转录记录';

  @override
  String get historyScopeHistory => '历史';

  @override
  String get historyScopeTrash => '回收站';

  @override
  String get historyEmpty => '暂无转录记录';

  @override
  String get historyTrashEmpty => '回收站为空';

  @override
  String get historyCopy => '复制';

  @override
  String get historyCopied => '已复制到剪贴板';

  @override
  String get historyMoveToTrash => '移入回收站';

  @override
  String get historyRestore => '恢复';

  @override
  String get historyDeletePermanently => '永久删除';

  @override
  String get historyDeleteConfirmTitle => '永久删除？';

  @override
  String get historyDeleteConfirmBody => '该转录将从本机彻底删除，无法恢复。';

  @override
  String get historyDetailTitle => '转录详情';

  @override
  String get historyDetailCreated => '创建时间';

  @override
  String get historyDetailAudio => '音频';

  @override
  String get historySearchLiteral => '字面';

  @override
  String get historySearchSemantic => '语义';

  @override
  String get historySearchHybrid => '混合';

  @override
  String get historySearchSemanticOff => '选择已下载的向量模型后即可使用语义检索。';

  @override
  String get historyIndexing => '正在建立索引…';

  @override
  String get historyIndexFailed => '索引失败';

  @override
  String get historyIndexRetry => '重试';

  @override
  String get historyIndexRebuild => '重建索引';

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
  String get modelsAsrSection => '语音模型';

  @override
  String get modelsEmbeddingSection => '向量模型';

  @override
  String get modelsEmbeddingNote => '向量模型用于历史页的语义检索，不能用于转录。';

  @override
  String get modelsEmbeddingError => '无法加载向量模型：';

  @override
  String get modelsUse => '使用';

  @override
  String get modelsInUse => '使用中';

  @override
  String get modelsBusyNote => '正在转录，停止后才能切换模型。';

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
  String get settingsActiveModel => '当前模型';

  @override
  String get settingsActiveModelNone => '未选择';

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
  String get settingsChunking => '切割';

  @override
  String get settingsChunkMode => '模式';

  @override
  String get settingsChunkFixed => '固定时长';

  @override
  String get settingsChunkEnergy => '能量检测';

  @override
  String get settingsChunkSeconds => '分块时长';

  @override
  String settingsChunkSecondsValue(int seconds) {
    return '$seconds 秒';
  }

  @override
  String get settingsEnergyThreshold => '能量阈值';

  @override
  String get settingsSpeechPad => '语音补白';

  @override
  String settingsSpeechPadValue(int ms) {
    return '$ms 毫秒';
  }

  @override
  String get settingsChunkHint =>
      '能量检测是按响度开门限，不是神经 VAD。默认不重叠：本构建不会合并分块接缝处重复的文本。';

  @override
  String get settingsChunkReset => '恢复默认切割';

  @override
  String get settingsAbout => '关于';

  @override
  String settingsVersion(String version) {
    return '版本 $version';
  }

  @override
  String get settingsAboutHint => '完全在本机运行，不会上传任何内容。';

  @override
  String get settingsNotPersisted => '已保存在本机；线程数重启后恢复默认。';

  @override
  String get benchTitle => '性能基准';

  @override
  String get benchIntro =>
      '对每个已下载的语音模型，在你选定的一段音频上各跑三次，数字才可比较。每行都复用转录页的同一套引擎路径与指标口径。';

  @override
  String get benchUnavailableTitle => '当前构建无法运行';

  @override
  String get benchUnavailableEngine => '本地语音引擎不可用，因此无法产生真实数据。';

  @override
  String get benchHonesty => '没有真实运行之前，不显示任何性能数字。';

  @override
  String get benchSample => '固定输入';

  @override
  String get benchNoAudio => '尚未选择音频';

  @override
  String get benchSampleHint => '整个矩阵共用同一个文件，行与行之间才可比较。不会运行任何追踪模型。';

  @override
  String get benchChooseAudio => '选择音频';

  @override
  String get benchChangeAudio => '更换音频';

  @override
  String get benchAudioRequired => '运行前请先选择音频文件。';

  @override
  String get benchMatrix => 'CPU 矩阵';

  @override
  String get benchCpuOnly => '仅 CPU——本构建不对 GPU 或 NPU 做基准。';

  @override
  String get benchFamily => '家族';

  @override
  String get benchQuant => '量化';

  @override
  String get benchStatus => '状态';

  @override
  String get benchStatusNotRun => '未运行';

  @override
  String get benchStatusRunning => '运行中';

  @override
  String get benchStatusDone => '已完成';

  @override
  String get benchStatusFailed => '失败';

  @override
  String get benchStatusCancelled => '已取消';

  @override
  String get benchNoModelsTitle => '没有已下载的语音模型';

  @override
  String get benchNoModelsBody => '请先在“模型”页下载语音模型；只有本机已有的模型才会参与基准测试。';

  @override
  String get benchResults => '结果';

  @override
  String get benchRun => '运行基准测试';

  @override
  String get benchCancel => '取消';

  @override
  String get benchRuns => '有效次数';

  @override
  String get benchNoResultsTitle => '暂无结果';

  @override
  String get benchNoResultsBody =>
      '运行后会列出每个模型三次运行的中位墙钟、RTF 与 tokens/s。在此之前保持为空。';

  @override
  String get benchExportJson => '导出 JSON';

  @override
  String get benchExportCsv => '导出 CSV';

  @override
  String get benchExportFailed => '导出失败';

  @override
  String get benchExitHint => '连续点击标题七次可退出。';

  @override
  String get settingsChunkNeural => '神经 VAD';

  @override
  String get settingsVadHint =>
      '神经 VAD 在独立的 sherpa-onnx worker 上运行真实 Silero 模型，按模型听到的内容切分语音，而不是按响度；它不是 ASR 模型。';

  @override
  String get settingsVadModel => 'VAD 模型';

  @override
  String get settingsVadModelNone => '未选择';

  @override
  String get settingsVadThreshold => '语音阈值';

  @override
  String get settingsVadMinSilence => '最短静音';

  @override
  String get settingsVadMinSpeech => '最短语音';

  @override
  String get settingsVadMaxSeconds => '单段上限';

  @override
  String settingsVadSecondsValue(String seconds) {
    return '$seconds 秒';
  }

  @override
  String get vadModelRequired => '请先在“模型”页选择已下载的 VAD 模型，才能使用神经 VAD。';

  @override
  String get modelsVadSection => 'VAD 模型';

  @override
  String get modelsVadNote => 'VAD 模型为神经切割模式检测语音边界，不能用于转录。';

  @override
  String get vadPreview => '语音预览';

  @override
  String get vadPreviewRun => '预览';

  @override
  String get vadPreviewAgain => '重新预览';

  @override
  String get vadPreviewing => '正在分析语音…';

  @override
  String vadPreviewSummary(int windows, String speech) {
    return '$windows 个窗口，共 $speech 秒语音';
  }

  @override
  String vadPreviewWindow(int index) {
    return '窗口 $index';
  }

  @override
  String vadPreviewSegment(String start, String end) {
    return '$start – $end 秒';
  }

  @override
  String get vadPreviewStale => '参数已更改，本次预览已过期，请重新预览。';

  @override
  String get transcribeCancel => '取消';

  @override
  String get transcribeCancelling => '正在取消…';

  @override
  String get comingSoon => '即将推出';
}
