#!/usr/bin/env python3
"""Ensure Android APKs include Sherpa notices but no downloaded model payload."""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import sys
import zipfile


FLUTTER_ASSET_ROOT = "assets/flutter_assets/"
REQUIRED_LICENSE_ASSETS = (
    "assets/sherpa_mnn_licenses/NOTICE.txt",
    "assets/sherpa_mnn_licenses/apache-2.0-sherpa-kaldi.txt",
    "assets/sherpa_mnn_licenses/sherpa_mnn_NOTICE.txt",
    "assets/sherpa_mnn_licenses/kaldifst_LICENSE.txt",
    "assets/sherpa_mnn_licenses/openfst_COPYING.txt",
    "assets/sherpa_mnn_licenses/simple-sentencepiece_LICENSE.txt",
    "assets/sherpa_mnn_licenses/eigen_COPYING_README.txt",
    "assets/sherpa_mnn_licenses/eigen_COPYING_MPL2.txt",
    "assets/sherpa_mnn_licenses/eigen_COPYING_BSD.txt",
    "assets/sherpa_mnn_licenses/eigen_COPYING_LGPL.txt",
    "assets/sherpa_mnn_licenses/eigen_COPYING_MINPACK.txt",
    "native/sherpa_mnn/UPSTREAM_LICENSE.txt",
)
MODEL_WEIGHT_SUFFIXES = (".mnn", ".onnx", ".gguf")
MODEL_COMPANION_SUFFIXES = ("tokens.txt", "funasr-model-license.txt")


def inspect_apk(apk_path: Path) -> list[str]:
    try:
        with zipfile.ZipFile(apk_path) as archive:
            names = {
                name.replace("\\", "/").lstrip("/") for name in archive.namelist()
            }
    except (OSError, zipfile.BadZipFile) as error:
        return [f"cannot read APK {apk_path}: {error}"]

    problems = []
    for asset in REQUIRED_LICENSE_ASSETS:
        apk_asset = f"{FLUTTER_ASSET_ROOT}{asset}"
        if apk_asset not in names:
            problems.append(f"missing required Flutter license asset: {apk_asset}")

    for name in sorted(names):
        lower_name = name.lower()
        basename = PurePosixPath(lower_name).name
        if lower_name.endswith(MODEL_WEIGHT_SUFFIXES) or basename.endswith(
            MODEL_COMPANION_SUFFIXES
        ):
            problems.append(f"model payload must not be bundled in the APK: {name}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, help="APK file to inspect")
    args = parser.parse_args(argv)

    problems = inspect_apk(args.apk)
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}")
        print("verify_apk_contents: FAIL")
        return 1

    print(
        "verify_apk_contents: PASS "
        f"({len(REQUIRED_LICENSE_ASSETS)} Sherpa license assets, no model payload)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
