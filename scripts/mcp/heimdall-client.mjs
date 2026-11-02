// Thin native-user client. Crypto, pairing, directory verification and content
// formats stay owned by the same modules the web UI uses.
import { randomUUID } from 'node:crypto';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { buildPairedRegistration } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, generatePairCode, generatePairSalt, pairHubOrigin, verifyPairApproveMac, PAIR_CODE_TTL_MS } from '../../src/ui/utils/vaultPairing.ts';
import { verifyDirectory, pinsFromChain } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { installKeyringFromWrap, clearKeyringSession } from '../../src/ui/utils/vaultKeyringSession.ts';
import { signP256 } from '../../src/ui/utils/vaultStatements.ts';
import { sha256HexOfText } from '../../src/ui/utils/vaultRequestSigner.ts';
import { encryptChainFields, decryptChainRecord } from '../../src/ui/utils/vaultChains.ts';
import { decryptTaskRecord } from '../../src/ui/utils/vaultTasks.ts';
import { containsVaultArmored } from '../../src/ui/utils/vaultContent.ts';

export class ControlError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

export async function nativeRequestHeaders(identity, method, target, body = '', now = Date.now(), nonce = randomUUID()) {
  const canonical = ['heimdall-device-request/v2', method, target, identity.userId, String(now), nonce, await sha256HexOfText(body)].join('\n');
  return {
    'X-Heimdall-Device-Sig-Version': '2',
    'X-Heimdall-Device-Id': identity.deviceId,
    'X-Heimdall-Device-Ts': String(now),
    'X-Heimdall-Device-Nonce': nonce,
    'X-Heimdall-Device-Sig': await signP256(identity.signPrivateKey, new TextEncoder().encode(canonical)),
  };
}

const locked = () => new ControlError('vault_locked', 'Vault content is unavailable. Approve this MCP device in Ninjy, or restart and pair again.');
const unwrap = value => value?.data ?? value;
const id = value => {
  if (typeof value !== 'string' || !/^chain_[A-Za-z0-9_-]{1,128}$/.test(value)) throw new ControlError('invalid_arguments', 'chain_id must be a chain identifier.');
  return value;
};

// Omit sensitive nested task fields that this POC does not expose. Reuse the UI's
// domain transformers, then fail closed rather than return their armor fallback.
async function readableChain(raw, keyring) {
  const chain = await decryptChainRecord(raw, keyring);
  const result = {};
  for (const k of ['chain_id', 'title', 'description', 'status', 'kind', 'work_revision', 'task_count', 'completed_task_count', 'user_validation_count', 'created_at', 'updated_at']) if (chain[k] !== undefined) result[k] = chain[k];
  if (JSON.stringify(result).includes('vault:v2:')) throw locked();
  return result;
}
async function readableTask(raw, keyring) {
  const task = await decryptTaskRecord(raw, keyring);
  const result = {};
  for (const k of ['task_id', 'title', 'description', 'state', 'kind', 'attempt_no', 'requires_user_approval', 'reviews', 'updated_at']) if (task[k] !== undefined) result[k] = task[k];
  if (JSON.stringify(result).includes('vault:v2:')) throw locked();
  return result;
}

export class HeimdallControlClient {
  constructor({ hubUrl, token, fetchImpl = fetch, openSocket, onPairing = () => {} }) {
    this.base = new URL(hubUrl);
    if (this.base.username || this.base.password || this.base.search || this.base.hash ||
        (this.base.protocol !== 'https:' && !(this.base.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(this.base.hostname)))) {
      throw new ControlError('configuration', 'Use an HTTPS Hub URL (HTTP is allowed only on loopback).');
    }
    if (!token || /^(hut_|hba_|hbr_|hbf_|hit_|hlat_)/.test(token) || /[\r\n]/.test(token)) throw new ControlError('configuration', 'An OIDC user access token is required; agent and bridge credentials are not accepted.');
    this.base.pathname = this.base.pathname.replace(/\/+$/, '') + '/';
    this.token = token;
    this.fetchImpl = fetchImpl;
    this.openSocket = openSocket;
    this.onPairing = onPairing;
    this.identity = null;
    this.keyring = null;
    this.pins = null;
    this.pending = null;
    this.closed = false;
    this.sockets = new Set();
  }

  url(path) { return new URL(path.replace(/^\//, ''), this.base); }

  async request(method, path, value, signed = true, signal) {
    if (this.closed) throw new ControlError('closed', 'MCP session is closed.');
    const url = this.url(path);
    const body = value === undefined ? '' : JSON.stringify(value);
    const headers = { Authorization: `Bearer ${this.token}` };
    if (body) headers['Content-Type'] = 'application/json';
    if (signed) {
      if (!this.identity) throw locked();
      Object.assign(headers, await nativeRequestHeaders(this.identity, method, url.pathname + url.search, body));
    }
    const response = await this.fetchImpl(url, { method, headers, body: body || undefined, redirect: 'error', signal: signal ?? AbortSignal.timeout(15_000) });
    // Never expose a remote response body as a tool error: it may echo secrets.
    if (!response.ok) {
      if ([401, 403].includes(response.status)) this.lock();
      throw new ControlError(`http_${response.status}`, `Heimdall refused the request (HTTP ${response.status}). Check sign-in, device approval, and resource ownership.`);
    }
    return await response.json();
  }

  lock() { this.keyring = null; clearKeyringSession(); }
  close() {
    this.closed = true;
    this.lock();
    this.pending = null;
    this.identity = null;
    this.token = '';
    for (const socket of this.sockets) socket.terminate();
    this.sockets.clear();
  }

  async ready() {
    if (this.closed) throw new ControlError('closed', 'MCP session is closed.');
    const me = unwrap(await this.request('GET', 'api/v1/me', undefined, false));
    if (!me?.user_id) throw new ControlError('authentication', 'Hub did not return an authenticated user.');
    if (this.identity && this.identity.userId !== me.user_id) { this.close(); throw new ControlError('account_changed', 'User identity changed; restart MCP.'); }
    if (!this.identity) this.identity = await createDeviceIdentity(memoryDeviceStore(), me.user_id);
    let directory = unwrap(await this.request('GET', 'api/v1/vault/directory', undefined, false));
    if (!directory || directory.configured === false) throw new ControlError('vault_unconfigured', 'Initialize the account vault in Ninjy before using MCP.');
    const listed = directory.devices?.find(row => row.device_id === this.identity.deviceId);
    if (!listed && !this.pending) {
      const code = generatePairCode();
      const pairSalt = generatePairSalt();
      const context = { kind: 'browser', userId: me.user_id, hubOrigin: pairHubOrigin(this.base.href), pairSalt };
      const keys = await derivePairKeys(code, context);
      const registration = await buildPairedRegistration(this.identity, 'Ninjy MCP POC (ephemeral)', keys);
      const reply = unwrap(await this.request('POST', 'api/v1/vault/devices/register', {
        statement: registration.statement, proof_signature: registration.signature,
        pair_lookup: registration.pairLookup, pair_key_mac: registration.pairKeyMac,
        pair_salt: pairSalt, pair_hub_origin: context.hubOrigin,
      }, false));
      if (reply.device_id !== this.identity.deviceId || reply.fingerprint !== this.identity.fingerprint) throw new ControlError('pairing_failed', 'Registration returned a different device.');
      this.pending = { code, keys, expiresAt: Date.now() + PAIR_CODE_TTL_MS };
      this.onPairing({ code, fingerprint: this.identity.fingerprint });
    }
    if (!listed || listed.status === 'pending') {
      if (!this.pending || Date.now() > this.pending.expiresAt) throw new ControlError('pairing_expired', 'Pairing expired. Restart the MCP server and pair again.');
      throw new ControlError('pairing_pending', `Approve Ninjy MCP POC in your signed-in Ninjy device using code ${this.pending.code}. Then retry this tool.`);
    }
    if (listed.status !== 'approved') { this.lock(); throw locked(); }
    try {
      const chain = await verifyDirectory(directory, me.user_id, this.pins);
      const mine = chain.trusted.get(this.identity.deviceId);
      if (!mine) throw locked();
      const self = unwrap(await this.request('GET', 'api/v1/vault/devices/self'));
      if (self.device_id !== this.identity.deviceId || self.status !== 'approved' || !self.wrap) throw locked();
      if (!this.pins && (!this.pending || Date.now() > this.pending.expiresAt ||
          !await verifyPairApproveMac(this.pending.keys, mine.approval_statement, chain.rootSignPub, self.pair_mac))) throw locked();
      this.keyring = await installKeyringFromWrap(this.identity, self.wrap, chain);
      if (this.closed) throw new ControlError('closed', 'MCP session is closed.');
      this.pins = pinsFromChain(chain);
      this.pending = null;
    } catch (error) { this.lock(); throw error instanceof ControlError ? error : locked(); }
  }

  async list({ limit = 25, cursor } = {}) {
    if (!Number.isInteger(limit) || limit < 1 || limit > 100 || (cursor !== undefined && (typeof cursor !== 'string' || cursor.length > 2048))) throw new ControlError('invalid_arguments', 'limit must be 1–100; cursor must be a short string.');
    await this.ready();
    const query = new URLSearchParams({ flat: '1', limit: String(limit) });
    if (cursor) query.set('cursor', cursor);
    const reply = await this.request('GET', `api/v1/task-chains?${query}`);
    const rows = unwrap(reply);
    if (!Array.isArray(rows)) throw new ControlError('invalid_response', 'Expected a chain list.');
    return { chains: await Promise.all(rows.map(row => readableChain(row, this.keyring))), page: reply.page ?? reply.meta?.page ?? null };
  }

  async snapshot(chainId) {
    const path = `api/v1/task-chains/${encodeURIComponent(id(chainId))}`;
    const chain = unwrap(await this.request('GET', path));
    const tasks = unwrap(await this.request('GET', `${path}/tasks`));
    if (!Array.isArray(tasks)) throw new ControlError('invalid_response', 'Expected a task list.');
    return { chain: await readableChain(chain, this.keyring), tasks: await Promise.all(tasks.map(task => readableTask(task, this.keyring))) };
  }

  async get({ chain_id }) { id(chain_id); await this.ready(); return this.snapshot(chain_id); }

  async create({ title, description = '' }) {
    if (typeof title !== 'string' || !title.trim() || title.length > 500 || typeof description !== 'string' || description.length > 20_000 || containsVaultArmored(title + description)) throw new ControlError('invalid_arguments', 'Supply a plain-text title (1–500 characters) and optional description (up to 20000 characters).');
    await this.ready();
    // Require the keyring before calling the UI helper (whose normal UI fallback
    // permits unconfigured accounts). MCP never writes these fields in plaintext.
    if (!this.keyring) throw locked();
    const body = await encryptChainFields({ title, description, kind: 'mixed_work' }, this.keyring);
    return readableChain(unwrap(await this.request('POST', 'api/v1/task-chains', body)), this.keyring);
  }

  async wait({ chain_id, timeout_ms = 25_000 }, signal) {
    id(chain_id);
    if (!Number.isInteger(timeout_ms) || timeout_ms < 1 || timeout_ms > 30_000) throw new ControlError('invalid_arguments', 'timeout_ms must be 1–30000.');
    await this.ready();
    // Permission check before opening a user-wide stream. Only scoped metadata
    // is returned; the full user stream never becomes an MCP resource.
    await this.request('GET', `api/v1/task-chains/${encodeURIComponent(chain_id)}`);
    const url = this.url('api/v1/user-ws');
    const headers = { Authorization: `Bearer ${this.token}`, ...await nativeRequestHeaders(this.identity, 'GET', url.pathname) };
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    if (!this.openSocket) throw new ControlError('configuration', 'WebSocket transport is unavailable.');
    if (signal?.aborted) throw new ControlError('cancelled', 'Wait cancelled.');
    const socket = this.openSocket(url, headers);
    this.sockets.add(socket);
    try {
      const event = await new Promise((resolve, reject) => {
        let done = false;
        let subscribed = false;
        const finish = (error, value) => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          signal?.removeEventListener('abort', cancel);
          error ? reject(error) : resolve(value);
        };
        const cancel = () => finish(new ControlError('cancelled', 'Wait cancelled.'));
        const timer = setTimeout(() => subscribed ? finish(null, null) : finish(new ControlError('stream_unavailable', 'Event stream did not become ready; retry and refresh chain state.')), timeout_ms);
        signal?.addEventListener('abort', cancel, { once: true });
        socket.on('error', () => finish(new ControlError('stream_closed', 'Event connection failed; retry and refresh chain state.')));
        socket.on('close', () => finish(new ControlError('stream_closed', 'Event connection closed; retry and refresh chain state.')));
        socket.on('message', data => {
          try {
            const message = JSON.parse(String(data));
            if (message.type === 'user_ws_ready') { subscribed = true; return; }
            if (!subscribed) return finish(new ControlError('invalid_response', 'Event arrived before the stream was ready.'));
            if (message.type === 'resync_required') return finish(null, { type: 'resync_required', chain_id });
            const matches = message.chain_id === chain_id || message.summary?.chain_id === chain_id ||
              (message.resource === 'task_chain' && message.resource_id === chain_id);
            if (matches) finish(null, { type: message.type, resource: message.resource, resource_id: message.resource_id, change: message.change, chain_id });
          } catch { finish(new ControlError('invalid_response', 'Invalid event stream message.')); }
        });
      });
      // Revalidate authentication/device approval after a potentially long wait.
      await this.ready();
      return { status: event ? 'changed' : 'timeout', event, refresh_required: true, state: await this.snapshot(chain_id) };
    } finally { this.sockets.delete(socket); socket.terminate(); }
  }
}
