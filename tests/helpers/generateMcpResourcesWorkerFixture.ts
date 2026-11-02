// Synthetic browser/native interoperability vector. No production material.
import { writeFileSync } from 'node:fs';
import { mcpWorkerFixture } from './mcpWorkerFixture.ts';
import { mcpJobDigest, transformMcpWorkerJob, type McpWorkerJob } from '../../src/ui/utils/mcpWorker.ts';

const f = await mcpWorkerFixture(Date.parse('2026-10-31T07:00:00Z'), 'mcp:chains mcp:memories:read mcp:memories:write mcp:projects:read mcp:projects:write mcp:issues:read mcp:issues:write');
const token = JSON.parse(f.job.payload).chain.title;
const cases = [
  { tool: 'memories.create', operation: 'seal_resource', payload: { title: 'memory secret', body: 'memory secret body', evidence: '', description: '' } },
  { tool: 'projects.create', operation: 'seal_resource', payload: { name: 'project secret', description: '' } },
  { tool: 'issues.create', operation: 'seal_resource', payload: { title: 'issue secret', description: '' } },
  { tool: 'issues.comment', operation: 'seal_resource', payload: { body: 'comment secret' } },
  { tool: 'memories.get', operation: 'read', payload: { records_kind: 'memory', records: [{ owner_user_id: f.job.owner, memory_id: 'mem_a', read_only: false, title: token, body: token, evidence: token, status: 'pending', agent_ids: [] }] } },
  { tool: 'memories.get', operation: 'read', payload: { records_kind: 'memory', records: [{ owner_user_id: 'system', memory_id: 'mem_system', read_only: true, title: 'System title', body: 'Public builtin', status: 'active' }] } },
  { tool: 'projects.get', operation: 'read', payload: { records_kind: 'project', records: [{ owner_user_id: f.job.owner, project_id: 'proj_a', name: token, slug: token, description: token, default_path: '/native/path', bridge_paths: [{ bridge_id: 'brg_a', path: '/owned/path', is_validated: false, last_validated_at: '', updated_at: '' }] }] } },
  { tool: 'issues.get', operation: 'read', payload: { records_kind: 'issue', records: [{ owner_user_id: f.job.owner, issue_id: 'iss_a', title: token, description: token, comments: [{ owner_user_id: f.job.owner, issue_id: 'iss_a', comment_id: 'icmt_a', author_id: f.job.owner, author_name: token, body: token, secret: 'never expose' }], comments_next_cursor: 'bound_comments' }] } },
  { tool: 'issues.list', operation: 'read', payload: { records_kind: 'issue', records: [{ owner_user_id: f.job.owner, issue_id: 'iss_preview', description: 'é'.repeat(400), description_limit: 512 }] } },
] as const;
const entries = [];
for (const c of cases) {
  const job: McpWorkerJob = { ...f.job, tool: c.tool, operation: c.operation, payload: JSON.stringify(c.payload) };
  job.digest = await mcpJobDigest(job);
  entries.push({ job, result: await transformMcpWorkerJob(job, f.keyring) });
}
writeFileSync(new URL('../fixtures/mcp_resources_worker_v2.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, now_ms: f.now, keyring_hex: f.keyringHex, device_id: f.identity.deviceId, bridge_device_id: f.bridge.deviceId, entries }, null, 2) + '\n');
