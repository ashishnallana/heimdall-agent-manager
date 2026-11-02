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
    assert "HAM_TLS_BACKEND=s_client requires openssl." not in source
    assert 'env+=("HAM_TLS_BACKEND=s_client")' not in source
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
    assert "Build, sign, and notarize Ninjy DMG" in workflow
    assert 'electron-builder --mac dmg zip "$arch" --publish never' in workflow
    assert 'scripts/release/staple-with-retry.sh "$dmg"' in workflow
    # REQ-DMG-4: validate contacts CloudKit too, so every validate is retried.
    assert "xcrun stapler validate" not in workflow
    for target in ("$app_bundle", "$pkg", "$dmg"):
        assert f'scripts/release/staple-with-retry.sh --validate "{target}"' in workflow


def test_dmg_configuration_embeds_bridge_and_enables_hardened_runtime():
    config = read("electron-builder.yml")
    package = read("package.json")
    notarize_hook = read("scripts/release/notarize-electron.cjs")
    assert "from: release-assets/bridge" in config
    assert "hardenedRuntime: true" in config
    assert "notarize: false" in config
    assert "afterSign: scripts/release/notarize-electron.cjs" in config
    assert '"dist:mac": "npm run build && electron-builder --mac dmg"' in package
    assert "await import('@electron/notarize')" in notarize_hook
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


def _fake_counting_xcrun(root: Path) -> Path:
    fake_bin = root / "bin"
    fake_bin.mkdir()
    fake_xcrun = fake_bin / "xcrun"
    fake_xcrun.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$*\" >> \"$STAPLE_ARGS_FILE\"\n"
        "count=$(wc -l < \"$STAPLE_ARGS_FILE\")\n"
        "if [ \"$count\" -lt \"$STAPLE_SUCCEED_ON\" ]; then\n"
        "  echo 'NSURLErrorDomain Code=-1005 The network connection was lost.' >&2; exit 68\n"
        "fi\n"
    )
    fake_xcrun.chmod(0o755)
    return fake_bin


def test_stapler_validate_retry_is_bounded_and_logged():
    """REQ-DMG-4: `--validate` retries `xcrun stapler validate`; exhaustion fails closed."""
    script = ROOT / "scripts/release/staple-with-retry.sh"
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        fake_bin = _fake_counting_xcrun(root)
        pkg = root / "Ninjy.pkg"
        pkg.write_bytes(b"fixture")
        args_file = root / "args"
        env = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "STAPLE_ARGS_FILE": str(args_file),
            "HEIMDALL_STAPLE_MAX_ATTEMPTS": "3",
            "HEIMDALL_STAPLE_RETRY_DELAY_SECONDS": "0",
        }
        recovered = subprocess.run(
            ["bash", str(script), "--validate", str(pkg)],
            cwd=ROOT, env={**env, "STAPLE_SUCCEED_ON": "2"}, text=True, capture_output=True,
        )
        assert recovered.returncode == 0, recovered.stdout + recovered.stderr
        assert args_file.read_text().splitlines() == [f"stapler validate -v {pkg}"] * 2
        assert f"Validating {pkg} (attempt 1/3)" in recovered.stdout
        assert "Validating failed (attempt 1/3); retrying in 0s." in recovered.stderr

        args_file.unlink()
        exhausted = subprocess.run(
            ["bash", str(script), "--validate", str(pkg)],
            cwd=ROOT, env={**env, "STAPLE_SUCCEED_ON": "99"}, text=True, capture_output=True,
        )
        assert exhausted.returncode == 1
        assert len(args_file.read_text().splitlines()) == 3
        assert f"Validating failed after 3 attempts: {pkg}" in exhausted.stderr


def _run_with_fake_gh(root: Path, script: str, gh_body: str, extra_env=None):
    fake_bin = root / "bin"
    fake_bin.mkdir(exist_ok=True)
    fake_gh = fake_bin / "gh"
    fake_gh.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n"
        "calls=$(grep -c . \"$GH_LOG\")\n" + gh_body
    )
    fake_gh.chmod(0o755)
    log = root / "gh.log"
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "GH_LOG": str(log),
        "STATE": str(root / "state"),
        "GITHUB_WORKSPACE": str(ROOT),
        "HEIMDALL_GH_RETRY_MAX_ATTEMPTS": "3",
        "HEIMDALL_GH_RETRY_DELAY_SECONDS": "0",
        **(extra_env or {}),
    }
    result = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script], cwd=ROOT, env=env, text=True, capture_output=True,
    )
    calls = log.read_text().splitlines() if log.exists() else []
    log.unlink(missing_ok=True)
    return result, calls


def test_gh_retry_retries_only_transient_errors_and_is_bounded():
    lib = 'source scripts/release/gh-retry.sh; '
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        flaky = (
            'if [ "$calls" -lt 3 ]; then\n'
            '  echo "HTTP 403: Resource not accessible by integration (https://api.github.com/repos/o/r/releases)" >&2\n'
            '  exit 1\n'
            'fi\n'
        )
        ok, calls = _run_with_fake_gh(root, lib + 'retry_transient "Create release" gh release create v1', flaky)
        assert ok.returncode == 0, ok.stdout + ok.stderr
        assert len(calls) == 3
        assert "Create release (attempt 3/3)" in ok.stdout
        assert "Create release hit a transient error (exit 1); retrying in 0s." in ok.stderr

        exhausted, calls = _run_with_fake_gh(
            root, lib + 'retry_transient "Upload" gh release upload v1', 'echo "HTTP 502: Bad Gateway" >&2; exit 1\n',
        )
        assert exhausted.returncode == 1
        assert len(calls) == 3
        assert "Upload failed after 3 attempts on transient errors" in exhausted.stderr

        fatal, calls = _run_with_fake_gh(
            root, lib + 'retry_transient "Edit" gh release edit v1', 'echo "HTTP 422: Validation Failed" >&2; exit 4\n',
        )
        assert fatal.returncode == 4
        assert len(calls) == 1
        assert "Edit failed with a non-transient error (exit 4); not retrying." in fatal.stderr


def _publish_block() -> str:
    workflow = read(".github/workflows/release-local-binaries.yml")
    start = workflow.index('          source "$GITHUB_WORKSPACE/scripts/release/gh-retry.sh"\n')
    end = workflow.index("\n", workflow.index('gh release edit "$VERSION" "${edit_flags[@]}"', start))
    end = workflow.index("          fi\n", end) + len("          fi\n")
    block = workflow[start:end].replace("${{ needs.prepare.outputs.clean_version }}", "1.2.3")
    assert "${{" not in block
    return block


def test_publish_create_is_idempotent_after_partial_create():
    """A create that dies after gh made the (draft) release falls through to upload + edit."""
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "notes.md").write_text("notes\n")
        prelude = (
            f'VERSION=v1.2.3; RELEASE_COMMIT=abc123; BUILD_DARWIN_X64=false; RUNNER_TEMP="{root}"\n'
            f'notes_file="{root}/notes.md"; release_flags=(--prerelease)\n'
        )
        gh = (
            'case "$1 $2" in\n'
            '  "release view")\n'
            '    [ -f "$STATE" ] || { echo "release not found" >&2; exit 1; }\n'
            '    case "$*" in *assets*) echo "Ninjy-1.2.3-x64.dmg";; esac ;;\n'
            '  "release create") : > "$STATE"; echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;\n'
            '  "release delete-asset"|"release upload"|"release edit") ;;\n'
            '  *) echo "unexpected gh $*" >&2; exit 9 ;;\n'
            'esac\n'
        )
        result, calls = _run_with_fake_gh(root, prelude + _publish_block(), gh)
        assert result.returncode == 0, result.stdout + result.stderr
        verbs = [" ".join(c.split()[:2]) for c in calls]
        assert verbs == [
            "release view", "release create", "release view", "release view",
            "release delete-asset", "release upload", "release edit",
        ], calls
        assert "switching to upload + edit" in result.stdout
        assert calls[-1] == (
            f"release edit v1.2.3 --notes-file {root}/notes.md --title v1.2.3 --target abc123 "
            "--draft=false --prerelease=true"
        )

        # Existing release: unchanged upload + notes-only edit, no create.
        (root / "state").write_text("")
        result, calls = _run_with_fake_gh(root, prelude + _publish_block(), gh)
        assert result.returncode == 0, result.stdout + result.stderr
        assert not any(c.startswith("release create") for c in calls)
        assert calls[-1] == f"release edit v1.2.3 --notes-file {root}/notes.md"


if __name__ == "__main__":
    tests = [
        test_local_bundle_installer_contract_and_dry_run,
        test_curl_and_dmg_share_signed_archive,
        test_dmg_configuration_embeds_bridge_and_enables_hardened_runtime,
        test_stapler_retry_is_bounded_and_recovers_from_transient_error_68,
        test_stapler_validate_retry_is_bounded_and_logged,
        test_gh_retry_retries_only_transient_errors_and_is_bounded,
        test_publish_create_is_idempotent_after_partial_create,
    ]
    for case in tests:
        case()
        print(f"PASS: {case.__name__}")
