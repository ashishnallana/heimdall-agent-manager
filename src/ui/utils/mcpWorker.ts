import { mcpJobPayloadMax, openArtifactBundle, resourceSpecs, resourceToolKinds, sealResourceFields } from './mcpResourceFields.ts';
import { mcpConsentVersion, mcpConsentDomain, validMcpScopes } from './mcpCapabilities.ts';
import type { DeviceIdentity } from './deviceIdentity.ts';
import type { VerifiedChain } from './vaultDirectoryVerify.ts';
import type { VaultKeyring } from './vaultKeyring.ts';
import { kindPolicy, signP256, verifySignature } from './vaultStatements.ts';
import { sha256HexOfText } from './vaultRequestSigner.ts';
import { decryptVaultBytes, encryptVaultText, findVaultTokens, replaceVaultTokens, VAULT_TOKEN_RE } from './vaultContent.ts';

// Mirrors vault.control_job_deadline_max_ms: html-bundle capable artifact jobs
// (artifacts.create seal_resource, artifacts.get read) may run up to 20 s.
export const MCP_JOB_DEADLINE_MAX_MS = 5000;
export const MCP_JOB_ARTIFACT_DEADLINE_MAX_MS = 20000;
export function mcpJobDeadlineMaxMs(operation: string, tool?: string): number {
  return mcpJobPayloadMax(operation, tool) > mcpJobPayloadMax('read') ? MCP_JOB_ARTIFACT_DEADLINE_MAX_MS : MCP_JOB_DEADLINE_MAX_MS;
}
export interface McpWorkerJob {
  request_id: string; generation: string; owner: string; resource: string; grant: string; head: string;
  operation: 'read' | 'seal' | 'seal_comment' | 'seal_message' | 'seal_task' | 'seal_agent' | 'seal_resource'; payload: string; digest: string; revision: number; deadline_ms: number;
  tool?: string;
  epoch: number; consent: string; signature: string; directory: Record<string, unknown>;
}
export interface McpWorkerReply {
  request_id: string; generation: string; digest: string; device_id: string; result: string; signature: string; deadline_ms: number;
}
export async function mcpJobDigest(j: McpWorkerJob): Promise<string> {
  return sha256HexOfText(JSON.stringify({ request_id: j.request_id, generation: j.generation, owner: j.owner, resource: j.resource, grant: j.grant, head: j.head, operation: j.operation, payload: j.payload, digest: '', revision: j.revision, deadline_ms: j.deadline_ms, epoch: j.epoch, consent: j.consent, signature: j.signature, directory: j.directory, ...(j.tool ? { tool: j.tool } : {}) }));
}
export function mcpJobScopeAllowed(scope: string, tool: string | undefined, operation: string): boolean {
  if (!validMcpScopes(scope)) return false;
  for (const [resource, tools] of Object.entries({ artifacts: ['create', 'update'], memories: ['create', 'update'], projects: ['create', 'update'], issues: ['create', 'update', 'comment'] })) {
    if (tools.some(action => tool === `${resource}.${action}`)) return operation === 'seal_resource' && scope.split(' ').includes(`mcp:${resource}:write`);
    if ([`${resource}.list`, `${resource}.get`].includes(tool || '')) return operation === 'read' && scope.split(' ').includes(`mcp:${resource}:read`);
  }
  if (!tool) return operation === 'read' || operation === 'seal';
  if (['agents.list', 'agents.get'].includes(tool)) return operation === 'read' && scope.split(' ').includes('mcp:agents:read');
  if (['bridges.list', 'providers.list', 'instances.list', 'instances.get'].includes(tool)) return operation === 'read' && scope.split(' ').includes('mcp:instances:read');
  if (['agents.create', 'agents.update', 'agents.archive'].includes(tool)) return operation === 'seal_agent' && scope.split(' ').includes('mcp:agents:write');
  if (['chains.list', 'chains.get', 'events.wait'].includes(tool)) return operation === 'read';
  if (tool === 'chains.create') return operation === 'seal';
  if (['tasks.list', 'tasks.get'].includes(tool)) return operation === 'read' && scope.split(' ').includes('mcp:tasks:read');
  if (['tasks.create', 'tasks.update', 'tasks.control'].includes(tool)) return operation === 'seal_task' && scope.split(' ').includes('mcp:tasks:write');
  if (tool === 'chains.message') return operation === 'seal_message' && scope.split(' ').includes('mcp:chains:message');
  return tool === 'tasks.comment' && operation === 'seal_comment' && scope.split(' ').includes('mcp:tasks:write');
}
/** No worker gets an OAuth token. Verify the original approver's signed grant
 * against this device's independently pinned, freshly verified directory. */
export async function verifyMcpWorkerJob(j: McpWorkerJob, identity: DeviceIdentity, chain: VerifiedChain, resource: string, now = Date.now()): Promise<void> {
  const id = (s: unknown) => typeof s === 'string' && /^[A-Za-z0-9_.:-]{1,256}$/.test(s);
  if (!id(j.request_id) || !id(j.generation) || j.owner !== identity.userId || j.owner !== chain.userId || j.resource !== resource || j.head !== chain.headHash || j.epoch !== chain.currentEpoch || !Number.isSafeInteger(j.deadline_ms) || j.deadline_ms <= now || j.deadline_ms > now + mcpJobDeadlineMaxMs(j.operation, j.tool) || typeof j.payload !== 'string' || j.payload.length > mcpJobPayloadMax(j.operation, j.tool) || !['read', 'seal', 'seal_comment', 'seal_message', 'seal_task', 'seal_agent', 'seal_resource'].includes(j.operation) || j.digest !== await mcpJobDigest(j)) throw new Error('Stale or mismatched MCP request');
  const me = chain.trusted.get(identity.deviceId);
  if (!me || !kindPolicy(me.kind).receivesWrap) throw new Error('Approved device required');
  const c = JSON.parse(j.consent);
  if (!mcpJobScopeAllowed(c.scope, j.tool, j.operation)) throw new Error('MCP operation exceeds consent');
  const canonical = JSON.stringify({ v: c.v, owner: c.owner, vault_id: c.vault_id, client: c.client, resource: c.resource, scope: c.scope, grant: c.grant, family: c.family, revision: c.revision, mode: c.mode, recipient: c.recipient, recipient_public_key: c.recipient_public_key, approver: c.approver, directory_version: c.directory_version, directory_head: c.directory_head, epoch: c.epoch, issued_ms: c.issued_ms, wrap_sha256: c.wrap_sha256 });
  const signer = chain.trusted.get(c.approver);
  if (canonical !== j.consent || !mcpConsentVersion(c.scope) || c.v !== mcpConsentVersion(c.scope) || c.mode !== 'device' || c.owner !== chain.userId || c.vault_id !== chain.vaultId || c.client === '' || typeof c.client !== 'string' || typeof c.family !== 'string' || !c.family || c.resource !== resource || c.grant !== j.grant || c.revision !== j.revision || !Number.isSafeInteger(c.revision) || c.revision < 1 || !Number.isSafeInteger(c.directory_version) || c.directory_version < 1 || c.directory_version > chain.version || chain.logHashes[c.directory_version - 1] !== c.directory_head || !signer || signer.approval_seq > c.directory_version || !kindPolicy(signer.kind).canApprove || c.recipient !== '' || c.recipient_public_key !== '' || c.wrap_sha256 !== '') throw new Error('MCP consent does not verify');
  let epoch = 0;
  for (const [ep, proof] of chain.epochs) if (proof.seq <= c.directory_version && ep > epoch) epoch = ep;
  if (c.epoch !== epoch || !await verifySignature(signer.sign_alg, signer.sign_public_key, new TextEncoder().encode(mcpConsentDomain(c.v) + j.consent), j.signature)) throw new Error('MCP consent signature does not verify');
}
const chainFields = ['chain_id', 'title', 'description', 'status', 'kind', 'work_revision', 'task_count', 'completed_task_count', 'user_validation_count', 'created_at', 'updated_at', 'configuration_revision', 'fleet'];
const taskFields = ['task_id', 'title', 'description', 'state', 'kind', 'attempt_no', 'requires_user_approval', 'reviews', 'updated_at'];
const taskDetailFields = [...taskFields, 'chain_id', 'goal', 'acceptance', 'inputs', 'review_roles', 'reviewers', 'assignee_agent_id', 'bridge_id', 'depends_on', 'publish_state', 'priority', 'revision', 'blocked_kind', 'blocked_ref', 'blocked_reason', 'blocked_since', 'blocked_since_ms', 'hold_reason', 'hold_since_ms', 'hold_by', 'checkpoint_requested', 'allowed_actions', 'latest_attempt_no', 'latest_attempt_holder_instance_id', 'latest_attempt_outcome', 'latest_attempt_started_at', 'latest_attempt_ended_at', 'latest_attempt_summary', 'latest_attempt_summary_error', 'requirements_revision', 'requirements_submitted_revision', 'requirements_submitted_head', 'requirements_checkpoint_required', 'requirements_acknowledgements', 'requirements_history', 'requirements_history_truncated'];
const commentFields = ['comment_id', 'chain_id', 'task_id', 'body', 'created_at', 'author_kind', 'author_user_id', 'author_agent_instance_id', 'delegated_client_id', 'delegated_grant_id', 'body_error', 'body_bytes'];
const catalogFields: Record<string, { fields: string[]; text: string[] }> = {
  ...resourceSpecs,
  agent: { fields: ['agent_id', 'name', 'slug', 'template_id', 'instructions', 'instructions_error', 'state', 'permission_mode', 'created_at', 'updated_at', 'revision', 'supports'], text: ['name', 'slug', 'instructions'] },
  instance: { fields: ['agent_instance_id', 'agent_id', 'bridge_id', 'display_name', 'provider', 'provider_profile', 'model', 'runtime_status', 'startup_status', 'activity_status', 'project_id', 'chain_id', 'current_task_id', 'current_task_role', 'revision', 'configuration_revision', 'permission_mode', 'created_at', 'updated_at', 'last_seen_at'], text: ['display_name'] },
  bridge: { fields: ['bridge_id', 'label', 'status', 'machine_os', 'machine_arch', 'version', 'plan_disabled', 'enrollment_pending', 'eligible', 'created_at', 'last_seen_at'], text: ['label'] },
  provider: { fields: ['bridge_id', 'provider', 'provider_profile', 'display_name', 'label', 'enabled', 'profile_state', 'detection_state', 'models_state', 'models_source', 'models_checked_at', 'eligible', 'models', 'models_next_cursor'], text: ['display_name', 'label'] },
};
const catalogToolKinds: Record<string, string> = { ...resourceToolKinds, 'agents.list': 'agent', 'agents.get': 'agent', 'instances.list': 'instance', 'instances.get': 'instance', 'bridges.list': 'bridge', 'providers.list': 'provider' };
async function readable(raw: Record<string, unknown>, fields: string[], textFields: string[], keyring: VaultKeyring, owner: string, allowSystem = false): Promise<Record<string, unknown>> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || (raw.owner_user_id !== undefined && raw.owner_user_id !== owner && !(allowSystem && raw.owner_user_id === 'system' && raw.read_only === true))) throw new Error('MCP record owner mismatch');
  const out: Record<string, unknown> = {};
  for (const key of fields) if (raw[key] !== undefined) out[key] = raw[key];
  for (const key of textFields) {
    const value = out[key];
    if (value === undefined || value === null) continue;
    if (typeof value !== 'string') throw new Error('Invalid MCP text');
    const open = async (token: string) => {
      const opened = await decryptVaultBytes(token, keyring);
      if (opened.status !== 'ok') throw new Error('MCP key unavailable');
      try { return new TextDecoder('utf-8', { fatal: true }).decode(opened.bytes); }
      finally { opened.bytes.fill(0); }
    };
    if (value.startsWith('vault:v2:')) out[key] = await open(value);
    else if (value.includes('vault:v2:')) {
      if (replaceVaultTokens(value, '').includes('vault:v2:')) throw new Error('Malformed MCP envelope');
      const tokens = new Map<string, string>();
      for (const token of findVaultTokens(value)) if (!tokens.has(token)) tokens.set(token, await open(token));
      out[key] = value.replace(new RegExp(VAULT_TOKEN_RE.source, 'g'), (token) => tokens.get(token)!);
    }
  }
  if (JSON.stringify(out).includes('vault:v2:')) throw new Error('MCP decryption failed');
  return out;
}
export async function transformMcpWorkerJob(job: McpWorkerJob, keyring: VaultKeyring): Promise<string> {
  const input = JSON.parse(job.payload);
  if (job.operation === 'seal_resource') return sealResourceFields(job.tool || '', input, keyring);
  if (job.operation === 'seal_agent') {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid agent fields');
    const sealed: Record<string, string> = {};
    for (const [key, value] of Object.entries(input)) {
      const limit = ({ name: 500, slug: 500, instructions: 65536 } as Record<string, number>)[key];
      if (!limit || typeof value !== 'string' || new TextEncoder().encode(value).length > limit) throw new Error('Invalid agent text');
      if (key !== 'instructions' && !value.trim()) throw new Error('Invalid agent name');
      sealed[key] = await encryptVaultText(value, keyring);
    }
    return JSON.stringify(sealed);
  }
  if (job.operation === 'seal_task') {
    if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).length < 1 || Object.keys(input).length > 5) throw new Error('Invalid task fields');
    const sealed: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(input)) {
      if (key === 'acceptance') {
        if (!Array.isArray(value) || value.length < 1 || value.length > 20 || value.some(item => typeof item !== 'string' || new TextEncoder().encode(item).length < 1 || new TextEncoder().encode(item).length > 200)) throw new Error('Invalid task acceptance');
        sealed[key] = await Promise.all(value.map(item => encryptVaultText(item, keyring)));
      } else {
        const limit = ({ title: 500, description: 20000, goal: 2000, reason: 20000 } as Record<string, number>)[key];
        if (!limit || typeof value !== 'string' || new TextEncoder().encode(value).length > limit) throw new Error('Invalid task text');
        sealed[key] = await encryptVaultText(value, keyring);
      }
    }
    return JSON.stringify(sealed);
  }
  if (job.operation === 'seal_comment' || job.operation === 'seal_message') {
    if (job.operation === 'seal_message' && (Object.keys(input).length !== 1 || !Object.hasOwn(input, 'body'))) throw new Error('Invalid message fields');
    if (typeof input.body !== 'string' || input.body.length < 1 || (job.operation === 'seal_message' && !input.body.trim()) || new TextEncoder().encode(input.body).length > 20000) throw new Error('Invalid message or comment body');
    return JSON.stringify({ body: await encryptVaultText(input.body, keyring) });
  }
  if (job.operation === 'seal') {
    if (typeof input.title !== 'string' || typeof input.description !== 'string') throw new Error('Invalid chain fields');
    // Explicit keyring: never fall back to the UI's global active-key session.
    return JSON.stringify({ title: await encryptVaultText(input.title, keyring), description: await encryptVaultText(input.description, keyring) });
  }
  const out: Record<string, unknown> = {};
  const expectedKind = catalogToolKinds[job.tool || ''] || '';
  if ((input.records_kind || '') !== expectedKind || (!expectedKind && input.records?.length)) throw new Error('MCP catalog/tool mismatch');
  if (expectedKind && (input.chain || input.chains?.length || input.tasks?.length || input.comments?.length || input.comments_next_cursor)) throw new Error('Unexpected catalog payload');
  if (expectedKind) {
    out.records_kind = expectedKind;
    if (input.records !== undefined && !Array.isArray(input.records)) throw new Error('Invalid catalog records');
    const spec = catalogFields[expectedKind];
    out.records = await Promise.all((input.records || []).map(async (record: Record<string, unknown>) => {
      const source = expectedKind === 'provider' ? { ...record, models: undefined } : expectedKind === 'issue' ? { ...record, comments: undefined } : expectedKind === 'artifact' ? { ...record, content_base64: undefined } : record;
      const row = await readable(source, spec.fields, spec.text, keyring, job.owner, expectedKind === 'memory');
      if (expectedKind === 'artifact' && record.content_base64 !== undefined) {
        if (record.content !== undefined || job.tool !== 'artifacts.get') throw new Error('Invalid artifact bundle');
        row.content_base64 = await openArtifactBundle(record.kind, record.content_base64, keyring);
      }
      if (expectedKind === 'artifact' && row.content !== undefined) {
        const mime = String(row.mime || row.content_type || '').split(';', 1)[0].trim().toLowerCase();
        if (!['text/plain', 'text/markdown', 'application/json'].includes(mime) || typeof row.content !== 'string' || new TextEncoder().encode(row.content).length > 65536 || row.content.includes('\0')) throw new Error('Invalid or oversized artifact text');
      }
      if (expectedKind === 'issue' && record.description_limit !== undefined) {
        if (record.description_limit !== 512) throw new Error('Invalid issue preview limit');
        if (typeof row.description === 'string') {
          const bytes = new TextEncoder().encode(row.description);
          if (bytes.length > 512) { let end = 512; while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--; row.description = new TextDecoder().decode(bytes.subarray(0, end)); }
          bytes.fill(0);
        }
      }
      if (expectedKind === 'memory') {
        for (const field of ['agent_ids', 'project_ids', 'bridge_ids', 'template_ids']) {
          const ids = record[field];
          if (ids !== undefined && (!Array.isArray(ids) || ids.length > 100 || ids.some(id => typeof id !== 'string' || id.length > 256))) throw new Error('Invalid memory targets');
        }
      }
      if (expectedKind === 'issue' && record.comments !== undefined) {
        if (!Array.isArray(record.comments) || record.comments.length > 100) throw new Error('Invalid issue comments');
        const commentSpec = resourceSpecs.issue_comment;
        row.comments = await Promise.all(record.comments.map(comment => readable(comment, commentSpec.fields, commentSpec.text, keyring, job.owner)));
      }
      if (expectedKind === 'project' && record.bridge_paths !== undefined) {
        if (!Array.isArray(record.bridge_paths) || record.bridge_paths.length > 100) throw new Error('Invalid bridge paths');
        for (const path of record.bridge_paths) {
          if (!path || typeof path !== 'object' || Object.keys(path).length !== 5 || typeof path.is_validated !== 'boolean' || ['bridge_id', 'path', 'last_validated_at', 'updated_at'].some(key => typeof path[key] !== 'string' || path[key].length > 4096)) throw new Error('Invalid bridge path');
        }
      }
      if (expectedKind === 'provider' && record.models !== undefined) {
        if (!Array.isArray(record.models) || record.models.length > 100) throw new Error('Invalid provider models');
        row.models = await Promise.all(record.models.map(model => {
          if (!model || typeof model !== 'object' || Object.keys(model).length !== 5 || typeof model.model_id !== 'string' || typeof model.label !== 'string' || typeof model.state !== 'string' || !Number.isSafeInteger(model.rank) || typeof model.eligible !== 'boolean') throw new Error('Invalid provider model');
          return readable(model, ['model_id', 'label', 'state', 'rank', 'eligible'], ['label'], keyring, job.owner);
        }));
      }
      return row;
    }));
  }
  if (input.chain) out.chain = await readable(input.chain, chainFields, ['title', 'description'], keyring, job.owner);
  if (input.chains) out.chains = await Promise.all(input.chains.map((r: Record<string, unknown>) => readable(r, chainFields, ['title', 'description'], keyring, job.owner)));
  if (input.tasks) out.tasks = await Promise.all(input.tasks.map(async (r: Record<string, unknown>) => {
    const details = job.tool === 'tasks.get' || job.tool === 'tasks.list';
    // Acceptance items need the same strict text transform as individual fields.
    const { acceptance, inputs, ...rest } = r;
    const result = await readable(details ? rest : r, details ? taskDetailFields : taskFields, details ? ['title', 'description', 'goal', 'blocked_reason', 'hold_reason', 'latest_attempt_summary', 'requirements_history'] : ['title', 'description'], keyring, job.owner);
    for (const [key, value] of [['acceptance', acceptance], ['inputs', inputs]] as const) if (details && value !== undefined) {
      if (!Array.isArray(value)) throw new Error('Invalid task text list');
      result[key] = await Promise.all(value.map(async body => {
        if (typeof body !== 'string') throw new Error('Invalid task acceptance');
        return (await readable({ body }, commentFields, ['body'], keyring, job.owner)).body;
      }));
    }
    return result;
  }));
  if (input.comments) out.comments = await Promise.all(input.comments.map((r: Record<string, unknown>) => readable(r, commentFields, ['body'], keyring, job.owner)));
  if (input.next_cursor) out.next_cursor = input.next_cursor;
  if (input.comments_next_cursor) out.comments_next_cursor = input.comments_next_cursor;
  return JSON.stringify(out);
}
export async function signMcpWorkerReply(job: McpWorkerJob, identity: DeviceIdentity, result: string): Promise<McpWorkerReply> {
  const canonical = ['heimdall-mcp-worker-result/v1', job.owner, job.resource, job.grant, job.request_id, job.generation, String(job.revision), job.head, job.digest, identity.deviceId, String(job.deadline_ms), await sha256HexOfText(result)].join('\n');
  return { request_id: job.request_id, generation: job.generation, digest: job.digest, device_id: identity.deviceId, result, signature: await signP256(identity.signPrivateKey, new TextEncoder().encode(canonical)), deadline_ms: job.deadline_ms };
}
