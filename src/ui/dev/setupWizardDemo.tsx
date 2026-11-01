/**
 * Setup-wizard fixture (setup-wizard-demo.html): the REAL SetupWizardPage, driven by a
 * scripted fake of the desktop app's bridgeManager and a fixture hub. Dev only, like
 * composer-demo.html: vite.config.js has no rollupOptions.input, so `vite build` never
 * emits it.
 *
 * SAFETY: setupWizardDemoGuard (imported first) replaces fetch/WebSocket/EventSource,
 * answers only the routes below and refuses everything else, so nothing on this page
 * can reach a real hub. Mutations (approve, revoke, project create) are answered by the
 * fixture and listed in the "Requests" panel.
 *
 * NOT NATIVE: no ham-bridge runs. Install progress, the pairing code and connection
 * status are scripted. The vault approval signature needs this browser's approved
 * device vault, which a fixture has none of, so "approve" stops with the real
 * vault error (shown as such) rather than pretending to enroll.
 *
 * ?scenario=<id>, see SCENARIOS.
 */
import './setupWizardDemoGuard';
import { demoCalls, setDemoRouter, subscribeDemoCalls, type DemoRequest } from './setupWizardDemoGuard';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { combineReducers, configureStore } from '@reduxjs/toolkit';
import { heimdallApi } from '../api/heimdallApi';
import { accountBillingApi } from '../api/endpoints/accountBilling';
import '../api/endpoints/bridgeSupport';
import '../api/endpoints/projects';
import vaultReducer, { keyringInstalled } from '../store/vaultSlice';
import deviceVaultReducer, { deviceVaultIdentityKnown } from '../store/deviceVaultSlice';
import themeReducer, { applyThemeToDocument } from '../store/themeSlice';
import { setActiveVaultKey } from '../utils/vaultCrypto';
import { derivePairKeys, generatePairCode, generatePairSalt, pairBridgePayload, pairKeyMac } from '../utils/vaultPairing';
import { pairingHubOrigin } from '../api/endpoints/vaultDevices';
import { toLowerHex } from '../utils/vaultStatements';
import type { DesktopBridgeEvent, DesktopBridgeManagerApi, DesktopBridgeStatus } from '../bridge/desktopBridge';
import SetupWizardPage from '../components/setup/SetupWizardPage';
import '../styles.css';

const USER = 'usr_fixture';
const OLD_VERSION = '0.5.30';
const LATEST = '0.5.32';

interface Scenario {
  id: string;
  label: string;
  note: string;
  native: 'current' | 'none' | 'legacy';
  supported?: boolean;
  installed?: 'none' | 'own' | 'other';
  maxBridges: number;
  /** Bridges already on the account (the hub's /bridges rows). */
  bridges: number;
  updateAvailable?: boolean;
  installFails?: boolean;
  reuseHint?: boolean;
}

const SCENARIOS: Scenario[] = [
  { id: 'fresh', label: 'Fresh machine', note: 'Nothing installed, room on the plan → Install → pairing → choose identity (new).', native: 'current', installed: 'none', maxBridges: 3, bridges: 1 },
  { id: 'full-plan', label: 'Plan full', note: 'Nothing installed, plan full (2 of 2) → identity offers reuse or register-new-and-sunset.', native: 'current', installed: 'none', maxBridges: 2, bridges: 2 },
  { id: 'reuse-hint', label: 'Reinstall (reuse hint)', note: 'The machine names a previous bridge → reuse is preselected, with the sign-out warning.', native: 'current', installed: 'none', maxBridges: 2, bridges: 2, reuseHint: true },
  { id: 'connected', label: 'Already connected', note: 'Own bridge installed and connected, up to date → machine card → Agents → Projects.', native: 'current', installed: 'own', maxBridges: 3, bridges: 1 },
  { id: 'update', label: 'Update available', note: `Own bridge installed at v${OLD_VERSION}; hub says v${LATEST} is out.`, native: 'current', installed: 'own', maxBridges: 3, bridges: 1, updateAvailable: true },
  { id: 'install-fails', label: 'Install fails', note: 'Setup fails at the service step → failure card with retry / copy log.', native: 'current', installed: 'none', maxBridges: 3, bridges: 1, installFails: true },
  { id: 'other-account', label: 'Other account here', note: "Another account's bridge is installed on this machine; setup installs alongside it.", native: 'current', installed: 'other', maxBridges: 3, bridges: 1 },
  { id: 'unsupported', label: 'Unsupported platform', note: 'The desktop app reports this platform cannot run a bridge.', native: 'current', supported: false, installed: 'none', maxBridges: 3, bridges: 1 },
  { id: 'not-desktop', label: 'Browser (not desktop)', note: 'No desktop app API → the browser fallback.', native: 'none', maxBridges: 3, bridges: 1 },
  { id: 'legacy-app', label: 'Old desktop app', note: 'An older desktop app (pre-v0.5.22 bridge manager) → the legacy fallback.', native: 'legacy', maxBridges: 3, bridges: 1 },
];

const params = new URLSearchParams(location.search);
const scenario = SCENARIOS.find((s) => s.id === params.get('scenario')) || SCENARIOS[0];

// ---------------------------------------------------------------------------
// Fixture hub data

const HUB_URL = location.origin;
const BRIDGE_NAMES = ['studio-mac', 'build-box', 'old-laptop'];
const accountBridges = Array.from({ length: scenario.bridges }, (_, i) => ({
  bridge_id: `brg_fixture_${i + 1}`,
  label: BRIDGE_NAMES[i] || `bridge-${i + 1}`,
  machine_hostname: BRIDGE_NAMES[i] || `bridge-${i + 1}`,
  status: i === 0 ? 'online' : 'offline',
  version: scenario.updateAvailable ? OLD_VERSION : LATEST,
  update_available: Boolean(scenario.updateAvailable && i === 0),
  latest_version: LATEST,
  latest_commit_sha: '8d895ea6c0ffee00',
  created_at: '2026-09-01T10:00:00Z',
  revoked_at: '',
}));
const THIS_MACHINE = 'this-workstation';
const ownProfile: DesktopBridgeStatus = {
  supported: true, busy: false, operation: '', installed: true, state: 'connected', hub: HUB_URL, profile: 'default', service: 'ham-bridge',
  enrolled: true, running: true, connected: true, version: scenario.updateAvailable ? OLD_VERSION : LATEST, bridge_id: 'brg_fixture_1', bundledVersion: LATEST, error: '',
};
const otherProfile: DesktopBridgeStatus = { ...ownProfile, profile: 'default', bridge_id: 'brg_someone_else', state: 'connected' };
const notInstalled: DesktopBridgeStatus = { supported: true, busy: false, operation: '', installed: false, state: 'not_installed', hub: HUB_URL, error: '' };

const projects: any[] = [
  { project_id: 'prj_existing', name: 'notes', description: 'My own notes description.', bridge_paths: [{ bridge_id: 'brg_fixture_1', path: '/home/dev/notes' }] },
];
const model = (model_id: string, label: string) => ({ model_id, label, state: 'active' });
const PROVIDERS: any[] = [
  { provider: 'claude', display_name: 'Claude Code', catalog_state: 'active', state: 'present', binary_path: '/home/dev/.local/bin/claude', version_text: '2.1.0', checked_at: '2026-10-31T12:00:00Z', enabled: true, models: [model('claude-sonnet-5-5', 'Sonnet 5.5'), model('claude-opus-5-5', 'Opus 5.5')], extension: null },
  { provider: 'codex', display_name: 'Codex', catalog_state: 'active', state: 'present', binary_path: '/usr/local/bin/codex', version_text: '0.60.0', checked_at: '2026-10-31T12:00:00Z', enabled: false, models: [model('gpt-5-codex', 'GPT-5 Codex')], extension: null },
  { provider: 'copilot', display_name: 'GitHub Copilot', catalog_state: 'active', state: 'absent', binary_path: '', version_text: '', checked_at: '2026-10-31T12:00:00Z', enabled: false, models: [], extension: null },
];
const FS: Record<string, { entries: Array<{ name: string; is_dir: boolean }> }> = {
  '~/.claude/projects': { entries: [
    { name: '-home-dev-heimdall-agent-manager', is_dir: true },
    { name: '-home-dev-notes', is_dir: true },
    { name: '-home-dev-scratch', is_dir: true },
  ] },
};
const SESSIONS: Record<string, number> = { '-home-dev-heimdall-agent-manager': 12, '-home-dev-notes': 3, '-home-dev-scratch': 0 };
const DIRS = new Set(['/home', '/home/dev', '/home/dev/heimdall-agent-manager', '/home/dev/notes', '/home/dev/scratch', '/home/dev/archive/heimdall-agent-manager']);

// The pairing request this machine's (scripted) setup prints. Built with the real
// pairing derivation so the wizard's own key-MAC check passes on it.
interface Pairing { code: string; info: any; lookup: string }
let pairingPromise: Promise<Pairing> | null = null;
async function hexKey(name: 'ECDSA' | 'ECDH'): Promise<string> {
  const kp = await crypto.subtle.generateKey({ name, namedCurve: 'P-256' }, true, name === 'ECDSA' ? ['sign', 'verify'] : ['deriveBits']) as CryptoKeyPair;
  return toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey)));
}
function pairing(): Promise<Pairing> {
  pairingPromise ||= (async () => {
    const code = generatePairCode();
    const salt = generatePairSalt();
    const origin = pairingHubOrigin();
    const keys = await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: origin, pairSalt: salt });
    const identity = await hexKey('ECDSA');
    const ecdh = await hexKey('ECDH');
    const challenge = 'fixture-challenge_1';
    const info = {
      kind: 'bridge', is_bridge_enrollment: true, pair_salt: salt, pair_hub_origin: origin,
      bridge_identity_public_key: identity, bridge_public_key: ecdh, code_challenge: challenge,
      hub_observed: { bridge_public_key_on_record: ecdh },
      pair_key_mac: await pairKeyMac(keys, 'bridge', pairBridgePayload(identity, ecdh, challenge)),
      device_label: THIS_MACHINE, machine_hostname: THIS_MACHINE, os: 'linux', os_user: 'dev', app_version: LATEST,
      reusable_bridges: accountBridges.map((b) => ({ bridge_id: b.bridge_id, label: b.label, machine_hostname: b.machine_hostname, status: b.status })),
      previous_bridge_id: scenario.reuseHint ? accountBridges[accountBridges.length - 1]?.bridge_id || '' : '',
    };
    return { code, info, lookup: keys.lookup };
  })();
  return pairingPromise;
}

const ok = (data: unknown) => ({ status: 200, body: { data } });
const notFound = { status: 404, body: { error: { code: 'not_found', message: 'not found' } } };

async function route(req: DemoRequest) {
  const { method, path } = req;
  if (method === 'GET' && path === '/account/billing') {
    return ok({ user_id: USER, entitlements: { max_bridges: scenario.maxBridges, terminal_streaming_enabled: true, terminal_input_enabled: true, max_concurrent_streams: -1, shells_enabled: true } });
  }
  if (method === 'GET' && path === '/bridges') {
    return ok({ bridges: req.query.get('include_pending') ? accountBridges : accountBridges.filter((b) => !b.revoked_at) });
  }
  const revoke = path.match(/^\/bridges\/([^/]+)\/revoke$/);
  if (method === 'POST' && revoke) {
    const row = accountBridges.find((b) => b.bridge_id === decodeURIComponent(revoke[1]));
    if (!row) return notFound;
    row.revoked_at = new Date().toISOString();
    row.status = 'revoked';
    return ok({ bridge: row });
  }
  if (method === 'GET' && /^\/bridges\/[^/]+\/session-projects$/.test(path)) {
    return ok({ ok: true, truncated: false, projects: [
      { source: 'Claude Code', path: '-home-dev-heimdall-agent-manager', canonical_path: '/home/dev/heimdall-agent-manager', sessions: 12, last_session_at: '2026-10-31T10:00:00Z', description: 'Heimdall is a Hub-and-Bridge multi-agent orchestration system.' },
      { source: 'Codex', path: '/home/dev/heimdall-agent-manager', canonical_path: '/home/dev/heimdall-agent-manager', sessions: 4, last_session_at: '2026-10-31T12:00:00Z', description: 'Heimdall is a Hub-and-Bridge multi-agent orchestration system.' },
      { source: 'Codex', path: '/home/dev/archive/heimdall-agent-manager', canonical_path: '/home/dev/archive/heimdall-agent-manager', sessions: 2, last_session_at: '2026-10-30T12:00:00Z', description: 'An archived orchestration prototype.' },
      { source: 'Claude Code', path: '-home-dev-notes', canonical_path: '/home/dev/notes', sessions: 3, last_session_at: '2026-10-29T12:00:00Z', description: 'A notebook for project research.' },
    ] });
  }
  const fs = path.match(/^\/bridges\/[^/]+\/fs(\/stat)?$/);
  if (method === 'GET' && fs) {
    const p = req.query.get('path') || '';
    if (fs[1]) return ok({ ok: true, path: p, exists: DIRS.has(p), is_dir: DIRS.has(p) });
    if (FS[p]) return ok({ ok: true, path: '/home/dev/.claude/projects', entries: FS[p].entries });
    const dir = p.split('/').pop() || '';
    if (dir in SESSIONS) return ok({ ok: true, path: p, entries: Array.from({ length: SESSIONS[dir] }, (_, i) => ({ name: `session-${i}.jsonl`, is_dir: false })) });
    return ok({ ok: false, path: p, entries: [] });
  }
  const providerStatus = path.match(/^\/bridges\/([^/]+)\/provider-status$/);
  if (method === 'GET' && providerStatus) return ok({ bridge_id: decodeURIComponent(providerStatus[1]), providers: PROVIDERS });
  if (method === 'POST' && /^\/bridges\/[^/]+\/providers\/discover$/.test(path)) return ok({ providers: PROVIDERS });
  const toggle = path.match(/^\/bridges\/[^/]+\/providers\/([^/]+)$/);
  if (method === 'PUT' && toggle) {
    const row = PROVIDERS.find((p) => p.provider === decodeURIComponent(toggle[1]));
    if (!row) return notFound;
    row.enabled = Boolean(req.body?.enabled);
    return ok(row);
  }
  if (method === 'GET' && path === '/projects') return { status: 200, body: { data: projects.map(({ bridge_paths, ...project }) => project), page: { has_more: false, next_cursor: null } } };
  if (method === 'POST' && path === '/projects') {
    const project = { project_id: `prj_fixture_${projects.length + 1}`, name: req.body?.name || '', description: req.body?.description || '', default_path: req.body?.default_path || '', bridge_paths: [] as any[] };
    projects.push(project);
    return ok(project);
  }
  const detail = path.match(/^\/projects\/([^/]+)$/);
  if (method === 'GET' && detail) {
    const project = projects.find((p) => p.project_id === decodeURIComponent(detail[1]));
    return project ? ok({ project, bridge_paths: project.bridge_paths }) : notFound;
  }
  const bp = path.match(/^\/projects\/([^/]+)\/bridge-paths\/([^/]+)$/);
  if (method === 'PUT' && bp) {
    const project = projects.find((p) => p.project_id === decodeURIComponent(bp[1]));
    if (!project) return notFound;
    project.bridge_paths.push({ bridge_id: decodeURIComponent(bp[2]), path: req.body?.path || '' });
    return ok(project);
  }
  if (method === 'POST' && path === '/device/pair-salts') {
    const p = await pairing();
    return ok({ pairing_hub_origins: [], candidates: [{ kind: 'bridge', pair_salt: p.info.pair_salt, pair_hub_origin: p.info.pair_hub_origin }] });
  }
  if (method === 'POST' && path === '/device/verify') {
    const p = await pairing();
    return (req.body?.pair_lookups || []).includes(p.lookup) ? ok(p.info) : notFound;
  }
  if (method === 'POST' && path === '/device/approve') {
    // Only a denial reaches here (an approval stops at the vault signature first).
    return ok({});
  }
  return null;
}
setDemoRouter(route);

// ---------------------------------------------------------------------------
// Scripted desktop bridge manager

function fakeManager(): DesktopBridgeManagerApi {
  const callbacks = new Set<(e: DesktopBridgeEvent) => void>();
  const emit = (e: DesktopBridgeEvent) => callbacks.forEach((cb) => cb(e));
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  let installed = scenario.installed === 'own';
  let version = ownProfile.version;
  let cancelled = false;
  const status = (): DesktopBridgeStatus => (installed ? { ...ownProfile, version } : notInstalled);
  const profiles = () => [
    ...(installed ? [status()] : []),
    ...(scenario.installed === 'other' ? [otherProfile] : []),
  ];
  const progress = async (step: string, message: string) => {
    if (cancelled) throw new Error('cancelled');
    emit({ type: 'progress', step, state: 'start', message });
    await sleep(500);
    emit({ type: 'output', message: `${step}: ${message}` });
    emit({ type: 'progress', step, state: 'ok' });
  };
  return {
    getConfig: async () => ({ ok: true, supported: scenario.supported !== false, platform: 'linux', hubUrl: HUB_URL, defaultHubUrl: HUB_URL, bundledVersion: LATEST }),
    setHubUrl: async (hubUrl) => ({ ok: true, hubUrl }),
    getStatus: async () => status(),
    list: async () => ({ ok: true, profiles: profiles() }),
    cancel: async () => { cancelled = true; emit({ type: 'error', message: 'Setup was cancelled.', cancelled: true }); return { ok: true }; },
    openLog: async () => ({ ok: false, error: 'Log files are not available in the fixture preview.' }),
    onEvent: (cb) => { callbacks.add(cb); return () => { callbacks.delete(cb); }; },
    run: async (kind) => {
      cancelled = false;
      void (async () => {
        try {
          if (kind === 'uninstall') {
            await progress('service', 'Stopping and removing the service');
            installed = false;
            emit({ type: 'complete', status: status() });
            return;
          }
          if (kind === 'update') {
            await progress('download', `Downloading v${LATEST}`);
            await progress('binaries', 'Replacing binaries');
            await progress('verify', 'Reconnected');
            version = LATEST;
            // The hub row catches up once the updated bridge reconnects.
            if (accountBridges[0]) Object.assign(accountBridges[0], { version: LATEST, update_available: false });
            emit({ type: 'complete', status: status() });
            return;
          }
          await progress('download', `Downloading v${LATEST}`);
          await progress('binaries', 'Installing ham-bridge');
          if (scenario.installFails) {
            emit({ type: 'progress', step: 'service', state: 'start', message: 'Registering the user service' });
            await sleep(500);
            emit({ type: 'output', message: 'systemctl --user enable ham-bridge.service: Failed to connect to bus (fixture)' });
            emit({ type: 'error', message: 'Could not register the bridge service (fixture failure).', step: 'service', rolledBack: true });
            return;
          }
          await progress('service', 'Registering the user service');
          emit({ type: 'progress', step: 'enroll', state: 'start', message: 'Waiting for approval in this app' });
          const p = await pairing();
          emit({ type: 'pairing', url: `${HUB_URL}/#/device/add`, code: p.code });
          // A real bridge now waits for the approval + vault key; the fixture cannot
          // approve (no device vault), so it waits here until cancelled.
        } catch { /* cancelled */ }
      })();
      return { ok: true };
    },
  };
}

if (scenario.native === 'current') (window as any).odinApi = { bridgeManager: fakeManager() };
if (scenario.native === 'legacy') (window as any).odinApi = { bridgeManager: { getStatus: async () => notInstalled, installBundled: async () => ({ ok: false }), startEnrollment: async () => ({ ok: false }) } };

// ---------------------------------------------------------------------------

const store = configureStore({
  reducer: combineReducers({ vault: vaultReducer, deviceVault: deviceVaultReducer, theme: themeReducer, [heimdallApi.reducerPath]: heimdallApi.reducer }),
  middleware: (getDefault) => getDefault({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
});

function RequestLog() {
  const [, setTick] = useState(0);
  useEffect(() => subscribeDemoCalls(() => setTick((n) => n + 1)), []);
  const calls = demoCalls();
  // Pair lookups are POSTs that read; everything else non-GET is a write the fixture absorbed.
  const mutations = calls.filter((c) => !c.blocked && c.method !== 'GET' && c.path !== '/device/pair-salts' && c.path !== '/device/verify');
  const blocked = calls.filter((c) => c.blocked);
  return (
    <details data-debug-id="setup-demo-requests" className="rounded-lg border border-subtle bg-surface p-3 text-xs">
      <summary className="cursor-pointer text-muted">
        Requests: {calls.length} answered by fixture · {mutations.length} fixture-only writes · {blocked.length} refused
      </summary>
      <ul className="mt-2 max-h-48 overflow-y-auto font-mono">
        {calls.slice().reverse().map((c, i) => (
          <li key={i} className={c.blocked ? 'text-danger' : c.method === 'GET' ? 'text-faint' : 'text-primary'}>
            {c.blocked ? 'REFUSED ' : ''}{c.method} {c.path} → {c.status}
          </li>
        ))}
      </ul>
    </details>
  );
}

function Demo() {
  const hash = useSyncExternalStore((cb) => { window.addEventListener('hashchange', cb); return () => window.removeEventListener('hashchange', cb); }, () => location.hash);
  const finished = hash && hash !== '#/' && hash !== '#' ? hash : '';
  return (
    <div className="flex h-screen flex-col bg-canvas text-primary">
      <header data-debug-id="setup-demo-toolbar" className="flex shrink-0 flex-col gap-2 border-b border-subtle bg-surface px-4 py-2">
        <div className="flex flex-wrap items-center gap-2">
          <span className="rounded bg-warning-soft px-2 py-0.5 text-xs font-semibold text-warning">FIXTURE PREVIEW · no real hub, no ham-bridge</span>
          <label className="flex items-center gap-2 text-xs text-muted">
            Scenario
            <select
              data-debug-id="setup-demo-scenario"
              className="rounded border border-subtle bg-canvas px-2 py-1 text-xs text-primary"
              value={scenario.id}
              onChange={(e) => { location.search = `?scenario=${encodeURIComponent(e.target.value)}`; }}
            >
              {SCENARIOS.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          </label>
          <button type="button" data-debug-id="setup-demo-restart" className="rounded border border-subtle px-2 py-1 text-xs" onClick={() => { location.hash = ''; location.reload(); }}>Restart</button>
        </div>
        <p data-debug-id="setup-demo-note" className="text-xs text-muted">{scenario.note}</p>
        {finished ? <p data-debug-id="setup-demo-finished" className="text-xs text-success">Wizard navigated to {finished} (setup finished or skipped).</p> : null}
        <RequestLog />
      </header>
      <div className="min-h-0 flex-1"><SetupWizardPage userId={USER} /></div>
    </div>
  );
}

async function main() {
  applyThemeToDocument('default-dark');
  history.replaceState(null, '', location.pathname + location.search);
  // A throwaway in-memory key so project names can be sealed like the real app does.
  const key = { userId: USER, vaultId: '7e57000000000002', currentEpoch: 1,
    keys: new Map([[1, await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'])]]) };
  setActiveVaultKey(key);
  store.dispatch(keyringInstalled({ currentEpoch: 1 }));
  store.dispatch(deviceVaultIdentityKnown({ userId: USER, deviceId: '', fingerprint: '' }));
  await store.dispatch(accountBillingApi.endpoints.getAccountBilling.initiate(USER) as any);
  createRoot(document.getElementById('root')!).render(<Provider store={store}><Demo /></Provider>);
}
void main();
