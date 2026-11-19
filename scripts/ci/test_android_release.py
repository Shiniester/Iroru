from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


sys.path.insert(0, str(Path(__file__).resolve().parent))

import android_release


class FakeAndroidTools:
    def __init__(
        self,
        badging: str,
        *,
        certificate: str = android_release.RELEASE_CERT_SHA256,
    ):
        self.badging = badging
        self.certificate = certificate
        self.calls: list[list[str]] = []

    def __call__(self, command, **_kwargs):
        normalized = [str(part) for part in command]
        self.calls.append(normalized)
        if normalized[1:3] == ["dump", "badging"]:
            return subprocess.CompletedProcess(normalized, 0, self.badging, "")
        if "verify" in normalized:
            if "--print-certs" in normalized:
                output = (
                    "Signer #1 certificate SHA-256 digest: "
                    f"{self.certificate}\n"
                )
            else:
                output = "Verified using v2 scheme\n"
            return subprocess.CompletedProcess(normalized, 0, output, "")
        raise AssertionError(f"Unexpected command: {normalized}")


class AndroidReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def make_apk(
        self,
        abis=("arm64-v8a",),
        libraries=(
            "libmpv.so",
            "libmediakitandroidhelper.so",
            "libc++_shared.so",
        ),
    ):
        apk = self.root / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for abi in abis:
                for library in libraries:
                    archive.writestr(f"lib/{abi}/{library}", b"native")
        return apk

    @staticmethod
    def badging(
        *,
        package="com.meteor.iroru",
        version="4.5.3",
        version_code=22000,
        abis=("arm64-v8a",),
        debuggable=False,
    ):
        native_code = " ".join(f"'{abi}'" for abi in abis)
        lines = [
            (
                f"package: name='{package}' versionCode='{version_code}' "
                f"versionName='{version}' compileSdkVersion='36'"
            ),
            "sdkVersion:'24'",
            f"native-code: {native_code}",
        ]
        if debuggable:
            lines.append("application-debuggable")
        return "\n".join(lines) + "\n"

    @staticmethod
    def verify(apk, runner, **overrides):
        options = {
            "package_id": "com.meteor.iroru",
            "aapt": Path("aapt"),
            "apksigner": Path("apksigner"),
            "expected_version": "4.5.3",
            "base_version_code": 20000,
            "signing_policy": "release",
            "signing_configured": True,
            "required_libraries": (
                "libmpv.so",
                "libmediakitandroidhelper.so",
                "libc++_shared.so",
            ),
        }
        options.update(overrides)
        return android_release.verify_apk(apk, runner=runner, **options)

    def test_apk_basename_preserves_existing_channel_names(self):
        self.assertEqual(
            "Iroru-android-arm64-v8a_381_com.meteor.iroru.apk",
            android_release.apk_basename("381", "com.meteor.iroru"),
        )
        self.assertEqual(
            "Iroru-android-arm64-v8a_4.5.3-beta.1_com.meteor.iroru.beta.apk",
            android_release.apk_basename(
                "4.5.3-beta.1",
                "com.meteor.iroru.beta",
            ),
        )
        with self.assertRaises(android_release.VerificationError):
            android_release.apk_basename("../381", "com.meteor.iroru")

    def test_release_policy_checks_metadata_and_certificate(self):
        apk = self.make_apk()
        runner = FakeAndroidTools(self.badging())

        result = self.verify(apk, runner)

        self.assertEqual("com.meteor.iroru", result.metadata.package_name)
        self.assertEqual("4.5.3", result.metadata.version_name)
        self.assertEqual(22000, result.metadata.version_code)
        self.assertEqual(("arm64-v8a",), result.metadata.abis)
        self.assertEqual(android_release.RELEASE_CERT_SHA256, result.certificate_sha256)
        self.assertFalse(result.debug_fallback)
        self.assertIn("--print-certs", runner.calls[-1])

    def test_beta_policy_verifies_signature_without_pinning_certificate(self):
        apk = self.make_apk()
        runner = FakeAndroidTools(self.badging(), certificate="00" * 32)

        result = self.verify(
            apk,
            runner,
            signing_policy="signed",
            signing_configured=False,
        )

        self.assertIsNone(result.certificate_sha256)
        self.assertNotIn("--print-certs", runner.calls[-1])

    def test_optional_signing_preserves_debug_fallback(self):
        apk = self.make_apk()
        runner = FakeAndroidTools(self.badging(), certificate="00" * 32)

        result = self.verify(
            apk,
            runner,
            signing_policy="optional",
            signing_configured=False,
        )

        self.assertTrue(result.debug_fallback)
        self.assertIsNone(result.certificate_sha256)
        self.assertNotIn("--print-certs", runner.calls[-1])

    def test_optional_signing_pins_configured_release_certificate(self):
        apk = self.make_apk()
        runner = FakeAndroidTools(self.badging())

        result = self.verify(
            apk,
            runner,
            signing_policy="optional",
            signing_configured=True,
        )

        self.assertFalse(result.debug_fallback)
        self.assertEqual(android_release.RELEASE_CERT_SHA256, result.certificate_sha256)

    def test_release_signing_must_be_configured(self):
        with self.assertRaisesRegex(
            android_release.VerificationError,
            "signing was not configured",
        ):
            self.verify(
                self.make_apk(),
                FakeAndroidTools(self.badging()),
                signing_configured=False,
            )

    def test_bad_certificate_fails(self):
        with self.assertRaisesRegex(
            android_release.VerificationError,
            "signing certificate",
        ):
            self.verify(
                self.make_apk(),
                FakeAndroidTools(self.badging(), certificate="00" * 32),
            )

    def test_package_version_code_abi_library_and_debug_failures(self):
        cases = (
            (
                "package",
                {"package_id": "com.meteor.other"},
                self.badging(),
                {},
                "package name",
            ),
            (
                "version",
                {"expected_version": "4.5.4"},
                self.badging(),
                {},
                "versionName",
            ),
            (
                "versionCode",
                {"base_version_code": 19999},
                self.badging(),
                {},
                "versionCode",
            ),
            (
                "ABI",
                {},
                self.badging(abis=("x86_64",)),
                {"abis": ("x86_64",)},
                "arm64-only",
            ),
            (
                "library",
                {},
                self.badging(),
                {"libraries": ("libmpv.so",)},
                "libmediakitandroidhelper.so",
            ),
            (
                "debuggable",
                {"forbid_debuggable": True},
                self.badging(debuggable=True),
                {},
                "release build mode",
            ),
        )
        for name, options, badging, apk_options, message in cases:
            with self.subTest(name):
                apk = self.make_apk(**apk_options)
                with self.assertRaisesRegex(
                    android_release.VerificationError,
                    message,
                ):
                    self.verify(
                        apk,
                        FakeAndroidTools(badging),
                        **options,
                    )


if __name__ == "__main__":
    unittest.main()
