// /device/add lookUpPairing (DeviceApprovalPage): the approver derives each candidate's
// lookup with the hub origin THAT CANDIDATE DECLARED (pair_hub_origin), never with the
// page's own origin. A device enrolled against https://hub.x pairs while the UI runs on
// https://app.x; a hub that alters the declared origin only gets a refusal.
// Hermetic: fake hub behind a stubbed fetch.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_device_approval_lookup_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, browserPairCtx, newBrowser } from './helpers/vaultDirectoryFixture.ts';

const { lookUpPairing } = await import('../src/ui/components/devices/DeviceApprovalPage.tsx');
const { setVaultDevicesFetch } = await import('../src/ui/api/endpoints/vaultDevices.ts');
const { buildPairedRegistration } = await import('../src/ui/utils/vaultDeviceFlows.ts');
const { derivePairKeys, generatePairCode, generatePairSalt } = await import('../src/ui/utils/vaultPairing.ts');

const DEVICE_HUB = 'https://hub.mundus.test:443'; // what the new device enrolled against
const PAGE = 'https://heimdall.mundus.test/'; // where the approving UI is served

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

async function setup(declared: (real: string) => string | undefined) {
  (globalThis as any).location = { href: PAGE, origin: new URL(PAGE).origin };
  const hub = new FakeHub();
  await hub.genesis(await newBrowser());
  const b = await newBrowser();
  const code = generatePairCode();
  const salt = generatePairSalt();
  const keys = await derivePairKeys(code, { ...browserPairCtx(salt), hubOrigin: DEVICE_HUB });
  const reg = await buildPairedRegistration(b, 'Phone', keys);
  await hub.register(reg.statement, reg.pairLookup, reg.pairKeyMac, salt, DEVICE_HUB);
  setVaultDevicesFetch((async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    if (url.endsWith('/device/pair-salts')) {
      const origin = declared(DEVICE_HUB);
      return json(200, { data: { candidates: [{ kind: 'browser', pair_salt: salt, ...(origin === undefined ? {} : { pair_hub_origin: origin }) }] } });
    }
    if (url.endsWith('/device/verify')) {
      for (const l of body.pair_lookups ?? []) {
        if (hub.registered.has(l)) return json(200, { data: { ...hub.codeInfo(l), pair_hub_origin: declared(DEVICE_HUB) } });
      }
      return json(404, { error: { code: 'not_found', message: 'invalid or expired code' } });
    }
    return json(500, { error: { code: 'unexpected', message: url } });
  }) as typeof fetch);
  return { b, code };
}

test('lookUpPairing derives with the declared origin, not the page origin', async () => {
  const { b, code } = await setup((real) => real);
  try {
    const review = await lookUpPairing(code, USER);
    assert.equal(review.browser?.device_id, b.deviceId);
    assert.equal(review.fingerprint, b.fingerprint);
  } finally {
    setVaultDevicesFetch(null);
  }
});

test('lookUpPairing: a hub that alters the declared origin gets a refusal', async () => {
  const { code } = await setup(() => 'https://heimdall.mundus.test:443');
  try {
    await assert.rejects(lookUpPairing(code, USER));
  } finally {
    setVaultDevicesFetch(null);
  }
});

test('lookUpPairing: a candidate without a valid declared origin is never derived (no page-origin fallback)', async () => {
  for (const origin of [undefined, 'https://hub.mundus.test', 'not an origin']) {
    const { code } = await setup(() => origin);
    try {
      await assert.rejects(lookUpPairing(code, USER), /No device is waiting|waiting/i);
    } finally {
      setVaultDevicesFetch(null);
    }
  }
});
