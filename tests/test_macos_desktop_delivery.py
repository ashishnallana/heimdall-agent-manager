"""REQ-DMG-1 / REQ-DMG-3 / REQ-SIGN-1 release-contract tests."""

from pathlib import Path
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
    assert "xcrun stapler validate" in workflow


def test_dmg_configuration_embeds_bridge_and_enables_hardened_runtime():
    config = read("electron-builder.yml")
    package = read("package.json")
    assert "from: release-assets/bridge" in config
    assert "hardenedRuntime: true" in config
    assert "afterSign: scripts/release/notarize-electron.cjs" in config
    assert '"dist:mac": "npm run build && electron-builder --mac dmg"' in package


if __name__ == "__main__":
    tests = [
        test_local_bundle_installer_contract_and_dry_run,
        test_curl_and_dmg_share_signed_archive,
        test_dmg_configuration_embeds_bridge_and_enables_hardened_runtime,
    ]
    for case in tests:
        case()
        print(f"PASS: {case.__name__}")
