"""REQ-DMG-1 / REQ-DMG-3 / REQ-DMG-4 / REQ-SIGN-1 release-contract tests."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def read(name: str) -> str:
    return (ROOT / name).read_text()


def test_local_bundle_installer_contract_and_dry_run():
    source = read("scripts/install.sh")
    assert "--bundle and --checksum-file must be provided together" in source
    assert "Packaged bundle SHA-256 verification failed" in source
    assert "HAM_TLS_BACKEND=s_client requires openssl." in source
    assert 'env+=("HAM_TLS_BACKEND=s_client")' in source
    assert source.index('if [ -n "$local_bundle" ]') < source.index('download "$base/SHA256SUMS"')

    with tempfile.TemporaryDirectory() as td:
        bundle = Path(td) / "heimdall-local-darwin-amd64.tar.gz"
        sums = Path(td) / "SHA256SUMS"
        bundle.write_bytes(b"fixture")
        sums.write_text("0" * 64 + f"  {bundle.name}\n")
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/install.sh"), "--hub", "https://hub.example.com", "--version", "v1.2.3",
             "--bundle", str(bundle), "--checksum-file", str(sums), "--non-interactive", "--dry-run"],
            cwd=ROOT, text=True, capture_output=True,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert "Verify and install packaged bundle" in result.stdout
        assert "Download heimdall-local" not in result.stdout


def test_curl_and_dmg_share_signed_archive():
    package = read("scripts/release/package-local-binary-tarball.sh")
    stage = read("scripts/release/stage-macos-desktop-resources.sh")
    workflow = read(".github/workflows/release-local-binaries.yml")
    assert "HEIMDALL_REQUIRE_MACOS_SIGNING" in package
    assert "--identifier \"$identifier\" --options runtime --timestamp" in package
    assert package.index("codesign --force") < package.index('tar -C "$stage" -czf')
    assert 'install -m 0644 "$bundle" "$out_dir/$archive"' in stage
    assert '"developer_id_signed"[[:space:]]*:[[:space:]]*true' in stage
    assert "MACOS_DEVELOPER_ID_P12_BASE64" in workflow
    assert 'CSC_NAME=${identity#Developer ID Application: }' in workflow
    assert "codesign --verify --strict" in workflow
    assert "Build, sign, and notarize Heimdall DMG" in workflow
    assert 'electron-builder --mac dmg "$arch" --publish never' in workflow
    assert 'scripts/release/staple-with-retry.sh "$dmg"' in workflow
    assert "xcrun stapler validate" in workflow


def test_dmg_configuration_embeds_bridge_and_enables_hardened_runtime():
    config = read("electron-builder.yml")
    package = read("package.json")
    notarize_hook = read("scripts/release/notarize-electron.cjs")
    assert "from: release-assets/bridge" in config
    assert "hardenedRuntime: true" in config
    assert "notarize: false" in config
    assert "afterSign: scripts/release/notarize-electron.cjs" in config
    assert '"dist:mac": "npm run build && electron-builder --mac dmg"' in package
    assert "Failed to staple your application" in notarize_hook
    assert "staple-with-retry.sh" in notarize_hook


def test_stapler_retry_is_bounded_and_recovers_from_transient_error_68():
    """REQ-DMG-4: transient CloudKit ticket failures retry; exhaustion fails closed."""
    script = ROOT / "scripts/release/staple-with-retry.sh"
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        app = root / "Heimdall.app"
        app.mkdir()
        dmg = root / "Heimdall.dmg"
        dmg.write_bytes(b"fixture")
        count_file = root / "count"
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            "#!/usr/bin/env bash\n"
            "count=0\n"
            "[ ! -f \"$STAPLE_COUNT_FILE\" ] || count=$(cat \"$STAPLE_COUNT_FILE\")\n"
            "count=$((count + 1))\n"
            "printf '%s' \"$count\" > \"$STAPLE_COUNT_FILE\"\n"
            "if [ \"$count\" -lt \"$STAPLE_SUCCEED_ON\" ]; then exit 68; fi\n"
        )
        fake_xcrun.chmod(0o755)
        env = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "STAPLE_COUNT_FILE": str(count_file),
            "HEIMDALL_STAPLE_MAX_ATTEMPTS": "3",
            "HEIMDALL_STAPLE_RETRY_DELAY_SECONDS": "0",
        }

        recovered = subprocess.run(
            ["bash", str(script), str(app)],
            cwd=ROOT,
            env={**env, "STAPLE_SUCCEED_ON": "3"},
            text=True,
            capture_output=True,
        )
        assert recovered.returncode == 0, recovered.stdout + recovered.stderr
        assert count_file.read_text() == "3"

        count_file.unlink()
        exhausted = subprocess.run(
            ["bash", str(script), str(dmg)],
            cwd=ROOT,
            env={**env, "HEIMDALL_STAPLE_MAX_ATTEMPTS": "2", "STAPLE_SUCCEED_ON": "99"},
            text=True,
            capture_output=True,
        )
        assert exhausted.returncode != 0
        assert count_file.read_text() == "2"


if __name__ == "__main__":
    tests = [
        test_local_bundle_installer_contract_and_dry_run,
        test_curl_and_dmg_share_signed_archive,
        test_dmg_configuration_embeds_bridge_and_enables_hardened_runtime,
        test_stapler_retry_is_bounded_and_recovers_from_transient_error_68,
    ]
    for case in tests:
        case()
        print(f"PASS: {case.__name__}")
