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
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path "$unpacked/*" -Destination $target -Recurse -Force
& (Join-Path $target 'bin/ffmpeg.exe') -version
if ($LASTEXITCODE -ne 0) { throw 'Bundled FFmpeg failed to start' }
Copy-Item -LiteralPath "$PSScriptRoot/../../native/FFMPEG-NOTICE.txt" -Destination $target
