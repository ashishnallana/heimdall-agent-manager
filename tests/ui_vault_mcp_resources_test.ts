import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mcpWorkerFixture } from './helpers/mcpWorkerFixture.ts';
import { mcpJobDigest, mcpJobScopeAllowed, transformMcpWorkerJob, verifyMcpWorkerJob } from '../src/ui/utils/mcpWorker.ts';
import { decryptVaultBytes } from '../src/ui/utils/vaultContent.ts';

const scope = 'mcp:chains mcp:memories:read mcp:memories:write mcp:projects:read mcp:projects:write mcp:issues:read mcp:issues:write';
test('resource sealing requires exact signed tool rights and excludes operational metadata', async () => {
  const f = await mcpWorkerFixture(Date.now(), scope);
  for (const [tool, fields] of [
    ['memories.create', { title: 'Memory title', body: 'Memory body', evidence: '', description: '' }],
    ['memories.update', { body: 'Changed memory' }],
    ['projects.create', { name: 'Project name', description: '' }],
    ['projects.update', { description: 'Changed project' }],
    ['issues.create', { title: 'Issue title', description: '' }],
    ['issues.update', { description: 'Changed issue' }],
    ['issues.comment', { body: 'Comment body' }],
  ] as const) {
    const job = { ...f.job, operation: 'seal_resource' as const, tool, payload: JSON.stringify(fields) };
    job.digest = await mcpJobDigest(job);
    await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
    const result = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
    for (const [key, text] of Object.entries(fields)) {
      assert.match(result[key], /^vault:v2:/);
      const opened = await decryptVaultBytes(result[key], f.keyring);
      assert.equal(opened.status, 'ok');
      if (opened.status === 'ok') { assert.equal(new TextDecoder().decode(opened.bytes), text); opened.bytes.fill(0); }
    }
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ environment: 'no' }) }, f.keyring));
  }
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:memories:read', 'memories.create', 'seal_resource'), false);
  assert.equal(mcpJobScopeAllowed(scope, 'memories.approve', 'seal_resource'), false);
  assert.equal(mcpJobScopeAllowed(scope, 'projects.create', 'seal_task'), false);
  await assert.rejects(transformMcpWorkerJob({ ...f.job, tool: 'projects.create', operation: 'seal_resource', payload: JSON.stringify({ default_path: '/no' }) }, f.keyring));
  await assert.rejects(transformMcpWorkerJob({ ...f.job, tool: 'memories.create', operation: 'seal_resource', payload: JSON.stringify({ body: 'x'.repeat(65537) }) }, f.keyring));
});

test('typed resource reads preserve system read-only, operational paths and nested issue comment ownership', async () => {
  const f = await mcpWorkerFixture(Date.now(), scope);
  const token = JSON.parse(f.job.payload).chain.title;
  const cases = [
    ['memories.get', 'memory', { owner_user_id: f.job.owner, memory_id: 'mem_a', read_only: false, title: token, body: token, evidence: token, status: 'pending', project_ids: ['proj_a'] }],
    ['memories.get', 'memory', { owner_user_id: 'system', memory_id: 'mem_system', read_only: true, title: 'System title', body: 'Public built-in', status: 'active' }],
    ['projects.get', 'project', { owner_user_id: f.job.owner, project_id: 'proj_a', name: token, slug: token, description: token, default_path: '/native/path', bridge_paths: [{ bridge_id: 'brg_a', path: '/owned/override', is_validated: false, last_validated_at: '', updated_at: '' }] }],
    ['issues.get', 'issue', { owner_user_id: f.job.owner, issue_id: 'iss_a', title: token, description: token, comments: [{ owner_user_id: f.job.owner, issue_id: 'iss_a', comment_id: 'icmt_a', author_id: f.job.owner, author_name: token, body: token, raw_metadata: 'never expose' }], comments_next_cursor: 'bound_comments' }],
  ] as const;
  for (const [tool, kind, record] of cases) {
    const input = { records_kind: kind, records: [{ ...record, secret: 'never expose' }] };
    const job = { ...f.job, operation: 'read' as const, tool, payload: JSON.stringify(input) };
    job.digest = await mcpJobDigest(job);
    await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
    const result = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
    assert.ok(!JSON.stringify(result).includes('never expose'));
    assert.ok(!JSON.stringify(result).includes('vault:v2:'));
    if (kind === 'project') assert.equal(result.records[0].default_path, '/native/path');
    if (kind === 'issue') { assert.equal(result.records[0].comments[0].body, 'worker secret title'); assert.equal(result.records[0].comments_next_cursor, 'bound_comments'); }
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ ...input, records: [{ ...record, owner_user_id: 'foreign_owner' }] }) }, f.keyring));
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ ...input, records_kind: 'wrong_kind' }) }, f.keyring));
  }
  const bad = { records_kind: 'issue', records: [{ owner_user_id: f.job.owner, issue_id: 'iss_a', comments: [{ owner_user_id: 'foreign', body: token }] }] };
  await assert.rejects(transformMcpWorkerJob({ ...f.job, tool: 'issues.get', payload: JSON.stringify(bad) }, f.keyring));
  const preview = JSON.parse(await transformMcpWorkerJob({ ...f.job, tool: 'issues.list', payload: JSON.stringify({ records_kind: 'issue', records: [{ owner_user_id: f.job.owner, issue_id: 'iss_preview', description: 'é'.repeat(400), description_limit: 512 }] }) }, f.keyring));
  assert.equal(new TextEncoder().encode(preview.records[0].description).length, 512);
  assert.ok(!preview.records[0].description.includes('\ufffd'));
});
