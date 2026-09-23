from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
import zipfile

from verify_apk_contents import (
    FLUTTER_ASSET_ROOT,
    REQUIRED_LICENSE_ASSETS,
    inspect_apk,
)


class VerifyApkContentsTest(unittest.TestCase):
    def make_apk(self, directory: str, extra_entries: tuple[str, ...] = ()) -> Path:
        apk = Path(directory) / "candidate.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for asset in REQUIRED_LICENSE_ASSETS:
                archive.writestr(f"{FLUTTER_ASSET_ROOT}{asset}", b"license")
            for entry in extra_entries:
                archive.writestr(entry, b"model")
        return apk

    def test_accepts_notices_without_model_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            problems = inspect_apk(self.make_apk(directory))
        self.assertEqual(problems, [])

    def test_rejects_model_weights_and_companion_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            apk = self.make_apk(
                directory,
                (
                    "assets/flutter_assets/model.mnn",
                    "assets/flutter_assets/tokens.txt",
                    "assets/flutter_assets/qwen.gguf",
                ),
            )
            problems = inspect_apk(apk)
        self.assertEqual(len(problems), 3)
        self.assertTrue(all("must not be bundled" in item for item in problems))

    def test_requires_mnn_license_to_be_reachable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "candidate.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                for asset in REQUIRED_LICENSE_ASSETS[:-1]:
                    archive.writestr(f"{FLUTTER_ASSET_ROOT}{asset}", b"license")
            problems = inspect_apk(apk)
        self.assertEqual(len(problems), 1)
        self.assertIn("native/sherpa_mnn/UPSTREAM_LICENSE.txt", problems[0])


if __name__ == "__main__":
    unittest.main()
