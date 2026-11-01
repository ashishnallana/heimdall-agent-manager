import { mcpConsentVersion, mcpConsentDomain } from './mcpCapabilities.ts';
import type { DeviceIdentity } from './deviceIdentity.ts';
import type { VerifiedChain } from './vaultDirectoryVerify.ts';
import { kindPolicy, verifySignature } from './vaultStatements.ts';
import { sealKeyringWrap } from './vaultKeyringWrap.ts';

export interface ConnectorRecipient { grant: string; revision: number; consent: string; signature: string }
export interface ConnectorEpochDelivery { grant: string; revision: number; directory_version: number; directory_head: string; wrap_json: string }

/** The Hub's recipient list is untrusted. Recover the public recipient ONLY
 * from an approver-signed consent pinned into this verified directory chain. */
export async function verifiedConnectorRecipient(row: ConnectorRecipient, chain: VerifiedChain, resource: string): Promise<{ device_id: string; ecdh_public_key: string }> {
  const c = JSON.parse(row.consent);
  const canonical = JSON.stringify({ v: c.v, owner: c.owner, vault_id: c.vault_id, client: c.client, resource: c.resource, scope: c.scope, grant: c.grant, family: c.family, revision: c.revision, mode: c.mode, recipient: c.recipient, recipient_public_key: c.recipient_public_key, approver: c.approver, directory_version: c.directory_version, directory_head: c.directory_head, epoch: c.epoch, issued_ms: c.issued_ms, wrap_sha256: c.wrap_sha256 });
  const signer = chain.trusted.get(c.approver);
  if (!Number.isSafeInteger(c.revision) || c.revision < 1 || !Number.isSafeInteger(c.issued_ms) || c.issued_ms < 1 || !Number.isSafeInteger(c.epoch) || c.epoch < 1 || typeof c.client !== 'string' || !c.client || typeof c.family !== 'string' || !c.family || typeof c.grant !== 'string' || !c.grant || typeof c.wrap_sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(c.wrap_sha256)) throw new Error('Malformed connector consent');
  if (canonical !== row.consent || !mcpConsentVersion(c.scope) || c.v !== mcpConsentVersion(c.scope) || c.owner !== chain.userId || c.vault_id !== chain.vaultId || c.resource !== resource || c.mode !== 'hosted' || c.grant !== row.grant || c.revision !== row.revision || !Number.isSafeInteger(c.directory_version) || c.directory_version < 1 || c.directory_version > chain.version || chain.logHashes[c.directory_version - 1] !== c.directory_head || !signer || signer.approval_seq > c.directory_version || !kindPolicy(signer.kind).canApprove) throw new Error('Connector consent does not verify');
  let epochAtConsent = 0;
  for (const [epoch, proof] of chain.epochs) if (proof.seq <= c.directory_version && epoch > epochAtConsent) epochAtConsent = epoch;
  if (epochAtConsent !== c.epoch || typeof c.recipient !== 'string' || !/^mcp_[A-Za-z0-9_.:-]+$/.test(c.recipient) || typeof c.recipient_public_key !== 'string' || !/^04[0-9a-f]{128}$/.test(c.recipient_public_key)) throw new Error('Connector recipient does not verify');
  if (!(await verifySignature(signer.sign_alg, signer.sign_public_key, new TextEncoder().encode(mcpConsentDomain(c.v) + row.consent), row.signature))) throw new Error('Connector signature does not verify');
  return { device_id: c.recipient, ecdh_public_key: c.recipient_public_key };
}

export async function buildConnectorEpochWraps(identity: DeviceIdentity, chain: VerifiedChain, recipients: ConnectorRecipient[], bytes: Uint8Array, resource: string): Promise<ConnectorEpochDelivery[]> {
  const me = chain.trusted.get(identity.deviceId);
  if (identity.userId !== chain.userId || !me || !kindPolicy(me.kind).canApprove) throw new Error('Approved device required');
  const out: ConnectorEpochDelivery[] = [];
  const seen = new Set<string>();
  for (const row of recipients) {
    if (seen.has(row.grant)) throw new Error('Duplicate connector grant');
    seen.add(row.grant);
    const recipient = await verifiedConnectorRecipient(row, chain, resource);
    const wrap = await sealKeyringWrap(identity, chain.userId, recipient, chain.version, bytes);
    if (wrap.json.current_epoch !== chain.currentEpoch) throw new Error('Vault changed before connector delivery');
    out.push({ grant: row.grant, revision: row.revision, directory_version: chain.version, directory_head: chain.headHash, wrap_json: JSON.stringify(wrap.json) });
  }
  return out;
}
