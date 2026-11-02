// Included by the standard ui_vault_*.ts test suite.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, newBrowser } from './helpers/vaultDirectoryFixture.ts';
import { buildMcpConsent, type McpConsentRequest } from '../src/ui/utils/mcpConsent.ts';
import { lowerHexToBytes as fromLowerHex, openKeyringWrap, verifySignature } from '../src/ui/utils/vaultStatements.ts';

const now = 1793443200000;
const request: McpConsentRequest = { owner: USER, client: 'client-fixture', redirect: 'https://client.example/callback', resource: 'https://hub.example/api/v1/mcp', scope: 'mcp:chains', grant: 'grant-fixture', family: 'family-fixture', revision: 1, expires_ms: now + 300000 };
async function setup() {
  const hub = new FakeHub();
  const identity = await newBrowser();
  await hub.genesis(identity);
  return { hub, identity, chain: await hub.chain() };
}

test('device mode signs the full binding without creating a recipient or reading keyring bytes', async () => {
  const { identity, chain } = await setup();
  const body = await buildMcpConsent('ticket', request, 'device', identity, chain, async () => { throw new Error('must not read keyring'); }, now);
  const consent = JSON.parse(body.consent);
  assert.equal(consent.owner, USER);
  assert.equal(consent.client, request.client);
  assert.equal(consent.resource, request.resource);
  assert.equal(consent.grant, request.grant);
  assert.equal(consent.family, request.family);
  assert.equal(consent.directory_head, chain.headHash);
  assert.equal(consent.vault_id, chain.vaultId);
  assert.equal(consent.recipient, '');
  assert.equal(body.private_capability, '');
  assert.equal(body.wrap_json, '');
  assert.ok(await verifySignature(identity.signAlg, identity.signPub, new TextEncoder().encode(`heimdall-mcp-consent/v1\n${body.consent}`), body.signature));
});

test('hosted consent delegates a fresh ECDH recipient and its signed keyring wrap', async () => {
  const { hub, identity, chain } = await setup();
  const body = await buildMcpConsent('ticket', request, 'hosted', identity, chain, async (run) => {
    const bytes = await hub.keyringBytes(identity);
    try { return await run(bytes); } finally { bytes.fill(0); }
  }, now);
  const consent = JSON.parse(body.consent);
  assert.equal(body.private_capability.length, 64);
  assert.notEqual(consent.recipient_public_key, identity.ecdhPub);
  assert.match(consent.recipient, /^mcp_/);
  assert.ok(await verifySignature(identity.signAlg, identity.signPub, new TextEncoder().encode(`heimdall-mcp-consent/v1\n${body.consent}`), body.signature));
  const raw = fromLowerHex(consent.recipient_public_key);
  const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64url');
  const privateKey = await crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: b64(raw.slice(1, 33)), y: b64(raw.slice(33)), d: b64(fromLowerHex(body.private_capability)) }, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  const parsed = await openKeyringWrap(JSON.parse(body.wrap_json), USER, privateKey);
  try { assert.equal(parsed.vaultId, chain.vaultId); assert.equal(parsed.currentEpoch, chain.currentEpoch); }
  finally { for (const entry of parsed.entries) entry.key.fill(0); }
});

test('consent refuses another account, an unapproved signer and an expired request', async () => {
  const { identity, chain } = await setup();
  const never = async () => { throw new Error('must not access keyring'); };
  await assert.rejects(buildMcpConsent('ticket', { ...request, owner: 'bob' }, 'device', identity, chain, never, now), /approved device/);
  await assert.rejects(buildMcpConsent('ticket', request, 'device', await newBrowser(), chain, never, now), /approved device/);
  await assert.rejects(buildMcpConsent('ticket', { ...request, expires_ms: now }, 'device', identity, chain, never, now), /expired/);
});

test('v2 consent signs only explicitly selected requested rights under a distinct domain', async () => {
  const { identity, chain } = await setup();
  const expanded = { ...request, scope: 'mcp:chains mcp:tasks:read mcp:tasks:write mcp:artifacts:read' };
  const never = async () => { throw new Error('must not access keyring'); };
  const selected = 'mcp:chains mcp:tasks:read';
  const body = await buildMcpConsent('ticket', expanded, 'device', identity, chain, never, now, selected);
  assert.equal(JSON.parse(body.consent).v, 2);
  assert.equal(JSON.parse(body.consent).scope, selected);
  assert.ok(await verifySignature(identity.signAlg, identity.signPub, new TextEncoder().encode(`heimdall-mcp-consent/v2\n${body.consent}`), body.signature));
  assert.equal(await verifySignature(identity.signAlg, identity.signPub, new TextEncoder().encode(`heimdall-mcp-consent/v1\n${body.consent}`), body.signature), false);
  await assert.rejects(buildMcpConsent('ticket', request, 'device', identity, chain, never, now, selected), /unsupported/);
  const reduced = await buildMcpConsent('ticket', expanded, 'device', identity, chain, never, now, 'mcp:chains');
  assert.equal(JSON.parse(reduced.consent).v, 1);
});
