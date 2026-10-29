#!/usr/bin/env python3
"""Integration tests for the non-hub binary distribution flow (REQ-DIST-6).

Verifies the distribution surfaces end-to-end and hermetically:

1. Tarball packaging: scripts/release/package-local-binary-tarball.sh produces a
   tarball with the required entries (bin/ham-bridge,
   bin/ham-pty-host, bin/ham-ctl, README.md, LICENSE, METADATA.json), executable
   modes for binaries, and a valid METADATA.json schema. Stub binaries stand in
   for the Nix outputs (the script only stages files, so stubs exercise it
   fully).
2. Checksum validation: the release-workflow SHA256SUMS layout
   (.github/workflows/release-local-binaries.yml) round-trips — hashlib,
   sha256sum(1) and install.sh's awk lookup all agree — and a tampered tarball
   no longer matches (fail-closed property).
3. Installer: scripts/install.sh passes `bash -n` and its --dry-run output
   matches the documented action plan (offline-safe: the --version/--hub
   resolution paths are asserted; the bare --dry-run only needs exit 0). The
   rendered unit carries --hub only when it was passed (no placeholder hub).
   Full sandboxed runs against a local file:// --hub mirror prove the
   service-file lifecycle (backup of a differing unit, identical re-run is a
   no-op, --force-service skips the backup), and unshare -r dry runs prove the
   sudo path (SUDO_USER resolution + root refusal) with zero writes. Real
   uid-0 runs inside unshare -rm (private mounts) prove the sudo branch writes
   the PATH export into the TARGET user's rc file even when root's PATH
   already contains /usr/local/bin, and that failed chowns warn with path,
   owner and remediation while the install stays non-fatal.
3b. Platform coverage, stated plainly because the file cannot imply coverage it
   does not have: every target here comes from host_target(), which reads the
   REAL host. On Linux the darwin branches of the installer tests -- the
   ~/Library/LaunchAgents service paths, render_launchd_plist's output as an
   installed file, the `launchctl bootout` in do_uninstall -- do NOT execute;
   only the plist RENDER assertion does. They execute when this same file runs
   unchanged on a Mac, which .github/workflows/install-sh.yml does on macos-14
   and macos-15-intel alongside scripts/ci/installer-smoke.sh, the end-to-end
   install/uninstall proof against the real published release. See
   host_target()'s docstring.
3c. Live-HOME tripwire (REQ-INST-19). Every test in this file runs between a
   before/after snapshot of the real user's home -- the paths install.sh can
   create, modify or delete -- and a test that changes any of them FAILS, even
   if it otherwise passed or skipped. The home is resolved from the password
   database, never from $HOME, because a test that escapes its sandbox is by
   definition a test that set $HOME somewhere else. See
   assert_live_home_untouched(); it is the post-condition sibling of
   assert_bridge_isolated()'s pre-condition.
4. (removed: the `heimdall` manager CLI was folded into ham-bridge.)
5. Documentation regression: SELF_HOSTING.md Part 2 documents the curl|bash
   installer and ham-bridge as the primary setup path while keeping the
   manual/Nix paths, and Part 1 (hub) headings are intact.

Run: python3 tests/test_binary_distribution.py
Env: HEIMDALL_BIN=<path> skips the odin build and tests that binary instead.
"""
from pathlib import Path
import contextlib
import hashlib
import http.server
import json
import os
import platform
import plistlib
import re
import shlex
import shutil
import socketserver
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_SCRIPT = ROOT / 'scripts' / 'release' / 'package-local-binary-tarball.sh'
STORELESS_SCRIPT = ROOT / 'scripts' / 'release' / 'storeless-exec.sh'
SECCOMP_PROBE_SCRIPT = ROOT / 'scripts' / 'release' / 'android-seccomp-probe.sh'
# android-seccomp-probe.sh contract: 1 = denylisted syscall (or control not
# rejected), 3 = could not trace at all.
SECCOMP_PROBE_VIOLATION = 1
SECCOMP_PROBE_UNTRACEABLE = 3
INSTALLER_SMOKE_SCRIPT = ROOT / 'scripts' / 'ci' / 'installer-smoke.sh'
# storeless-exec.sh contract: the static control exits 42, and 70 means no
# clean-environment mechanism could be validated.
STORELESS_CONTROL_RC = 42
STORELESS_NO_MECHANISM = 70
INSTALL_SCRIPT = ROOT / 'scripts' / 'install.sh'
GITHUB_REPO = 'tanmayv/heimdall-agent-manager'


class Skip(Exception):
    pass


def run(argv, cwd=None, timeout=120, env=None):
    return subprocess.run(
        [str(a) for a in argv],
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def host_target():
    """The release target of the REAL host -- never forced, never overridden.

    This is load-bearing for the darwin coverage, so read it before trusting a
    LaunchAgents assertion below. On a Linux host every test that calls this
    gets a linux-* target, and each `else` branch holding a
    ~/Library/LaunchAgents path is therefore DEAD CODE in that run. Those
    branches are not simulated anywhere: the only darwin behaviour that
    executes on Linux is the plist RENDER assertion in dry_run_unit_text /
    test_install_sh_dry_run_hub, which proves the template is well-formed and
    nothing about installing, re-installing or uninstalling on a Mac.

    What DOES execute them is running this same file unchanged on a real Mac,
    which .github/workflows/install-sh.yml does on macos-14 (aarch64-darwin) and
    macos-15-intel (x86_64-darwin) -- there host_target() returns darwin-* and
    the darwin branches are taken for real. That workflow also names the tests
    whose darwin halves must have PASSED, so they cannot quietly become skips.
    Deliberately NOT solved with a platform override: install.sh must grow no
    test-only surface, and simulated coverage on Linux would still not prove
    plutil accepts the plist or that launchd paths are writable.
    """
    system = platform.system()
    machine = platform.machine()
    if system == 'Linux':
        os_name = 'linux'
    elif system == 'Darwin':
        os_name = 'darwin'
    else:
        return None
    if machine in ('x86_64', 'amd64'):
        arch = 'amd64'
    elif machine in ('arm64', 'aarch64'):
        arch = 'arm64'
    else:
        return None
    return f'{os_name}-{arch}'


def make_stub_input(base: Path, name: str, binaries: list) -> Path:
    """A fake Nix output directory: <dir>/bin/<binary> per name."""
    out = base / name
    (out / 'bin').mkdir(parents=True)
    for binary in binaries:
        stub = out / 'bin' / binary
        stub.write_text(f'#!/bin/sh\necho "{binary} stub"\n')
        stub.chmod(0o755)
    return out


def package_tarball(base: Path, *, with_pty_host=True, with_openssl=False,
                    ctl_binaries=('ham-ctl',), target='linux-amd64'):
    """Run the packaging script against stub inputs; return (result, tarball)."""
    out_dir = base / 'dist'
    bridge = make_stub_input(base, 'bridge-out',
                             ['ham-bridge'] + (['openssl'] if with_openssl else []))
    ctl = make_stub_input(base, 'ctl-out', list(ctl_binaries))
    argv = ['bash', PACKAGE_SCRIPT, target, 'v0.1.0', out_dir,
            bridge, ctl]
    if with_pty_host:
        argv.append(make_stub_input(base, 'ptyhost-out', ['ham-pty-host']))
    res = run(argv, cwd=ROOT)
    return res, out_dir / f'heimdall-local-{target}.tar.gz'


def read_tarball(tarball: Path):
    with tarfile.open(tarball, 'r:gz') as tf:
        names = tf.getnames()
        modes = {m.name: m.mode for m in tf.getmembers()}
        metadata = json.load(tf.extractfile('METADATA.json'))
    return names, modes, metadata


# ---- 1. tarball packaging ----------------------------------------------------

def test_tarball_structure_and_metadata(ctx):
    res, tarball = package_tarball(ctx['work'], with_pty_host=True, with_openssl=True)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    assert tarball.is_file(), f'tarball not created at {tarball}'
    printed = [line for line in res.stdout.splitlines() if line.strip()]
    assert printed[-1] == str(tarball), (
        f'script must print the tarball path; got stdout: {res.stdout!r}')

    names, modes, metadata = read_tarball(tarball)
    required = {
        'bin/ham-bridge', 'bin/ham-pty-host', 'bin/ham-ctl',
        'README.md', 'LICENSE', 'METADATA.json',
    }
    missing = required - set(names)
    assert not missing, f'tarball missing required entries: {sorted(missing)}'
    assert 'bin/openssl' in names, 'bundled openssl must ship when present in the bridge output'

    for binary in ('ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert modes[f'bin/{binary}'] & 0o111, f'bin/{binary} must be executable in the tarball'

    expected_keys = {'product', 'version', 'target', 'commit', 'built_at',
                     'binaries', 'developer_id_signed', 'http_client', 'tls_dependency'}
    assert set(metadata.keys()) == expected_keys, (
        f'METADATA.json keys mismatch: {sorted(metadata.keys())}')
    assert metadata['product'] == 'heimdall-local'
    assert metadata['version'] == 'v0.1.0'
    assert metadata['target'] == 'linux-amd64'
    assert isinstance(metadata['commit'], str) and metadata['commit'], 'commit must be non-empty'
    assert isinstance(metadata['built_at'], str) and metadata['built_at'], 'built_at must be non-empty'
    assert sorted(metadata['binaries']) == ['ham-bridge', 'ham-ctl', 'ham-pty-host'], (
        f'METADATA.json binaries mismatch: {metadata["binaries"]}')
    assert isinstance(metadata['tls_dependency'], str) and metadata['tls_dependency']
    # libcurl is linked statically at the version pinned in nix/libcurl-pin.json.
    pinned_curl = json.loads((ROOT / 'nix' / 'libcurl-pin.json').read_text())['curl']['version']
    assert f'libcurl {pinned_curl}, statically linked' in metadata['http_client'], metadata['http_client']

    ctx['tarball'] = tarball


def test_tarball_without_pty_host(ctx):
    res, tarball = package_tarball(ctx['work2'], with_pty_host=False)
    assert res.returncode == 0, f'5-arg (no pty-host) invocation failed:\n{res.stderr}'
    names, _, metadata = read_tarball(tarball)
    for entry in ('bin/ham-bridge', 'bin/ham-ctl',
                  'README.md', 'LICENSE', 'METADATA.json'):
        assert entry in names, f'entry {entry} missing from 5-arg tarball'
    assert 'bin/ham-pty-host' not in names, 'pty-host must not ship when not provided'
    assert 'bin/openssl' not in names, 'openssl must not ship when not bundled'
    assert sorted(metadata['binaries']) == ['ham-bridge', 'ham-ctl'], (
        f'METADATA.json binaries mismatch: {metadata["binaries"]}')


def test_termux_build_carries_release_target(ctx):
    """T13: only the termux Odin builds define HAM_RELEASE_TARGET=termux-arm64.

    Without it the termux bundle reports linux-arm64 and self-updates to the
    glibc bundle, which dies under Android's seccomp (REQ-T13-1)."""
    flake = (ROOT/'flake.nix').read_text()
    def block(name):
        start = flake.index(f'      {name} = ')
        end = flake.index('\n\n', start)
        return flake[start:end]
    termux = block('mkTermuxOdinPackage')
    assert '-define:HAM_RELEASE_TARGET=termux-arm64' in termux, termux
    assert 'HAM_RELEASE_TARGET' not in block('mkReleaseOdinPackage'), 'linux/darwin builds keep the native target'
    contracts = (ROOT/'src/contracts/release_target.odin').read_text()
    assert '#config(HAM_RELEASE_TARGET, "")' in contracts, 'define name matches the contracts #config'


def test_termux_tarball_target(ctx):
    """T12: termux-arm64 is a release target with the linux-* layout."""
    base = ctx['work'] / 'termux-tarball'
    base.mkdir()
    res, tarball = package_tarball(base, target='termux-arm64')
    assert res.returncode == 0, f'termux-arm64 packaging failed:\n{res.stderr}'
    assert tarball.name == 'heimdall-local-termux-arm64.tar.gz', tarball
    names, _, metadata = read_tarball(tarball)
    for entry in ('bin/ham-bridge', 'bin/ham-ctl', 'bin/ham-pty-host',
                  'scripts/apply-bridge-update.sh', 'README.md', 'LICENSE', 'METADATA.json'):
        assert entry in names, f'entry {entry} missing from termux tarball'
    assert metadata['target'] == 'termux-arm64', metadata['target']


def test_packaging_error_cases(ctx):
    base = ctx['work'] / 'errors'
    base.mkdir()
    bridge = make_stub_input(base, 'bridge-out', ['ham-bridge'])
    ctl = make_stub_input(base, 'ctl-out', ['ham-ctl'])
    out_dir = base / 'dist'
    res = run(['bash', PACKAGE_SCRIPT, 'solaris-sparc64', 'v0.1.0', out_dir,
               bridge, ctl], cwd=ROOT)
    assert res.returncode == 2, f'unsupported target must exit 2, got {res.returncode}'
    assert 'unsupported release target' in res.stderr

    incomplete_ctl = make_stub_input(base, 'ctl-incomplete', [])
    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', out_dir,
               bridge, incomplete_ctl], cwd=ROOT)
    assert res.returncode == 1, f'missing input must exit 1, got {res.returncode}'
    assert 'missing required release input' in res.stderr

    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', out_dir], cwd=ROOT)
    assert res.returncode == 2, f'wrong argument count must exit 2 (usage), got {res.returncode}'


# ---- 2. SHA256SUMS validation ------------------------------------------------

def test_sha256sums_validation(ctx):
    if 'tarball' not in ctx:
        raise Skip('packaging test did not produce a tarball')
    tarball: Path = ctx['tarball']
    version = 'v0.1.0'
    dist = ctx['work'] / 'checksums'
    dist.mkdir(parents=True)

    # Replicate the release workflow: copy to the versioned asset name, then
    # sha256sum over the versioned names -> SHA256SUMS.
    asset = dist / f'heimdall-local-linux-amd64-{version}.tar.gz'
    shutil.copy(tarball, asset)
    digest = sha256_of(asset)
    sums = dist / 'SHA256SUMS'
    sums.write_text(f'{digest}  {asset.name}\n')

    # Independent recomputation agrees.
    assert sha256_of(asset) == digest
    # The system tool the workflow/installer rely on agrees with hashlib.
    if shutil.which('sha256sum'):
        cli = run(['sha256sum', asset]).stdout.split()[0]
    elif shutil.which('shasum'):
        cli = run(['shasum', '-a', '256', asset]).stdout.split()[0]
    else:
        raise Skip('neither sha256sum nor shasum available')
    assert cli == digest, f'sha256sum CLI {cli} != hashlib {digest}'
    # install.sh's awk lookup finds the hash (GitHub release flow, versioned name).
    got = run(['awk', '-v', f'f={asset.name}', '$2 == f {print $1; exit}', sums]).stdout.strip()
    assert got == digest, f'awk lookup for {asset.name} returned {got!r}'
    # install.sh --hub flow: unversioned target tarball name.
    hub_sums = dist / 'SHA256SUMS-hub'
    hub_name = 'heimdall-local-linux-amd64.tar.gz'
    hub_sums.write_text(f'{digest}  {hub_name}\n')
    got = run(['awk', '-v', f'f={hub_name}', '$2 == f {print $1; exit}', hub_sums]).stdout.strip()
    assert got == digest, f'awk lookup for {hub_name} returned {got!r}'

    # Fail-closed: a tampered tarball no longer matches the recorded checksum.
    tampered = dist / 'tampered.tar.gz'
    data = bytearray(asset.read_bytes())
    data[-1] ^= 0xFF
    tampered.write_bytes(bytes(data))
    assert sha256_of(tampered) != digest, 'tampered tarball must not match SHA256SUMS'


# ---- 3. install.sh -----------------------------------------------------------

def test_install_sh_syntax(ctx):
    res = run(['bash', '-n', INSTALL_SCRIPT], env=dry_run_env(ctx))
    assert res.returncode == 0, f'bash -n failed:\n{res.stderr}'
    # REQ-INST-4: main "$@" must be the final line, and nothing may execute at
    # top level before it — not even the shell-options statement.
    text = INSTALL_SCRIPT.read_text(encoding='utf-8')
    lines = [line for line in text.splitlines() if line.strip()]
    assert lines[-1] == 'main "$@"', f'last line must be main "$@", got {lines[-1]!r}'
    for line in text.splitlines():
        assert not line.startswith('set -'), (
            f'"set -" must live inside main(), not at top level: {line!r}')
    assert '\n  set -euo pipefail\n' in text, 'main() must enable set -euo pipefail'


def shell_function(script: Path, name: str) -> str:
    match = re.search(
        rf'(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}\n',
        script.read_text(encoding='utf-8'))
    assert match, f'{name}() not found in {script}'
    return match.group(0)


def test_report_shared_openssl_guard_has_teeth(ctx):
    """The CI proof gate must fail closed on every unproven outcome."""
    base = ctx['work'] / 'report-shared-openssl'
    base.mkdir(parents=True, exist_ok=True)
    function = shell_function(INSTALLER_SMOKE_SCRIPT, 'report_shared_openssl')
    harness = f'''set +e
ok() {{ :; }}
sha_of() {{ printf '%s\\n' hash; }}
cmp() {{
  if [ "$case_mode" = cmp-error ]; then return 2; fi
  command cmp "$@"
}}
{function}
run_case() {{
  label="$1"
  expected="$2"
  openssl_pre_existed="$3"
  case_mode="$4"
  case_dir={shlex.quote(str(base))}/"$label"
  sandbox="$case_dir/sandbox"
  openssl_path="$case_dir/openssl"
  openssl_pre_sha=before
  mkdir -p "$sandbox"
  case "$case_mode" in
    absent) ;;
    created) printf created >"$openssl_path" ;;
    deleted) printf before >"$sandbox/openssl-before" ;;
    identical)
      printf same >"$sandbox/openssl-before"
      printf same >"$openssl_path"
      ;;
    replaced)
      printf before >"$sandbox/openssl-before"
      printf after >"$openssl_path"
      ;;
    cmp-error)
      printf same >"$sandbox/openssl-before"
      printf same >"$openssl_path"
      ;;
  esac
  report_shared_openssl >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  printf 'report_shared_openssl branch=%s status=%s expected=%s\\n' \
    "$label" "$status" "$expected"
  if [ "$status" -ne "$expected" ]; then
    cat "$case_dir/stdout" "$case_dir/stderr" >&2
    return 1
  fi
}}
failures=0
run_case proven-absence 0 false absent || failures=$((failures + 1))
run_case unexpected-creation 1 false created || failures=$((failures + 1))
run_case unexpected-deletion 1 true deleted || failures=$((failures + 1))
run_case byte-identical 0 true identical || failures=$((failures + 1))
run_case byte-replacement 1 true replaced || failures=$((failures + 1))
run_case cmp-error 1 true cmp-error || failures=$((failures + 1))
exit "$failures"
'''
    res = run(['bash', '-c', harness], cwd=ROOT)
    print(res.stdout, end='')
    expected = (
        'report_shared_openssl branch=proven-absence status=0 expected=0\n'
        'report_shared_openssl branch=unexpected-creation status=1 expected=1\n'
        'report_shared_openssl branch=unexpected-deletion status=1 expected=1\n'
        'report_shared_openssl branch=byte-identical status=0 expected=0\n'
        'report_shared_openssl branch=byte-replacement status=1 expected=1\n'
        'report_shared_openssl branch=cmp-error status=1 expected=1\n'
    )
    assert res.stdout == expected, (
        f'guard branch results changed:\n{res.stdout}\nstderr:\n{res.stderr}')
    assert res.returncode == 0, f'guard branch harness failed:\n{res.stderr}'


def test_install_sh_help(ctx):
    res = run(['bash', INSTALL_SCRIPT, '--help'], env=dry_run_env(ctx))
    assert res.returncode == 0
    assert 'usage: install.sh' in res.stderr
    assert '--version <tag>' in res.stderr and '--hub <url>' in res.stderr
    assert '--dry-run' in res.stderr
    assert '--force-service' in res.stderr, 'usage() must document --force-service'
    assert '--uninstall' in res.stderr, 'usage() must document --uninstall (REQ-INST-8)'


def dry_run_unit_text(res):
    """Slice the rendered service file out of a --dry-run plan."""
    out = res.stdout
    tail = out[out.index('would write service file'):]
    if '[Unit]' in tail:
        start = tail.index('[Unit]')
        end = tail.index('WantedBy=default.target') + len('WantedBy=default.target')
    else:
        start = tail.index('<!DOCTYPE plist')
        end = tail.index('</plist>') + len('</plist>')
    return tail[start:end]


def dry_run_common_asserts(res, target, install_dir_hint):
    assert res.returncode == 0, f'--dry-run failed:\n{res.stderr}'
    out = res.stdout
    assert f'platform: {target.replace("-", "/")}' in out, 'platform line missing'
    for line in ('would download:', 'would verify SHA-256', 'would install'):
        assert line in out, f'dry run must state {line!r}'
    install_line = next(line for line in out.splitlines() if 'would install' in line)
    for binary in ('bin/heimdall', 'bin/ham-bridge', 'bin/ham-pty-host', 'bin/ham-ctl'):
        assert binary in install_line, f'{binary} missing from would-install line'
    assert install_dir_hint in install_line, f'install dir {install_dir_hint} missing'
    assert 'PATH' in out, 'dry run must mention PATH handling'
    assert '--force-service' in out, 'dry run must mention --force-service'
    # INVERTED (REQ-ENROLL-9): was `'heimdall enroll' in out`. That command is
    # DELETED along with the `hbe_` one-time token; onboarding now shows the
    # browser-approved device flow. Both halves matter: the presence half pins the
    # new command, and the absence half is what catches a revert or a half-applied
    # merge putting the old one back -- a presence-only assert passes happily with
    # both flows in the file.
    assert 'ham-bridge enroll --hub' in out, (
        'onboarding must show the device-flow enroll command')
    assert 'heimdall enroll' not in out, (
        'deleted `heimdall enroll` command reappeared in onboarding')
    assert 'hbe_' not in out, 'deleted hbe_ token vocabulary reappeared in onboarding'
    if target.startswith('linux'):
        # REQ-INST-28: ExecStart and the interpolated Environment= values are
        # QUOTED now, because systemd splits those lines on unquoted whitespace
        # and a spaced $install_dir silently truncated them. The opening quote is
        # part of each marker deliberately: matching the bare key would still
        # pass if the quoting were reverted.
        for marker in ('[Unit]', 'Description=Heimdall Bridge', 'ExecStart="',
                       'Environment="HEIMDALL_HAM_PTY_HOST_BIN=',
                       'WantedBy=default.target'):
            assert marker in out, f'systemd unit missing {marker!r}'
        assert 'systemctl --user enable --now heimdall-bridge' in out
    else:
        for marker in ('<!DOCTYPE plist', 'works.earendil.heimdall-bridge', 'RunAtLoad'):
            assert marker in out, f'launchd plist missing {marker!r}'
        assert 'launchctl bootstrap' in out


def test_install_sh_dry_run_version(ctx):
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh dry-run: {platform.system()}/{platform.machine()}')
    install_dir = '/usr/local/bin' if os.geteuid() == 0 else '.local/bin'
    res = run(['bash', INSTALL_SCRIPT, '--dry-run', '--version', 'v0.1.0'], timeout=60,
              env=dry_run_env(ctx))
    dry_run_common_asserts(res, target, install_dir)
    assert 'release: v0.1.0' in res.stdout
    expected_url = (f'https://github.com/{GITHUB_REPO}/releases/download/v0.1.0/'
                    f'heimdall-local-{target}-v0.1.0.tar.gz')
    assert f'would download: {expected_url}' in res.stdout
    assert 'would download: https://github.com/' + f'{GITHUB_REPO}/releases/download/v0.1.0/SHA256SUMS' in res.stdout
    # REQ-INST-1: no --hub flag and no placeholder hub in the rendered unit
    # when --hub was not passed — the bridge reads config.toml instead.
    unit = dry_run_unit_text(res)
    assert '--hub' not in unit, 'unit must not carry --hub when --hub was not passed'
    assert 'hub.example.com' not in unit, 'placeholder hub must not appear in the unit'
    assert 'hub.example.com' not in res.stdout, 'placeholder hub must not appear anywhere in the dry-run plan'


def test_install_sh_dry_run_hub(ctx):
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh dry-run: {platform.system()}/{platform.machine()}')
    install_dir = '/usr/local/bin' if os.geteuid() == 0 else '.local/bin'
    hub = 'http://hub.example.test'
    res = run(['bash', INSTALL_SCRIPT, '--dry-run', '--hub', hub], timeout=60,
              env=dry_run_env(ctx))
    dry_run_common_asserts(res, target, install_dir)
    assert 'release: github' in res.stdout
    assert f'would download: https://github.com/{GITHUB_REPO}/releases/' in res.stdout
    assert f'ham-bridge enroll --hub {hub}' in res.stdout, (
        f'onboarding must show `ham-bridge enroll --hub {hub}`')
    assert 'hbe_' not in res.stdout, 'deleted hbe_ token vocabulary reappeared'
    # The hub URL must be baked into the rendered service file as well as the
    # download URLs and onboarding text (tarball + sums + unit + onboarding).
    assert res.stdout.count(hub) >= 4, 'hub URL must appear in downloads, unit and onboarding'
    # REQ-INST-1: an explicitly passed --hub is a deliberate operator choice
    # and DOES land in the rendered unit.
    unit = dry_run_unit_text(res)
    assert '--hub' in unit, 'unit must carry --hub when it was explicitly passed'
    # The FORM differs by platform and this assertion used to state only the
    # systemd one, so it was wrong on darwin -- and being wrong cost nothing
    # until the suite first ran on a Mac, because host_target() never returns
    # darwin-* on Linux. systemd puts the flag and its value on an ExecStart
    # continuation line; a launchd plist spells them as two separate <string>
    # elements in ProgramArguments (service_hub_flags_plist, install.sh:711-716),
    # so '--hub <url>' as one literal string cannot appear there. The full-run
    # test below already knew this; this one did not.
    if target.startswith('linux'):
        assert f'--hub "{hub}"' in unit, 'the passed hub URL must follow --hub in the unit'
    else:
        assert '<string>--hub</string>' in unit, (
            'the plist must pass --hub as its own ProgramArguments string')
        assert f'<string>{hub}</string>' in unit, (
            'the plist must pass the hub URL as the string after --hub')


def test_install_sh_dry_run_bare(ctx):
    # Offline-tolerant: even when the latest-tag lookup fails the dry run must
    # still exit 0 and print the plan.
    res = run(['bash', INSTALL_SCRIPT, '--dry-run'], timeout=90, env=dry_run_env(ctx))
    assert res.returncode == 0, f'bare --dry-run failed:\n{res.stderr}'
    assert 'platform:' in res.stdout and 'would install' in res.stdout
    assert 'hub.example.com' not in res.stdout, 'placeholder hub must not appear in the dry-run plan'


def need_tool(name):
    if shutil.which(name) is None:
        raise Skip(f'{name} not available')


def sha256_cli(path) -> list:
    """The argv a FIXTURE should use to hash a file, mirroring install.sh.

    sha256_or_empty (install.sh:610-613) falls back sha256sum -> shasum -a 256
    because macOS ships only the latter. Test code has to make the same choice:
    a bare ['sha256sum', ...] here raised FileNotFoundError on macos-14, which
    main() counts as a FAILURE of the test rather than of the installer.
    """
    if shutil.which('sha256sum'):
        return ['sha256sum', str(path)]
    if shutil.which('shasum'):
        return ['shasum', '-a', '256', str(path)]
    raise Skip('neither sha256sum nor shasum is available to hash with')


def make_hub_mirror(base: Path, tarball: Path, target: str) -> str:
    """Stage the --hub mirror layout: unversioned tarball name plus SHA256SUMS.
    install.sh names the files heimdall-local-<target>.tar.gz / SHA256SUMS and
    looks the digest up with awk '$2 == f', so the sums entry must use the
    UNVERSIONED basename or the run reports a checksum mismatch."""
    mirror = base / 'mirror'
    mirror.mkdir(parents=True)
    asset_name = f'heimdall-local-{target}.tar.gz'
    shutil.copy(tarball, mirror / asset_name)
    digest = sha256_of(mirror / asset_name)
    (mirror / 'SHA256SUMS').write_text(f'{digest}  {asset_name}\n')
    return f'file://{mirror}'


# --- REQ-INST-6: hermetic release-resolution harness --------------------------
#
# install.sh resolves the latest tag against https://api.github.com, hard-coded.
# These tests never reach it. The installer runs with PATH pointing at a
# directory holding ONLY symlinks to the utilities the script needs plus a FAKE
# curl or wget, so there is no real downloader on that PATH at all: a request
# that escaped the stub could not be made, rather than quietly succeeding
# against the live API and making the test look like it passed.
#
# Stubbing the TOOL rather than adding an env override to install.sh is
# deliberate. It keeps test-only hooks out of the shipped installer and it
# exercises the real branch logic in api_fetch / resolve_latest_tag, including
# the curl-vs-wget split that is itself one of the bugs under test.
#
# NOTE ON SUCCESS CASES: a stub that resolves a tag successfully is only ever
# driven with --dry-run. A bare REAL run would carry on past resolution into the
# tarball download, and the point of this harness is that nothing reaches the
# network. Failure cases can use a real run safely: they exit at resolution,
# before the downloader guard or any write.

# Utilities install.sh needs on PATH. curl and wget are deliberately ABSENT --
# make_api_stub adds exactly the fake one a given test wants.
SHIM_TOOLS = ['bash', 'sh', 'uname', 'mktemp', 'sed', 'awk', 'head', 'tail', 'cat',
              'cp', 'mv', 'rm', 'ln', 'mkdir', 'rmdir', 'chmod', 'chown', 'touch',
              'grep', 'tr', 'cut', 'sort', 'id', 'date', 'dirname', 'basename',
              'env', 'tee', 'wc', 'stat', 'find', 'readlink', 'expr', 'sleep',
              'tar', 'gzip', 'sha256sum', 'shasum', 'systemctl', 'launchctl',
              'getent', 'whoami', 'install', 'printf', 'test', 'true', 'false']

RELEASE_LATEST_JSON = '{"tag_name": "v9.9.9", "name": "Heimdall v9.9.9"}\n'
# GitHub returns /releases newest-first; install.sh takes the first tag_name.
RELEASE_LIST_PRERELEASE_JSON = (
    '[{"tag_name": "v1.2.3-beta.2", "prerelease": true, "draft": false},\n'
    ' {"tag_name": "v1.2.3-beta.1", "prerelease": true, "draft": false}]\n')


def write_socat_stub(directory: Path) -> Path:
    """Put a no-op `socat` on a PATH entry (REQ-INST-14).

    install.sh resolves socat with `command -v socat` and NEVER executes it --
    presence is the whole contract -- so a stub is an honest stand-in rather
    than a fake. The suite supplying it is what makes every other test
    deterministic on hosts with and without socat installed, instead of the
    fatal preflight silently turning into a host-dependent skip.

    A real socat is deliberately NOT symlinked here: a test must not pass only
    because the machine happened to have the dependency.
    """
    directory.mkdir(parents=True, exist_ok=True)
    stub = directory / 'socat'
    if not stub.exists():
        stub.write_text('#!/bin/sh\n'
                        '# no-op stand-in: install.sh only probes for presence\n'
                        'exit 0\n')
        stub.chmod(0o755)
    return stub


# The stub's directory name has TWO independent users -- socat_stub_dir() below
# creates it, and sandbox_home_writes() excludes it from "what the install wrote".
# A renamed literal in one place and not the other fails SILENTLY: the stub would
# start being reported as install.sh output. One definition, so it cannot drift.
SOCAT_STUB_DIRNAME = '.socat-stub'


def socat_stub_dir(home: Path) -> Path:
    """The PATH entry carrying the socat stub for a sandboxed install run.

    Defined ONCE on purpose (REQ-INST-22). Every sandboxed run -- the plain ones
    and the uid-0 namespace ones alike -- must get its socat from the suite and
    not from the host, or REQ-INST-14's fatal preflight turns into a
    host-dependent outcome. sudo_ns_install used to build its env inline and so
    never got a stub; it passed only because this host keeps socat outside /usr,
    where its own tmpfs-over-/usr could not hide it.

    Callers must keep this directory OUTSIDE any path the run bind-mounts over:
    sudo_ns_install shadows the target user's real home, so a stub under that
    home would vanish inside the namespace.
    """
    socat_dir = home / SOCAT_STUB_DIRNAME
    write_socat_stub(socat_dir)
    return socat_dir


def _shim_dir(base: Path, name: str, *, with_socat: bool = True) -> Path:
    shim = base / name
    shim.mkdir(parents=True, exist_ok=True)
    for tool in SHIM_TOOLS:
        real = shutil.which(tool)
        if real and not (shim / tool).exists():
            (shim / tool).symlink_to(real)
    # stub_env sets PATH to this directory ALONE, so without socat here every
    # test that reaches the REQ-INST-14 preflight would die on it. Tests that
    # want socat ABSENT ask for it with with_socat=False.
    if with_socat:
        write_socat_stub(shim)
    return shim


def make_api_stub(base: Path, name: str, *, tool: str,
                  latest_status: str = '200', latest_body: str = RELEASE_LATEST_JSON,
                  latest_headers: tuple = (),
                  list_status: str = '200', list_body: str = '[]\n',
                  list_headers: tuple = ()) -> Path:
    """Build a PATH dir whose only downloader is a fake `tool` answering the two
    endpoints install.sh asks for. tool=None means NO downloader at all.

    Status '000' makes the stub behave like a host that got no HTTP response
    (curl exit 6 / wget exit 4, nothing on stdout), which is how api_fetch tells
    a dead network apart from an HTTP error.

    *_headers are extra response header lines ('Name: value'), which is how a
    test says whether the server reported an exhausted rate limit. The DEFAULT is
    no headers, because that is what a secondary/abuse-limited 403 looks like --
    the case install.sh must not diagnose as the hourly limit.
    """
    shim = _shim_dir(base, name)
    data = base / (name + '-data')
    data.mkdir(parents=True, exist_ok=True)
    (data / 'latest.json').write_text(latest_body)
    (data / 'list.json').write_text(list_body)
    (data / 'latest.hdr').write_text(''.join(h + '\n' for h in latest_headers))
    (data / 'list.hdr').write_text(''.join(h + '\n' for h in list_headers))
    if tool is None:
        return shim

    bash_path = shutil.which('bash')
    assert bash_path, 'bash is required to build the downloader stub'
    if tool == 'curl':
        script = f"""#!{bash_path}
# Fake curl. Covers api_fetch's `-sS -o BODY -w %{{http_code}} URL` shape.
out=""; url=""; hdr=""; fail_fast=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    # -D is api_fetch's header capture. WITHOUT this arm the -[!-]* cluster arm
    # below eats only the flag and leaves its FILENAME to be read as the URL, so
    # the stub would answer the wrong endpoint and the bug would look like a
    # script bug rather than a stub bug.
    -D) hdr="$2"; shift 2 ;;
    -w|--connect-timeout|--max-time|--speed-limit|--speed-time|--retry) shift 2 ;;
    # A single-dash cluster containing f is -f/-fL/-fsSL: fail-fast. The stub MUST
    # model this. Without it the stub answers an HTTP error identically with and
    # without -f, so the test cannot see that dropping -f is what PRESERVES the
    # status code -- the whole mechanism keeping 403 distinguishable from 404.
    -[!-]*) case "$1" in *f*) fail_fast=1 ;; esac; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */releases/latest) status="{latest_status}"; src="{data}/latest.json"; hsrc="{data}/latest.hdr" ;;
  */releases)        status="{list_status}";   src="{data}/list.json";   hsrc="{data}/list.hdr" ;;
  *)                 status="404";             src="/dev/null";          hsrc="/dev/null" ;;
esac
if [ "$status" = "000" ]; then
  echo "curl: (6) Could not resolve host: api.github.com" >&2
  exit 6
fi
# Real curl -D writes the status line, the headers, and a blank line, with CRLF
# endings straight off the wire. The CRLF is modelled on purpose: a header parser
# that forgets to strip the CR compares "0\r" against "0" and silently never
# matches, which would make the rate-limit discrimination fail closed in the one
# direction no assertion would notice.
if [ -n "$hdr" ]; then
  {{ printf 'HTTP/1.1 %s stub\r\n' "$status"
    while IFS= read -r line; do printf '%s\r\n' "$line"; done <"$hsrc"
    printf '\r\n'; }} >"$hdr"
fi
if [ "$fail_fast" = 1 ]; then
  case "$status" in
    2*) ;;
    *)  # Real `curl -f`: exit 22, NO body, and NO status on stdout. The code is
        # destroyed, which is precisely why api_fetch must not pass -f.
        echo "curl: (22) The requested URL returned error: $status" >&2
        exit 22 ;;
  esac
fi
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
# Real curl WITHOUT -f exits 0 on an HTTP error and reports the code via -w,
# which is exactly why api_fetch dropped -f.
printf '%s' "$status"
exit 0
"""
    elif tool == 'wget':
        script = f"""#!{bash_path}
# Fake wget. Covers api_fetch's `-q -S -O BODY --tries=1 ... URL` shape; -S puts
# the status line on stderr, which is where api_fetch reads the code from.
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */releases/latest) status="{latest_status}"; src="{data}/latest.json"; hsrc="{data}/latest.hdr" ;;
  */releases)        status="{list_status}";   src="{data}/list.json";   hsrc="{data}/list.hdr" ;;
  *)                 status="404";             src="/dev/null";          hsrc="/dev/null" ;;
esac
if [ "$status" = "000" ]; then
  echo "wget: unable to resolve host address 'api.github.com'" >&2
  exit 4
fi
# wget -S indents every header line by two spaces and writes them to stderr,
# which is a different shape from curl's -D file. api_fetch feeds both to the
# same parser, so both shapes are exercised here.
echo "  HTTP/1.1 $status stub" >&2
while IFS= read -r line; do echo "  $line" >&2; done <"$hsrc"
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
case "$status" in
  2*) exit 0 ;;
  *)  exit 8 ;;
esac
"""
    else:
        raise AssertionError(f'unknown stub tool {tool!r}')

    stub = shim / tool
    stub.write_text(script)
    stub.chmod(0o755)
    return shim


def stub_env(home: Path, runtime: Path, shim: Path) -> dict:
    env = sandbox_install_env(home, runtime)
    # PATH is the shim ALONE. This is the hermetic guarantee: no real curl or
    # wget is reachable, so no test here can contact api.github.com.
    env['PATH'] = str(shim)
    return env


def run_installer(shim: Path, work: Path, tag: str, *args):
    home = work / f'home-{tag}'
    runtime = work / f'run-{tag}'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    # subprocess.run directly, matching the env-passing idiom the sandboxed
    # tests above already use (run() takes no env).
    return install_run_shielded(['bash', str(INSTALL_SCRIPT), *args],
                               stub_env(home, runtime, shim), timeout=90)


def assert_only_message(res, expected_fragments, forbidden_fragments):
    out = res.stdout + res.stderr
    for fragment in expected_fragments:
        assert fragment in out, f'missing {fragment!r} in:\n{out}'
    for fragment in forbidden_fragments:
        assert fragment not in out, f'unexpected {fragment!r} in:\n{out}'


# Fragments unique to each of the five diagnoses. Every resolution test asserts
# its own AND the absence of the other four, so the causes cannot silently
# re-collapse into one message the way they were before REQ-INST-6.
MSG_NO_DOWNLOADER = 'need curl or wget to resolve the latest release'
MSG_RATE_LIMIT = 'the unauthenticated rate limit (60 requests/hour/IP) is exhausted'
MSG_NO_RELEASES = 'lists no published release for this repository'
MSG_UNREACHABLE = 'could not reach api.github.com (no HTTP response'
MSG_NO_TAG_FIELD = 'answered the latest-release lookup with no tag_name field'
# A 403 that does NOT carry X-RateLimit-Remaining: 0 is its own diagnosis, not the
# rate-limit one. GitHub answers 403 for secondary (abuse) limiting as well, where
# "wait for the window to reset" is wrong advice rather than merely unproven.
MSG_403_UNCONFIRMED = 'did not report an exhausted rate limit'
ALL_RESOLVE_MSGS = [MSG_NO_DOWNLOADER, MSG_RATE_LIMIT, MSG_NO_RELEASES,
                    MSG_UNREACHABLE, MSG_NO_TAG_FIELD, MSG_403_UNCONFIRMED]


def others(mine):
    return [m for m in ALL_RESOLVE_MSGS if m != mine]


def install_sh_code() -> str:
    """install.sh with comment lines stripped.

    Regression checks that assert an OLD construct is gone must not read the
    comments, because install.sh deliberately quotes what it replaced -- the old
    catch-all message and the old unbounded wget call are both recorded verbatim
    in comments explaining why they were wrong.
    """
    return '\n'.join(line for line in INSTALL_SCRIPT.read_text().splitlines()
                     if not line.lstrip().startswith('#'))


def test_resolve_messages_are_distinct(ctx):
    """Structural guard: the five diagnoses must stay mutually exclusive and each
    must carry a next step. Before REQ-INST-6 four causes shared ONE message, so
    a regression that re-merges any two of them is the thing to catch."""
    text = INSTALL_SCRIPT.read_text()
    for msg in ALL_RESOLVE_MSGS:
        assert msg in text, f'diagnosis missing from install.sh: {msg!r}'
    for i, a in enumerate(ALL_RESOLVE_MSGS):
        for b in ALL_RESOLVE_MSGS[i + 1:]:
            assert a not in b and b not in a, f'diagnoses overlap: {a!r} / {b!r}'
    # Each resolve_error must name something the user can actually do next. The
    # `resolve_error=""` reset at the top of the function is not a diagnosis, so
    # the pattern requires a non-empty value.
    for line in re.findall(r'resolve_error="([^"]+)"', text):
        assert ('--version' in line or '--hub' in line or 'install one' in line
                or 'publish it' in line), f'diagnosis has no next step: {line!r}'
    assert 'api.github.com unreachable?' not in install_sh_code(), \
        'the old catch-all message is back'


def test_resolve_no_downloader(ctx):
    """(a) Neither curl nor wget. Diagnosed BEFORE any network attempt, and it
    must NOT claim the network is unreachable -- the network was never tried."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-nodl', tool=None)
    assert shutil.which('curl', path=str(shim)) is None
    assert shutil.which('wget', path=str(shim)) is None

    res = run_installer(shim, work, 'nodl-real')
    assert res.returncode != 0, f'a real run with no downloader must fail:\n{res.stdout}'
    assert_only_message(res, ['error: ' + MSG_NO_DOWNLOADER, '--version <tag>'],
                        others(MSG_NO_DOWNLOADER))

    # The dry run REPORTS the same cause as a warning and still exits 0: the
    # downloader guard stays below the dry-run exit precisely so this works.
    res = run_installer(shim, work, 'nodl-dry', '--dry-run')
    assert res.returncode == 0, f'--dry-run must survive a missing downloader:\n{res.stderr}'
    assert_only_message(res, ['warning: ' + MSG_NO_DOWNLOADER, 'platform:', 'would install'],
                        others(MSG_NO_DOWNLOADER))


def test_resolve_wget_only_host(ctx):
    """(b) curl absent, wget present -- the sharpened REQ-INST-6 root cause.

    resolve_latest_tag used to call curl and ONLY curl, so this host was told
    'api.github.com unreachable?' when the truth was 'curl is not installed'.
    The fix makes the lookup WORK here, so the assertion is success: the tag is
    resolved through wget and no diagnosis is printed at all."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-wgetonly', tool='wget')
    assert shutil.which('curl', path=str(shim)) is None
    assert shutil.which('wget', path=str(shim)) is not None

    res = run_installer(shim, work, 'wgetonly', '--dry-run')
    assert res.returncode == 0, f'wget-only resolution failed:\n{res.stderr}'
    assert_only_message(res, ['release: v9.9.9', 'releases/download/v9.9.9/'],
                        ALL_RESOLVE_MSGS + ['api.github.com unreachable'])


def test_resolve_rate_limited_confirmed(ctx):
    """(c) HTTP 403 WITH X-RateLimit-Remaining: 0 -- the server itself saying the
    hourly limit is exhausted. Only here may the message name that cause, and the
    reset timestamp is included because it is what makes "wait" actionable."""
    work = ctx['work']
    reset = 4102444800  # 2100-01-01T00:00:00Z: fixed, so the assertion cannot flake.
    shim = make_api_stub(work, 'stub-403-confirmed', tool='curl', latest_status='403',
                         latest_body='{"message": "API rate limit exceeded"}\n',
                         latest_headers=('X-RateLimit-Limit: 60',
                                         'X-RateLimit-Remaining: 0',
                                         f'X-RateLimit-Reset: {reset}'))
    res = run_installer(shim, work, 'rl-confirmed')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res, ['error: api.github.com rejected the request with HTTP 403',
                              MSG_RATE_LIMIT, 'transient', '--version <tag>'],
                        others(MSG_RATE_LIMIT))
    # The reset time only counts if it was actually rendered from the header.
    out = res.stdout + res.stderr
    if 'resets at' in out:
        assert '2100-01-01 00:00:00Z' in out, f'reset time not rendered from the header:\n{out}'
    else:
        # Neither GNU `date -d @N` nor BSD `date -r N` worked on this host, which
        # epoch_utc is designed to survive silently. It must then print no reset
        # claim at all rather than a raw epoch number.
        assert str(reset) not in out, f'raw epoch leaked into the message:\n{out}'


def test_resolve_403_without_ratelimit_header_does_not_claim_the_limit(ctx):
    """THE NEGATIVE BRANCH, and the reason this test replaced its predecessor.

    The old test stubbed a 403 with NO rate-limit headers and asserted the
    exhausted-limit claim -- so the suite PINNED a message that names a cause the
    response never established. Worse, GitHub answers 403 for secondary (abuse)
    rate limiting too, and for that mechanism "wait for the window to reset" is
    actively wrong: the hourly window is not what is blocking the caller and
    waiting it out does not clear it.

    So a headerless 403 must report only what is known -- the status, what the
    body said, and the --version escape hatch -- and the assertion that matters is
    the ABSENCE of the rate-limit claim."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-403-bare', tool='curl', latest_status='403',
                         latest_body='{"message": "Forbidden - abuse detection"}\n')
    res = run_installer(shim, work, 'rl-bare')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res,
                        ['error: api.github.com refused the latest-release lookup with HTTP 403',
                         MSG_403_UNCONFIRMED,
                         'Forbidden - abuse detection',  # the body excerpt, quoted not paraphrased
                         '--version <tag>'],
                        others(MSG_403_UNCONFIRMED) + [
                            # Named explicitly as well as via others(), because these
                            # three are the specific wrong claims being guarded:
                            '60 requests/hour/IP',
                            'is exhausted',
                            'wait for the window to reset',
                        ])


def test_resolve_403_discrimination_also_works_on_a_wget_only_host(ctx):
    """wget -S reports headers on stderr, indented, in a different shape from
    curl's -D file. api_fetch parses both with one reader, so the discrimination
    must hold on a wget-only host too -- otherwise half the hosts in the world get
    the unproven message back."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-403-wget', tool='wget', latest_status='403',
                         latest_body='{"message": "API rate limit exceeded"}\n',
                         latest_headers=('X-RateLimit-Remaining: 0',))
    res = run_installer(shim, work, 'rl-wget')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res, [MSG_RATE_LIMIT], others(MSG_RATE_LIMIT))

    bare = make_api_stub(work, 'stub-403-wget-bare', tool='wget', latest_status='403',
                         latest_body='{"message": "Forbidden - abuse detection"}\n')
    res = run_installer(bare, work, 'rl-wget-bare')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res, [MSG_403_UNCONFIRMED],
                        others(MSG_403_UNCONFIRMED) + ['wait for the window to reset'])


def test_resolve_prerelease_fallback(ctx):
    """(d) /releases/latest 404s because every release is a prerelease, which is
    how this project cuts them. The /releases list DOES include prereleases, so
    resolution falls back to it, picks the newest, and SAYS it picked a
    prerelease rather than passing it off as a stable release."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-pre', tool='curl',
                         latest_status='404', latest_body='{"message": "Not Found"}\n',
                         list_status='200', list_body=RELEASE_LIST_PRERELEASE_JSON)
    res = run_installer(shim, work, 'pre', '--dry-run')
    assert res.returncode == 0, f'prerelease fallback failed:\n{res.stderr}'
    assert_only_message(res, ['warning: no stable release exists yet',
                              'selected the newest PRERELEASE v1.2.3-beta.2',
                              'release: v1.2.3-beta.2',
                              'releases/download/v1.2.3-beta.2/'],
                        ALL_RESOLVE_MSGS + ['v1.2.3-beta.1'])


def test_resolve_draft_only_repo(ctx):
    """(e) THE LIVE PRODUCTION CASE. Releases here are cut through the GitHub UI
    with the workflow defaults left ticked, and release-local-binaries.yml passes
    both --draft and --prerelease. A DRAFT is invisible to an unauthenticated
    caller entirely: absent from /releases too, not merely excluded from
    /releases/latest. So the fallback finds nothing and this is the error a real
    user of the advertised one-liner hits today.

    Both shapes below are indistinguishable from outside -- an unauthenticated
    caller cannot tell a draft-only repository from a genuinely empty one, which
    is why ONE message covers both and why it must not claim to have enumerated
    the repository. The empty-list shape IS the draft-only shape.
    """
    work = ctx['work']
    for tag, list_body in (('draftonly-empty', '[]\n'),
                           ('draftonly-notags', '[{"name": "unnamed", "draft": true}]\n')):
        shim = make_api_stub(work, 'stub-' + tag, tool='curl',
                             latest_status='404', latest_body='{"message": "Not Found"}\n',
                             list_status='200', list_body=list_body)
        res = run_installer(shim, work, tag)
        assert res.returncode != 0, f'[{tag}] a repo with nothing published must fail:\n{res.stdout}'
        assert_only_message(res, ['error: api.github.com ' + MSG_NO_RELEASES,
                                  'still a DRAFT is invisible to an unauthenticated lookup',
                                  'publish it', '--version <tag>'],
                            others(MSG_NO_RELEASES))
        # Honesty: it reports what the API answered, never a claim about what the
        # repository holds. It cannot see drafts and must not imply it looked.
        out = res.stdout + res.stderr
        for overclaim in ('no releases exist', 'repository is empty',
                          'has no releases at all'):
            assert overclaim not in out, f'[{tag}] overclaims: {overclaim!r}'


def large_release_list(entries: int = 2500, pad: int = 64) -> str:
    """A /releases page whose tag_name lines TOTAL more than one 64K pipe buffer.

    DO NOT "SIMPLIFY" THIS FIXTURE DOWN TO A REALISTIC SIZE. Its size is the only
    thing it is for. parse_tag_name is `sed ... | head -n 1`: head exits after the
    first match, and sed only actually takes SIGPIPE once its REMAINING output
    exceeds the pipe buffer. A realistically-sized response is drained before sed
    ever notices, so a small fixture silently un-tests the property below.
    """
    entry = '{{"tag_name": "v9.{i}.0-{pad}", "prerelease": true, "draft": false}}'
    body = ',\n '.join(entry.format(i=i, pad='x' * pad) for i in range(entries))
    return '[' + body + ']\n'


def test_resolve_large_release_list_does_not_abort(ctx):
    """Resolution must survive a /releases page big enough to make sed take
    SIGPIPE, and still return the NEWEST tag with a complete plan.

    WHAT THIS DOES AND DOES NOT PROVE -- stated because an earlier version of this
    docstring claimed more than the test delivers:

    parse_tag_name is `sed ... | head -n 1`. head exits after the first match, and
    once sed's remaining output exceeds the 64K pipe buffer sed really does take
    SIGPIPE: measured at 141 from a 2500-entry list producing 186K of sed output.
    So this fixture DOES drive the pipeline into that state, which a
    realistically-sized response (GitHub caps a page at 100 entries) would not.
    Keep it oversized; shrinking it stops exercising this path.

    It does NOT prove parse_tag_name's `return 0` is load-bearing, and removing
    that line does NOT make this test fail. The reason is a bash rule worth
    knowing: resolve_latest_tag's only caller invokes it as
    `if resolve_latest_tag; then`, and bash SUSPENDS `set -e` for the whole body
    of a function whose status is being tested, so the 141 goes nowhere today. The
    captured VALUE is correct even at status 141, which is why nothing breaks.
    That line is kept as defence for the day someone calls resolve_latest_tag
    bare -- see the comment on api_fetch in install.sh -- and the mutation harness
    records it as expected-not-caught with that reasoning rather than pretending
    otherwise.

    What this test genuinely guards is the behaviour a user sees: a large,
    prerelease-only release list still resolves to the newest tag, still announces
    that it picked a prerelease, and still prints a whole plan rather than
    stopping part-way.
    """
    work = ctx['work']
    shim = make_api_stub(work, 'stub-biglist', tool='curl',
                         latest_status='404', latest_body='{"message": "Not Found"}\n',
                         list_status='200', list_body=large_release_list())
    res = run_installer(shim, work, 'bigl', '--dry-run')
    assert res.returncode == 0, (
        'resolution aborted on a large release list: parse_tag_name lost its '
        f'`return 0` and pipefail propagated SIGPIPE\nrc={res.returncode}\n{res.stderr}')
    # The newest entry, and a COMPLETE plan rather than one truncated by an abort.
    expected = 'v9.0.0-' + 'x' * 64
    assert_only_message(res, [f'release: {expected}',
                              f'selected the newest PRERELEASE {expected}',
                              'would install'],
                        ALL_RESOLVE_MSGS)


def test_resolve_unreachable(ctx):
    """Only a genuine absence of any HTTP response may blame the network. This is
    the ONE case the old catch-all message was actually right about."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-000', tool='curl', latest_status='000')
    res = run_installer(shim, work, 'net')
    assert res.returncode != 0, f'an unreachable API must fail the run:\n{res.stdout}'
    assert_only_message(res, ['error: ' + MSG_UNREACHABLE, 'check network, DNS, or proxy',
                              '--version <tag>'],
                        others(MSG_UNREACHABLE))


def test_resolve_200_without_tag_is_fail_closed(ctx):
    """FAIL-CLOSED. A 200 that does not parse must be a named failure, never a
    guessed tag: a wrong tag becomes a 404 on the tarball, which is worse and
    more confusing than the error it replaced."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-notag', tool='curl', latest_status='200',
                         latest_body='{"name": "v1.0.0", "assets": []}\n')
    res = run_installer(shim, work, 'notag')
    assert res.returncode != 0, f'an unparseable 200 must fail:\n{res.stdout}'
    assert_only_message(res, ['error: api.github.com ' + MSG_NO_TAG_FIELD],
                        others(MSG_NO_TAG_FIELD))
    # Nothing may have been derived from the unusable body.
    out = res.stdout + res.stderr
    assert 'releases/download' not in out, f'a tag was guessed from a bad body:\n{out}'


# --- REQ-INST-7: bounded downloads --------------------------------------------

def test_download_branches_are_equally_bounded(ctx):
    """Cheap structural regression guard on the flags. It does NOT establish
    equivalence -- test_download_bounds_are_enforced below does that by execution.

    An earlier version of this docstring claimed both paths bound total time on the
    strength of these flags, and that claim was false for BOTH of them: wget's
    --read-timeout bounds one IDLE read, not duration and not throughput, and wget
    has no total-time flag at all; curl's --max-time is per ATTEMPT, so --retry 3
    multiplied its ceiling by four. The operation-wide bounds come from run_bounded,
    so that is what this asserts."""
    text = INSTALL_SCRIPT.read_text()
    body = text.split('\ndownload() {', 1)[1].split('\n}', 1)[0]
    curl_branch, wget_branch = body.split('else', 1)

    for flag in ('--retry 3', '--connect-timeout', '--speed-limit', '--speed-time',
                 '--max-time'):
        assert flag in curl_branch, f'curl download branch lost {flag}:\n{curl_branch}'
    for flag in ('--tries=3', '--connect-timeout=', '--read-timeout='):
        assert flag in wget_branch, f'wget download branch lost {flag}:\n{wget_branch}'
    # BOTH branches must go through the watchdog: neither tool can bound the whole
    # operation on its own, so a branch that skips it is unbounded again.
    for name, branch in (('curl', curl_branch), ('wget', wget_branch)):
        assert 'run_bounded' in branch, \
            f'{name} branch no longer goes through the watchdog:\n{branch}'
    watchdog = text.split('run_bounded() {', 1)[1].split('\n}', 1)[0]
    for bound in ('NET_DOWNLOAD_MAX_TIME', 'NET_STALL_BYTES_PER_SEC', 'NET_STALL_SECONDS'):
        assert bound in watchdog, f'watchdog does not enforce {bound}:\n{watchdog}'
    # The stall WINDOW is derived from the floor, never a second literal: the
    # horizon must stay a multiple of NET_STALL_SECONDS so that retuning the
    # floor retunes the window with it. A hardcoded number here decouples them
    # silently, which is exactly the shape of bug the watchdog exists to stop.
    # Structural on purpose -- this cannot flake, unlike a timing assertion.
    assert 'stall_horizon=$(( NET_STALL_SECONDS * 2 ))' in watchdog, (
        'the stall horizon is no longer derived from NET_STALL_SECONDS:\n'
        f'{watchdog}')
    assert 'wget -O "$out" "$url"' not in install_sh_code(), \
        'the unbounded wget call is back'

    # The API lookup stays bounded too, and keeps the tighter cap: a slow small
    # response is a broken one.
    assert 'NET_API_MAX_TIME=30' in text
    # Values track src/manager/update.odin (60s tarball stall / 20-30s manifest)
    # rather than inventing new numbers for the same two operations.
    assert 'NET_STALL_SECONDS=60' in text
    odin = (ROOT / 'src' / 'manager' / 'update.odin').read_text()
    assert 'MANAGER_UPDATE_TIMEOUT_MS :: 60000' in odin, \
        'update.odin changed; re-justify install.sh download bounds against it'


# --- REQ-INST-7 adversarial download bounds ------------------------------------
# A localhost server that answers a huge Content-Length and then trickles, so a
# download starts healthily and never ends. Hermetic: loopback only, no external
# network, same discipline as the PATH shims above.

class _DribbleHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    chunk = 1
    interval = 0.5

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '100000000')
        self.end_headers()
        try:
            while True:
                self.wfile.write(b'x' * self.chunk)
                self.wfile.flush()
                time.sleep(self.interval)
        except Exception:
            pass  # client hung up: that is the bound firing, which is the point.

    def log_message(self, *a):
        pass


class _SlowFiniteHandler(http.server.BaseHTTPRequestHandler):
    """Serves a SMALL body slowly and then closes -- a successful transfer whose
    average rate is far below the stall floor."""
    protocol_version = 'HTTP/1.1'
    body = b'heimdall' * 12   # 96 bytes

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)
        self.wfile.flush()

    def log_message(self, *a):
        pass


class _BurstThenTrickleHandler(http.server.BaseHTTPRequestHandler):
    """Sends a large burst fast, then trickles below the floor for ever.

    This is what a connection that dies mid-transfer looks like, and it is the shape
    that distinguishes a floor anchored at the last known-good point from one
    averaged over the whole transfer: the burst keeps a whole-transfer average above
    the floor indefinitely, so an unanchored floor never notices the transfer stopped
    making progress. It trickles rather than going silent on purpose -- a truly idle
    socket is caught by wget's own --read-timeout, which would mask the difference.
    """
    protocol_version = 'HTTP/1.1'
    burst = 512 * 1024

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '100000000')
        self.end_headers()
        try:
            self.wfile.write(b'x' * self.burst)
            self.wfile.flush()
            while True:
                time.sleep(1.0)
                self.wfile.write(b'x')
                self.wfile.flush()
        except Exception:
            pass

    def log_message(self, *a):
        pass


class _DribbleServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


@contextlib.contextmanager
def burst_then_trickle_server():
    srv = _DribbleServer(('127.0.0.1', 0), _BurstThenTrickleHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{srv.server_address[1]}'
    finally:
        srv.shutdown()
        srv.server_close()


@contextlib.contextmanager
def slow_finite_server():
    srv = _DribbleServer(('127.0.0.1', 0), _SlowFiniteHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{srv.server_address[1]}', len(_SlowFiniteHandler.body)
    finally:
        srv.shutdown()
        srv.server_close()


@contextlib.contextmanager
def dribble_server(bytes_per_tick, interval):
    handler = type('H', (_DribbleHandler,),
                   {'chunk': bytes_per_tick, 'interval': interval})
    srv = _DribbleServer(('127.0.0.1', 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{srv.server_address[1]}'
    finally:
        srv.shutdown()
        srv.server_close()


# Real values are minutes; the tests need seconds. Rewriting a COPY keeps the
# production defaults free of test-only env knobs.
# A stall now needs TWO consecutive sub-floor windows (one is write buffering), so
# detection takes ~2 * NET_STALL_SECONDS. The total cap is set well clear of that so
# the two bounds are distinguishable by elapsed time rather than only by message.
FAST_BOUNDS = {
    'NET_CONNECT_TIMEOUT': 5,
    'NET_STALL_SECONDS': 2,
    'NET_STALL_BYTES_PER_SEC': 1024,
    'NET_DOWNLOAD_MAX_TIME': 14,
}


def install_sh_with_fast_bounds(work: Path, name: str) -> Path:
    """install.sh with the NET_* constants shrunk to seconds.

    Each substitution must match EXACTLY once. Without that check a renamed
    constant would silently leave the real 600s value in place and the bound tests
    would pass by timing out somewhere else entirely.
    """
    text = INSTALL_SCRIPT.read_text()
    for const, value in FAST_BOUNDS.items():
        pattern = rf'^{const}=\d+$'
        text, n = re.subn(pattern, f'{const}={value}', text, flags=re.M)
        assert n == 1, f'expected exactly one {const} assignment to rewrite, got {n}'
    path = work / name
    path.write_text(text)
    return path


def run_download_bound(script: Path, work: Path, tag: str, url: str, tool: str):
    """Drive download() directly against $url with only `tool` on PATH.

    Sourcing the script would run main(), so this appends a call instead -- the
    REQ-INST-4 structure (everything in functions, one main "$@" at the end) is
    what makes that possible.
    """
    tool_path = shutil.which(tool)
    assert tool_path, f'{tool} is required for this test'
    shim = _shim_dir(work, f'bound-{tag}')
    if not (shim / tool).exists():
        (shim / tool).symlink_to(tool_path)
    # Everything run_bounded and download_failed shell out to. `kill` is a bash
    # builtin and needs no link.
    for helper in ('date', 'sleep', 'wc', 'tr'):
        real = shutil.which(helper)
        assert real, f'{helper} is required to exercise the download bounds'
        if not (shim / helper).exists():
            (shim / helper).symlink_to(real)

    driver = work / f'driver-{tag}.sh'
    driver.write_text(
        script.read_text().replace('\nmain "$@"\n', '\n')
        + f'\nset -euo pipefail\n'
        + f'download {shlex.quote(url)} {shlex.quote(str(work / ("dl-" + tag + ".bin")))}\n')
    started = time.monotonic()
    # PATH is the shim ALONE. This is what makes the tool selection real: with the
    # host PATH appended, download() found the system curl and took the curl branch
    # even when this test meant to exercise wget, so the wget bound was never
    # actually executed. Same hermetic rule as stub_env above.
    res = subprocess.run(['bash', str(driver)],
                         env={'PATH': str(shim), 'HOME': str(work), 'TMPDIR': str(work)},
                         capture_output=True, text=True, timeout=180)
    return res, time.monotonic() - started


# Worst case for each branch, from the flags download() actually passes. curl
# retries (--retry 3 = up to 4 attempts, with 1+2+4s of backoff) and its native
# --max-time is PER ATTEMPT -- measured: `--retry 3 --max-time 3` against an
# above-floor endless stream took 19s, not 3s. run_bounded is what bounds the whole
# operation, so the ceiling asserted below is the WATCHDOG's, and the retry
# arithmetic only sets how much slack to allow before it fires.
WATCHDOG_TICK_SLACK = 4  # 1s poll + one TERM/teardown tick, for the STALL ceiling

# The stall ceiling above doubles as the LOWER bound that distinguishes "the floor
# fired" from "the deadline fired", so it is deliberately kept tight. The DEADLINE
# ceiling gets its own, wider slack, sized from run_bounded's real worst case rather
# than from the typical one:
#
#   1s poll granularity + the bounded grace loop (5 x 1s, install.sh:535) + teardown
#
# That matters because these assertions are about to run on GitHub-hosted macOS
# runners (T12), which are shared and throttled. MEASURED on this host with the
# suite's own scenarios, idle and under 16 CPU burners on 4 cpus:
#
#            idle        under 4x oversubscription
#   curl     15.4s       14.4s
#   wget     15.3s       17.0s      <-- 1.0s under an 18s ceiling
#
# wget's 17.0s left one second of headroom, so the old `total_s + 4` was genuinely
# too tight: a busier runner fails it while the watchdog is working perfectly, the
# test gets marked flaky, and the bound stops being checked at all. The bounds
# themselves are WALL-CLOCK (`date +%s`), so a slow host does not move them -- only
# the teardown term grows, which is what this slack covers.
#
# ENFORCEMENT, not a precise window, is the requirement: a non-zero exit plus the
# named bound is what proves the watchdog fired, and the endless server means the
# transfer can never end on its own. This ceiling only catches "it ran far past the
# bound", so widening it to the true worst case costs no detection power -- confirmed
# by re-running the mutation sweep against the wider ceiling.
WATCHDOG_KILL_SLACK = 8  # 1s poll + 5s bounded grace loop + teardown


def assert_download_bounds_enforced(ctx, tool):
    """REQ-INST-7 BY EXECUTION: both bounds, against a server that dribbles forever.

    The structural test above only reads flags. This drives a REAL downloader
    against a real endless server, which is the only thing that proves the two
    branches make the SAME promise rather than asserting they do. Both branches run
    the identical assertions; that symmetry IS the requirement.

    Each branch failed differently before run_bounded, and each was measured:
      wget -- no throughput floor and no total-duration flag exist. --read-timeout
        bounds one IDLE read, so real wget 1.25.0 on a 2 B/s trickle was still
        running after 25s having moved 50 bytes.
      curl -- states both bounds natively, but --max-time is PER ATTEMPT:
        `--retry 3 --max-time 3` against an above-floor endless stream took 19s,
        not 3s, so the real ceiling was 4x the constant.

    The curl assertions are on TIME, not on which mechanism named the bound: curl's
    native --speed-limit and --max-time sit at the same values as the watchdog's, so
    the two race and either may win. The wget assertions additionally require the
    watchdog to NAME the bound, because wget has no native equivalent of either and
    nothing else could have fired.
    """
    if not shutil.which(tool):
        raise Skip(f'{tool} is not installed, so its download bounds cannot be executed')

    work = ctx['work']
    script = install_sh_with_fast_bounds(work, f'install-fast-{tool}.sh')
    stall_s = FAST_BOUNDS['NET_STALL_SECONDS']
    total_s = FAST_BOUNDS['NET_DOWNLOAD_MAX_TIME']
    floor = FAST_BOUNDS['NET_STALL_BYTES_PER_SEC']
    ceiling = total_s + WATCHDOG_KILL_SLACK
    # Two consecutive sub-floor windows, plus a tick of slack.
    stall_ceiling = 2 * stall_s + WATCHDOG_TICK_SLACK

    # (a) STALL: 2 B/s against a 1024 B/s floor. The watchdog's absolute deadline
    #     would eventually stop this too, so asserting "it died" proves nothing
    #     about the floor. The floor is what makes it die EARLY, and on a host where
    #     the deadline is 10 minutes that difference is the whole point.
    with dribble_server(1, 0.5) as base:
        res, elapsed = run_download_bound(script, work, f'stall-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: a 2 B/s trickle must fail:\n{out}'
    assert 'download failed' in out, f'{tool}: no diagnosis:\n{out}'
    # A throughput floor fired, not the deadline -- asserted by TIME rather than by
    # message, because curl has a native --speed-limit at the same value and either
    # its floor or the watchdog's may win the race. Which one is immaterial; that a
    # sub-floor transfer dies well before the total cap is the requirement.
    assert elapsed < stall_ceiling, (
        f'{tool}: sub-floor trickle ran {elapsed:.1f}s, past the {stall_ceiling}s a '
        f'{floor} B/s floor allows -- nothing enforced it and it was heading for the '
        f'{total_s}s deadline instead:\n{out}')
    if tool == 'wget':
        # wget has NO native throughput floor, so here the watchdog is the only
        # thing that can have fired and it must say so.
        assert 'stalled below' in out, (
            f'wget: the stall was not named, so the floor did not fire '
            f'(elapsed {elapsed:.1f}s):\n{out}')

    # (b) DEADLINE: 4096 B/s, comfortably ABOVE the floor, so the stall check must
    #     never fire -- but the stream never ends. This is the case a watchdog
    #     implementing only the stall half would hang on forever, and the case
    #     curl's per-attempt --max-time multiplied by four.
    with dribble_server(4096, 1.0) as base:
        res, elapsed = run_download_bound(script, work, f'total-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: an endless stream must fail:\n{out}'
    assert 'download failed' in out, f'{tool}: no diagnosis:\n{out}'
    assert elapsed < ceiling, (
        f'{tool}: above-floor endless stream ran {elapsed:.1f}s, past the {total_s}s '
        f'cap -- NET_DOWNLOAD_MAX_TIME is not bounding the whole operation:\n{out}')
    assert elapsed > stall_ceiling, (
        f'{tool}: died in {elapsed:.1f}s on an ABOVE-floor stream, inside the window '
        f'a stall would be detected in -- the floor is firing on a transfer that is '
        f'meeting it, which is what write buffering causes when a single window is '
        f'trusted:\n{out}')
    if tool == 'wget':
        # wget has no total-duration flag at all, so only the watchdog can have
        # stopped this, and naming the bound is the difference between a diagnosis
        # and "download failed" for a transfer that was still moving data.
        assert 'total download limit' in out, (
            f'wget: the TOTAL cap was not named (elapsed {elapsed:.1f}s):\n{out}')

    # (c) BURSTY but healthy: bursts of 4 x floor x gap bytes every `gap` seconds,
    #     i.e. a 4096 B/s average against a 1024 B/s floor, delivered in bursts
    #     further apart than the watchdog's 1s poll. Seconds of zero file growth are
    #     guaranteed by construction while the transfer comfortably meets the floor --
    #     so this is the shape that a per-window floor gets wrong, and the reason the
    #     floor is an average since the last known-good anchor instead.
    #
    #     THE GAP USED TO BE PINNED AT NET_STALL_SECONDS and had to be moved off it,
    #     for a reason that only a real Mac could show. download() passes wget
    #     --read-timeout=NET_STALL_SECONDS, so a gap EQUAL to that value races
    #     wget's own idle-read timeout. On Linux the data arrives just in time; on
    #     both macOS runners it does not, and the run measured there is worth
    #     stating exactly, because it is also a finding about run_bounded:
    #
    #       wget: 'Read error at byte 8192 (Operation timed out). Retrying.'
    #       -> wget RESTARTS from byte 0 and TRUNCATES the output file (no -c)
    #       -> run_bounded's anchor_bytes is still 8192 while file_bytes drops to 0,
    #          so (current - anchor_bytes) is NEGATIVE for the whole horizon
    #       -> 'stalled below 1024 bytes/sec for 4s' on a transfer that was actively
    #          re-downloading.
    #
    #     That cascade is NOT a fixture artifact: any wget retry mid-transfer -- a
    #     read timeout, a dropped connection, a flaky link -- truncates the file and
    #     can make the watchdog report a stall as the cause. It is filed as a
    #     divergence for whoever owns REQ-INST-7 and wants a test of its own (an
    #     explicit mid-transfer-retry case); it is deliberately not fixed here,
    #     because install.sh is not this task's file to change.
    #
    #     So the gap is now 0.75 * NET_STALL_SECONDS: still LONGER than the 1s poll,
    #     which is what guarantees the zero-growth windows this case exists to
    #     produce, and comfortably SHORTER than wget's read timeout, so the shape
    #     under test is the watchdog's anchored floor and not a race with wget's
    #     retry logic. The burst scales with it to hold the average at 4x the floor.
    #     The narrower claim is stated plainly: gaps of 0.5s, 1s and 1.5s are carried
    #     to the deadline on Linux and darwin; a gap at or above the read timeout is
    #     the retry cascade above, and at the production 60s such a gap is a stall by
    #     any useful definition anyway.
    bursty_gap = 0.75 * FAST_BOUNDS['NET_STALL_SECONDS']
    bursty_chunk = int(4 * FAST_BOUNDS['NET_STALL_BYTES_PER_SEC'] * bursty_gap)
    with dribble_server(bursty_chunk, bursty_gap) as base:
        res, elapsed = run_download_bound(script, work, f'bursty-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: an endless bursty stream must still fail:\n{out}'
    assert 'stalled below' not in out, (
        f'{tool}: bursty delivery at 4x the floor was called a STALL after '
        f'{elapsed:.1f}s -- a single zero-growth window is write buffering, not a '
        f'stall:\n{out}')
    assert elapsed > stall_ceiling, (
        f'{tool}: bursty above-floor stream died in {elapsed:.1f}s, inside the stall '
        f'detection window:\n{out}')
    assert elapsed < ceiling, (
        f'{tool}: bursty stream ran {elapsed:.1f}s, past the {total_s}s cap:\n{out}')

    if tool != 'wget':
        # curl has a native throughput floor at the same value, and it fires on the
        # trickle below before the watchdog's anchor can be the deciding mechanism.
        # The case is therefore only observable on the branch that has no native
        # floor -- which is also the branch that needs the watchdog.
        return

    # (d) FAST, THEN DEAD: a 512 KB burst followed by a 1 B/s trickle for ever. This
    #     is a connection that dies mid-transfer, and it is the case that proves the
    #     floor is anchored at the last KNOWN-GOOD point rather than averaged over the
    #     whole transfer. An unanchored average keeps the burst in the numerator for
    #     ever, so it never notices the transfer stopped progressing and lets it run to
    #     the total cap instead -- a 10-minute hang in production where the floor
    #     should have caught it in 60 seconds. It trickles rather than going silent
    #     because a truly idle socket is caught by wget's own --read-timeout, which
    #     would hide the difference.
    with burst_then_trickle_server() as base:
        res, elapsed = run_download_bound(script, work, f'burstdead-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: a transfer that died must fail:\n{out}'
    assert 'stalled below' in out, (
        f'{tool}: a 512 KB burst followed by 1 B/s was not called a stall after '
        f'{elapsed:.1f}s -- the floor is being averaged over the whole transfer '
        f'instead of since the last known-good point:\n{out}')
    assert elapsed < stall_ceiling, (
        f'{tool}: took {elapsed:.1f}s to notice a dead transfer; the floor should '
        f'catch it within {stall_ceiling}s, not at the {total_s}s cap:\n{out}')


def test_download_floor_does_not_punish_small_files(ctx):
    """The floor is a STALL detector, not a minimum-average-rate requirement.

    SHA256SUMS is a couple of hundred bytes. If the watchdog demanded
    NET_STALL_BYTES_PER_SEC * NET_STALL_SECONDS bytes per window unconditionally,
    every small file would be aborted for the crime of being small, and the message
    would blame a stall for a transfer that was fine.

    This also pins the liveness re-check after the poll sleep. Without it, a
    transfer that finishes during a tick that crosses a window boundary is judged on
    the bytes of its own final fraction of a second, finds them under the floor, and
    reports a stall for a download that had already SUCCEEDED -- a wrong cause on a
    working install.
    """
    tool = 'curl' if shutil.which('curl') else 'wget'
    if not shutil.which(tool):
        raise Skip('neither curl nor wget is installed')

    work = ctx['work']
    script = install_sh_with_fast_bounds(work, f'install-fast-small-{tool}.sh')
    with slow_finite_server() as (base, size):
        res, elapsed = run_download_bound(script, work, f'small-{tool}',
                                          f'{base}/SHA256SUMS', tool)
    out = res.stdout + res.stderr
    assert res.returncode == 0, (
        f'{tool}: a {size}-byte file must download successfully even though its '
        f'average rate is far under the floor:\n{out}')
    assert 'stalled below' not in out, f'{tool}: false stall on a small file:\n{out}'
    assert 'download failed' not in out, f'{tool}: small file reported failure:\n{out}'
    landed = (work / f'dl-small-{tool}.bin')
    assert landed.is_file() and landed.stat().st_size == size, (
        f'{tool}: expected {size} bytes at {landed}, got '
        f'{landed.stat().st_size if landed.is_file() else "no file"}')


def test_download_bounds_curl(ctx):
    """curl states both bounds natively (--speed-limit/--speed-time, --max-time).
    Executed anyway, so the two branches are held to ONE assertion."""
    assert_download_bounds_enforced(ctx, 'curl')


def test_download_bounds_wget(ctx):
    """wget can express NEITHER bound as a flag, so download_with_wget enforces
    both. This is the blocking REQ-INST-7 defect's regression test."""
    assert_download_bounds_enforced(ctx, 'wget')


# --- REQ-INST-17: a TRUNCATING retry is progress, not a stall -------------------
# Found by T12 in a live macos-15-intel CI log: wget, which download() calls
# without -c, hit a read timeout, logged "Read error at byte 8192/100000000 ...
# Retrying", and RESTARTED FROM ZERO -- truncating the output file. run_bounded
# then compared the shrunken size against a high-water anchor, so
# (current - anchor_bytes) went negative, the re-anchor branch became UNREACHABLE,
# anchor_time never advanced, and the stall fired with certainty at the horizon on
# a transfer that was actively recovering.
#
# These drive run_bounded DIRECTLY rather than through a real downloader. The
# defect is in the WATCHDOG, not in wget's retry policy: any truncation reproduces
# it, the file size is the only signal run_bounded actually reads, and a synthetic
# writer makes the timing deterministic instead of racing a retry. It also keeps
# the case covered on hosts with no wget, where the real wget bound SKIPs.


def run_bounded_scenario(script: Path, work: Path, tag: str, body: str,
                         timeout: int = 180):
    """Run `run_bounded <out> bash -c <body> <out>` from a fast-bounds copy of
    the script and report what the watchdog decided.

    Deliberately no `set -e`: run_bounded returning non-zero is the OUTCOME under
    test, not a reason to abandon the driver before it prints which bound fired.
    """
    out = work / f'rb-{tag}.bin'
    shim = _shim_dir(work, f'rb-{tag}')
    for helper in ('date', 'sleep', 'wc', 'tr', 'bash'):
        real = shutil.which(helper)
        assert real, f'{helper} is required to exercise run_bounded'
        if not (shim / helper).exists():
            (shim / helper).symlink_to(real)
    driver = work / f'driver-rb-{tag}.sh'
    driver.write_text(
        script.read_text().replace('\nmain "$@"\n', '\n')
        + '\nset -uo pipefail\n'
        + f'run_bounded {shlex.quote(str(out))} bash -c {shlex.quote(body)} '
          f'writer {shlex.quote(str(out))}\n'
        + 'rc=$?\n'
        + 'printf "RC=%s\\n" "$rc"\n'
        + 'printf "BOUND_ERROR=%s\\n" "$bound_error"\n')
    started = time.monotonic()
    res = subprocess.run(['bash', str(driver)],
                         env={'PATH': str(shim), 'HOME': str(work), 'TMPDIR': str(work)},
                         capture_output=True, text=True, timeout=timeout)
    elapsed = time.monotonic() - started
    rc = next((int(line.split('=', 1)[1])
               for line in res.stdout.splitlines() if line.startswith('RC=')), None)
    bound_error = next((line.split('=', 1)[1]
                        for line in res.stdout.splitlines()
                        if line.startswith('BOUND_ERROR=')), '')
    assert rc is not None, f'driver never reported RC:\n{res.stdout}\n{res.stderr}'
    return rc, bound_error, elapsed, res


# Builds a LARGE high-water mark, truncates once, then recovers at a healthy rate
# that stays BELOW that mark for longer than the stall horizon. The large mark is
# the whole point: a retry EARLY in a transfer re-passes its old size immediately
# and hides the defect, while a retry LATE in one -- the expensive case, and the
# one a user on a lossy link actually hits -- cannot.
_TRUNCATE_THEN_RECOVER = r"""
out="$1"
chunk="$(printf '%01024d' 0)"
# Phase 1: 512 KiB fast, so the high-water anchor sits far above what follows.
i=0
while [ "$i" -lt 512 ]; do printf '%s' "$chunk" >> "$out"; i=$(( i + 1 )); done
sleep 1
# The truncating retry: exactly what wget without -c does to its output file.
: > "$out"
# Phase 2: recover at 8192 B/s -- EIGHT TIMES the 1024 B/s floor -- for 8s, twice
# the compressed horizon. It never regains 512 KiB, so a high-water anchor stays
# unmoved the entire time while real bytes land every single second.
i=0
while [ "$i" -lt 8 ]; do
  j=0
  while [ "$j" -lt 8 ]; do printf '%s' "$chunk" >> "$out"; j=$(( j + 1 )); done
  sleep 1
  i=$(( i + 1 ))
done
"""

_TRUNCATE_FOREVER_TIGHT = r"""
out="$1"
chunk="$(printf '%01024d' 0)"
# FUTILE, and the ordinary shape of one: every cycle throws away what it just
# fetched and re-fetches the SAME 8 KiB, so the file keeps returning to the same
# size and a 1s poll almost never observes growth.
while :; do
  : > "$out"
  i=0
  while [ "$i" -lt 8 ]; do printf '%s' "$chunk" >> "$out"; i=$(( i + 1 )); done
  sleep 0.5
done
"""

_TRUNCATE_FOREVER_TROUGH = r"""
out="$1"
chunk="$(printf '%01024d' 0)"
# Also futile, but it sits EMPTY for long enough that polls land in the trough and
# credit roughly one chunk per cycle -- about 2730 B/s, comfortably over the floor.
while :; do
  : > "$out"
  sleep 1.5
  i=0
  while [ "$i" -lt 8 ]; do printf '%s' "$chunk" >> "$out"; i=$(( i + 1 )); done
  sleep 1.5
done
"""


def test_download_futile_truncate_loop_still_hits_the_floor(ctx):
    """REQ-INST-17: the fix must not COST the guarantee run_bounded's header has
    always claimed -- that a downloader retrying and truncating without ever
    getting anywhere is caught.

    It does not, and this is the case that proves it. A loop re-fetching the same
    chunk keeps returning to the same size, so consecutive polls observe no
    growth, nothing is credited, and the floor fires just as it did before. The
    recovering transfer in the test above is distinguished precisely because it
    grows past every previous poll.
    """
    work = ctx['work']
    script = install_sh_with_fast_bounds(work, 'install-futile-tight.sh')
    rc, bound_error, elapsed, res = run_bounded_scenario(
        script, work, 'futile-tight', _TRUNCATE_FOREVER_TIGHT, timeout=180)
    assert rc != 0, 'a futile truncate/refetch loop must not run unbounded'
    assert f'stalled below {FAST_BOUNDS["NET_STALL_BYTES_PER_SEC"]} bytes/sec' in bound_error, (
        'the floor must still catch a futile loop that never delivers observable '
        f'growth; got {bound_error!r}')
    # It was the FLOOR and not the total limit: the floor fires at the horizon,
    # well before NET_DOWNLOAD_MAX_TIME.
    assert elapsed < FAST_BOUNDS['NET_DOWNLOAD_MAX_TIME'] + WATCHDOG_KILL_SLACK, (
        f'took {elapsed:.1f}s, which does not distinguish the floor from the total limit')


def test_download_futile_loop_with_a_trough_is_bounded_by_the_total_limit(ctx):
    """REQ-INST-17: the other shape, and the honest limit of the floor.

    A futile loop that stays empty long enough for polls to catch its trough DOES
    credit real delivered bytes -- measured at about 2730 B/s, over the floor. The
    floor therefore cannot catch it, and it must not pretend to: a transfer moving
    bytes is not 'stalled below N bytes/sec', and saying so would assert a cause
    the evidence does not support (the REQ-INST-6 defect class). NET_DOWNLOAD_MAX_TIME
    is what bounds it, and the message must name that instead.
    """
    work = ctx['work']
    script = install_sh_with_fast_bounds(work, 'install-futile-trough.sh')
    rc, bound_error, elapsed, res = run_bounded_scenario(
        script, work, 'futile-trough', _TRUNCATE_FOREVER_TROUGH, timeout=180)
    assert rc != 0, 'a futile truncate/refetch loop must not run unbounded'
    total = FAST_BOUNDS['NET_DOWNLOAD_MAX_TIME']
    assert f'exceeded the {total}s total download limit' in bound_error, (
        f'this shape must be bounded by the TOTAL limit, got {bound_error!r}')
    assert 'stalled' not in bound_error, (
        'a loop delivering ~2730 B/s is not stalled; claiming so would name a cause '
        f'the evidence does not support: {bound_error!r}')
    assert elapsed >= total, (
        f'ended after {elapsed:.1f}s, too early for the {total}s total limit to have '
        f'been the bound that fired ({bound_error!r})')


def test_download_truncating_retry_is_not_a_stall(ctx):
    """REQ-INST-17. The regression test for the defect itself.

    A transfer that truncates once and then recovers well above the floor must be
    carried to completion. Before the fix it was killed at the horizon with a
    stall diagnosis -- deterministically, on every host, however fast the recovery
    was actually going.
    """
    work = ctx['work']
    script = install_sh_with_fast_bounds(work, 'install-trunc.sh')
    rc, bound_error, elapsed, res = run_bounded_scenario(
        script, work, 'trunc', _TRUNCATE_THEN_RECOVER, timeout=120)
    assert rc == 0, (
        'a transfer that truncated once and then recovered at 8x the floor was '
        f'killed by the watchdog (rc={rc}, bound_error={bound_error!r}). That is '
        'REQ-INST-17: a recovering transfer must not be diagnosed as a stall.\n'
        f'stdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    assert bound_error == '', f'no bound should have fired, got {bound_error!r}'
    # The recovery really did stay under the old high-water mark, so the case the
    # test claims to cover is the case it ran. 8 * 8 KiB < 512 KiB.
    final = (work / 'rb-trunc.bin').stat().st_size
    assert final < 512 * 1024, (
        f'the recovery reached {final} bytes and passed the 512 KiB high-water '
        'mark, so this run did not exercise the defect at all')


def test_download_failure_names_url_and_tmpdir(ctx):
    """A failed download must name WHICH url failed -- the installer fetches
    several -- and, when the target sits under TMPDIR, say that a small tmpfs can
    be the real cause, because mktemp -d puts a multi-MB tarball there."""
    work = ctx['work']
    home = work / 'home-dlfail'
    runtime = work / 'run-dlfail'
    tmpdir = work / 'tmp-dlfail'
    for d in (home, runtime, tmpdir):
        d.mkdir(parents=True, exist_ok=True)
    missing = work / 'no-such-mirror'
    env = sandbox_install_env(home, runtime)
    env['TMPDIR'] = str(tmpdir)
    # --hub keeps this off the GitHub API entirely; the url is a local file://
    # that does not exist, so the failure is real and nothing leaves the machine.
    res = install_run_shielded(['bash', str(INSTALL_SCRIPT), '--hub', f'file://{missing}'],
                               env, timeout=90)
    assert res.returncode != 0, f'a missing mirror must fail:\n{res.stdout}'
    out = res.stdout + res.stderr
    assert 'download failed: ' in out, f'failure did not name the url:\n{out}'
    assert f'file://{missing}/heimdall-local-' in out, f'url missing from report:\n{out}'
    assert str(tmpdir) in out and 'tmpfs' in out, f'TMPDIR hint missing:\n{out}'
    assert 'set TMPDIR to a larger filesystem' in out, f'no remediation:\n{out}'


def test_hub_and_version_paths_never_call_the_api(ctx):
    """--hub and --version must not newly reach api.github.com. Proven by giving
    them a PATH whose only downloader is a stub that FAILS every api.github.com
    request: if either path consulted the API, resolution would report one of the
    five diagnoses instead of using the tag it was handed."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-noapi', tool='curl', latest_status='403',
                         list_status='403')
    res = run_installer(shim, work, 'ver-noapi', '--dry-run', '--version', 'v0.4.2')
    assert res.returncode == 0, f'--version dry run failed:\n{res.stderr}'
    assert_only_message(res, ['release: v0.4.2', 'releases/download/v0.4.2/'],
                        ALL_RESOLVE_MSGS)

    res = run_installer(shim, work, 'hub-noapi', '--dry-run', '--hub',
                        'file:///nonexistent-mirror')
    assert res.returncode == 0, f'--hub dry run failed:\n{res.stderr}'
    assert_only_message(res, ['file:///nonexistent-mirror/heimdall-local-'],
                        ALL_RESOLVE_MSGS + ['api.github.com'])


def test_install_sh_full_run_service_lifecycle(ctx):
    """Prove the service-file lifecycle by real runs against a local file://
    --hub mirror, with HOME sandboxed so nothing touches the real
    ~/.config/systemd/user or ~/.config/heimdall."""
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')
    base = ctx['work'] / 'fullrun'
    home = base / 'home'
    (base / 'xdg-runtime').mkdir(parents=True)

    res, tarball = package_tarball(base, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)
    # A second mirror serving the same tarball under a different URL, so a
    # re-run with a different --hub produces a differing unit.
    hub2 = make_hub_mirror(base / 'second', tarball, target)

    # sandbox_install_env, NOT a hand-rolled dict: this test used to build its
    # own env, which meant it was the ONE sandboxed run without the socat stub
    # on PATH. REQ-INST-14 makes a missing socat fatal, so it passed only on a
    # host that happened to have socat installed and failed on every host that
    # did not -- both macOS runners AND ubuntu-24.04 in CI, where this was the
    # only failure. A test whose result depends on a package the host may or may
    # not ship is not a gate. The helper also blanks DBUS_SESSION_BUS_ADDRESS,
    # which this env was missing.
    env = sandbox_install_env(home, base / 'xdg-runtime')

    def install_run(hub_url, *extra):
        # Shielded, NOT given --force-service: runs 1-3 below assert the DEFAULT
        # service-file path (no backup on fresh, no-op when identical, exactly one
        # .bak-<UTC> when differing), and --force-service suppresses backups --
        # it would delete the only coverage those three runs exist for.
        return install_run_shielded(
            ['bash', str(INSTALL_SCRIPT), '--hub', hub_url, *extra],
            env, cwd=ROOT, timeout=120)

    if target.startswith('linux'):
        service = home / '.config/systemd/user/heimdall-bridge.service'
        hub_in_unit = f'--hub "{hub}"'
        hub2_in_unit = f'--hub "{hub2}"'
    else:
        service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
        hub_in_unit = f'<string>{hub}</string>'
        hub2_in_unit = f'<string>{hub2}</string>'

    # Run 1: fresh install. No prior unit exists, so no backup may be created.
    res = install_run(hub)
    assert res.returncode == 0, f'first install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    assert service.is_file(), 'service file not written'
    assert hub_in_unit in service.read_text(), 'explicit --hub must be baked into the unit'
    assert 'wrote service file' in res.stdout
    assert not list(service.parent.glob('*.bak-*')), 'no backup may be created when no prior unit exists'
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert (home / '.local/bin' / binary).is_file(), f'{binary} not installed'
    assert '.local/bin' in (home / '.bashrc').read_text(), 'PATH line missing from sandbox .bashrc'

    # Run 2: identical re-run. The unit is unchanged, so the write must be
    # skipped with a message and no backup created.
    res = install_run(hub)
    assert res.returncode == 0, f'identical re-run failed:\n{res.stderr}'
    assert 'already up to date; leaving it untouched' in res.stdout
    assert not list(service.parent.glob('*.bak-*')), 'identical unit must not produce a backup'

    # Run 3: differing unit (different mirror URL). The old file must be backed
    # up to <service>.bak-<UTC timestamp> and the new unit installed.
    res = install_run(hub2)
    assert res.returncode == 0, f'differing re-run failed:\n{res.stderr}'
    assert 'saved a copy to' in res.stdout
    backups = sorted(service.parent.glob('*.bak-*'))
    assert len(backups) == 1, f'expected exactly one backup, got {[b.name for b in backups]}'
    assert re.fullmatch(r'.*\.bak-\d{8}T\d{6}Z', backups[0].name), (
        f'backup name must carry a UTC timestamp: {backups[0].name}')
    assert hub_in_unit in backups[0].read_text(), 'backup must hold the PREVIOUS unit contents'
    assert hub2_in_unit in service.read_text(), 'new unit must carry the new hub'

    # Run 4: --force-service overwrites a differing unit with NO new backup.
    res = install_run(hub, '--force-service')
    assert res.returncode == 0, f'--force-service run failed:\n{res.stderr}'
    assert 'saved a copy to' not in res.stdout, '--force-service must not back up'
    assert 'wrote service file' in res.stdout
    assert hub_in_unit in service.read_text()
    backups = sorted(service.parent.glob('*.bak-*'))
    assert len(backups) == 1, '--force-service must not add a backup'


def test_install_sh_sudo_paths(ctx):
    """Prove the sudo handling with unshare -r (current user mapped to uid 0 in
    a private user namespace): SUDO_USER resolves the service owner; root
    without a resolvable SUDO_USER refuses to run. Dry runs only — zero writes."""
    if not sys.platform.startswith('linux'):
        raise Skip(f'sudo-path test needs Linux user namespaces (got {sys.platform})')
    need_tool('unshare')
    probe = run(['unshare', '-r', 'id', '-u'])
    if probe.returncode != 0 or probe.stdout.strip() != '0':
        raise Skip('unprivileged user namespaces unavailable (unshare -r id -u != 0)')

    import pwd
    entry = pwd.getpwuid(os.getuid())
    base = ctx['work'] / 'sudo'
    root_home = base / 'root-home'
    root_home.mkdir(parents=True)

    def sudo_run(extra_env):
        env = {**os.environ, 'HOME': str(root_home), **extra_env}
        return subprocess.run(
            ['unshare', '-r', 'env', 'bash', str(INSTALL_SCRIPT),
             '--dry-run', '--version', 'v0.1.0'],
            cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=60)

    # Resolvable SUDO_USER: binaries global, service file + PATH lines planned
    # for that user's home.
    res = sudo_run({'SUDO_USER': entry.pw_name})
    assert res.returncode == 0, f'sudo dry run failed:\n{res.stderr}'
    sudo_line = (f'sudo detected: binaries go to /usr/local/bin; the service '
                 f'file and PATH lines will be written for user {entry.pw_name} '
                 f'(home: {entry.pw_dir})')
    assert sudo_line in res.stdout
    assert f'would write service file {entry.pw_dir}/.config/systemd/user/heimdall-bridge.service' in res.stdout
    assert 'refusing to run as root' not in res.stderr
    assert not any(root_home.iterdir()), 'dry run must not write anything'

    # BLOCKER 1 regression (reviewer repro shape): root's PATH normally
    # contains /usr/local/bin. The sudo branch must decide from the target
    # user's rc files, never from the process PATH, so the "already on PATH"
    # short-circuit must not fire and the target rc files must be named.
    res = sudo_run({'SUDO_USER': entry.pw_name,
                    'PATH': f'/usr/local/bin:{os.environ["PATH"]}'})
    assert res.returncode == 0, f'sudo dry run with /usr/local/bin on PATH failed:\n{res.stderr}'
    assert 'is already on PATH' not in res.stdout, (
        "sudo branch must not decide PATH wiring from the installer's (root's) PATH")
    assert (f"would add /usr/local/bin to PATH in {entry.pw_dir}/.bashrc / .zshrc as needed "
            f"(idempotent; decided from {entry.pw_name}'s rc files, not the sudo PATH)"
            ) in res.stdout, 'sudo dry run must plan the rc write for the target user'

    # SUDO_USER unset or root: refuse with the no-sudo instruction.
    for bad in ('', 'root'):
        res = sudo_run({'SUDO_USER': bad})
        assert res.returncode != 0, f'SUDO_USER={bad!r} must refuse to run as root'
        assert 'refusing to run as root' in res.stderr
        assert 'Re-run without sudo' in res.stderr, 'refusal must tell the user to re-run without sudo'
    assert not any(root_home.iterdir()), 'refused runs must not write anything'


def need_userns_mount():
    """Real uid-0 runs need unshare -rm plus the ability to mount inside it.
    The mounts are namespace-private: nothing is visible outside the process."""
    if not sys.platform.startswith('linux'):
        raise Skip(f'user-namespace tests need Linux (got {sys.platform})')
    need_tool('unshare')
    probe_dir = tempfile.mkdtemp(prefix='heimdall-usrns-probe-')
    probe = run(['unshare', '-rm', 'sh', '-c',
                 f'mount -t tmpfs tmpfs {probe_dir} && umount {probe_dir}'])
    os.rmdir(probe_dir)
    if probe.returncode != 0:
        raise Skip('user namespaces with mount support unavailable (unshare -rm mount failed)')


def sudo_ns_fixture(base: Path):
    """Shared fixture for uid-0 real runs: a stub release whose entries are
    uid-0 (tar runs under unshare -r so the apparent owner is root), a file://
    --hub mirror, and an empty sandbox home. Returns (hub, fake_home, user)."""
    import pwd
    entry = pwd.getpwuid(os.getuid())
    fake_home = base / 'fakehome'
    mirror = base / 'mirror'
    (fake_home / 'bin').mkdir(parents=True)
    mirror.mkdir(parents=True)
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        stub = fake_home / 'bin' / binary
        stub.write_text('#!/bin/sh\n')
        stub.chmod(0o755)
    asset = mirror / 'heimdall-local-linux-amd64.tar.gz'
    res = run(['unshare', '-r', 'tar', '-czf', str(asset), '-C', str(fake_home), 'bin'])
    assert res.returncode == 0, f'uid-0 stub tarball creation failed:\n{res.stderr}'
    (mirror / 'SHA256SUMS').write_text(f'{sha256_of(asset)}  {asset.name}\n')
    return f'file://{mirror}', fake_home, entry


def sudo_ns_install(base: Path, hub: str, entry, path_prefix: str, *extra: str,
                    pre: str = '', host_path: str = None, socat_stub: bool = True):
    """Run install.sh as uid 0 inside a private user+mount namespace:
    a tmpfs over /usr keeps /usr/local/bin writes contained, and the sandbox
    home is bind-mounted over the SUDO_USER's real home (ns-private) so the
    script's getent-based home resolution finds it. The script itself is
    copied under /tmp first — the bind mount shadows the real home, and the
    checkout lives there."""
    script_copy = base / 'install.sh'
    shutil.copy(INSTALL_SCRIPT, script_copy)
    # The tmpfs over /usr is namespace-PRIVATE, so /usr/local/bin starts empty
    # in every invocation — a second call cannot see the first call's binaries.
    # `pre` runs inside the namespace, which is how an uninstall run gets
    # something at /usr/local/bin to act on.
    # REQ-INST-23: hide the machine's own system-wide unit dirs too. These runs
    # perform a REAL install, so on a host that HAS a system-managed
    # heimdall-bridge.service install.sh would (correctly) refuse and these tests
    # would measure the guard instead of the sudo branch they exist for. Already
    # inside unshare -rm, so this is a mount and nothing more; no extra namespace.
    hide_units = ''.join(
        f'if [ -d {shlex.quote(d)} ]; then {ns_tool("mount")} -t tmpfs tmpfs {shlex.quote(d)}; fi && '
        for d in system_unit_dirs_from_install_sh())
    # REQ-INST-22: install.sh resolves socat with `command -v`, so its FATAL
    # preflight depends on PATH -- and every mount above hides part of the
    # filesystem from this namespace (the tmpfs over /usr, plus one per unit dir
    # from hide_units). A distro /usr/bin/socat would therefore be hidden, while
    # this host's /nix/store one is not. That difference, not anything the test
    # asserts, is what decided the outcome. So probe AFTER every mount and BEFORE
    # install.sh runs, and fail loudly naming the PATH searched. Note ns_tool()
    # shields T21's OWN tools by absolute path but socat is not among them
    # (NS_TOOLS), which is exactly the gap this closes.
    socat_probe = ('command -v socat >/dev/null 2>&1 || '
                   '{ echo "SOCAT_UNREACHABLE_IN_NS: PATH=$PATH" >&2; exit 97; }')
    inner = (hide_units
             + 'mount -t tmpfs tmpfs /usr && '
             'mkdir -p /usr/local/bin && '
             + socat_probe + ' && '
             + f'mount --bind {base / "fakehome"} {entry.pw_dir} && '
             + (f'{pre} && ' if pre else '')
             + f'cd {base} && bash {script_copy} --hub {hub}'
             + (' ' + ' '.join(extra) if extra else ''))
    root_home = base / 'root-home'
    runtime = base / 'root-runtime'
    root_home.mkdir(exist_ok=True)
    runtime.mkdir(exist_ok=True)
    # Build on the SHARED sandbox env rather than an inline one (REQ-INST-22),
    # so the socat stub and the XDG_RUNTIME_DIR/DBUS blanking that keeps
    # `systemctl --user` off the live session bus come from one place — the same
    # fix D-4 got for test_install_sh_full_run_service_lifecycle.
    #
    # Two overrides are re-asserted because they ARE the sudo path, and
    # sandbox_install_env deliberately sets both the other way for its own
    # (non-sudo) runs: SUDO_USER names the target user the install must resolve,
    # and HOME is root's, not the sandbox's.
    #
    # sandbox_install_env also blanks SHELL, which is safe here and NOT an
    # oversight: in its uid-0 branch install.sh reads the target user's shell
    # from `getent passwd` into service_shell, and both path_candidates() and
    # wire_path() prefer "${service_shell:-${SHELL:-}}", so the blanked SHELL is
    # never consulted on this path.
    env = {**sandbox_install_env(root_home, runtime),
           'HOME': str(root_home),
           'SUDO_USER': entry.pw_name}
    # path_prefix stays FIRST: a caller's stub (e.g. the failing `chown` in
    # test_install_sh_sudo_chown_failure_warns) has to outrank the real tool, and
    # losing that order would quietly stop those tests testing anything.
    # host_path and socat_stub exist for ONE caller: the REQ-INST-27 binding test
    # below, which must be able to run this exact code path with socat absent to
    # prove the probe and its assertion still bite. They are deliberately NOT a
    # production escape hatch -- install.sh is untouched by them, and every other
    # caller gets the defaults, which are the behaviour REQ-INST-22 established.
    stub = [str(socat_stub_dir(root_home))] if socat_stub else []
    tail = os.environ['PATH'] if host_path is None else host_path
    # Empty components are filtered: '' in a PATH means the CURRENT DIRECTORY to
    # every resolver, which is not something these runs should ever search, and
    # a caller passing an empty path_prefix or host_path would silently add one.
    env['PATH'] = os.pathsep.join(
        [p for p in [path_prefix, *stub, '/usr/local/bin', tail] if p])
    res = subprocess.run(['unshare', '-rm', 'env', 'bash', '-c', inner],
                         cwd=str(base), env=env, capture_output=True, text=True,
                         timeout=120)
    assert 'SOCAT_UNREACHABLE_IN_NS' not in res.stderr, (
        'the socat stub is not reachable inside the namespace, so this test would '
        'have exercised install.sh\'s socat preflight instead of the sudo install '
        f'it claims to test:\n{res.stderr}')
    return res


def test_install_sh_sudo_path_write(ctx):
    """BLOCKER 1 end-to-end: a real uid-0 install whose (root) PATH contains
    /usr/local/bin must still write the PATH export into the TARGET user's rc
    file — the decision comes from the rc files, not the process PATH."""
    need_userns_mount()
    base = ctx['work'] / 'sudo-write'
    base.mkdir(parents=True)
    hub, fake_home, entry = sudo_ns_fixture(base)

    res = sudo_ns_install(base, hub, entry, path_prefix='/nonexistent-stub')
    assert res.returncode == 0, f'uid-0 install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'

    service = fake_home / '.config/systemd/user/heimdall-bridge.service'
    assert service.is_file(), 'service file not written into the SUDO_USER home'
    unit = service.read_text()
    assert 'ExecStart="/usr/local/bin/ham-bridge"' in unit
    assert f'--hub "{hub}"' in unit
    expected_rc = '.zshrc' if entry.pw_shell.endswith('zsh') else '.bashrc'
    rc = fake_home / expected_rc
    assert rc.is_file(), f'target user rc file {expected_rc} not written despite root PATH containing /usr/local/bin'
    assert 'export PATH="/usr/local/bin:$PATH"' in rc.read_text()
    # The install announced the target user, not a silent /root fallback.
    assert f'Registered for user: {entry.pw_name}' in res.stdout


def test_install_sh_sudo_chown_failure_warns(ctx):
    """BLOCKER 2: when chown fails (stubbed on PATH ahead of the real one),
    the install stays non-fatal but every failed target is warned with the
    path, intended owner, and remediation — no silent root-owned leftovers."""
    need_userns_mount()
    base = ctx['work'] / 'sudo-chown'
    base.mkdir(parents=True)
    stub_dir = base / 'stub'
    stub_dir.mkdir(parents=True)
    chown_stub = stub_dir / 'chown'
    chown_stub.write_text('#!/bin/sh\nexit 1\n')
    chown_stub.chmod(0o755)
    hub, fake_home, entry = sudo_ns_fixture(base)

    res = sudo_ns_install(base, hub, entry, path_prefix=str(stub_dir))
    assert res.returncode == 0, (
        f'install must stay non-fatal when chown fails:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    service = fake_home / '.config/systemd/user/heimdall-bridge.service'
    assert service.is_file(), 'service file must still be written'

    service_path = f'{entry.pw_dir}/.config/systemd/user/heimdall-bridge.service'
    warnings = [line for line in res.stderr.splitlines() if 'could not chown' in line]
    assert warnings, 'failed chowns must produce warnings, not silence'
    assert len(warnings) >= 3, (
        f'expected warnings for rc file, config dirs and service file; got {len(warnings)}:\n{res.stderr}')
    assert any(service_path in line for line in warnings), (
        f'the service file chown failure must be named:\n{res.stderr}')
    for line in warnings:
        assert f"to {entry.pw_name}" in line, f'warning must name the intended owner: {line!r}'
        assert f"'chown {entry.pw_name}: " in line, f'warning must give the chown remediation: {line!r}'
        assert 'before starting the service' in line, f'warning must say when to remediate: {line!r}'


# --- REQ-INST-19: the live-HOME tripwire -------------------------------------
#
# assert_bridge_isolated() above is a PRE-condition, and it only covers routes
# that need the session bus. Writing
# ~/.config/systemd/user/heimdall-bridge.service needs no bus at all, and a
# user unit takes precedence over /etc/systemd/user — so a stray write there
# SILENTLY SHADOWS a system-managed bridge, invisibly, until someone restarts
# it and gets the wrong one. Installing into ~/.local/bin and editing a live rc
# file are the same class of damage.
#
# So this is the matching POST-condition: after every test, prove the real home
# is byte-for-byte what it was before. It states nothing about what the home
# SHOULD contain — it only requires that this suite did not change it, which is
# what makes it safe on a host whose home is already dirty.


def live_home() -> Path:
    """The invoking user's REAL home, from the password database — NOT $HOME.

    This distinction is the whole guard, so do not "simplify" it to
    Path.home() or os.environ['HOME']. Every test that could escape its
    sandbox is a test that set HOME to that sandbox. Reading $HOME here would
    compare the sandbox against itself and pass no matter what had just been
    written to the user's actual home directory.
    """
    import pwd
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def live_homes() -> list:
    """Every real home this suite could damage, live_home() plus SUDO_USER's.

    Under sudo the two DIFFER and the second one is the dangerous one:
    install.sh resolves its target home from SUDO_USER (scripts/install.sh,
    service_home) and writes the service file and rc lines THERE, while
    getpwuid(geteuid()) says /root. Watching only the latter would leave the
    exact outage path of REQ-INST-19 unguarded whenever the suite runs under
    sudo.
    """
    import pwd
    homes = [live_home()]
    sudo_user = os.environ.get('SUDO_USER', '')
    if sudo_user:
        try:
            extra = Path(pwd.getpwnam(sudo_user).pw_dir)
        except KeyError:
            extra = None
        if extra is not None and extra not in homes:
            homes.append(extra)
    return homes


# Every rc file install.sh can append a PATH line to, home-relative. This is a
# copy of path_candidates() in scripts/install.sh (its union branch, plus the
# per-shell branches), and test_tripwire_covers_every_rc_install_sh_writes below
# RE-DERIVES it from that function and fails if the two ever drift. Keeping the
# literals AND checking them beats either alone: the list stays readable here,
# and a new rc file added to install.sh cannot silently go unwatched.
TRIPWIRE_RC_FILES = (
    '.bashrc',
    '.bash_profile',
    '.zshrc',
    '.zprofile',
    '.profile',
    '.config/fish/config.fish',
)


def live_home_tripwire_paths() -> list:
    """Every path in the real home that install.sh is capable of creating,
    modifying or deleting: the four binaries, both platforms' service files,
    every rc file path_candidates() can name, and its config directory.

    Directories are watched as well as files -- ~/.local/bin,
    ~/.config/systemd/user, ~/Library/LaunchAgents and ~/.config/fish -- so a
    write under a name not listed here still shows up as a changed entry list
    rather than slipping through. That is what catches the timestamped
    $service_file.bak-<date> backups, whose names cannot be enumerated, and a
    fish config.fish created from nothing in a directory install.sh mkdir -p's
    itself.
    """
    paths = []
    for home in live_homes():
        binaries = ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl')
        paths.append(home / '.local' / 'bin')
        paths += [home / '.local' / 'bin' / name for name in binaries]
        paths += [
            home / '.config' / 'systemd' / 'user',
            home / '.config' / 'systemd' / 'user' / 'heimdall-bridge.service',
            home / 'Library' / 'LaunchAgents',
            home / 'Library' / 'LaunchAgents' / 'works.earendil.heimdall-bridge.plist',
            home / '.config' / 'heimdall',
            home / '.config' / 'fish',
        ]
        paths += [home / rc for rc in TRIPWIRE_RC_FILES]
    return paths


# Hash anything small enough that a same-size, same-mtime edit is conceivable
# (rc files, unit files, the checksum record). Multi-megabyte binaries fall
# back to identity+size+mtime, which a reinstall cannot leave untouched.
TRIPWIRE_HASH_MAX_BYTES = 1 << 20


def _tripwire_state(path: Path) -> str:
    """A change-detecting fingerprint of one path. Never raises: an
    unreadable path records WHY, and that reason is itself part of the
    fingerprint, so a permission flip is a change too."""
    try:
        st = path.lstat()
    except FileNotFoundError:
        return 'absent'
    except OSError as exc:
        return f'unreadable ({exc.__class__.__name__})'
    if stat.S_ISLNK(st.st_mode):
        try:
            return f'symlink -> {os.readlink(path)}'
        except OSError as exc:
            return f'symlink unreadable ({exc.__class__.__name__})'
    if stat.S_ISDIR(st.st_mode):
        try:
            entries = sorted(entry.name for entry in path.iterdir())
        except OSError as exc:
            return f'dir unreadable ({exc.__class__.__name__})'
        # Mode is part of the fingerprint: take_ownership() chmods the config
        # dir, and an entry list alone would not notice.
        return (f'dir mode={stat.S_IMODE(st.st_mode):o} entries=['
                + ','.join(entries) + ']')
    if st.st_size <= TRIPWIRE_HASH_MAX_BYTES:
        try:
            return f'file mode={stat.S_IMODE(st.st_mode):o} sha256={sha256_of(path)}'
        except OSError as exc:
            return f'file unreadable ({exc.__class__.__name__})'
    return (f'file mode={stat.S_IMODE(st.st_mode):o} size={st.st_size} '
            f'mtime_ns={st.st_mtime_ns} ino={st.st_ino}')


def snapshot_live_home() -> dict:
    return {str(path): _tripwire_state(path) for path in live_home_tripwire_paths()}


def assert_live_home_untouched(before: dict, label: str) -> None:
    """REQ-INST-19. HARD post-condition after EVERY test.

    If this fires, a test wrote into the real user's home. Do NOT relax it and
    do NOT add an allowlist entry to get a green run: on 2026-09-27 exactly
    these paths, written outside a sandbox, left this host unable to restart
    its own production bridge for six hours, because the user unit shadowed
    the system one and nothing failed until the next restart.

    Fix the test to sandbox its HOME instead. If a change here is genuinely
    intended, it belongs in a deliberate, reviewed commit and not in a test run.
    """
    after = snapshot_live_home()
    changed = [(path, before[path], after[path])
               for path in before if before[path] != after[path]]
    if not changed:
        return
    detail = '\n'.join(f'  {path}\n    before: {was}\n    after:  {now}'
                        for path, was, now in changed)
    homes = ', '.join(str(home) for home in live_homes())
    raise AssertionError(
        f'{label!r} MODIFIED THE LIVE HOME at {homes} — a test must never '
        f'write outside its sandbox (REQ-INST-19):\n{detail}\n'
        "Sandbox that test's HOME. Do not weaken this guard.\n"
        'If the changed path is under ~/.local/bin or ~/.config/heimdall, rule out '
        'an UNRELATED process writing there concurrently before blaming the test '
        'named above: those directories are shared with whatever else is running.')


def dry_run_env(ctx) -> dict:
    """Env for the --dry-run / --help / syntax invocations: a sandbox HOME.

    --dry-run writes nothing today, and these tests only read its plan. That
    is precisely why the live HOME was inherited here for so long. But it
    meant the only thing standing between this suite and the real
    ~/.local/bin was install.sh honouring --dry-run on every one of its paths,
    and the dry-run plan these tests assert on was being computed against the
    developer's actual home — which is visible in the output, where it printed
    the real ~/.local/bin. The tripwire above CATCHES such a write; this
    removes the reason it could happen. Keep both.
    """
    home = ctx['work'] / 'dry-run-home'
    home.mkdir(parents=True, exist_ok=True)
    return {**os.environ, 'HOME': str(home)}



def test_tripwire_covers_every_rc_install_sh_writes(ctx):
    """REQ-INST-19: the watch list must not DESYNC from install.sh.

    The first version of this guard watched four rc files while
    path_candidates() named six, so ~/.zprofile and ~/.config/fish/config.fish
    were written by install.sh and unwatched -- and the miss was invisible,
    because a list of literals looks complete. This re-derives the set from the
    function itself, so the next rc file added to install.sh fails here instead
    of quietly going unguarded.

    Deliberately checks the WATCH LIST and not just TRIPWIRE_RC_FILES: what
    matters is that the paths actually end up watched for every home.
    """
    body = re.search(r'^path_candidates\(\) \{(.*?)^\}', INSTALL_SCRIPT.read_text(),
                     flags=re.S | re.M)
    assert body, 'path_candidates() not found in install.sh — this test must be updated, not deleted'
    named = set(re.findall(r'\$service_home/(\S+?)"', body.group(1)))
    assert named, f'no $service_home rc paths parsed out of path_candidates():\n{body.group(1)}'
    # Sanity: the parse found the shapes we expect, so a regex that silently
    # matched nothing useful cannot make this test vacuous.
    assert '.zshrc' in named and '.config/fish/config.fish' in named, (
        f'path_candidates() parse looks wrong, got {sorted(named)}')

    watched = {str(path) for path in live_home_tripwire_paths()}
    for home in live_homes():
        missing = sorted(rc for rc in named if str(home / rc) not in watched)
        assert not missing, (
            f'install.sh writes these rc files under {home} and the REQ-INST-19 '
            f'tripwire does not watch them: {missing}. Add them to '
            'TRIPWIRE_RC_FILES — a test that escapes its sandbox could rewrite '
            'them with nothing noticing.')


def sandbox_install_env(home: Path, runtime: Path) -> dict:
    """Env for a hermetic install run: sandbox HOME, no sudo, unknown shell.
    SHELL='' makes path_candidates() take its union branch, which is the
    historical ~/.bashrc-first behaviour.

    XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are NOT cosmetic here: they
    are what keeps `systemctl --user stop heimdall-bridge` inside install.sh's
    uninstall path away from the live session bus. See
    assert_bridge_isolated() — and do not drop either override.
    """
    # REQ-INST-14: socat is a FATAL preflight now, so a sandboxed run needs one
    # on PATH. Prepending our own stub rather than relying on the host's socat
    # keeps the suite deterministic on machines that do not have it -- notably
    # the macOS runners, where neither outcome is guaranteed.
    home.mkdir(parents=True, exist_ok=True)
    socat_dir = socat_stub_dir(home)
    return {**os.environ,
            'PATH': f'{socat_dir}{os.pathsep}' + os.environ.get('PATH', ''),
            'HOME': str(home),
            'XDG_CONFIG_HOME': '',
            'XDG_RUNTIME_DIR': str(runtime),
            # Belt and braces: XDG_RUNTIME_DIR alone is what systemd actually
            # resolves the user bus from today, but blanking the bus address too
            # means the isolation does not depend on that implementation detail.
            'DBUS_SESSION_BUS_ADDRESS': '',
            'SUDO_USER': '',
            'SHELL': ''}


def assert_bridge_isolated(env: dict, work: Path) -> None:
    """REQ-INST-13. HARD precondition before ANY non-dry-run --uninstall.

    install.sh's uninstall path runs `systemctl --user stop heimdall-bridge`,
    and that is the RIGHT command for real users — the unit name in
    scripts/install.sh is the same one that runs the bridge on a developer's own
    machine, which on this project's hosts is the process supervising the
    agents themselves. A test that reached the live user bus would stop the
    bridge, and every agent with it, in the middle of the run.

    So the isolation is the harness's responsibility: production code must not
    grow a test-only escape hatch. This fails (never skips) unless BOTH hold:

      1. env['XDG_RUNTIME_DIR'] is inside the test work dir — in particular it
         must not be /run/user/<uid>, the live session bus; and
      2. `systemctl --user is-active heimdall-bridge`, run with THIS env,
         cannot reach a bus at all. Any verdict it returns — active OR
         inactive — means the env resolves to a real session, and the
         destructive call must not be made.

    If this ever fires, STOP and report it. Do not weaken it to get a green
    run: a firing guard means the suite was about to kill the fleet.
    """
    runtime = env.get('XDG_RUNTIME_DIR') or ''
    assert runtime, (
        'XDG_RUNTIME_DIR must point at a sandbox dir before a real --uninstall; '
        'an empty value lets systemd fall back to the live session bus')
    resolved = Path(runtime).resolve()
    assert not str(resolved).startswith('/run/user/'), (
        f'XDG_RUNTIME_DIR={resolved} is a LIVE session bus directory — a real '
        '--uninstall with this env would stop the running heimdall-bridge')
    work_resolved = work.resolve()
    assert resolved == work_resolved or work_resolved in resolved.parents, (
        f'XDG_RUNTIME_DIR={resolved} is outside the test work dir '
        f'{work_resolved}; refusing to run a destructive --uninstall against a '
        'session this suite does not own')
    assert env.get('DBUS_SESSION_BUS_ADDRESS', '') == '', (
        'DBUS_SESSION_BUS_ADDRESS must be blanked before a real --uninstall; '
        'an inherited address is a second route to the live bus')

    # DARWIN: the checks above are systemd-shaped and do not cover this host at
    # all. do_uninstall's macOS branch runs
    # `launchctl bootout gui/<uid>/works.earendil.heimdall-bridge`, and launchctl
    # addresses the per-user launchd DOMAIN -- a sandboxed HOME does not scope
    # it, and there is no XDG_RUNTIME_DIR equivalent to point somewhere
    # harmless. So on darwin the isolation can only be a PRECONDITION: if that
    # label is loaded, a real --uninstall in this suite would stop the live
    # bridge, exactly the REQ-INST-13 accident this guard exists to prevent.
    # Reached for the first time when this file started running on the macOS
    # runners (.github/workflows/install-sh.yml); on a CI runner nothing is
    # loaded, but on a developer's own Mac it very much is.
    if platform.system() == 'Darwin':
        if shutil.which('launchctl') is None:
            return  # nothing can be booted out on a host without launchctl
        label = f'gui/{os.getuid()}/works.earendil.heimdall-bridge'
        loaded = subprocess.run(['launchctl', 'print', label],
                                capture_output=True, text=True, timeout=30)
        assert loaded.returncode != 0, (
            f'{label} is LOADED in this user launchd domain, and a real '
            '--uninstall here would bootout the running heimdall-bridge. A '
            'sandboxed HOME does not scope launchctl, so this is a hard '
            'precondition: unload it by hand before running this suite. Do not '
            'weaken this guard.')
        return

    if shutil.which('systemctl') is None:
        return  # nothing can be stopped on a host without systemctl
    probe = subprocess.run(
        ['systemctl', '--user', 'is-active', 'heimdall-bridge'],
        env=env, capture_output=True, text=True, timeout=30)
    combined = f'{probe.stdout}\n{probe.stderr}'
    unreachable = any(marker in combined for marker in (
        'Failed to connect',
        'Failed to get D-Bus connection',
        'No such file or directory',
        'Permission denied',
    ))
    assert unreachable, (
        '`systemctl --user is-active heimdall-bridge` REACHED a user bus with '
        f'the test env (exit={probe.returncode}, stdout={probe.stdout.strip()!r}) — '
        'this env resolves to a live systemd session, so a real --uninstall '
        'would stop the bridge that runs the agents. Aborting BEFORE the '
        'destructive call; fix the sandbox env, do not weaken this guard.')


def test_install_sh_readonly_rc_nonfatal(ctx):
    """REQ-INST-5 (the user's explicit requirement): an rc file that cannot be
    written must NOT fail the install. The original bug aborted under
    `set -euo pipefail` at the bare `printf >> "$rc"` — after the binaries were
    installed but BEFORE the service file was written — so exit 0 alone does
    not prove the fix: the service file must be shown to exist afterwards.

    Runs the real installer against a local file:// --hub mirror with a
    chmod 0444 rc file, then repeats with the mode restored to prove the
    three outcomes (could-not-write / added / already present) and that the
    grep -Fqx duplicate guard survives the failure boundary."""
    if os.getuid() == 0:
        raise Skip('running as root: root bypasses the 0444 mode bits, so a '
                   'read-only rc file cannot be simulated with chmod')
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')

    base = ctx['work'] / 'readonly-rc'
    home = base / 'home'
    home.mkdir(parents=True)
    (base / 'xdg-runtime').mkdir(parents=True)
    res, tarball = package_tarball(base, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)
    env = sandbox_install_env(home, base / 'xdg-runtime')

    rc = home / '.bashrc'
    original = '# user rc\nexport EDITOR=vi\n'
    rc.write_text(original)
    rc.chmod(0o444)

    def install_run(*extra):
        return install_run_shielded(
            ['bash', str(INSTALL_SCRIPT), '--hub', hub, *extra],
            env, cwd=ROOT, timeout=120)

    if target.startswith('linux'):
        service = home / '.config/systemd/user/heimdall-bridge.service'
    else:
        service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
    install_dir = home / '.local/bin'

    # --- run 1: read-only rc. Must be non-fatal AND must reach the unit. -----
    res = install_run()
    assert res.returncode == 0, (
        'a read-only rc file must NOT fail the install:\n'
        f'stdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    assert service.is_file(), (
        'the install aborted between the binaries and the service file — the '
        'exact REQ-INST-5 bug; exit 0 is not enough on its own')
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert (install_dir / binary).is_file(), f'{binary} not installed'
    assert rc.read_text() == original, 'an unwritable rc file must be left byte-identical'

    # The failure is named, with the file, and reads as a warning not a fatal.
    assert any('could not write' in line and '.bashrc' in line
               for line in res.stderr.splitlines()), (
        f'the unwritable rc file must be named in a warning:\n{res.stderr}')

    # The printed snippet is copy-pasteable and covers all three shapes.
    out = res.stdout
    assert f'export PATH="{install_dir}:$PATH"' in out, 'plain export form missing from snippet'
    assert f'home.sessionPath = [ "{install_dir}" ];' in out, 'home-manager form missing from snippet'
    assert 'home.sessionVariables.PATH' in out, 'home-manager sessionVariables variant missing'
    # REQ-INST-28: the fish form is quoted too -- unquoted, fish reads a spaced
    # install dir as two arguments and adds neither.
    assert f'fish_add_path "{install_dir}"' in out, 'fish form missing from snippet'

    # The summary must read as a SUCCESS with one manual step left.
    assert 'the install SUCCEEDED' in out, (
        f'the final summary must not read like a failure:\n{out}')
    assert 'Only PATH still needs your action' in out

    # --- run 2: rc writable. Outcome must switch to "added". ----------------
    rc.chmod(0o644)
    res = install_run()
    assert res.returncode == 0, f'second install failed:\n{res.stderr}'
    assert f'added {install_dir} to PATH in {rc}' in res.stdout, (
        f'a writable rc file must report "added":\n{res.stdout}')
    assert 'the install SUCCEEDED' not in res.stdout, (
        'the PATH-needs-action note must not appear once the rc file was written')
    body = rc.read_text()
    assert body.startswith(original), 'the pre-existing rc content must be preserved'
    assert body.count('# Added by heimdall install.sh') == 1
    assert body.count(f'export PATH="{install_dir}:$PATH"') == 1

    # --- run 3: idempotency. The grep -Fqx guard must prevent a duplicate. ---
    res = install_run()
    assert res.returncode == 0, f'third install failed:\n{res.stderr}'
    assert f'{rc} already adds {install_dir} to PATH' in res.stdout, (
        f'a re-run must report "already adds":\n{res.stdout}')
    assert rc.read_text() == body, 'a re-run must not modify the rc file at all'
    assert rc.read_text().count(f'export PATH="{install_dir}:$PATH"') == 1, (
        'the duplicate guard must survive the read-only failure boundary')


def test_install_sh_uninstall(ctx):
    """REQ-INST-8/21: install and uninstall touch only installer-owned paths.
    Proves the dry run touches nothing, only marked PATH lines are removed, user
    state is kept, and a pre-existing openssl stays byte-identical even when an
    older release tarball contains a bundled openssl."""
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')

    base = ctx['work'] / 'uninstall'
    home = base / 'home'
    home.mkdir(parents=True)
    (base / 'xdg-runtime').mkdir(parents=True)
    res, tarball = package_tarball(base, with_openssl=True, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    names, _, _ = read_tarball(tarball)
    assert 'bin/openssl' in names, 'the old-release fixture must contain a bundled openssl'
    hub = make_hub_mirror(base, tarball, target)
    env = sandbox_install_env(home, base / 'xdg-runtime')

    rc = home / '.bashrc'
    # A decoy that looks like ours but is NOT under the marker, plus an
    # unrelated export. Neither may be touched.
    decoy = 'export PATH="/opt/other/bin:$PATH"\nexport EDITOR=vi\n'
    rc.write_text(decoy)

    install_dir = home / '.local/bin'
    install_dir.mkdir(parents=True)
    stranger = install_dir / 'openssl'
    stranger_bytes = b'#!/bin/sh\n# wrapper used by heimdall, not written by it\n'
    stranger.write_bytes(stranger_bytes)
    stranger.chmod(0o755)
    stranger_sha = sha256_of(stranger)
    sidecar = install_dir / '.heimdall-openssl.sha256'

    res = install_run_shielded(['bash', str(INSTALL_SCRIPT), '--hub', hub],
                               env, cwd=ROOT, timeout=120)
    assert res.returncode == 0, f'install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    assert stranger.read_bytes() == stranger_bytes, 'install replaced the pre-existing openssl'
    assert sha256_of(stranger) == stranger_sha, 'install changed the pre-existing openssl checksum'
    assert not sidecar.exists(), 'install created retired openssl provenance state'

    if target.startswith('linux'):
        service = home / '.config/systemd/user/heimdall-bridge.service'
    else:
        service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
    assert service.is_file()

    # A unit backup (RULING 2: recovery artifact, must survive and be named).
    backup = service.parent / f'{service.name}.bak-20260101T000000Z'
    backup.write_text('[Unit]\n# hand-tuned unit\n')
    # Enrollment state: must survive.
    enrollment = home / '.config/heimdall/config.toml'
    enrollment.parent.mkdir(parents=True, exist_ok=True)
    enrollment.write_text('# bridge token lives here\n')

    binaries = ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl')
    rc_after_install = rc.read_text()

    def uninstall_run(*extra):
        return subprocess.run(['bash', str(INSTALL_SCRIPT), '--uninstall', *extra],
                              cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)

    # --- dry run: reports everything, changes nothing (and needs no network) --
    res = uninstall_run('--dry-run')
    assert res.returncode == 0, f'--uninstall --dry-run failed:\n{res.stderr}'
    out = res.stdout
    for binary in binaries:
        assert f'would remove {install_dir / binary}' in out, f'dry run must list {binary}'
    assert f'would remove service file {service}' in out
    assert f'would remove the heimdall PATH lines from {rc}' in out
    assert 'dry run: nothing was removed' in out
    for binary in binaries:
        assert (install_dir / binary).is_file(), 'dry run must not remove a binary'
    assert service.is_file(), 'dry run must not remove the service file'
    assert rc.read_text() == rc_after_install, 'dry run must not touch the rc file'
    assert stranger.read_bytes() == stranger_bytes, 'dry-run uninstall changed the pre-existing openssl'
    assert sha256_of(stranger) == stranger_sha, 'dry-run uninstall changed the openssl checksum'
    assert not sidecar.exists(), 'dry-run uninstall created retired openssl provenance state'
    assert backup.is_file() and enrollment.is_file()

    # --- real uninstall ------------------------------------------------------
    # REQ-INST-13: the unit name install.sh stops is the SAME one running this
    # agent, so prove the env cannot reach the live session bus before making
    # the destructive call. This is not ceremony — without it a stray
    # XDG_RUNTIME_DIR here stops the bridge and every agent on the host.
    assert_bridge_isolated(env, ctx['work'])
    res = uninstall_run()
    assert res.returncode == 0, f'--uninstall failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    out = res.stdout
    for binary in binaries:
        assert not (install_dir / binary).exists(), f'{binary} not removed'
        assert f'removed {install_dir / binary}' in out
    assert not service.exists(), 'service file not removed'

    # Only the marked lines went; the decoys are intact.
    body = rc.read_text()
    assert '# Added by heimdall install.sh' not in body, 'installer marker not removed'
    assert f'export PATH="{install_dir}:$PATH"' not in body, 'installer PATH line not removed'
    assert 'export PATH="/opt/other/bin:$PATH"' in body, 'an unrelated PATH export must survive'
    assert 'export EDITOR=vi' in body, 'unrelated rc content must survive'

    # Kept state, each reported with the path to remove by hand where applicable.
    assert stranger.read_bytes() == stranger_bytes, 'uninstall changed the pre-existing openssl'
    assert sha256_of(stranger) == stranger_sha, 'uninstall changed the openssl checksum'
    assert not sidecar.exists(), 'uninstall created retired openssl provenance state'
    assert str(stranger) not in out, 'uninstall must not inspect or report a path it no longer owns'
    assert backup.is_file(), 'unit backups are recovery artifacts and must be kept'
    assert f'kept service file backup {backup}' in out, 'the kept backup must be named'
    assert f'rm -f {service}.bak-*' in out, 'the backup glob must be given for manual removal'
    assert enrollment.is_file(), 'enrollment state must never be removed'
    assert 'kept enrollment state at' in out and str(home / '.config/heimdall') in out
    assert f'rm -rf {home / ".config/heimdall"}' in out, (
        'the enrollment path must be given for manual removal')
    assert 'uninstall complete' in out


def test_uninstall_guard_detects_live_session(ctx):
    """REQ-INST-13: the guard that stands between this suite and the live
    bridge must itself be proven, or it is ceremony. install.sh's uninstall
    path runs `systemctl --user stop heimdall-bridge` — the same unit name that
    supervises the agents on a developer host — so assert_bridge_isolated()
    has to FIRE on a live-session env, not merely pass on a sandbox one.

    Read-only throughout: the strongest thing done here is
    `systemctl --user is-active`, never a stop."""
    base = ctx['work'] / 'isolation-guard'
    home = base / 'home'
    runtime = base / 'xdg-runtime'
    home.mkdir(parents=True)
    runtime.mkdir(parents=True)

    # 1. The sandbox env the destructive tests actually use must be accepted.
    env = sandbox_install_env(home, runtime)
    assert_bridge_isolated(env, ctx['work'])

    def must_fire(bad_env, what):
        try:
            assert_bridge_isolated(bad_env, ctx['work'])
        except AssertionError:
            return
        raise AssertionError(
            f'assert_bridge_isolated did NOT fire for {what}; the guard is not '
            f'protecting the live bridge and a real --uninstall could stop it')

    # 2. The live session runtime dir — the exact value a leaked env would have.
    live = {**env, 'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}'}
    must_fire(live, 'XDG_RUNTIME_DIR=/run/user/<uid> (the live session bus)')

    # 3. An empty runtime dir lets systemd fall back to the real session.
    must_fire({**env, 'XDG_RUNTIME_DIR': ''}, 'an empty XDG_RUNTIME_DIR')

    # 4. A runtime dir outside the suite's work dir, even if not /run/user.
    must_fire({**env, 'XDG_RUNTIME_DIR': '/tmp'}, 'a runtime dir outside the test work dir')

    # 5. An inherited bus address is a second route to the live bus.
    must_fire({**env, 'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{os.getuid()}/bus'},
              'an inherited DBUS_SESSION_BUS_ADDRESS')

    # 6. And the substantive half: with the sandbox env, systemctl --user must
    # be unable to reach ANY bus. If this ever starts succeeding, the sandbox
    # no longer isolates and the guard's probe arm is what catches it.
    if shutil.which('systemctl') is not None:
        probe = subprocess.run(['systemctl', '--user', 'is-active', 'heimdall-bridge'],
                               env=env, capture_output=True, text=True, timeout=30)
        assert probe.stdout.strip() not in ('active', 'inactive', 'activating', 'failed'), (
            f'the sandbox env REACHED a user bus (stdout={probe.stdout.strip()!r}); '
            f'a real --uninstall under it could stop the running bridge')


def test_install_sh_sudo_uninstall_dry_run(ctx):
    """The sudo shape of --uninstall: paths must resolve under the TARGET
    user's home (not root's), and the service-stop command must be PRINTED for
    that user rather than run as root. Dry run only — nothing is removed."""
    need_userns_mount()
    base = ctx['work'] / 'sudo-uninstall'
    base.mkdir(parents=True)
    hub, fake_home, entry = sudo_ns_fixture(base)

    res = sudo_ns_install(base, hub, entry, path_prefix='/nonexistent-stub')
    assert res.returncode == 0, f'uid-0 install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    service = fake_home / '.config/systemd/user/heimdall-bridge.service'
    assert service.is_file(), 'service file not written into the SUDO_USER home'

    # The binaries must be planted inside the namespace: the tmpfs over /usr is
    # private to each unshare invocation, so the install above is not visible
    # here. The real removal is covered by test_install_sh_uninstall; what this
    # run proves is that the SUDO shape resolves the right paths.
    plant = ' && '.join(f'printf "#!/bin/sh\n" > /usr/local/bin/{b} '
                        for b in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'))
    res = sudo_ns_install(base, hub, entry, '/nonexistent-stub', '--uninstall', '--dry-run',
                          pre=plant)
    assert res.returncode == 0, (
        f'sudo --uninstall --dry-run failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    out = res.stdout
    # The stop command is printed for the target user, never run as root.
    assert f'service runs as {entry.pw_name}' in out, (
        f'the stop command must be printed for the target user:\n{out}')
    assert 'systemctl --user stop heimdall-bridge' in out
    # Paths come from the TARGET user's home, not /root.
    assert f'would remove service file {entry.pw_dir}/.config/systemd/user/heimdall-bridge.service' in out, (
        f'the service path must resolve under the SUDO_USER home:\n{out}')
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert f'would remove /usr/local/bin/{binary}' in out, (
            f'a sudo install lives in /usr/local/bin, so {binary} must be listed there:\n{out}')
    assert f'kept enrollment state at {entry.pw_dir}/.config/heimdall' in out
    assert 'dry run: nothing was removed' in out
    # Nothing was actually removed (the namespace mounts are gone, but the
    # bind-mounted sandbox home is a real directory we can still inspect).
    assert service.is_file(), 'a dry run must not remove the service file'


# ---- 4. heimdall CLI schemas --------------------------------------------------

def version_constants():
    proto = (ROOT / 'src' / 'contracts' / 'protocol.odin').read_text(encoding='utf-8')
    app_version = re.search(r'APP_VERSION :: (?:#config\(HAM_APP_VERSION, )?"([^"]*)"', proto)
    protocol_version = re.search(r'PROTOCOL_VERSION :: (\d+)', proto)
    assert app_version and protocol_version, 'could not parse src/contracts/protocol.odin'
    return app_version.group(1), protocol_version.group(1)


# ---- 4b. release portability gate (REQ-INST-16) -------------------------------
#
# The release tarballs target stock Linux/macOS hosts with no /nix/store. The
# bug this gate exists for: v0.3.2 shipped bin/ham-bridge as the 652-byte nix
# wrapProgram shell script (shebang AND exec target under /nix/store) and the
# other binaries as dynamically linked ELFs whose interpreter/RUNPATH point
# under /nix/store, so the whole bundle failed on any non-Nix machine.
#
# The gate builds the release-* flake attrs (static glibc for the Odin
# binaries, musl +crt-static for the Rust pty host -- see flake.nix), packages
# a tarball through the REAL packaging script, then:
#   1. scans every shipped binary for /nix/store references (ELF interpreter,
#      dynamic section, Mach-O dylibs/rpaths, script text), and
#   2. EXECUTES every Linux binary in a rootfs without /nix/store, via
#      scripts/release/storeless-exec.sh -- the same helper the release
#      workflow uses, which picks a mechanism (an empty imported docker image,
#      or a user-namespace chroot) by proving it can run a static control and
#      reject a dynamic one, and hard-fails rather than skipping when it can
#      prove neither, and
#   3. proves the execution half has teeth with a DIFFERENTIAL negative
#      control: the same mechanism must run a known-good static binary AND
#      fail a dynamic one. Asserting only that the dynamic binary failed is
#      what let the unrunnable `docker run ... scratch` invocation pass this
#      check vacuously on every docker host until v0.3.3 (REQ-INST-25).

RELEASE_BINARIES = ('ham-bridge', 'ham-ctl', 'ham-pty-host')
# Release attr per binary; the pty-host out dir name carries the musl target
# triple, so out dirs are matched to binaries by name prefix, not position.
RELEASE_ATTRS = {name: f'release-{name}' for name in RELEASE_BINARIES}
RELEASE_ATTRS_SKIP_REASON = 'nix is unavailable; REQ-INST-16 release build checks require Nix'


def release_attrs_or_skip(ctx):
    if 'release_outs' not in ctx:
        raise Skip(ctx.get('release_attrs_skip_reason', 'release attrs were not built'))
    return ctx['release_outs']


def build_release_attrs(ctx):
    if shutil.which('nix') is None:
        ctx['release_attrs_skip_reason'] = RELEASE_ATTRS_SKIP_REASON
        raise Skip(RELEASE_ATTRS_SKIP_REASON)
    res = run(['nix', 'build', *[f'.#{a}' for a in RELEASE_ATTRS.values()],
               '--print-out-paths', '--no-link'], cwd=ROOT, timeout=1200)
    assert res.returncode == 0, f'nix build of release-* attrs failed:\n{res.stderr}'
    outs = [l for l in res.stdout.splitlines() if l.startswith('/nix/store/')]
    assert len(outs) == len(RELEASE_BINARIES), (
        f'expected {len(RELEASE_BINARIES)} nix out paths, got: {outs!r}')
    release_outs = {}
    for out in outs:
        # Store dir names are <32-char hash>-<pname>-<version>; drop the hash.
        base = Path(out).name.split('-', 1)[1]
        for name in RELEASE_BINARIES:
            if base.startswith(name) or base.startswith(f'release-{name}'):
                release_outs[name] = Path(out)
                break
    missing = set(RELEASE_BINARIES) - set(release_outs)
    assert not missing, f'could not map nix outs to binaries, missing: {sorted(missing)}'
    for name, out in release_outs.items():
        binary = out / 'bin' / name
        assert binary.is_file(), f'{RELEASE_ATTRS[name]} produced no binary at {binary}'
    ctx['release_outs'] = release_outs


def test_release_build_skips_without_nix(ctx):
    original_path = os.environ.get('PATH')
    try:
        os.environ['PATH'] = ''
        skip_ctx = {}
        try:
            build_release_attrs(skip_ctx)
        except Skip as skipped:
            assert str(skipped) == RELEASE_ATTRS_SKIP_REASON
            assert skip_ctx['release_attrs_skip_reason'] == RELEASE_ATTRS_SKIP_REASON
        else:
            raise AssertionError('release build must skip when nix is unavailable')
    finally:
        if original_path is None:
            os.environ.pop('PATH', None)
        else:
            os.environ['PATH'] = original_path


def scan_binary_for_nix_references(binary: Path, name: str):
    """Static half of the gate: no shipped binary may reference /nix/store."""
    head = binary.read_bytes()[:4]
    assert head != b'#!', (
        f'{name} is a shell script, not a binary -- the v0.3.2 nix wrapper '
        'regression is back')
    if platform.system() == 'Linux':
        assert head == b'\x7fELF', f'{name} is not an ELF binary'
        res = run(['readelf', '-l', str(binary)])
        assert res.returncode == 0, f'readelf -l failed on {name}:\n{res.stderr}'
        assert 'Requesting program interpreter' not in res.stdout, (
            f'{name} has a program interpreter; release Linux binaries must be '
            f'fully static:\n{res.stdout}')
        res = run(['readelf', '-d', str(binary)])
        assert res.returncode == 0, f'readelf -d failed on {name}:\n{res.stderr}'
        assert '/nix/store' not in res.stdout, (
            f'{name} references /nix/store in its dynamic section:\n{res.stdout}')
    else:
        res = run(['llvm-objdump', '--macho', '--dylibs-used', str(binary)])
        out = res.stdout + res.stderr
        assert res.returncode == 0, f'llvm-objdump failed on {name}:\n{out}'
        assert '/nix/store' not in out, f'{name} links a nix-store dylib:\n{out}'
        res = run(['llvm-objdump', '--macho', '--rpaths', str(binary)])
        assert res.returncode == 0, f'llvm-objdump --rpaths failed on {name}:\n{res.stderr}'
        assert '/nix/store' not in res.stdout, (
            f'{name} has an rpath under /nix/store:\n{res.stdout}')


def test_release_binaries_have_no_nix_references(ctx):
    for name, out in release_attrs_or_skip(ctx).items():
        scan_binary_for_nix_references(out / 'bin' / name, name)


def test_release_gate_rejects_nix_wrapper(ctx):
    base = ctx['work'] / 'gate-nix-wrapper'
    base.mkdir()
    bridge = make_stub_input(base, 'bridge-out', ['ham-bridge'])
    (bridge / 'bin' / 'ham-bridge').write_text(
        '#!/nix/store/fake-shell/bin/bash\n'
        'exec /nix/store/fake-bridge/bin/ham-bridge "$@"\n')
    (bridge / 'bin' / 'ham-bridge').chmod(0o755)
    ctl = make_stub_input(base, 'ctl-out', ['ham-ctl'])
    pty_host = make_stub_input(base, 'pty-host-out', ['ham-pty-host'])
    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', base / 'dist',
               bridge, ctl, pty_host], cwd=ROOT)
    assert res.returncode != 0, 'the v0.3.2-style Nix wrapper must be rejected'
    assert 'script' in res.stderr and '/nix/store' in res.stderr, res.stderr


def test_release_gate_rejects_dynamic_elf(ctx):
    if platform.system() != 'Linux':
        raise Skip('dynamic ELF gate check requires Linux')
    need_tool('readelf')
    candidates = [Path(path) for path in (shutil.which('sh'), '/bin/sh', '/usr/bin/env') if path]
    dynamic_binary = None
    for candidate in candidates:
        if not candidate.is_file():
            continue
        probe = run(['readelf', '-l', candidate])
        if probe.returncode == 0 and 'Requesting program interpreter' in probe.stdout:
            dynamic_binary = candidate
            break
    assert dynamic_binary is not None, 'test host has no dynamic ELF control binary'

    base = ctx['work'] / 'gate-dynamic-elf'
    base.mkdir()
    bridge = make_stub_input(base, 'bridge-out', ['ham-bridge'])
    ctl = make_stub_input(base, 'ctl-out', ['ham-ctl'])
    shutil.copy(dynamic_binary, ctl / 'bin' / 'ham-ctl')
    pty_host = make_stub_input(base, 'pty-host-out', ['ham-pty-host'])
    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', base / 'dist',
               bridge, ctl, pty_host], cwd=ROOT)
    assert res.returncode != 0, 'a dynamic ELF must be rejected'
    assert 'has a program interpreter' in res.stderr, res.stderr


def test_release_gate_rejects_shared_libcurl(ctx):
    """A binary that needs a shared libcurl is named and rejected: libcurl, its
    TLS library and zlib must be linked statically (nix/libcurl.nix)."""
    if platform.system() != 'Linux':
        raise Skip('ELF gate check requires Linux')
    need_tool('readelf')
    control = None
    for candidate in (shutil.which('curl'), '/usr/bin/curl'):
        if candidate and Path(candidate).is_file():
            probe = run(['readelf', '-d', candidate])
            if probe.returncode == 0 and re.search(r'NEEDED.*\[libcurl\.so', probe.stdout):
                control = Path(candidate)
                break
    if control is None:
        raise Skip('no curl CLI linking a shared libcurl on this host')
    base = ctx['work'] / 'gate-shared-libcurl'
    base.mkdir()
    bridge = make_stub_input(base, 'bridge-out', ['ham-bridge'])
    shutil.copy(control, bridge / 'bin' / 'ham-bridge')
    ctl = make_stub_input(base, 'ctl-out', ['ham-ctl'])
    pty_host = make_stub_input(base, 'pty-host-out', ['ham-pty-host'])
    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', base / 'dist',
               bridge, ctl, pty_host], cwd=ROOT)
    assert res.returncode != 0, 'a binary needing a shared libcurl must be rejected'
    assert 'needs the shared library libcurl' in res.stderr, res.stderr


def storeless_mechanism(timeout=120):
    """Name of the validated clean-environment mechanism, or AssertionError.

    Delegates to scripts/release/storeless-exec.sh, the same helper the release
    workflow uses, so the CI gate and this suite cannot disagree about what a
    storeless execution is. The helper validates by EXECUTION -- it will only
    report a mechanism that ran a known-good static control and refused a
    dynamic one -- so a truthy answer here is evidence, not availability.

    Never raises Skip: a storeless check that quietly does nothing is the
    defect this gate exists to catch (REQ-INST-25).
    """
    res = run(['bash', str(STORELESS_SCRIPT), 'select'], timeout=timeout)
    assert res.returncode == 0, (
        'no storeless-execution mechanism could be validated on this host; '
        'refusing to skip the REQ-INST-16 execution gate:\n' + res.stderr)
    return res.stdout.strip()


def write_static_control(dest: Path):
    """Materialise the known-good static control binary from the shared helper.

    Taken from storeless-exec.sh rather than rebuilt here on purpose: a second
    copy of the control is a second thing that can rot out of step with the
    mechanism it is meant to validate.
    """
    res = run(['bash', str(STORELESS_SCRIPT), 'write-control', str(dest)], timeout=60)
    assert res.returncode == 0, f'could not write static control:\n{res.stderr}'
    return dest


def storeless_exec(binary: Path, args, timeout=60):
    """Execute a binary in an environment with no /nix/store, proving it needs
    nothing from the store, not even a dynamic loader. On Linux this is
    scripts/release/storeless-exec.sh (an empty imported docker image, or a
    user-namespace chroot, whichever is proven to work). On Darwin the host
    itself is the clean environment -- the load-command scan is what proves
    store independence there."""
    if platform.system() == 'Darwin':
        return run([str(binary), *args], timeout=timeout)
    res = run(['bash', str(STORELESS_SCRIPT), 'run', str(binary), *args], timeout=timeout)
    assert res.returncode != STORELESS_NO_MECHANISM, (
        f'storeless-exec.sh could not run {binary.name} at all '
        f'(rc={STORELESS_NO_MECHANISM}); the gate did not execute:\n{res.stderr}')
    return res


def test_release_tarball_is_portable(ctx):
    """Package the freshly built release outs through the REAL packaging
    script, then scan and storeless-execute every binary in the tarball. This
    is the check that would have caught the v0.3.2 wrapper shipment."""
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for portability gate: {platform.system()}/{platform.machine()}')
    out_dir = ctx['work'] / 'release-dist'
    outs = release_attrs_or_skip(ctx)
    res = run(['bash', PACKAGE_SCRIPT, target, 'v0.1.0', out_dir,
               outs['ham-bridge'], outs['ham-ctl'],
               outs['ham-pty-host']], cwd=ROOT, timeout=120)
    assert res.returncode == 0, f'packaging release tarball failed:\n{res.stderr}'
    tarball = out_dir / f'heimdall-local-{target}.tar.gz'
    assert tarball.is_file(), f'no tarball at {tarball}'

    extract = ctx['work'] / 'release-extract'
    extract.mkdir(exist_ok=True)
    res = run(['tar', '-xzf', str(tarball), '-C', str(extract)], timeout=60)
    assert res.returncode == 0, f'tar extract failed:\n{res.stderr}'
    names = sorted(p.name for p in (extract / 'bin').iterdir())
    assert sorted(RELEASE_BINARIES) == names, (
        f'tarball bin/ mismatch: {names!r} != {sorted(RELEASE_BINARIES)!r}')

    for name in RELEASE_BINARIES:
        scan_binary_for_nix_references(extract / 'bin' / name, name)
    # The bundled-openssl era is over: nothing nix-linked may ship.
    assert 'openssl' not in names, (
        'bundled openssl is back in the tarball; it links nix glibc and cannot '
        'run on stock hosts (REQ-INST-16 removed it on purpose)')

    app_version, protocol_version = version_constants()
    expected = {
        'ham-bridge': f'ham-bridge {app_version} protocol {protocol_version} bridge 1 ws 1',
        'ham-ctl': f'ham-ctl {app_version} protocol {protocol_version}',
    }
    print(f'    storeless mechanism: {storeless_mechanism()}')
    for name, line in expected.items():
        res = storeless_exec(extract / 'bin' / name, ['--version'])
        assert res.returncode == 0, (
            f'{name} --version failed storeless (rc={res.returncode}):\n{res.stderr}')
        assert res.stdout.splitlines()[0] == line, (
            f'{name} version line mismatch storeless: {res.stdout.splitlines()[:1]!r}')
    # ham-pty-host is clap-based: no --version, but --help must load and run.
    res = storeless_exec(extract / 'bin' / 'ham-pty-host', ['--help'])
    assert res.returncode == 0, (
        f'ham-pty-host --help failed storeless (rc={res.returncode}):\n{res.stderr}')
    assert res.stdout.strip(), 'ham-pty-host --help printed nothing storeless'


def test_storeless_exec_has_teeth(ctx):
    """Negative control for the execution half, made DIFFERENTIAL.

    A dynamically linked binary must fail to execute in the clean environment;
    if it runs, the gate is decorative and would pass the exact bug it exists
    to catch. But "it failed" is not enough on its own, and that is what broke
    in v0.3.3: the old control asserted only rc != 0, and the docker branch it
    selected was unrunnable (`scratch` is a reserved name), so the daemon's
    exit 125 refusal satisfied the assertion on every docker host. The test
    written to prove the gate had teeth was the one with none.

    So both legs are required, on the SAME mechanism:
      positive -- a known-good static control must run and return exactly 42
      negative -- a dynamic binary must fail
    A mechanism that merely refuses commands fails the positive leg and the
    test fails loudly, instead of passing while executing nothing.
    """
    if platform.system() != 'Linux':
        raise Skip('teeth check is Linux-specific')
    # Not a Skip: if nothing can execute, that is a failure of the gate.
    mechanism = storeless_mechanism()

    # Positive leg: proves the mechanism can execute at all.
    control = write_static_control(ctx['work'] / 'teeth-static-control')
    res = run(['bash', str(STORELESS_SCRIPT), 'run', str(control)], timeout=60)
    assert res.returncode == STORELESS_CONTROL_RC, (
        f'mechanism {mechanism!r} did not execute the known-good static '
        f'control (rc={res.returncode}, expected {STORELESS_CONTROL_RC}). The '
        f'clean environment is not running anything, so the negative leg below '
        f'would be vacuous:\n{res.stderr}')

    # Negative leg: whichever /bin/sh this is (NixOS store bash or a distro
    # dash), it is dynamically linked and its loader is absent from the clean
    # environment, so it must not run.
    dynamic = Path('/bin/sh')
    assert dynamic.is_file(), 'no /bin/sh dynamic control binary on this host'
    probe = run(['readelf', '-l', str(dynamic)], timeout=30)
    assert 'Requesting program interpreter' in probe.stdout, (
        '/bin/sh is not dynamically linked on this host, so it cannot serve as '
        'the negative control')
    res = run(['bash', str(STORELESS_SCRIPT), 'run', str(dynamic), '-c', 'true'],
              timeout=60)
    assert res.returncode != 0, (
        f'dynamic control /bin/sh ran inside the clean environment under '
        f'mechanism {mechanism!r}; the storeless exec gate has no teeth and '
        f'would not catch a nix-linked release')
    assert res.returncode != STORELESS_NO_MECHANISM, (
        'the dynamic control failed because no mechanism was available, not '
        'because the binary could not find its loader')


# ---- 4c. Android seccomp probe (T12) ------------------------------------------
#
# Android 15/Termux SIGSYS-killed the glibc-static linux-arm64 ham-bridge at
# set_robust_list before main. The termux-arm64 bundle is musl-static, and
# scripts/release/android-seccomp-probe.sh is the gate the release workflow
# runs on it (with the glibc linux-arm64 ham-bridge as its negative control).
# These tests pin the probe's own contract: it rejects glibc, passes a binary
# that makes none of the denylisted calls, never passes without a trace, and
# its denylist stays the bionic-verified one.

def test_seccomp_probe_denylist_is_bionic_verified(ctx):
    text = SECCOMP_PROBE_SCRIPT.read_text(encoding='utf-8')
    m = re.search(r"^DENYLIST='([^']*)'", text, re.M)
    assert m, 'android-seccomp-probe.sh must define DENYLIST'
    denied = set(m.group(1).split('|'))
    assert denied == {'set_robust_list', 'rseq', 'clone3', 'io_uring_[a-z_]+', 'add_key',
                      'keyctl', 'request_key', 'memfd_secret', 'accept'}, sorted(denied)
    # Allowed by Android 12 and 15 app policy; statx is called at runtime by
    # Odin's core:os, so denying it would fail every correct binary.
    for allowed in ('statx', 'membarrier', 'personality', 'setns', 'unshare'):
        assert allowed not in denied, f'{allowed} is allowed on Android; must not be denylisted'
    for source in ('SECCOMP_ALLOWLIST_COMMON.TXT', 'android-12.0.0_r1', 'android-15.0.0_r1',
                   'set_robust_list'):
        assert source in text, f'probe must cite {source}'


def test_seccomp_probe_never_passes_untraced(ctx):
    """A strace that traces nothing is an error (3), never a pass."""
    if platform.system() != 'Linux':
        raise Skip('seccomp probe is Linux-specific')
    fake = ctx['work'] / 'fake-strace-bin'
    fake.mkdir()
    (fake / 'strace').write_text('#!/bin/sh\nexit 0\n')
    (fake / 'strace').chmod(0o755)
    control = write_static_control(ctx['work'] / 'seccomp-untraced-control')
    env = dict(os.environ, PATH=f'{fake}:{os.environ.get("PATH", "")}')
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'check', control], env=env, timeout=60)
    assert res.returncode == SECCOMP_PROBE_UNTRACEABLE, (
        f'untraced probe must exit {SECCOMP_PROBE_UNTRACEABLE}, got {res.returncode}:\n{res.stderr}')
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'control', control], env=env, timeout=60)
    assert res.returncode == SECCOMP_PROBE_UNTRACEABLE, (
        f'untraced control must exit {SECCOMP_PROBE_UNTRACEABLE}, got {res.returncode}:\n{res.stderr}')


def glibc_control_binary():
    """A glibc binary for the negative leg: on a glibc host, /bin/true. glibc
    (static or dynamic) registers a robust list for the main thread at start-up,
    which is exactly what the device killed."""
    res = run(['getconf', 'GNU_LIBC_VERSION'], timeout=10)
    if res.returncode != 0 or not res.stdout.startswith('glibc'):
        raise Skip('host libc is not glibc; no glibc negative control available')
    for candidate in ('/bin/true', '/usr/bin/true'):
        if Path(candidate).is_file():
            return Path(candidate)
    raise Skip('no /bin/true on this glibc host')


def test_seccomp_probe_has_teeth(ctx):
    """Differential: the same probe must PASS the static control (exit 42,
    no libc at all) and REJECT a glibc binary naming set_robust_list."""
    if platform.system() != 'Linux':
        raise Skip('seccomp probe is Linux-specific')
    need_tool('strace')
    control = write_static_control(ctx['work'] / 'seccomp-static-control')
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'check', control], timeout=60)
    assert res.returncode == 0, (
        f'probe rejected the libc-free static control (rc={res.returncode}):\n{res.stderr}')
    glibc = glibc_control_binary()
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'check', glibc], timeout=60)
    assert res.returncode == SECCOMP_PROBE_VIOLATION, (
        f'probe passed glibc {glibc} (rc={res.returncode}); it has no teeth:\n{res.stderr}')
    assert 'set_robust_list' in res.stderr, res.stderr
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'control', glibc], timeout=60)
    assert res.returncode == 0, f'control mode did not accept glibc rejection:\n{res.stderr}'
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'control', control], timeout=60)
    assert res.returncode == SECCOMP_PROBE_VIOLATION, (
        f'control mode must fail when the control is NOT rejected:\n{res.stderr}')


def test_termux_release_binaries_pass_seccomp_probe(ctx):
    """The real termux-arm64 Odin binaries, where this host can run them."""
    if host_target() != 'linux-arm64':
        raise Skip('termux-arm64 binaries execute only on an aarch64 Linux host')
    if shutil.which('nix') is None:
        raise Skip(RELEASE_ATTRS_SKIP_REASON)
    need_tool('strace')
    attrs = ['release-termux-ham-bridge', 'release-termux-ham-ctl']
    res = run(['nix', 'build', *[f'.#{a}' for a in attrs], '--print-out-paths', '--no-link'],
              cwd=ROOT, timeout=1800)
    assert res.returncode == 0, f'nix build of termux attrs failed:\n{res.stderr}'
    outs = [l for l in res.stdout.splitlines() if l.startswith('/nix/store/')]
    binaries = [str(Path(out) / 'bin' / name)
                for out, name in zip(outs, ('ham-bridge', 'ham-ctl'))]
    for binary in binaries:
        scan_binary_for_nix_references(Path(binary), Path(binary).name)
    res = run(['bash', SECCOMP_PROBE_SCRIPT, 'check', *binaries], timeout=300)
    assert res.returncode == 0, f'termux binaries failed the seccomp probe:\n{res.stderr}'


# ---- 5. documentation regression ----------------------------------------------

def part2_text():
    text = (ROOT / 'SELF_HOSTING.md').read_text(encoding='utf-8')
    start = text.index('## Part 2')
    end = text.index('## Quick-start checklist')
    return text[start:end], text[:start]


def test_self_hosting_documents_installer(ctx):
    part2, part1 = part2_text()
    one_liner = (f'curl -fsSL https://raw.githubusercontent.com/{GITHUB_REPO}/main/'
                 f'scripts/install.sh | bash')
    assert one_liner in part2, 'Part 2 must show the curl|bash one-liner installer'
    assert 'Quick install' in part2 and 'recommended' in part2.lower(), (
        'Part 2 must present the installer as the recommended path')
    # INVERTED (REQ-ENROLL-9): was ('heimdall enroll', 'heimdall status',
    # 'heimdall update'). `heimdall enroll` is DELETED, so a test demanding the doc
    # document it was pinning a dead command and would have fought whoever fixed the
    # doc.
    for command in ('ham-bridge enroll --hub', 'heimdall status', 'heimdall update'):
        assert command in part2, f'Part 2 must document {command}'

    # The absence half, SHAPED DELIBERATELY. Note what is NOT asserted: a bare
    # `'heimdall enroll' not in part2`. Part 2 names the deleted commands on purpose,
    # in one sentence telling an operator who came looking for them that all three are
    # gone --- that discoverability IS the operator story REQ-ENROLL-9 owes, so a test
    # forbidding the string outright would delete the most useful line in the section.
    #
    # What must be absent is the INSTRUCTIONAL form: a command an operator could paste.
    for dead in ('heimdall enroll hbe_... --hub', '--enrollment-token',
                 'ham-ctl bridge enroll-token --new\n'):
        assert dead not in part2, (
            f'Part 2 still instructs the operator to run the deleted {dead!r}')
    # And the ceremony that cannot happen any more: a token "shown only once".
    assert 'shown only once' not in part2, (
        'Part 2 still promises a one-time token ceremony that no longer exists')
    assert 'set-key' not in part2, (
        'Part 2 must not document the removed vault set-key command')
    assert 'Settings → User Vault → Unseal' in part2, (
        'Part 2 must document unsealing each bridge from the UI')
    for target in ('linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64'):
        asset = f'heimdall-local-{target}.tar.gz'
        assert asset in part2, f'mirror layout must name {asset}'
    assert '`install.sh --hub <url>` and `heimdall update --hub <url>` consume the same' in part2
    assert 'mirror root must contain `SHA256SUMS`' in part2
    assert 'unversioned basenames' in part2
    assert 'sha256sum heimdall-local-*.tar.gz > SHA256SUMS' in part2
    assert 'sudo loginctl enable-linger "$USER"' in part2
    assert 'bridge stops when you\nlog out' in part2
    for socat_command in ('sudo apt install socat', 'brew install socat'):
        assert socat_command in part2, f'quick install must document {socat_command}'
    # Manual/source paths retained as advanced alternatives.
    for marker in ('nix build .#ham-bridge', 'ham-bridge enroll',
                   'Systemd user service', 'launchd agent', 'Home Manager module'):
        assert marker in part2, f'manual path {marker!r} must remain documented'
    # Cross-reference renumbering after the new quick-install section.
    assert 'sections 2.8–2.9' in part2
    # Part 1 (hub) untouched.
    for heading in ('### 1.5 Systemd service (Linux hub)',
                    '### 1.6 NixOS module (hub + nginx)',
                    '### 1.7 Single-user / VPN setup with dev-proxy'):
        assert heading in part1, f'Part 1 heading {heading!r} must be unchanged'


def test_readme_points_at_installer(ctx):
    readme = (ROOT / 'README.md').read_text(encoding='utf-8')
    assert 'install.sh | bash' in readme, 'README Getting started must point at the installer'
    assert 'SELF_HOSTING.md' in readme
    assert '`socat` runtime dependency' in readme
    assert '`heimdall update`' in readme
    assert '`--hub` mirror layout' in readme
    assert 'keep a headless bridge running after logout' in readme


# ---- runner --------------------------------------------------------------------

# --- REQ-INST-14: socat is a hard runtime dep, checked at preflight ------------
# socat is the DEFAULT bridge->hub TLS transport (src/lib/ws/ws.odin:286-297
# returns socat_openssl_command for every HAM_TLS_BACKEND except the legacy
# "s_client") and it is NOT bundled in the release tarball. Before this check a
# socat-less host installed cleanly, was told it succeeded, and then never
# reached a TLS hub. These tests pin the four behaviours: fatal by default,
# exempt for --uninstall, exempt for --dry-run, exempt for an explicitly
# plain-HTTP hub.

SOCAT_FATAL_FRAGMENTS = (
    'socat is not installed',
    'sudo apt install socat',
    'brew install socat',
    'default bridge->hub TLS transport',
    'Nothing has been installed',
)


def socat_free_shim(base: Path, name: str) -> Path:
    """A hermetic PATH with every tool install.sh needs EXCEPT socat.

    Absence is simulated by PATH construction, never by touching what is
    installed on this host -- socat is what the live bridge uses to reach the
    hub, so a test that uninstalled it would break the machine it runs on.
    """
    return _shim_dir(base, name, with_socat=False)


def assert_nothing_installed(home: Path) -> None:
    """No binary, no service file, no PATH edit -- the preflight must fire
    before anything is written, not halfway through."""
    install_dir = home / '.local' / 'bin'
    if install_dir.exists():
        stray = sorted(q.name for q in install_dir.iterdir())
        assert not stray, f'preflight failed yet {install_dir} contains {stray}'
    unit = home / '.config' / 'systemd' / 'user' / 'heimdall-bridge.service'
    plist = home / 'Library' / 'LaunchAgents' / 'works.earendil.heimdall-bridge.plist'
    assert not unit.exists(), f'a failed preflight still wrote {unit}'
    assert not plist.exists(), f'a failed preflight still wrote {plist}'
    for rc in ('.bashrc', '.zshrc', '.profile'):
        target = home / rc
        if target.exists():
            assert 'Added by heimdall install.sh' not in target.read_text(), \
                f'a failed preflight still edited {target}'


def test_socat_missing_is_fatal_and_installs_nothing(ctx):
    """REQ-INST-14. The hub is UNKNOWN here (no --hub), which is the common case
    since REQ-INST-1 made the unit read config.toml instead of baking a URL in.
    Unknown must be treated as needing socat: at install time we cannot know the
    eventual hub and it is overwhelmingly a remote TLS one."""
    base = ctx['work'] / 'socat-fatal'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat')

    res = run_installer(shim, base, 'nosocat', )
    assert res.returncode != 0, (
        f'a missing socat must FAIL the install, got exit 0:\n{res.stdout}')
    out = res.stdout + res.stderr
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment in out, f'the failure does not say {fragment!r}:\n{out}'

    # It must fire BEFORE the release lookup and before any download -- that is
    # the difference between "nothing happened" and "half a machine". This shim
    # has no curl and no wget, so if the preflight ran late the run would have
    # died with the no-downloader diagnosis instead. Asserting that message is
    # ABSENT is what pins the ordering.
    for other in ALL_RESOLVE_MSGS:
        assert other not in out, (
            f'the socat preflight ran AFTER release resolution -- got {other!r}:\n{out}')
    assert 'downloading' not in out, f'a download was attempted anyway:\n{out}'
    assert_nothing_installed(base / 'home-nosocat')


def test_socat_missing_is_fatal_for_a_tls_hub(ctx):
    """An explicit https:// hub is the unambiguous TLS case: socat is exactly
    what terminates that connection, so this must fail like the unknown one."""
    base = ctx['work'] / 'socat-fatal-tls'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-tls')

    res = run_installer(shim, base, 'nosocat-tls', '--hub', 'https://hub.example.com')
    assert res.returncode != 0, (
        f'a missing socat must FAIL against an https:// hub:\n{res.stdout}')
    out = res.stdout + res.stderr
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment in out, f'the failure does not say {fragment!r}:\n{out}'
    assert 'downloading' not in out, f'a download was attempted anyway:\n{out}'
    assert_nothing_installed(base / 'home-nosocat-tls')


def test_socat_failure_names_the_escape_hatch_but_does_not_take_it(ctx):
    """The message must offer HAM_TLS_BACKEND=s_client as an ADVANCED option --
    a user who knowingly accepts the 16 KB multi-read teardown is not stuck --
    while install.sh itself must never fall back to it automatically. An
    automatic fallback would trade a loud failure for a silent degradation of
    large FS reads and artifact transfers, which is the worse bug."""
    base = ctx['work'] / 'socat-escape'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-escape')
    res = run_installer(shim, base, 'nosocat-escape', '--hub', 'https://hub.example.com')
    out = res.stdout + res.stderr
    assert 'HAM_TLS_BACKEND=s_client' in out, \
        f'the failure does not name the manual escape hatch:\n{out}'
    assert 'no automatic fallback' in out, \
        f'the failure does not say the fallback is NOT automatic:\n{out}'

    code = install_sh_code()
    assert 'HAM_TLS_BACKEND=s_client' not in code.replace(
        'HAM_TLS_BACKEND=s_client switches', ''), (
        'install.sh sets HAM_TLS_BACKEND itself somewhere -- the escape hatch is '
        'the operator\'s to take, never the installer\'s')

    # Structural: the preflight must guard on socat's ABSENCE, never silently
    # accept an openssl standing in for it.
    assert 'have_socat()' in code and 'command -v socat' in code


def test_socat_missing_dry_run_previews_instead_of_failing(ctx):
    """REQ-INST-14 exemption: --dry-run writes nothing and exists to PREVIEW, so
    it must still print the plan and exit 0. But the preview has to tell the
    TRUTH about what a real run would do, and what a real run would do is stop --
    so the missing socat is reported at the HEAD of the plan, on stdout, where
    the operator is actually reading, not only beside it on stderr."""
    base = ctx['work'] / 'socat-dry'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-dry')

    res = run_installer(shim, base, 'nosocat-dry', '--dry-run', '--version', 'v0.1.0')
    assert res.returncode == 0, (
        f'--dry-run must stay non-fatal when socat is missing:\n'
        f'stdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    assert 'socat is NOT installed' in res.stdout, (
        'the socat problem must appear IN the plan on stdout, not only on '
        f'stderr:\n{res.stdout}')
    assert 'would STOP HERE and install nothing' in res.stdout, (
        f'the preview must say what a real run would do:\n{res.stdout}')
    # The rest of the plan still prints: a preview that stops at the first
    # problem is not a preview.
    assert 'platform:' in res.stdout and 'would install' in res.stdout, (
        f'the plan was truncated by the socat notice:\n{res.stdout}')
    assert 'would download' in res.stdout
    # And the remedy is still spelled out, on stderr with the rest of the detail.
    assert 'sudo apt install socat' in res.stderr, \
        f'the dry run does not say how to fix it:\n{res.stderr}'
    assert_nothing_installed(base / 'home-nosocat-dry')


def test_socat_missing_uninstall_still_works(ctx):
    """REQ-INST-14 exemption: removing files needs no transport, and refusing to
    uninstall over a missing dependency would strand exactly the users who most
    need to get the thing off their machine."""
    base = ctx['work'] / 'socat-uninstall'
    home = base / 'home-nosocat-un'
    runtime = base / 'run-nosocat-un'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-un')
    env = stub_env(home, runtime, shim)

    # REQ-INST-13: this is a REAL --uninstall, and install.sh's uninstall path
    # stops `heimdall-bridge` -- the same user unit that supervises the agents on
    # this host. Prove the env cannot reach the live session bus first.
    assert_bridge_isolated(env, ctx['work'])
    res = subprocess.run(['bash', str(INSTALL_SCRIPT), '--uninstall'],
                         env=env, capture_output=True, text=True, timeout=90)
    assert res.returncode == 0, (
        f'--uninstall must not require socat:\nstdout:\n{res.stdout}\n'
        f'stderr:\n{res.stderr}')
    out = res.stdout + res.stderr
    assert 'uninstall complete' in out, f'--uninstall did not complete:\n{out}'
    # Match the MESSAGE, not the bare word: this test's own sandbox paths
    # contain "socat", so `'socat' not in out` passes only by accident of
    # naming and fails as soon as a path is printed -- which it is.
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment not in out, (
            f'--uninstall raised the socat requirement ({fragment!r}):\n{out}')
    assert 'socat is NOT installed' not in out, (
        f'--uninstall previewed the socat problem:\n{out}')


def test_socat_missing_plain_http_hub_proceeds(ctx):
    """REQ-INST-14 exemption: parse_ws_url (src/lib/ws/ws.odin:347) sets
    secure=true only for wss://, so the plain-HTTP VPN-only deployment
    documented in SELF_HOSTING.md terminates no TLS and genuinely needs no
    socat. An explicitly plain http:// --hub must therefore inform, not fail.

    Proven by ORDERING rather than by a full install: the run is pointed at a
    closed port, so reaching a download failure is proof it got PAST the
    preflight -- which is the whole claim. A socat error would have come first
    and no download would have been attempted at all."""
    base = ctx['work'] / 'socat-plain-http'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-http')
    # curl is what turns the closed port into a download failure rather than a
    # missing-downloader one; without it this test cannot make its point.
    need_tool('curl')
    if not (shim / 'curl').exists():
        (shim / 'curl').symlink_to(shutil.which('curl'))

    res = run_installer(shim, base, 'nosocat-http', '--hub', 'http://127.0.0.1:9/mirror')
    out = res.stdout + res.stderr
    assert 'socat is not installed; continuing because' in out, (
        f'a plain-HTTP hub must INFORM about the missing socat, not stay silent:\n{out}')
    assert 'is plain HTTP' in out
    assert 'downloading http://127.0.0.1:9/mirror' in out, (
        'the run did not get past the preflight to the download it was pointed '
        f'at:\n{out}')
    assert 'Nothing has been installed' not in out, (
        f'the fatal socat message fired for an exempt plain-HTTP hub:\n{out}')
    # It still fails -- on the unreachable mirror, which is the point: the
    # failure that remains is the download one, not the socat one.
    assert res.returncode != 0
    assert 'download failed' in out, f'expected the download to be what failed:\n{out}'


def test_socat_present_keeps_the_installer_silent(ctx):
    """The control: with socat on PATH the preflight says nothing at all. A
    check that narrates on the happy path is noise, and it would also mean the
    dry-run and exemption assertions above could pass for the wrong reason."""
    base = ctx['work'] / 'socat-present'
    base.mkdir(parents=True, exist_ok=True)
    shim = _shim_dir(base, 'shim-socat')  # with_socat=True by default
    res = run_installer(shim, base, 'socat-ok', '--dry-run', '--version', 'v0.1.0')
    assert res.returncode == 0, f'dry run failed with socat present:\n{res.stderr}'
    out = res.stdout + res.stderr
    # Again the message, not the word: the sandbox path contains "socat".
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment not in out, (
            f'the preflight spoke up although socat is present ({fragment!r}):\n{out}')
    assert 'socat is NOT installed' not in out, (
        f'the dry run reported socat missing although it is present:\n{out}')
    assert 'continuing because' not in out, (
        f'the plain-HTTP exemption fired although socat is present:\n{out}')
    assert 'platform:' in res.stdout and 'would install' in res.stdout


# --- REQ-INST-23: refusing to shadow a system-managed unit --------------------
#
# A unit in ~/.config/systemd/user takes PRECEDENCE over the same name in the
# machine's system-wide user unit directories, so writing ours on a host that
# already has a system-managed heimdall-bridge.service silently takes it over at
# the next restart -- see the long comment at the guard in install.sh. install.sh
# therefore refuses unless --force-service says the shadowing is deliberate.
#
# THE TESTING PROBLEM, AND WHY THESE TESTS LOOK THE WAY THEY DO.
# The guard scans ABSOLUTE paths (/etc/systemd/user and friends), which an
# ordinary-user test cannot redirect -- and this is not hypothetical: the machine
# this suite is developed on HAS /etc/systemd/user/heimdall-bridge.service as a
# NixOS symlink, so every real install below would refuse without a fixture, and
# the negative control ("no system unit -> unchanged") could not be written here
# at all. Redirecting the scan with an env var was considered and rejected: a
# test-only hatch in install.sh, on a safety guard, is the worst place for one.
# So the fixture takes the paths away instead, in a private namespace.


# The namespace scaffolding is resolved ABSOLUTELY, from this harness's own
# environment, because several tests below run install.sh with a deliberately
# minimal stub PATH holding only the utilities the script needs. subprocess
# resolves argv[0] against the PATH of the env it is GIVEN, so a bare 'unshare'
# there raises FileNotFoundError and a bare 'mount' inside the namespace would
# fail the same way. The fixture must not need anything on the PATH under test.
NS_TOOLS = {name: shutil.which(name) for name in ('unshare', 'mount', 'mkdir', 'sh', 'bash')}


def ns_tool(name: str) -> str:
    path = NS_TOOLS.get(name)
    assert path, f'{name} not found on the harness PATH; the namespace fixture needs it'
    return path


def system_unit_dirs_from_install_sh() -> list:
    """The scanned directories, RE-DERIVED from install.sh's own
    system_unit_dirs(). Never keep a hand-typed copy here: a mirrored list
    desyncs the day one side is edited, and a scan this suite no longer covers
    is exactly how a guard rots into decoration."""
    text = INSTALL_SCRIPT.read_text(encoding='utf-8')
    body = re.search(r'^system_unit_dirs\(\) \{(.*?)^\}', text, re.S | re.M)
    assert body, 'install.sh no longer defines system_unit_dirs(); REQ-INST-23 scan lost'
    dirs = re.findall(r'(/[\w.\-/]*?/systemd/user)\b', body.group(1))
    assert dirs, f'system_unit_dirs() lists no directories:\n{body.group(1)}'
    return dirs


# Mounting a tmpfs over one of these to fake a unit inside it would hide most of
# the filesystem from the namespace, so a directory whose only usable mount point
# is one of them is skipped WITH A REASON rather than faked unsafely.
UNSAFE_MOUNT_POINTS = ('/', '/usr', '/etc', '/var', '/run', '/lib', '/usr/lib')


def _unit_dir_mount_point(unit_dir: str):
    """Where to mount a tmpfs so that `unit_dir` can be created inside it, or
    None when this host offers no safe place. A dir that exists is covered
    directly; otherwise the nearest existing ancestor is used, provided covering
    it does not blind the namespace."""
    if os.path.isdir(unit_dir):
        return unit_dir
    parent = str(Path(unit_dir).parent)
    if os.path.isdir(parent) and parent not in UNSAFE_MOUNT_POINTS:
        return parent
    return None


def need_nonroot_userns():
    """The machine-unit fixture needs an unprivileged mount namespace AND the
    ability to map root back to an ordinary uid inside it."""
    if not sys.platform.startswith('linux'):
        raise Skip(
            f'the machine-unit fixture needs Linux mount namespaces and {sys.platform} '
            'has no unshare; launchd precedence differs from systemd (both LaunchAgents '
            'dirs load and a duplicate LABEL conflicts rather than silently overriding) '
            'and REQ-INST-23 deliberately asserts nothing about it')
    need_tool('unshare')
    version = run(['unshare', '--version']).stdout
    parsed = re.search(r'(\d+)\.(\d+)', version)
    assert parsed, f'could not parse a util-linux version out of {version!r}'
    # Deliberately an ASSERT, not a Skip. Without --map-user the fixture would
    # leave install.sh at uid 0, where it takes the sudo/SUDO_USER branch -- so a
    # silent fallback would make every test below exercise the wrong code while
    # still reporting green.
    assert (int(parsed.group(1)), int(parsed.group(2))) >= (2, 38), (
        f'unshare --map-user needs util-linux >= 2.38, this host has {version.strip()}; '
        'refusing to fall back to running install.sh as uid 0, which would silently '
        'test the sudo branch instead of the ordinary one')
    need_userns_mount()
    probe = run(['unshare', '-rm', 'sh', '-c',
                 f'exec unshare --user --map-user={os.getuid()} '
                 f'--map-group={os.getgid()} id -u'])
    if probe.returncode != 0:
        raise Skip(f'nested user namespace unavailable: {probe.stderr.strip() or probe.stdout.strip()}')
    assert probe.stdout.strip() == str(os.getuid()), (
        'the nested namespace did not restore an ordinary uid '
        f'(wanted {os.getuid()}, got {probe.stdout.strip()!r}) -- install.sh would take '
        'the root branch and these tests would cover the wrong path')


def machine_unit_run(args, env, *, unit_in=None, timeout=180, cwd=None):
    """Run install.sh with the MACHINE's system-wide user-unit directories under
    this test's control, as an ORDINARY (non-root) user.

    Both namespaces are load-bearing:
      * the outer `unshare -rm` gives CAP_SYS_ADMIN over a PRIVATE mount
        namespace, the only way an unprivileged test can neutralise absolute
        paths like /etc/systemd/user -- and every mount is invisible to the host;
      * the inner `unshare --user --map-user` maps root BACK to the caller's uid,
        so install.sh sees an ordinary user and takes its $HOME/.local/bin
        branch. Without it the run would stay at uid 0 and take the
        sudo/SUDO_USER branch instead, i.e. cover different code than the test
        claims to.

    unit_in=None hides EVERY scanned directory (the negative control's world: a
    host with no system-managed unit). unit_in=<dir> additionally plants a fake
    machine unit there, which is the world the guard must refuse in.
    """
    dirs = system_unit_dirs_from_install_sh()
    mount, mkdir = ns_tool('mount'), ns_tool('mkdir')
    script = ['set -e']
    for unit_dir in dirs:
        # A directory that does not exist needs no hiding -- the scan's `[ -e ]`
        # already misses it.
        if os.path.isdir(unit_dir):
            script.append(f'{mount} -t tmpfs tmpfs {shlex.quote(unit_dir)}')
    if unit_in is not None:
        assert unit_in in dirs, f'{unit_in} is not scanned by install.sh; dirs={dirs}'
        mount_point = _unit_dir_mount_point(unit_in)
        assert mount_point, f'no safe mount point for {unit_in} on this host'
        if mount_point != unit_in:
            script.append(f'{mount} -t tmpfs tmpfs {shlex.quote(mount_point)}')
        script.append(f'{mkdir} -p {shlex.quote(unit_in)}')
        # printf is a shell builtin, so it needs nothing on PATH.
        script.append(
            f'printf "[Unit]\\nDescription=the machine\'s own bridge\\n" '
            f'> {shlex.quote(unit_in + "/heimdall-bridge.service")}')
    inner = ' '.join(shlex.quote(str(a)) for a in [ns_tool('bash'), str(INSTALL_SCRIPT), *args])
    script.append(f'exec {ns_tool("unshare")} --user --map-user={os.getuid()} '
                  f'--map-group={os.getgid()} {inner}')
    return subprocess.run([ns_tool('unshare'), '-rm', ns_tool('sh'), '-c', '\n'.join(script)],
                          cwd=str(cwd or ROOT), env=env, capture_output=True,
                          text=True, timeout=timeout)


def machine_unit_fixture(ctx, name: str):
    """A stub release, a file:// mirror and a sandbox home+env, for one case."""
    base = ctx['work'] / name
    home = base / 'home'
    (base / 'xdg-runtime').mkdir(parents=True)
    res, tarball = package_tarball(base, target='linux-amd64')
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, 'linux-amd64')
    env = sandbox_install_env(home, base / 'xdg-runtime')
    return home, hub, env


def host_system_unit():
    """The machine's own heimdall-bridge unit, if this host has one. Returns the
    path install.sh's scan would match, or None.

    Tests that perform a REAL install need to know, because on a host that HAS
    one install.sh now (correctly) refuses -- so such a host is the only place
    those tests need the namespace fixture at all. On a host without one (every
    CI runner today, and macOS, where the scan does not run) they keep executing
    exactly as they did before this guard existed: no namespace, no new
    dependency, no behaviour change."""
    if not sys.platform.startswith('linux'):
        return None
    for unit_dir in system_unit_dirs_from_install_sh():
        candidate = f'{unit_dir}/heimdall-bridge.service'
        if os.path.exists(candidate):
            return candidate
    return None


def install_run_shielded(argv, env, *, cwd=None, timeout=120):
    """Run install.sh so that the MACHINE's unit, if any, cannot change the
    outcome -- for tests whose subject is the ordinary install path and not
    REQ-INST-23.

    On a host with no system-managed unit this is a plain subprocess, byte for
    byte what these tests did before the guard existed. On a host that HAS one
    (this development machine does) the run is wrapped in the namespace fixture
    with every scanned directory hidden, because otherwise install.sh would
    rightly refuse and the test would be measuring the guard instead of its own
    subject. Passing --force-service instead was rejected: it would suppress the
    service-file BACKUP behaviour that some of these tests exist to assert."""
    if host_system_unit() is None:
        return subprocess.run(argv, cwd=cwd and str(cwd), env=env,
                              capture_output=True, text=True, timeout=timeout)
    need_nonroot_userns()
    assert Path(argv[0]).name == 'bash' and str(argv[1]) == str(INSTALL_SCRIPT), (
        f'install_run_shielded expects a bash install.sh invocation, got {argv!r}')
    return machine_unit_run(argv[2:], env, unit_in=None, timeout=timeout, cwd=cwd)


def sandbox_home_writes(home: Path) -> list:
    """What a run left in the sandbox home, EXCLUDING the harness's own socat
    stub (socat_stub_dir writes that before install.sh ever starts)."""
    return sorted(str(p.relative_to(home)) for p in home.rglob('*')
                  if not str(p.relative_to(home)).startswith(SOCAT_STUB_DIRNAME))


def test_install_sh_refuses_to_shadow_system_unit(ctx):
    """REQ-INST-23: with a system-managed unit present, a real run must REFUSE
    and leave the machine exactly as it found it -- no service file, no
    binaries, no rc edit -- and say WHY in terms the operator can act on."""
    need_nonroot_userns()
    home, hub, env = machine_unit_fixture(ctx, 'sysunit-refuse')
    res = machine_unit_run(['--hub', hub], env, unit_in='/etc/systemd/user')

    assert res.returncode != 0, (
        f'a run that would shadow the machine unit must FAIL:\n{res.stdout}')
    message = res.stdout + res.stderr
    assert '/etc/systemd/user/heimdall-bridge.service' in message, (
        f'the refusal must name the unit it found:\n{message}')
    assert 'precedence' in message, (
        f'the refusal must explain WHY writing ours is dangerous:\n{message}')
    assert 'Nothing has been installed' in message, (
        f'the refusal must tell the operator the machine is untouched:\n{message}')
    assert '--force-service' in message, (
        f'the refusal must name the deliberate-shadow escape hatch:\n{message}')
    # The third bullet routes an upgrader at their OS, NOT at `heimdall update`:
    # on exactly this host that command stops the service by name, swaps binaries
    # the system unit never execs, and restarts it -- a production bounce for no
    # benefit (T22 / REQ-INST-24). A message naming it would hand the user a
    # version of the harm it is warning about.
    assert 'heimdall update' not in message, (
        'the refusal must NOT route the user at `heimdall update` while it bounces a '
        f'system-managed service for zero benefit (T22):\n{message}')
    assert 'never remove or modify' in message, (
        f'the refusal must promise it will not touch the machine unit:\n{message}')

    # REFUSED MEANS NOTHING WRITTEN. This is the assertion the incident is about:
    # the damage was invisible precisely because a shadowing write succeeds
    # quietly, so "it exited non-zero" is not enough on its own.
    assert sandbox_home_writes(home) == [], (
        f'a refused run must write NOTHING: {sandbox_home_writes(home)}')


def test_install_sh_force_service_shadows_deliberately(ctx):
    """REQ-INST-23: --force-service is the documented way to say "I know a unit
    is in the way and I want mine to win", so the guard must not block it."""
    need_nonroot_userns()
    home, hub, env = machine_unit_fixture(ctx, 'sysunit-force')
    res = machine_unit_run(['--hub', hub, '--force-service'], env,
                           unit_in='/etc/systemd/user')

    assert res.returncode == 0, (
        f'--force-service must proceed past the guard:\n{res.stdout}\n{res.stderr}')
    unit = home / '.config/systemd/user/heimdall-bridge.service'
    assert unit.is_file(), '--force-service must still write the user unit'
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert (home / '.local/bin' / binary).is_file(), f'{binary} not installed'


def test_install_sh_dry_run_reports_system_unit_refusal(ctx):
    """REQ-INST-23: --dry-run must keep previewing (exit 0) and its plan must
    tell the TRUTH -- that a real run would stop here. A preview that omits the
    refusal is how an operator learns about it from an outage instead."""
    need_nonroot_userns()
    home, hub, env = machine_unit_fixture(ctx, 'sysunit-dryrun')
    res = machine_unit_run(['--dry-run', '--hub', hub], env,
                           unit_in='/etc/systemd/user')

    assert res.returncode == 0, (
        f'--dry-run must stay a preview, not a failure:\n{res.stderr}')
    assert 'would REFUSE to continue' in res.stdout, (
        f'the plan must say a real run would refuse:\n{res.stdout}')
    assert '/etc/systemd/user/heimdall-bridge.service' in res.stdout, (
        f'the plan must name the unit it found:\n{res.stdout}')
    assert 'precedence' in res.stdout, f'the plan must say why:\n{res.stdout}'
    assert sandbox_home_writes(home) == [], (
        f'--dry-run must write nothing: {sandbox_home_writes(home)}')


def test_install_sh_without_system_unit_installs_normally(ctx):
    """THE NEGATIVE CONTROL, and the reason the fixture exists at all: with the
    machine's unit directories EMPTY, install.sh must behave exactly as before.
    Without this test an always-on guard -- one that refused on every host --
    would pass every other test in this section."""
    need_nonroot_userns()
    home, hub, env = machine_unit_fixture(ctx, 'sysunit-absent')
    res = machine_unit_run(['--hub', hub], env, unit_in=None)

    assert res.returncode == 0, (
        f'no system unit present, so the install must proceed:\n{res.stdout}\n{res.stderr}')
    assert 'REFUSE' not in res.stdout + res.stderr, (
        f'nothing to refuse here:\n{res.stdout}\n{res.stderr}')
    unit = home / '.config/systemd/user/heimdall-bridge.service'
    assert unit.is_file(), 'the user unit must be written when nothing is shadowed'
    assert 'wrote service file' in res.stdout
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert (home / '.local/bin' / binary).is_file(), f'{binary} not installed'
    # The ordinary (non-root) branch is what the nested namespace exists to
    # preserve: install_dir must be the user's ~/.local/bin, not /usr/local/bin.
    assert str(home / '.local/bin') in res.stdout, (
        f'the run must have taken the ordinary $HOME/.local/bin branch:\n{res.stdout}')


def test_install_sh_uninstall_unaffected_by_system_unit(ctx):
    """REQ-INST-23: the guard sits BELOW the --uninstall exit, so removing our
    own files is never blocked by the machine having its own unit. A user who
    installed before the guard existed must still be able to get out."""
    need_nonroot_userns()
    home, hub, env = machine_unit_fixture(ctx, 'sysunit-uninstall')

    # Install in the world where nothing is shadowed...
    res = machine_unit_run(['--hub', hub], env, unit_in=None)
    assert res.returncode == 0, f'setup install failed:\n{res.stdout}\n{res.stderr}'
    unit = home / '.config/systemd/user/heimdall-bridge.service'
    assert unit.is_file(), 'setup install did not write the unit'

    # ...then uninstall in the world where the machine DOES have its own unit.
    res = machine_unit_run(['--uninstall'], env, unit_in='/etc/systemd/user')
    assert res.returncode == 0, (
        f'--uninstall must not be blocked by a system unit:\n{res.stdout}\n{res.stderr}')
    assert 'REFUSE' not in res.stdout + res.stderr, (
        f'--uninstall has nothing to shadow:\n{res.stdout}\n{res.stderr}')
    assert not unit.exists(), 'the user unit must be removed'
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert not (home / '.local/bin' / binary).exists(), f'{binary} not removed'


def test_install_sh_system_unit_search_path_is_complete(ctx):
    """The scan is a LIST, and a list is where coverage rots. This half is pure
    source inspection so it can never skip: it holds the search path itself to
    account on every host, including the macOS runners where the guard does not
    run and the behavioural half below cannot."""
    dirs = system_unit_dirs_from_install_sh()
    # systemd.unit(5), "User Unit Search Path": the system-wide half of it.
    # ~/.config/systemd/user is deliberately NOT here -- that is where install.sh
    # writes, and it sits above all of these, which is the whole defect.
    assert dirs == ['/etc/systemd/user', '/run/systemd/user',
                    '/usr/local/lib/systemd/user', '/usr/lib/systemd/user',
                    '/lib/systemd/user'], (
        f'the system-wide user unit search path changed: {dirs}')
    home_config = '/.config/systemd/user'
    assert not any(d.endswith(home_config) for d in dirs), (
        'the scan must not include the per-user dir install.sh writes to; it would '
        f'then refuse on an idempotent re-run: {dirs}')


def test_install_sh_scans_every_system_unit_dir(ctx):
    """And this half EXECUTES the guard against each scanned directory the host
    lets us fake, so a loop that silently only ever looks at its first entry is
    caught. Directories with no safe mount point are named, never passed over in
    silence."""
    dirs = system_unit_dirs_from_install_sh()
    need_nonroot_userns()
    executed, unfakeable = [], []
    for index, unit_dir in enumerate(dirs):
        if _unit_dir_mount_point(unit_dir) is None:
            unfakeable.append(unit_dir)
            continue
        home, hub, env = machine_unit_fixture(ctx, f'sysunit-dir{index}')
        res = machine_unit_run(['--hub', hub], env, unit_in=unit_dir)
        assert res.returncode != 0, (
            f'a unit in {unit_dir} must be refused:\n{res.stdout}\n{res.stderr}')
        assert f'{unit_dir}/heimdall-bridge.service' in res.stdout + res.stderr, (
            f'the refusal must name the directory it matched ({unit_dir}):\n{res.stderr}')
        assert sandbox_home_writes(home) == [], (
            f'refused on {unit_dir} but wrote {sandbox_home_writes(home)}')
        executed.append(unit_dir)

    if not executed:
        raise Skip('no scanned unit directory can be faked on this host without a '
                   'tmpfs over / or /usr, which would blind the namespace: '
                   f'{", ".join(unfakeable)} (the search path itself is still '
                   'asserted by the source-level test above)')
    if unfakeable:
        # Stated, never silent: these need a tmpfs over /usr or / to fake, which
        # would blind the namespace. They are covered by the list assertion above.
        print(f'    (executed {len(executed)}/{len(dirs)} scanned dirs; '
              f'no safe mount point on this host for: {", ".join(unfakeable)})')



# --- REQ-INST-26: the PATH the bridge SERVICE runs with ------------------------
# Every assertion below is on the RENDERED unit -- the text install.sh actually
# emits -- never on the heredoc source. A template can contain the right literal
# and still render nothing useful (an unset variable, a $() that failed under
# `set -e`), which is precisely the class of miss these tests exist to catch.

# The dirs each service manager puts on PATH when the unit says nothing.
# systemd --user compiles its default in; launchd's is even narrower. Neither
# contains the installer's $install_dir, and launchd's omits /opt/homebrew/bin,
# which is where `brew install socat` lands on Apple Silicon.
SYSTEMD_DEFAULT_PATH_DIRS = ('/usr/local/bin', '/usr/bin', '/bin',
                             '/usr/local/sbin', '/usr/sbin', '/sbin')
LAUNCHD_DEFAULT_PATH_DIRS = ('/usr/bin', '/bin', '/usr/sbin', '/sbin')


def darwin_uname_shim(base: Path, name: str = 'uname-darwin') -> Path:
    """A PATH dir whose `uname` reports an Apple Silicon Mac.

    install.sh calls uname exactly twice -- `uname -s` and `uname -m`, at the
    platform-detection block -- so shadowing that one binary is TOTAL: it moves
    the whole run onto the darwin branch. This is what lets the launchd
    assertions below actually EXECUTE on a Linux developer box and in Linux CI,
    instead of being written here and only ever proven on a Mac we may not
    reach. Everything else on PATH stays real, and --dry-run writes nothing.
    """
    shim = base / name
    shim.mkdir(parents=True, exist_ok=True)
    real_uname = shutil.which('uname')
    assert real_uname, 'uname is required to build the darwin shim'
    stub = shim / 'uname'
    stub.write_text(
        '#!/bin/sh\n'
        'case "$1" in\n'
        '  -s) echo Darwin ;;\n'
        '  -m) echo arm64 ;;\n'
        f'  *) exec {real_uname} "$@" ;;\n'
        'esac\n')
    stub.chmod(0o755)
    return shim


def rendered_systemd_path(res) -> str:
    """The PATH= value out of a rendered systemd unit, or '' if it sets none."""
    unit = dry_run_unit_text(res)
    assert '[Unit]' in unit, f'not a systemd unit:\n{unit}'
    # systemd accepts Environment=PATH=... and Environment="PATH=..." and the
    # quoted form is the one install.sh must emit (see the space test below), so
    # accept both HERE and let that test police the quoting. Unwrapping is done
    # explicitly rather than by str.strip('"') so a half-quoted line -- which
    # systemd would parse as a literal quote inside the value -- is reported
    # instead of being silently tidied into a pass.
    values = []
    for line in unit.splitlines():
        if not line.startswith('Environment='):
            continue
        body = line[len('Environment='):]
        if body.startswith('"'):
            assert body.endswith('"') and len(body) >= 2, (
                f'unbalanced quote in {line!r}')
            body = body[1:-1]
        elif body.endswith('"'):
            raise AssertionError(f'unbalanced quote in {line!r}')
        if body.startswith('PATH='):
            values.append(body[len('PATH='):])
    assert len(values) <= 1, f'unit sets PATH more than once: {values}'
    return values[0] if values else ''


def rendered_plist_path(res) -> str:
    """The PATH out of a rendered launchd plist, PARSED not grepped.

    plistlib is used deliberately: it proves the plist is well-formed XML and
    that PATH sits under EnvironmentVariables as a real key, which a substring
    match on '<key>PATH</key>' would assert neither of.
    """
    unit = dry_run_unit_text(res)
    assert '<!DOCTYPE plist' in unit, f'not a plist:\n{unit}'
    # dry_run_unit_text slices from '<!DOCTYPE', dropping the '<?xml ...?>'
    # declaration that plistlib requires to recognise the format. Put it back
    # here rather than widening that shared helper, whose exact slice other
    # tests assert on.
    if not unit.lstrip().startswith('<?xml'):
        unit = '<?xml version="1.0" encoding="UTF-8"?>\n' + unit
    parsed = plistlib.loads(unit.encode('utf-8'))
    return parsed.get('EnvironmentVariables', {}).get('PATH', '')


def assert_service_path_is_sane(value: str, install_dir: str, default_dirs, label: str):
    assert value, (
        f'{label}: the rendered unit sets NO PATH. The bridge spawns socat, tmux, '
        f'git and sh by BARE NAME and Odin resolves a slashless argv[0] against '
        f'the spawning process own PATH (core/os/process_linux.odin:425-455), so '
        f'an unset PATH here means the service manager narrow default decides '
        f'whether the bridge can reach its hub at all.')
    entries = value.split(':')
    assert '' not in entries, (
        f'{label}: PATH has an empty component ({value!r}) -- an empty entry means '
        f'"the current directory" to a PATH resolver, which is not something a '
        f'boot service should search.')
    assert entries[0] == install_dir, (
        f'{label}: $install_dir must be the FIRST PATH entry so the binaries this '
        f'installer just wrote win over any older copy elsewhere; got {entries[0]!r} '
        f'first in {value!r}')
    for d in default_dirs:
        assert d in entries, (
            f'{label}: static fallback dir {d} missing from {value!r} -- the tail is '
            f'the boot-time net for when discovery finds nothing.')


def test_service_units_set_path_for_both_writers(ctx, install_script=INSTALL_SCRIPT):
    """REQ-INST-26. BOTH writers, together, asserted on rendered output.

    A systemd-only fix would leave macOS broken, and macOS is where this is
    worst: launchd's default PATH excludes /opt/homebrew/bin, which is exactly
    where `brew install socat` puts the binary the bridge spawns by bare name.
    So the launchd half is not a courtesy -- it is the load-bearing platform.
    """
    base = ctx['work'] / 'service-path'
    base.mkdir(parents=True, exist_ok=True)
    env = dry_run_env(ctx)
    install_dir = str(Path(env['HOME']) / '.local' / 'bin')

    # --- linux / systemd ------------------------------------------------------
    res = run(['bash', install_script, '--dry-run', '--version', 'v0.1.0'],
              timeout=60, env=env)
    assert res.returncode == 0, f'linux dry-run failed:\n{res.stderr}'
    assert 'platform: linux/' in res.stdout, (
        f'expected the linux branch on this host:\n{res.stdout[:400]}')
    systemd_path = rendered_systemd_path(res)
    assert_service_path_is_sane(systemd_path, install_dir,
                                SYSTEMD_DEFAULT_PATH_DIRS, 'systemd unit')

    # --- darwin / launchd, forced with the uname shim -------------------------
    shim = darwin_uname_shim(base)
    denv = {**env, 'PATH': f'{shim}:{env["PATH"]}'}
    dres = run(['bash', install_script, '--dry-run', '--version', 'v0.1.0'],
               timeout=60, env=denv)
    assert dres.returncode == 0, f'darwin dry-run failed:\n{dres.stderr}'
    assert 'platform: darwin/arm64' in dres.stdout, (
        'the uname shim did not move the run onto the darwin branch; the plist '
        f'assertions would silently test nothing:\n{dres.stdout[:400]}')
    plist_path = rendered_plist_path(dres)
    assert_service_path_is_sane(plist_path, install_dir,
                                LAUNCHD_DEFAULT_PATH_DIRS, 'launchd plist')
    assert '/opt/homebrew/bin' in plist_path.split(':'), (
        'the launchd plist PATH must include /opt/homebrew/bin: launchd default '
        'PATH omits it, and `brew install socat` puts socat there on Apple '
        f'Silicon. got {plist_path!r}')


def test_service_path_writer_mutations_are_detected(ctx):
    source = INSTALL_SCRIPT.read_text(encoding='utf-8')
    mutations = (
        ('systemd PATH line removed',
         'Environment="PATH=$(service_path_value)"\n',
         'systemd unit:'),
        ('launchd PATH entry removed',
         '    <key>PATH</key>\n    <string>$(service_path_value)</string>\n',
         'launchd plist:'),
    )

    for name, anchor, expected_failure in mutations:
        assert source.count(anchor) == 1, (
            f'{name}: mutation anchor must occur exactly once')
        mutant = ctx['work'] / f'{name.replace(" ", "-")}.sh'
        mutant.write_text(source.replace(anchor, '', 1), encoding='utf-8')
        try:
            test_service_units_set_path_for_both_writers(ctx, mutant)
        except AssertionError as error:
            assert expected_failure in str(error), (
                f'{name}: killed for the wrong reason: {error}')
        else:
            raise AssertionError(f'mutation survived: {name}')


def test_service_path_reaches_a_socat_outside_the_default_dirs(ctx):
    """REQ-INST-26/REQ-INST-14: the preflight must BIND.

    The REQ-INST-14 preflight resolves socat in the INSTALLER's shell. If the
    generated unit then ships a PATH that cannot see that same socat, the
    preflight guarantees something other than what it claims -- it passes, the
    install reports success, and the bridge still cannot reach a wss:// hub.

    _shim_dir + stub_env put socat in a hermetic directory that is NOT any
    service-manager default dir (that is the whole point of stub_env setting
    PATH to the shim ALONE), so this is the real 'socat lives somewhere the
    service manager would never look' case rather than a simulation of it.
    """
    base = ctx['work'] / 'service-path-socat'
    base.mkdir(parents=True, exist_ok=True)
    shim = _shim_dir(base, 'shim-socat-elsewhere')
    assert (shim / 'socat').exists(), 'the shim must supply socat'
    shim_str = str(shim)
    for default_dir in set(SYSTEMD_DEFAULT_PATH_DIRS) | set(LAUNCHD_DEFAULT_PATH_DIRS):
        assert shim_str != default_dir, 'the shim must not BE a default dir'

    home = base / 'home'
    runtime = base / 'runtime'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    res = install_run_shielded(
        ['bash', str(INSTALL_SCRIPT), '--dry-run', '--version', 'v0.1.0'],
        stub_env(home, runtime, shim), timeout=90)
    assert res.returncode == 0, (
        f'hermetic dry-run failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')

    rendered = rendered_systemd_path(res)
    entries = rendered.split(':')
    assert shim_str in entries, (
        f'socat lives in {shim_str}, which no service manager default PATH '
        f'contains, and the rendered unit PATH does not include it: {rendered!r}. '
        f'The REQ-INST-14 preflight would pass and the bridge would still fail '
        f'to spawn socat.')
    # Prove the claim the assertion rests on rather than asserting around it:
    # no OTHER entry in the rendered PATH could have supplied socat, so the shim
    # dir is genuinely load-bearing here.
    others = [d for d in entries if d != shim_str]
    assert shutil.which('socat', path=':'.join(others)) is None, (
        f'this test is not proving what it claims: socat is also reachable via '
        f'{others} on this host, so the assertion above would pass even without '
        f'the discovered entry. Harden the shim.')


def test_service_path_tool_inventory_does_not_desync(ctx):
    """REQ-INST-26: the tool list must be re-derivable, not a hand-typed mirror.

    service_path_tools() exists so this single source can be checked against the
    bridge's actual bare-name spawns. A literal list pasted into the writers
    would drift the moment someone adds a spawn, and the drift would be
    invisible -- the same failure the REQ-INST-19 rc tripwire and
    system_unit_dirs() were both built to prevent.
    """
    # Sourcing install.sh would run main(); read the function body instead.
    text = INSTALL_SCRIPT.read_text(encoding='utf-8')
    body = text.split('service_path_tools() {', 1)[1].split('}', 1)[0]
    tools = body.replace("printf '%s\\n'", '').split()
    assert tools, f'could not re-derive service_path_tools() from:\n{body}'

    # Each declared tool must correspond to a real bare-name spawn in the Odin
    # sources: a vector whose argv[0] is that literal with no slash.
    src = ROOT / 'src'
    missing = []
    for tool in tools:
        lit = re.escape(tool)
        # Two spawn spellings in this codebase, and a pattern that knew only the
        # first silently reported socat missing:
        #   composite literal -- []string{"tmux", "has-session", ...}
        #   incremental append -- append(&cmd, "socat")   (ws.odin:341)
        pats = (re.compile(r'(\{|,)\s*"' + lit + r'"\s*(,|\})'),
                re.compile(r'append\(\s*&\w+\s*,\s*"' + lit + r'"\s*\)'))
        found = any(any(pat.search(body) for pat in pats)
                    for body in (f.read_text(encoding='utf-8', errors='replace')
                                 for f in src.rglob('*.odin') if 'test' not in f.name))
        if not found:
            missing.append(tool)
    assert not missing, (
        f'service_path_tools() lists {missing}, which no Odin source spawns by '
        f'bare name -- either the spawn was removed and the list went stale, or '
        f'the name is wrong.')

    # And the reverse direction for the tools this task established: every one
    # of these IS spawned bare, so none may quietly fall out of the list.
    for required in ('socat', 'tmux', 'git', 'sh'):
        assert required in tools, (
            f'{required} is spawned by bare name by the bridge but is no longer '
            f'in service_path_tools(); the service PATH may no longer reach it.')



def test_service_path_survives_a_space_in_the_install_dir(ctx):
    """REQ-INST-26: systemd Environment= splits on whitespace.

    `Environment=PATH=/home/my user/.local/bin:...` does NOT set that PATH --
    systemd takes the assignment up to the space and discards the remainder,
    which `systemd-analyze verify` reports as "Invalid environment assignment,
    ignoring: user/.local/bin:...". So the unquoted form renders a unit whose
    PATH is a truncated fragment, and the fix for REQ-INST-26 would itself be
    broken on any host with a space in $HOME. The quoted form is the fix; this
    test is what stops it being un-fixed.

    Asserted on the rendered unit AND, where systemd-analyze is available, by
    systemd's own parser rather than by this file's reading of the manual.
    """
    base = ctx['work'] / 'service-path-space'
    home = base / 'my home'
    home.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, 'HOME': str(home)}
    install_dir = str(home / '.local' / 'bin')
    assert ' ' in install_dir, 'this test is pointless without a space'

    res = run(['bash', INSTALL_SCRIPT, '--dry-run', '--version', 'v0.1.0'],
              timeout=60, env=env)
    assert res.returncode == 0, f'dry-run failed:\n{res.stderr}'
    unit = dry_run_unit_text(res)

    line = next((l for l in unit.splitlines()
                 if l.startswith('Environment=') and 'PATH=' in l), None)
    assert line is not None, f'no PATH line in:\n{unit}'
    assert line.startswith('Environment="PATH=') and line.endswith('"'), (
        f'the PATH assignment must be QUOTED or systemd truncates it at the '
        f'first space in $install_dir; got {line!r}')
    # The whole install_dir, space included, must survive inside the quotes.
    assert install_dir in line, (
        f'{install_dir!r} did not survive into {line!r}')

    # Let systemd judge its own syntax where we can -- but judge OUR line only.
    #
    # This lifts the PATH line into a minimal unit rather than verifying the
    # whole thing, so that any environment-assignment complaint from systemd is
    # unambiguously about the line under test and cannot be masked or satisfied
    # by a sibling line. REQ-INST-28 has since fixed ExecStart and the two
    # HEIMDALL_*_BIN lines, which carried the identical defect, and
    # test_systemd_unit_survives_a_space_in_the_install_dir now verifies the
    # COMPLETE rendered unit. Both are wanted: that one proves a user's bridge
    # starts, this one keeps the PATH line individually pinned.
    #
    # So the PATH line is lifted into a minimal unit of its own. Any
    # environment-assignment complaint from systemd is then unambiguously about
    # the line under test. T30 leaves this focused check working unchanged.
    analyze = shutil.which('systemd-analyze')
    if analyze is None:
        raise Skip('systemd-analyze not available; rendered-text assertions above still ran')
    unit_file = base / 'heimdall-bridge.service'
    unit_file.write_text(
        '[Unit]\nDescription=PATH quoting probe\n\n'
        '[Service]\nType=simple\nExecStart=/bin/true\n'
        + line + '\n\n[Install]\nWantedBy=default.target\n')
    vres = run([analyze, 'verify', str(unit_file)], timeout=60)
    combined = vres.stdout + vres.stderr
    assert 'Invalid environment assignment' not in combined, (
        f'systemd rejected the PATH assignment {line!r}:\n{combined}')


# --- REQ-INST-28: a space in $install_dir must not break the generated units ---
# systemd's Environment= and ExecStart= split on UNQUOTED whitespace, so an
# interpolated path containing a space silently truncates the line: no error at
# install time, total failure at runtime. Everything below is asserted on the
# RENDERED unit and, where the platform's own parser is available, judged by
# THAT parser rather than by this file's reading of the manual.

SPACED_HOME_DIRNAME = 'my home'


def render_unit_with_spaced_home(ctx, name: str, extra_env: dict = None):
    """Run a real --dry-run whose $HOME (and so $install_dir) contains a space.

    Returns (res, install_dir). A ham-bridge stub is created at the rendered
    install_dir because systemd-analyze resolves ExecStart against the
    filesystem: without it systemd reports "is not executable: No such file",
    which would be indistinguishable from the truncation defect under test.
    """
    base = ctx['work'] / name
    home = base / SPACED_HOME_DIRNAME
    install_dir = home / '.local' / 'bin'
    install_dir.mkdir(parents=True, exist_ok=True)
    assert ' ' in str(install_dir), 'this test is pointless without a space'
    stub = install_dir / 'ham-bridge'
    stub.write_text('#!/bin/sh\nexit 0\n')
    stub.chmod(0o755)
    env = {**os.environ, 'HOME': str(home)}
    if extra_env:
        env.update(extra_env)
    res = run(['bash', INSTALL_SCRIPT, '--dry-run', '--version', 'v0.1.0',
               '--hub', 'https://hub.example/x'], timeout=60, env=env)
    assert res.returncode == 0, f'dry-run failed:\n{res.stdout}\n{res.stderr}'
    return res, str(install_dir)


def test_systemd_unit_survives_a_space_in_the_install_dir(ctx):
    """REQ-INST-28. The WHOLE unit must verify clean, not one lifted line.

    T27's REQ-INST-26 test could only lift its PATH line into a minimal unit,
    because ExecStart and the two HEIMDALL_*_BIN lines carried the identical
    defect and would have failed the full-unit check for a reason that was not
    that test's subject. This task fixed those three, so the full-unit check is
    now possible -- and it is the only form that proves a user's bridge would
    actually start.
    """
    res, install_dir = render_unit_with_spaced_home(ctx, 'unit-space-systemd')
    assert 'platform: linux/' in res.stdout, 'expected the linux branch on this host'
    unit = dry_run_unit_text(res)

    # Every interpolated value must survive WHOLE into the rendered unit.
    for key, want in (('HEIMDALL_HAM_PTY_HOST_BIN', f'{install_dir}/ham-pty-host'),
                      ('HEIMDALL_HAM_CTL_BIN', f'{install_dir}/ham-ctl')):
        line = next((l for l in unit.splitlines()
                     if l.startswith('Environment=') and key in l), None)
        assert line is not None, f'no {key} line in:\n{unit}'
        assert line == f'Environment="{key}={want}"', (
            f'{key} must be QUOTED or systemd truncates it at the first space '
            f'in $install_dir; got {line!r}')
    exec_line = next((l for l in unit.splitlines() if l.startswith('ExecStart=')), None)
    assert exec_line is not None, f'no ExecStart in:\n{unit}'
    assert exec_line.startswith(f'ExecStart="{install_dir}/ham-bridge"'), (
        f'ExecStart must quote $install_dir or systemd execs the truncated '
        f'prefix; got {exec_line!r}')

    # Now let systemd judge its own syntax, on the COMPLETE unit.
    analyze = shutil.which('systemd-analyze')
    if analyze is None:
        raise Skip('systemd-analyze not available; rendered-text assertions above still ran')
    unit_file = ctx['work'] / 'unit-space-systemd' / 'heimdall-bridge.service'
    unit_file.write_text(unit + '\n')
    vres = run([analyze, 'verify', str(unit_file)], timeout=60)
    combined = vres.stdout + vres.stderr
    assert 'Invalid environment assignment' not in combined, (
        f'systemd rejected an Environment= line:\n{combined}\n\nunit:\n{unit}')
    assert 'is not executable' not in combined, (
        f'systemd could not resolve ExecStart -- the path was truncated at a '
        f'space:\n{combined}\n\nunit:\n{unit}')
    assert vres.returncode == 0, (
        f'systemd-analyze verify failed on the rendered unit:\n{combined}\n\nunit:\n{unit}')


def test_launchd_plist_survives_a_space_in_the_install_dir(ctx):
    """REQ-INST-28, the NEGATIVE half: launchd was ALREADY correct.

    XML is not whitespace-split, so $install_dir inside a <string> needs no
    quoting and none was added. This is a REGRESSION TEST, not a fix: it pins
    the property so a future 'tidy-up' of the plist heredoc -- say one that
    moved ProgramArguments to a single space-separated <string> -- cannot
    reintroduce on macOS the defect just fixed on Linux.

    The darwin branch is reached on Linux with the uname shim from REQ-INST-26,
    so this assertion actually EXECUTES here instead of being written and only
    ever proven on a Mac we may not reach.
    """
    shim = darwin_uname_shim(ctx['work'] / 'unit-space-launchd-shim')
    res, install_dir = render_unit_with_spaced_home(
        ctx, 'unit-space-launchd', {'PATH': f'{shim}:{os.environ["PATH"]}'})
    assert 'platform: darwin/arm64' in res.stdout, (
        f'the uname shim did not move the run onto the darwin branch; the plist '
        f'assertions would silently test nothing:\n{res.stdout[:400]}')

    xml = dry_run_unit_text(res)
    if not xml.lstrip().startswith('<?xml'):
        xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + xml
    parsed = plistlib.loads(xml.encode('utf-8'))

    argv = parsed['ProgramArguments']
    # The decisive assertion: the spaced path is ONE argv element, not two.
    assert argv[0] == f'{install_dir}/ham-bridge', (
        f'ProgramArguments[0] must be the whole spaced path as a single '
        f'element; got {argv[0]!r} in {argv!r}')
    for i, arg in enumerate(argv):
        assert arg == arg.strip(), f'argv[{i}]={arg!r} has stray whitespace'
    # No element may be a fragment of the install dir -- what splitting looks like.
    head = install_dir.split(' ')[0]
    assert head not in argv, (
        f'argv contains {head!r}, the prefix of $install_dir up to its first '
        f'space -- the path was split: {argv!r}')
    env_vars = parsed['EnvironmentVariables']
    assert env_vars['HEIMDALL_HAM_PTY_HOST_BIN'] == f'{install_dir}/ham-pty-host'
    assert env_vars['HEIMDALL_HAM_CTL_BIN'] == f'{install_dir}/ham-ctl'


def test_fish_rc_line_quotes_a_spaced_install_dir(ctx):
    """REQ-INST-28: the same defect in the rc writer, not a unit file.

    `fish_add_path /home/my user/.local/bin` is TWO arguments to fish, so on a
    spaced home the installer writes an rc line that adds two wrong paths and
    not the right one. The independent awk mirror in do_uninstall() must change
    in lockstep or uninstall silently leaves that line behind.

    This is a REAL install into a sandboxed spaced HOME -- the rc file on disk
    is the artifact asserted on, because the printed fallback snippet and the
    written line are two different code paths. The second install binds
    wire_path()'s duplicate guard. The independent do_uninstall() matcher is
    exercised by test_fish_uninstall_removes_quoted_spaced_install_dir below.
    """
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')
    base = ctx['work'] / 'fish-space'
    home = base / SPACED_HOME_DIRNAME
    runtime = base / 'xdg-runtime'
    runtime.mkdir(parents=True, exist_ok=True)
    home.mkdir(parents=True, exist_ok=True)

    res, tarball = package_tarball(base, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)

    # sandbox_install_env blanks SHELL (its union branch); this test is
    # specifically the *fish* branch of path_candidates()/wire_path(), so SHELL
    # is set back to a fish. The binary need not exist -- install.sh only
    # case-globs the string.
    env = {**sandbox_install_env(home, runtime), 'SHELL': '/usr/bin/fish'}
    install_dir = home / '.local' / 'bin'
    assert ' ' in str(install_dir), 'this test is pointless without a space'

    res = install_run_shielded(
        ['bash', str(INSTALL_SCRIPT), '--hub', hub], env, cwd=ROOT, timeout=120)
    assert res.returncode == 0, (
        f'install into a spaced HOME failed:\nstdout:\n{res.stdout}\n'
        f'stderr:\n{res.stderr}')

    config_fish = home / '.config' / 'fish' / 'config.fish'
    assert config_fish.is_file(), (
        f'the fish branch must write config.fish; got:\n{res.stdout}')
    written = config_fish.read_text()
    want = f'fish_add_path "{install_dir}"'
    assert want in written, (
        f'the rc line must QUOTE the spaced install dir -- unquoted, fish takes '
        f'{install_dir!r} as two arguments and adds neither.\n'
        f'wanted: {want!r}\ngot:\n{written}')

    # Idempotency: a second run must not append a second copy. wire_path()
    # decides this with `grep -Fqx "$path_line"`, i.e. against the very string
    # it writes -- so this pins that the WRITTEN form stays greppable (a stray
    # trailing space or a re-quoting would break it), not that two independent
    # copies agree.
    res2 = install_run_shielded(
        ['bash', str(INSTALL_SCRIPT), '--hub', hub], env, cwd=ROOT, timeout=120)
    assert res2.returncode == 0, f're-run failed:\n{res2.stderr}'
    rewritten = config_fish.read_text()
    assert rewritten.count('fish_add_path') == 1, (
        f'a re-run must not append a second PATH line -- wire_path no longer '
        f'recognises the exact line it writes:\n{rewritten}')


def test_fish_uninstall_removes_quoted_spaced_install_dir(ctx):
    """REQ-INST-28: do_uninstall must match the exact Fish line wire_path writes."""
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')
    base = ctx['work'] / 'fish-space-uninstall'
    home = base / SPACED_HOME_DIRNAME
    runtime = base / 'xdg-runtime'
    runtime.mkdir(parents=True, exist_ok=True)
    config_fish = home / '.config' / 'fish' / 'config.fish'
    config_fish.parent.mkdir(parents=True)
    unrelated = '# user fish config\nset -gx EDITOR vi\n'
    config_fish.write_text(unrelated)

    packaged, tarball = package_tarball(base, target=target)
    assert packaged.returncode == 0, f'packaging failed:\n{packaged.stderr}'
    hub = make_hub_mirror(base, tarball, target)
    env = {**sandbox_install_env(home, runtime), 'SHELL': '/usr/bin/fish'}
    install_dir = home / '.local' / 'bin'
    assert ' ' in str(install_dir), 'this test is pointless without a space'

    installed = install_run_shielded(
        ['bash', str(INSTALL_SCRIPT), '--hub', hub], env, cwd=ROOT, timeout=120)
    assert installed.returncode == 0, (
        f'install into a spaced HOME failed:\nstdout:\n{installed.stdout}\n'
        f'stderr:\n{installed.stderr}')
    quoted_line = f'fish_add_path "{install_dir}"'
    before_uninstall = config_fish.read_text()
    assert '# Added by heimdall install.sh' in before_uninstall
    assert quoted_line in before_uninstall

    assert_bridge_isolated(env, ctx['work'])
    removed = install_run_shielded(
        ['bash', str(INSTALL_SCRIPT), '--uninstall'], env, cwd=ROOT, timeout=120)
    assert removed.returncode == 0, (
        f'uninstall from a spaced HOME failed:\nstdout:\n{removed.stdout}\n'
        f'stderr:\n{removed.stderr}')
    after_uninstall = config_fish.read_text()
    assert '# Added by heimdall install.sh' not in after_uninstall, (
        f'uninstall left its marker in config.fish:\n{after_uninstall}')
    assert quoted_line not in after_uninstall, (
        f'do_uninstall no longer matches the quoted Fish line it must remove:\n'
        f'{after_uninstall}')
    assert '# user fish config' in after_uninstall, (
        f'uninstall removed unrelated Fish configuration:\n{after_uninstall}')
    assert 'set -gx EDITOR vi' in after_uninstall, (
        f'uninstall removed an unrelated Fish setting:\n{after_uninstall}')


# --- REQ-INST-27: the socat probe's own assertion must BIND --------------------

# Exactly the tools sudo_ns_install's inner script needs BEFORE install.sh runs:
# the mounts, the probe, and the shells that carry them. Supplying precisely
# these -- and nothing else -- is what makes the mutation below surgical.
#
# The trap this avoids was measured during REQ-INST-22: on this host socat is
# supplied by FOUR PATH entries, one of which (/run/current-system/sw/bin) is
# the ONLY provider of `mount`. Dropping "socat's PATH entry" therefore kills
# `mount` too, and the mutant dies of a broken mount rather than of a missing
# socat -- a caught mutant that caught nothing. Linking INDIVIDUAL binaries by
# their resolved absolute path sidesteps directory granularity entirely.
NS_PROBE_PREREQS = ('mount', 'mkdir', 'unshare', 'env', 'bash', 'sh', 'umount')


def thinned_tool_dir(base: Path):
    """A PATH dir holding symlinks to exactly NS_PROBE_PREREQS, socat excluded.

    Returns (dir, skip_reason). skip_reason is non-None when this host cannot
    support an HONEST mutation, and the caller must skip rather than assert:
    a tool resolving under /usr would be hidden by the fixture's own tmpfs over
    /usr inside the namespace, so the run would die of a missing `mount` and the
    mutation would prove nothing. That is the same host assumption
    sudo_ns_install ALREADY makes at its bare `mount`/`mkdir` calls -- this test
    inherits it, it does not add one.
    """
    thin = base / 'thin-bin'
    thin.mkdir(parents=True, exist_ok=True)
    under_usr = []
    for name in NS_PROBE_PREREQS:
        found = shutil.which(name)
        if not found:
            return thin, f'{name} not on PATH; cannot build a surgical namespace PATH'
        real = os.path.realpath(found)
        if real.startswith('/usr/'):
            under_usr.append(f'{name}->{real}')
        link = thin / name
        if not link.exists():
            link.symlink_to(real)
    if under_usr:
        return thin, ('these tools resolve under /usr, which the fixture mounts a '
                      'tmpfs over inside the namespace, so the mutation would die '
                      f'of a missing tool rather than of a missing socat: {under_usr}')
    return thin, None


def test_socat_probe_assertion_binds(ctx):
    """REQ-INST-27: MUTATION + CONTROL for the REQ-INST-22 probe.

    REQ-INST-22 added a socat probe inside sudo_ns_install and asserted
    SOCAT_UNREACHABLE_IN_NS is absent from stderr. That assertion's proof was a
    throwaway harness run once and never committed -- so a later refactor could
    neuter the probe and the suite would go quiet again, which is the very
    failure mode REQ-INST-22 exists to remove, one level up.

    This drives the REAL sudo_ns_install (not a copy of its inner script), so
    BOTH the probe and the assertion that reads it are under test:

      MUTATION: surgical PATH, no socat anywhere -> sudo_ns_install must RAISE.
      CONTROL : byte-identical run + the socat stub -> must NOT raise.

    The control is what makes the mutation mean anything. A mutation alone
    proves the probe died; only the control proves it died of MISSING SOCAT
    rather than of the thinning having broken the namespace -- and that
    distinction is the entire point, established when the naive mutation was
    measured vacuous in REQ-INST-22.

    HOST ASSUMPTION, stated rather than assumed: the tools in NS_PROBE_PREREQS
    must resolve OUTSIDE /usr (they do on a Nix host; see thinned_tool_dir,
    which skips loudly otherwise). Note this is NOT sensitive to where socat
    lives: socat is excluded BY NAME from the thinned dir, so a host with
    /usr/bin/socat is fine on that axis -- and doubly so, since the fixture's
    tmpfs over /usr would hide it anyway.
    """
    need_userns_mount()
    base = ctx['work'] / 'socat-probe-binding'
    base.mkdir(parents=True, exist_ok=True)
    thin, skip_reason = thinned_tool_dir(base)
    if skip_reason:
        raise Skip(f'cannot mutate honestly on this host: {skip_reason}')

    thin_path = str(thin)
    # PRECONDITIONS. Without these the mutation is not attributable: the first
    # makes socat genuinely absent, the second proves the thinning did not
    # break the namespace tooling and take the probe down with it.
    assert shutil.which('socat', path=thin_path) is None, (
        f'the thinned PATH still reaches socat, so the mutation would not '
        f'suppress it: {shutil.which("socat", path=thin_path)}')
    assert shutil.which('mount', path=thin_path), (
        'the thinned PATH lost `mount`; the mutant would die of a broken '
        'namespace rather than of a missing socat')

    hub, _fake_home, entry = sudo_ns_fixture(base)

    # --- MUTATION: socat absent. The probe must fire AND be caught. ----------
    try:
        sudo_ns_install(base, hub, entry, thin_path,
                        host_path='', socat_stub=False)
    except AssertionError as exc:
        mutation_error = str(exc)
    else:
        raise AssertionError(
            'THE PROBE NO LONGER BINDS: socat was absent from the namespace and '
            'sudo_ns_install did not raise. Either the probe was removed from '
            'the inner script or the SOCAT_UNREACHABLE_IN_NS assertion no longer '
            'reads it -- which is exactly the silent regression REQ-INST-22 was '
            'written to prevent.')
    assert 'SOCAT_UNREACHABLE_IN_NS' in mutation_error, (
        f'the probe fired but not via its own diagnostic:\n{mutation_error}')
    # The failure must be about socat, not about a namespace we broke.
    lowered = mutation_error.lower()
    for noise in ('permission denied', 'operation not permitted',
                  'mount: ', 'no such file or directory'):
        assert noise not in lowered, (
            f'the mutation died with {noise!r} in its output, so it is not '
            f'attributable to the missing socat alone:\n{mutation_error}')

    # --- CONTROL: byte-identical, plus the stub. Must NOT raise. ------------
    # install.sh itself will fail further on (the thinned PATH has no curl or
    # tar) and that is FINE and deliberately not asserted against: the only
    # claim here is that the PROBE passed, which is the single variable that
    # differs from the mutation above.
    control = sudo_ns_install(base, hub, entry, thin_path,
                              host_path='', socat_stub=True)
    assert 'SOCAT_UNREACHABLE_IN_NS' not in control.stderr, (
        f'CONTROL FAILED: socat WAS supplied and the probe still fired, so the '
        f'mutation above proved nothing about socat -- the thinned PATH itself '
        f'is what breaks these runs:\n{control.stderr}')


def test_install_sh_enrollment_interactive_scenarios(ctx):
    """REQ-INST-ENROLL-1 through REQ-INST-ENROLL-4: Interactive onboarding ceremony
    including Hub URL prompt, bridge token pre-check, enrollment command invocation,
    service startup verification, and client vault master-password setup."""
    work = ctx['work'] / 'interactive-enroll'
    home = work / 'home'
    runtime = work / 'runtime'
    bin_dir = work / 'bin'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)

    # Mock heimdall binary.
    #
    # INVERTED (REQ-ENROLL-9): the `enroll <token>` branch is GONE, not reshaped.
    # `heimdall enroll hbe_...` is deleted, and enrollment is no longer this binary's
    # job at all --- the installer drives `ham-bridge enroll --hub` instead (mocked
    # separately below). What is left here is the vault ceremony, which is unrelated
    # to enrollment and unchanged.
    #
    # Leaving a dead `enroll` branch in the mock would be actively misleading: the
    # installer would never call it, so it could rot indefinitely while looking like
    # supported behaviour.
    mock_heimdall = bin_dir / 'heimdall'
    mock_heimdall.write_text(
        '#!/usr/bin/env bash\n'
        'if [ "$1" = "vault" ]; then\n'
        '  if [ "${2:-}" = "--help" ]; then\n'
        '    echo "Commands:"\n'
        '    echo "  master-password  Configure vault master password"\n'
        '    exit 0\n'
        '  elif [ "${2:-}" = "master-password" ]; then\n'
        '    read -r pwd\n'
        '    echo "vault_configured:$pwd" > "$HOME/.config/heimdall/vault_status"\n'
        '    exit 0\n'
        '  fi\n'
        'fi\n'
        'exit 0\n'
    )
    mock_heimdall.chmod(0o755)

    # Mock systemctl binary
    mock_systemctl = bin_dir / 'systemctl'
    mock_systemctl.write_text(
        '#!/usr/bin/env bash\n'
        'if [ "$1" = "--user" ] && [ "$2" = "enable" ] && [ "$3" = "--now" ] && [ "$4" = "heimdall-bridge" ]; then\n'
        '  echo "mock: bridge started"\n'
        '  exit 0\n'
        'elif [ "$1" = "--user" ] && [ "$2" = "is-active" ] && [ "$3" = "heimdall-bridge" ]; then\n'
        '  echo "active"\n'
        '  exit 0\n'
        'fi\n'
        'exit 0\n'
    )
    mock_systemctl.chmod(0o755)

    # Mock ham-bridge --- the device flow (REQ-ENROLL-9).
    #
    # install.sh invokes "$install_dir/ham-bridge" by ABSOLUTE PATH, not via PATH
    # lookup (install.sh:1354), so this must live in bin_dir to be found.
    #
    # It records its argv, because argv is the only proof the installer actually
    # drove the device flow: stdout can be made to say anything, but the flags
    # passed to the binary are the behaviour under test. It also prints the ceremony
    # a real `ham-bridge enroll --hub` prints, so the test can prove the link and the
    # short code reach the operator's terminal rather than being swallowed.
    mock_bridge_argv = work / 'ham_bridge_argv.log'
    mock_ham_bridge = bin_dir / 'ham-bridge'
    mock_ham_bridge.write_text(
        '#!/usr/bin/env bash\n'
        f'echo "$*" >> "{mock_bridge_argv}"\n'
        'if [ "$1" = "enroll" ]; then\n'
        '  token_file=""\n'
        '  while [ "$#" -gt 0 ]; do\n'
        '    if [ "$1" = "--bridge-token-file" ]; then token_file="$2"; fi\n'
        '    shift\n'
        '  done\n'
        '  echo "Open this link on any device to approve:  http://heimdall.example.test/enroll/device"\n'
        '  echo "User code: WDJB-MJHT"\n'
        '  echo "Key fingerprint: SHA256:mockmockmockmockmockmockmockmockmockmockmoc"\n'
        '  if [ -n "$token_file" ]; then\n'
        '    mkdir -p "$(dirname "$token_file")"\n'
        '    echo "mock-device-flow-credential" > "$token_file"\n'
        '  fi\n'
        '  exit 0\n'
        'fi\n'
        'exit 0\n'
    )
    mock_ham_bridge.chmod(0o755)

    env = sandbox_install_env(home, runtime)
    cur_path = env['PATH']
    env['PATH'] = f"{bin_dir}{os.pathsep}{cur_path}"
    env['HEIMDALL_INTERACTIVE'] = '1'

    # Scenario A: full interactive flow (Hub URL prompt, browser-approved
    # enrollment, bridge startup, vault password).
    #
    # INVERTED (REQ-ENROLL-9): the `hbe_abc123xyz` line is GONE. There is nothing
    # secret to type any more --- that is the whole point of the requirement, and the
    # shrinking of this heredoc from five lines to four is the clearest statement of
    # it in this suite. Feeding a token line to a prompt that no longer exists would
    # desynchronise every answer after it, so this is a correctness fix as well as a
    # semantic one.
    simulated_inputs = (
        "  http://my-test-hub.example.com///  \n"
        "y\n"
        "test-secret-password\n"
        "test-secret-password\n"
    )

    test_harness = (
        f'source <(sed "/^main \\"\\$@\\"/d" "{INSTALL_SCRIPT}")\n'
        f'service_home="{home}"\n'
        f'install_dir="{bin_dir}"\n'
        'os="linux"\n'
        'service_user=""\n'
        'path_needs_action=false\n'
        'hub_url=""\n'
        'run_interactive_onboarding\n'
        'echo "END_TEST_HUB_URL: $hub_url"\n'
    )

    proc = subprocess.run(
        ['bash', '-c', test_harness],
        input=simulated_inputs,
        text=True,
        capture_output=True,
        env=env,
        timeout=60,
    )
    assert proc.returncode == 0, f'interactive onboarding failed:\n{proc.stderr}'
    out = proc.stdout + proc.stderr
    assert 'Enter Hub URL:' in out, 'Missing Hub URL prompt'
    assert 'END_TEST_HUB_URL: http://my-test-hub.example.com' in out, 'Hub URL trailing slashes or spaces not cleaned'
    # INVERTED (REQ-ENROLL-9): was `'Enter one-time enrollment token (hbe_...):' in out`.
    # The operator is told what will happen before it happens --- a link, a short code,
    # a fingerprint to compare --- because an unexplained code on screen is
    # indistinguishable from a phishing prompt.
    assert 'Enrolling node (browser approval required)' in out, (
        'Missing device-flow enrollment banner')
    assert 'Nothing secret is copied between machines' in out, (
        'onboarding did not state that no secret is copied')
    # The ceremony ham-bridge itself prints must reach the operator's terminal rather
    # than being swallowed by the installer: an approval code nobody can see cannot be
    # approved.
    assert 'User code: WDJB-MJHT' in out, "ham-bridge's user code was not surfaced"
    # The absence half --- this is the half that catches a revert.
    assert 'Enter one-time enrollment token' not in out, 'deleted token prompt reappeared'
    assert 'hbe_' not in out, 'deleted hbe_ token vocabulary reappeared'
    assert 'Node successfully enrolled.' in out, 'Missing enrollment success message'
    # ARGV, not stdout: proof the device flow was invoked with the Hub origin and a
    # credential destination.
    argv = mock_bridge_argv.read_text() if mock_bridge_argv.exists() else ''
    assert 'enroll --hub http://my-test-hub.example.com' in argv, (
        f'ham-bridge was not invoked as `enroll --hub <origin>`:\n{argv}')
    assert '--bridge-token-file' in argv, (
        f'ham-bridge enroll was not told where to write the credential:\n{argv}')
    assert '--enrollment-token' not in argv, (
        f'installer passed the deleted --enrollment-token flag:\n{argv}')
    assert ('Bridge service started via systemctl --user.' in out or 'Bridge service restarted via systemctl --user.' in out), 'Missing bridge service start message'
    assert 'Enrollment verified: bridge token is present' in out, 'Missing bridge token verification'
    assert 'Bridge service is running (active).' in out, 'Missing bridge active verification'
    assert 'Vault encryption successfully configured.' in out, 'Missing vault success message'

    # The credential is delivered by `ham-bridge enroll` directly now, not pasted in
    # by the operator. This asserts the installer pointed the device flow at the right
    # destination and that something landed there --- deliberately NOT a credential
    # FORMAT assertion, because the format is REQ-IMPL-3's business and this test's
    # subject is the installer's ceremony. What it does pin is that the `hbe_` token
    # is not what lands there.
    token_file = home / '.config' / 'heimdall' / 'bridge-token'
    assert token_file.exists(), 'Bridge credential file was not written by the device flow'
    credential = token_file.read_text()
    assert 'mock-device-flow-credential' in credential, (
        f'credential was not delivered by `ham-bridge enroll`: {credential!r}')
    assert 'hbe_' not in credential, (
        f'deleted hbe_ one-time token was written as the credential: {credential!r}')
    vault_file = home / '.config' / 'heimdall' / 'vault_status'
    assert vault_file.exists() and 'test-secret-password' in vault_file.read_text(), 'Vault password was not delivered'

    # Scenario B: Existing token pre-check skips enrollment
    simulated_inputs_b = "n\n"
    test_harness_b = (
        f'source <(sed "/^main \\"\\$@\\"/d" "{INSTALL_SCRIPT}")\n'
        f'service_home="{home}"\n'
        f'install_dir="{bin_dir}"\n'
        'os="linux"\n'
        'service_user=""\n'
        'path_needs_action=false\n'
        'hub_url="http://existing-hub.example.com"\n'
        'run_interactive_onboarding\n'
    )
    proc_b = subprocess.run(
        ['bash', '-c', test_harness_b],
        input=simulated_inputs_b,
        text=True,
        capture_output=True,
        env=env,
        timeout=60,
    )
    assert proc_b.returncode == 0, f'pre-check test failed:\n{proc_b.stderr}'
    out_b = proc_b.stdout + proc_b.stderr
    assert 'Found existing bridge token at' in out_b, 'Existing token was not reported'
    assert 'node is already enrolled.' in out_b, 'Existing enrollment message missing'
    assert 'Enter one-time enrollment token' not in out_b, 'Prompted for token when already enrolled'
    assert 'Client vault encryption skipped.' in out_b, 'Opt-out message missing'


def test_install_sh_enrollment_noninteractive_invariants(ctx):
    """REQ-INST-ENROLL-5, REQ-INST-ENROLL-6: Non-interactive pipeline, subshell,
    CI, and flag invariants for scripts/install.sh.
    Ensures that when stdin is not a tty, or when HEIMDALL_NON_INTERACTIVE=1,
    DEBIAN_FRONTEND=noninteractive, --dry-run, or --uninstall are set,
    interactive prompts are cleanly bypassed and fallback instructions are printed."""
    work = ctx['work'] / 'noninteractive-enroll'
    home = work / 'home'
    runtime = work / 'runtime'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)

    # 1. Non-interactive stdin via pipe/subprocess must skip prompts and print onboarding
    env = sandbox_install_env(home, runtime)
    res_dry = run(['bash', str(INSTALL_SCRIPT), '--dry-run'], env=env, timeout=60)
    assert res_dry.returncode == 0, f'--dry-run failed:\n{res_dry.stderr}'
    assert 'Enter Hub URL:' not in res_dry.stdout, '--dry-run must not prompt for Hub URL'
    assert 'Enter one-time enrollment token' not in res_dry.stdout, '--dry-run must not prompt for enrollment token'
    assert 'Do you wish to enable client vault encryption?' not in res_dry.stdout, '--dry-run must not prompt for vault'

    # 2. Run the standalone enrollment suite (17 tests; Test 14 was deleted --- see
    #    its tombstone in that file for why a pty test that reached the real session
    #    bus is never coming back in that shape).
    test_script = ROOT / 'tests' / 'test_installer_enrollment.sh'
    assert test_script.exists(), 'test_installer_enrollment.sh missing'
    res_script = run(['bash', str(test_script)], env=env, timeout=120)
    assert res_script.returncode == 0, (
        f'test_installer_enrollment.sh failed (exit={res_script.returncode}):\n'
        f'stdout:\n{res_script.stdout}\nstderr:\n{res_script.stderr}'
    )


def main() -> int:
    tests = [
        ('tarball structure + METADATA.json schema', test_tarball_structure_and_metadata),
        ('tarball without pty-host (5-arg variant)', test_tarball_without_pty_host),
        ('packaging error cases', test_packaging_error_cases),
        ('SHA256SUMS validation + tamper fail-closed', test_sha256sums_validation),
        ('install.sh syntax (bash -n)', test_install_sh_syntax),
        ('release build skips when Nix is absent (REQ-INST-16)',
         test_release_build_skips_without_nix),
        ('release gate rejects Nix wrapper scripts (REQ-INST-16)',
         test_release_gate_rejects_nix_wrapper),
        ('release gate rejects dynamic ELF binaries (REQ-INST-16)',
         test_release_gate_rejects_dynamic_elf),
        ('release gate rejects a shared libcurl (static libcurl)',
         test_release_gate_rejects_shared_libcurl),
        ('storeless execution gate has teeth (REQ-INST-16)', test_storeless_exec_has_teeth),
        ('termux-arm64 tarball target (T12)', test_termux_tarball_target),
        ('seccomp probe denylist is bionic-verified (T12)',
         test_seccomp_probe_denylist_is_bionic_verified),
        ('seccomp probe never passes untraced (T12)', test_seccomp_probe_never_passes_untraced),
        ('seccomp probe has teeth (T12)', test_seccomp_probe_has_teeth),
    ]
    if os.environ.get('HEIMDALL_TEST_NIX_RELEASE_BUILD') == '1':
        tests.extend([
            ('build release attrs (nix, REQ-INST-16)', build_release_attrs),
            ('release binaries: no /nix/store references (REQ-INST-16)',
             test_release_binaries_have_no_nix_references),
            ('release tarball: package + storeless execution (REQ-INST-16)',
             test_release_tarball_is_portable),
            ('termux release binaries pass seccomp probe (T12)',
             test_termux_release_binaries_pass_seccomp_probe),
        ])

    filter_pattern = sys.argv[1].lower() if len(sys.argv) > 1 else None
    if filter_pattern:
        tests = [(name, fn) for name, fn in tests if filter_pattern in name.lower()]

    ctx = {}
    work = Path(tempfile.mkdtemp(prefix='heimdall-dist-test-'))
    ctx['work'] = work
    ctx['work2'] = Path(tempfile.mkdtemp(prefix='heimdall-dist-test2-'))
    try:
        failures = []
        skips = []
        for name, fn in tests:
            before = snapshot_live_home()
            outcome = None
            try:
                fn(ctx)
            except Skip as skipped:
                outcome = ('skip', str(skipped))
            except (AssertionError, subprocess.TimeoutExpired, OSError) as exc:
                outcome = ('fail', str(exc))
            # REQ-INST-19: checked after a PASS, a FAIL and a SKIP alike — a
            # test that escaped its sandbox and then skipped still escaped,
            # and a tripped wire always downgrades the result to a failure.
            try:
                assert_live_home_untouched(before, name)
            except AssertionError as exc:
                outcome = ('fail', str(exc))
            if outcome is None:
                print(f'PASS: {name}')
            elif outcome[0] == 'skip':
                skips.append((name, outcome[1]))
                print(f'SKIP: {name} ({outcome[1]})')
            else:
                failures.append((name, outcome[1]))
                print(f'FAIL: {name}: {outcome[1]}')
        print()
        for name, _ in skips:
            print(f'skipped: {name}')
        if failures:
            print('FAILED:')
            for name, message in failures:
                print(f'- {name}: {message}')
            return 1
        print('BINARY DISTRIBUTION TEST PASSED '
              f'({len(tests) - len(skips)} passed, {len(skips)} skipped)')
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(ctx['work2'], ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
