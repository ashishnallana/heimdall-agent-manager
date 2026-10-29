#!/usr/bin/env python3
"""Hermetic tests of the thin bootstraps (scripts/install.sh, scripts/install.ps1).

install.sh only resolves a release, downloads + SHA-256 verifies the bundle and
runs `ham-bridge setup --headless` with the remaining flags. A mock `curl` on
PATH serves a fake GitHub release list and release assets from a temp dir, and the
bundle's bin/ham-bridge is a stub that records its argv, so nothing is downloaded,
installed or enrolled.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'scripts/install.sh'
INSTALLER_PS1 = ROOT / 'scripts/install.ps1'
REPO = 'tanmayv/heimdall-agent-manager'

MOCK_CURL = r'''#!/usr/bin/env bash
# Maps the URLs install.sh fetches onto $MOCK_ROOT/www; anything else is a 404.
url='' out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --connect-timeout|--max-time|--speed-limit|--speed-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$MOCK_ROOT/curl.log"
case "$url" in
  https://api.github.com/repos/*/releases\?*) src="$MOCK_ROOT/www/releases.json" ;;
  https://github.com/*/releases/download/*) src="$MOCK_ROOT/www/download/${url#*/releases/download/}" ;;
  *) src='' ;;
esac
[ -n "$src" ] && [ -f "$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$src" "$out"
'''

STUB_BRIDGE = '#!/bin/sh\nprintf "%s\\n" "$*" >> "$MOCK_ROOT/ham-bridge.log"\nexit "${STUB_EXIT:-0}"\n'


def host_target():
    os_name = {'Linux': 'linux', 'Darwin': 'darwin'}[platform.system()]
    arch = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}[platform.machine()]
    return f'{os_name}-{arch}'


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='heimdall-bootstrap-test-')
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home with spaces'
        self.home.mkdir()
        mock = self.root / 'mock'
        mock.mkdir()
        (mock / 'curl').write_text(MOCK_CURL)
        (mock / 'curl').chmod(0o755)
        self.target = host_target()
        base = {k: v for k, v in os.environ.items() if not k.startswith('HEIMDALL_') and k not in ('TERMUX_VERSION', 'PREFIX')}
        self.env = dict(base, HOME=str(self.home), PATH=f'{mock}:{os.environ["PATH"]}',
                        MOCK_ROOT=str(self.root), TMPDIR=str(self.root))
        self.releases = []

    def tearDown(self):
        self.tmp.cleanup()

    def bundle_bytes(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as tf:
            data = STUB_BRIDGE.encode()
            info = tarfile.TarInfo('bin/ham-bridge')
            info.size, info.mode = len(data), 0o755
            tf.addfile(info, io.BytesIO(data))
        return buf.getvalue()

    def publish(self, tag, *, prerelease=False, draft=False, sums=True, bundle=True, tamper=False):
        name = f'heimdall-local-{self.target}-{tag}.tar.gz'
        d = self.root / 'www' / 'download' / tag
        d.mkdir(parents=True)
        data = self.bundle_bytes()
        assets = []
        if bundle:
            (d / name).write_bytes(data + (b'x' if tamper else b''))
            assets.append({'name': name})
        if sums:
            (d / 'SHA256SUMS').write_text(f'{hashlib.sha256(data).hexdigest()}  {name}\n')
            assets.append({'name': 'SHA256SUMS'})
        self.releases.append({'tag_name': tag, 'draft': draft, 'prerelease': prerelease, 'assets': assets})
        (self.root / 'www' / 'releases.json').write_text(json.dumps(self.releases))
        return d / name, d / 'SHA256SUMS'

    def run_installer(self, *args, stdin_script=False, extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        if stdin_script:
            return subprocess.run(['bash', '-s', '--', *args], input=INSTALLER.read_text(),
                                  env=env, capture_output=True, text=True, timeout=60)
        return subprocess.run(['bash', str(INSTALLER), *args], env=env, capture_output=True,
                              text=True, timeout=60, stdin=subprocess.DEVNULL)

    def bridge_calls(self):
        log = self.root / 'ham-bridge.log'
        return log.read_text().splitlines() if log.exists() else []

    def assert_clean(self):
        # The temporary download/unpack directory is always removed.
        self.assertEqual([p.name for p in self.root.glob('heimdall-install.*')], [])

    def test_latest_promoted_release_runs_setup_with_passthrough(self):
        self.publish('v1.1.0', prerelease=True)
        self.publish('v1.0.0')
        res = self.run_installer('--hub', 'https://hub.example.com', '--name', 'bob', '--new-bridge')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://hub.example.com --profile bob --new-bridge'])
        self.assertIn(f'releases/download/v1.0.0/heimdall-local-{self.target}-v1.0.0.tar.gz',
                      (self.root / 'curl.log').read_text())
        self.assert_clean()

    def test_curl_pipe_bash(self):
        self.publish('v1.0.0')
        res = self.run_installer('--hub', 'https://hub.example.com', stdin_script=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://hub.example.com'])

    def test_explicit_version_may_be_prerelease(self):
        self.publish('v1.0.0')
        self.publish('v1.1.0-rc1', prerelease=True)
        res = self.run_installer('--version', 'v1.1.0-rc1', '--hub', 'https://h')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('/v1.1.0-rc1/', (self.root / 'curl.log').read_text())

    def test_tampered_bundle_is_refused_before_ham_bridge_runs(self):
        self.publish('v1.0.0', tamper=True)
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 1)
        self.assertIn('SHA-256 verification failed', res.stderr)
        self.assertEqual(self.bridge_calls(), [])
        self.assert_clean()

    def test_unknown_or_unverifiable_release_is_refused(self):
        self.publish('v1.0.0')
        res = self.run_installer('--version', 'v9.9.9', '--hub', 'https://h')
        self.assertEqual(res.returncode, 1)
        self.assertIn('no SHA256SUMS', res.stderr)
        res = self.run_installer('--version', '../x', '--hub', 'https://h')
        self.assertIn('Invalid release tag', res.stderr)
        self.assertEqual(self.bridge_calls(), [])

    def test_no_promoted_release_for_target(self):
        self.publish('v1.0.0', sums=False)
        self.publish('v0.9.0', draft=True)
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 1)
        self.assertIn('No promoted release', res.stderr)

    def test_uninstall_runs_ham_bridge_uninstall(self):
        self.publish('v1.0.0')
        res = self.run_installer('--uninstall', '--hub', 'https://h', '--purge')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['uninstall --hub https://h --purge'])

    def test_local_bundle_is_verified_and_target_checked(self):
        bundle, sums = self.publish('v1.0.0')
        res = self.run_installer('--bundle', str(bundle), '--checksum-file', str(sums), '--hub', 'https://h')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse((self.root / 'curl.log').exists(), 'a local bundle needs no download')
        other = self.root / 'heimdall-local-plan9-amd64-v1.0.0.tar.gz'
        other.write_bytes(bundle.read_bytes())
        res = self.run_installer('--bundle', str(other), '--checksum-file', str(sums), '--hub', 'https://h')
        self.assertEqual(res.returncode, 1)
        self.assertIn('not for this machine', res.stderr)

    def test_ham_bridge_failure_is_the_exit_code(self):
        self.publish('v1.0.0')
        res = self.run_installer('--hub', 'https://h', extra_env={'STUB_EXIT': '3'})
        self.assertEqual(res.returncode, 3)
        self.assert_clean()

    def test_bootstraps_hold_no_install_logic(self):
        """REQ-ENR-5: download + verify + exec only; the lifecycle lives in ham-bridge."""
        sh = INSTALLER.read_text()
        for word in ('systemctl', 'launchctl', 'LaunchAgents', 'enroll.sh', 'sv-enable', 'apply-bridge-update', '/public/'):
            self.assertNotIn(word, sh)
        self.assertEqual([l for l in sh.splitlines() if l.strip()][-1], 'main "$@"')
        ps1 = INSTALLER_PS1.read_text()
        self.assertTrue(ps1.isascii(), 'install.ps1 must be pure ASCII (PowerShell 5.1)')
        for word in ('Register-ScheduledTask', 'schtasks', 'enroll.ps1', 'apply-bridge-update', 'Set-Acl'):
            self.assertNotIn(word, ps1)
        self.assertIn("'setup', '--headless'", ps1)
        # The same promoted-release rule on both sides.
        self.assertIn('-not $r.draft -and -not $r.prerelease', ps1)
        self.assertTrue(re.search(r'releases\?per_page=30', ps1))


if __name__ == '__main__':
    unittest.main()
