// Synthetic browser/native interoperability vector. No production material.
import { writeFileSync } from 'node:fs';
import { mcpWorkerFixture } from './mcpWorkerFixture.ts';
import { mcpJobDigest, transformMcpWorkerJob, type McpWorkerJob } from '../../src/ui/utils/mcpWorker.ts';

const f = await mcpWorkerFixture(Date.parse('2026-10-31T07:00:00Z'), 'mcp:chains mcp:memories:read mcp:memories:write mcp:projects:read mcp:projects:write mcp:issues:read mcp:issues:write mcp:artifacts:read mcp:artifacts:write');
const token = JSON.parse(f.job.payload).chain.title;
const cases = [
  { tool: 'artifacts.create', operation: 'seal_resource', payload: { name: 'artifact secret', description: '', content: '# Private result\nDone.' } },
  { tool: 'artifacts.update', operation: 'seal_resource', payload: { description: '' } },
  { tool: 'artifacts.get', operation: 'read', payload: { records_kind: 'artifact', records: [{ owner_user_id: f.job.owner, artifact_id: 'art_a', name: token, description: token, content: token, content_type: 'text/markdown', task_id: 'task_a', chain_id: 'chain_a', link: 'artifact://art_a', blob_ref: '/never expose' }] } },
] as const;
const entries = [];
for (const c of cases) {
  const job: McpWorkerJob = { ...f.job, tool: c.tool, operation: c.operation, payload: JSON.stringify(c.payload) };
  job.digest = await mcpJobDigest(job);
  entries.push({ job, result: await transformMcpWorkerJob(job, f.keyring) });
}
writeFileSync(new URL('../fixtures/mcp_artifacts_worker_v2.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, now_ms: f.now, keyring_hex: f.keyringHex, device_id: f.identity.deviceId, bridge_device_id: f.bridge.deviceId, entries }, null, 2) + '\n');
