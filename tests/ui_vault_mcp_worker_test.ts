import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mcpWorkerFixture } from './helpers/mcpWorkerFixture.ts';
import { verifyMcpWorkerJob, transformMcpWorkerJob, mcpJobDigest, mcpJobScopeAllowed, mcpJobDeadlineMaxMs, MCP_JOB_ARTIFACT_DEADLINE_MAX_MS, MCP_JOB_DEADLINE_MAX_MS } from '../src/ui/utils/mcpWorker.ts';
import { decryptVaultBytes } from '../src/ui/utils/vaultContent.ts';

test('requirement changes seal their reason and extended reads decrypt history without changing acknowledgement metadata', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:tasks:read mcp:tasks:write');
  const edit = { ...f.job, tool: 'tasks.update', operation: 'seal_task' as const, payload: JSON.stringify({ goal: 'Changed goal', reason: 'Changed requirement reason' }) };
  edit.digest = await mcpJobDigest(edit);
  await verifyMcpWorkerJob(edit, f.identity, f.chain, edit.resource, f.now);
  const sealed = JSON.parse(await transformMcpWorkerJob(edit, f.keyring));
  assert.match(sealed.goal, /^vault:v2:/); assert.match(sealed.reason, /^vault:v2:/);
  const acknowledgements = [{ lease_id: 'lease_a', holder_instance_id: 'inst_a', revision: 1, pending: true }];
  const read = { ...f.job, tool: 'tasks.get', payload: JSON.stringify({ tasks: [{
    owner_user_id: f.job.owner, task_id: 'task_a', title: '',
    requirements_revision: 2, requirements_submitted_revision: 1,
    requirements_submitted_head: 'submitted-head', requirements_checkpoint_required: true,
    requirements_acknowledgements: acknowledgements,
    requirements_history: `Revision 2\nReason: ${sealed.reason}\nAfter goal: ${sealed.goal}\n`,
  }] }) };
  read.digest = await mcpJobDigest(read);
  await verifyMcpWorkerJob(read, f.identity, f.chain, read.resource, f.now);
  const result = JSON.parse(await transformMcpWorkerJob(read, f.keyring)).tasks[0];
  assert.match(result.requirements_history, /Changed requirement reason/);
  assert.match(result.requirements_history, /Changed goal/);
  assert.ok(!result.requirements_history.includes('vault:v2:'));
  assert.deepEqual(result.requirements_acknowledgements, acknowledgements);
  const legacy = JSON.parse(await transformMcpWorkerJob({ ...read, tool: undefined }, f.keyring)).tasks[0];
  assert.equal(legacy.requirements_history, undefined, 'legacy grant projection never gains requirement history');
});

test('task comment worker requires signed write scope and binds the tool in its digest', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:tasks:write');
  const job = { ...f.job, tool: 'tasks.comment', operation: 'seal_comment' as const, payload: JSON.stringify({ body: 'task comment secret' }) };
  job.digest = await mcpJobDigest(job);
  await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
  const result = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  assert.match(result.body, /^vault:v2:/);
  assert.ok(!JSON.stringify(result).includes('task comment secret'));
  const opened = await decryptVaultBytes(result.body, f.keyring);
  assert.equal(opened.status, 'ok');
  if (opened.status === 'ok') {
    assert.equal(new TextDecoder().decode(opened.bytes), 'task comment secret');
    opened.bytes.fill(0);
  }
  await assert.rejects(verifyMcpWorkerJob({ ...job, tool: 'tasks.get' }, f.identity, f.chain, job.resource, f.now));
  const legacy = await mcpWorkerFixture();
  const unauthorized = { ...legacy.job, tool: 'tasks.comment', operation: 'seal_comment' as const, payload: job.payload };
  unauthorized.digest = await mcpJobDigest(unauthorized);
  await assert.rejects(verifyMcpWorkerJob(unauthorized, legacy.identity, legacy.chain, unauthorized.resource, legacy.now));
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:tasks:read', 'tasks.comment', 'seal_comment'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:tasks:write', 'tasks.get', 'read'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains', undefined, 'seal_comment'), false);
  const create = { ...f.job, tool: 'tasks.create', operation: 'seal_task' as const, payload: JSON.stringify({ title: 'private title', goal: 'private goal', acceptance: ['private acceptance'] }) };
  create.digest = await mcpJobDigest(create);
  await verifyMcpWorkerJob(create, f.identity, f.chain, create.resource, f.now);
  const sealedTask = JSON.parse(await transformMcpWorkerJob(create, f.keyring));
  assert.match(sealedTask.title, /^vault:v2:/);
  assert.match(sealedTask.goal, /^vault:v2:/);
  assert.match(sealedTask.acceptance[0], /^vault:v2:/);
  assert.ok(!JSON.stringify(sealedTask).includes('private'));
  await assert.rejects(transformMcpWorkerJob({ ...create, payload: JSON.stringify({ owner_user_id: 'foreign' }) }, f.keyring));
  await assert.rejects(transformMcpWorkerJob({ ...create, payload: JSON.stringify({ acceptance: ['x'.repeat(201)] }) }, f.keyring));
});

test('extended task reads open only typed brief fields and retain legacy projection', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:tasks:read');
  const token = JSON.parse(f.job.payload).chain.title;
  const payload = JSON.stringify({ tasks: [{ owner_user_id: f.job.owner, task_id: 'task_a', chain_id: 'chain_a', title: token, description: '', goal: token, acceptance: [token], assignee_agent_id: 'agt_a', bridge_id: 'brg_a', arbitrary_secret: 'omitted' }] });
  const job = { ...f.job, tool: 'tasks.get', payload };
  job.digest = await mcpJobDigest(job);
  await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
  const result = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  assert.equal(result.tasks[0].goal, 'worker secret title');
  assert.deepEqual(result.tasks[0].acceptance, ['worker secret title']);
  assert.equal(result.tasks[0].bridge_id, 'brg_a');
  assert.equal(result.tasks[0].arbitrary_secret, undefined);
  const legacy = JSON.parse(await transformMcpWorkerJob({ ...job, tool: undefined }, f.keyring));
  assert.equal(legacy.tasks[0].goal, undefined);
  assert.equal(legacy.tasks[0].acceptance, undefined);
  const malformed = JSON.parse(payload); malformed.tasks[0].acceptance = [{}];
  await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify(malformed) }, f.keyring));
});

test('task detail worker retains typed hold, attempt, provenance and comment paging metadata', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:tasks:read');
  const token = JSON.parse(f.job.payload).chain.title;
  const input = {
    tasks: [{ owner_user_id: f.job.owner, task_id: 'task_a', chain_id: 'chain_a', title: token,
      inputs: [token, 'output:task_ref'], review_roles: ['reviewer'], reviewers: ['agt_reviewer'],
      blocked_kind: 'agent_not_running', blocked_since_ms: 123, blocked_reason: token,
      hold_reason: token, hold_since_ms: 456, hold_by: 'user', checkpoint_requested: true,
      allowed_actions: ['release', 'recheck'], latest_attempt_no: 2,
      latest_attempt_holder_instance_id: 'inst_worker', latest_attempt_outcome: 'submitted',
      latest_attempt_summary: token, arbitrary_facet: { secret: token },
      reviews: [{ reviewer_agent_id: 'agt_reviewer', reviewer_instance_id: 'inst_reviewer', verdict: 'approve' }] }],
    comments: [{ owner_user_id: f.job.owner, comment_id: 'cmt_a', task_id: 'task_a', chain_id: 'chain_a', body: token,
      author_kind: 'delegated_user', author_user_id: f.job.owner, author_agent_instance_id: '',
      delegated_client_id: 'client_a', delegated_grant_id: 'grant_a' },
      { owner_user_id: f.job.owner, comment_id: 'cmt_big', body_error: 'comment_too_large', body_bytes: 300000 }],
    comments_next_cursor: 'owner-task-bound-position',
  };
  const job = { ...f.job, tool: 'tasks.get', payload: JSON.stringify(input) };
  const output = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  const task = output.tasks[0];
  assert.deepEqual(task.inputs, ['worker secret title', 'output:task_ref']);
  for (const key of ['blocked_reason', 'hold_reason', 'latest_attempt_summary']) assert.equal(task[key], 'worker secret title');
  for (const key of ['blocked_since_ms', 'hold_since_ms', 'checkpoint_requested', 'allowed_actions', 'latest_attempt_no', 'reviews']) assert.deepEqual(task[key], input.tasks[0][key as keyof typeof input.tasks[0]]);
  assert.equal(task.arbitrary_facet, undefined);
  assert.equal(output.comments[0].body, 'worker secret title');
  assert.equal(output.comments[0].author_kind, 'delegated_user');
  assert.equal(output.comments[0].delegated_grant_id, 'grant_a');
  assert.equal(output.comments[1].body, undefined);
  assert.equal(output.comments[1].body_error, 'comment_too_large');
  assert.equal(output.comments_next_cursor, input.comments_next_cursor);
  input.tasks[0].hold_reason = 'vault:v2:broken';
  await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify(input) }, f.keyring));
});
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

test('MCP job deadline window: 20 s only for html-bundle capable artifact jobs (mirrors vault.control_job_deadline_max_ms)', () => {
  assert.equal(MCP_JOB_DEADLINE_MAX_MS, 5000);
  assert.equal(MCP_JOB_ARTIFACT_DEADLINE_MAX_MS, 20000);
  assert.equal(mcpJobDeadlineMaxMs('seal_resource', 'artifacts.create'), 20000);
  assert.equal(mcpJobDeadlineMaxMs('read', 'artifacts.get'), 20000);
  assert.equal(mcpJobDeadlineMaxMs('read', 'artifacts.list'), 5000);
  assert.equal(mcpJobDeadlineMaxMs('seal_resource', 'memories.create'), 5000);
  assert.equal(mcpJobDeadlineMaxMs('read', 'chains.get'), 5000);
  assert.equal(mcpJobDeadlineMaxMs('seal'), 5000);
});

test('coordinator messages require dedicated signed consent and seal as user-message text', async () => {
  const f = await mcpWorkerFixture(Date.now(), 'mcp:chains mcp:chains:message');
  const job = { ...f.job, tool: 'chains.message', operation: 'seal_message' as const, payload: JSON.stringify({ body: 'Private coordinator text' }) };
  job.digest = await mcpJobDigest(job);
  await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
  const sealed = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  assert.deepEqual(Object.keys(sealed), ['body']);
  const opened = await decryptVaultBytes(sealed.body, f.keyring);
  assert.equal(opened.status, 'ok');
  if (opened.status === 'ok') {
    assert.equal(new TextDecoder().decode(opened.bytes), 'Private coordinator text');
    opened.bytes.fill(0);
  }
  for (const scope of ['mcp:chains', 'mcp:chains mcp:tasks:write', 'mcp:chains mcp:instances:control']) {
    assert.equal(mcpJobScopeAllowed(scope, 'chains.message', 'seal_message'), false);
  }
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:chains:message', 'tasks.comment', 'seal_message'), false);
  await assert.rejects(verifyMcpWorkerJob({ ...job, operation: 'seal_comment' }, f.identity, f.chain, job.resource, f.now));
  for (const body of ['', '   ', 'é'.repeat(10001)]) {
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ body }) }, f.keyring));
  }
});
