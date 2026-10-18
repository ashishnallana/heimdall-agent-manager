/**
 * Binary PTY viewer frames (REQ-PTY-NET-2) — the browser side of src/contracts/pty_wire.odin.
 *
 * Hub -> browser (and browser -> hub for input) pty bytes travel as WebSocket BINARY frames:
 *
 *   u8 kind | u8 flags | [u16be cursor_row | u16be cursor_col]* | payload
 *
 *   kind  : 1 output, 2 input, 3 screen (hub pane-capture repaint)
 *   flags : 0x01 snapshot (absolute repaint; reset the UTF-8 decoder), 0x02 encrypted
 *           (payload = u32be epoch | nonce(12) | tag(16) | AES-256-GCM ciphertext, AAD
 *           `heimdall-pty-v2|e<epoch>|<session_id>|<out|in>`), 0x04 cursor block present
 *           (*) only when 0x04 is set.
 *
 * Control frames (ready / stream_ready / stream_closed / status / error / resize / heartbeat)
 * remain JSON text frames. There is no base64 on this path any more.
 */

import { AES_GCM_NONCE_BYTES, AES_GCM_TAG_BYTES, MIN_ARMOR_PAYLOAD_BYTES } from '../../utils/vaultCrypto.ts';
import { currentKey, keyFor, type VaultKeyring } from '../../utils/vaultKeyring.ts';

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
  /** Raw bytes or nonce|tag|ciphertext; a VIEW over the frame buffer, not a copy. */
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

/** PTY payload v2 header: u32be epoch | nonce(12) | tag(16). */
export const PTY_V2_HEADER_BYTES = 4 + MIN_ARMOR_PAYLOAD_BYTES;

/** AAD for a PTY v2 payload: `heimdall-pty-v2|e<epoch>|<session_id>|<out|in>`. */
export function ptyAad(epoch: number, sessionId: string, direction: PtyDirection): Uint8Array {
  return new TextEncoder().encode(`heimdall-pty-v2|e${epoch}|${sessionId}|${direction}`);
}

/** The epoch in a v2 payload header, or 0 when the payload is too short or names epoch 0. */
export function ptyPayloadEpoch(payload: Uint8Array): number {
  if (payload.length < PTY_V2_HEADER_BYTES) return 0;
  return new DataView(payload.buffer, payload.byteOffset, 4).getUint32(0);
}

/** Seal one v2 payload. `nonce` is supplied by callers that need determinism (tests). */
export async function sealPtyPayload(
  data: Uint8Array,
  key: CryptoKey,
  epoch: number,
  sessionId: string,
  direction: PtyDirection,
  nonce?: Uint8Array,
): Promise<Uint8Array> {
  if (!sessionId) throw new Error('PTY payload needs a session id');
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new Error('invalid PTY epoch');
  const iv = nonce ? Uint8Array.from(nonce) : crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));
  if (iv.length !== AES_GCM_NONCE_BYTES) throw new Error('invalid PTY nonce');
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: iv as unknown as BufferSource, additionalData: ptyAad(epoch, sessionId, direction) as unknown as BufferSource, tagLength: 128 },
    key,
    data as unknown as BufferSource,
  ));
  const ciphertextLen = sealed.length - AES_GCM_TAG_BYTES;
  const out = new Uint8Array(PTY_V2_HEADER_BYTES + ciphertextLen);
  new DataView(out.buffer).setUint32(0, epoch);
  out.set(iv, 4);
  out.set(sealed.subarray(ciphertextLen), 4 + AES_GCM_NONCE_BYTES);
  out.set(sealed.subarray(0, ciphertextLen), PTY_V2_HEADER_BYTES);
  return out;
}

/**
 * Decrypt a PTY v2 payload (u32be epoch | nonce | tag | ct) with the key for the
 * epoch in its header, straight from the binary frame. Returns null when this
 * keyring does not hold that epoch (the caller shows the locked notice); throws when
 * the payload is malformed or does not authenticate.
 */
export async function decryptPtyPayload(
  payload: Uint8Array,
  keyring: VaultKeyring,
  sessionId: string,
  direction: PtyDirection = 'out',
): Promise<Uint8Array | null> {
  if (payload.length < PTY_V2_HEADER_BYTES) {
    throw new Error(`Encrypted pty frame shorter than header (${payload.length} < ${PTY_V2_HEADER_BYTES})`);
  }
  const epoch = ptyPayloadEpoch(payload);
  if (epoch < 1) throw new Error('Encrypted pty frame names epoch 0');
  const key = keyFor(keyring, epoch);
  if (!key) return null;
  const nonce = payload.subarray(4, 4 + AES_GCM_NONCE_BYTES);
  const tag = payload.subarray(4 + AES_GCM_NONCE_BYTES, PTY_V2_HEADER_BYTES);
  const ciphertext = payload.subarray(PTY_V2_HEADER_BYTES);
  // WebCrypto AES-GCM expects ciphertext || auth_tag.
  const combined = new Uint8Array(ciphertext.length + AES_GCM_TAG_BYTES);
  combined.set(ciphertext, 0);
  combined.set(tag, ciphertext.length);
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: ptyAad(epoch, sessionId, direction) as unknown as BufferSource, tagLength: 128 },
    key,
    combined as unknown as BufferSource,
  );
  return new Uint8Array(plain);
}

/**
 * Encrypt browser input for the bridge under the keyring's CURRENT epoch (the bridge
 * rejects any other), with a random 12-byte IV and the `in` direction AAD.
 */
export async function encryptPtyPayload(data: Uint8Array, keyring: VaultKeyring, sessionId: string): Promise<Uint8Array> {
  return sealPtyPayload(data, currentKey(keyring), keyring.currentEpoch, sessionId, 'in');
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
