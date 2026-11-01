"""Disposable second-machine Bridge. No service install or real config edits."""
import base64, hashlib, json, os, pathlib, re, shutil, signal, socket, ssl
import subprocess, sys, tempfile, time, urllib.request

root = pathlib.Path(tempfile.mkdtemp(prefix='mcp-e2e-'))
root.chmod(0o700)
test_home = root/'home'; test_home.mkdir()
project = root/'project'; project.mkdir()
real_home = pathlib.Path.home()
bridge = real_home/'.local/share/heimdall/bridges/heimdall-bridge-hub-brolabs-ai/bin/ham-bridge'
if not bridge.is_file() or bridge.read_bytes()[:4] != b'\x7fELF':
    raise SystemExit('Remote test requires the native ELF Bridge, not a service wrapper')
pty = bridge.with_name('ham-pty-host'); ctl = bridge.with_name('ham-ctl')
installed_bridge = bridge
prefix = []
legacy = subprocess.run(['systemctl','--user','show','heimdall-bridge.service','--property=LoadState','--value'],capture_output=True,text=True)
if legacy.stdout.strip() not in ('', 'not-found'):
    raise SystemExit('Refusing remote enrollment while a legacy fixed-name service exists')
base, expected = sys.argv[1:3]
# Only the PUBLIC test certificate is bootstrapped without CA trust, and its
# exact SHA256 is pinned by the local test operator before any credential flows.
cert = urllib.request.urlopen(base+'/__acceptance_ca', context=ssl._create_unverified_context(), timeout=10).read()
if hashlib.sha256(cert).hexdigest() != expected: raise SystemExit('Test CA pin mismatch')
ca = root/'ca.pem'; ca.write_bytes(cert)
if len(sys.argv)>3 and sys.argv[3]:
    binary = urllib.request.urlopen(base+'/__acceptance_bridge', context=ssl.create_default_context(cafile=str(ca)), timeout=20).read()
    if hashlib.sha256(binary).hexdigest() != sys.argv[3]: raise SystemExit('Test Bridge binary pin mismatch')
    bridge = root/'ham-bridge'; bridge.write_bytes(binary); bridge.chmod(0o700)
    # A test binary built on a conventional Linux host names /lib64/ld-linux;
    # NixOS instead uses its installed Bridge's store loader and library closure.
    if not pathlib.Path('/lib64/ld-linux-x86-64.so.2').exists():
        libs = []
        for executable in (installed_bridge, pathlib.Path(shutil.which('curl') or str(installed_bridge))):
            listing = subprocess.run(['ldd',str(executable)],capture_output=True,text=True).stdout
            for name in re.findall(r'(/[^\s()]+)',listing):
                p = pathlib.Path(name)
                if p.is_file():
                    libs.append(str(p.parent))
                    if 'ld-linux' in p.name: prefix = [str(p)]
        if not prefix: raise SystemExit('Nix test loader unavailable')
        prefix += ['--library-path',':'.join(dict.fromkeys(libs))]
env = {k:v for k,v in os.environ.items() if not k.startswith('HEIMDALL_')}
env.update(HOME=str(test_home), XDG_CONFIG_HOME=str(test_home/'.config'), HAM_TLS_CA_FILE=str(ca), HEIMDALL_HAM_CTL_BIN=str(ctl), HEIMDALL_HAM_PTY_HOST_BIN=str(pty))
auth_file = test_home/'.codex/auth.json'
try:
    auth = json.loads((real_home/'.codex/auth.json').read_text())
    token = auth['tokens']['access_token']
    exp = json.loads(base64.urlsafe_b64decode(token.split('.')[1]+'==='))['exp']
    if exp < time.time()+600: raise ValueError()
    auth['tokens']['refresh_token'] = ''
    auth_file.parent.mkdir(); auth_file.write_text(json.dumps(auth)); auth_file.chmod(0o600)
except Exception:
    raise SystemExit('Remote provider needs a valid short-lived access credential')

def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]

args = ['--config',str(root/'config.toml'),'--bridge-token-file',str(root/'bridge.token'),
        '--data-dir',str(root/'data'),'--port',str(free_port()),
        '--local-endpoint-port',str(free_port()),'--local-run-dir',str(root/'run')]
proc = None
def stop(signum,frame): raise SystemExit(0)
signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
print('REMOTE_META '+json.dumps({'root':str(root),'project':str(project),'hostname':socket.gethostname()}),flush=True)
try:
    proc = subprocess.Popen([*prefix,str(bridge),'enroll','--hub',base,'--headless',*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    enrollment_succeeded = False
    with (root/'enroll.log').open('w') as log:
        for line in proc.stdout:
            log.write(line); log.flush()
            if 'bridge enroll SUCCESS:' in line: enrollment_succeeded = True
            m = re.fullmatch(r'\s*([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*',line)
            if m: print('PAIR_CODE '+m[1],flush=True)
    code = proc.wait()
    if code != 0 and not (enrollment_succeeded and (root/'config.toml').is_file() and (root/'bridge.token').is_file()):
        raise SystemExit('Remote enrollment failed; diagnostics remain private')
    print('REMOTE_ENROLLED',flush=True)
    log = (root/'bridge.log').open('w')
    proc = subprocess.Popen([*prefix,str(bridge),*args],cwd=root,env=env,stdout=log,stderr=log)
    deadline = time.monotonic()+600
    while proc.poll() is None and time.monotonic()<deadline: time.sleep(1)
finally:
    for sock in (root/'run').glob('pty-host-*.sock'):
        subprocess.run([str(pty),'--socket',str(sock),'stop'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill()
    auth_file.unlink(missing_ok=True)
    print('REMOTE_CLEAN',flush=True)
