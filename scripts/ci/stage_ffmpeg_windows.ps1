param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$tag = 'autobuild-2026-09-15-13-18'
$name = 'ffmpeg-n9.0.1-30-g9258bacca5-win64-lgpl-shared-9.0'
$url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$tag/$name.zip"
$sha = '04d256aa477122949304a717bf61d8eec78e255c2c7c9be17fab1677227cb548'
if (!(Test-Path -LiteralPath $Destination -PathType Container)) { throw "Missing build directory: $Destination" }
$cache = Join-Path ([IO.Path]::GetTempPath()) "pocketasr-ffmpeg-$sha"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$zip = Join-Path $cache 'ffmpeg.zip'
if (!(Test-Path $zip)) { Invoke-WebRequest $url -OutFile $zip }
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'FFmpeg SHA-256 mismatch' }
$unpacked = Join-Path $cache $name
if (!(Test-Path $unpacked)) { Expand-Archive $zip -DestinationPath $cache -Force }
$target = Join-Path $Destination 'ffmpeg'
$binDir = Join-Path $target 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
# ffmpeg.exe hard-links every shared library in its import table, including
# avdevice/avfilter/swscale, so all of them must ship even though decoding
# never touches avdevice. ffplay, ffprobe, docs, headers and import libs do
# nothing at runtime; dropping them keeps the release zip ~12MB smaller.
$runtime = 'ffmpeg.exe', 'avcodec-63.dll', 'avformat-63.dll', 'avutil-61.dll',
  'swresample-7.dll', 'avfilter-12.dll', 'swscale-10.dll', 'avdevice-63.dll'
foreach ($file in $runtime) {
  Copy-Item -LiteralPath (Join-Path $unpacked "bin/$file") -Destination $binDir
}
& (Join-Path $binDir 'ffmpeg.exe') -version
if ($LASTEXITCODE -ne 0) { throw 'Bundled FFmpeg failed to start' }
Copy-Item -LiteralPath "$PSScriptRoot/../../native/FFMPEG-NOTICE.txt" -Destination $target
