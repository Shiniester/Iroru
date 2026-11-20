"""Check the Beta workflow's shared versionCode sequence and Android SHA wiring."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
from android_release import VerificationError, version_code_base


beta = (ROOT / ".github/workflows/build_android_beta.yml").read_text(encoding="utf-8")


versions = ["4.8.2-beta.998", "4.9.1-beta.1", "4.9.1-beta.2", "4.9.2-beta.1",
            "4.10.0-beta.1", "5.0.0-beta.1"]
numbers = [version_code_base(version) for version in versions]
assert numbers == sorted(set(numbers))
assert numbers[1] == 409001001
assert numbers[1] > 2000  # Upgrade from the former workflow run-number scheme.
for version in ["4.100.0-beta.1", "4.9.1000-beta.1", "4.9.1-beta.999", "21.0.0-beta.1"]:
    try:
        version_code_base(version)
    except VerificationError:
        pass
    else:
        raise AssertionError(f"Invalid Android version accepted: {version}")
assert beta.count('python3 scripts/ci/android_release.py version-code') == 1
assert '--latest-stable "$latest_stable"' in beta
assert 'repos/${GH_REPO}/releases/latest' in beta
assert beta.count('--build-number="$BUILD_NUMBER"') == 1
assert "--target-platform android-arm64 --split-per-abi" in beta
assert "$GITHUB_RUN_NUMBER" not in beta

android = (ROOT / ".github/workflows/build_android.yml").read_text(encoding="utf-8")
assert "      commit_sha:\n        description:" in android
assert "ref: ${{ inputs.commit_sha || github.sha }}" in android
assert "ref: ${{ needs.prepare.outputs.commit_sha }}" in android
assert '-f "target_commitish=${RELEASE_COMMIT}"' in android
print("Release metadata checks passed.")
