const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

// REQ-DMG-2 / REQ-WIN-DESKTOP-2: all host mutation stays in Electron's main
// process. The renderer receives only structured status and explicit actions.
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

function supportedPlatform(platform: NodeJS.Platform = process.platform): boolean {
  return platform === 'darwin' || platform === 'win32';
}

function desktopPaths(
  platform: NodeJS.Platform = process.platform,
  env: NodeJS.ProcessEnv = process.env,
  home: string = os.homedir(),
) {
  if (platform === 'win32') {
    const roaming = env.APPDATA || path.join(home, 'AppData', 'Roaming');
    const local = env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
    return {
      stateRoot: path.join(roaming, 'heimdall', 'bridges'),
      dataRoot: path.join(local, 'heimdall', 'bridges'),
      binaryName: 'ham-bridge.exe',
      enrollScriptName: 'enroll.ps1',
    };
  }
  return {
    stateRoot: path.join(home, '.config', 'heimdall', 'bridges'),
    dataRoot: path.join(home, '.local', 'share', 'heimdall', 'bridges'),
    binaryName: 'ham-bridge',
    enrollScriptName: 'enroll.sh',
  };
}

function findState(hubUrl: string, platform: NodeJS.Platform = process.platform): { stateDir: string; serviceName: string } | null {
  const root = desktopPaths(platform).stateRoot;
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

function resources(
  platform: NodeJS.Platform = process.platform,
  arch: string = process.arch,
  resourcesRoot: string = process.env.HEIMDALL_BRIDGE_RESOURCES || path.join((process as any).resourcesPath || '', 'bridge'),
) {
  if (platform === 'win32') {
    // The current native Windows release is amd64. Windows on Arm executes it
    // through the OS x64 compatibility layer, as scripts/install.ps1 documents.
    const target = 'windows-amd64';
    return {
      installScript: path.join(resourcesRoot, 'install.ps1'),
      bundle: path.join(resourcesRoot, `heimdall-local-${target}.zip`),
      checksums: path.join(resourcesRoot, 'SHA256SUMS'),
      metadata: path.join(resourcesRoot, 'METADATA.json'),
    };
  }
  const target = arch === 'arm64' ? 'darwin-arm64' : 'darwin-amd64';
  return {
    installScript: path.join(resourcesRoot, 'install.sh'),
    bundle: path.join(resourcesRoot, `heimdall-local-${target}.tar.gz`),
    checksums: path.join(resourcesRoot, 'SHA256SUMS'),
    metadata: path.join(resourcesRoot, 'METADATA.json'),
  };
}

function bundledVersion(platform: NodeJS.Platform = process.platform): string {
  try { return String(JSON.parse(fs.readFileSync(resources(platform).metadata, 'utf8'))?.version || '').replace(/^v/, ''); }
  catch (_err) { return ''; }
}

function installedVersion(binary: string): string {
  try {
    const result = childProcess.spawnSync(binary, ['--version'], { encoding: 'utf8', timeout: 5000 });
    const match = `${result.stdout || ''}\n${result.stderr || ''}`.match(/ham-bridge\s+v?([^\s]+)/);
    return match ? match[1] : '';
  } catch (_err) { return ''; }
}

function powershellPath(env: NodeJS.ProcessEnv = process.env): string {
  return env.SystemRoot
    ? path.join(env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    : 'powershell.exe';
}

function launchdRunning(serviceName: string): boolean {
  if (!serviceName) return false;
  const result = childProcess.spawnSync('/bin/launchctl', ['print', `gui/${process.getuid()}/${serviceName}`], { stdio: 'ignore', timeout: 5000 });
  return result.status === 0;
}

function windowsTaskRunning(serviceName: string): boolean {
  if (!/^[A-Za-z0-9_-]+$/.test(serviceName)) return false;
  const script = "$task = Get-ScheduledTask -TaskPath '\\' -TaskName $env:HEIMDALL_BRIDGE_TASK_NAME -ErrorAction SilentlyContinue; if ($task -and $task.State -eq 'Running') { exit 0 }; exit 1";
  const result = childProcess.spawnSync(powershellPath(), ['-NoProfile', '-NonInteractive', '-Command', script], {
    stdio: 'ignore', timeout: 5000, env: { ...process.env, HEIMDALL_BRIDGE_TASK_NAME: serviceName },
  });
  return result.status === 0;
}

function serviceRunning(platform: NodeJS.Platform, serviceName: string): boolean {
  if (platform === 'darwin') return launchdRunning(serviceName);
  if (platform === 'win32') return windowsTaskRunning(serviceName);
  return false;
}

function getStatus(hubUrl: string) {
  const platform = process.platform;
  const files = resources(platform);
  const packaged = supportedPlatform(platform) && Object.values(files).every((file: any) => fs.existsSync(file));
  if (!supportedPlatform(platform)) return {
    supported: false, packaged: false, installed: false, enrolled: false,
    bridgeId: '', canReEnroll: false, serviceState: 'not-installed', serviceName: '', hubUrl, installedVersion: '', bundledVersion: '', busy: busy || Boolean(enrollmentProcess), error: '',
  };
  const state = findState(hubUrl, platform);
  const paths = desktopPaths(platform);
  const dataDir = state ? path.join(paths.dataRoot, state.serviceName) : '';
  const binary = dataDir ? path.join(dataDir, 'bin', paths.binaryName) : '';
  const installed = Boolean(state && fs.existsSync(binary));
  let enrolled = false;
  try { enrolled = Boolean(state && fs.statSync(path.join(state.stateDir, 'bridge-token')).size > 0); } catch (_err) { /* Tokenless. */ }
  const bridgeId = state ? discoverBridgeId(state.stateDir) : '';
  const running = Boolean(state && serviceRunning(platform, state.serviceName));
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
    installedVersion: installed ? installedVersion(binary) : '',
    bundledVersion: bundledVersion(platform),
    busy: busy || Boolean(enrollmentProcess),
    error: packaged ? '' : 'The packaged Bridge resources are incomplete.',
  };
}

function runProcess(command: string, args: string[], env: NodeJS.ProcessEnv = process.env): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    const proc = childProcess.spawn(command, args, { env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let output = '';
    const collect = (chunk: any) => { output += String(chunk || ''); if (output.length > 64_000) output = output.slice(-64_000); };
    proc.stdout.on('data', collect); proc.stderr.on('data', collect);
    proc.on('error', (error: Error) => resolve({ code: -1, output: error.message }));
    proc.on('close', (code: number) => resolve({ code: Number(code ?? -1), output }));
  });
}

// REQ-DMG-ENV-1 / REQ-WIN-DESKTOP-2: packaged apps do not reliably inherit
// shell/package-manager PATH entries. Keep provider CLIs visible to both the
// enrollment process and the service definition rendered by the installer.
function bridgeHostEnv(platform: NodeJS.Platform = process.platform): NodeJS.ProcessEnv {
  const home = os.homedir();
  if (platform === 'win32') {
    const roaming = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    const local = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
    const providerPaths = [
      path.join(roaming, 'npm'),
      path.join(local, 'pnpm'),
      path.join(home, '.local', 'bin'),
      path.join(home, '.bun', 'bin'),
      path.join(home, '.volta', 'bin'),
      path.join(home, '.cargo', 'bin'),
    ];
    return {
      ...process.env,
      PATH: [...providerPaths, process.env.PATH || ''].filter(Boolean).join(';'),
      HEIMDALL_INSTALL_PLAIN: '1',
    };
  }
  const providerPaths = [
    '/usr/bin', '/bin', '/usr/sbin', '/sbin',
    '/usr/local/bin', '/opt/homebrew/bin',
    path.join(home, '.local', 'bin'),
    path.join(home, '.npm-global', 'bin'),
    path.join(home, '.bun', 'bin'),
    path.join(home, '.volta', 'bin'),
    path.join(home, '.cargo', 'bin'),
    path.join(home, '.nix-profile', 'bin'),
    '/run/current-system/sw/bin', '/nix/var/nix/profiles/default/bin',
  ];
  return {
    ...process.env,
    // System tools stay first while common per-user package-manager locations
    // remain visible to the long-lived launchd bridge for provider discovery.
    PATH: providerPaths.join(':'),
    HEIMDALL_INSTALL_PLAIN: '1',
  };
}

function run(command: string, args: string[], platform: NodeJS.Platform = process.platform): Promise<{ code: number; output: string }> {
  return runProcess(command, args, bridgeHostEnv(platform));
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

function installInvocation(platform: NodeJS.Platform, files: ReturnType<typeof resources>, hubUrl: string, version: string) {
  if (platform === 'win32') return {
    command: powershellPath(),
    args: ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', files.installScript,
      '-Hub', hubUrl, '-Version', `v${version}`, '-Bundle', files.bundle, '-ChecksumFile', files.checksums, '-NonInteractive'],
  };
  return {
    command: '/bin/bash',
    args: [files.installScript, '--hub', hubUrl, '--version', `v${version}`,
      '--bundle', files.bundle, '--checksum-file', files.checksums, '--non-interactive'],
  };
}

async function installBundled(hubUrl: string) {
  if (busy || enrollmentProcess) return { ok: false, status: getStatus(hubUrl), error: 'A Bridge operation is already running.' };
  const platform = process.platform;
  const files = resources(platform);
  const version = bundledVersion(platform);
  if (!supportedPlatform(platform) || !version || !Object.values(files).every((file: any) => fs.existsSync(file))) {
    return { ok: false, status: getStatus(hubUrl), error: 'This app does not contain a complete Bridge bundle.' };
  }
  busy = true;
  try {
    const invocation = installInvocation(platform, files, hubUrl, version);
    const result = await run(invocation.command, invocation.args, platform);
    const error = result.code === 0 ? '' : commandError(result.output, `Installer exited with status ${result.code}.`);
    busy = false;
    return { ok: result.code === 0, status: getStatus(hubUrl), ...(error ? { error } : {}) };
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
  const platform = process.platform;
  const state = findState(hubUrl, platform);
  if (!supportedPlatform(platform) || !state) return { ok: false, status: getStatus(hubUrl), error: 'Install the packaged Bridge before restarting it.' };
  busy = true;
  let error = '';
  try {
    if (platform === 'darwin') {
      const plist = path.join(os.homedir(), 'Library', 'LaunchAgents', `${state.serviceName}.plist`);
      if (!fs.existsSync(plist)) error = `LaunchAgent is missing: ${plist}`;
      if (!error) {
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
      }
    } else {
      const script = "Stop-ScheduledTask -TaskPath '\\' -TaskName $env:HEIMDALL_BRIDGE_TASK_NAME -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskPath '\\' -TaskName $env:HEIMDALL_BRIDGE_TASK_NAME -ErrorAction Stop";
      const result = await runProcess(powershellPath(), ['-NoProfile', '-NonInteractive', '-Command', script], {
        ...process.env, HEIMDALL_BRIDGE_TASK_NAME: state.serviceName,
      });
      if (result.code !== 0) error = commandError(result.output, `Unable to restart ${state.serviceName}.`);
    }
  } catch (caught: any) {
    error = String(caught?.message || caught || 'Unable to restart the Bridge.');
  } finally {
    busy = false;
  }
  return { ok: !error, status: getStatus(hubUrl), ...(error ? { error } : {}) };
}

// restartSync is the quit-time variant of restart(): the app is exiting, so it
// cannot await child processes. Both launchctl and Scheduled Task commands are
// bounded and do not rely on the Electron event loop.
function restartSync(hubUrl: string): string {
  if (process.platform === 'win32') {
    const state = findState(hubUrl, 'win32');
    if (!state) return 'Install the packaged Bridge before restarting it.';
    const script = "Stop-ScheduledTask -TaskPath '\\' -TaskName $env:HEIMDALL_BRIDGE_TASK_NAME -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskPath '\\' -TaskName $env:HEIMDALL_BRIDGE_TASK_NAME -ErrorAction Stop";
    const result = childProcess.spawnSync(powershellPath(), ['-NoProfile', '-NonInteractive', '-Command', script], {
      stdio: 'ignore', timeout: 5000, windowsHide: true,
      env: { ...bridgeHostEnv('win32'), HEIMDALL_BRIDGE_TASK_NAME: state.serviceName },
    });
    return result.status === 0 ? '' : `Unable to restart ${state.serviceName}.`;
  }
  const agent = launchAgent(hubUrl);
  if (agent.error) return agent.error;
  const options = { stdio: 'ignore', timeout: 5000 };
  if (childProcess.spawnSync('/bin/launchctl', ['print', agent.target], options).status !== 0
    && childProcess.spawnSync('/bin/launchctl', ['bootstrap', `gui/${process.getuid()}`, agent.plist], options).status !== 0) {
    return `Unable to load ${agent.serviceName}.`;
  }
  return childProcess.spawnSync('/bin/launchctl', ['kickstart', '-k', agent.target], options).status === 0 ? '' : `Unable to restart ${agent.serviceName}.`;
}

function enrollmentInvocation(platform: NodeJS.Platform, script: string, reuseBridgeId = '') {
  if (platform === 'win32') return {
    command: powershellPath(),
    args: ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, '-Headless',
      ...(reuseBridgeId ? ['-ReuseBridge', reuseBridgeId] : [])],
  };
  return { command: '/bin/bash', args: [script, '--headless', ...(reuseBridgeId ? ['--reuse-bridge', reuseBridgeId] : [])] };
}

function startEnrollment(
  hubUrl: string,
  emit: (event: any) => void,
  options: { restartOnFailure?: boolean; reuseBridgeId?: string } = {},
) {
  if (enrollmentProcess) return { ok: false, error: 'Enrollment is already running.' };
  const platform = process.platform;
  const state = findState(hubUrl, platform);
  const script = state && path.join(state.stateDir, desktopPaths(platform).enrollScriptName);
  if (!supportedPlatform(platform) || !script || !fs.existsSync(script)) return { ok: false, error: 'Install the packaged Bridge before enrolling it.' };
  const reuseBridgeId = String(options.reuseBridgeId || '').trim();
  if (reuseBridgeId && !BRIDGE_ID_PATTERN.test(reuseBridgeId)) return { ok: false, error: 'The previous Bridge ID is invalid; refusing to re-enroll it.' };
  const invocation = enrollmentInvocation(platform, script, reuseBridgeId);
  // On Unix the detached process group lets stopEnrollment() terminate the
  // shell and ham-bridge together. Windows uses taskkill /T for the same tree.
  const proc = childProcess.spawn(invocation.command, invocation.args, {
    env: bridgeHostEnv(platform),
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: platform !== 'win32',
    windowsHide: true,
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
  if (process.platform === 'win32') {
    try { childProcess.spawnSync('taskkill.exe', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore', timeout: 5000, windowsHide: true }); }
    catch (_err) { try { proc.kill(); } catch (_ignored) { /* Already exited. */ } }
  } else {
    try { process.kill(-proc.pid, 'SIGTERM'); } catch (_err) { try { proc.kill('SIGTERM'); } catch (_ignored) { /* Already exited. */ } }
  }
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

module.exports = {
  bridgeHostEnv,
  desktopPaths,
  discoverBridgeId,
  enrollmentInvocation,
  extractEnrollmentPairing,
  findState,
  getStatus,
  installBundled,
  installInvocation,
  resources,
  restart,
  startEnrollment,
  startReEnrollment,
  stopEnrollment,
  supportedPlatform,
};
