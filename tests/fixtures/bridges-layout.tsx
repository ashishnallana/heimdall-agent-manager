// Isolated UI fixture. Every API and desktop operation below is in memory.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { SettingsModal } from '../../src/ui/components/settings/SettingsModal';
import SetupWizardPage from '../../src/ui/components/setup/SetupWizardPage';
import { heimdallApi } from '../../src/ui/api/heimdallApi';
import '../../src/ui/styles.css';

const scenario = new URLSearchParams(location.search).get('scenario') || 'browser';
const hub = location.origin;
const rows = [
  { bridge_id: 'brg_local', label: 'Dawnstar', machine_hostname: 'dawnstar', machine_os: 'Linux', machine_arch: 'x86_64', target: 'linux-amd64',
    status: 'online', runtime_connected: true, version: '0.3.30', latest_version: '0.3.31', update_available: true, update_artifact_available: true,
    active_instance_count: 2, vault_status: 'unlocked', telemetry_enabled: 'inherit' },
  { bridge_id: 'brg_remote', label: 'Riverwood', machine_hostname: 'riverwood', machine_os: 'macOS', machine_arch: 'arm64', target: 'darwin-arm64',
    status: 'online', runtime_connected: true, version: '0.3.31', latest_version: '0.3.32', latest_source: 'manifest', update_available: true, active_instance_count: 1, vault_status: 'locked', telemetry_enabled: 'enabled' },
  { bridge_id: 'brg_offline', label: 'Laptop', machine_hostname: 'tanmay-laptop', machine_os: 'macOS', machine_arch: 'arm64', target: 'darwin-arm64',
    status: 'offline', version: '0.3.29', latest_version: '0.3.31', vault_status: 'locked', telemetry_enabled: 'disabled' },
];
const requests: any[] = [];
const runs: any[] = [];
const listeners = new Set<(event: any) => void>();
let telemetry = true;
let autoUpdate = true;
let installed = scenario === 'installed' || scenario === 'unknown';
const status = () => ({ supported: true, busy: false, operation: '', installed, enrolled: installed,
  state: scenario === 'unknown' ? 'unknown' : 'connected', hub, profile: 'personal', bridge_id: 'brg_local', service: 'ninjy-bridge-personal', version: '0.3.30' });
const manager = {
  getConfig: async () => ({ ok: true, supported: true, platform: 'linux', hubUrl: hub, defaultHubUrl: hub, bundledVersion: '0.3.30' }),
  setHubUrl: async () => ({ ok: true }),
  list: async () => scenario === 'error' ? { ok: false, error: 'Unable to inspect local service' } : { ok: true, profiles: installed ? [status()] : [] },
  getStatus: async () => status(),
  run: async (kind: string, target: any, options: any) => { runs.push({ kind, target, options }); return { ok: true }; },
  cancel: async () => { listeners.forEach((fn) => fn({ type: 'error', cancelled: true, rolledBack: true, step: 'install', message: 'Cancelled' })); return { ok: true }; },
  openLog: async () => ({ ok: true }),
  onEvent: (fn: (event: any) => void) => { listeners.add(fn); return () => listeners.delete(fn); },
};
if (scenario !== 'browser') (window as any).odinApi = { bridgeManager: manager };
(window as any).bridgesFixture = { requests, runs, emit: (event: any) => {
  if (event.type === 'complete' && event.status) installed = true;
  listeners.forEach((fn) => fn(event));
} };
window.fetch = async (input, init = {}) => {
  const url = String(input); const method = init.method || 'GET';
  const body = init.body ? JSON.parse(String(init.body)) : null;
  requests.push({ url, method, body });
  const json = (data: any) => Response.json({ data });
  if (url.endsWith('/bridges')) return json({ bridges: rows });
  if (url.includes('/auto-update')) { if (body) autoUpdate = body.enabled; return json({ enabled: autoUpdate }); }
  if (url.includes('/telemetry')) { if (body) telemetry = body.enabled; return json({ enabled: telemetry }); }
  if (url.endsWith('/provider-status')) return json({ providers: [{ provider: 'claude', state: 'present', models: [] }], extension_commands: [] });
  if (url.includes('/events')) return json({ events: [] });
  if (url.includes('pending')) return json([]);
  if (url.endsWith('/experiments')) return json({ flags: [] });
  if (url.endsWith('/me')) return json({ user_id: 'usr_fixture', display_name: 'Tanmay' });
  if (url.endsWith('/update')) return json({ ok: true });
  if (method === 'PATCH' && url.includes('/bridges/')) {
    const row = rows.find((r) => url.endsWith('/' + r.bridge_id)); if (row) Object.assign(row, body);
    return json({ ok: true });
  }
  throw new Error('Unexpected fixture request: ' + method + ' ' + url);
};
const store = configureStore({ reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
  middleware: (g) => g().concat(heimdallApi.middleware) });
const root = createRoot(document.getElementById('root')!);
let host = new URLSearchParams(location.search).get('host') || 'settings';
function render() {
  root.render(<Provider store={store}>{host === 'wizard' ? <SetupWizardPage userId="usr_fixture" />
    : <SettingsModal open onOpenChange={() => {}} initialTab="bridges" user={{ display_name: 'Tanmay' }} />}</Provider>);
}
(window as any).bridgesFixture.host = (next: string) => { host = next; render(); };
render();
