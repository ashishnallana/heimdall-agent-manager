// Regenerate only deliberately. All material belongs to a synthetic test vault.
// node --import ./tests/helpers/vaultEndpointHarness.ts tests/helpers/generateMcpConsentFixture.ts
import { writeFileSync } from 'node:fs';
import { FakeHub, USER, newBrowser } from './vaultDirectoryFixture.ts';
import { buildMcpConsent } from '../../src/ui/utils/mcpConsent.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';

const now = Date.parse('2026-10-31T07:00:00Z');
const scoped = process.argv.includes('--scoped');
const hub = new FakeHub();
const identity = await newBrowser();
await hub.genesis(identity);
const chain = await hub.chain();
const request = { owner: USER, client: 'client-fixture', redirect: 'https://client.example/callback', resource: 'https://hub.example/api/v1/mcp', scope: 'mcp:chains', grant: 'grant-fixture', family: 'family-fixture', revision: 1, expires_ms: now + 300000 };
if (scoped) request.scope = 'mcp:chains mcp:tasks:read mcp:tasks:write mcp:artifacts:read';
const withBytes = async <T>(run: (bytes: Uint8Array) => Promise<T>) => {
  const bytes = await hub.keyringBytes(identity);
  try { return await run(bytes); } finally { bytes.fill(0); }
};
const selected = scoped ? 'mcp:chains mcp:tasks:read mcp:artifacts:read' : request.scope;
const hosted = await buildMcpConsent('fixture-ticket', request, 'hosted', identity, chain, withBytes, now, selected);
const device = await buildMcpConsent('fixture-ticket', request, 'device', identity, chain, withBytes, now, selected);
const consent_body = JSON.stringify(hosted);
const consent_headers = await signedRequestHeaders(identity, USER, 'POST', '/api/v1/mcp/oauth/consent', consent_body, { ts: now, nonce: 'n11111111111111111111111111111111' });
const disconnect_body = JSON.stringify({ grant: request.grant });
const disconnect_headers = await signedRequestHeaders(identity, USER, 'POST', '/api/v1/mcp/oauth/disconnect', disconnect_body, { ts: now, nonce: 'n22222222222222222222222222222222' });
const delivery_body = JSON.stringify({ grant: request.grant, revision: 1, directory_version: chain.version, directory_head: chain.headHash, wrap_json: hosted.wrap_json });
const delivery_headers = await signedRequestHeaders(identity, USER, 'POST', '/api/v1/mcp/oauth/wraps', delivery_body, { ts: now, nonce: 'n33333333333333333333333333333333' });
const recipients_headers = await signedRequestHeaders(identity, USER, 'GET', '/api/v1/mcp/oauth/recipients', '', { ts: now, nonce: 'n44444444444444444444444444444444' });
writeFileSync(new URL(scoped ? '../fixtures/mcp_consent_v2.json' : '../fixtures/mcp_consent_v1.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, now_ms: now, request, directory: hub.dir(), hosted, device, consent_body, consent_headers, disconnect_body, disconnect_headers, delivery_body, delivery_headers, recipients_headers }, null, 2) + '\n');
