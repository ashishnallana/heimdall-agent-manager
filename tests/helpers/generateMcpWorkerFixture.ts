// Synthetic vault only. Regenerate deliberately, never with an account keyring.
import { writeFileSync } from 'node:fs';
import { mcpWorkerFixture } from './mcpWorkerFixture.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
const scoped = process.argv.includes('--scoped');
const f = await mcpWorkerFixture(Date.parse('2026-10-31T07:00:00Z'), scoped ? 'mcp:chains mcp:tasks:read mcp:artifacts:read' : 'mcp:chains');
const get_jobs_headers = await signedRequestHeaders(f.identity, f.job.owner, 'GET', '/api/v1/mcp/oauth/jobs', '', { ts: f.now, nonce: 'n55555555555555555555555555555555' });
const post_body = JSON.stringify(f.reply);
const post_jobs_headers = await signedRequestHeaders(f.identity, f.job.owner, 'POST', '/api/v1/mcp/oauth/jobs', post_body, { ts: f.now, nonce: 'n66666666666666666666666666666666' });
writeFileSync(new URL(scoped ? '../fixtures/mcp_worker_v2.json' : '../fixtures/mcp_worker_v1.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, now_ms: f.now, initial: { now_ms: f.now, request: f.request, hosted: f.consent, directory: f.hub.dir() }, keyring_hex: f.keyringHex, device_id: f.identity.deviceId, bridge_device_id: f.bridge.deviceId, job: f.job, reply: f.reply, bridge_reply: f.bridgeReply, result: f.result, get_jobs_headers, post_jobs_headers, post_body }, null, 2) + '\n');
