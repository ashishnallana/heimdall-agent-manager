import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mcpWorkerFixture } from './helpers/mcpWorkerFixture.ts';
import { verifyMcpWorkerJob, transformMcpWorkerJob, mcpJobDigest } from '../src/ui/utils/mcpWorker.ts';
import { importKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { FakeHub, newBrowser, hubApi, recorder, USER } from './helpers/vaultDirectoryFixture.ts';
import { memoryDeviceStore } from '../src/ui/utils/deviceIdentity.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import * as dv from '../src/ui/services/deviceVault.ts';
import { isMcpWorkerEnabled, setMcpWorkerEnabled } from '../src/ui/services/mcpWorker.ts';

test('MCP worker verifies pinned consent, owner, head, digest, generation and deadline', async () => {
  const f = await mcpWorkerFixture();
  const verify = (j = f.job, c = f.chain, resource = f.job.resource, now = f.now) => verifyMcpWorkerJob(j, f.identity, c, resource, now);
  await verify();
  for (const patch of [{ owner: 'another' }, { generation: 'other' }, { payload: '{}' }, { grant: 'other' }, { head: '0'.repeat(64) }, { epoch: 2 }, { deadline_ms: f.now }, { deadline_ms: f.now + 6000 }]) await assert.rejects(verify({ ...f.job, ...patch }));
  await assert.rejects(verify(f.job, f.chain, 'https://other.example/api/v1/mcp'));
  const untrusted = { ...f.chain, trusted: new Map(f.chain.trusted) }; untrusted.trusted.delete(f.identity.deviceId);
  await assert.rejects(verify(f.job, untrusted));
  const c = JSON.parse(f.job.consent); c.client = 'attacker';
  const forged = { ...f.job, consent: JSON.stringify(c) }; forged.digest = await mcpJobDigest(forged);
  await assert.rejects(verify(forged));
});

test('MCP worker accepts signed v2 scope and rejects unsigned scope/version changes', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:tasks:read mcp:artifacts:read');
  await verifyMcpWorkerJob(f.job, f.identity, f.chain, f.job.resource, f.now);
  for (const patch of [{ v: 1 }, { scope: 'mcp:chains' }, { scope: 'mcp:chains mcp:tasks:write' }, { scope: 'mcp:chains mcp:messages:write' }]) {
    const job = { ...f.job, consent: JSON.stringify({ ...JSON.parse(f.job.consent), ...patch }) };
    job.digest = await mcpJobDigest(job);
    await assert.rejects(verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now));
  }
});

test('MCP worker projects readable records and fails closed instead of returning locked placeholders', async () => {
  const f = await mcpWorkerFixture();
  const result = JSON.parse(await transformMcpWorkerJob(f.job, f.keyring));
  assert.equal(result.chain.title, 'worker secret title');
  assert.equal(result.chain.description, 'embedded worker secret body');
  assert.equal(result.chain.defaults_json, undefined);
  const input = JSON.parse(f.job.payload);
  input.chain.owner_user_id = 'someone_else';
  await assert.rejects(transformMcpWorkerJob({ ...f.job, payload: JSON.stringify(input) }, f.keyring));
  input.chain.owner_user_id = f.job.owner;
  for (const title of ['vault:v2:broken', 'embedded vault:v2:broken']) {
    input.chain.title = title;
    await assert.rejects(transformMcpWorkerJob({ ...f.job, payload: JSON.stringify(input) }, f.keyring));
  }
  const other = await mcpWorkerFixture();
  await assert.rejects(transformMcpWorkerJob(f.job, other.keyring));
  const wrong = Buffer.from(f.keyringHex, 'hex'); wrong[wrong.length - 1] ^= 1;
  await assert.rejects(transformMcpWorkerJob(f.job, await importKeyring(new Uint8Array(wrong), f.job.owner)));
  const sealed = JSON.parse(await transformMcpWorkerJob({ ...f.job, operation: 'seal', payload: JSON.stringify({ title: 'new chain', description: '' }) }, f.keyring));
  assert.match(sealed.title, /^vault:v2:/); assert.match(sealed.description, /^vault:v2:/);
});

test('browser worker is off by default, registers only on explicit opt-in, and withdraws on lock', async (t) => {
  const kv = memoryDeviceStore();
  const identity = await newBrowser(USER, kv);
  const hub = new FakeHub(); await hub.genesis(identity);
  dv.stopDeviceVault(); dv.configureDeviceVault({ kv, api: hubApi(hub), bridges: null, connectors: null, pollIntervalMs: 1e9 });
  await dv.bootDeviceVault(USER, recorder().dispatch);
  const originalFetch = globalThis.fetch;
  const registrations: any[] = [];
  globalThis.fetch = async (url, init) => {
    assert.ok((init?.headers as Record<string, string>)['X-Heimdall-Device-Sig']);
    if (String(url).endsWith('/worker')) {
      const body = JSON.parse(String(init?.body)); registrations.push(body);
      return new Response(JSON.stringify({ registered: body.enabled }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    assert.match(String(url), /\/jobs\?generation=/);
    return new Response(null, { status: 204 });
  };
  t.after(async () => { await setMcpWorkerEnabled(false).catch(() => {}); dv.stopDeviceVault(); globalThis.fetch = originalFetch; });
  assert.equal(isMcpWorkerEnabled(), false);
  await setMcpWorkerEnabled(true);
  assert.equal(isMcpWorkerEnabled(), true);
  assert.equal(registrations.length, 1); assert.equal(registrations[0].enabled, true);
  clearKeyringSession();
  assert.equal(isMcpWorkerEnabled(), false);
  const deadline = Date.now() + 500;
  while (!registrations.some(r => r.enabled === false) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(registrations.at(-1).enabled, false);
  assert.equal(registrations.at(-1).generation, registrations[0].generation);
});
