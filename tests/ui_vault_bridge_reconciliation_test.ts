// REQ-AUX-10: runtime coverage for exact multi-bridge vault reconciliation.

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

async function bridgePublicKeyBase64(): Promise<string> {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits', 'deriveKey'],
  );
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
  return Buffer.from(raw).toString('base64');
}

test('REQ-AUX-10: reconciliation calls public-key and unseal for every and only online locked bridge', async () => {
  const realFetch = globalThis.fetch;
  const publicKey = await bridgePublicKeyBase64();
  const calls: Array<{ url: string; method: string }> = [];
  try {
    globalThis.fetch = (async (input: any, init: RequestInit = {}) => {
      const url = String(input?.url ?? input);
      const method = String(init.method || 'GET').toUpperCase();
      calls.push({ url, method });
      if (url.endsWith('/public-key')) return response({ public_key: publicKey });
      if (url.endsWith('/unseal')) return response({ type: 'bridge_unseal_result', command_id: 'cmd_test', ok: true });
      throw new Error(`unexpected request: ${method} ${url}`);
    }) as typeof fetch;

    const { reconcileLockedBridges } = await import('../src/ui/api/endpoints/bridges.ts');
    const result = await reconcileLockedBridges([
      { bridge_id: 'brg_a', status: 'online', vault_status: 'locked' },
      { bridge_id: 'brg_b', status: 'online', vault_status: 'locked' },
      { bridge_id: 'brg_open', status: 'online', vault_status: 'unlocked' },
      { bridge_id: 'brg_unknown', status: 'online', vault_status: '' },
      { bridge_id: 'brg_offline', status: 'offline', vault_status: 'locked' },
      { bridge_id: 'brg_revoked', status: 'revoked', vault_status: 'locked' },
    ], '11'.repeat(32));

    assert.deepEqual(result.targetBridgeIds, ['brg_a', 'brg_b']);
    assert.deepEqual(result.failedBridgeIds, []);
    assert.deepEqual([...result.succeededBridgeIds].sort(), ['brg_a', 'brg_b']);
    assert.equal(result.needsReauthentication, false);
    assert.deepEqual(
      calls.filter((call) => call.url.endsWith('/unseal')).map((call) => call.url.match(/bridges\/([^/]+)\/unseal/)?.[1]).sort(),
      ['brg_a', 'brg_b'],
    );
    assert.equal(calls.filter((call) => call.url.endsWith('/public-key')).length, 2);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('REQ-AUX-10: missing transfer material requests reauthentication without network calls', async () => {
  const realFetch = globalThis.fetch;
  let calls = 0;
  try {
    globalThis.fetch = (async () => {
      calls++;
      throw new Error('network must not be touched');
    }) as typeof fetch;
    const { setActiveBridgeVaultKeyMaterial } = await import('../src/ui/store/vaultSlice.ts');
    const { reconcileLockedBridges } = await import('../src/ui/api/endpoints/bridges.ts');
    setActiveBridgeVaultKeyMaterial(null);
    const result = await reconcileLockedBridges([
      { bridge_id: 'brg_locked', status: 'online', vault_status: 'locked' },
    ]);
    assert.equal(result.needsReauthentication, true);
    assert.deepEqual(result.attemptedBridgeIds, []);
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('REQ-AUX-10: partial failures are reported per bridge after all targets are attempted', async () => {
  const realFetch = globalThis.fetch;
  const publicKey = await bridgePublicKeyBase64();
  try {
    globalThis.fetch = (async (input: any) => {
      const url = String(input?.url ?? input);
      if (url.endsWith('/public-key')) return response({ public_key: publicKey });
      if (url.includes('/brg_bad/unseal')) return response({ error: { message: 'bridge refused unseal' } }, 500);
      if (url.endsWith('/unseal')) return response({ type: 'bridge_unseal_result', command_id: 'cmd_test', ok: true });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;
    const { reconcileLockedBridges } = await import('../src/ui/api/endpoints/bridges.ts');
    const result = await reconcileLockedBridges([
      { bridge_id: 'brg_good', status: 'online', vault_status: 'locked' },
      { bridge_id: 'brg_bad', status: 'online', vault_status: 'locked' },
    ], '22'.repeat(32));
    assert.deepEqual(result.targetBridgeIds, ['brg_good', 'brg_bad']);
    assert.deepEqual(result.succeededBridgeIds, ['brg_good']);
    assert.deepEqual(result.failedBridgeIds, ['brg_bad']);
    assert.deepEqual([...result.attemptedBridgeIds].sort(), ['brg_bad', 'brg_good']);
  } finally {
    globalThis.fetch = realFetch;
  }
});
