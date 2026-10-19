/**
 * Binary PTY viewer frames (REQ-PTY-NET-2) — the browser side of src/contracts/pty_wire.odin.
 *
 * Hub -> browser (and browser -> hub for input) pty bytes travel as WebSocket BINARY frames:
 *
 *   u8 kind | u8 flags | [u16be cursor_row | u16be cursor_col]* | payload
 *
 *   kind  : 1 output, 2 input, 3 screen (hub pane-capture repaint)
 *   flags : 0x01 snapshot (absolute repaint; reset the UTF-8 decoder), 0x02 encrypted
 *           (payload = PTY v2: u32be epoch | salt(16) | nonce(12) | tag(16) | AES-256-GCM
 *           ciphertext under a per-stream subkey -- see below), 0x04 cursor block present
 *           (*) only when 0x04 is set.
 *
 * Control frames (ready / stream_ready / stream_closed / status / error / resize / heartbeat)
 * remain JSON text frames. There is no base64 on this path any more.
 */

import { AES_GCM_NONCE_BYTES, AES_GCM_TAG_BYTES, MIN_ARMOR_PAYLOAD_BYTES, getActiveVaultKey, isVaultArmored, parseVaultEnvelope } from '../../utils/vaultCrypto.ts';
import { isValidAadId, type VaultKeyring } from '../../utils/vaultKeyring.ts';

export const PTY_WIRE_KIND_OUTPUT = 0x01;
export const PTY_WIRE_KIND_INPUT = 0x02;
export const PTY_WIRE_KIND_SCREEN = 0x03;

export const PTY_WIRE_FLAG_SNAPSHOT = 0x01;
export const PTY_WIRE_FLAG_ENCRYPTED = 0x02;
export const PTY_WIRE_FLAG_CURSOR = 0x04;

export const PTY_WIRE_VIEWER_HEADER_BYTES = 2;
export const PTY_WIRE_VIEWER_CURSOR_BYTES = 4;

export interface PtyViewerFrame {
  kind: number;
  flags: number;
  snapshot: boolean;
  encrypted: boolean;
  /** -1 when the frame carries no cursor block. */
  cursorRow: number;
  cursorCol: number;
  /** Raw bytes or the PTY v2 payload; a VIEW over the frame buffer, not a copy. */
  payload: Uint8Array;
}

/** Parse one binary viewer frame. Returns null for anything shorter than its header. */
export function decodePtyViewerFrame(data: ArrayBuffer | Uint8Array): PtyViewerFrame | null {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < PTY_WIRE_VIEWER_HEADER_BYTES) return null;
  const kind = bytes[0];
  const flags = bytes[1];
  let offset = PTY_WIRE_VIEWER_HEADER_BYTES;
  let cursorRow = -1;
  let cursorCol = -1;
  if (flags & PTY_WIRE_FLAG_CURSOR) {
    if (bytes.length < PTY_WIRE_VIEWER_HEADER_BYTES + PTY_WIRE_VIEWER_CURSOR_BYTES) return null;
    cursorRow = (bytes[2] << 8) | bytes[3];
    cursorCol = (bytes[4] << 8) | bytes[5];
    offset += PTY_WIRE_VIEWER_CURSOR_BYTES;
  }
  return {
    kind,
    flags,
    snapshot: (flags & PTY_WIRE_FLAG_SNAPSHOT) !== 0,
    encrypted: (flags & PTY_WIRE_FLAG_ENCRYPTED) !== 0,
    cursorRow,
    cursorCol,
    payload: bytes.subarray(offset),
  };
}

/** Build one binary viewer frame (browser -> hub input uses kind=INPUT). */
export function encodePtyViewerFrame(kind: number, flags: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(PTY_WIRE_VIEWER_HEADER_BYTES + payload.length);
  out[0] = kind & 0xff;
  out[1] = flags & 0xff;
  out.set(payload, PTY_WIRE_VIEWER_HEADER_BYTES);
  return out;
}

export type PtyDirection = 'out' | 'in';

// ── PTY payload v2 (docs/plans/passwordless-vault.md §1; Odin twin: src/lib/vault/channels.odin)
//
//   frame  = u32be epoch | salt(16) | nonce(12) | tag(16) | ct
//   subkey = HKDF-SHA256(ikm = epoch key, salt = salt16, info = `heimdall-pty-v2|<session_id>|<out|in>`)
//   nonce  = u32be(0) | u64be(counter), counter >= 1, never repeated under one salt
//   AAD    = `heimdall-pty-v2|e<epoch>|<session_id>|out`, or for input
//            `heimdall-pty-v2|e<epoch>|<session_id>|in|<counter>|<bridge_boot_id>` (the
//            bridge refuses any input counter that does not increase for its stream, and
//            any frame bound to another boot id -- replay defence across restarts too).

export const PTY_V2_SALT_BYTES = 16;
/** PTY payload v2 header: u32be epoch | salt(16) | nonce(12) | tag(16). */
export const PTY_V2_HEADER_BYTES = 4 + PTY_V2_SALT_BYTES + MIN_ARMOR_PAYLOAD_BYTES;
const PTY_V2_NONCE_OFFSET = 4 + PTY_V2_SALT_BYTES;
const PTY_V2_INFO = 'heimdall-pty-v2';
const utf8 = new TextEncoder();

function assertPtyEpoch(epoch: number): void {
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new Error('invalid PTY epoch');
}

function assertPtyCounter(counter: bigint): void {
  if (counter < 1n || counter > 0xffffffffffffffffn) throw new Error('invalid PTY counter');
}

function assertPtySession(sessionId: string): void {
  // Mirror of lib/vault pty_session_id_valid: fail closed on anything that could shift
  // the AAD / HKDF info fields.
  if (!isValidAadId(sessionId)) throw new Error('invalid PTY session id');
}

/**
 * AAD for a PTY v2 payload. Input frames require (and bind) the counter and the
 * receiving bridge's unseal boot id.
 */
export function ptyAad(epoch: number, sessionId: string, direction: PtyDirection, counter?: number | bigint, bootId?: string): Uint8Array {
  assertPtyEpoch(epoch);
  assertPtySession(sessionId);
  if (direction === 'in') {
    if (counter === undefined) throw new Error('PTY input AAD needs a counter');
    const c = BigInt(counter);
    assertPtyCounter(c);
    if (!isValidAadId(bootId)) throw new Error('PTY input AAD needs the bridge boot id');
    return utf8.encode(`${PTY_V2_INFO}|e${epoch}|${sessionId}|in|${c.toString()}|${bootId}`);
  }
  return utf8.encode(`${PTY_V2_INFO}|e${epoch}|${sessionId}|out`);
}

/** The 12-byte nonce u32be(0) | u64be(counter). */
export function ptyNonce(counter: number | bigint): Uint8Array {
  const c = BigInt(counter);
  assertPtyCounter(c);
  const n = new Uint8Array(AES_GCM_NONCE_BYTES);
  new DataView(n.buffer).setBigUint64(4, c);
  return n;
}

/** Derive the per-stream AES-GCM subkey from an HKDF base key (non-extractable). */
export async function derivePtySubkey(baseKey: CryptoKey, salt: Uint8Array, sessionId: string, direction: PtyDirection): Promise<CryptoKey> {
  assertPtySession(sessionId);
  if (salt.length !== PTY_V2_SALT_BYTES) throw new Error('invalid PTY salt');
  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: Uint8Array.from(salt) as unknown as BufferSource,
      info: utf8.encode(`${PTY_V2_INFO}|${sessionId}|${direction}`) as unknown as BufferSource,
    },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

/** The epoch's PTY HKDF base key, or null when this keyring cannot do PTY for it. */
export async function ptyBaseKeyFor(keyring: VaultKeyring | null | undefined, epoch: number): Promise<CryptoKey | null> {
  const entry = keyring?.ptyBaseKeys?.get(epoch);
  if (!entry) return null;
  try {
    return (await entry) ?? null;
  } catch {
    return null;
  }
}

/** The epoch in a v2 payload header, or 0 when the payload is too short or names epoch 0. */
export function ptyPayloadEpoch(payload: Uint8Array): number {
  if (payload.length < PTY_V2_HEADER_BYTES) return 0;
  return new DataView(payload.buffer, payload.byteOffset, 4).getUint32(0);
}

/**
 * Seal one v2 payload under the (salt, session, direction) subkey of `baseKey`. The
 * caller owns counter uniqueness: one salt, strictly increasing counters from 1.
 */
export async function sealPtyPayload(
  data: Uint8Array,
  baseKey: CryptoKey,
  epoch: number,
  sessionId: string,
  direction: PtyDirection,
  salt: Uint8Array,
  counter: number | bigint,
  bootId?: string,
): Promise<Uint8Array> {
  const aad = ptyAad(epoch, sessionId, direction, counter, bootId);
  const nonce = ptyNonce(counter);
  const subkey = await derivePtySubkey(baseKey, salt, sessionId, direction);
  return sealPtyWithSubkey(data, subkey, epoch, salt, nonce, aad);
}

async function sealPtyWithSubkey(data: Uint8Array, subkey: CryptoKey, epoch: number, salt: Uint8Array, nonce: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: aad as unknown as BufferSource, tagLength: 128 },
    subkey,
    data as unknown as BufferSource,
  ));
  const ciphertextLen = sealed.length - AES_GCM_TAG_BYTES;
  const out = new Uint8Array(PTY_V2_HEADER_BYTES + ciphertextLen);
  new DataView(out.buffer).setUint32(0, epoch);
  out.set(salt, 4);
  out.set(nonce, PTY_V2_NONCE_OFFSET);
  out.set(sealed.subarray(ciphertextLen), PTY_V2_NONCE_OFFSET + AES_GCM_NONCE_BYTES);
  out.set(sealed.subarray(0, ciphertextLen), PTY_V2_HEADER_BYTES);
  return out;
}

// Derived subkeys are cached per base key, so a stream pays HKDF once, not per frame.
const PTY_SUBKEY_CACHE_MAX = 32;
const ptySubkeyCache = new WeakMap<CryptoKey, Map<string, Promise<CryptoKey>>>();

function cachedPtySubkey(baseKey: CryptoKey, salt: Uint8Array, sessionId: string, direction: PtyDirection): Promise<CryptoKey> {
  let byStream = ptySubkeyCache.get(baseKey);
  if (!byStream) {
    byStream = new Map();
    ptySubkeyCache.set(baseKey, byStream);
  }
  let saltHex = '';
  for (const b of salt) saltHex += b.toString(16).padStart(2, '0');
  const id = `${saltHex}|${sessionId}|${direction}`;
  let subkey = byStream.get(id);
  if (!subkey) {
    subkey = derivePtySubkey(baseKey, salt, sessionId, direction);
    subkey.catch(() => byStream!.delete(id));
    if (byStream.size >= PTY_SUBKEY_CACHE_MAX) byStream.delete(byStream.keys().next().value as string);
    byStream.set(id, subkey);
  }
  return subkey;
}

/**
 * Decrypt a PTY v2 payload (u32be epoch | salt | nonce | tag | ct) straight from the
 * binary frame. Returns null when this keyring does not hold that epoch (the caller
 * shows the locked notice); throws when the payload is malformed or does not
 * authenticate.
 */
/** Thrown by decryptPtyPayload for an authentic frame the replay guard refuses. */
export class PtyReplayError extends Error {
  constructor() { super('replayed or reordered pty frame'); this.name = 'PtyReplayError'; }
}

/**
 * Per-connection replay guard for PTY OUTPUT frames: within one salt (one sender
 * stream / subkey) the nonce counter must strictly increase, so a replayed or
 * reordered frame is dropped. A new salt starts fresh, but only for a frame that
 * authenticated (the guard is consulted after decryption). Salts pushed out of the
 * bounded table are remembered as retired and never start fresh again.
 */
export class PtyOutputReplayGuard {
  private readonly last = new Map<string, bigint>();
  private readonly retired = new Set<string>();
  constructor(private readonly maxSalts = 8, private readonly maxRetired = 1024) {}

  accept(salt: Uint8Array, counter: bigint): boolean {
    const id = Array.from(salt, (b) => b.toString(16).padStart(2, '0')).join('');
    const prev = this.last.get(id);
    if (prev !== undefined) {
      if (counter <= prev) return false;
      this.last.delete(id); // re-insert below: Map order is recency
    } else {
      if (this.retired.has(id)) return false;
      if (this.last.size >= this.maxSalts) {
        const oldest = this.last.keys().next().value as string;
        this.last.delete(oldest);
        if (this.retired.size >= this.maxRetired) this.retired.delete(this.retired.values().next().value as string);
        this.retired.add(oldest);
      }
    }
    this.last.set(id, counter);
    return true;
  }
}

export async function decryptPtyPayload(
  payload: Uint8Array,
  keyring: VaultKeyring,
  sessionId: string,
  direction: PtyDirection = 'out',
  bootId?: string,
  replay?: PtyOutputReplayGuard,
): Promise<Uint8Array | null> {
  if (payload.length < PTY_V2_HEADER_BYTES) {
    throw new Error(`Encrypted pty frame shorter than header (${payload.length} < ${PTY_V2_HEADER_BYTES})`);
  }
  const epoch = ptyPayloadEpoch(payload);
  if (epoch < 1) throw new Error('Encrypted pty frame names epoch 0');
  assertPtySession(sessionId);
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  if (view.getUint32(PTY_V2_NONCE_OFFSET) !== 0) throw new Error('Encrypted pty frame has a non-counter nonce');
  const counter = view.getBigUint64(PTY_V2_NONCE_OFFSET + 4);
  if (counter < 1n) throw new Error('Encrypted pty frame has counter 0');
  const baseKey = await ptyBaseKeyFor(keyring, epoch);
  if (!baseKey) return null;
  const salt = payload.slice(4, PTY_V2_NONCE_OFFSET);
  const nonce = payload.subarray(PTY_V2_NONCE_OFFSET, PTY_V2_NONCE_OFFSET + AES_GCM_NONCE_BYTES);
  const tag = payload.subarray(PTY_V2_NONCE_OFFSET + AES_GCM_NONCE_BYTES, PTY_V2_HEADER_BYTES);
  const ciphertext = payload.subarray(PTY_V2_HEADER_BYTES);
  // WebCrypto AES-GCM expects ciphertext || auth_tag.
  const combined = new Uint8Array(ciphertext.length + AES_GCM_TAG_BYTES);
  combined.set(ciphertext, 0);
  combined.set(tag, ciphertext.length);
  const subkey = await cachedPtySubkey(baseKey, salt, sessionId, direction);
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: ptyAad(epoch, sessionId, direction, counter, bootId) as unknown as BufferSource, tagLength: 128 },
    subkey,
    combined as unknown as BufferSource,
  );
  if (replay && !replay.accept(salt, counter)) throw new PtyReplayError();
  return new Uint8Array(plain);
}

/**
 * Decrypt an armored PTY capture `vault:v2:<vault_id>:e<N>:<b64(salt|nonce|tag|ct)>`
 * (the bridge's sealed pane reply) to text. Returns null when the keyring cannot open
 * that epoch or the capture names another vault (never tried with these keys); throws
 * on a malformed or unauthenticated capture.
 */
export async function decryptPtyCaptureText(armored: string, keyring: VaultKeyring, sessionId: string): Promise<string | null> {
  const { vaultId, epoch, payload } = parseVaultEnvelope(armored);
  if (vaultId !== keyring.vaultId) return null;
  const frame = new Uint8Array(4 + payload.length);
  new DataView(frame.buffer).setUint32(0, epoch);
  frame.set(payload, 4);
  const plain = await decryptPtyPayload(frame, keyring, sessionId, 'out');
  return plain ? new TextDecoder().decode(plain) : null;
}

/**
 * A pane reply whose `output` is an armored PTY v2 capture (the bridge seals pane
 * captures whenever its vault is configured) is decrypted for `sessionId`. Fails
 * closed: a capture this browser cannot open throws instead of returning ciphertext
 * or a partial screen.
 */
export async function openPaneReplyOutput<T extends { output?: unknown }>(data: T, sessionId: string): Promise<T> {
  const output = data?.output;
  if (typeof output !== 'string' || !isVaultArmored(output)) return data;
  const keyring = getActiveVaultKey();
  if (!keyring) throw new Error('vault_locked: unlock the vault to view this pane');
  const text = await decryptPtyCaptureText(output, keyring, sessionId);
  if (text === null) throw new Error('vault_locked: this pane was sealed under a key this browser does not hold');
  return { ...data, output: text };
}

// ── Browser input streams ────────────────────────────────────────────────────
// One input stream per session: a fresh CSPRNG salt (hence a fresh subkey) whenever the
// stream starts, the keyring changes or its current epoch changes, and a counter seeded
// from the wall clock (ms x 1000) that only ever increases -- also across salts, so a
// later stream always starts above an earlier one (the bridge's replay floor).

interface PtyInputStream {
  keyring: VaultKeyring;
  bootId: string;
  epoch: number;
  salt: Uint8Array;
  subkey: Promise<CryptoKey>;
  counter: bigint;
}

const ptyInputStreams = new Map<string, PtyInputStream>();
const ptyInputHighWater = new Map<string, bigint>();
const ptyBridgeBootIds = new Map<string, string>();

/**
 * Record the session's bridge unseal boot id, as announced in the stream's
 * `ready` / `stream_ready` control frames (refreshed on every (re)connect and bridge
 * re-attach). Input is sealed to it; a changed id starts a new input stream.
 */
export function setPtyBridgeBootId(sessionId: string, bootId: unknown): void {
  if (!sessionId || !isValidAadId(bootId)) return;
  if (ptyBridgeBootIds.get(sessionId) !== bootId) {
    ptyBridgeBootIds.set(sessionId, bootId);
    ptyInputStreams.delete(sessionId);
  }
}

/** Start a new input stream (new salt) for the session on its next keystroke. */
export function resetPtyInputStream(sessionId: string): void {
  ptyInputStreams.delete(sessionId);
}

/**
 * Encrypt browser input for the bridge under the keyring's CURRENT epoch (the bridge
 * rejects any other), on this session's input stream. Throws (fail closed: nothing is
 * sent) when the keyring has no PTY base key for that epoch.
 */
export async function encryptPtyPayload(data: Uint8Array, keyring: VaultKeyring, sessionId: string, now: () => number = Date.now): Promise<Uint8Array> {
  assertPtySession(sessionId);
  const epoch = keyring.currentEpoch;
  assertPtyEpoch(epoch);
  // Fail closed: without the bridge's boot id there is nothing valid to seal to.
  const bootId = ptyBridgeBootIds.get(sessionId);
  if (!bootId) throw new Error('PTY input unavailable: bridge boot id not yet known');
  let stream = ptyInputStreams.get(sessionId);
  if (!stream || stream.keyring !== keyring || stream.epoch !== epoch || stream.bootId !== bootId) {
    const baseKey = await ptyBaseKeyFor(keyring, epoch);
    if (!baseKey) throw new Error('Vault PTY key unavailable');
    // Re-check after the await: a concurrent call may already have started the stream.
    stream = ptyInputStreams.get(sessionId);
    if (!stream || stream.keyring !== keyring || stream.epoch !== epoch || stream.bootId !== bootId) {
      const salt = crypto.getRandomValues(new Uint8Array(PTY_V2_SALT_BYTES));
      const seed = BigInt(Math.max(0, Math.floor(now()))) * 1000n;
      const prev = ptyInputHighWater.get(sessionId) ?? 0n;
      stream = {
        keyring,
        bootId,
        epoch,
        salt,
        subkey: derivePtySubkey(baseKey, salt, sessionId, 'in'),
        counter: (seed > prev ? seed : prev),
      };
      ptyInputStreams.set(sessionId, stream);
    }
  }
  // Reserve the counter synchronously so concurrent calls never share one.
  stream.counter += 1n;
  const counter = stream.counter;
  ptyInputHighWater.set(sessionId, counter);
  const subkey = await stream.subkey;
  return sealPtyWithSubkey(data, subkey, epoch, stream.salt, ptyNonce(counter), ptyAad(epoch, sessionId, 'in', counter, stream.bootId));
}

/**
 * ONE persistent streaming UTF-8 decoder per connection. The bridge cuts output at byte
 * boundaries (16 KiB frames, 32 KiB snapshot chunks), so a multi-byte character can straddle
 * two frames; a fresh TextDecoder per frame would turn both halves into U+FFFD. `stream: true`
 * carries the partial sequence across calls. `reset()` discards any pending partial — called
 * on a snapshot/screen frame (an absolute repaint starts a new byte stream) and on reconnect.
 */
export class PtyTextDecoder {
  private decoder = new TextDecoder('utf-8', { stream: true } as TextDecoderOptions);

  decode(bytes: Uint8Array): string {
    return this.decoder.decode(bytes as unknown as BufferSource, { stream: true });
  }

  reset(): void {
    // decode() with no stream flag flushes and resets the decoder's internal state; the
    // flushed replacement character (if any) belongs to a stream we are abandoning.
    try { this.decoder.decode(); } catch { /* nothing pending */ }
    this.decoder = new TextDecoder('utf-8', { stream: true } as TextDecoderOptions);
  }
}
