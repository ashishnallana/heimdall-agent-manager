import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mcpWorkerFixture } from './helpers/mcpWorkerFixture.ts';
import { mcpJobDigest, mcpJobScopeAllowed, transformMcpWorkerJob, verifyMcpWorkerJob } from '../src/ui/utils/mcpWorker.ts';
import { decryptVaultBytes, encryptVaultText } from '../src/ui/utils/vaultContent.ts';

const scope = 'mcp:chains mcp:artifacts:read mcp:artifacts:write';
test('artifact workers seal only bounded typed prose with explicit artifact write consent', async () => {
  const f = await mcpWorkerFixture(Date.now(), scope);
  for (const [tool, input] of [
    ['artifacts.create', { name: 'Private result.md', description: '', content: '# Private result\nDone.' }],
    ['artifacts.update', { name: 'Renamed.md', description: '' }],
  ] as const) {
    const job = { ...f.job, tool, operation: 'seal_resource' as const, payload: JSON.stringify(input) };
    job.digest = await mcpJobDigest(job);
    await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
    const output = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
    for (const [key, value] of Object.entries(input)) {
      assert.match(output[key], /^vault:v2:/);
      const opened = await decryptVaultBytes(output[key], f.keyring);
      assert.equal(opened.status, 'ok');
      if (opened.status === 'ok') { assert.equal(new TextDecoder().decode(opened.bytes), value); opened.bytes.fill(0); }
    }
    for (const fields of [{ path: '/etc/passwd' }, { content_base64: 'secret' }, { owner_user_id: 'foreign' }]) {
      await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify(fields) }, f.keyring));
    }
  }
  for (const content of ['x'.repeat(65537), 'é'.repeat(32769), '\0', '\ud800']) {
    await assert.rejects(transformMcpWorkerJob({ ...f.job, tool: 'artifacts.create', operation: 'seal_resource', payload: JSON.stringify({ content }) }, f.keyring));
  }
  await assert.rejects(transformMcpWorkerJob({ ...f.job, tool: 'artifacts.update', operation: 'seal_resource', payload: JSON.stringify({ content: 'No replacement' }) }, f.keyring));
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:artifacts:read', 'artifacts.create', 'seal_resource'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:tasks:write', 'artifacts.create', 'seal_resource'), false);
  assert.equal(mcpJobScopeAllowed('mcp:chains mcp:artifacts:write', 'artifacts.get', 'read'), false);
  assert.equal(mcpJobScopeAllowed(scope, 'artifacts.delete', 'seal_resource'), false);
  assert.equal(mcpJobScopeAllowed(scope, 'artifacts.get', 'seal_resource'), false);
});

test('artifact reads decrypt native content and preserve task links without paths or foreign data', async () => {
  const f = await mcpWorkerFixture(Date.now(), scope);
  const token = JSON.parse(f.job.payload).chain.title;
  const record = { owner_user_id: f.job.owner, artifact_id: 'art_result', name: token, description: token, content: token, content_type: 'text/markdown', task_id: 'task_result', chain_id: 'chain_result', link: 'artifact://art_result', revision: 'a'.repeat(64), blob_ref: '/private/path', origin_ref: 'never expose', secret: 'never expose' };
  const job = { ...f.job, tool: 'artifacts.get', operation: 'read' as const, payload: JSON.stringify({ records_kind: 'artifact', records: [record] }) };
  job.digest = await mcpJobDigest(job);
  await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
  const result = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  assert.equal(result.records[0].content, 'worker secret title');
  assert.equal(result.records[0].link, 'artifact://art_result');
  assert.equal(result.records[0].task_id, 'task_result');
  assert.ok(!JSON.stringify(result).includes('/private/path') && !JSON.stringify(result).includes('never expose'));
  for (const owner_user_id of ['foreign', 'system']) {
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ records_kind: 'artifact', records: [{ ...record, owner_user_id, read_only: true }] }) }, f.keyring));
  }
  for (const content of ['x'.repeat(65537), '\0', await encryptVaultText('é'.repeat(32769), f.keyring)]) {
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify({ records_kind: 'artifact', records: [{ ...record, content }] }) }, f.keyring));
  }
  const metadata = JSON.parse(await transformMcpWorkerJob({ ...job, payload: JSON.stringify({ records_kind: 'artifact', records: [{ owner_user_id: f.job.owner, artifact_id: 'art_binary', content_error: 'unsupported_content_type', content_type: 'image/png' }] }) }, f.keyring));
  assert.equal(metadata.records[0].content_error, 'unsupported_content_type');
  assert.equal(metadata.records[0].content, undefined);
});

// Hub-packed html-bundle (artifacts.create entry/files) relayed as content_base64.
const BUNDLE_B64 = 'UEsDBBQAAAAAAFW3Yl2UKFEnLwAAAC8AAAAWAAAAaGVpbWRhbGwtYXJ0aWZhY3QuanNvbnsiZm9ybWF0X3ZlcnNpb24iOjEsImVudHJ5cG9pbnQiOiJpbmRleC5odG1sIn0KUEsDBBQAAAAAAFW3Yl07wbBJIQAAACEAAAAKAAAAaW5kZXguaHRtbDwhZG9jdHlwZSBodG1sPjxpbWcgc3JjPWxvZ28ucG5nPlBLAwQUAAAAAABVt2JdVoDwEwcAAAAHAAAACAAAAGxvZ28ucG5niVBORwD/gFBLAQIUAxQAAAAAAFW3Yl2UKFEnLwAAAC8AAAAWAAAAAAAAAAAAAACAAQAAAABoZWltZGFsbC1hcnRpZmFjdC5qc29uUEsBAhQDFAAAAAAAVbdiXTvBsEkhAAAAIQAAAAoAAAAAAAAAAAAAAIABYwAAAGluZGV4Lmh0bWxQSwECFAMUAAAAAABVt2JdVoDwEwcAAAAHAAAACAAAAAAAAAAAAAAAgAGsAAAAbG9nby5wbmdQSwUGAAAAAAMAAwCyAAAA2QAAAAAA';
test('artifact workers re-validate and seal a relayed html-bundle byte-exact', async () => {
  const f = await mcpWorkerFixture(Date.now(), scope);
  const job = { ...f.job, tool: 'artifacts.create', operation: 'seal_resource' as const, payload: JSON.stringify({ name: 'Site', content_base64: BUNDLE_B64 }) };
  job.digest = await mcpJobDigest(job);
  await verifyMcpWorkerJob(job, f.identity, f.chain, job.resource, f.now);
  const output = JSON.parse(await transformMcpWorkerJob(job, f.keyring));
  const opened = await decryptVaultBytes(output.content_base64, f.keyring);
  assert.equal(opened.status, 'ok');
  if (opened.status === 'ok') assert.equal(Buffer.from(opened.bytes).toString('base64'), BUNDLE_B64);
  const notBundle = Buffer.from([1, 2, 3, 4]).toString('base64');
  for (const fields of [{ name: 'x', content_base64: notBundle }, { name: 'x', content_base64: 'eB==' }, { name: 'x', content_base64: `${BUNDLE_B64}\n` }, { name: 'x', content_base64: BUNDLE_B64, content: 'x' }]) {
    await assert.rejects(transformMcpWorkerJob({ ...job, payload: JSON.stringify(fields) }, f.keyring));
  }
  await assert.rejects(transformMcpWorkerJob({ ...job, tool: 'artifacts.update', payload: JSON.stringify({ content_base64: BUNDLE_B64 }) }, f.keyring));
  // The raised payload bound is artifact-create only.
  const big = { ...f.job, tool: 'memories.create', operation: 'seal_resource' as const, payload: 'x'.repeat(4 * 1024 * 1024 + 1) };
  big.digest = await mcpJobDigest(big);
  await assert.rejects(verifyMcpWorkerJob(big, f.identity, f.chain, big.resource, f.now));
});
