// Disposable native Hub + synthetic vault. Never points at a production database.
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { randomBytes, createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import https from 'node:https';
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import { hubLogin, sessionHeaders, startMockOidc, freePort } from '../e2e/hubOidc.mjs';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { buildGenesis, buildBridgeApproval, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes, parseKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { buildMcpConsent } from '../../src/ui/utils/mcpConsent.ts';
import { derivePairKeys, pairApproveMac } from '../../src/ui/utils/vaultPairing.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';

export const pause = (ms: number) => new Promise(r => setTimeout(r, ms));
export function check(ok: unknown, message: string): asserts ok { if (!ok) throw new Error(message); console.log(`PASS ${message}`); }
export async function eventually<T>(fn: () => Promise<T | undefined>, label: string, ms = 30000): Promise<T> {
  for (const deadline = Date.now() + ms;;) { const value = await fn(); if (value !== undefined) return value; if (Date.now() > deadline) throw new Error(`Timeout: ${label}`); await pause(250); }
}
export async function nativeMcpHub() {
  const operatorEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => ["PATH","HOME","HEIMDALL_AGENT_TOKEN","HEIMDALL_AGENT_INSTANCE_ID","HEIMDALL_BRIDGE_ENDPOINT"].includes(key)));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-mcp-acceptance-')); fs.chmodSync(root, 0o700);
  const testHome = path.join(root, 'home'); fs.mkdirSync(testHome);
  const providerHome = process.env.HEIMDALL_E2E_PROVIDER_CODEX_HOME;
  let isolatedAuth: string | undefined;
  if (process.env.HEIMDALL_E2E_LIVE_RUNTIME === '1' && providerHome) {
    // Use only an unexpired short-lived access credential. Never copy the real
    // config/plugins or refresh a shared OAuth family from this disposable run.
    const auth = JSON.parse(fs.readFileSync(path.join(providerHome, 'auth.json'), 'utf8'));
    const token = auth.tokens?.access_token;
    const expires = token ? JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).exp : 0;
    check(expires * 1000 > Date.now() + 600000, 'provider access credential valid beyond test deadline');
    auth.tokens.refresh_token = '';
    const home = path.join(testHome, '.codex'); fs.mkdirSync(home);
    isolatedAuth = path.join(home, 'auth.json'); fs.writeFileSync(isolatedAuth, JSON.stringify(auth), { mode: 0o600 });
  }
  for (const key of Object.keys(process.env)) if (key.startsWith('HEIMDALL_') && !key.startsWith('HEIMDALL_E2E_')) delete process.env[key];
  const env = { ...process.env };
  // Enrollment has service-install fallbacks. An isolated home and scrubbed
  // service environment prevent it from stopping the caller's real Bridge.
  Object.assign(env, { HOME: testHome, USERPROFILE: testHome, XDG_CONFIG_HOME: path.join(testHome, '.config') });
  const children: ChildProcess[] = [];
  const spawnOwned = (bin: string, args: string[], cwd: string, extra = {}, logName = 'child.log') => {
    const fd = fs.openSync(path.join(root, logName), 'w', 0o600);
    const child = spawn(bin, args, { cwd, env: { ...env, ...extra }, stdio: ['ignore', fd, fd] }); fs.closeSync(fd); children.push(child); return child;
  };
  const hubBin = process.env.HEIMDALL_E2E_HUB_BIN; check(hubBin && fs.existsSync(hubBin), 'native Hub binary available');
  const mock = await startMockOidc({ username: 'mcp-acceptance' });
  const daemonSockets: string[] = [];
  const stopDaemons = () => { if (process.env.HEIMDALL_E2E_PTY_HOST_BIN) for (const socket of daemonSockets) if (fs.existsSync(socket)) spawnSync(process.env.HEIMDALL_E2E_PTY_HOST_BIN, ['--socket', socket, 'stop'], { stdio: 'ignore', timeout: 10000 }); };
  process.once('exit', () => { stopDaemons(); for (const child of children) child.kill('SIGKILL'); mock.stop(); if (isolatedAuth) fs.rmSync(isolatedAuth, { force: true }); });
  const port = await freePort(), backendPort = await freePort(); const bindAddress = process.env.HEIMDALL_E2E_BIND_ADDRESS || '127.0.0.1'; const base = `https://${bindAddress}:${port}`;
  const certFile = path.join(root, 'tls-cert.pem'), privateFile = path.join(root, 'tls-key.pem');
  check(spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', privateFile, '-out', certFile, '-days', '1', '-subj', '/CN=localhost', '-addext', `subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${bindAddress}`], { stdio: 'ignore' }).status === 0, 'throwaway localhost TLS certificate');
  fs.chmodSync(privateFile, 0o600);
  const cert = fs.readFileSync(certFile, 'utf8');
  tls.setDefaultCACertificates([...tls.getCACertificates(), cert]);
  env.HAM_TLS_CA_FILE = certFile;
  const sockets = new Set<net.Socket>();
  const proxy = https.createServer({ cert, key: fs.readFileSync(privateFile) }, (req, res) => {
    if (req.method === "GET" && req.url === "/__acceptance_ca") { res.writeHead(200, { "Content-Type": "application/x-pem-file" }); res.end(cert); return; }
    if (req.method === 'GET' && req.url === '/__acceptance_bridge' && process.env.HEIMDALL_E2E_REMOTE_TEST_BINARY === '1') { res.writeHead(200, { 'Content-Type': 'application/octet-stream' }); fs.createReadStream(process.env.HEIMDALL_E2E_BRIDGE_BIN!).pipe(res); return; }
    const upstream = http.request({ host: '127.0.0.1', port: backendPort, method: req.method, path: req.url, headers: req.headers }, reply => { res.writeHead(reply.statusCode!, reply.headers); reply.pipe(res); });
    upstream.on('error', () => { res.writeHead(502); res.end(); }); req.pipe(upstream);
  });
  proxy.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  proxy.on('upgrade', (req, socket, head) => {
    const upstream = net.connect(backendPort, '127.0.0.1', () => { upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${Object.entries(req.headers).map(([k,v]) => `${k}: ${v}\r\n`).join('')}\r\n`); if (head.length) upstream.write(head); socket.pipe(upstream); upstream.pipe(socket); });
    sockets.add(upstream); upstream.once('close', () => sockets.delete(upstream));
    socket.on('error', () => upstream.destroy()); upstream.on('error', () => socket.destroy()); socket.once('close', () => upstream.destroy()); upstream.once('close', () => socket.destroy());
  });
  await new Promise<void>(resolve => proxy.listen(port, bindAddress, resolve));
  console.log('TEST_SERVER ' + JSON.stringify({ base, certFile }));
  const keyFile = path.join(root, 'mcp-envelope.json'); fs.writeFileSync(keyFile, JSON.stringify({ keys: [{ id: 'acceptance', key_hex: randomBytes(32).toString('hex') }] }), { mode: 0o600 });
  spawnOwned(hubBin, ['--listen', `127.0.0.1:${backendPort}`, '--db', path.join(root, 'hub.db'), '--ui-origin', base, '--public-app-origin', base, '--mcp-oauth-key-file', keyFile, '--billing-enforce-plan-limits', 'false'], root, mock.hubEnv(base), 'hub.log');
  await eventually(async () => { try { return (await fetch(base + '/api/v1/health')).ok ? true : undefined; } catch { return undefined; } }, 'Hub health');
  const session = await hubLogin(base, 'mcp-acceptance');
  const request = async (method: string, target: string, body?: unknown, headers = {}, redirect: RequestRedirect = 'follow') => {
    const text = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
    const response = await fetch(base + target, { method, headers: { ...sessionHeaders(session, base), ...(text === undefined ? {} : { 'Content-Type': 'application/json' }), ...headers }, body: text, redirect });
    const raw = await response.text(); let json: any; try { json = JSON.parse(raw); } catch { /* redirect */ }
    return { status: response.status, headers: response.headers, data: json?.data ?? json, json };
  };
  const me = await request('GET', '/api/v1/me'); const owner = me.data.user_id;
  const identity = await createDeviceIdentity(memoryDeviceStore(), owner);
  check((await request('POST', '/api/v1/vault/directory/genesis', await buildGenesis(identity, 'Synthetic acceptance vault'))).status === 201, 'synthetic vault genesis');
  const signed = async (method: string, target: string, body?: unknown) => {
    const text = body === undefined ? '' : JSON.stringify(body);
    const headers = await signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, owner, method, target.split('?')[0], text);
    return request(method, target, body === undefined ? undefined : text, headers);
  };
  const chain = async () => verifyDirectory((await request('GET', '/api/v1/vault/directory')).data, owner, null);
  const self = await signed('GET', '/api/v1/vault/devices/self');
  const ring = await openVerifiedWrap(self.data.wrap, { userId: owner, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chain() });
  const keyringBytes = serializeKeyringBytes(ring); for (const entry of ring.entries) entry.key.fill(0);
  const grant = async (scope: string, mode: 'hosted' | 'device' = 'hosted') => {
    const redirect = 'https://client.example/callback';
    const registered = await request('POST', '/api/v1/mcp/oauth/register', { redirect_uris: [redirect], token_endpoint_auth_method: 'none' });
    check(registered.status === 201, `${mode} OAuth dynamic registration`);
    const verifier = 'a'.repeat(43); const client = registered.data.client_id;
    const q = new URLSearchParams({ response_type: 'code', client_id: client, redirect_uri: redirect, code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256', state: 'acceptance', resource: base + '/api/v1/mcp', scope });
    const authorized = await request('GET', '/api/v1/mcp/oauth/authorize?' + q, undefined, {}, 'manual');
    check(authorized.status === 302, `${mode} OAuth authorize`);
    const ticket = new URLSearchParams(new URL(authorized.headers.get('location')!, base).hash.split('?')[1]).get('request')!;
    const pending = await signed('GET', '/api/v1/mcp/oauth/consent?request=' + ticket);
    check(pending.status === 200, `${mode} signed consent request (${pending.status})`);
    const consent = await buildMcpConsent(ticket, pending.data, mode, identity, await chain(), async run => { const bytes = Uint8Array.from(keyringBytes); try { return await run(bytes); } finally { bytes.fill(0); } });
    const approved = await signed('POST', '/api/v1/mcp/oauth/consent', consent); check(approved.status === 200, `${mode} signed consent accepted`);
    const code = new URL(approved.data.redirect).searchParams.get('code')!;
    const token = await request('POST', '/api/v1/mcp/oauth/token', new URLSearchParams({ grant_type: 'authorization_code', client_id: client, redirect_uri: redirect, code, code_verifier: verifier, resource: base + '/api/v1/mcp' }).toString(), { 'Content-Type': 'application/x-www-form-urlencoded' });
    check(token.status === 200 && token.data.access_token, `${mode} OAuth token exchange`);
    return token.data.access_token as string;
  };
  let rpcId = 1;
  const rpc = async (token: string, method: string, params?: unknown) => {
    const response = await fetch(base + '/api/v1/mcp', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method, ...(params === undefined ? {} : { params }) }) });
    return { status: response.status, json: await response.json() };
  };
  const tool = async (token: string, name: string, args: unknown) => {
    const r = await rpc(token, 'tools/call', { name, arguments: args });
    const text = r.json.result?.content?.[0]?.text;
    if (r.status !== 200 || r.json.result?.isError || r.json.error) throw new Error(`${name}: ${r.status} ${text || r.json.error?.message || 'failed'}`);
    return JSON.parse(text);
  };
  const approveBridge = async (code: string) => {
    const salts = await request('POST', '/api/v1/device/pair-salts', {});
    const candidates = await Promise.all(salts.data.candidates.filter((c: any) => c.kind === 'bridge').map(async (c: any) => ({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: c.pair_hub_origin, pairSalt: c.pair_salt }) })));
    const verified = await request('POST', '/api/v1/device/verify', { pair_lookups: candidates.map(c => c.keys.lookup) });
    const keys = candidates.find(c => c.salt === verified.data?.pair_salt)?.keys; check(verified.status === 200 && keys, 'native Bridge pairing verified');
    await checkBridgeCodeInfo(verified.data, keys);
    const { vault_approval, statement } = await buildBridgeApproval(identity, await chain(), verified.data, 'MCP acceptance');
    const approved = await request('POST', '/api/v1/device/approve', { pair_lookup: keys.lookup, approve: true, vault_approval, new_bridge_label: 'MCP acceptance' });
    const bridgeId = approved.data?.hub_observed?.bridge_id; check(approved.status === 200 && bridgeId, 'native Bridge approved');
    const target = await eventually(async () => { const pk = await request('GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`); return pk.data?.unseal_key_signature ? bridgeUnsealTargetFromRecord(bridgeId, pk.data) : undefined; }, 'enrollment connection');
    const after = await chain(); const mac = await pairApproveMac(keys, statement, after.rootSignPub);
    await deliverKeyringToBridge(bridgeId, after, { fetchTarget: async () => target, dispatch: async (_id, payload) => { const r = await request('POST', `/api/v1/bridges/${bridgeId}/unseal`, payload); check(r.status === 200 && r.data?.ok !== false, 'synthetic Bridge unsealed'); return r.data; }, withKeyringBytes: async run => { const bytes = Uint8Array.from(keyringBytes); try { return await run(bytes); } finally { bytes.fill(0); } } }, { enrollment: true, expectedPublicKey: target.publicKey, extra: { enrollment: true, expected_public_key: target.publicKey, pair_mac: mac } });
    return bridgeId;
  };
  const enroll = async () => {
    const bin = process.env.HEIMDALL_E2E_BRIDGE_BIN; check(bin && fs.existsSync(bin), 'native Bridge binary available');
    const dir = path.join(root, 'bridge'); fs.mkdirSync(dir);
    const cfg = path.join(dir, 'config.toml'); const credential = path.join(dir, 'bridge.token');
    const bridgePort = await freePort(), endpointPort = await freePort();
    const args = ['--config', cfg, '--bridge-token-file', credential, '--port', String(bridgePort), '--data-dir', path.join(dir, 'data'), '--local-endpoint-port', String(endpointPort), '--local-run-dir', path.join(dir, 'run')];
    let output = ''; const child = spawn(bin, ['enroll', '--hub', base, '--headless', ...args], { cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] }); children.push(child);
    child.stdout!.on('data', b => output += b); child.stderr!.on('data', b => output += b);
    const code = await eventually(async () => /^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m.exec(output)?.[1], 'bridge pairing code');
    const bridgeId = await approveBridge(code);
    await eventually(async () => child.exitCode !== null ? child.exitCode === 0 ? true : Promise.reject(new Error('Bridge enrollment failed')) : undefined, 'enrollment exit');
    check(output.includes('bridge enroll SUCCESS'), 'real native Bridge enrolled');
    const runtime = spawnOwned(bin, args, dir, {
      HEIMDALL_HAM_CTL_BIN: process.env.HEIMDALL_E2E_CTL_BIN,
      HEIMDALL_HAM_PTY_HOST_BIN: process.env.HEIMDALL_E2E_PTY_HOST_BIN,
    }, 'bridge.log');
    await eventually(async () => { const r = await request('GET', '/api/v1/bridges'); const rows = r.data?.bridges ?? r.data; return rows.find((b: any) => b.bridge_id === bridgeId && b.status === 'online'); }, 'Bridge online');
    daemonSockets.push(path.join(dir, 'run', `pty-host-${bridgeId}.sock`));
    return { bridgeId, runtime, dir };
  };
  return { root, base, certFile, operatorEnv, approveBridge, owner, keyringBytes, identity, chain, request, signed, grant, rpc, tool, enroll,
    async close() { keyringBytes.fill(0); stopDaemons(); for (const child of children.reverse()) child.kill(); mock.stop(); for (const socket of sockets) socket.destroy(); proxy.close(); if (isolatedAuth) fs.rmSync(isolatedAuth, { force: true }); await pause(300); for (const child of children) if (child.exitCode === null) child.kill('SIGKILL'); },
  };
}
