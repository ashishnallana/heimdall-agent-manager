// Browser-only fixture backend. The real settings components and sealed API client
// run unchanged; no requests leave this page and no live provider is mutated.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { SettingsModal } from '../../src/ui/components/settings/SettingsModal';
import { heimdallApi } from '../../src/ui/api/heimdallApi';
import vaultReducer, { keyringInstalled } from '../../src/ui/store/vaultSlice';
import { importKeyring, serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring';
import { decryptVaultText, encryptVaultText, setActiveVaultKey } from '../../src/ui/utils/vaultCrypto';
import '../../src/ui/styles.css';

const bridge = { bridge_id: 'bridge_test', label: 'Riverwood', machine_hostname: 'riverwood', status: 'online', vault_status: 'unlocked' };
const bridges = [bridge,
  { ...bridge, bridge_id: 'bridge_offline', label: 'Laptop', status: 'offline', vault_status: 'sealed' },
  { ...bridge, bridge_id: 'bridge_locked', label: 'Locked', vault_status: 'locked' },
];
const profiles: any[] = ['claude', 'codex', 'antigravity', 'copilot', 'pi'].map((provider) => ({
  profile_id: provider, provider, label_enc: '', accent: '#9c9c9c', enabled: true, environment: [], config: {},
}));
profiles.push({ ...profiles[0], profile_id: 'claude_work', environment: [
  { name: 'WORK_TOKEN', value: '', sensitive: true, value_redacted: true },
], config: { config_dir: '/bridge/work' } });
const keyring = await importKeyring(serializeKeyringBytes({ userId: 'usr_test', vaultId: '7e57000000000001',
  currentEpoch: 1, entries: [{ epoch: 1, key: new Uint8Array(32).fill(17) }] }));
setActiveVaultKey(keyring);
const store = configureStore({ reducer: { vault: vaultReducer, [heimdallApi.reducerPath]: heimdallApi.reducer },
  middleware: (g) => g({ serializableCheck: false }).concat(heimdallApi.middleware) });
store.dispatch(keyringInstalled({ currentEpoch: 1 }));

const requests: any[] = [];
(window as any).providerLayoutRequests = requests;
let rejectDelete = true;
window.fetch = async (input, init = {}) => {
  const url = String(input);
  const method = init.method || 'GET';
  requests.push({ url, method });
  const json = (data: any, status = 200) => new Response(JSON.stringify({ data }), { status, headers: { 'content-type': 'application/json' } });
  if (url.endsWith('/bridges')) return json({ bridges });
  if (url.endsWith('/public-key')) return json({ unseal_boot_id: 'fixture_boot' });
  if (url.endsWith('/provider-profiles')) return json({ profiles: profiles.map(({ environment, config, ...p }) => p) });
  if (url.includes('/provider-profiles/')) {
    const wire = JSON.parse(await decryptVaultText(JSON.parse(String(init.body)).sealed));
    requests[requests.length - 1].op = wire.op;
    const p = profiles.find((p) => p.profile_id === wire.profile_id);
    if (wire.op === 'get') return json({ ok: true, sealed: await encryptVaultText(JSON.stringify({ nonce: wire.nonce, profiles: p ? [p] : [] })) });
    if (wire.op === 'upsert') {
      const saved = structuredClone({ ...wire.body, profile_id: wire.profile_id });
      saved.environment = saved.environment.map((e: any) => ({ ...e, value: '', value_redacted: e.sensitive && Boolean(e.value || e.keep) }));
      if (saved.config.api_key) { saved.config.api_key = ''; saved.config.api_key_redacted = true; }
      if (p) Object.assign(p, saved); else profiles.push(saved);
    }
    if (wire.op === 'remove') {
      if (rejectDelete) {
        rejectDelete = false;
        return new Response(JSON.stringify({ error: { code: 'profile_in_use', message: 'Profile is in use', details: { agents: ['agent_test'] } } }), { status: 409 });
      }
      profiles.splice(profiles.indexOf(p), 1);
    }
    if (wire.op === 'reset') Object.assign(p, { config: {}, environment: [], label_enc: '' });
    return json({ ok: true });
  }
  if (url.endsWith('/provider-status') || url.endsWith('/providers/discover')) return json({ providers: profiles.map((p) => ({ ...p,
    display_name: p.provider === 'claude' ? 'Claude Code' : p.provider === 'codex' ? 'Codex' : p.provider,
    state: ['claude', 'codex'].includes(p.provider) ? 'present' : 'absent', catalog_state: 'active', version_text: '1.0',
    models: [{ model_id: 'example-model', label: 'Example model', state: 'active' }], extension: { state: 'absent' },
  })) });
  if (url.endsWith('/experiments')) return json({ flags: [] });
  if (url.endsWith('/me')) return json({ user_id: 'usr_test', display_name: 'Layout test' });
  if (url.includes('/providers/')) return json({ ok: true });
  throw new Error('Unexpected fixture request: ' + method + ' ' + url);
};
createRoot(document.getElementById('root')!).render(<Provider store={store}>
  <SettingsModal open onOpenChange={() => {}} initialTab="providers" user={{ display_name: 'Layout test' }} />
</Provider>);
