// /device/add lookUpPairing (DeviceApprovalPage): the approver derives each candidate's
// lookup with the hub origin THAT CANDIDATE DECLARED (pair_hub_origin), and accepts that
// origin only if it is the page's own API origin or a hub-configured alias
// (--pairing-hub-origins). A device enrolled against an alias https://hub.x pairs while
// the UI runs on https://app.x; a device enrolled through a relay (an origin the hub does
// not list) is refused; a hub that alters the declared origin only gets a refusal.
// Hermetic: fake hub behind a stubbed fetch.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_device_approval_lookup_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, browserPairCtx, newBrowser } from './helpers/vaultDirectoryFixture.ts';

const { lookUpPairing } = await import('../src/ui/components/devices/DeviceApprovalPage.tsx');
const { setVaultDevicesFetch } = await import('../src/ui/api/endpoints/vaultDevices.ts');
const { buildPairedRegistration } = await import('../src/ui/utils/vaultDeviceFlows.ts');
const { acceptedPairOrigins, derivePairKeys, generatePairCode, generatePairSalt } = await import('../src/ui/utils/vaultPairing.ts');

const ALIAS = 'https://hub.mundus.test:443'; // a hub alias a device may enroll against
const PAGE = 'https://heimdall.mundus.test/'; // where the approving UI is served
const OWN = 'https://heimdall.mundus.test:443'; // the page's own API origin
const RELAY = 'https://evil.example.test:443';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

interface Setup {
  /** The origin the new device bound and declares. */
  bound: string;
  /** What the hub serves as the declared origin (a hostile hub may alter it). */
  served?: (real: string) => string | undefined;
  /** Hub-configured aliases. */
  aliases?: unknown;
}

async function setup({ bound, served = (r) => r, aliases = [ALIAS] }: Setup) {
  (globalThis as any).location = { href: PAGE, origin: new URL(PAGE).origin };
  const hub = new FakeHub();
  await hub.genesis(await newBrowser());
  const b = await newBrowser();
  const code = generatePairCode();
  const salt = generatePairSalt();
  const keys = await derivePairKeys(code, { ...browserPairCtx(salt), hubOrigin: bound });
  const reg = await buildPairedRegistration(b, 'Phone', keys);
  await hub.register(reg.statement, reg.pairLookup, reg.pairKeyMac, salt, bound);
  setVaultDevicesFetch((async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    if (url.endsWith('/device/pair-salts')) {
      const origin = served(bound);
      return json(200, { data: { pairing_hub_origins: aliases, candidates: [{ kind: 'browser', pair_salt: salt, ...(origin === undefined ? {} : { pair_hub_origin: origin }) }] } });
    }
    if (url.endsWith('/device/verify')) {
      for (const l of body.pair_lookups ?? []) {
        if (hub.registered.has(l)) return json(200, { data: { ...hub.codeInfo(l), pair_hub_origin: served(bound) } });
      }
      return json(404, { error: { code: 'not_found', message: 'invalid or expired code' } });
    }
    return json(500, { error: { code: 'unexpected', message: url } });
  }) as typeof fetch);
  return { b, code };
}

async function withSetup(s: Setup, fn: (x: { b: any; code: string }) => Promise<void>) {
  const x = await setup(s);
  try {
    await fn(x);
  } finally {
    setVaultDevicesFetch(null);
  }
}

test('acceptedPairOrigins: own API origin plus well-formed hub aliases only', () => {
  assert.deepEqual([...acceptedPairOrigins(OWN, [ALIAS, 'https://bad', 7, ALIAS])], [OWN, ALIAS]);
  assert.deepEqual([...acceptedPairOrigins(null, null)], []);
});

test('lookUpPairing: a device bound to a configured alias pairs (declared origin, not the page origin) and is flagged', async () => {
  await withSetup({ bound: ALIAS }, async ({ b, code }) => {
    const review = await lookUpPairing(code, USER);
    assert.equal(review.browser?.device_id, b.deviceId);
    assert.equal(review.hubOrigin, ALIAS);
    assert.equal(review.foreignOrigin, true);
  });
});

test("lookUpPairing: a device bound to the page's own API origin pairs without aliases", async () => {
  await withSetup({ bound: OWN, aliases: [] }, async ({ b, code }) => {
    const review = await lookUpPairing(code, USER);
    assert.equal(review.browser?.device_id, b.deviceId);
    assert.equal(review.hubOrigin, OWN);
    assert.equal(review.foreignOrigin, false);
  });
});

test('lookUpPairing: a device that enrolled through a non-listed origin (relay) is refused with a clear error', async () => {
  await withSetup({ bound: RELAY }, async ({ code }) => {
    await assert.rejects(lookUpPairing(code, USER), (err: Error) => err.message.includes(RELAY) && /not one of this hub's pairing addresses/.test(err.message));
  });
});

test('lookUpPairing: a hub that alters the declared origin (even to an accepted one) gets a refusal', async () => {
  await withSetup({ bound: ALIAS, served: () => OWN }, async ({ code }) => {
    await assert.rejects(lookUpPairing(code, USER), /No device is waiting/);
  });
});

test('lookUpPairing: a candidate without a valid declared origin is never derived (no page-origin fallback)', async () => {
  for (const origin of [undefined, 'https://heimdall.mundus.test', 'not an origin']) {
    await withSetup({ bound: OWN, served: () => origin }, async ({ code }) => {
      await assert.rejects(lookUpPairing(code, USER), /No device is waiting/);
    });
  }
});
