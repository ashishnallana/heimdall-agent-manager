#!/usr/bin/env python3
"""Hermetic installer execution: no downloads, host services, or real enrollment."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import socket
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'scripts/install.sh'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='heimdall-installer-test-')
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home with spaces'
        self.home.mkdir()
        self.mock = self.root / 'mock'
        self.mock.mkdir()
        self.log = self.root / 'commands.jsonl'
        base = {k: v for k, v in os.environ.items() if not k.startswith('HEIMDALL_')}
        self.env = dict(base, HOME=str(self.home), PATH=str(self.mock)+':'+os.environ['PATH'],
                        MOCK_ROOT=str(self.root), MOCK_OS='Linux',
                        XDG_RUNTIME_DIR=str(self.root/'runtime'), DBUS_SESSION_BUS_ADDRESS='',
                        HEIMDALL_NON_INTERACTIVE='1')
        # The managed workspace denies AF_INET sockets. Simulate bind outcomes in
        # child processes only; no test can reach a host service or network.
        (self.mock/'sitecustomize.py').write_text("""import os, socket
if os.environ.get('MOCK_SOCKET'):
    class BoundSocket:
        held=set()
        def __init__(self,*args): self.port=None
        def bind(self,address):
            port=address[1]
            busy={int(p) for p in os.environ.get('BUSY_PORTS','').split(',') if p}
            if port in busy or port in self.held: raise OSError('Address in use')
            self.held.add(port); self.port=port
        def close(self):
            if self.port is not None: self.held.discard(self.port)
    socket.socket=BoundSocket
""")
        self.env.update(PYTHONPATH=str(self.mock),MOCK_SOCKET='1')
        self.stub('id', '#!/bin/sh\necho 1000\n')
        self.stub('uname', '#!/bin/sh\nif [ "$1" = -s ]; then echo "$MOCK_OS"; else echo "${MOCK_ARCH:-x86_64}"; fi\n')
        self.stub('socat', '#!/bin/sh\nexit 0\n')
        manager = '''#!/usr/bin/env python3
import json, os, pathlib, sys
r=pathlib.Path(os.environ['MOCK_ROOT'])
with (r/'commands.jsonl').open('a') as f: f.write(json.dumps([pathlib.Path(sys.argv[0]).name]+sys.argv[1:])+'\\n')
if pathlib.Path(sys.argv[0]).name=='launchctl':
    marker=r/'loaded'
    if sys.argv[1]=='bootstrap': marker.touch()
    if sys.argv[1]=='bootout' and marker.exists(): marker.unlink()
    if sys.argv[1]=='print' and sys.argv[2].count('/')>1 and not marker.exists(): sys.exit(1)
'''
        for tool in ('systemctl', 'launchctl', 'plutil'):
            self.stub(tool, manager)
        # MOCK_RELEASES overrides the release list; MOCK_SUM_TARGETS names the
        # bundles a release's SHA256SUMS lists; BAD_SUM (all) or BAD_SUM_TARGET
        # (one target) corrupts digests. Archive downloads append to downloads.
        self.stub('curl', '''#!/usr/bin/env python3
import hashlib, os, pathlib, sys
r=pathlib.Path(os.environ['MOCK_ROOT']); a=sys.argv[1:]; out=pathlib.Path(a[a.index('--output')+1]); url=a[a.index('--output')-1]
if '/releases?' in url:
    out.write_text(os.environ.get('MOCK_RELEASES') or '[{"tag_name":"vtest","prerelease":true,"assets":[{"name":"SHA256SUMS"},{"name":"heimdall-local-linux-amd64-vtest.tar.gz"},{"name":"heimdall-local-darwin-amd64-vtest.tar.gz"},{"name":"heimdall-local-linux-arm64-vtest.tar.gz"}]}]')
elif url.endswith('/SHA256SUMS'):
    version=url.rsplit('/',2)[1]; digest=hashlib.sha256((r/'bundle').read_bytes()).hexdigest()
    targets=os.environ.get('MOCK_SUM_TARGETS','linux-amd64,darwin-amd64,linux-arm64,darwin-arm64').split(',')
    bad=lambda t: os.environ.get('BAD_SUM') or os.environ.get('BAD_SUM_TARGET')==t
    out.write_text(''.join(('0'*64 if bad(t) else digest)+'  heimdall-local-'+t+'-'+version+'.tar.gz\\n' for t in targets))
else:
    with (r/'downloads').open('a') as f: f.write(url.rsplit('/',1)[1]+'\\n')
    out.write_bytes((r/'bundle').read_bytes())
''')
        bridge = b'''#!/usr/bin/env bash
if [ "$1" = enroll ]; then
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --bridge-token-file) token="$2";; esac
    shift 2
  done
  printf 'credential\\n' > "$token"
  printf 'approved by     alice\\n'
  if [ -n "${TERMUX_VERSION:-}" ] && [ -d "$PREFIX/var/service/ham-bridge" ]; then sv restart "$PREFIX/var/service/ham-bridge"
  elif [ "$MOCK_OS" = Linux ]; then systemctl --user restart heimdall-bridge
  else launchctl kickstart -k gui/1000/works.earendil.heimdall-bridge; fi
fi
'''
        ctl = b'''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['MOCK_ROOT']+'/ctl.json').write_text(json.dumps({'args':sys.argv[1:],'endpoint':os.environ.get('HEIMDALL_BRIDGE_ENDPOINT')}))
'''
        with tarfile.open(self.root/'bundle', 'w:gz') as t:
            for name in ('heimdall','ham-bridge','ham-pty-host','ham-ctl'):
                content = bridge if name=='ham-bridge' else ctl if name=='ham-ctl' else b'#!/bin/sh\nexit 0\n'
                m=tarfile.TarInfo('bin/'+name); m.size=len(content); m.mode=0o755
                t.addfile(m, io.BytesIO(content))
            content = (ROOT/'scripts/apply-bridge-update.sh').read_bytes()
            m=tarfile.TarInfo('scripts/apply-bridge-update.sh'); m.size=len(content); m.mode=0o755
            t.addfile(m, io.BytesIO(content))

    def tearDown(self):
        self.tmp.cleanup()

    def stub(self, name, text):
        p=self.mock/name; p.write_text(text); p.chmod(0o755)

    def termux(self):
        """Model a Termux install: $PREFIX with termux-services and Termux:API present."""
        prefix=self.root/'prefix'; (prefix/'var/service').mkdir(parents=True,exist_ok=True); (prefix/'bin').mkdir(exist_ok=True)
        (prefix/'share/termux-services').mkdir(parents=True,exist_ok=True)
        svlogger=prefix/'share/termux-services/svlogger'; svlogger.write_text('#!/bin/sh\nexit 0\n'); svlogger.chmod(0o755)
        self.env.update(TERMUX_VERSION='0.118.1', PREFIX=str(prefix), HEIMDALL_RUNSV_WAIT='0', MOCK_ARCH='aarch64')
        self.stub('termux-keystore','#!/bin/sh\nexit 0\n')
        self.stub('pgrep','#!/bin/sh\nexit 0\n')  # runsvdir is running
        sv='''#!/usr/bin/env python3
import json, os, pathlib, sys
r=pathlib.Path(os.environ['MOCK_ROOT']); me=pathlib.Path(sys.argv[0]).name
with (r/'commands.jsonl').open('a') as f: f.write(json.dumps([me]+sys.argv[1:])+'\\n')
root=pathlib.Path(os.environ['PREFIX'])/'var/service'
if me=='sv' and sys.argv[1]=='status':
    d=pathlib.Path(sys.argv[2]); d=d if d.is_absolute() else root/sys.argv[2]
    print('run: ham-bridge: (pid 123) 2s' if (d/'run').exists() and not (d/'down').exists() else 'down: ham-bridge: 1s')
if me=='sv-enable':
    down=root/sys.argv[1]/'down'
    if down.exists(): down.unlink()
'''
        self.stub('sv',sv); self.stub('sv-enable',sv)
        return prefix

    def run_install(self, *args, answers=None, success=True):
        if answers is None:
            command=['bash',str(INSTALLER),*args]
        else:
            # Override only terminal input; exercise the real prompt decision branches.
            lib=self.root/'installer-lib.sh'
            lib.write_text(INSTALLER.read_text().replace('main "$@"\n',''))
            self.env['HEIMDALL_NON_INTERACTIVE']='0'
            self.env['PROMPT_ANSWERS']=json.dumps(answers)
            (self.root/'answers').write_text('\n'.join(answers)+'\n')
            script='source '+shlex.quote(str(lib))+'\nexec 3< '+shlex.quote(str(self.root/'answers'))+'\nprompt() { printf "%s\\n" "$1"; IFS= read -r answer <&3; }\nmain "$@"'
            command=['bash','-c',script,'installer',*args]
        r=subprocess.run(command,env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
        if success: self.assertEqual(r.returncode,0,r.stdout)
        else: self.assertNotEqual(r.returncode,0,r.stdout)
        return r.stdout

    def state(self, name):
        return self.home/'.config/heimdall/bridges'/name

    def data(self, name):
        return self.home/'.local/share/heimdall/bridges'/name

    def commands(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_names(self):
        for hub, name in [('https://hub.mundus.in','hub-mundus-in'),('http://localhost:8080','localhost-8080'),
                          ('http://localhost:8081','localhost-8081'),('http://127.0.0.1:8080','127-0-0-1-8080'),
                          ('https://192.168.1.4','192-168-1-4'),('http://[::1]:8080','--1-8080'),
                          ('https://HUB.MUNDUS.IN:443/','hub-mundus-in')]:
            with self.subTest(hub=hub):
                out=self.run_install('--hub',hub,'--dry-run')
                self.assertIn('Service: heimdall-bridge-'+name+' (',out)
        self.assertFalse(self.state('heimdall-bridge-hub-mundus-in').exists())
        self.assertFalse(self.log.exists())

    def test_installs_update_supervisor_and_managed_service_identity(self):
        name='heimdall-bridge-hub-mundus-in'
        self.run_install('--hub','https://hub.mundus.in')
        data=self.home/'.local/share/heimdall/bridges'/name
        supervisor=data/'updates/apply-bridge-update.sh'
        self.assertEqual(supervisor.read_bytes(),(ROOT/'scripts/apply-bridge-update.sh').read_bytes())
        self.assertTrue(os.access(supervisor,os.X_OK))
        unit=self.home/'.config/systemd/user'/f'{name}.service'
        unit_text=unit.read_text()
        self.assertIn('HEIMDALL_BRIDGE_SERVICE_NAME='+name+'.service',unit_text)
        self.assertIn('ExecStopPost=',unit_text)
        self.assertNotIn('ExecStopPost="bash"',unit_text)
        self.assertIn('--stop-pty-hosts-only',unit_text)

    def test_bad_origins(self):
        for hub in ('https://hub/a','https://u:p@hub','http://hub:99999','https://hub?q=x','https://hub/#f','garbage'):
            self.run_install('--hub',hub,'--dry-run',success=False)
        self.assertFalse(self.log.exists())

    def test_termux_requires_termux_keystore(self):
        for env in ({'TERMUX_VERSION':'0.118.1'},{'PREFIX':'/data/data/com.termux/files/usr'}):
            with self.subTest(env=env):
                self.env.update(env)
                out=self.run_install('--hub','https://hub.mundus.in','--dry-run',success=False)
                self.assertIn('termux-keystore is missing',out)
                self.assertIn('pkg install termux-api',out)
                self.assertFalse(self.log.exists())
                for k in env: del self.env[k]
        # With Termux:API and termux-services present the check passes and the install proceeds.
        self.termux()
        self.assertNotIn('termux-keystore',self.run_install('--hub','https://hub.mundus.in','--dry-run'))
        # A desktop Linux $PREFIX (e.g. /usr/local) is not Termux.
        del self.env['TERMUX_VERSION']; (self.mock/'termux-keystore').unlink()
        self.env['PREFIX']='/usr/local'
        self.run_install('--hub','https://hub.mundus.in','--dry-run')

    def test_termux_requires_termux_services(self):
        self.termux(); (self.mock/'sv').unlink()
        self.assertIn('termux-services is required',self.run_install('--hub','https://hub.mundus.in','--dry-run',success=False))
        self.termux(); self.env['PREFIX']=str(self.root/'empty-prefix')
        self.assertIn('service directory not found',self.run_install('--hub','https://hub.mundus.in','--dry-run',success=False))
        self.assertFalse(self.log.exists())

    def test_termux_requires_running_runsvdir(self):
        prefix=self.termux(); self.stub('pgrep','#!/bin/sh\nexit 1\n')
        out=self.run_install('--hub','https://hub.mundus.in',success=False)
        self.assertIn('termux-services is not running',out); self.assertIn('start-services.sh',out)
        self.assertFalse((prefix/'var/service/ham-bridge').exists())
        self.assertFalse(any(c[0] in ('sv','sv-enable') for c in self.commands()))

    def test_termux_dry_run_plans_runit(self):
        prefix=self.termux()
        out=self.run_install('--hub','https://hub.mundus.in','--dry-run')
        self.assertIn('runit service: '+str(prefix/'var/service/ham-bridge'),out)
        self.assertIn('sv-enable ham-bridge',out)
        self.assertFalse((prefix/'var/service/ham-bridge').exists())
        self.assertFalse(self.log.exists())

    def test_termux_runit_install_enroll_and_uninstall(self):
        prefix=self.termux(); name='heimdall-bridge-hub-mundus-in'; svc=prefix/'var/service/ham-bridge'
        out=self.run_install('--hub','https://hub.mundus.in',answers=[])
        self.assertIn('approved by     alice',out); self.assertIn('runit service running: ham-bridge',out)
        run=svc/'run'; text=run.read_text()
        self.assertTrue(os.access(run,os.X_OK)); self.assertTrue(text.startswith('#!'+str(prefix)+'/bin/sh\n'))
        self.assertIn(str(self.data(name)/'bin/ham-bridge'),text); self.assertIn('--hub https://hub.mundus.in',text)
        self.assertIn('export HEIMDALL_BRIDGE_SERVICE_NAME=ham-bridge\n',text)
        self.assertIn('export HEIMDALL_HAM_CTL_BIN='+shlex.quote(str(self.data(name)/'bin'/('ham-ctl-'+name))),text)
        self.assertTrue((svc/'log/run').exists()); self.assertFalse((svc/'down').exists())
        self.assertEqual((svc/'hub-url').read_text(),'https://hub.mundus.in\n')
        commands=self.commands()
        self.assertIn(['sv-enable','ham-bridge'],commands)
        self.assertIn(['sv','restart',str(svc)],commands)
        self.assertFalse(any(c[0] in ('systemctl','launchctl') for c in commands))
        self.assertEqual((self.state(name)/'bridge-token').stat().st_mode&0o777,0o600)
        # One Termux install serves one Hub: a second Hub is refused before anything is touched.
        out=self.run_install('--hub','http://localhost:8080','--dry-run',success=False)
        self.assertIn('one bridge service',out); self.assertFalse(self.state('heimdall-bridge-localhost-8080').exists())
        # Re-install replaces the service (down, then recreated and enabled again).
        self.run_install('--hub','https://hub.mundus.in','--keep-enrollment')
        self.assertIn(['sv','down',str(svc)],self.commands()); self.assertTrue(run.exists()); self.assertFalse((svc/'down').exists())
        # Uninstall removes the service directory and binaries, keeps the enrollment.
        self.run_install('--hub','https://hub.mundus.in','--uninstall')
        self.assertFalse(svc.exists()); self.assertFalse((self.data(name)/'bin').exists())
        self.assertTrue((self.state(name)/'bridge-token').exists())

    def downloads(self):
        p=self.root/'downloads'
        return p.read_text().split() if p.exists() else []

    @staticmethod
    def releases(*entries):
        """A GitHub release list, newest first: (tag, [bundle targets])."""
        return json.dumps([{'tag_name':tag,'assets':[{'name':'SHA256SUMS'}]+[
            {'name':f'heimdall-local-{t}-{tag}.tar.gz'} for t in targets]} for tag,targets in entries])

    def test_termux_downloads_termux_bundle(self):
        # T12: glibc-static linux-* binaries are SIGSYS-killed under Android's
        # seccomp, so Termux must fetch the musl termux-* bundle. The picker
        # prefers an older release that has it over a newer one that does not.
        self.termux()
        self.env.update(MOCK_SUM_TARGETS='linux-arm64,termux-arm64',
                        MOCK_RELEASES=self.releases(('v9',['linux-arm64']),('v8',['linux-arm64','termux-arm64'])))
        out=self.run_install('--hub','https://hub.mundus.in','--keep-enrollment')
        self.assertEqual(self.downloads(),['heimdall-local-termux-arm64-v8.tar.gz'])
        self.assertNotIn('[WARN]',out)

    def test_termux_dry_run_plans_termux_bundle(self):
        self.termux()
        out=self.run_install('--hub','https://hub.mundus.in','--dry-run','--version','v1')
        self.assertIn('Download heimdall-local-termux-arm64-v1.tar.gz (or heimdall-local-linux-arm64 if the release has none)',out)

    def test_termux_falls_back_to_linux_bundle_with_warning(self):
        # An explicit --version predating the Termux bundle: SHA256SUMS lists no
        # termux-* entry, so install linux-* and say it will not run.
        self.termux()
        self.env['MOCK_SUM_TARGETS']='linux-arm64,linux-amd64'
        out=self.run_install('--hub','https://hub.mundus.in','--version','v0.3.28','--keep-enrollment')
        self.assertEqual(self.downloads(),['heimdall-local-linux-arm64-v0.3.28.tar.gz'])
        self.assertIn('[WARN] Release v0.3.28 has no termux-arm64 bundle',out)
        self.assertIn('set_robust_list',out)
        # The picker falls back too when no listed release has a Termux bundle.
        (self.root/'downloads').unlink()
        self.env['MOCK_RELEASES']=self.releases(('v7',['linux-arm64']))
        out=self.run_install('--hub','https://hub.mundus.in','--keep-enrollment')
        self.assertEqual(self.downloads(),['heimdall-local-linux-arm64-v7.tar.gz'])
        self.assertIn('[WARN] Release v7 has no termux-arm64 bundle',out)

    def test_termux_bundle_checksum_is_enforced(self):
        # The termux entry of SHA256SUMS is the one verified: a bad termux digest
        # fails closed even though the linux entry would match.
        self.termux()
        self.env.update(MOCK_SUM_TARGETS='linux-arm64,termux-arm64',BAD_SUM_TARGET='termux-arm64')
        out=self.run_install('--hub','https://hub.mundus.in','--version','v8','--keep-enrollment',success=False)
        self.assertIn('SHA-256 verification failed',out)
        self.assertEqual(self.downloads(),['heimdall-local-termux-arm64-v8.tar.gz'])
        self.assertFalse((self.root/'prefix/var/service/ham-bridge').exists())

    def test_linux_never_takes_termux_bundle(self):
        self.env.update(MOCK_ARCH='aarch64',MOCK_SUM_TARGETS='linux-arm64,termux-arm64',
                        MOCK_RELEASES=self.releases(('v8',['linux-arm64','termux-arm64'])))
        out=self.run_install('--hub','http://localhost:8080')
        self.assertEqual(self.downloads(),['heimdall-local-linux-arm64-v8.tar.gz'])
        self.assertNotIn('[WARN]',out)

    def test_missing_hub(self):
        self.assertIn('--hub is required',self.run_install('--dry-run',success=False))
        self.assertIn('localhost-8888',self.run_install('--dry-run',answers=['http://localhost:8888']))

    def test_install_two_hubs_and_busy_ports(self):
        self.env['BUSY_PORTS']='49323,49324'
        name='heimdall-bridge-localhost-8080'
        self.state(name).mkdir(parents=True)
        (self.state(name)/'ports.json').write_text(json.dumps([49323,49323]))
        self.run_install('--hub','http://localhost:8080')
        p1=json.loads((self.state(name)/'ports.json').read_text())
        self.assertNotIn(49323,p1); self.assertEqual(len(set(p1)),2)
        name2='heimdall-bridge-localhost-8081'
        self.run_install('--hub','http://localhost:8081')
        p2=json.loads((self.state(name2)/'ports.json').read_text())
        self.assertFalse(set(p1)&set(p2))
        unit=(self.home/'.config/systemd/user'/f'{name}.service').read_text()
        self.assertIn(f'--local-endpoint-port" "{p1[1]}',unit)
        self.assertIn(str(self.data(name)/'run'),unit)
        self.assertIn(str(self.data(name)),unit)
        wrapper=self.data(name)/'bin'/('ham-ctl-'+name)
        subprocess.run([str(wrapper),'tasks','list'],env=self.env,check=True)
        result=json.loads((self.root/'ctl.json').read_text())
        self.assertEqual(result['endpoint'],f'tcp:127.0.0.1:{p1[1]}')
        self.assertEqual(result['args'][:2],['--config',str(self.state(name)/'config.toml')])
        env=dict(self.env,HEIMDALL_BRIDGE_ENDPOINT='unix:/agent/own.sock')
        subprocess.run([str(wrapper),'tasks','list'],env=env,check=True)
        self.assertEqual(json.loads((self.root/'ctl.json').read_text())['endpoint'],'unix:/agent/own.sock')

    def test_checksum_failure_does_not_stop_service(self):
        self.env['BAD_SUM']='1'
        self.run_install('--hub','http://localhost:8080',success=False)
        self.assertFalse(any('stop' in c for c in self.commands()))
        self.assertFalse(self.data('heimdall-bridge-localhost-8080').exists())
        self.assertFalse((self.home/'.config/heimdall/bridges/.install-lock').exists())

    def test_enroll_then_keep_then_reenroll(self):
        name='heimdall-bridge-localhost-8080'
        out=self.run_install('--hub','http://localhost:8080',answers=[])
        self.assertIn('approved by     alice',out)
        token=self.state(name)/'bridge-token'; token.write_text('keep-me')
        out=self.run_install('--hub','http://localhost:8080',answers=['n'])
        self.assertIn('Re-enroll this bridge?',out); self.assertEqual(token.read_text(),'keep-me')
        self.run_install('--hub','http://localhost:8080',answers=['y'])
        self.assertEqual(token.read_text(),'credential\n')
        restarts=[c for c in self.commands() if 'restart' in c]
        self.assertTrue(restarts); self.assertTrue(all(c[-1]==name for c in restarts))
        self.assertEqual(token.stat().st_mode&0o777,0o600)

    def test_persisted_enrollment_command(self):
        name='heimdall-bridge-localhost-8080'
        self.run_install('--hub','http://localhost:8080')
        subprocess.run([str(self.state(name)/'enroll.sh')],env=self.env,check=True,stdout=subprocess.PIPE)
        self.assertTrue((self.state(name)/'bridge-token').exists())
        self.assertEqual(self.commands()[-1],['systemctl','--user','restart',name])

    def test_macos_plist_and_enrollment(self):
        self.env['MOCK_OS']='Darwin'; name='heimdall-bridge-127-0-0-1-8081'
        self.run_install('--hub','http://127.0.0.1:8081',answers=[])
        plist=plistlib.loads((self.home/'Library/LaunchAgents'/f'{name}.plist').read_bytes())
        self.assertEqual(plist['Label'],name)
        self.assertEqual(plist['EnvironmentVariables']['HEIMDALL_BRIDGE_SERVICE_NAME'],name)
        args=plist['ProgramArguments']; port=args[args.index('--local-endpoint-port')+1]
        self.assertEqual(plist['EnvironmentVariables']['HEIMDALL_BRIDGE_ENDPOINT'],'tcp:127.0.0.1:'+port)
        self.assertIn(['launchctl','kickstart','-k','gui/1000/'+name],self.commands())

    def test_legacy_migration_and_foreign_hub(self):
        legacy=self.home/'.config/systemd/user/heimdall-bridge.service'; legacy.parent.mkdir(parents=True)
        legacy.write_text('ExecStart=/bin/ham-bridge --hub "http://localhost:8080"\n')
        old=self.home/'.config/heimdall'; old.mkdir(parents=True)
        (old/'bridge-token').write_text('legacy-credential')
        (old/'bridge-token.refresh').write_text('legacy-refresh')
        self.run_install('--hub','http://localhost:8081')
        self.assertTrue(legacy.exists())
        self.assertFalse(any(c[-1]=='heimdall-bridge' for c in self.commands()))
        self.run_install('--hub','http://localhost:8080')
        self.assertFalse(legacy.exists())
        self.assertEqual((self.state('heimdall-bridge-localhost-8080')/'bridge-token').read_text(),'legacy-credential')
        self.assertTrue((old/'bridge-token').exists())

    def test_uninstall_only_target(self):
        for port in (8080,8081): self.run_install('--hub',f'http://localhost:{port}')
        name='heimdall-bridge-localhost-8080'; (self.state(name)/'bridge-token').write_text('preserve')
        self.run_install('--hub','http://localhost:8080','--uninstall')
        self.assertFalse((self.data(name)/'bin').exists())
        self.assertTrue((self.state(name)/'bridge-token').exists())
        self.assertTrue((self.data('heimdall-bridge-localhost-8081')/'bin/ham-bridge').exists())

    def test_name_collision_rejected(self):
        name='heimdall-bridge-hub-mundus-in'; self.state(name).mkdir(parents=True)
        (self.state(name)/'hub-url').write_text('http://hub.mundus.in')
        self.run_install('--hub','https://hub.mundus.in','--dry-run',success=False)
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
