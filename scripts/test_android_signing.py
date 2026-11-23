from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
from android_release import RELEASE_CERT_SHA256, apk_basename


WORKFLOWS = {
    ".github/workflows/build.yml": "release",
    ".github/workflows/build_android.yml": "release",
    ".github/workflows/build_android_beta.yml": "release",
    ".github/workflows/build_test_only.yml": "optional",
}
EXPECTED_CERT = (
    "8d432df267b5eb175c2f806381c44d7b4bf657145af792ace223af34e340f740"
)


assert RELEASE_CERT_SHA256 == EXPECTED_CERT
assert re.fullmatch(r"[0-9a-f]{64}", RELEASE_CERT_SHA256)
assert apk_basename("381", "com.meteor.iroru") == (
    "Iroru-android-arm64-v8a_381_com.meteor.iroru.apk"
)
assert apk_basename("4.5.3-beta.1", "com.meteor.iroru") == (
    "Iroru-android-arm64-v8a_4.5.3-beta.1_com.meteor.iroru.apk"
)

for workflow, signing_policy in WORKFLOWS.items():
    source = (ROOT / workflow).read_text(encoding="utf-8")
    assert "python3 scripts/ci/android_release.py verify" in source, workflow
    assert f"--signing-policy {signing_policy}" in source, workflow
    assert "EXPECTED_CERT_SHA256:" not in source, workflow
