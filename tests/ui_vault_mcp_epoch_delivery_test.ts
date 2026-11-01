import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, hubApi, recorder } from './helpers/vaultDirectoryFixture.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../src/ui/utils/deviceIdentity.ts';
import { buildMcpConsent } from '../src/ui/utils/mcpConsent.ts';
import { verifiedConnectorRecipient, buildConnectorEpochWraps, type ConnectorEpochDelivery } from '../src/ui/utils/mcpEpochDelivery.ts';
import * as dv from '../src/ui/services/deviceVault.ts';

const resource = 'https://hub.example/api/v1/mcp';
async function setup(scope = 'mcp:chains') {
  const kv = memoryDeviceStore();
  const identity = await createDeviceIdentity(kv, USER);
  const hub = new FakeHub();
  await hub.genesis(identity);
  const chain = await hub.chain();
  const now = Date.now();
  const request = { owner: USER, client: 'client-fixture', redirect: 'https://client.example/callback', resource, scope, grant: 'grant-fixture', family: 'family-fixture', revision: 1, expires_ms: now + 300000 };
  const body = await buildMcpConsent('ticket', request, 'hosted', identity, chain, async (run) => { const bytes = await hub.keyringBytes(identity); try { return await run(bytes); } finally { bytes.fill(0); } }, now);
  const row = { grant: request.grant, revision: 1, consent: body.consent, signature: body.signature };
  return { kv, identity, hub, chain, row };
}

test('connector recipient comes from signed consent and a pinned verified chain', async () => {
  const { identity, hub, chain, row } = await setup();
  const recipient = await verifiedConnectorRecipient(row, chain, resource);
  assert.equal(recipient.ecdh_public_key, JSON.parse(row.consent).recipient_public_key);
  await assert.rejects(verifiedConnectorRecipient({ ...row, grant: 'other' }, chain, resource));
  await assert.rejects(verifiedConnectorRecipient(row, chain, 'https://other.example/mcp'));
  const changed = JSON.parse(row.consent); changed.recipient_public_key = identity.ecdhPub;
  await assert.rejects(verifiedConnectorRecipient({ ...row, consent: JSON.stringify(changed) }, chain, resource));
  const revoked = { ...chain, trusted: new Map(chain.trusted) }; revoked.trusted.delete(identity.deviceId);
  await assert.rejects(verifiedConnectorRecipient(row, revoked, resource));
  const bytes = await hub.keyringBytes(identity);
  try {
    const wraps = await buildConnectorEpochWraps(identity, chain, [row], bytes, resource);
    assert.equal(wraps.length, 1);
    assert.equal(JSON.parse(wraps[0].wrap_json).recipient_device_id, recipient.device_id);
    await assert.rejects(buildConnectorEpochWraps(identity, chain, [row, row], bytes, resource));
  } finally { bytes.fill(0); }
});

test('scoped hosted recipient verifies v2 consent and cannot accept a changed scope', async () => {
  const { identity, hub, chain, row } = await setup('mcp:chains mcp:tasks:read mcp:artifacts:read');
  const recipient = await verifiedConnectorRecipient(row, chain, resource);
  assert.match(recipient.device_id, /^mcp_/);
  const changed = { ...JSON.parse(row.consent), scope: 'mcp:chains mcp:tasks:write' };
  await assert.rejects(verifiedConnectorRecipient({ ...row, consent: JSON.stringify(changed) }, chain, resource));
  const bytes = await hub.keyringBytes(identity);
  try { assert.equal((await buildConnectorEpochWraps(identity, chain, [row], bytes, resource)).length, 1); }
  finally { bytes.fill(0); }
});

test('rotation automatically delivers connector wraps; failure preserves rotation and can be repaired', async (t) => {
  const { kv, identity, hub, row } = await setup();
  const rec = recorder();
  const delivered: ConnectorEpochDelivery[] = [];
  let fail = true;
  const api = hubApi(hub, { postRotateDirectory: async (body) => {
    await hub.append(body.statement, body.signature);
    for (const wrap of body.wraps) hub.wraps.set(wrap.recipient_device_id, wrap);
    return { directory_version: hub.version };
  } });
  dv.stopDeviceVault();
  dv.configureDeviceVault({ kv, api, bridges: null, pollIntervalMs: 1e9, connectors: {
    list: async () => [row], resource: () => resource,
    deliver: async (body) => { if (fail) throw new Error('offline'); delivered.push(body); },
  } });
  t.after(() => dv.stopDeviceVault());
  await dv.bootDeviceVault(USER, rec.dispatch);
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'ready');
  const result = await dv.rotateKeys();
  assert.equal(result.outcome.kind, 'rotated');
  assert.equal(hub.currentEpoch, 2, 'directory rotation committed despite a delivery failure');
  assert.match(rec.last('deviceVault/mcpKeyDeliveryReported'), /updated decryption keys/);
  assert.equal(delivered.length, 0);
  fail = false;
  await dv.refreshConnectorEpochs();
  assert.equal(rec.last('deviceVault/mcpKeyDeliveryReported'), '');
  assert.equal(delivered.length, 1);
  assert.equal(JSON.parse(delivered[0].wrap_json).current_epoch, 2);
  assert.equal(JSON.parse(delivered[0].wrap_json).wrapped_by_device_id, identity.deviceId);
});
