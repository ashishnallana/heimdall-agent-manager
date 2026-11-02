import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import WebSocket, { WebSocketServer } from 'ws';
import { FakeHub, USER, newBrowser } from './helpers/vaultDirectoryFixture.ts';
import { HeimdallControlClient, nativeRequestHeaders, ControlError } from '../scripts/mcp/heimdall-client.mjs';
import { McpProtocol } from '../scripts/mcp/protocol.mjs';
import { importKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { encryptVaultText, decryptVaultText } from '../src/ui/utils/vaultCrypto.ts';
import { verifySignature } from '../src/ui/utils/vaultStatements.ts';
import { sha256HexOfText } from '../src/ui/utils/vaultRequestSigner.ts';

const owned = 'chain_owned';
const token = 'fixture-oidc-access-token';

async function setup(t) {
  const hub = new FakeHub();
  const root = await newBrowser();
  await hub.genesis(root);
  const keyring = await importKeyring(await hub.keyringBytes(root), USER);
  const records = new Map([[owned, { chain_id: owned, title: await encryptVaultText('Owned chain', keyring), description: '', status: 'active' }]]);
  let code;
  let failAuth = false;
  const calls = [];
  const seenNonces = new Set();
  const authorize = async (headers, method, path, body) => {
    if (headers.authorization !== `Bearer ${token}` || failAuth) return false;
    const row = hub.rows.get(headers['x-heimdall-device-id']);
    if (!row || row.status !== 'approved' || headers['x-heimdall-device-sig-version'] !== '2') return false;
    const nonce = headers['x-heimdall-device-nonce'];
    if (seenNonces.has(nonce) || !/^[0-9a-f-]{36}$/.test(nonce)) return false;
    const canonical = ['heimdall-device-request/v2', method, path, USER, headers['x-heimdall-device-ts'], nonce, await sha256HexOfText(body)].join('\n');
    const ok = await verifySignature(row.sign_alg, row.sign_public_key, new TextEncoder().encode(canonical), headers['x-heimdall-device-sig']);
    if (ok) seenNonces.add(nonce);
    return ok;
  };
  const response = (status, data, page) => new Response(JSON.stringify({ data, ...(page ? { page } : {}) }), { status });
  const fetchImpl = async (url, init) => {
    const path = url.pathname;
    const headers = Object.fromEntries(Object.entries(init.headers).map(([key, value]) => [key.toLowerCase(), value]));
    const body = init.body ?? '';
    calls.push({ url: String(url), ...init });
    if (headers.authorization !== `Bearer ${token}` || failAuth) return response(401, {});
    if (path === '/api/v1/me') return response(200, { user_id: USER });
    if (path === '/api/v1/vault/directory') return response(200, hub.dir());
    if (path === '/api/v1/vault/devices/register') {
      const value = JSON.parse(body);
      const proof = value.statement.split('\n').find(line => line.startsWith('subject_sign_pub=')).split('=')[1];
      assert.equal(await verifySignature('ecdsa-p256-sha256', proof, new TextEncoder().encode(value.statement), value.proof_signature), true);
      return response(200, await hub.register(value.statement, value.pair_lookup, value.pair_key_mac, value.pair_salt, value.pair_hub_origin));
    }
    if (!await authorize(headers, init.method, url.pathname + url.search, body)) return response(403, {});
    if (path === '/api/v1/vault/devices/self') {
      const device_id = headers['x-heimdall-device-id'];
      return response(200, { device_id, status: hub.row(device_id).status, wrap: hub.wraps.get(device_id), pair_mac: hub.pairMacs.get(device_id) });
    }
    if (path === '/api/v1/task-chains' && init.method === 'GET') {
      assert.equal(url.searchParams.get('flat'), '1');
      return response(200, [...records.values()], { has_more: false, next_cursor: '', limit: 25 });
    }
    if (path === '/api/v1/task-chains' && init.method === 'POST') {
      const value = JSON.parse(body);
      assert.match(value.title, /^vault:v2:/);
      if (value.description) assert.match(value.description, /^vault:v2:/);
      const row = { chain_id: 'chain_created', ...value };
      records.set(row.chain_id, row);
      return response(201, row);
    }
    const match = path.match(/^\/api\/v1\/task-chains\/(chain_[\w-]+)(\/tasks)?$/);
    if (match && records.has(match[1])) {
      if (!match[2]) return response(200, records.get(match[1]));
      return response(200, [{ task_id: 'task_1', title: await encryptVaultText('Review this', keyring), state: 'in_review', reviews: [{ reviewer: 'user', verdict: 'approve' }] }]);
    }
    return response(404, {});
  };
  const client = new HeimdallControlClient({ hubUrl: 'https://hub.example.test', token, fetchImpl, onPairing: value => { code = value.code; } });
  t.after(() => client.close());
  const pair = async () => {
    await assert.rejects(client.list(), error => error.code === 'pairing_pending');
    assert.ok(code);
    await hub.approveByCode(root, code);
  };
  return { hub, root, keyring, client, calls, records, pair, authorize, expire: () => { failAuth = true; } };
}

test('native OIDC device proof binds method, query, body and user; uses UUID nonce', async () => {
  const identity = await newBrowser();
  const headers = await nativeRequestHeaders(identity, 'POST', '/prefix/api/v1/x?a=1', '{"x":1}', 123, '12345678-1234-1234-1234-123456789abc');
  assert.equal(headers['X-Heimdall-Device-Sig-Version'], '2');
  const bytes = new TextEncoder().encode(['heimdall-device-request/v2', 'POST', '/prefix/api/v1/x?a=1', USER, '123', '12345678-1234-1234-1234-123456789abc', await sha256HexOfText('{"x":1}')].join('\n'));
  assert.equal(await verifySignature(identity.signAlg, identity.signPub, bytes, headers['X-Heimdall-Device-Sig']), true);
});

test('real pairing helpers unlock readable lists/detail and seal chain creation', async t => {
  const { client, pair, records, keyring, calls } = await setup(t);
  await pair();
  const listed = await client.list();
  assert.equal(listed.chains[0].title, 'Owned chain');
  assert.equal(listed.page.has_more, false);
  const detail = await client.get({ chain_id: owned });
  assert.equal(detail.tasks[0].title, 'Review this');
  assert.equal(detail.tasks[0].reviews[0].verdict, 'approve');
  const created = await client.create({ title: 'New chain', description: 'Private purpose' });
  assert.equal(created.title, 'New chain');
  assert.equal(created.description, 'Private purpose');
  assert.equal(await decryptVaultText(records.get('chain_created').title, keyring), 'New chain');
  assert.equal(calls.filter(call => call.method === 'POST' && call.url.endsWith('/task-chains')).length, 1);
});

test('unapproved device cannot create a chain; keyring remains absent', async t => {
  const { client, records } = await setup(t);
  await assert.rejects(client.create({ title: 'Must not write' }), error => error.code === 'pairing_pending');
  assert.equal(records.size, 1);
  assert.equal(client.keyring, null);
});

test('tampered pairing MAC fails closed before key installation', async t => {
  const { client, pair, hub } = await setup(t);
  await pair();
  hub.pairMacs.set(client.identity.deviceId, '0'.repeat(64));
  await assert.rejects(client.list(), error => error.code === 'vault_locked');
  assert.equal(client.keyring, null);
});

test('revocation and expired authentication clear local vault access', async t => {
  const { client, pair, hub, expire } = await setup(t);
  await pair(); await client.list();
  hub.row(client.identity.deviceId).status = 'revoked';
  await assert.rejects(client.list(), error => error.code === 'vault_locked');
  assert.equal(client.keyring, null);
  expire();
  await assert.rejects(client.list(), error => error.code === 'http_401');
});

test('unreadable chain ciphertext is an error, never an armored tool result', async t => {
  const { client, pair, records } = await setup(t);
  await pair();
  records.get(owned).title = 'vault:v2:bad';
  await assert.rejects(client.list(), error => error.code === 'vault_locked');
});

test('another owner chain cannot be read or subscribed; no event socket opens', async t => {
  const { client, pair } = await setup(t);
  await pair();
  let opened = false;
  client.openSocket = () => { opened = true; throw Error('must not open'); };
  await assert.rejects(client.get({ chain_id: 'chain_foreign' }), error => error.code === 'http_404');
  await assert.rejects(client.wait({ chain_id: 'chain_foreign' }), error => error.code === 'http_404');
  assert.equal(opened, false);
});

test('real WebSocket waits use signed user auth, filter chains and return fresh review state', async t => {
  const fixture = await setup(t);
  const { client, pair, authorize } = fixture;
  await pair();
  const server = createServer();
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', async (request, socket, head) => {
    if (!await authorize(request.headers, 'GET', request.url, '')) { socket.destroy(); return; }
    wss.handleUpgrade(request, socket, head, ws => wss.emit('connection', ws));
  });
  wss.on('connection', socket => {
    socket.send(JSON.stringify({ type: 'user_ws_ready', stream_epoch: 'fixture', stream_seq: 0 }));
    socket.send(JSON.stringify({ type: 'resource_changed', resource: 'task', resource_id: 'task_foreign', summary: { chain_id: 'chain_foreign', body: 'do not expose' } }));
    socket.send(JSON.stringify({ type: 'resource_changed', resource: 'task', resource_id: 'task_1', change: 'updated', summary: { chain_id: owned, body: 'do not expose' } }));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { for (const socket of wss.clients) socket.terminate(); wss.close(); await new Promise(resolve => server.close(resolve)); });
  client.openSocket = (url, headers) => {
    assert.equal(url.protocol, 'wss:');
    return new WebSocket(`ws://127.0.0.1:${server.address().port}${url.pathname}`, { headers });
  };
  const result = await client.wait({ chain_id: owned, timeout_ms: 2000 });
  assert.equal(result.status, 'changed');
  assert.equal(result.event.resource_id, 'task_1');
  assert.equal(result.state.tasks[0].reviews[0].verdict, 'approve');
  assert.equal(JSON.stringify(result).includes('do not expose'), false);
  assert.equal(client.sockets.size, 0);
});

test('wait timeout refreshes state; cancellation closes the socket', async t => {
  const { client, pair } = await setup(t);
  await pair();
  let ended = 0;
  client.openSocket = () => {
    const socket = Object.assign(new EventEmitter(), { terminate() { ended++; } });
    queueMicrotask(() => socket.emit('message', JSON.stringify({ type: 'user_ws_ready' })));
    return socket;
  };
  const result = await client.wait({ chain_id: owned, timeout_ms: 10 });
  assert.equal(result.status, 'timeout');
  assert.equal(result.state.chain.title, 'Owned chain');
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 100);
  await assert.rejects(client.wait({ chain_id: owned, timeout_ms: 1000 }, controller.signal), error => error.code === 'cancelled');
  assert.equal(ended, 2);
});

test('an event stream that never becomes ready fails rather than reporting a healthy timeout', async t => {
  const { client, pair } = await setup(t);
  await pair();
  client.openSocket = () => Object.assign(new EventEmitter(), { terminate() {} });
  await assert.rejects(client.wait({ chain_id: owned, timeout_ms: 10 }), error => error.code === 'stream_unavailable');
  assert.equal(client.sockets.size, 0);
});

test('expired auth during a wait prevents event/state disclosure and clears keys', async t => {
  const { client, pair, expire } = await setup(t);
  await pair();
  client.openSocket = () => {
    const socket = Object.assign(new EventEmitter(), { terminate() {} });
    queueMicrotask(() => {
      socket.emit('message', JSON.stringify({ type: 'user_ws_ready' }));
      expire();
      socket.emit('message', JSON.stringify({ type: 'resource_changed', resource: 'task_chain', resource_id: owned }));
    });
    return socket;
  };
  await assert.rejects(client.wait({ chain_id: owned, timeout_ms: 100 }), error => error.code === 'http_401');
  assert.equal(client.keyring, null);
  assert.equal(client.sockets.size, 0);
});

test('configuration rejects agent credentials and plaintext remote URLs; closed clients cannot run tools', async t => {
  for (const credential of ['hlat_secret', 'hit_secret', 'hba_secret', 'hut_secret', 'hbr_secret', 'hbf_secret']) {
    assert.throws(() => new HeimdallControlClient({ hubUrl: 'https://hub.example.test', token: credential }), /OIDC/);
  }
  assert.throws(() => new HeimdallControlClient({ hubUrl: 'http://remote.example.test', token }), /HTTPS/);
  const { client } = await setup(t);
  client.close();
  await assert.rejects(client.list(), error => error.code === 'closed');
});

test('MCP initialization, four tools, errors, cancellation and serialization', async () => {
  let finish;
  const protocol = new McpProtocol({ close() {}, async list() { return { chains: [] }; }, async create() { throw new ControlError('http_403', 'Denied'); }, async wait(args, signal) { return new Promise((resolve, reject) => { finish = resolve; signal.addEventListener('abort', () => reject(new ControlError('cancelled', 'Wait cancelled.'))); }); } });
  const req = (id, method, params) => ({ jsonrpc: '2.0', id, method, params });
  assert.equal((await protocol.handle(req(1, 'tools/list'))).error.code, -32002);
  const initialized = await protocol.handle(req(2, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } }));
  assert.equal(initialized.result.serverInfo.name, 'heimdall-control-poc');
  assert.deepEqual((await protocol.handle(req(3, 'tools/list'))).result.tools.map(tool => tool.name), ['chains.list', 'chains.get', 'chains.create', 'events.wait']);
  assert.equal((await protocol.handle(req(4, 'tools/call', { name: 'chains.create', arguments: { title: 'x', owner_user_id: 'other' } }))).error.code, -32602);
  assert.equal((await protocol.handle(req(5, 'tools/call', { name: 'chains.create', arguments: { title: 'x' } }))).result.isError, true);
  const waiting = protocol.handle(req(6, 'tools/call', { name: 'events.wait', arguments: { chain_id: owned } }));
  assert.ok(finish);
  assert.match((await protocol.handle(req(7, 'tools/call', { name: 'chains.list' }))).result.content[0].text, /busy/);
  await protocol.handle({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 6 } });
  assert.match((await waiting).result.content[0].text, /cancelled/);
  assert.equal((await protocol.handle(req(8, 'tools/call', { name: 'chains.list' }))).result.isError, undefined);
});

test('stdio executable emits only protocol JSON and never echoes configured credentials', async () => {
  const child = spawn(process.execPath, ['scripts/heimdall-mcp.mjs'], { cwd: new URL('..', import.meta.url), env: { ...process.env, HEIMDALL_MCP_HUB_URL: 'https://hub.example.test', HEIMDALL_MCP_OIDC_TOKEN: token }, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', errors = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { errors += chunk; });
  child.stdin.write('{bad}\n');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25' } }) + '\n');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) + '\n');
  child.stdin.end();
  const [status] = await once(child, 'exit');
  assert.equal(status, 0, errors);
  const messages = output.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(messages.length, 3);
  assert.equal(messages[0].error.code, -32700);
  assert.equal(messages.find(message => message.id === 2).result.tools.length, 4);
  assert.equal((output + errors).includes(token), false);
});
