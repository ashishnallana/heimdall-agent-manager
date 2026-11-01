import { mcpConsentVersion, mcpConsentDomain } from './mcpCapabilities.ts';
import type { DeviceIdentity } from './deviceIdentity.ts';
import type { VerifiedChain } from './vaultDirectoryVerify.ts';
import type { VaultKeyring } from './vaultKeyring.ts';
import { kindPolicy, signP256, verifySignature } from './vaultStatements.ts';
import { sha256HexOfText } from './vaultRequestSigner.ts';
import { decryptVaultBytes, encryptVaultText, findVaultTokens, replaceVaultTokens, VAULT_TOKEN_RE } from './vaultContent.ts';

export interface McpWorkerJob {
  request_id: string; generation: string; owner: string; resource: string; grant: string; head: string;
  operation: 'read' | 'seal'; payload: string; digest: string; revision: number; deadline_ms: number;
  epoch: number; consent: string; signature: string; directory: Record<string, unknown>;
}
export interface McpWorkerReply {
  request_id: string; generation: string; digest: string; device_id: string; result: string; signature: string; deadline_ms: number;
}
export async function mcpJobDigest(j: McpWorkerJob): Promise<string> {
  return sha256HexOfText(JSON.stringify({ request_id: j.request_id, generation: j.generation, owner: j.owner, resource: j.resource, grant: j.grant, head: j.head, operation: j.operation, payload: j.payload, digest: '', revision: j.revision, deadline_ms: j.deadline_ms, epoch: j.epoch, consent: j.consent, signature: j.signature, directory: j.directory }));
}
/** No worker gets an OAuth token. Verify the original approver's signed grant
 * against this device's independently pinned, freshly verified directory. */
export async function verifyMcpWorkerJob(j: McpWorkerJob, identity: DeviceIdentity, chain: VerifiedChain, resource: string, now = Date.now()): Promise<void> {
  const id = (s: unknown) => typeof s === 'string' && /^[A-Za-z0-9_.:-]{1,256}$/.test(s);
  if (!id(j.request_id) || !id(j.generation) || j.owner !== identity.userId || j.owner !== chain.userId || j.resource !== resource || j.head !== chain.headHash || j.epoch !== chain.currentEpoch || !Number.isSafeInteger(j.deadline_ms) || j.deadline_ms <= now || j.deadline_ms > now + 5000 || typeof j.payload !== 'string' || j.payload.length > 4 * 1024 * 1024 || !['read', 'seal'].includes(j.operation) || j.digest !== await mcpJobDigest(j)) throw new Error('Stale or mismatched MCP request');
  const me = chain.trusted.get(identity.deviceId);
  if (!me || !kindPolicy(me.kind).receivesWrap) throw new Error('Approved device required');
  const c = JSON.parse(j.consent);
  const canonical = JSON.stringify({ v: c.v, owner: c.owner, vault_id: c.vault_id, client: c.client, resource: c.resource, scope: c.scope, grant: c.grant, family: c.family, revision: c.revision, mode: c.mode, recipient: c.recipient, recipient_public_key: c.recipient_public_key, approver: c.approver, directory_version: c.directory_version, directory_head: c.directory_head, epoch: c.epoch, issued_ms: c.issued_ms, wrap_sha256: c.wrap_sha256 });
  const signer = chain.trusted.get(c.approver);
  if (canonical !== j.consent || !mcpConsentVersion(c.scope) || c.v !== mcpConsentVersion(c.scope) || c.mode !== 'device' || c.owner !== chain.userId || c.vault_id !== chain.vaultId || c.client === '' || typeof c.client !== 'string' || typeof c.family !== 'string' || !c.family || c.resource !== resource || c.grant !== j.grant || c.revision !== j.revision || !Number.isSafeInteger(c.revision) || c.revision < 1 || !Number.isSafeInteger(c.directory_version) || c.directory_version < 1 || c.directory_version > chain.version || chain.logHashes[c.directory_version - 1] !== c.directory_head || !signer || signer.approval_seq > c.directory_version || !kindPolicy(signer.kind).canApprove || c.recipient !== '' || c.recipient_public_key !== '' || c.wrap_sha256 !== '') throw new Error('MCP consent does not verify');
  let epoch = 0;
  for (const [ep, proof] of chain.epochs) if (proof.seq <= c.directory_version && ep > epoch) epoch = ep;
  if (c.epoch !== epoch || !await verifySignature(signer.sign_alg, signer.sign_public_key, new TextEncoder().encode(mcpConsentDomain(c.v) + j.consent), j.signature)) throw new Error('MCP consent signature does not verify');
}
const chainFields = ['chain_id', 'title', 'description', 'status', 'kind', 'work_revision', 'task_count', 'completed_task_count', 'user_validation_count', 'created_at', 'updated_at'];
const taskFields = ['task_id', 'title', 'description', 'state', 'kind', 'attempt_no', 'requires_user_approval', 'reviews', 'updated_at'];
const commentFields = ['comment_id', 'body', 'created_at'];
async function readable(raw: Record<string, unknown>, fields: string[], textFields: string[], keyring: VaultKeyring, owner: string): Promise<Record<string, unknown>> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || (raw.owner_user_id !== undefined && raw.owner_user_id !== owner)) throw new Error('MCP record owner mismatch');
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
  if (job.operation === 'seal') {
    if (typeof input.title !== 'string' || typeof input.description !== 'string') throw new Error('Invalid chain fields');
    // Explicit keyring: never fall back to the UI's global active-key session.
    return JSON.stringify({ title: await encryptVaultText(input.title, keyring), description: await encryptVaultText(input.description, keyring) });
  }
  const out: Record<string, unknown> = {};
  if (input.chain) out.chain = await readable(input.chain, chainFields, ['title', 'description'], keyring, job.owner);
  if (input.chains) out.chains = await Promise.all(input.chains.map((r: Record<string, unknown>) => readable(r, chainFields, ['title', 'description'], keyring, job.owner)));
  if (input.tasks) out.tasks = await Promise.all(input.tasks.map((r: Record<string, unknown>) => readable(r, taskFields, ['title', 'description'], keyring, job.owner)));
  if (input.comments) out.comments = await Promise.all(input.comments.map((r: Record<string, unknown>) => readable(r, commentFields, ['body'], keyring, job.owner)));
  if (input.next_cursor) out.next_cursor = input.next_cursor;
  return JSON.stringify(out);
}
export async function signMcpWorkerReply(job: McpWorkerJob, identity: DeviceIdentity, result: string): Promise<McpWorkerReply> {
  const canonical = ['heimdall-mcp-worker-result/v1', job.owner, job.resource, job.grant, job.request_id, job.generation, String(job.revision), job.head, job.digest, identity.deviceId, String(job.deadline_ms), await sha256HexOfText(result)].join('\n');
  return { request_id: job.request_id, generation: job.generation, digest: job.digest, device_id: identity.deviceId, result, signature: await signP256(identity.signPrivateKey, new TextEncoder().encode(canonical)), deadline_ms: job.deadline_ms };
}
