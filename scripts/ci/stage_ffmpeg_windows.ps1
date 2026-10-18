param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$name = 'ffmpeg-master-latest-win64-lgpl-shared'
$url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl-shared.zip'
if (!(Test-Path -LiteralPath $Destination -PathType Container)) { throw "Missing build directory: $Destination" }
$headers = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
$release = Invoke-RestMethod 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest' -Headers $headers
$assets = @($release.assets | Where-Object { $_.name -eq "$name.zip" })
if ($assets.Count -ne 1) { throw 'Expected exactly one master latest LGPL shared asset' }
$digest = [string]$assets[0].digest
if ($digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'FFmpeg asset has no valid SHA-256 digest' }
$sha = $Matches[1].ToLowerInvariant()
$cache = Join-Path ([IO.Path]::GetTempPath()) "pocketasr-ffmpeg-$sha"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$zip = Join-Path $cache 'ffmpeg.zip'
if (!(Test-Path $zip)) {
  $download = Join-Path $cache 'ffmpeg.zip.part'
  Invoke-WebRequest $url -OutFile $download -MaximumRetryCount 3
  if ((Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'FFmpeg SHA-256 mismatch' }
  Move-Item -LiteralPath $download -Destination $zip
}
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'FFmpeg SHA-256 mismatch' }
$unpacked = Join-Path $cache $name
Expand-Archive $zip -DestinationPath $cache -Force
$target = Join-Path $Destination 'ffmpeg'
$binDir = Join-Path $target 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
# DLL major versions can change on master; ship every DLL from this same archive.
Copy-Item -LiteralPath (Join-Path $unpacked 'bin/ffmpeg.exe') -Destination $binDir
$libraries = @(Get-ChildItem -LiteralPath (Join-Path $unpacked 'bin') -Filter '*.dll' -File)
if ($libraries.Count -eq 0) { throw 'FFmpeg shared archive contains no DLLs' }
foreach ($library in $libraries) {
  Copy-Item -LiteralPath $library.FullName -Destination $binDir
}
$version = & (Join-Path $binDir 'ffmpeg.exe') -version
if ($LASTEXITCODE -ne 0) { throw 'Bundled FFmpeg failed to start' }
$version | Write-Output
# Keep upstream license, documentation and build information.
Get-ChildItem -LiteralPath $unpacked | Where-Object { $_.Name -notin @('bin', 'lib', 'include') } |
  ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force }
Copy-Item -LiteralPath "$PSScriptRoot/../../native/FFMPEG-NOTICE.txt" -Destination $target
@(
  "Binary: $name.zip"
  "Download: $url"
  "Release: $($release.html_url)"
  "Asset ID: $($assets[0].id)"
  "Asset updated: $($assets[0].updated_at)"
  "SHA-256: $sha"
  ''
  $version
) | Set-Content -LiteralPath (Join-Path $target 'BUILD-INFO.txt') -Encoding utf8
