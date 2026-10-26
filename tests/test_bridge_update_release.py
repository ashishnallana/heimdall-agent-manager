#!/usr/bin/env python3
"""Release-to-supervisor checks without host services or network access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BridgeUpdateReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='heimdall-update-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root/'home with spaces'
        self.data = self.home/'data/bridges/brg_actual'
        self.stage = self.root/'stage'
        self.mock = self.root/'mock'
        for path in (self.home, self.data/'bin', self.stage/'bin', self.mock):
            path.mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.mock)+':'+os.environ['PATH'])
        for key in ('SERVICE_NAME', 'HEIMDALL_BRIDGE_SERVICE_NAME', 'RESTART_HOOK', 'STOP_HOOK', 'BRIDGE_PID', 'TERMUX_VERSION', 'PREFIX'):
            self.env.pop(key, None)
        self.log = self.root/'commands.jsonl'
        self.env['UPDATE_TEST_LOG'] = str(self.log)
        # The supervisor must run without python3 or perl: both are stubs that
        # record the call and fail. Python mocks run sys.executable directly.
        self.forbidden = self.root/'forbidden'
        self.env['UPDATE_TEST_FORBIDDEN'] = str(self.forbidden)
        for tool in ('python3', 'python', 'perl'):
            self.stub(tool, '#!/bin/sh\necho "$0 $*" >> "$UPDATE_TEST_FORBIDDEN"\nexit 127\n')
        self.addCleanup(self.assert_no_forbidden_calls)
        self.stub('systemctl', '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['UPDATE_TEST_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if 'show' in sys.argv: print('loaded')
''')
        self.stub('curl', '#!/bin/sh\nprintf "${UPDATE_TEST_HTTP:-200}"\n')
        self.stub('uname', '#!/bin/sh\nprintf "Linux\\n"\n')
        for binary in ('ham-bridge', 'ham-ctl', 'ham-pty-host', 'heimdall'):
            self.write(self.data/'bin'/binary, '#!/bin/sh\necho old\n')
            self.write(self.stage/'bin'/binary, '#!/bin/sh\necho new\n')
        self.shim = self.data/'bin/ham-ctl-brg_actual'
        self.shim_text = '#!/bin/sh\nexec "'+str(self.data/'bin/ham-ctl')+'" "$@"\n'
        self.write(self.shim, self.shim_text)
        units = self.home/'.config/systemd/user'
        units.mkdir(parents=True)
        (units/'brg_actual.service').write_text('[Service]\nExecStart="'+str(self.data/'bin/ham-bridge')+'" --config "installation config"\n')

    def write(self, path, text):
        # Python mocks and fixture hosts name this interpreter: python3 on the
        # supervisor's PATH is a failing stub.
        path.write_text(text.replace('#!/usr/bin/env python3\n', '#!'+sys.executable+'\n', 1))
        path.chmod(0o755)

    def stub(self, name, text):
        self.write(self.mock/name, text)

    def assert_no_forbidden_calls(self):
        calls = self.forbidden.read_text() if self.forbidden.exists() else ''
        self.assertEqual(calls, '', 'the supervisor ran python3/perl')

    def apply(self, **env):
        return subprocess.run(['bash', str(ROOT/'scripts/apply-bridge-update.sh'),
                               '--data-dir', str(self.data), '--stage-dir', str(self.stage),
                               '--health-timeout', '1'], env=dict(self.env, **env),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_discovers_bridge_id_service_and_preserves_executable_shim(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(['--user', 'stop', 'brg_actual.service'], self.commands())
        self.assertIn(['--user', 'restart', 'brg_actual.service'], self.commands())
        self.assertEqual(self.shim.read_text(), self.shim_text)
        self.assertEqual(subprocess.check_output([str(self.shim)], text=True).strip(), 'new')

    def test_service_environment_routes_per_hub_installation(self):
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='heimdall-bridge-hub-example.service')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(['--user', 'restart', 'heimdall-bridge-hub-example.service'], self.commands())

    def test_macos_restart_uses_launchagent_label(self):
        self.stub('uname', '#!/bin/sh\nprintf "Darwin\n"\n')
        self.stub('launchctl', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['UPDATE_TEST_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
""")
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='heimdall-bridge-hub-example')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(['kickstart', '-k', f'gui/{os.geteuid()}/heimdall-bridge-hub-example'], self.commands())

    def test_missing_managed_service_fails_before_replacing_binaries(self):
        self.stub('systemctl', '#!/bin/sh\nprintf "not-found\\n"\n')
        old = (self.data/'bin/ham-bridge').read_bytes()
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='missing.service')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.data/'bin/ham-bridge').read_bytes(), old)
        self.assertEqual(self.shim.read_text(), self.shim_text)

    def test_rollback_restores_binaries_and_shim_on_same_service(self):
        old = (self.data/'bin/ham-bridge').read_bytes()
        result = self.apply(UPDATE_TEST_HTTP='503')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual((self.data/'bin/ham-bridge').read_bytes(), old)
        self.assertEqual(self.shim.read_text(), self.shim_text)
        self.assertEqual(self.commands().count(['--user', 'restart', 'brg_actual.service']), 2)
        self.assertEqual(subprocess.check_output([str(self.shim)], text=True).strip(), 'old')

    def test_incomplete_bundle_fails_before_service_stop(self):
        (self.stage/'bin/ham-pty-host').unlink()
        result = self.apply()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.log.exists())
        self.assertTrue(self.shim.exists())

    # REQ-T13-3: Termux has no systemd. The bridge is the termux-services
    # (runit) service $PREFIX/var/service/ham-bridge, driven with sv.
    def termux(self):
        prefix = self.root/'termux-prefix'
        runit = prefix/'var/service/ham-bridge'
        runit.mkdir(parents=True)
        self.write(runit/'run', '#!/bin/sh\nexec "'+str(self.data/'bin/ham-bridge')+'" --hub https://hub.example\n')
        self.stub('sv', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['UPDATE_TEST_LOG'], 'a') as f: f.write(json.dumps(['sv']+sys.argv[1:])+'\\n')
""")
        self.stub('systemctl', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['UPDATE_TEST_LOG'], 'a') as f: f.write(json.dumps(['systemctl']+sys.argv[1:])+'\\n')
sys.exit(1)
""")
        (self.stage/'METADATA.json').write_text(json.dumps({'product': 'heimdall-local', 'target': 'termux-arm64'}))
        return runit, dict(TERMUX_VERSION='0.118.0', PREFIX=str(prefix))

    def test_termux_refuses_non_termux_bundle_before_stopping(self):
        _, env = self.termux()
        old = (self.data/'bin/ham-bridge').read_bytes()
        for metadata in ({'target': 'linux-arm64'}, None):
            with self.subTest(metadata=metadata):
                if metadata is None:
                    (self.stage/'METADATA.json').unlink()
                else:
                    (self.stage/'METADATA.json').write_text(json.dumps(metadata))
                result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', **env)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('only termux-* bundles run on Android', result.stdout)
                self.assertEqual((self.data/'bin/ham-bridge').read_bytes(), old)
                self.assertFalse(self.log.exists(), 'service never touched')

    def test_linux_ignores_bundle_target_metadata(self):
        (self.stage/'METADATA.json').write_text(json.dumps({'target': 'linux-amd64'}))
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_termux_runit_service_restarts_with_sv_never_systemctl(self):
        runit, env = self.termux()
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', **env)
        self.assertEqual(result.returncode, 0, result.stdout)
        commands = self.commands()
        self.assertEqual(commands, [['sv', 'down', str(runit)], ['sv', 'up', str(runit)]])
        self.assertEqual(subprocess.check_output([str(self.data/'bin/ham-bridge')], text=True).strip(), 'new')

    def test_termux_runit_service_is_discovered_from_run_file(self):
        runit, env = self.termux()
        result = self.apply(**env)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('SERVICE_NAME:   ham-bridge', result.stdout)
        self.assertEqual(self.commands(), [['sv', 'down', str(runit)], ['sv', 'up', str(runit)]])

    def test_termux_rollback_uses_sv(self):
        runit, env = self.termux()
        old = (self.data/'bin/ham-bridge').read_bytes()
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', UPDATE_TEST_HTTP='503', **env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual((self.data/'bin/ham-bridge').read_bytes(), old)
        commands = self.commands()
        self.assertFalse([c for c in commands if c[0] == 'systemctl'], commands)
        self.assertEqual(commands.count(['sv', 'up', str(runit)]), 2)

    def test_termux_missing_runit_service_fails_before_replacing_binaries(self):
        runit, env = self.termux()
        (runit/'run').unlink()
        old = (self.data/'bin/ham-bridge').read_bytes()
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', **env)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('Managed runit service not found', result.stdout)
        self.assertEqual((self.data/'bin/ham-bridge').read_bytes(), old)
        self.assertFalse(self.log.exists())

    def test_termux_bridge_pid_is_stopped_through_sv_down(self):
        runit, env = self.termux()
        bridge = subprocess.Popen(['sleep', '30'])
        self.addCleanup(bridge.kill)
        # The sv stub records the call; a real `sv down` TERMs the supervised
        # bridge, which the stub emulates by killing the PID it was given.
        self.stub('sv', """#!/usr/bin/env python3
import json, os, signal, sys
with open(os.environ['UPDATE_TEST_LOG'], 'a') as f: f.write(json.dumps(['sv']+sys.argv[1:])+'\\n')
if sys.argv[1] == 'down': os.kill(int(os.environ['BRIDGE_PID']), signal.SIGTERM)
""")
        result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', BRIDGE_PID=str(bridge.pid), **env)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.commands()[0], ['sv', 'down', str(runit)])
        self.assertEqual(bridge.wait(timeout=5), -15)

    def start_host(self, binary, socket, marker):
        source = """#!/usr/bin/env python3
import signal, subprocess, sys, time
from pathlib import Path
if 'stop' in sys.argv: sys.exit(0)
child = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(120)'])
signal.signal(signal.SIGTERM,signal.SIG_IGN)
Path(sys.argv[sys.argv.index('--marker')+1]).write_text(str(child.pid))
while True: time.sleep(1)
"""
        binary.parent.mkdir(parents=True, exist_ok=True)
        self.write(binary, source)
        process = subprocess.Popen([str(binary), 'daemon', '--socket', str(socket), '--marker', str(marker)])
        self.addCleanup(process.wait)
        self.addCleanup(self.stop_process, process.pid)
        import time
        for _ in range(50):
            if marker.exists(): break
            time.sleep(0.02)
        self.assertTrue(marker.exists())
        child = int(marker.read_text())
        self.addCleanup(self.stop_process, child)
        return process, child

    @staticmethod
    def stop_process(pid):
        import signal
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass

    @staticmethod
    def process_alive(pid):
        try:
            return (Path('/proc')/str(pid)/'stat').read_text().rsplit(')',1)[1].split()[0] != 'Z'
        except FileNotFoundError: return False

    @unittest.skipUnless(Path('/proc').exists(), 'process isolation fixture uses Linux procfs')
    def test_kills_live_and_stale_private_hosts_and_children_only_for_target_bridge(self):
        live, live_child = self.start_host(self.data/'bin/ham-pty-host', self.root/'live.sock', self.root/'live.pid')
        stale, stale_child = self.start_host(self.data/'bin/ham-pty-host', self.root/'stale.sock', self.root/'stale.pid')
        other, other_child = self.start_host(self.home/'data/bridges/brg_other/bin/ham-pty-host', self.root/'other.sock', self.root/'other.pid')
        # Running hosts retain an old executable path after a previous replacement.
        (self.data/'bin/ham-pty-host').unlink()
        self.write(self.data/'bin/ham-pty-host', '#!/bin/sh\nexit 0\n')
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout)
        for pid in (live.pid, live_child, stale.pid, stale_child):
            self.assertFalse(self.process_alive(pid), result.stdout)
        for pid in (other.pid, other_child):
            self.assertTrue(self.process_alive(pid), result.stdout)

    @unittest.skipUnless(Path('/proc').exists(), 'process isolation fixture uses Linux procfs')
    def test_shared_binary_is_scoped_by_exact_socket(self):
        shared = self.root/'shared/bin/ham-pty-host'
        target, child = self.start_host(shared, self.root/'target.sock', self.root/'target.pid')
        other, other_child = self.start_host(shared, self.root/'other.sock', self.root/'other.pid')
        result = subprocess.run(['bash', str(ROOT/'scripts/apply-bridge-update.sh'),
                                 '--data-dir', str(self.data), '--stage-dir', str(self.stage),
                                 '--pty-host-socket', str(self.root/'target.sock'), '--health-timeout', '1'],
                                env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.process_alive(target.pid), result.stdout)
        self.assertFalse(self.process_alive(child), result.stdout)
        self.assertTrue(self.process_alive(other.pid), result.stdout)
        self.assertTrue(self.process_alive(other_child), result.stdout)

    @unittest.skipUnless(Path('/proc').exists(), 'process isolation fixture uses Linux procfs')
    def test_stop_only_cleanup_needs_no_bundle_and_preserves_other_bridge(self):
        target, child = self.start_host(self.data/'bin/ham-pty-host', self.root/'target.sock', self.root/'target.pid')
        other, other_child = self.start_host(self.home/'data/bridges/brg_other/bin/ham-pty-host', self.root/'other.sock', self.root/'other.pid')
        result = subprocess.run(['bash', str(ROOT/'scripts/apply-bridge-update.sh'),
                                 '--data-dir', str(self.data), '--stop-pty-hosts-only'],
                                env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.process_alive(target.pid), result.stdout)
        self.assertFalse(self.process_alive(child), result.stdout)
        self.assertTrue(self.process_alive(other.pid), result.stdout)
        self.assertTrue(self.process_alive(other_child), result.stdout)
        self.assertTrue(self.shim.exists())
        self.assertFalse(self.log.exists())

    def stop_only(self, *args, **env):
        # NixOS bridge units carry only their declared PATH, which may have no
        # python3: setUp shadows it with a failing one for the supervisor. The
        # fixture hosts above were started with the real interpreter.
        return subprocess.run(['bash', str(ROOT/'scripts/apply-bridge-update.sh'),
                               '--data-dir', str(self.data), '--stop-pty-hosts-only', *args],
                              env=dict(self.env, **env),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)

    @unittest.skipUnless(Path('/proc').exists(), 'process isolation fixture uses Linux procfs')
    def test_stop_only_cleanup_without_python3_keeps_ownership_scope(self):
        live, live_child = self.start_host(self.data/'bin/ham-pty-host', self.root/'live.sock', self.root/'live.pid')
        stale, stale_child = self.start_host(self.data/'bin/ham-pty-host', self.root/'stale.sock', self.root/'stale.pid')
        other, other_child = self.start_host(self.home/'data/bridges/brg_other/bin/ham-pty-host', self.root/'other.sock', self.root/'other.pid')
        shared = self.root/'shared/bin/ham-pty-host'
        target, target_child = self.start_host(shared, self.root/'target.sock', self.root/'target.pid')
        unrelated, unrelated_child = self.start_host(shared, self.root/'unrelated.sock', self.root/'unrelated.pid')
        (self.data/'bin/ham-pty-host').unlink()
        self.write(self.data/'bin/ham-pty-host', '#!/bin/sh\nexit 0\n')
        result = self.stop_only('--pty-host-socket', str(self.root/'target.sock'))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('(found through procfs)', result.stdout)
        self.assertIn('stopping bridge-owned PTY processes:', result.stdout)
        for pid in (live.pid, live_child, stale.pid, stale_child, target.pid, target_child):
            self.assertFalse(self.process_alive(pid), result.stdout)
        for pid in (other.pid, other_child, unrelated.pid, unrelated_child):
            self.assertTrue(self.process_alive(pid), result.stdout)
        self.assertFalse(self.log.exists())

    @unittest.skipUnless(Path('/proc').exists(), 'process isolation fixture uses Linux procfs')
    def test_stop_only_cleanup_without_python3_and_no_hosts_succeeds(self):
        other, other_child = self.start_host(self.home/'data/bridges/brg_other/bin/ham-pty-host', self.root/'other.sock', self.root/'other.pid')
        result = self.stop_only()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('stopping bridge-owned PTY processes:', result.stdout)
        self.assertTrue(self.process_alive(other.pid), result.stdout)
        self.assertTrue(self.process_alive(other_child), result.stdout)

    # Hosts without /proc (macOS) are read through ps. Linux procps prints the
    # same columns; the shim rewrites a fixture host's command the way macOS ps
    # shows a native binary: argv joined with spaces, never quoted. It can also
    # fake a reused PID (new start time), a survivor, or a failing ps.
    def ps_reader(self, commands):
        real = shutil.which('ps')
        mapping = self.root/'ps-map'
        mapping.write_text(''.join(f'{pid}\t{command}\n' for pid, command in commands.items()))
        self.stub('ps', '''#!/usr/bin/env bash
[ -z "${PS_TEST_FAIL:-}" ] || exit 1
case " $* " in *" -axww "*) mode=list ;; *) mode=row ;; esac
requested=''
for arg in "$@"; do [ "$prev" = -p ] && requested=",$arg,"; prev="$arg"; done
out="$('''+real+''' "$@")"; status=$?
printf '%s\\n' "$out" | awk -v mode="$mode" -v map="$PS_TEST_MAP" -v reborn="${PS_TEST_REBORN:-}" \\
    -v ghost="${PS_TEST_GHOST:-}" -v ghostfile="$PS_TEST_MAP.ghost" '
  BEGIN { while ((getline line < map) > 0) { i = index(line, "\\t"); cmd[substr(line, 1, i - 1)] = substr(line, i + 1) } }
  $0 == "" { next }
  mode == "list" && $1 == ghost { print $1, $3, "S", $5, $6, $7, $8, $9 > ghostfile }
  mode == "list" && ($1 in cmd) { out = $1; for (k = 2; k <= 9; k++) out = out " " $k; print out " " cmd[$1]; next }
  mode == "row" && $1 == reborn { print $1, $2, $3, "Thu", "Jan", "1", "00:00:00", "1970"; next }
  mode == "row" && $1 == ghost { next }
  { print }'
if [ "$mode" = row ] && [ -n "${PS_TEST_GHOST:-}" ] && [[ "$requested" == *",$PS_TEST_GHOST,"* ]]; then
  cat "$PS_TEST_MAP.ghost"; exit 0
fi
exit $status
''')
        return dict(PTY_PROCESS_READER='ps', PS_TEST_MAP=str(mapping))

    @unittest.skipUnless(Path('/proc').exists(), 'process fixture uses Linux procfs to check liveness')
    def test_ps_reader_recovers_unquoted_argv_and_keeps_ownership_scope(self):
        live_bin = self.data/'bin/ham-pty-host'
        live, live_child = self.start_host(live_bin, self.root/'live.sock', self.root/'live.pid')
        other_bin = self.home/'data/bridges/brg_other/bin/ham-pty-host'
        other, other_child = self.start_host(other_bin, self.root/'other.sock', self.root/'other.pid')
        shared = self.root/'shared dir/bin/ham-pty-host'
        target_socket = self.root/'sock dir/target.sock'
        target, target_child = self.start_host(shared, target_socket, self.root/'target.pid')
        unrelated, unrelated_child = self.start_host(shared, self.root/'sock dir/other.sock', self.root/'unrelated.pid')
        env = self.ps_reader({
            live.pid: f'{live_bin} daemon --socket {self.root}/live.sock',
            other.pid: f'{other_bin} daemon --socket {self.root}/other.sock',
            target.pid: f'{shared} --socket {target_socket} daemon',
            unrelated.pid: f'{shared} daemon --socket {self.root}/sock dir/other.sock',
        })
        result = self.stop_only('--pty-host-socket', str(target_socket), **env)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('(found through ps)', result.stdout)
        for pid in (live.pid, live_child, target.pid, target_child):
            self.assertFalse(self.process_alive(pid), result.stdout)
        for pid in (other.pid, other_child, unrelated.pid, unrelated_child):
            self.assertTrue(self.process_alive(pid), result.stdout)

    @unittest.skipUnless(Path('/proc').exists(), 'process fixture uses Linux procfs to check liveness')
    def test_ps_reader_never_signals_a_reused_pid(self):
        host_bin = self.data/'bin/ham-pty-host'
        host, child = self.start_host(host_bin, self.root/'live.sock', self.root/'live.pid')
        env = self.ps_reader({host.pid: f'{host_bin} daemon --socket {self.root}/live.sock'})
        result = self.stop_only(PS_TEST_REBORN=str(host.pid), **env)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.process_alive(host.pid), 'a PID with a new start time is another process')
        self.assertFalse(self.process_alive(child), result.stdout)

    @unittest.skipUnless(Path('/proc').exists(), 'process fixture uses Linux procfs to check liveness')
    def test_ps_reader_refuses_swap_when_a_host_survives(self):
        host_bin = self.data/'bin/ham-pty-host'
        host, child = self.start_host(host_bin, self.root/'live.sock', self.root/'live.pid')
        env = self.ps_reader({host.pid: f'{host_bin} daemon --socket {self.root}/live.sock'})
        result = self.stop_only(PS_TEST_GHOST=str(host.pid), **env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('did not stop; refusing binary swap', result.stdout)
        self.assertFalse(self.process_alive(child), result.stdout)

    @unittest.skipUnless(Path('/proc').exists(), 'process fixture uses Linux procfs to check liveness')
    def test_cleanup_that_cannot_list_processes_exits_3_and_signals_nothing(self):
        host_bin = self.data/'bin/ham-pty-host'
        host, child = self.start_host(host_bin, self.root/'live.sock', self.root/'live.pid')
        env = self.ps_reader({host.pid: f'{host_bin} daemon --socket {self.root}/live.sock'})
        for case, extra in (('ps fails', dict(env, PS_TEST_FAIL='1')), ('no reader', dict(PTY_PROCESS_READER='none'))):
            with self.subTest(case):
                result = self.stop_only(**extra)
                self.assertEqual(result.returncode, 3, result.stdout)
                self.assertIn('no process was stopped', result.stdout)
                self.assertTrue(self.process_alive(host.pid))
                self.assertTrue(self.process_alive(child))

    def test_multiple_services_referencing_the_bridge_are_refused(self):
        units = self.home/'.config/systemd/user'
        (units/'legacy.service').write_text('[Service]\nExecStart='+str(self.data/'bin/ham-bridge').replace(' ', '\\ ')+'\n')
        old = (self.data/'bin/ham-bridge').read_bytes()
        result = self.apply()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('Multiple services reference this bridge; specify --service-name.', result.stdout)
        self.assertFalse(self.log.exists(), 'service never touched')
        self.assertEqual((self.data/'bin/ham-bridge').read_bytes(), old)

    def test_systemd_lookup_follows_shell_quoting_and_unit_escapes(self):
        data = self.home/"data/bridges/brg_50%$x 'q'"
        shutil.copytree(self.data, data, symlinks=True)
        self.data = data
        exe = str(data/'bin/ham-bridge')
        units = self.home/'.config/systemd/user'
        (units/'brg_actual.service').unlink()
        escaped = exe.replace('%', '%%').replace('$', '$$')
        (units/'decoy-unbalanced.service').write_text('[Service]\nExecStart="'+escaped+'\n')
        (units/'decoy-argument.service').write_text('[Service]\nExecStart=/bin/env "'+escaped+'"\n')
        (units/'decoy-indented.service').write_text('[Service]\n ExecStart="'+escaped+'"\n')
        (units/'decoy-unescaped.service').write_text('[Service]\nExecStart="'+exe.replace('$', '$$$$')+'"\n')
        quoted = escaped.replace("'", "\\'").replace(' ', '\\ ')
        (units/'actual.service').write_text('[Unit]\nDescription=x\r\n[Service]\nExecStartPre=/bin/true\nExecStart='+quoted+' --config "c d"\r\n')
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('SERVICE_NAME:   actual.service', result.stdout)
        self.assertIn(['--user', 'restart', 'actual.service'], self.commands())

    def launch_agents(self):
        import plistlib
        self.stub('uname', '#!/bin/sh\nprintf "Darwin\\n"\n')
        self.stub('launchctl', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['UPDATE_TEST_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
""")
        # plutil -extract KEYPATH raw|xml1 -o - FILE; PLUTIL_NO_RAW models macOS < 12.
        self.stub('plutil', """#!/usr/bin/env python3
import os, plistlib, sys
_, _, keypath, fmt, _, _, path = sys.argv
if fmt == 'raw' and os.environ.get('PLUTIL_NO_RAW'): sys.exit(1)
value = plistlib.loads(open(path, 'rb').read())
try:
    for key in keypath.split('.'): value = value[int(key)] if isinstance(value, list) else value[key]
except (KeyError, IndexError, ValueError): sys.exit(1)
if fmt == 'raw': print(value)
else: sys.stdout.write(plistlib.dumps(value).decode())
""")
        (self.home/'.config/systemd/user/brg_actual.service').unlink()
        agents = self.home/'Library/LaunchAgents'
        agents.mkdir(parents=True)
        def agent(name, label, program):
            (agents/name).write_bytes(plistlib.dumps({'Label': label, 'ProgramArguments': [program, '--config', 'x']}))
        agent('actual.plist', 'dev.heimdall.bridge & <hub>', str(self.data/'bin/ham-bridge'))
        agent('other.plist', 'dev.heimdall.other', str(self.home/'data/bridges/brg_other/bin/ham-bridge'))
        (agents/'broken.plist').write_text('not a plist')
        return agents

    def test_macos_discovers_launchagent_label_with_plutil(self):
        self.launch_agents()
        for case, env in (('raw', {}), ('xml1 fallback', dict(PLUTIL_NO_RAW='1'))):
            with self.subTest(case):
                (self.stage/'bin').mkdir(parents=True, exist_ok=True)
                for binary in ('ham-bridge', 'ham-ctl', 'ham-pty-host', 'heimdall'):
                    self.write(self.stage/'bin'/binary, '#!/bin/sh\necho new\n')
                self.log.unlink(missing_ok=True)
                result = self.apply(**env)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn(['kickstart', '-k', f'gui/{os.geteuid()}/dev.heimdall.bridge & <hub>'], self.commands())

    def test_macos_unit_and_launchagent_for_the_same_bridge_are_refused(self):
        self.launch_agents()
        units = self.home/'.config/systemd/user'
        (units/'brg_actual.service').write_text('[Service]\nExecStart="'+str(self.data/'bin/ham-bridge')+'"\n')
        result = self.apply()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('Multiple services reference this bridge', result.stdout)
        self.assertFalse(self.log.exists())

    def test_termux_reads_only_the_top_level_bundle_target(self):
        _, env = self.termux()
        metadata = self.stage/'METADATA.json'
        refused = {
            'nested decoy': json.dumps({'nested': {'target': 'termux-arm64'}, 'target': 'linux-arm64'}),
            'array decoy': json.dumps({'target': 'linux-arm64', 'x': ['termux-arm64', {'target': 'termux-arm64'}]}),
            'key in a string': '{"note": "\\"target\\": \\"termux-arm64\\"", "target": "linux-arm64"}',
            'not an object': json.dumps([{'target': 'termux-arm64'}]),
            'truncated': '{"target": "termux-arm64"',
            'not a string': json.dumps({'target': 7}),
            'no target': json.dumps({'nested': {'target': 'termux-arm64'}}),
            'earlier duplicate': '{"target": "termux-arm64", "target": "linux-arm64"}',
        }
        for case, text in refused.items():
            with self.subTest(case):
                metadata.write_text(text)
                result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', **env)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('only termux-* bundles run on Android', result.stdout)
                self.assertFalse(self.log.exists(), 'service never touched')
        accepted = {
            'pretty': json.dumps({'product': 'x', 'nested': {'target': 'linux-arm64'}, 'target': 'termux-arm64'}, indent=2),
            'escaped': '{"target":"termux-\\u0061rm64","t":"\\\\"}',
            'later duplicate': '{"target": "linux-arm64", "target": "termux-arm64"}',
        }
        for case, text in accepted.items():
            with self.subTest(case):
                self.stage.mkdir(exist_ok=True)
                (self.stage/'bin').mkdir(exist_ok=True)
                for binary in ('ham-bridge', 'ham-ctl', 'ham-pty-host', 'heimdall'):
                    self.write(self.stage/'bin'/binary, '#!/bin/sh\necho new\n')
                metadata.write_text(text)
                result = self.apply(HEIMDALL_BRIDGE_SERVICE_NAME='ham-bridge', **env)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn('BUNDLE_TARGET:  termux-arm64', result.stdout)

    def test_release_tarball_contains_executable_supervisor(self):
        outputs = []
        for binary in ('ham-bridge', 'ham-ctl', 'heimdall', 'ham-pty-host'):
            output = self.root/binary
            (output/'bin').mkdir(parents=True)
            self.write(output/'bin'/binary, '#!/bin/sh\nexit 0\n')
            outputs.append(str(output))
        out = self.root/'dist'
        result = subprocess.run(['bash', str(ROOT/'scripts/release/package-local-binary-tarball.sh'),
                                 'linux-amd64', '0.9.9', str(out), *outputs], cwd=ROOT,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout)
        with tarfile.open(out/'heimdall-local-linux-amd64.tar.gz') as archive:
            supervisor = archive.getmember('scripts/apply-bridge-update.sh')
            self.assertTrue(supervisor.isfile())
            self.assertEqual(supervisor.mode & 0o777, 0o755)
            self.assertEqual(archive.extractfile(supervisor).read(), (ROOT/'scripts/apply-bridge-update.sh').read_bytes())
            self.assertIn('bin/ham-pty-host', archive.getnames())


if __name__ == '__main__':
    unittest.main()
