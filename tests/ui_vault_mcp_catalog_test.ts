import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mcpWorkerFixture } from './helpers/mcpWorkerFixture.ts';
import { mcpJobDigest, mcpJobScopeAllowed, verifyMcpWorkerJob, transformMcpWorkerJob } from '../src/ui/utils/mcpWorker.ts';
import { decryptVaultBytes } from '../src/ui/utils/vaultContent.ts';

test('agent writes seal only typed prose under signed management rights', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:agents:write');
  const job = { ...f.job, tool: 'agents.create', operation: 'seal_agent' as const, payload: JSON.stringify({ name: 'Private name', slug: 'Private slug', instructions: 'Private instructions' }) };
  job.digest = await mcpJobDigest(job);
  await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
  const sealed = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  for (const field of ['name', 'slug', 'instructions']) assert.match(sealed[field], /^vault:v2:/);
  assert.ok(!JSON.stringify(sealed).includes('Private'));
  const clear = JSON.parse(await transformMcpWorkerJob({ ...job, tool: 'agents.update', payload: JSON.stringify({ instructions: '' }) }, f.keyring));
  const opened = await decryptVaultBytes(clear.instructions, f.keyring);
  assert.equal(opened.status, 'ok');
  if (opened.status === 'ok') { assert.equal(opened.bytes.length, 0); opened.bytes.fill(0); }
  for (const body of [{ token: 'never seal arbitrary credentials' }, { instructions: 'x'.repeat(65537) }, { name: 'x'.repeat(501) }, { name: ' ' }]) await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify(body) }, f.keyring));
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:agents:read', 'agents.create', 'seal_agent'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:agents:write', 'agents.create', 'seal_task'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:tasks:write', 'agents.create', 'seal_agent'), false);
});

test('catalog reads open approved text and omit runtime credentials and diagnostics', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:agents:read mcp:instances:read');
  const token = JSON.parse(f.job.payload).chain.title;
  const cases = [
    ['agents.get', 'agent', { agent_id: 'agt_a', name: token, slug: token, instructions: token, permission_mode: 'ask', revision: 'a'.repeat(64), supports: [{ bridge_id: 'brg_a', enabled: true }] }, ['name', 'slug', 'instructions']],
    ['instances.get', 'instance', { agent_instance_id: 'inst_a', agent_id: 'agt_a', bridge_id: 'brg_a', display_name: token, provider: 'codex', provider_profile: 'work', model: 'model_a', runtime_status: 'running', revision: 'b'.repeat(64) }, ['display_name']],
    ['bridges.list', 'bridge', { bridge_id: 'brg_a', label: token, status: 'online', eligible: true }, ['label']],
    ['providers.list', 'provider', { bridge_id: 'brg_a', provider: 'codex', provider_profile: 'work', display_name: 'Codex', label: token, models: [{ model_id: 'model_a', label: token, state: 'active', rank: 1, eligible: true }] }, ['label']],
  ] as const;
  for (const [tool, kind, record, textFields] of cases) {
    const input = { records_kind: kind, records: [{ owner_user_id: f.job.owner, ...record, bridge_token_hash: 'no', binary_path: 'no', base_args_json: 'no', environment: 'no', provider_transcript_path: 'no', launch_epoch: 'no', last_error_json: 'no' }], next_cursor: 'bound_position' };
    const job = { ...f.job, tool, payload: JSON.stringify(input) };
    job.digest = await mcpJobDigest(job);
    await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
    const output = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
    assert.equal(output.records_kind, kind);
    for (const field of textFields) assert.equal(output.records[0][field], 'worker secret title');
    for (const field of ['bridge_token_hash', 'binary_path', 'base_args_json', 'environment', 'provider_transcript_path', 'launch_epoch', 'last_error_json']) assert.equal(output.records[0][field], undefined);
    if (kind === 'provider') assert.equal(output.records[0].models[0].label, 'worker secret title');
    if (kind === 'instance') assert.equal(output.records[0].revision, 'b'.repeat(64));
    assert.equal(output.next_cursor, 'bound_position');
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ ...input, records_kind: 'wrong_kind' }) }, f.keyring));
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ ...input, chain: { title: token } }) }, f.keyring));
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ ...input, records: [{ ...input.records[0], owner_user_id: 'foreign_owner' }] }) }, f.keyring));
  }
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:agents:read', 'providers.list', 'read'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:instances:read', 'agents.get', 'read'), false);
});
