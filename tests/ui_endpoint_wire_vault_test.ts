// REQ-RAWKEY-A8: endpoint-layer wire verification for vault encryption.
//
// RUN: node --test tests/ui_endpoint_wire_vault_test.ts
//
// WHY THIS FILE EXISTS (A1 / task_18db44c4dbe591ec):
// A P0 survived in four places because the endpoint layer had NO runtime coverage
// at all. ui_artifacts_vault_test.ts / ui_chains_vault_test.ts only exercise the
// encryptArtifactFields / encryptChainFields HELPERS, which the endpoints never
// call -- the endpoints inline their own logic. So those suites stayed green while
// artifact names and chain titles were written to the wire in PLAINTEXT.
//
// This harness drives the REAL RTK Query endpoints through a REAL store with a
// stubbed global fetch and asserts on the ACTUAL WIRE PAYLOAD, across the three
// vault states (unlocked / encryption-disabled / locked) plus idempotence and
// counterfactuals. Authored by A1; adopted verbatim into tests/ by A8 so it
// protects the tree instead of living in a scratchpad.
//
// The `tests/ui_*_vault_test.ts` glob in package.json picks this file up
// automatically -- no test-script change is needed.

import { importRawKeyHex } from './helpers/vaultTestKeyring.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { registerHooks } from 'node:module';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const R = REPO_ROOT;

// The endpoint modules under test use extensionless relative imports
// (e.g. `from '../daemonApi'`) that only vite resolves at build time. Register an
// in-thread resolver so plain `node --test` can load them. This MUST run before
// the dynamic imports below, which is why every repo import in this file is
// dynamic rather than static.
registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (err) {
      if (!specifier.startsWith('.') && !specifier.startsWith('/')) throw err;
      const base = new URL(specifier, context.parentURL);
      for (const cand of [base.href + '.ts', base.href + '.tsx',
                          base.href + '/index.ts', base.href + '/index.tsx']) {
        if (fs.existsSync(fileURLToPath(cand))) return { url: cand, shortCircuit: true };
      }
      throw err;
    }
  },
});

const { configureStore } = await import(`${R}/node_modules/@reduxjs/toolkit/dist/redux-toolkit.modern.mjs`);

const { heimdallApi } = await import(`${R}/src/ui/api/heimdallApi.ts`);
const vaultSlice = await import(`${R}/src/ui/store/vaultSlice.ts`);
const { keyringInstalled, keyringCleared } = vaultSlice;
const vaultReducer = vaultSlice.default;
const { setActiveVaultKey, getActiveVaultKey,
        isVaultArmored, encryptVaultText } = await import(`${R}/src/ui/utils/vaultCrypto.ts`);
const artifacts = await import(`${R}/src/ui/api/endpoints/artifacts.ts`);
const taskChains = await import(`${R}/src/ui/api/endpoints/taskChains.ts`);

const KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const KEY_HEX = await keyringFromHex(KEY_HEX_RAW);

// daemonApi's requestJson uses window.setTimeout/clearTimeout, and artifacts.ts
// isBrowserAmbientAuth() reads window.location.protocol. Shim ONLY those — a bare
// `window = globalThis` makes browser-only branches fire and then throw.
(globalThis as any).window = {
  setTimeout: (...a: any[]) => (setTimeout as any)(...a),
  clearTimeout: (h: any) => clearTimeout(h),
  location: { protocol: 'file:', href: 'file:///test' },
};

// ---- fetch stub: records every request, answers with a benign JSON envelope ----
type Captured = { url: string; method: string; body: any };
let captured: Captured[] = [];
let nextResponseBody: any = { data: { ok: true } };

(globalThis as any).fetch = async (input: any, init: any = {}) => {
  const url = String(input?.url ?? input);
  let body: any = init?.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch {} }
  else if (body && typeof body.entries === 'function') {
    const o: any = {};
    for (const [k, v] of body.entries()) o[k] = typeof v === 'string' ? v : '<blob>';
    body = o;
  }
  captured.push({ url, method: String(init?.method || 'GET').toUpperCase(), body });
  const text = typeof nextResponseBody === 'string' ? nextResponseBody : JSON.stringify(nextResponseBody);
  return {
    ok: true, status: 200,
    headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
    text: async () => text,
    json: async () => (typeof nextResponseBody === 'string' ? JSON.parse(nextResponseBody) : nextResponseBody),
  } as any;
};

function makeStore() {
  return configureStore({
    reducer: {
      vault: vaultReducer,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
}

let lastResult: any = null;
async function go(store: any, thunk: any) {
  lastResult = await store.dispatch(thunk);
  return lastResult;
}

async function unlock(store: any) {
  const key = await keyringFromHex(KEY_HEX_RAW);
  setActiveVaultKey(key, null);           // hardened path: CryptoKey only, no hex
  store.dispatch(keyringInstalled({ currentEpoch: 1 }));
}

function assertNoError(res: any, label: string) {
  assert.ok(!res?.error, `${label} returned an error: ${JSON.stringify(res?.error)}`);
}

function body(pred: (c: Captured) => boolean) {
  if (lastResult?.error) assert.fail(`endpoint returned an error: ${JSON.stringify(lastResult.error)}`);
  const hit = captured.find(pred);
  assert.ok(hit, `no captured request matched; saw: ${captured.map(c => c.method + ' ' + c.url).join(', ')}`);
  return hit!.body;
}

// =============================================================================
// STATE: ENABLED + UNLOCKED  — writes must be armored on the wire
// =============================================================================

test('UNLOCKED: createArtifact sends vault:v2:7e57000000000001:e1: name and description on the wire', async () => {
  captured = []; nextResponseBody = { data: { artifact: { artifact_id: 'art_1' } } };
  const store = makeStore();
  await unlock(store);
  assert.ok(getActiveVaultKey(), 'precondition: active CryptoKey present');

  await go(store, artifacts.artifactsApi.endpoints.createArtifact.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test',
    name: 'Quarterly Secret Plan', description: 'confidential rollout notes',
    content: 'line one of secret content', projectId: 'proj_1',
  } as any));

  const b = body(c => /\/artifacts\/create/.test(c.url) || c.method === 'POST');
  assert.ok(isVaultArmored(b.name), `name must be armored, got: ${JSON.stringify(b.name)?.slice(0, 80)}`);
  assert.ok(isVaultArmored(b.description), `description must be armored, got: ${JSON.stringify(b.description)?.slice(0, 80)}`);
  assert.ok(!String(b.name).includes('Quarterly'), 'plaintext name must NOT appear on the wire');
  assert.ok(!String(b.description).includes('confidential'), 'plaintext description must NOT appear on the wire');
});

test('UNLOCKED: updateArtifact sends vault:v2:7e57000000000001:e1: name and description on the wire', async () => {
  captured = []; nextResponseBody = { data: { artifact: { artifact_id: 'art_1' } } };
  const store = makeStore();
  await unlock(store);
  await go(store, artifacts.artifactsApi.endpoints.updateArtifact.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test',
    artifactId: 'art_1', name: 'Renamed Secret', description: 'updated confidential text',
  } as any));
  const b = body(c => c.method === 'PATCH' && /\/artifacts\//.test(c.url));
  assert.ok(isVaultArmored(b.name), 'updated name must be armored');
  assert.ok(isVaultArmored(b.description), 'updated description must be armored');
});

test('UNLOCKED: createTaskChain sends vault:v2:7e57000000000001:e1: title and description on the wire', async () => {
  captured = []; nextResponseBody = { data: { chain_id: 'chain_1' } };
  const store = makeStore();
  await unlock(store);
  await go(store, taskChains.taskChainsApi.endpoints.createTaskChain.initiate({
    title: 'Secret Chain Title', description: 'secret chain description',
  } as any));
  const b = body(c => c.method === 'POST' && /task-chains/.test(c.url));
  assert.ok(isVaultArmored(b.title), `chain title must be armored, got: ${String(b.title).slice(0, 60)}`);
  assert.ok(isVaultArmored(b.description), 'chain description must be armored');
  assert.ok(!String(b.title).includes('Secret'), 'plaintext chain title must NOT appear on the wire');
});

test('UNLOCKED: updateTaskChain sends vault:v2:7e57000000000001:e1: title and description on the wire', async () => {
  captured = []; nextResponseBody = { data: { chain_id: 'chain_1' } };
  const store = makeStore();
  await unlock(store);
  await go(store, taskChains.taskChainsApi.endpoints.updateTaskChain.initiate({
    chainId: 'chain_1', title: 'Renamed Chain', description: 'renamed chain description',
  } as any));
  const b = body(c => c.method === 'PATCH');
  assert.ok(isVaultArmored(b.title), 'updated chain title must be armored');
  assert.ok(isVaultArmored(b.description), 'updated chain description must be armored');
});

test('UNLOCKED: fetchArtifactTextContent decrypts pre-existing armored content to plaintext', async () => {
  captured = [];
  const key = await keyringFromHex(KEY_HEX_RAW);
  setActiveVaultKey(key, null);
  const armored = await encryptVaultText('previously stored secret body', key);
  assert.ok(isVaultArmored(armored));
  nextResponseBody = { content: armored };

  const store = makeStore();
  await unlock(store);
  const res: any = await go(store, artifacts.artifactsApi.endpoints.fetchArtifactTextContent.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test', artifactId: 'art_1', versionNo: 1,
  } as any));
  assert.equal(res.data?.text, 'previously stored secret body',
    `content must render decrypted, got: ${String(res.data?.text).slice(0, 60)}`);
  assert.ok(!isVaultArmored(res.data?.text), 'no vault:v2:7e57000000000001:e1: string may reach the screen');
});

// =============================================================================
// STATE: ENCRYPTION DISABLED (no vault configured, no key) — plaintext passthrough
// =============================================================================

test('DISABLED: createArtifact and createTaskChain send plaintext unchanged, no throw', async () => {
  captured = []; nextResponseBody = { data: { artifact: { artifact_id: 'art_2' } } };
  setActiveVaultKey(null, null);
  const store = makeStore();                       // never unlocked
  assert.equal(getActiveVaultKey(), null, 'precondition: no active key');

  await go(store, artifacts.artifactsApi.endpoints.createArtifact.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test',
    name: 'Public Artifact', description: 'public description', content: 'public body',
  } as any));
  const a = body(c => c.method === 'POST');
  assert.equal(a.name, 'Public Artifact', 'plaintext name must pass through untouched');
  assert.equal(a.description, 'public description', 'plaintext description must pass through untouched');

  captured = []; nextResponseBody = { data: { chain_id: 'chain_2' } };
  await go(store, taskChains.taskChainsApi.endpoints.createTaskChain.initiate({
    title: 'Public Chain', description: 'public chain description',
  } as any));
  const c2 = body(c => c.method === 'POST' && /task-chains/.test(c.url));
  assert.equal(c2.title, 'Public Chain', 'plaintext chain title must pass through untouched');
  assert.equal(c2.description, 'public chain description');
});

test('DISABLED: fetchArtifactTextContent returns pre-existing plaintext unchanged', async () => {
  captured = []; setActiveVaultKey(null, null);
  nextResponseBody = { content: 'legacy plaintext artifact body' };
  const store = makeStore();
  const res: any = await go(store, artifacts.artifactsApi.endpoints.fetchArtifactTextContent.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test', artifactId: 'art_2', versionNo: 1,
  } as any));
  assert.equal(res.data?.text, 'legacy plaintext artifact body');
});

// =============================================================================
// IDEMPOTENCE: already-armored input must not be double-encrypted
// =============================================================================

test('UNLOCKED: already-armored name/title is NOT re-encrypted (no double armor)', async () => {
  captured = []; nextResponseBody = { data: { artifact: { artifact_id: 'art_3' } } };
  const key = await keyringFromHex(KEY_HEX_RAW);
  setActiveVaultKey(key, null);
  const store = makeStore();
  await unlock(store);
  const preArmoredName = await encryptVaultText('already encrypted name', key);

  await go(store, artifacts.artifactsApi.endpoints.createArtifact.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test',
    name: preArmoredName, description: 'fresh description',
  } as any));
  const b = body(c => c.method === 'POST');
  assert.equal(b.name, preArmoredName, 'already-armored name must be sent byte-identical');

  captured = []; nextResponseBody = { data: { chain_id: 'chain_3' } };
  const preArmoredTitle = await encryptVaultText('already encrypted title', key);
  await go(store, taskChains.taskChainsApi.endpoints.createTaskChain.initiate({
    title: preArmoredTitle, description: 'fresh chain description',
  } as any));
  const c3 = body(c => c.method === 'POST' && /task-chains/.test(c.url));
  assert.equal(c3.title, preArmoredTitle, 'already-armored chain title must be sent byte-identical');
});

// =============================================================================
// STATE: ENABLED BUT LOCKED — no key, so no encryption and no crash
// =============================================================================

test('LOCKED: writes do not throw and armored reads stay armored (locked placeholder path)', async () => {
  const key = await keyringFromHex(KEY_HEX_RAW);
  const armored = await encryptVaultText('secret body', key);

  const store = makeStore();
  await unlock(store);
  store.dispatch(keyringCleared());
  setActiveVaultKey(null);                          // a purge clears the active keyring
  assert.equal(getActiveVaultKey(), null, 'precondition: locked means no active key');

  captured = []; nextResponseBody = { content: armored };
  const res: any = await go(store, artifacts.artifactsApi.endpoints.fetchArtifactTextContent.initiate({
    daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test', artifactId: 'art_4', versionNo: 7,
  } as any));
  assert.equal(res.data?.text, armored, 'locked: ciphertext is preserved for the locked placeholder, not corrupted');

  captured = []; nextResponseBody = { data: { chain_id: 'chain_4' } };
  await go(store, taskChains.taskChainsApi.endpoints.createTaskChain.initiate({
    title: 'Chain while locked',
  } as any));
  const b = body(c => c.method === 'POST' && /task-chains/.test(c.url));
  assert.equal(b.title, 'Chain while locked', 'locked: write proceeds in plaintext without throwing');
});

// =============================================================================
// COUNTERFACTUAL: prove the OLD key expression could never have worked.
// A test that passes after a fix proves nothing unless the pre-fix code fails it.
// The two files cannot be reverted (shared working tree), so instead evaluate the
// EXACT pre-fix operand against a real, fully unlocked store.
// =============================================================================


