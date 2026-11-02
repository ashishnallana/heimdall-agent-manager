import { mcpConsentVersion, mcpConsentDomain, mcpScopeSubset } from './mcpCapabilities.ts';
import type { DeviceIdentity } from './deviceIdentity.ts';
import type { VerifiedChain } from './vaultDirectoryVerify.ts';
import { sealKeyringWrap, exportPublicHex } from './vaultKeyringWrap.ts';
import { kindPolicy, signP256, toLowerHex } from './vaultStatements.ts';

export interface McpConsentRequest {
  owner: string;
  client: string;
  redirect: string;
  resource: string;
  scope: string;
  grant: string;
  family: string;
  revision: number;
  expires_ms: number;
}

export interface McpConsentBody {
  request: string;
  consent: string;
  signature: string;
  wrap_json: string;
  private_capability: string;
}

/** This keypair is new for this connection. Existing device private keys are
 * never exported. The caller sends the result once and retains no local copy. */
export async function buildMcpConsent(
  ticket: string,
  request: McpConsentRequest,
  mode: 'device' | 'hosted',
  identity: DeviceIdentity,
  chain: VerifiedChain,
  withBytes: <T>(run: (bytes: Uint8Array) => Promise<T>) => Promise<T>,
  now = Date.now(),
  selectedScope = request.scope,
): Promise<McpConsentBody> {
  const approver = chain.trusted.get(identity.deviceId);
  if (identity.userId !== chain.userId || request.owner !== chain.userId || !approver || !kindPolicy(approver.kind).canApprove) {
    throw new Error('An approved device for this account is required');
  }
  if (request.expires_ms <= now || !mcpScopeSubset(selectedScope, request.scope) || request.revision !== 1) throw new Error('Connector request expired or unsupported');
  let recipient = '';
  let recipientPublic = '';
  let privateCapability = '';
  let wrapJson = '';
  let wrapHash = '';
  let scalar: Uint8Array | undefined;
  try {
    if (mode === 'hosted') {
      recipient = `mcp_${crypto.randomUUID()}`;
      const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
      recipientPublic = await exportPublicHex(pair.publicKey);
      const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
      if (!jwk.d) throw new Error('Cannot export delegated recipient');
      const padded = jwk.d.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - jwk.d.length % 4) % 4);
      scalar = Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
      if (scalar.length !== 32) throw new Error('Invalid delegated recipient');
      privateCapability = toLowerHex(scalar);
      const wrap = await withBytes((bytes) => sealKeyringWrap(identity, chain.userId, { device_id: recipient, ecdh_public_key: recipientPublic }, chain.version, bytes));
      if (wrap.json.current_epoch !== chain.currentEpoch) throw new Error('Vault changed; review consent again');
      wrapJson = JSON.stringify(wrap.json);
      wrapHash = wrap.sha;
    }
    // Must match the fixed-order Odin Consent struct. Every field is present.
    const consent = JSON.stringify({
      v: mcpConsentVersion(selectedScope), owner: chain.userId, vault_id: chain.vaultId, client: request.client,
      resource: request.resource, scope: selectedScope, grant: request.grant, family: request.family,
      revision: request.revision, mode, recipient, recipient_public_key: recipientPublic, approver: identity.deviceId,
      directory_version: chain.version, directory_head: chain.headHash, epoch: chain.currentEpoch, issued_ms: now, wrap_sha256: wrapHash,
    });
    return { request: ticket, consent, signature: await signP256(identity.signPrivateKey, new TextEncoder().encode(mcpConsentDomain(mcpConsentVersion(selectedScope)) + consent)), wrap_json: wrapJson, private_capability: privateCapability };
  } finally {
    scalar?.fill(0);
    // JS strings / CryptoKeys cannot be reliably zeroized. No browser storage,
    // Redux, logging, retry cache or analytics receives this capability.
    privateCapability = '';
  }
}
