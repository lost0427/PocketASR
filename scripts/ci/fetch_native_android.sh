#!/usr/bin/env bash
#
# Fetch the pinned native Android libraries into the Flutter app's jniLibs.
#
# Chooses `.sh` (not `.ps1`) because the Android GitHub Actions runner in
# .github/workflows/release.yml is `ubuntu-latest`.
#
# CrispEmbed is intentionally NOT downloaded by default. Its Flutter plugin
# (crispembed 0.16.1) already runs a `fetchCrispembedLibs` Gradle task on
# preBuild that downloads and unpacks its own prebuilt libcrispembed.so; doing
# it here too would duplicate a 13 MB download. Pass `--with-crispembed` to
# force the pinned v0.16.1 asset (e.g. to pre-seed an offline CI cache).
#
# Binaries are never committed: they land under android/app/src/main/jniLibs/
# and are excluded by .gitignore.
set -euo pipefail

CRISPASR_VERSION="v0.8.32"
CRISPASR_ASSET="crispasr-android-arm64-v8a.tar.gz"
CRISPASR_SHA256="c1a3478ed7c0ad47077ecb8f8c600068b78674aa56c98a6c366108a3a09dd8fc"

CRISPEMBED_VERSION="v0.16.1"
CRISPEMBED_ASSET="crispembed-android-arm64-v8a.tar.gz"
CRISPEMBED_SHA256="bc6f61d501a95aeefb2dff54b82ca34e5e84ad21ed748604004e984f6a3b1334"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JNI_DIR="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Download one release asset, verify its SHA-256, extract it, and copy every
# lib*.so it contains into dest (archives may nest the .so under a directory).
fetch_and_extract() {
  local asset="$1" url="$2" sha="$3" dest="$4"
  echo "fetch_native_android: downloading $asset"
  curl -fL --retry 3 --retry-delay 2 -o "$TMP/$asset" "$url"
  echo "$sha  $TMP/$asset" | sha256sum -c -
  tar -xzf "$TMP/$asset" -C "$TMP"
  mkdir -p "$dest"
  find "$TMP" -type f -name 'lib*.so' -exec cp -f {} "$dest/" \;
}

mkdir -p "$JNI_DIR"

fetch_and_extract \
  "$CRISPASR_ASSET" \
  "https://github.com/CrispStrobe/CrispASR/releases/download/$CRISPASR_VERSION/$CRISPASR_ASSET" \
  "$CRISPASR_SHA256" \
  "$JNI_DIR"

if [ "${1:-}" = "--with-crispembed" ]; then
  fetch_and_extract \
    "$CRISPEMBED_ASSET" \
    "https://github.com/CrispStrobe/CrispEmbed/releases/download/$CRISPEMBED_VERSION/$CRISPEMBED_ASSET" \
    "$CRISPEMBED_SHA256" \
    "$JNI_DIR"
else
  echo "fetch_native_android: CrispEmbed left to the crispembed plugin's fetchCrispembedLibs task."
fi

echo "fetch_native_android: staged native libs in $JNI_DIR"
ls -l "$JNI_DIR"
