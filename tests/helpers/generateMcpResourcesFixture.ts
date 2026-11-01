// Synthetic resource capability interoperability vector. Never use a real vault.
import { writeFileSync } from 'node:fs';
import { FakeHub, newBrowser } from './vaultDirectoryFixture.ts';
import { buildMcpConsent } from '../../src/ui/utils/mcpConsent.ts';

const owner = 'usr_mcp_task_fixture';
const now = Date.parse('2026-10-31T07:00:00Z');
const hub = new FakeHub(owner);
const identity = await newBrowser(owner);
await hub.genesis(identity);
const chain = await hub.chain();
const request = { owner, client: 'client-task-fixture', redirect: 'https://client.example/callback', resource: 'https://hub.example/api/v1/mcp', scope: 'mcp:chains mcp:tasks:read mcp:tasks:write mcp:agents:read mcp:agents:write mcp:instances:read mcp:instances:control mcp:memories:read mcp:memories:write mcp:projects:read mcp:projects:write mcp:issues:read mcp:issues:write', grant: 'grant-task-fixture', family: 'family-task-fixture', revision: 1, expires_ms: now + 300000 };
const hosted = await buildMcpConsent('ticket-task-fixture', request, 'hosted', identity, chain, async run => {
  const bytes = await hub.keyringBytes(identity);
  try { return await run(bytes); } finally { bytes.fill(0); }
}, now);
const device = await buildMcpConsent('ticket-task-fixture', request, 'device', identity, chain, async () => { throw new Error('No export'); }, now);
writeFileSync(new URL('../fixtures/mcp_resources_v2.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, now_ms: now, request, directory: hub.dir(), hosted, device }, null, 2) + '\n');
