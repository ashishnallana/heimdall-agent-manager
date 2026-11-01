// Synthetic browser/bridge interoperability vector; no production key material.
import { writeFileSync } from 'node:fs';
import { mcpWorkerFixture } from './mcpWorkerFixture.ts';
import { mcpJobDigest, transformMcpWorkerJob, type McpWorkerJob } from '../../src/ui/utils/mcpWorker.ts';

const f = await mcpWorkerFixture(Date.parse('2026-10-31T07:00:00Z'), 'mcp:chains mcp:agents:read mcp:agents:write mcp:instances:read');
const token = JSON.parse(f.job.payload).chain.title;
const cases = [
  { tool: 'agents.create', operation: 'seal_agent', payload: { name: 'agent secret name', slug: 'agent secret slug', instructions: 'agent secret instructions' } },
  { tool: 'agents.get', operation: 'read', payload: { records_kind: 'agent', records: [{ owner_user_id: f.job.owner, agent_id: 'agt_a', name: token, slug: token, instructions: token, permission_mode: 'ask', revision: 'a'.repeat(64), token: 'never expose' }] } },
  { tool: 'instances.get', operation: 'read', payload: { records_kind: 'instance', records: [{ owner_user_id: f.job.owner, agent_instance_id: 'inst_a', agent_id: 'agt_a', bridge_id: 'brg_a', display_name: token, provider: 'codex', provider_profile: 'work', model: 'model_a', runtime_status: 'running', launch_epoch: 'never expose' }] } },
  { tool: 'bridges.list', operation: 'read', payload: { records_kind: 'bridge', records: [{ owner_user_id: f.job.owner, bridge_id: 'brg_a', label: token, status: 'online', eligible: true, bridge_token_hash: 'never expose' }] } },
  { tool: 'providers.list', operation: 'read', payload: { records_kind: 'provider', records: [{ owner_user_id: f.job.owner, bridge_id: 'brg_a', provider: 'codex', provider_profile: 'work', label: token, eligible: true, models: [{ model_id: 'model_a', label: token, state: 'active', rank: 1, eligible: true }], base_args_json: 'never expose' }], next_cursor: 'owner_bound_position' } },
] as const;
const entries = [];
for (const c of cases) {
  const job: McpWorkerJob = { ...f.job, tool: c.tool, operation: c.operation, payload: JSON.stringify(c.payload) };
  job.digest = await mcpJobDigest(job);
  entries.push({ job, result: await transformMcpWorkerJob(job, f.keyring) });
}
writeFileSync(new URL('../fixtures/mcp_catalog_worker_v2.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, now_ms: f.now, keyring_hex: f.keyringHex, device_id: f.identity.deviceId, bridge_device_id: f.bridge.deviceId, entries }, null, 2) + '\n');
