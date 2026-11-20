"""Name and verify Android release APKs.

The release workflows use this module so APK names, package metadata, ABI
selection, versionCode offsets, and signing checks stay in one place.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile
from typing import Callable, Sequence


RELEASE_CERT_SHA256 = (
    "8d432df267b5eb175c2f806381c44d7b4bf657145af792ace223af34e340f740"
)
VERSION_CODE_SPLIT_OFFSET = 2000
MAX_ANDROID_VERSION_CODE = 2_100_000_000
STABLE_VERSION_CODE_SLOT = 999
MAX_BETA_VERSION_CODE_SLOT = 998
ARM64_ABI = "arm64-v8a"
_SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
_ANDROID_VERSION = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.([1-9]\d*))?\Z"
)
_CERT_DIGEST = re.compile(
    r"certificate SHA-256 digest:\s*([0-9a-fA-F: ]+)", re.IGNORECASE
)

Runner = Callable[..., subprocess.CompletedProcess[str]]


class VerificationError(RuntimeError):
    """Raised when an APK does not match the release contract."""


@dataclass(frozen=True)
class ApkMetadata:
    package_name: str
    version_name: str
    version_code: int
    abis: tuple[str, ...]
    native_libraries: tuple[str, ...]
    debuggable: bool


@dataclass(frozen=True)
class VerificationResult:
    metadata: ApkMetadata
    signing: str
    certificate_sha256: str | None
    debug_fallback: bool


def apk_basename(version_label: str, package_id: str) -> str:
    """Return the release APK basename while preserving the channel suffix."""
    for label, value in (("version", version_label), ("package id", package_id)):
        if not _SAFE_NAME.fullmatch(value):
            raise VerificationError(f"Invalid Android APK {label}: {value!r}")
    return f"Iroru-android-arm64-v8a_{version_label}_{package_id}.apk"


def version_code_base(
    version: str,
    *,
    latest_stable: str | None = None,
) -> int:
    """Return the base versionCode, optionally enforcing the Beta base rule."""
    match = _ANDROID_VERSION.fullmatch(version)
    if not match:
        raise VerificationError(
            f"Invalid Android release version: {version!r}; expected "
            "MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N."
        )
    major, minor, patch = map(int, match.group(1, 2, 3))
    beta = match.group(4)
    slot = STABLE_VERSION_CODE_SLOT if beta is None else int(beta)
    if (
        minor >= 100
        or patch >= 1000
        or (beta is not None and slot > MAX_BETA_VERSION_CODE_SLOT)
    ):
        raise VerificationError(
            "Android versionCode requires minor < 100, patch < 1000, "
            f"and Beta sequence 1..{MAX_BETA_VERSION_CODE_SLOT}."
        )
    if latest_stable is not None:
        stable_match = _ANDROID_VERSION.fullmatch(latest_stable)
        if beta is None or stable_match is None or stable_match.group(4):
            raise VerificationError(
                "A Beta version and a stable latest release are required "
                "for Beta version validation."
            )
        stable = tuple(map(int, stable_match.group(1, 2, 3)))
        expected = (stable[0], stable[1], stable[2] + 1)
        base = (major, minor, patch)
        if base != expected:
            raise VerificationError(
                f"Beta base {major}.{minor}.{patch} must be the next PATCH "
                f"after latest stable {latest_stable}: "
                f"{expected[0]}.{expected[1]}.{expected[2]}."
            )
    code = ((major * 100 + minor) * 1000 + patch) * 1000 + slot
    if code + VERSION_CODE_SPLIT_OFFSET > MAX_ANDROID_VERSION_CODE:
        raise VerificationError(
            f"Android versionCode {code + VERSION_CODE_SPLIT_OFFSET} exceeds "
            "the platform limit."
        )
    return code


def _parse_badging(
    output: str,
) -> tuple[str, str, int, tuple[str, ...], bool]:
    lines = output.splitlines()
    package_line = next(
        (line for line in lines if line.startswith("package: ")),
        "",
    )
    if not package_line:
        raise VerificationError("aapt did not report an Android package line.")

    attributes = dict(re.findall(r"(\w+)='([^']*)'", package_line))
    package_name = attributes.get("name", "")
    version_name = attributes.get("versionName", "")
    version_code_text = attributes.get("versionCode", "")
    if not package_name or not version_code_text.isdigit():
        raise VerificationError(
            f"Unable to read Android package metadata: {package_line}"
        )

    native_code_line = next(
        (line for line in lines if line.startswith("native-code:")),
        "",
    )
    if not native_code_line:
        raise VerificationError("aapt did not report native-code ABIs.")
    declared_abis = tuple(sorted(re.findall(r"'([^']+)'", native_code_line)))

    return (
        package_name,
        version_name,
        int(version_code_text),
        declared_abis,
        any(line.startswith("application-debuggable") for line in lines),
    )


def _native_entries(apk: Path) -> tuple[tuple[str, ...], tuple[str, ...]]:
    try:
        with zipfile.ZipFile(apk) as archive:
            entries = [name for name in archive.namelist() if name.startswith("lib/")]
    except (OSError, zipfile.BadZipFile) as error:
        raise VerificationError(f"Unable to read APK entries from {apk}: {error}") from error

    abis: set[str] = set()
    for entry in entries:
        parts = entry.split("/")
        if len(parts) >= 3 and parts[1] and parts[2]:
            abis.add(parts[1])
    return tuple(sorted(abis)), tuple(sorted(entries))


def discover_android_tool(tool_name: str, android_home: Path | None = None) -> Path:
    """Find a tool in the newest installed Android build-tools directory."""
    home = android_home or os.environ.get("ANDROID_HOME") or os.environ.get(
        "ANDROID_SDK_ROOT"
    )
    if not home:
        raise VerificationError(
            "ANDROID_HOME or ANDROID_SDK_ROOT is required to find Android build tools."
        )

    build_tools = Path(home) / "build-tools"
    if not build_tools.is_dir():
        raise VerificationError(f"Android build-tools directory not found: {build_tools}")

    def version_key(directory: Path) -> tuple[int, ...]:
        return tuple(int(part) for part in re.findall(r"\d+", directory.name))

    for directory in sorted(build_tools.iterdir(), key=version_key, reverse=True):
        if not directory.is_dir():
            continue
        for filename in (tool_name, f"{tool_name}.exe", f"{tool_name}.bat"):
            candidate = directory / filename
            if candidate.is_file():
                return candidate
    raise VerificationError(f"Android build tool not found: {tool_name}")


def _run_tool(
    command: Sequence[str | os.PathLike[str]],
    runner: Runner,
) -> str:
    normalized = [str(part) for part in command]
    try:
        result = runner(
            normalized,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise VerificationError(
            f"Unable to run {Path(normalized[0]).name}: {error}"
        ) from error

    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        raise VerificationError(
            f"{Path(normalized[0]).name} failed with exit code "
            f"{result.returncode}:\n{output.strip()}"
        )
    return output


def _verify_signing(
    apk: Path,
    *,
    apksigner: Path,
    policy: str,
    signing_configured: bool,
    expected_cert_sha256: str,
    runner: Runner,
) -> tuple[str, str | None, bool]:
    if policy == "signed":
        _run_tool([apksigner, "verify", apk], runner)
        return "signature verified (certificate pin skipped)", None, False

    if policy not in ("release", "optional"):
        raise VerificationError(f"Unsupported Android signing policy: {policy}")

    if not signing_configured:
        if policy == "release":
            raise VerificationError("Android release signing was not configured.")
        _run_tool([apksigner, "verify", apk], runner)
        return (
            "signature verified (debug fallback; certificate pin skipped)",
            None,
            True,
        )

    output = _run_tool([apksigner, "verify", "--print-certs", apk], runner)
    match = _CERT_DIGEST.search(output)
    if not match:
        raise VerificationError(
            f"Unable to read the Android signing certificate for {apk}."
        )

    actual_cert = re.sub(r"[^0-9a-f]", "", match.group(1).lower())
    expected_cert = re.sub(r"[^0-9a-f]", "", expected_cert_sha256.lower())
    if actual_cert != expected_cert:
        raise VerificationError(
            f"Unexpected Android signing certificate for {apk}: {actual_cert}"
        )
    return f"signature verified with certificate {actual_cert}", actual_cert, False


def verify_apk(
    apk: str | os.PathLike[str],
    *,
    package_id: str,
    aapt: str | os.PathLike[str],
    apksigner: str | os.PathLike[str],
    expected_version: str | None = None,
    base_version_code: int | None = None,
    signing_policy: str,
    signing_configured: bool = False,
    required_libraries: Sequence[str] = (),
    forbid_debuggable: bool = False,
    expected_cert_sha256: str = RELEASE_CERT_SHA256,
    runner: Runner = subprocess.run,
) -> VerificationResult:
    """Check one release APK against its package, ABI, version, and signing policy."""
    apk_path = Path(apk)
    if not apk_path.is_file() or apk_path.stat().st_size == 0:
        raise VerificationError(f"APK is missing or empty: {apk_path}")

    badging = _run_tool([aapt, "dump", "badging", apk_path], runner)
    (
        package_name,
        version_name,
        version_code,
        declared_abis,
        debuggable,
    ) = _parse_badging(badging)

    if package_name != package_id:
        raise VerificationError(
            f"Unexpected Android package name: {package_name}; expected {package_id}."
        )
    if expected_version is not None and version_name != expected_version:
        raise VerificationError(
            f"Unexpected Android versionName: {version_name}; expected {expected_version}."
        )
    if base_version_code is not None:
        if base_version_code < 0:
            raise VerificationError("Android base versionCode must not be negative.")
        expected_code = base_version_code + VERSION_CODE_SPLIT_OFFSET
        if expected_code > MAX_ANDROID_VERSION_CODE:
            raise VerificationError(
                f"Android versionCode {expected_code} exceeds the platform limit."
            )
        if version_code != expected_code:
            raise VerificationError(
                f"arm64 versionCode {version_code} does not preserve the legacy "
                f"split offset from base versionCode {base_version_code}."
            )

    abis, native_libraries = _native_entries(apk_path)
    if declared_abis != abis:
        raise VerificationError(
            f"aapt reported ABI entries {declared_abis}, but the APK contains {abis}."
        )
    if abis != (ARM64_ABI,):
        found = ", ".join(abis) or "<none>"
        raise VerificationError(f"Expected an arm64-only APK, found ABI entries: {found}.")

    required = {
        f"lib/{ARM64_ABI}/{library}"
        for library in required_libraries
    }
    missing = sorted(required.difference(native_libraries))
    if missing:
        raise VerificationError(
            f"Missing native libraries from {apk_path}: {', '.join(missing)}"
        )

    if forbid_debuggable and debuggable:
        raise VerificationError("APK must use the release build mode.")

    signing, certificate_sha256, debug_fallback = _verify_signing(
        apk_path,
        apksigner=Path(apksigner),
        policy=signing_policy,
        signing_configured=signing_configured,
        expected_cert_sha256=expected_cert_sha256,
        runner=runner,
    )
    return VerificationResult(
        metadata=ApkMetadata(
            package_name=package_name,
            version_name=version_name,
            version_code=version_code,
            abis=abis,
            native_libraries=native_libraries,
            debuggable=debuggable,
        ),
        signing=signing,
        certificate_sha256=certificate_sha256,
        debug_fallback=debug_fallback,
    )


def _parse_bool(value: str) -> bool:
    normalized = value.lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    name = commands.add_parser("name", help="Print a release APK basename.")
    name.add_argument("--version", dest="version_label", required=True)
    name.add_argument("--package-id", required=True)

    version_code = commands.add_parser(
        "version-code",
        help="Print the base versionCode for a release version.",
    )
    version_code.add_argument("--version", dest="version_label", required=True)
    version_code.add_argument("--latest-stable")

    verify = commands.add_parser("verify", help="Verify one release APK.")
    verify.add_argument("--apk", type=Path, required=True)
    verify.add_argument("--package-id", required=True)
    verify.add_argument("--expected-version")
    verify.add_argument("--base-version-code", type=int)
    verify.add_argument(
        "--signing-policy",
        choices=("release", "signed", "optional"),
        required=True,
    )
    verify.add_argument("--signing-configured", type=_parse_bool, default=False)
    verify.add_argument("--require-library", action="append", default=[])
    verify.add_argument("--forbid-debuggable", action="store_true")
    verify.add_argument("--aapt", type=Path)
    verify.add_argument("--apksigner", type=Path)
    verify.add_argument("--android-home", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "name":
            print(apk_basename(args.version_label, args.package_id))
            return 0

        if args.command == "version-code":
            print(
                version_code_base(
                    args.version_label,
                    latest_stable=args.latest_stable,
                )
            )
            return 0

        aapt = args.aapt or discover_android_tool("aapt", args.android_home)
        apksigner = args.apksigner or discover_android_tool(
            "apksigner",
            args.android_home,
        )
        result = verify_apk(
            args.apk,
            package_id=args.package_id,
            aapt=aapt,
            apksigner=apksigner,
            expected_version=args.expected_version,
            base_version_code=args.base_version_code,
            signing_policy=args.signing_policy,
            signing_configured=args.signing_configured,
            required_libraries=args.require_library,
            forbid_debuggable=args.forbid_debuggable,
        )
        metadata = result.metadata
        print(f"APK: {args.apk}")
        print(f"package: {metadata.package_name}")
        print(f"versionName: {metadata.version_name}")
        print(f"versionCode: {metadata.version_code}")
        print(f"ABIs: {', '.join(metadata.abis)}")
        libraries = [
            entry
            for entry in metadata.native_libraries
            if entry.endswith(".so")
        ]
        print(f"native libraries: {', '.join(libraries) or '<none>'}")
        print(f"signing: {result.signing}")
        return 0
    except VerificationError as error:
        prefix = (
            "::error::"
            if os.environ.get("GITHUB_ACTIONS") == "true"
            else "error: "
        )
        print(f"{prefix}{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
