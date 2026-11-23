"""Check the release workflow artifact, dependency, and validation contracts."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
sys.path.insert(0, str(ROOT / "scripts/ci"))
from android_release import (
    MAX_BETA_VERSION_CODE_SLOT,
    STABLE_VERSION_CODE_SLOT,
    VERSION_CODE_SPLIT_OFFSET,
    apk_basename,
    version_code_base,
)
from validate_release_source import required_source_files


def job(workflow: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9-]+:\n|\Z)",
        workflow,
    )
    assert match, f"Missing workflow job: {name}"
    return match.group(1)


build = (WORKFLOWS / "build.yml").read_text(encoding="utf-8")
android = (WORKFLOWS / "build_android.yml").read_text(encoding="utf-8")
beta = (WORKFLOWS / "build_android_beta.yml").read_text(encoding="utf-8")
release_on_push = (WORKFLOWS / "release_on_push.yml").read_text(encoding="utf-8")

for workflow in (build, android, beta):
    assert workflow.count("--target-platform android-arm64 --split-per-abi") == 1
    assert "Iroru-android-universe_" not in workflow
assert "android_all_abis: true" in job(build, "native-audio-android")
assert "android_all_abis: false" in job(android, "native-audio")
assert "android_all_abis: false" in job(beta, "native-audio")

for workflow in (build, android):
    android_job = job(workflow, "android")
    prepare_job = job(workflow, "prepare")
    assert "com.meteor.iroru" in workflow
    assert "com.meteor.kikoeruflutter" not in workflow
    assert (
        'python3 scripts/ci/android_release.py version-code --version "$version"'
        in prepare_job
    )
    assert '--build-number="${{ needs.prepare.outputs.build_number }}"' in android_job
    assert "Read Android base version code" not in android_job
    assert "python3 scripts/ci/android_release.py name" in android_job
    assert "python3 scripts/ci/android_release.py verify" in android_job
    assert "--signing-policy release" in android_job
    assert (
        '--base-version-code "${{ needs.prepare.outputs.build_number }}"'
        in android_job
    )
    assert "APK_NAME: ${{ steps.package.outputs.apk_name }}" in android_job
    assert "EXPECTED_CERT_SHA256" not in workflow
    assert 'apksigner" verify' not in workflow
    assert "_com.meteor.iroru.apk" not in workflow
    assert (
        "APK_NAME: ${{ needs.android.outputs.apk_name }}"
        in job(workflow, "release")
    )

assert VERSION_CODE_SPLIT_OFFSET == 2000
assert STABLE_VERSION_CODE_SLOT == 999
assert MAX_BETA_VERSION_CODE_SLOT == 998
assert apk_basename("381", "com.meteor.iroru") == (
    "Iroru-android-arm64-v8a_381_com.meteor.iroru.apk"
)
assert version_code_base("4.5.3") == (
    ((4 * 100 + 5) * 1000 + 3) * 1000 + STABLE_VERSION_CODE_SLOT
)
assert version_code_base("4.5.3-beta.998") == version_code_base("4.5.3") - 1
assert version_code_base("4.5.4") > version_code_base("4.5.3-beta.998")
beta_job = job(beta, "android")
assert "python3 scripts/ci/android_release.py version-code" in beta_job
assert "python3 scripts/ci/android_release.py name" in beta_job
assert "python3 scripts/ci/android_release.py verify" in beta_job
assert "--signing-policy release" in beta_job
assert '--signing-configured "$SIGNING_CONFIGURED"' in beta_job
assert "--forbid-debuggable" in beta_job
assert '--base-version-code "$EXPECTED_BUILD_NUMBER"' in beta_job
assert "APK_NAME: ${{ steps.package.outputs.apk_name }}" in beta_job
assert "--package-id com.meteor.iroru" in beta_job
assert "com.meteor.iroru.beta" not in beta
assert "com.meteor.kikoeruflutter" not in beta
assert "Configure Separate Beta Application" not in beta
assert 'android:label="Iroru Beta"' not in beta
assert "EXPECTED_CERT_SHA256" not in beta
assert 'apksigner" verify' not in beta
assert "length == 1 and all" in beta
assert (
    "does not import data from the previous standalone Iroru Beta app"
    in beta
)
assert "The previous app and its data remain on the device" in beta
assert (
    "APK_NAME: ${{ needs.android.outputs.apk_name }}"
    in job(beta, "release")
)

installer = (ROOT / "installer_script.iss").read_text(encoding="utf-8")
assert "AppId={{F6844AAE-393D-450F-BC48-3965B0B6628C}" in installer
assert "[InstallDelete]" not in installer
assert 'Name: "{autoprograms}\\Iroru\\{#MyAppName}"' in installer
assert 'Name: "{autodesktop}\\Iroru Desktop"' in installer
assert "Iroru Desktop.app" in build
assert "Iroru Desktop.app" in (
    WORKFLOWS / "build_test_only.yml"
).read_text(encoding="utf-8")
macos_app_info = (ROOT / "macos/Runner/Configs/AppInfo.xcconfig").read_text(encoding="utf-8")
assert "PRODUCT_NAME = Iroru Desktop" in macos_app_info
assert re.search(r"(?m)^PRODUCT_BUNDLE_IDENTIFIER = com\.meteor\.iroru$", macos_app_info)
ios_project = (ROOT / "ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
assert set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", ios_project)) == {
    "com.meteor.iroru",
    "com.meteor.iroru.RunnerTests",
}
assert 'VALUE "ProductName", "Iroru"' in (
    ROOT / "windows/runner/Runner.rc"
).read_text(encoding="utf-8")
assert 'applicationId = "com.meteor.iroru"' in (
    ROOT / "android/app/build.gradle.kts"
).read_text(encoding="utf-8")
assert 'android:label="Iroru"' in (
    ROOT / "android/app/src/main/AndroidManifest.xml"
).read_text(encoding="utf-8")
assert 'set(APPLICATION_ID "com.meteor.iroru")' in (
    ROOT / "linux/CMakeLists.txt"
).read_text(encoding="utf-8")
assert "g_get_user_data_dir(), APPLICATION_ID" in (
    ROOT / "linux/runner/my_application.cc"
).read_text(encoding="utf-8")

android_job = job(build, "android")
windows_job = job(build, "windows")
assert "needs: [prepare, native-audio-android]" in android_job
assert "needs: [prepare, native-audio-windows]" in windows_job
android_native = job(build, "native-audio-android")
assert "needs: prepare" in android_native
assert "android_only: true" in android_native
assert "android_all_abis: true" in android_native
assert "needs: prepare" in job(build, "native-audio-windows")
assert "windows_only: true" in job(build, "native-audio-windows")

android_verify = job(build, "android-verify")
assert "arch: x86_64" in android_verify
assert "timeout-minutes: 15" in android_verify
assert "run_android_emulator_test.sh" in android_verify
assert "--dart-define=KIKOFLU_PERFORMANCE=true integration_test/android_audio_verification.dart" in android_verify
assert "android-emulator-diagnostics" in android_verify
assert "always() && steps.android-emulator-tests.outcome == 'failure'" in android_verify
assert "${{ runner.temp }}/android-emulator-diagnostics/" in android_verify
emulator_script = re.search(r"(?ms)^          script: >-\n(.*?)(?=^      - name:)", android_verify)
assert emulator_script and len([line for line in emulator_script.group(1).splitlines() if line.strip()]) == 1

release = job(build, "release")
for required_job in ("android", "android-verify", "windows", "ios-verify", "ios-build", "macos", "linux"):
    assert f"      - {required_job}" in release
assert "linux-arm64" not in build
assert "Iroru-linux-arm64_" not in release
assert "Iroru-linux-x64_" in release

ios_verify = job(build, "ios-verify")
assert "Restarting the simulator and retrying" in ios_verify
assert "verified HTTPS video output remains independent from the audio graph (failed)" in ios_verify
assert "TimeoutException after 0:00:30.000000" in ios_verify
assert "native HTTPS rejects an untrusted certificate (failed)" not in ios_verify

for workflow in (build, android, beta):
    flutter_setups = workflow.count("uses: subosito/flutter-action@v2")
    assert workflow.count("          cache: true") == flutter_setups
    assert workflow.count("          pub-cache: true") == flutter_setups
    assert "Cache Android Gradle dependencies" in workflow
    assert "~/.gradle/caches/modules-2" in workflow
    assert "release-key.jks" not in workflow.split("Cache Android Gradle dependencies", 1)[1].split("- name:", 1)[0]

linux_cache = (ROOT / ".github/actions/linux-native-audio-cache/action.yml").read_text(encoding="utf-8")
test_only = (WORKFLOWS / "build_test_only.yml").read_text(encoding="utf-8")
test_only_ios = job(test_only, "ios-verify")
test_only_android = job(test_only, "android-build")
assert "TimeoutException after 0:00:30.000000" in test_only_ios
assert "native HTTPS rejects an untrusted certificate (failed)" not in test_only_ios
assert "python3 scripts/ci/android_release.py verify" in test_only_android
assert "--signing-policy optional" in test_only_android
assert '--signing-configured "$SIGNING_CONFIGURED"' in test_only_android
assert 'apksigner" verify' not in test_only_android
assert "EXPECTED_CERT_SHA256" not in test_only
assert "python3 scripts/ci/test_android_release.py" in job(
    test_only,
    "quality-analysis",
)
assert "uses: ./.github/actions/linux-native-audio-cache" in build
assert "uses: ./.github/actions/linux-native-audio-cache" in test_only
assert "ImageOS" in linux_cache and "ImageVersion" in linux_cache
assert "dpkg-query -W" in linux_cache and "python3 -m pip freeze" in linux_cache
assert 'workspace=%s\\n' in linux_cache and '"$GITHUB_WORKSPACE"' in linux_cache
assert "hashFiles('.github/actions/linux-native-audio-cache/action.yml'" in linux_cache
assert "scripts/native_audio/linux.lock" in linux_cache
assert "scripts/native_audio/ffmpeg-sendcmd-precision.patch" in linux_cache
assert "scripts/native_audio/mpv-audio-controls.patch" in linux_cache
assert "ldd \"$prefix/lib/libmpv.so\"" in linux_cache
assert "readelf -d" in linux_cache
assert "readelf -h" in linux_cache and "x86_64 shared library" in linux_cache
assert "actions/cache/restore@v4" in linux_cache
assert "actions/cache/save@v4" in linux_cache
assert "continue-on-error: true" in linux_cache
assert "production-pcm.json" not in linux_cache
cache_keys = re.findall(r"^        key: (.+)$", linux_cache, re.MULTILINE)
assert len(cache_keys) == 2 and cache_keys[0] == cache_keys[1]

plan = job(release_on_push, "plan")
assert "scripts/ci/build_test_scope.py" not in release_on_push
assert re.findall(r"^    if: (.+)$", plan, re.MULTILINE) == ["github.event.deleted != true"]
assert "scripts/plan_push_release.py" in plan
for release_job in ("stable", "beta"):
    assert "needs: plan" in job(release_on_push, release_job)
    assert "needs.plan.outputs.publish == 'true'" in job(release_on_push, release_job)
assert "workflow_dispatch:" not in release_on_push
assert "python3 scripts/test_plan_push_release.py" in job(test_only, "quality-analysis")

build_scope = job(test_only, "build-scope")
assert "fetch-depth: 0" in build_scope
assert 'args+=("refs/remotes/origin/$DEFAULT_BRANCH")' in build_scope
assert 'scripts/ci/build_test_scope.py "${args[@]}"' in build_scope
for gated_job in ("native-audio", "native-audio-android", "native-audio-darwin", "linux"):
    assert "needs.build-scope.outputs.build_required != 'false'" in job(test_only, gated_job)


for workflow, profile in (
    (build, "full"),
    (android, "android"),
    ((WORKFLOWS / "native_audio.yml").read_text(encoding="utf-8"), "android"),
):
    assert "path: .release-gate" in workflow
    assert "if: ${{ inputs.commit_sha && inputs.commit_sha != github.sha }}" in workflow
    assert "ref: ${{ github.sha }}" in workflow
    assert f'python3 "$gate" {profile} --root .' in workflow
    assert "if [[ ! -f scripts/ci/android_release.py ]]" in workflow
    assert "Choose a commit that includes the new release configuration." in workflow

assert "needs: prepare" in job(build, "native-audio-android")
assert "needs: prepare" in job(build, "native-audio-windows")
assert "needs: native-audio" in job(beta, "android")
assert "scripts/ci/android_release.py" in required_source_files("android")
assert "def version_code_base(" in required_source_files("android")[
    "scripts/ci/android_release.py"
]
assert "--latest-stable" in required_source_files("android")[
    "scripts/ci/android_release.py"
]
assert 'python3 "$gate" android --root .' in job(beta, "android")


def make_source_fixture(destination: Path, profile: str) -> None:
    for relative_path in required_source_files(profile):
        source = ROOT / relative_path
        target = destination / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


def run_source_preflight(root: Path, profile: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/ci/validate_release_source.py"),
            profile,
            "--root",
            str(root),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary) / "current-source"
    fixture.mkdir()
    make_source_fixture(fixture, "full")
    for profile in ("android", "full"):
        result = run_source_preflight(fixture, profile)
        assert result.returncode == 0, result.stdout + result.stderr

    legacy = Path(temporary) / "legacy-source"
    legacy.mkdir()
    make_source_fixture(legacy, "full")
    (legacy / "scripts/native_audio/build_android.sh").write_text(
        "# Legacy builder without per-ABI validation or provenance output.\n",
        encoding="utf-8",
    )
    (legacy / "third_party/media_kit_libs_android_video/android/build.gradle").write_text(
        "// Legacy Gradle integration without target-platform selection.\n",
        encoding="utf-8",
    )
    (legacy / ".github/actions/linux-native-audio-cache/action.yml").unlink()
    (legacy / "scripts/ci/run_android_emulator_test.sh").unlink()
    (legacy / "scripts/ci/android_release.py").unlink()
    (legacy / "scripts/native_audio/build_darwin.sh").write_text(
        'python3 "$script_dir/rewrite_darwin_sdk_paths.py"\n'
        'python3 "$script_dir/test_darwin_native.py"\n',
        encoding="utf-8",
    )
    result = run_source_preflight(legacy, "full")
    assert result.returncode != 0
    assert "Selected commit lacks required release configuration" in result.stdout
    assert "--validate-output" in result.stdout
    assert "target-platform" in result.stdout
    assert "scripts/ci/android_release.py is missing" in result.stdout
    assert "linux-native-audio-cache/action.yml is missing" in result.stdout
    assert "native source checks before rewriting SDK paths" in result.stdout

print("Release workflow contract checks passed.")
