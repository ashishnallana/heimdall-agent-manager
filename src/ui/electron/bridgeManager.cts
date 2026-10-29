const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const childProcess = require('child_process');

// REQ-ENR-5 / REQ-ENR-9: Electron drives the Bridge lifecycle only through the
// ham-bridge CLI (`setup|update|uninstall|status|list`, see
// docs/bridge-setup-progress.md). It never runs install scripts, renders
// services, edits PATH or discovers state itself: ham-bridge owns all of that on
// Linux, macOS and Windows. All host mutation stays in Electron's main process;
// the renderer receives structured status/progress and asks for explicit actions.

const RELEASES_URL = 'https://api.github.com/repos/tanmayv/heimdall-agent-manager/releases?per_page=30';
const RELEASE_DOWNLOAD_BASE = 'https://github.com/tanmayv/heimdall-agent-manager/releases/download';
const PROFILE_PATTERN = /^[a-z0-9][a-z0-9-]{0,30}$/;
const SERVICE_PATTERN = /^heimdall-bridge-[a-z0-9-]+(?:_[a-z0-9][a-z0-9-]{0,30})?$/;
const BRIDGE_ID_PATTERN = /^brg_[A-Za-z0-9_-]{1,60}$/;
const VERSION_PATTERN = /^v?[0-9A-Za-z._-]+$/;

// F26: every child process is bounded. Setup includes browser approval of the
// pairing code, so its limit is generous; status/list are quick reads.
const TIMEOUTS = {
  query: 15_000,
  download: 5 * 60_000,
  setup: 20 * 60_000,
  update: 15 * 60_000,
  uninstall: 5 * 60_000,
  // How long a Windows uninstall's relocated %TEMP% copy may take to remove
  // bin\ham-bridge.exe after the parent hand-off exits.
  uninstallSettle: 60_000,
  // How long quitting the app waits for a cancelled operation's rollback.
  quit: 90_000,
};

type Platform = NodeJS.Platform;
type BridgeProfile = { hub: string; profile?: string; service?: string };
type OperationKind = 'setup' | 'update' | 'reenroll' | 'uninstall';
type Emit = (event: any) => void;

function supportedPlatform(platform: Platform = process.platform): boolean {
  return platform === 'darwin' || platform === 'win32' || platform === 'linux';
}

function normalizeHubUrl(value: string): string {
  try {
    const url = new URL(String(value || '').trim());
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return '';
    return url.origin;
  } catch (_err) { return ''; }
}

// releaseTarget names the release bundle for this machine. Windows on Arm runs
// the amd64 build through the OS x64 compatibility layer.
function releaseTarget(platform: Platform = process.platform, arch: string = process.arch): string {
  if (platform === 'win32') return 'windows-amd64';
  const cpu = arch === 'arm64' ? 'arm64' : 'amd64';
  return platform === 'darwin' ? `darwin-${cpu}` : `linux-${cpu}`;
}

function archiveName(target: string, version: string, platform: Platform = process.platform): string {
  return `heimdall-local-${target}-${version}.${platform === 'win32' ? 'zip' : 'tar.gz'}`;
}

function binaryName(platform: Platform = process.platform): string {
  return platform === 'win32' ? 'ham-bridge.exe' : 'ham-bridge';
}

function bundledResources(
  platform: Platform = process.platform,
  arch: string = process.arch,
  resourcesRoot: string = process.env.HEIMDALL_BRIDGE_RESOURCES || path.join((process as any).resourcesPath || '', 'bridge'),
) {
  const target = releaseTarget(platform, arch);
  const ext = platform === 'win32' ? 'zip' : 'tar.gz';
  return {
    bundle: path.join(resourcesRoot, `heimdall-local-${target}.${ext}`),
    checksums: path.join(resourcesRoot, 'SHA256SUMS'),
    metadata: path.join(resourcesRoot, 'METADATA.json'),
  };
}

function bundledVersion(platform: Platform = process.platform): string {
  try { return String(JSON.parse(fs.readFileSync(bundledResources(platform).metadata, 'utf8'))?.version || '').replace(/^v/, ''); }
  catch (_err) { return ''; }
}

function cacheRoot(): string {
  const base = process.env.HEIMDALL_BRIDGE_CACHE
    || (process.platform === 'win32'
      ? path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'heimdall', 'releases')
      : path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'), 'heimdall', 'releases'));
  return base;
}

// profileArgs selects one profile explicitly (never "the only installed one"):
// --service when the caller has it, else --hub [--profile].
function profileArgs(target: BridgeProfile, allowService = true): string[] {
  const service = allowService ? String(target?.service || '') : '';
  if (service) {
    if (!SERVICE_PATTERN.test(service)) throw new Error('Invalid bridge service name.');
    return ['--service', service];
  }
  const hub = normalizeHubUrl(target?.hub || '');
  if (!hub) throw new Error('A valid Hub URL (https://…) is required.');
  const profile = String(target?.profile || '');
  if (profile && !PROFILE_PATTERN.test(profile)) throw new Error('Profile names use lower-case letters, digits and dashes.');
  return ['--hub', hub, ...(profile ? ['--profile', profile] : [])];
}

// ---------------------------------------------------------------------------
// Child processes: bounded, cancellable, process-tree aware.
// ---------------------------------------------------------------------------

type Running = { proc: any; kill: () => void };

function killTree(proc: any) {
  if (!proc || proc.exitCode !== null && proc.exitCode !== undefined) return;
  if (process.platform === 'win32') {
    try { childProcess.spawnSync('taskkill.exe', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore', timeout: 5000, windowsHide: true }); }
    catch (_err) { try { proc.kill(); } catch (_ignored) { /* Already exited. */ } }
    return;
  }
  try { process.kill(-proc.pid, 'SIGTERM'); } catch (_err) { try { proc.kill('SIGTERM'); } catch (_ignored) { /* Already exited. */ } }
}

// runCommand runs one process with a hard timeout. onLine receives complete
// stdout/stderr lines. The returned handle can cancel it (whole process tree).
function runCommand(
  command: string,
  args: string[],
  options: { timeoutMs: number; onLine?: (line: string, stream: 'stdout' | 'stderr') => void; register?: (running: Running) => void },
): Promise<{ code: number; output: string; timedOut: boolean; cancelled: boolean }> {
  return new Promise((resolve) => {
    let proc: any;
    try {
      proc = childProcess.spawn(command, args, {
        stdio: ['ignore', 'pipe', 'pipe'],
        // A process group of its own lets cancel terminate ham-bridge and the
        // enrollment it spawns together. Windows uses taskkill /T instead.
        detached: process.platform !== 'win32',
        windowsHide: true,
      });
    } catch (error: any) {
      resolve({ code: -1, output: String(error?.message || error), timedOut: false, cancelled: false });
      return;
    }
    let output = '';
    let timedOut = false;
    let cancelled = false;
    let settled = false;
    const partial = { stdout: '', stderr: '' };
    const collect = (stream: 'stdout' | 'stderr') => (chunk: any) => {
      const text = String(chunk || '');
      output = (output + text).slice(-64_000);
      partial[stream] += text;
      const lines = partial[stream].split(/\r?\n/);
      partial[stream] = lines.pop() || '';
      for (const line of lines) options.onLine?.(line, stream);
    };
    proc.stdout?.on('data', collect('stdout'));
    proc.stderr?.on('data', collect('stderr'));
    const timer = setTimeout(() => { timedOut = true; killTree(proc); }, options.timeoutMs);
    const finish = (code: number) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      for (const stream of ['stdout', 'stderr'] as const) if (partial[stream]) options.onLine?.(partial[stream], stream);
      resolve({ code, output, timedOut, cancelled });
    };
    options.register?.({ proc, kill: () => { cancelled = true; killTree(proc); } });
    proc.on('error', (error: Error) => { output += error.message; finish(-1); });
    proc.on('close', (code: number | null) => finish(code === null ? -1 : Number(code)));
  });
}

function tailError(output: string, fallback: string): string {
  return output.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').trim().split('\n').filter((line) => !line.startsWith('{')).slice(-8).join('\n') || fallback;
}

// parseProgressLine accepts one --json-progress line. Plain text lines (the
// enrollment's own prompts) are returned as null and shown as log output.
function parseProgressLine(line: string): any | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith('{')) return null;
  try {
    const value = JSON.parse(trimmed);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch (_err) { return null; }
}

function extractEnrollmentPairing(output: string): { url: string; code: string } | null {
  const url = output.match(/https?:\/\/[^\s]+\/api\/v1\/device\/add[^\s]*/)?.[0]?.replace(/[),.;]+$/, '') || '';
  // Pairing codes contain 14 RFC 4648 base32 symbols, rendered XXXX-XXXX-XXXX-XX.
  const code = output.match(/\b[A-Z2-7]{4}(?:-[A-Z2-7]{4}){2}-[A-Z2-7]{2}\b/)?.[0] || '';
  return url && code ? { url, code } : null;
}

// ---------------------------------------------------------------------------
// Locating a ham-bridge binary.
// ---------------------------------------------------------------------------

function findBinary(root: string, platform: Platform = process.platform, depth = 3): string {
  const name = binaryName(platform);
  for (const candidate of [path.join(root, name), path.join(root, 'bin', name)]) {
    if (fs.existsSync(candidate)) return candidate;
  }
  if (depth <= 0) return '';
  let entries: any[] = [];
  try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (_err) { return ''; }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const found = findBinary(path.join(root, entry.name), platform, depth - 1);
    if (found) return found;
  }
  return '';
}

// installedBinaries are the ham-bridge executables of installed profiles; any
// of them can answer `list` / `status`, which read only per-user files.
function installedBinaries(platform: Platform = process.platform): string[] {
  const home = os.homedir();
  const dataRoot = platform === 'win32'
    ? path.join(process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'heimdall', 'bridges')
    : path.join(home, '.local', 'share', 'heimdall', 'bridges');
  let names: string[] = [];
  try { names = fs.readdirSync(dataRoot).sort(); } catch (_err) { return []; }
  return names
    .map((name) => path.join(dataRoot, name, 'bin', binaryName(platform)))
    .filter((binary) => fs.existsSync(binary));
}

let preparedBinary = '';

// queryBinary is any ham-bridge that can read status: the one prepared for the
// last operation, an installed profile's, or the cached/bundled release.
function queryBinary(): string {
  if (process.env.HEIMDALL_HAM_BRIDGE) return process.env.HEIMDALL_HAM_BRIDGE;
  if (preparedBinary && fs.existsSync(preparedBinary)) return preparedBinary;
  return installedBinaries()[0] || findBinary(cacheRoot(), process.platform, 4);
}

function sha256File(file: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    fs.createReadStream(file).on('error', reject).on('data', (chunk: any) => hash.update(chunk)).on('end', () => resolve(hash.digest('hex')));
  });
}

function checksumFor(sums: string, archive: string): string {
  for (const line of sums.split(/\r?\n/)) {
    const match = line.trim().match(/^([0-9a-fA-F]{64})\s+\*?(.+)$/);
    if (match && match[2].trim() === archive) return match[1].toLowerCase();
  }
  return '';
}

async function verifyArchive(file: string, sums: string, archive: string): Promise<void> {
  const expected = checksumFor(sums, archive);
  if (!expected) throw new Error(`SHA256SUMS does not list ${archive}.`);
  const actual = await sha256File(file);
  if (actual !== expected) throw new Error(`SHA-256 mismatch for ${archive}; refusing to install it.`);
}

// extractArchive unpacks a verified bundle. bsdtar (macOS, Windows 10+) reads
// both .tar.gz and .zip; GNU tar reads the Linux .tar.gz.
async function extractArchive(file: string, dest: string, register: (running: Running) => void): Promise<void> {
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  const tar = process.platform === 'win32' ? path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'tar.exe') : 'tar';
  const args = file.endsWith('.zip') ? ['-xf', file, '-C', dest] : ['-xzf', file, '-C', dest];
  const result = await runCommand(tar, args, { timeoutMs: TIMEOUTS.download, register });
  if (result.code !== 0) throw new Error(tailError(result.output, `Unable to extract ${path.basename(file)}.`));
}

type FetchLike = (url: string, init?: any) => Promise<any>;

async function fetchWithTimeout(fetchImpl: FetchLike, url: string, signal: AbortSignal): Promise<any> {
  const response = await fetchImpl(url, { signal, headers: { 'user-agent': 'heimdall-desktop' } });
  if (!response.ok) throw new Error(`GET ${url} returned ${response.status}.`);
  return response;
}

// latestRelease picks the newest promoted (not draft, not prerelease) release
// that ships this machine's bundle (the bootstraps apply the same rule).
function latestRelease(releases: any[], target: string, platform: Platform = process.platform): string {
  for (const release of Array.isArray(releases) ? releases : []) {
    if (release?.draft || release?.prerelease) continue;
    const tag = String(release?.tag_name || '');
    if (!VERSION_PATTERN.test(tag)) continue;
    const names = new Set((release?.assets || []).map((asset: any) => String(asset?.name || '')));
    if (names.has(archiveName(target, tag, platform)) && names.has('SHA256SUMS')) return tag;
  }
  return '';
}

// prepareBinary (F27) downloads and SHA-256-verifies the latest release and
// returns its ham-bridge. The bundle shipped inside the app is only the
// offline fallback, used when the release cannot be fetched.
async function prepareBinary(
  emit: Emit,
  register: (running: Running) => void,
  options: { fetchImpl?: FetchLike; version?: string } = {},
): Promise<{ binary: string; version: string; source: 'release' | 'bundled' | 'override' }> {
  if (process.env.HEIMDALL_HAM_BRIDGE) return { binary: process.env.HEIMDALL_HAM_BRIDGE, version: '', source: 'override' };
  const platform = process.platform;
  const target = releaseTarget(platform);
  const fetchImpl: FetchLike = options.fetchImpl || (globalThis as any).fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUTS.download);
  register({ proc: null, kill: () => controller.abort() });
  try {
    emit({ step: 'download', state: 'start', pct: 0, message: 'Looking up the latest Bridge release…' });
    const version = options.version || latestRelease(await (await fetchWithTimeout(fetchImpl, RELEASES_URL, controller.signal)).json(), target, platform);
    if (!version) throw new Error(`No published Bridge release for ${target}.`);
    const archive = archiveName(target, version, platform);
    const dir = path.join(cacheRoot(), version);
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const sums = await (await fetchWithTimeout(fetchImpl, `${RELEASE_DOWNLOAD_BASE}/${version}/SHA256SUMS`, controller.signal)).text();
    const file = path.join(dir, archive);
    let verified = false;
    if (fs.existsSync(file)) {
      try { await verifyArchive(file, sums, archive); verified = true; } catch (_err) { fs.rmSync(file, { force: true }); }
    }
    if (!verified) {
      emit({ step: 'download', state: 'progress', pct: 20, message: `Downloading ${archive}…` });
      const response = await fetchWithTimeout(fetchImpl, `${RELEASE_DOWNLOAD_BASE}/${version}/${archive}`, controller.signal);
      fs.writeFileSync(`${file}.part`, Buffer.from(await response.arrayBuffer()), { mode: 0o600 });
      await verifyArchive(`${file}.part`, sums, archive);
      fs.renameSync(`${file}.part`, file);
    }
    const extracted = path.join(dir, 'bundle');
    await extractArchive(file, extracted, register);
    const binary = findBinary(extracted, platform);
    if (!binary) throw new Error(`${archive} does not contain ${binaryName(platform)}.`);
    emit({ step: 'download', state: 'ok', pct: 100, message: `Bridge ${version} downloaded and verified.` });
    preparedBinary = binary;
    return { binary, version: version.replace(/^v/, ''), source: 'release' };
  } catch (error: any) {
    if (controller.signal.aborted && cancelRequested) throw error;
    const files = bundledResources(platform);
    const version = bundledVersion(platform);
    if (!version || !fs.existsSync(files.bundle) || !fs.existsSync(files.checksums)) {
      throw new Error(`Unable to download the Bridge (${String(error?.message || error)}) and this app has no bundled Bridge to fall back to.`);
    }
    emit({ step: 'download', state: 'retry', pct: 50, failure: 'offline', message: `Download failed (${String(error?.message || error)}); using the Bridge ${version} bundled with this app.` });
    await verifyArchive(files.bundle, fs.readFileSync(files.checksums, 'utf8'), path.basename(files.bundle));
    const extracted = path.join(cacheRoot(), `bundled-${version}`);
    await extractArchive(files.bundle, extracted, register);
    const binary = findBinary(extracted, platform);
    if (!binary) throw new Error(`The bundled Bridge does not contain ${binaryName(platform)}.`);
    emit({ step: 'download', state: 'ok', pct: 100, message: `Using the bundled Bridge ${version}.` });
    preparedBinary = binary;
    return { binary, version, source: 'bundled' };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Status.
// ---------------------------------------------------------------------------

async function runJson(binary: string, args: string[]): Promise<any> {
  const result = await runCommand(binary, args, { timeoutMs: TIMEOUTS.query });
  if (result.timedOut) throw new Error(`ham-bridge ${args[0]} timed out.`);
  const line = result.output.split(/\r?\n/).map(parseProgressLine).find(Boolean);
  if (!line) throw new Error(tailError(result.output, `ham-bridge ${args[0]} returned no JSON.`));
  return line;
}

// listProfiles returns every bridge profile installed for this OS user
// (`ham-bridge list --json`), or [] when ham-bridge has never been installed.
async function listProfiles(): Promise<any[]> {
  if (!supportedPlatform()) return [];
  const binary = queryBinary();
  if (!binary) return [];
  const result = await runJson(binary, ['list', '--json']);
  return Array.isArray(result?.profiles) ? result.profiles : [];
}

// getStatus reports one profile (`ham-bridge status --json`) plus what the app
// can do about it. `state` is ham-bridge's single word for the UI.
async function getStatus(target: BridgeProfile) {
  const base = {
    supported: supportedPlatform(),
    busy: Boolean(current),
    operation: current ? current.kind : '',
    bundledVersion: bundledVersion(),
    hub: normalizeHubUrl(target?.hub || ''),
    profile: String(target?.profile || ''),
  };
  if (!base.supported) return { ...base, installed: false, state: 'unsupported', error: '' };
  const binary = queryBinary();
  if (!binary) return { ...base, installed: false, state: 'not_installed', error: '' };
  try {
    const status = await runJson(binary, ['status', '--json', ...profileArgs(target)]);
    return { ...base, ...status, installed: Boolean(status?.installed), state: String(status?.state || (status?.installed ? 'stopped' : 'not_installed')), error: '' };
  } catch (error: any) {
    return { ...base, installed: false, state: 'unknown', error: String(error?.message || error) };
  }
}

// ---------------------------------------------------------------------------
// Operations: setup (wizard), update, re-enroll, uninstall.
// ---------------------------------------------------------------------------

let current: { kind: OperationKind; target: BridgeProfile; running: Running[]; wasInstalled: boolean; settled: Promise<unknown> } | null = null;
let cancelRequested = false;

function operationArgs(kind: OperationKind, target: BridgeProfile, options: { bridgeId?: string; purge?: boolean; bundleDir?: string; replaceOtherAccount?: boolean; stateDir?: string }): string[] {
  // setup and enroll name a profile by Hub (+ profile); the others also take --service.
  const select = profileArgs(target, kind === 'update' || kind === 'uninstall');
  switch (kind) {
    case 'setup':
      return ['setup', ...select, '--headless', '--json-progress', ...(options.replaceOtherAccount ? ['--replace-other-account'] : [])];
    case 'reenroll': {
      // `enroll` has no --profile: it names the profile's files explicitly
      // (state_dir from `status --json`), exactly as `setup` does.
      const bridgeId = String(options.bridgeId || '');
      if (bridgeId && !BRIDGE_ID_PATTERN.test(bridgeId)) throw new Error('The previous Bridge ID is invalid; refusing to re-enroll it.');
      const stateDir = String(options.stateDir || '');
      if (!stateDir || !path.isAbsolute(stateDir)) throw new Error('The installed Bridge did not report its state directory; refusing to re-enroll it.');
      return ['enroll', '--hub', select[1], '--config', path.join(stateDir, 'config.toml'), '--bridge-token-file', path.join(stateDir, 'bridge-token'),
        '--headless', '--json-progress', ...(bridgeId ? ['--reuse-bridge', bridgeId] : ['--new-bridge']),
        ...(options.replaceOtherAccount ? ['--replace-other-account'] : [])];
    }
    case 'update':
      return ['update', '--bundle', String(options.bundleDir || ''), ...select, '--json-progress'];
    case 'uninstall':
      return ['uninstall', ...select, options.purge ? '--purge' : '--keep-data', '--yes', '--json-progress'];
  }
  throw new Error(`Unknown operation ${kind}.`);
}

// runOperation performs one lifecycle operation and streams events to `emit`:
//   {type:'progress', step, state, pct, message, log, attempt, failure}  (ham-bridge --json-progress and the app's own `download` step)
//   {type:'output', message}            plain log lines
//   {type:'pairing', url, code}         an enrollment approval code
//   {type:'complete', status}           success
//   {type:'error', message, step, cancelled, timedOut, rolledBack}
// Only one operation runs at a time. Cancel (cancelOperation) terminates the
// process tree; ham-bridge setup rolls itself back, and a cancelled first
// install is then uninstalled so nothing is left half-configured.
function runOperation(
  kind: OperationKind,
  target: BridgeProfile,
  emit: Emit,
  options: { bridgeId?: string; purge?: boolean; replaceOtherAccount?: boolean; fetchImpl?: FetchLike } = {},
): Promise<{ ok: boolean; error?: string }> {
  if (!supportedPlatform()) return Promise.resolve({ ok: false, error: 'This platform cannot run a Heimdall Bridge.' });
  if (current) return Promise.resolve({ ok: false, error: 'A Bridge operation is already running.' });
  // performOperation claims `current` before its first await, so the claim
  // exists by the time it returns; stopOnQuit waits on `settled`.
  const settled = performOperation(kind, target, emit, options);
  const op = current as { settled: Promise<unknown> } | null;
  if (op) op.settled = settled;
  return settled;
}

async function performOperation(
  kind: OperationKind,
  target: BridgeProfile,
  emit: Emit,
  options: { bridgeId?: string; purge?: boolean; replaceOtherAccount?: boolean; fetchImpl?: FetchLike } = {},
): Promise<{ ok: boolean; error?: string }> {
  try { profileArgs(target, kind === 'update' || kind === 'uninstall'); } catch (error: any) { return { ok: false, error: String(error?.message || error) }; }
  // Claim the slot before the first await so a second call is refused.
  const op: NonNullable<typeof current> = { kind, target, running: [], wasInstalled: false, settled: Promise.resolve() };
  current = op;
  cancelRequested = false;
  let before: any = { installed: false };
  const register = (running: Running) => { op.running.push(running); if (cancelRequested) running.kill(); };
  let lastStep = '';
  const onProgress = (event: any) => {
    if (event?.step) lastStep = String(event.step);
    emit({ type: 'progress', ...event });
  };
  let pairingSent = false;
  let plain = '';
  const onLine = (line: string) => {
    const event = parseProgressLine(line);
    if (event?.event === 'enroll_code') {
      emit({ type: 'pairing', url: String(event.approval_url || ''), code: String(event.pairing_code || ''), issue: Number(event.issue || 1) });
      pairingSent = true;
      return;
    }
    if (event && typeof event.step === 'string') { onProgress(event); return; }
    if (!line.trim()) return;
    emit({ type: 'output', message: line });
    plain = (plain + line + '\n').slice(-16_000);
    const pairing = !pairingSent && extractEnrollmentPairing(plain);
    if (pairing) { pairingSent = true; emit({ type: 'pairing', ...pairing }); }
  };
  try {
    before = await getStatus(target);
    op.wasInstalled = Boolean(before.installed);
    let binary = '';
    let bundleDir = '';
    if (kind === 'setup' || kind === 'update') {
      const prepared = await prepareBinary(onProgress, register, { fetchImpl: options.fetchImpl });
      binary = prepared.binary;
      bundleDir = path.dirname(binary).endsWith(`${path.sep}bin`) ? path.dirname(path.dirname(binary)) : path.dirname(binary);
    } else {
      binary = kind === 'uninstall' ? uninstallBinary() : queryBinary();
      if (!binary) throw new Error('No installed Bridge was found on this machine.');
    }
    if (cancelRequested) throw Object.assign(new Error('Cancelled.'), { cancelled: true });
    if (kind === 'reenroll' && !before.installed) throw new Error('Install the Bridge on this machine before re-enrolling it.');
    const args = operationArgs(kind, target, { ...options, bundleDir, stateDir: String(before.state_dir || '') });
    const result = await runCommand(binary, args, { timeoutMs: TIMEOUTS[kind === 'reenroll' ? 'setup' : kind], onLine, register });
    if (result.code === 0 && !result.cancelled && !result.timedOut) {
      // A Windows uninstall started from bin\ham-bridge.exe relocates to
      // %TEMP% and its parent exits 0 at once, so the exit code alone proves
      // nothing: confirm the profile is really gone.
      if (kind === 'uninstall') await confirmUninstalled(target);
      emit({ type: 'complete', status: await getStatus(target) });
      return { ok: true };
    }
    const reason = result.cancelled ? 'Cancelled.'
      : result.timedOut ? `The ${kind} did not finish within ${Math.round(TIMEOUTS[kind === 'reenroll' ? 'setup' : kind] / 60_000)} minutes and was stopped.`
      : tailError(result.output, `ham-bridge ${args[0]} exited with status ${result.code}.`);
    throw Object.assign(new Error(reason), { cancelled: result.cancelled, timedOut: result.timedOut });
  } catch (error: any) {
    const cancelled = Boolean(error?.cancelled || cancelRequested);
    let rolledBack = false;
    // Cancel = rollback: ham-bridge setup undoes its own completed steps on a
    // failure; a first install that the user cancelled or that timed out is
    // also removed so the machine returns to "not installed".
    if (kind === 'setup' && !op.wasInstalled && (cancelled || error?.timedOut)) {
      const after = await getStatus(target);
      if (after.installed && queryBinary()) {
        emit({ type: 'progress', step: 'rollback', state: 'start', pct: 0, message: 'Removing the partial install…' });
        const undo = await runCommand(queryBinary(), operationArgs('uninstall', target, { purge: true }), { timeoutMs: TIMEOUTS.uninstall, onLine });
        rolledBack = undo.code === 0;
      } else rolledBack = true;
    }
    const message = String(error?.message || error || 'The Bridge operation failed.');
    emit({ type: 'error', message, step: lastStep, cancelled, timedOut: Boolean(error?.timedOut), rolledBack });
    return { ok: false, error: message };
  } finally {
    current = null;
    cancelRequested = false;
  }
}

// uninstallBinary prefers a ham-bridge outside the profile's bin/ (the one this
// app prepared, or a cached release): run from there, Windows uninstall needs
// no %TEMP% relocation and its exit code is the real result.
function uninstallBinary(): string {
  if (process.env.HEIMDALL_HAM_BRIDGE) return process.env.HEIMDALL_HAM_BRIDGE;
  if (preparedBinary && fs.existsSync(preparedBinary)) return preparedBinary;
  return findBinary(cacheRoot(), process.platform, 4) || installedBinaries()[0] || '';
}

// confirmUninstalled waits (bounded) for `status --json` to stop reporting
// the profile installed, and throws if it never does.
async function confirmUninstalled(target: BridgeProfile, settleMs: number = TIMEOUTS.uninstallSettle): Promise<void> {
  const deadline = Date.now() + settleMs;
  for (;;) {
    const after = await getStatus(target);
    if (!after.installed) return;
    if (Date.now() >= deadline) throw new Error('ham-bridge uninstall reported success, but this Bridge is still installed. Check the uninstall log and try again.');
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
}

function cancelOperation(): boolean {
  if (!current) return false;
  cancelRequested = true;
  for (const running of current.running) running.kill();
  return true;
}

function operationRunning(): boolean {
  return Boolean(current);
}

// stopOnQuit (app quit): a running operation is cancelled and the returned
// promise settles once it has finished, including the rollback of a cancelled
// first install, or after waitMs. The caller holds the quit until then. The
// installed Bridge service itself is independent of the app and keeps running.
function stopOnQuit(waitMs: number = TIMEOUTS.quit): Promise<void> {
  const op = current;
  if (!op) return Promise.resolve();
  cancelOperation();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<void>((resolve) => { timer = setTimeout(resolve, waitMs); });
  return Promise.race([op.settled.then(() => undefined, () => undefined), timeout]).finally(() => clearTimeout(timer));
}

module.exports = {
  TIMEOUTS,
  bundledResources,
  bundledVersion,
  cancelOperation,
  checksumFor,
  extractEnrollmentPairing,
  getStatus,
  latestRelease,
  listProfiles,
  normalizeHubUrl,
  operationArgs,
  operationRunning,
  parseProgressLine,
  prepareBinary,
  profileArgs,
  releaseTarget,
  runCommand,
  runOperation,
  stopOnQuit,
  supportedPlatform,
};
