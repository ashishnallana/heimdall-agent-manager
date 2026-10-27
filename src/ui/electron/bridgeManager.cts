const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

// REQ-DMG-2: all host mutation stays in Electron's main process. The renderer
// receives only structured status and the two explicit install/enroll actions.
let busy = false;
let enrollmentProcess: any = null;

function normalizeOrigin(value: string): string {
  try { return new URL(String(value || '')).origin; } catch (_err) { return String(value || '').replace(/\/$/, ''); }
}

function bridgeRoot(): string {
  return path.join(os.homedir(), '.config', 'heimdall', 'bridges');
}

function findState(hubUrl: string): { stateDir: string; serviceName: string } | null {
  const root = bridgeRoot();
  let names: string[] = [];
  try { names = fs.readdirSync(root); } catch (_err) { return null; }
  const wanted = normalizeOrigin(hubUrl);
  for (const serviceName of names.sort()) {
    const stateDir = path.join(root, serviceName);
    try {
      if (!fs.statSync(stateDir).isDirectory()) continue;
      const saved = normalizeOrigin(fs.readFileSync(path.join(stateDir, 'hub-url'), 'utf8').trim());
      if (saved === wanted) return { stateDir, serviceName };
    } catch (_err) { /* Ignore incomplete/foreign state directories. */ }
  }
  return null;
}

function resources(): { installScript: string; bundle: string; checksums: string; metadata: string } {
  const target = process.arch === 'arm64' ? 'darwin-arm64' : 'darwin-amd64';
  const root = process.env.HEIMDALL_BRIDGE_RESOURCES || path.join((process as any).resourcesPath || '', 'bridge');
  return {
    installScript: path.join(root, 'install.sh'),
    bundle: path.join(root, `heimdall-local-${target}.tar.gz`),
    checksums: path.join(root, 'SHA256SUMS'),
    metadata: path.join(root, 'METADATA.json'),
  };
}

function bundledVersion(): string {
  try { return String(JSON.parse(fs.readFileSync(resources().metadata, 'utf8'))?.version || '').replace(/^v/, ''); }
  catch (_err) { return ''; }
}

function installedVersion(binary: string): string {
  try {
    const result = childProcess.spawnSync(binary, ['--version'], { encoding: 'utf8', timeout: 5000 });
    const match = `${result.stdout || ''}\n${result.stderr || ''}`.match(/ham-bridge\s+v?([^\s]+)/);
    return match ? match[1] : '';
  } catch (_err) { return ''; }
}

function launchdRunning(serviceName: string): boolean {
  if (!serviceName || process.platform !== 'darwin') return false;
  const result = childProcess.spawnSync('/bin/launchctl', ['print', `gui/${process.getuid()}/${serviceName}`], { stdio: 'ignore', timeout: 5000 });
  return result.status === 0;
}

function getStatus(hubUrl: string) {
  const packaged = Object.values(resources()).every((file: any) => fs.existsSync(file));
  if (process.platform !== 'darwin') return {
    supported: false, packaged: false, installed: false, enrolled: false,
    serviceState: 'not-installed', serviceName: '', hubUrl, installedVersion: '', bundledVersion: '', busy: busy || Boolean(enrollmentProcess), error: '',
  };
  const state = findState(hubUrl);
  const dataDir = state ? path.join(os.homedir(), '.local', 'share', 'heimdall', 'bridges', state.serviceName) : '';
  const binary = dataDir ? path.join(dataDir, 'bin', 'ham-bridge') : '';
  const installed = Boolean(state && fs.existsSync(binary));
  const enrolled = Boolean(state && fs.existsSync(path.join(state.stateDir, 'bridge-token')));
  const running = Boolean(state && launchdRunning(state.serviceName));
  return {
    supported: true,
    packaged,
    installed,
    enrolled,
    serviceState: installed ? (running ? 'running' : 'stopped') : 'not-installed',
    serviceName: state?.serviceName || '',
    hubUrl,
    installedVersion: installed ? installedVersion(binary) : '',
    bundledVersion: bundledVersion(),
    busy: busy || Boolean(enrollmentProcess),
    error: packaged ? '' : 'The packaged Bridge resources are incomplete.',
  };
}

function runProcess(command: string, args: string[], env: NodeJS.ProcessEnv = process.env): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    const proc = childProcess.spawn(command, args, {
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    const collect = (chunk: any) => { output += String(chunk || ''); if (output.length > 64_000) output = output.slice(-64_000); };
    proc.stdout.on('data', collect); proc.stderr.on('data', collect);
    proc.on('error', (error: Error) => resolve({ code: -1, output: error.message }));
    proc.on('close', (code: number) => resolve({ code: Number(code ?? -1), output }));
  });
}

// REQ-DMG-ENV-1: Finder-launched apps do not inherit Homebrew/Nix paths. macOS
// ships /usr/bin/openssl, so every Bridge host process the app starts (install,
// enroll, re-enroll) selects the bridge's verified s_client fallback instead of
// requiring an external socat install. Enrollment needs it too: `ham-bridge
// enroll` opens the Hub WebSocket to receive the encrypted vault key.
function bridgeHostEnv(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
    HAM_TLS_BACKEND: 's_client',
    HEIMDALL_INSTALL_PLAIN: '1',
  };
}

function run(command: string, args: string[]): Promise<{ code: number; output: string }> {
  return runProcess(command, args, bridgeHostEnv());
}

function commandError(output: string, fallback: string): string {
  return output.trim().split('\n').slice(-8).join('\n') || fallback;
}

function extractEnrollmentPairing(output: string): { url: string; code: string } | null {
  const url = output.match(/https?:\/\/[^\s]+\/api\/v1\/device\/add[^\s]*/)?.[0]?.replace(/[),.;]+$/, '') || '';
  // Pairing codes contain 14 RFC 4648 base32 symbols, rendered XXXX-XXXX-XXXX-XX.
  const code = output.match(/\b[A-Z2-7]{4}(?:-[A-Z2-7]{4}){2}-[A-Z2-7]{2}\b/)?.[0] || '';
  return url && code ? { url, code } : null;
}

async function installBundled(hubUrl: string) {
  if (busy || enrollmentProcess) return { ok: false, status: getStatus(hubUrl), error: 'A Bridge operation is already running.' };
  const files = resources();
  const version = bundledVersion();
  if (!version || !Object.values(files).every((file: any) => fs.existsSync(file))) {
    return { ok: false, status: getStatus(hubUrl), error: 'This app does not contain a complete Bridge bundle.' };
  }
  busy = true;
  try {
    const result = await run('/bin/bash', [files.installScript, '--hub', hubUrl, '--version', `v${version}`,
      '--bundle', files.bundle, '--checksum-file', files.checksums, '--non-interactive']);
    const error = result.code === 0 ? '' : (result.output.trim().split('\n').slice(-8).join('\n') || `Installer exited with status ${result.code}.`);
    busy = false;
    return { ok: result.code === 0, status: getStatus(hubUrl), ...(error ? { error } : {}) };
  } finally { busy = false; }
}

async function restart(hubUrl: string) {
  if (busy || enrollmentProcess) return { ok: false, status: getStatus(hubUrl), error: 'A Bridge operation is already running.' };
  const state = findState(hubUrl);
  if (process.platform !== 'darwin' || !state) return { ok: false, status: getStatus(hubUrl), error: 'Install the packaged Bridge before restarting it.' };
  const plist = path.join(os.homedir(), 'Library', 'LaunchAgents', `${state.serviceName}.plist`);
  if (!fs.existsSync(plist)) return { ok: false, status: getStatus(hubUrl), error: `LaunchAgent is missing: ${plist}` };
  busy = true;
  let error = '';
  try {
    const target = `gui/${process.getuid()}/${state.serviceName}`;
    const loaded = await runProcess('/bin/launchctl', ['print', target]);
    if (loaded.code !== 0) {
      const bootstrapped = await runProcess('/bin/launchctl', ['bootstrap', `gui/${process.getuid()}`, plist]);
      if (bootstrapped.code !== 0) error = commandError(bootstrapped.output, `Unable to load ${state.serviceName}.`);
    }
    if (!error) {
      const kicked = await runProcess('/bin/launchctl', ['kickstart', '-k', target]);
      if (kicked.code !== 0) error = commandError(kicked.output, `Unable to restart ${state.serviceName}.`);
    }
  } catch (caught: any) {
    error = String(caught?.message || caught || 'Unable to restart the Bridge.');
  } finally {
    busy = false;
  }
  return { ok: !error, status: getStatus(hubUrl), ...(error ? { error } : {}) };
}

function startEnrollment(hubUrl: string, emit: (event: any) => void) {
  if (enrollmentProcess) return { ok: false, error: 'Enrollment is already running.' };
  const state = findState(hubUrl);
  const script = state && path.join(state.stateDir, 'enroll.sh');
  if (!script || !fs.existsSync(script)) return { ok: false, error: 'Install the packaged Bridge before enrolling it.' };
  enrollmentProcess = childProcess.spawn('/bin/bash', [script, '--headless'], { env: bridgeHostEnv(), stdio: ['ignore', 'pipe', 'pipe'] });
  let buffer = '';
  let pairingSent = false;
  const onData = (chunk: any) => {
    const message = String(chunk || '');
    buffer = (buffer + message).slice(-16_000);
    emit({ type: 'output', message });
    const pairing = extractEnrollmentPairing(buffer);
    if (!pairingSent && pairing) { pairingSent = true; emit({ type: 'pairing', ...pairing }); }
  };
  enrollmentProcess.stdout.on('data', onData); enrollmentProcess.stderr.on('data', onData);
  enrollmentProcess.on('error', (error: Error) => { emit({ type: 'error', message: error.message }); enrollmentProcess = null; });
  enrollmentProcess.on('close', (code: number) => {
    emit(code === 0 ? { type: 'complete', message: 'Bridge enrollment complete.' } : { type: 'error', message: `Enrollment exited with status ${code}.` });
    enrollmentProcess = null;
  });
  return { ok: true };
}

function startReEnrollment(hubUrl: string, emit: (event: any) => void) {
  const status = getStatus(hubUrl);
  if (!status.installed) return { ok: false, error: 'Install the packaged Bridge before re-enrolling it.' };
  if (!status.enrolled) return { ok: false, error: 'This Bridge is not enrolled yet. Use the standard enrollment action.' };
  return startEnrollment(hubUrl, emit);
}

module.exports = { extractEnrollmentPairing, getStatus, installBundled, restart, startEnrollment, startReEnrollment };
