[CmdletBinding()]
param(
  [string]$Destination,
  [string]$WorkDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CrispEmbedUrl = 'https://github.com/CrispStrobe/CrispEmbed.git'
$CrispEmbedCommit = 'e6411e48bfd2572cc29a7c04eccee8a8153bef2e'
$CrispEmbedGgml = '0714117daca2471b00e09554c7eaa74a06b0b2c5'

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Resolve-RepoPath([string]$Path, [string]$DefaultRelativePath) {
  $candidate = if ([string]::IsNullOrWhiteSpace($Path)) {
    Join-Path $RepoRoot $DefaultRelativePath
  } elseif ([IO.Path]::IsPathRooted($Path)) {
    $Path
  } else {
    Join-Path $RepoRoot $Path
  }
  return [IO.Path]::GetFullPath($candidate)
}

function Assert-WorkspacePath([string]$Path) {
  $prefix = $RepoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a work directory outside the repository: $Path"
  }
}

function Invoke-Tool([string]$FilePath, [string[]]$ArgumentList) {
  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

$OutputDir = Resolve-RepoPath $Destination 'native\windows'
$WorkRoot = Resolve-RepoPath $WorkDirectory '.native-work-windows'
Assert-WorkspacePath $WorkRoot

$SourceDir = Join-Path $WorkRoot 'crispembed'
$BuildDir = Join-Path $WorkRoot 'build'

if (Test-Path -LiteralPath $WorkRoot) {
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkRoot, $OutputDir -Force | Out-Null

Write-Host "Fetching CrispEmbed $CrispEmbedCommit"
Invoke-Tool git @('init', '--quiet', $SourceDir)
Invoke-Tool git @('-C', $SourceDir, 'remote', 'add', 'origin', $CrispEmbedUrl)
Invoke-Tool git @(
  '-C', $SourceDir, 'fetch', '--quiet', '--depth', '1', 'origin',
  $CrispEmbedCommit
)
Invoke-Tool git @('-C', $SourceDir, 'checkout', '--quiet', 'FETCH_HEAD')
Invoke-Tool git @(
  '-C', $SourceDir, 'submodule', 'update', '--init', '--recursive', '--depth', '1'
)

$ResolvedCommit = (& git -C $SourceDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $ResolvedCommit -ne $CrispEmbedCommit) {
  throw "CrispEmbed commit mismatch: expected $CrispEmbedCommit, got $ResolvedCommit"
}
$ResolvedGgml = (& git -C $SourceDir rev-parse ':ggml').Trim()
if ($LASTEXITCODE -ne 0 -or $ResolvedGgml -ne $CrispEmbedGgml) {
  throw "CrispEmbed ggml mismatch: expected $CrispEmbedGgml, got $ResolvedGgml"
}

Write-Host 'Configuring the Windows x64 CPU build'
Invoke-Tool cmake @(
  '-S', $SourceDir,
  '-B', $BuildDir,
  '-G', 'Visual Studio 17 2022',
  '-A', 'x64',
  '-DCMAKE_C_FLAGS=/utf-8',
  '-DCMAKE_CXX_FLAGS=/utf-8 /EHsc',
  '-DBUILD_SHARED_LIBS=OFF',
  '-DCRISPEMBED_BUILD_SHARED=ON',
  '-DCRISPEMBED_NATIVE=OFF',
  '-DGGML_NATIVE=OFF',
  '-DGGML_AVX512=OFF',
  '-DGGML_BLAS=OFF',
  '-DGGML_CUDA=OFF',
  '-DGGML_VULKAN=OFF',
  '-DGGML_LLAMAFILE=OFF',
  '-DGGML_OPENMP=OFF'
)
Invoke-Tool cmake @(
  '--build', $BuildDir,
  '--config', 'Release',
  '--target', 'crispembed-shared',
  '--parallel'
)

$BuiltDlls = @(
  Get-ChildItem -LiteralPath $BuildDir -Filter 'crispembed.dll' -File -Recurse
)
if ($BuiltDlls.Count -ne 1) {
  throw "Expected one crispembed.dll, found $($BuiltDlls.Count) under $BuildDir"
}

$OutputDll = Join-Path $OutputDir 'crispembed.dll'
Copy-Item -LiteralPath $BuiltDlls[0].FullName -Destination $OutputDll -Force
$Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputDll).Hash.ToLowerInvariant()
Write-Host "Staged $OutputDll"
Write-Host "SHA-256: $Hash"
