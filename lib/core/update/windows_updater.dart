import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'release_check.dart';

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class WindowsUpdater {
  WindowsUpdater({required this.info, required this.installDirectory});

  final ReleaseInfo info;
  final Directory installDirectory;

  static const String _sep = r'\';

  String get _exeName => Platform.resolvedExecutable.split(_sep).last;

  Directory get _workDirectory => Directory(
    '${Directory.systemTemp.path}${_sep}pocket_asr_update_${info.version}',
  );

  File get _zipFile => File('${_workDirectory.path}${_sep}release.zip');

  Directory get _staging =>
      Directory('${_workDirectory.path}${_sep}staging');

  Future<void> download({
    required void Function(int received, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final expected = info.sha256;
    if (expected == null) {
      throw const UpdateException(
        'This release has no checksum, so it will not be installed automatically.',
      );
    }
    await _workDirectory.create(recursive: true);
    if (await _zipFile.exists()) await _zipFile.delete();
    final client = HttpClient()..autoUncompress = false;
    try {
      final request = await client.getUrl(Uri.parse(info.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'PocketASR');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException('Download failed with HTTP ${response.statusCode}.');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : (info.size ?? 0);
      final capture = _DigestCapture();
      final hash = sha256.startChunkedConversion(capture);
      final sink = _zipFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          if (isCancelled()) throw const UpdateCancelled();
          sink.add(chunk);
          hash.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      hash.close();
      if (info.size != null && received != info.size) {
        throw UpdateException(
          'Downloaded $received bytes but the release lists ${info.size}.',
        );
      }
      if (capture.value.toString() != expected) {
        throw const UpdateException(
          'Checksum mismatch; the downloaded file was discarded.',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> extract({required bool Function() isCancelled}) async {
    if (isCancelled()) throw const UpdateCancelled();
    if (await _staging.exists()) await _staging.delete(recursive: true);
    await _staging.create(recursive: true);
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Expand-Archive -LiteralPath ${_quote(_zipFile.path)} '
          '-DestinationPath ${_quote(_staging.path)} -Force',
    ]);
    if (result.exitCode != 0) {
      throw UpdateException('Could not unpack the update: ${result.stderr}');
    }
    if (!await File('${_staging.path}${_sep}pocket_asr.exe').exists()) {      throw const UpdateException(
        'The update package does not contain the application.',
      );
    }
  }

  Future<void> preflight() async {
    final probe = File('${installDirectory.path}$_sep.update-write-test');
    try {
      await probe.writeAsString('x');
      await probe.delete();
    } on Object {
      throw UpdateException(
        'Cannot write to ${installDirectory.path}. Move the app to a folder '
        'you own, or update manually.',
      );
    }
  }

  Future<void> applyAndExit() async {
    final script = File('${_workDirectory.path}${_sep}apply_update.ps1');
    await script.writeAsString(_helperScript, encoding: utf8);
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ProcessId',
        '$pid',
        '-Staging',
        _staging.path,
        '-Install',
        installDirectory.path,
        '-Exe',
        _exeName,
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: _workDirectory.path,
    );
    exit(0);
  }

  static String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  static const String _helperScript = r'''
param(
  [Parameter(Mandatory=$true)][int]$ProcessId,
  [Parameter(Mandatory=$true)][string]$Staging,
  [Parameter(Mandatory=$true)][string]$Install,
  [Parameter(Mandatory=$true)][string]$Exe
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'pocket_asr_update.log'
function Write-Log([string]$Text) {
  Add-Content -LiteralPath $log -Value ((Get-Date -Format 's') + ' ' + $Text)
}
function Copy-Tree([string]$From, [string]$To) {
  & robocopy $From $To /E /NFL /NDL /NJH /NJS /R:5 /W:1 | Out-Null
  return $LASTEXITCODE
}
Write-Log 'start'
try {
  try { Wait-Process -Id $ProcessId -Timeout 180 -ErrorAction Stop } catch { }
  Start-Sleep -Milliseconds 500
  $backup = Join-Path (Split-Path -Parent $Install) ((Split-Path -Leaf $Install) + '.update-backup')
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  $backupCode = Copy-Tree $Install $backup
  Write-Log ('backup ' + $backupCode)
  if ($backupCode -ge 8) {
    Start-Process -FilePath (Join-Path $Install $Exe) -WorkingDirectory $Install
    exit
  }
  $copyCode = Copy-Tree $Staging $Install
  Write-Log ('copy ' + $copyCode)
  if ($copyCode -ge 8) {
    Write-Log 'restore'
    Copy-Tree $backup $Install | Out-Null
    Start-Process -FilePath (Join-Path $Install $Exe) -WorkingDirectory $Install
  } else {
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath (Join-Path $Install $Exe) -WorkingDirectory $Install
    Write-Log 'restarted'
  }
  Remove-Item -LiteralPath (Split-Path -Parent $Staging) -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  Write-Log ('failed ' + $_.Exception.Message)
  try { Start-Process -FilePath (Join-Path $Install $Exe) -WorkingDirectory $Install } catch { }
}
''';
}
