[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$BundleDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BundlePath = [IO.Path]::GetFullPath($BundleDirectory)
$LibraryPath = Join-Path $BundlePath 'crispembed.dll'
if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) {
  throw "Missing Windows native library: $LibraryPath"
}

# These are the symbols the crispembed 0.16.1 Dart constructor binds eagerly,
# plus the optional metadata-prefix functions used by PocketASR.
$RequiredExports = @(
  'crispembed_resolve_model',
  'crispembed_init',
  'crispembed_encode',
  'crispembed_encode_batch',
  'crispembed_free',
  'crispembed_set_dim',
  'crispembed_set_prefix',
  'crispembed_get_prefix',
  'crispembed_has_sparse',
  'crispembed_has_colbert',
  'crispembed_is_reranker',
  'crispembed_encode_sparse',
  'crispembed_encode_multivec',
  'crispembed_rerank',
  'crispembed_ctx_query_prefix',
  'crispembed_ctx_passage_prefix'
)

$Handle = [IntPtr]::Zero
try {
  # Loading the DLL also proves that every non-delay-loaded dependency can be
  # resolved from the release bundle or the Windows system directories.
  $Handle = [Runtime.InteropServices.NativeLibrary]::Load($LibraryPath)
  foreach ($Symbol in $RequiredExports) {
    $Address = [IntPtr]::Zero
    if (-not [Runtime.InteropServices.NativeLibrary]::TryGetExport(
        $Handle,
        $Symbol,
        [ref]$Address
      )) {
      throw "crispembed.dll does not export $Symbol"
    }
  }
} finally {
  if ($Handle -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.NativeLibrary]::Free($Handle)
  }
}

$Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $LibraryPath).Hash.ToLowerInvariant()
Write-Host "Verified crispembed.dll dependency loading and $($RequiredExports.Count) exports"
Write-Host "SHA-256: $Hash"
