const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

// REQ-DMG-2: all host mutation stays in Electron's main process. The renderer
// receives only structured status and the two explicit install/enroll actions.
let busy = false;
let enrollmentProcess: any = null;
// REQ-REENROLL-RECOVER-1: enroll.sh boots the running service out before it
// enrolls, and only a successful enrollment brings it back. A re-enrollment
// that fails, is abandoned or is stopped by quitting the app must restart the
// Bridge with its existing credential instead of leaving it offline.
let enrollmentRecovery: { hubUrl: string } | null = null;
let enrollmentStopping = false;

const BRIDGE_ID_PATTERN = /^brg_[A-Za-z0-9_-]{1,60}$/;

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

// The bridge id is not a credential. Keep it independently discoverable so a
// missing/rotated token can still enter the explicit --reuse-bridge flow rather
// than being mistaken for a first enrollment.
function discoverBridgeId(stateDir: string): string {
  const candidates: string[] = [];
  try { candidates.push(fs.readFileSync(path.join(stateDir, 'bridge-id'), 'utf8').trim()); } catch (_err) { /* Optional marker. */ }
  try {
    const config = fs.readFileSync(path.join(stateDir, 'config.toml'), 'utf8');
    candidates.push(config.match(/^\s*daemon_id\s*=\s*"(brg_[A-Za-z0-9_-]{1,60})"\s*$/m)?.[1] || '');
  } catch (_err) { /* An incomplete install has no config yet. */ }
  try {
    const header = fs.readFileSync(path.join(stateDir, 'bridge-token'), 'utf8').split(/\r?\n/, 1)[0] || '';
    candidates.push(header.match(/^heimdall-bridge-credential\/v1\s+\S+\s+(brg_[A-Za-z0-9_-]{1,60})$/)?.[1] || '');
  } catch (_err) { /* Tokenless is a valid re-enrollment state. */ }
  const valid = [...new Set(candidates.filter((candidate) => BRIDGE_ID_PATTERN.test(candidate)))];
  // A stale marker must never authorize replacement of a different identity.
  // Require every available source to agree; the operator can then repair the
  // non-secret metadata rather than Electron guessing which key to replace.
  return valid.length === 1 ? valid[0] : '';
}

function rememberBridgeId(stateDir: string, bridgeId: string) {
  if (!BRIDGE_ID_PATTERN.test(bridgeId)) return;
  try { fs.writeFileSync(path.join(stateDir, 'bridge-id'), `${bridgeId}\n`, { mode: 0o600 }); }
  catch (_err) { /* config.toml remains the compatibility source of truth. */ }
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

// REQ-BRIDGE-STATUS-ASYNC-1: launchctl and `ham-bridge --version` are probed
// asynchronously by refreshStatus() and cached per service. getStatus() only
// reads files and that cache, so it never blocks Electron's main process.
type ServiceProbe = { running: boolean; installedVersion: string; binary: string };
const serviceProbes = new Map<string, ServiceProbe>();
const statusRefreshes = new Map<string, Promise<any>>();

function execFileResult(command: string, args: string[]): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    try {
      childProcess.execFile(command, args, { encoding: 'utf8', timeout: 5000 }, (error: any, stdout: string, stderr: string) => {
        const code = error ? (typeof error.code === 'number' ? error.code : -1) : 0;
        resolve({ code, output: `${stdout || ''}\n${stderr || ''}` });
      });
    } catch (error: any) {
      resolve({ code: -1, output: String(error?.message || error) });
    }
  });
}

function bridgeBinary(serviceName: string): string {
  return path.join(os.homedir(), '.local', 'share', 'heimdall', 'bridges', serviceName, 'bin', 'ham-bridge');
}

async function probeService(serviceName: string, binary: string): Promise<ServiceProbe> {
  const [launchd, version] = await Promise.all([
    execFileResult('/bin/launchctl', ['print', `gui/${process.getuid()}/${serviceName}`]),
    fs.existsSync(binary) ? execFileResult(binary, ['--version']) : Promise.resolve({ code: -1, output: '' }),
  ]);
  return { running: launchd.code === 0, installedVersion: version.output.match(/ham-bridge\s+v?([^\s]+)/)?.[1] || '', binary };
}

// refreshStatus re-probes this Hub's Bridge service and returns the fresh
// status. Concurrent callers share one probe.
function refreshStatus(hubUrl: string): Promise<any> {
  const key = normalizeOrigin(hubUrl);
  const pending = statusRefreshes.get(key);
  if (pending) return pending;
  const refresh = (async () => {
    const state = process.platform === 'darwin' ? findState(hubUrl) : null;
    if (state) serviceProbes.set(state.serviceName, await probeService(state.serviceName, bridgeBinary(state.serviceName)));
    return getStatus(hubUrl);
  })().finally(() => statusRefreshes.delete(key));
  statusRefreshes.set(key, refresh);
  return refresh;
}

function getStatus(hubUrl: string) {
  const packaged = Object.values(resources()).every((file: any) => fs.existsSync(file));
  if (process.platform !== 'darwin') return {
    supported: false, packaged: false, installed: false, enrolled: false,
    bridgeId: '', canReEnroll: false, serviceState: 'not-installed', serviceName: '', hubUrl, installedVersion: '', bundledVersion: '', busy: busy || Boolean(enrollmentProcess), error: '',
  };
  const state = findState(hubUrl);
  const binary = state ? bridgeBinary(state.serviceName) : '';
  const installed = Boolean(state && fs.existsSync(binary));
  let enrolled = false;
  try { enrolled = Boolean(state && fs.statSync(path.join(state.stateDir, 'bridge-token')).size > 0); } catch (_err) { /* Tokenless. */ }
  const bridgeId = state ? discoverBridgeId(state.stateDir) : '';
  const probe = state ? serviceProbes.get(state.serviceName) : undefined;
  const running = Boolean(probe?.running);
  return {
    supported: true,
    packaged,
    installed,
    enrolled,
    bridgeId,
    canReEnroll: Boolean(bridgeId),
    serviceState: installed ? (running ? 'running' : 'stopped') : 'not-installed',
    serviceName: state?.serviceName || '',
    hubUrl,
    installedVersion: installed && probe?.binary === binary ? probe.installedVersion : '',
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

// REQ-DMG-ENV-1: Finder-launched apps do not inherit Homebrew/Nix paths. Bridge
// HTTPS and WSS are provided by the packaged binary's pinned libcurl, so only the
// stock paths needed by the installer/service tools are required here.
function bridgeHostEnv(): NodeJS.ProcessEnv {
  const home = os.homedir();
  const providerPaths = [
    '/usr/bin', '/bin', '/usr/sbin', '/sbin',
    '/usr/local/bin', '/opt/homebrew/bin',
    path.join(home, '.local', 'bin'),
    path.join(home, '.npm-global', 'bin'),
    path.join(home, '.bun', 'bin'),
    path.join(home, '.volta', 'bin'),
    path.join(home, '.cargo', 'bin'),
    path.join(home, '.nix-profile', 'bin'),
    '/run/current-system/sw/bin',
    '/nix/var/nix/profiles/default/bin',
  ];
  return {
    ...process.env,
    // System tools stay first while common per-user package-manager locations
    // remain visible to the long-lived launchd bridge for provider discovery.
    PATH: providerPaths.join(':'),
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
    return { ok: result.code === 0, status: await refreshStatus(hubUrl), ...(error ? { error } : {}) };
  } finally { busy = false; }
}

function launchAgent(hubUrl: string): { serviceName: string; plist: string; target: string; error: string } {
  const state = findState(hubUrl);
  if (process.platform !== 'darwin' || !state) return { serviceName: '', plist: '', target: '', error: 'Install the packaged Bridge before restarting it.' };
  const plist = path.join(os.homedir(), 'Library', 'LaunchAgents', `${state.serviceName}.plist`);
  if (!fs.existsSync(plist)) return { serviceName: '', plist: '', target: '', error: `LaunchAgent is missing: ${plist}` };
  return { serviceName: state.serviceName, plist, target: `gui/${process.getuid()}/${state.serviceName}`, error: '' };
}

async function restart(hubUrl: string) {
  if (busy || enrollmentProcess) return { ok: false, status: getStatus(hubUrl), error: 'A Bridge operation is already running.' };
  const { serviceName, plist, target, error: agentError } = launchAgent(hubUrl);
  if (agentError) return { ok: false, status: getStatus(hubUrl), error: agentError };
  busy = true;
  let error = '';
  try {
    const loaded = await runProcess('/bin/launchctl', ['print', target]);
    if (loaded.code !== 0) {
      const bootstrapped = await runProcess('/bin/launchctl', ['bootstrap', `gui/${process.getuid()}`, plist]);
      if (bootstrapped.code !== 0) error = commandError(bootstrapped.output, `Unable to load ${serviceName}.`);
    }
    if (!error) {
      const kicked = await runProcess('/bin/launchctl', ['kickstart', '-k', target]);
      if (kicked.code !== 0) error = commandError(kicked.output, `Unable to restart ${serviceName}.`);
    }
  } catch (caught: any) {
    error = String(caught?.message || caught || 'Unable to restart the Bridge.');
  } finally {
    busy = false;
  }
  return { ok: !error, status: await refreshStatus(hubUrl), ...(error ? { error } : {}) };
}

// restartSync is the quit-time variant of restart(): the app is exiting, so it
// cannot await child processes. launchctl print/bootstrap/kickstart are fast.
function restartSync(hubUrl: string): string {
  const agent = launchAgent(hubUrl);
  if (agent.error) return agent.error;
  const options = { stdio: 'ignore', timeout: 5000 };
  if (childProcess.spawnSync('/bin/launchctl', ['print', agent.target], options).status !== 0
    && childProcess.spawnSync('/bin/launchctl', ['bootstrap', `gui/${process.getuid()}`, agent.plist], options).status !== 0) {
    return `Unable to load ${agent.serviceName}.`;
  }
  return childProcess.spawnSync('/bin/launchctl', ['kickstart', '-k', agent.target], options).status === 0 ? '' : `Unable to restart ${agent.serviceName}.`;
}

function startEnrollment(
  hubUrl: string,
  emit: (event: any) => void,
  options: { restartOnFailure?: boolean; reuseBridgeId?: string } = {},
) {
  if (enrollmentProcess) return { ok: false, error: 'Enrollment is already running.' };
  const state = findState(hubUrl);
  const script = state && path.join(state.stateDir, 'enroll.sh');
  if (!script || !fs.existsSync(script)) return { ok: false, error: 'Install the packaged Bridge before enrolling it.' };
  const reuseBridgeId = String(options.reuseBridgeId || '').trim();
  if (reuseBridgeId && !BRIDGE_ID_PATTERN.test(reuseBridgeId)) return { ok: false, error: 'The previous Bridge ID is invalid; refusing to re-enroll it.' };
  const args = [script, '--headless', ...(reuseBridgeId ? ['--reuse-bridge', reuseBridgeId] : [])];
  // Its own process group, so stopEnrollment() also stops the ham-bridge child.
  const proc = childProcess.spawn('/bin/bash', args, {
    env: bridgeHostEnv(),
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });
  enrollmentProcess = proc;
  enrollmentRecovery = options.restartOnFailure ? { hubUrl } : null;
  enrollmentStopping = false;
  let buffer = '';
  let pairingSent = false;
  let finished = false;
  const onData = (chunk: any) => {
    const message = String(chunk || '');
    buffer = (buffer + message).slice(-16_000);
    emit({ type: 'output', message });
    const pairing = extractEnrollmentPairing(buffer);
    if (!pairingSent && pairing) { pairingSent = true; emit({ type: 'pairing', ...pairing }); }
  };
  const finishFailure = (message: string) => {
    if (finished) return;
    finished = true;
    if (enrollmentProcess === proc) enrollmentProcess = null;
    const recovery = enrollmentRecovery;
    enrollmentRecovery = null;
    // stopEnrollment() already restarted the Bridge synchronously.
    if (!recovery || enrollmentStopping) { emit({ type: 'error', message }); return; }
    void restart(recovery.hubUrl).then((result) => emit({
      type: 'error',
      message: result.ok
        ? `${message} The Bridge was restarted with its existing enrollment.`
        : `${message} The Bridge could not be restarted: ${result.error}`,
    }));
  };
  const finishSuccess = () => {
    if (finished) return;
    finished = true;
    if (enrollmentProcess === proc) enrollmentProcess = null;
    enrollmentRecovery = null;
    const completedBridgeId = discoverBridgeId(state.stateDir)
      || buffer.match(/(?:bridge_id=|(?:Re-enrolled existing|Registered new) bridge\s+)(brg_[A-Za-z0-9_-]{1,60})/)?.[1]
      || reuseBridgeId;
    if (completedBridgeId) rememberBridgeId(state.stateDir, completedBridgeId);
    emit({ type: 'complete', message: 'Bridge enrollment complete.' });
  };
  proc.stdout.on('data', onData); proc.stderr.on('data', onData);
  proc.on('error', (error: Error) => { finishFailure(error.message); });
  proc.on('close', (code: number) => {
    if (finished) return;
    if (code === 0) finishSuccess();
    else finishFailure(commandError(buffer, `Enrollment exited with status ${code}.`));
  });
  return { ok: true };
}

// stopEnrollment ends a running enrollment when the app quits. A re-enrollment
// that is cut short restarts the Bridge it booted out.
function stopEnrollment(): void {
  const proc = enrollmentProcess;
  if (!proc) return;
  enrollmentStopping = true;
  try { process.kill(-proc.pid, 'SIGTERM'); } catch (_err) { try { proc.kill('SIGTERM'); } catch (_ignored) { /* Already exited. */ } }
  if (enrollmentRecovery) {
    const error = restartSync(enrollmentRecovery.hubUrl);
    if (error) console.warn('[heimdall] unable to restart Bridge after stopping re-enrollment:', error);
  }
  enrollmentRecovery = null;
}

function startReEnrollment(hubUrl: string, emit: (event: any) => void) {
  const status = getStatus(hubUrl);
  if (!status.installed) return { ok: false, error: 'Install the packaged Bridge before re-enrolling it.' };
  if (!status.bridgeId) return { ok: false, error: 'No previous Bridge ID is recorded. Use the standard enrollment action.' };
  return startEnrollment(hubUrl, emit, { restartOnFailure: true, reuseBridgeId: status.bridgeId });
}

module.exports = { discoverBridgeId, extractEnrollmentPairing, getStatus, installBundled, refreshStatus, restart, startEnrollment, startReEnrollment, stopEnrollment };
