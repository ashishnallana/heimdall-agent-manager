// Hub-blind device pairing (docs/plans/passwordless-vault.md §1 "Pairing"). The Odin
// twin is src/lib/vault/pairing.odin; both are pinned by the `pairing` vectors in
// tests/fixtures/vault_v2_vectors.json.
//
// The NEW device draws a secret code S (12 base32 symbols, 60 bits), shows it, and
// never sends it to the hub. The user types S once on an approving device. Both
// derive, with HKDF-SHA256 (32 zero-byte salt, IKM = the 12 canonical symbols):
//   lookup = HKDF(S, "heimdall-pair/v1|lookup")  — what the hub indexes the request by
//   K_mac  = HKDF(S, "heimdall-pair/v1|mac")     — never leaves the two devices
// key_mac  = HMAC(K_mac, "heimdall-pair-key/v1|<kind>|<payload>") proves to the
//            approver that the hub served the new device's real keys;
// pair_mac = HMAC(K_mac, "heimdall-pair-approve/v1|<approval>|<root_sign_pub>|<head>")
//            proves to the new device that its approval (and so the log prefix and
//            root it chains to) came from a device the user typed S into.

import { logEntryHash, lowerHexToBytes, toLowerHex } from './vaultStatements.ts';

export const PAIR_CODE_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export const PAIR_CODE_SYMBOLS = 12;
/** Lifetime of a pairing code; the new device refuses to use S after it. */
export const PAIR_CODE_TTL_MS = 10 * 60 * 1000;

const utf8 = new TextEncoder();
const PAIR_HEX_RE = /^[0-9a-f]{64}$/;
const P256_HEX_RE = /^04[0-9a-f]{128}$/;

/** The 12 canonical symbols (case folded; spaces, tabs and dashes ignored), or null. */
export function pairCodeSymbols(raw: unknown): string | null {
  const s = String(raw ?? '');
  if (s.length > 64) return null;
  const sym = s.replace(/[ \t-]+/g, '').toUpperCase();
  if (sym.length !== PAIR_CODE_SYMBOLS) return null;
  for (const c of sym) if (!PAIR_CODE_ALPHABET.includes(c)) return null;
  return sym;
}

/** "XXXX-XXXX-XXXX", or throws with a message fit for the user. */
export function normalizePairCode(raw: unknown): string {
  const sym = pairCodeSymbols(raw);
  if (!sym) throw new Error('A pairing code has 12 letters and digits (2–7), like ABCD-EFGH-JKLM.');
  return `${sym.slice(0, 4)}-${sym.slice(4, 8)}-${sym.slice(8)}`;
}

/** A fresh code from the CSPRNG (256 % 32 === 0: unbiased). */
export function generatePairCode(): string {
  const raw = crypto.getRandomValues(new Uint8Array(PAIR_CODE_SYMBOLS));
  let s = '';
  for (const b of raw) s += PAIR_CODE_ALPHABET[b % 32];
  raw.fill(0);
  return normalizePairCode(s);
}

export interface PairKeys {
  /** 64 lowercase hex: what the hub resolves the pending request by. */
  lookup: string;
  /** Non-extractable HMAC-SHA256 key (sign + verify). */
  macKey: CryptoKey;
}

export async function derivePairKeys(code: string): Promise<PairKeys> {
  const sym = pairCodeSymbols(code);
  if (!sym) throw new Error('Invalid pairing code');
  const ikm = await crypto.subtle.importKey('raw', utf8.encode(sym), 'HKDF', false, ['deriveBits', 'deriveKey']);
  const salt = new Uint8Array(32);
  const lookupBits = new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info: utf8.encode('heimdall-pair/v1|lookup') }, ikm, 256));
  const macKey = await crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt, info: utf8.encode('heimdall-pair/v1|mac') },
    ikm,
    { name: 'HMAC', hash: 'SHA-256', length: 256 },
    false,
    ['sign', 'verify'],
  );
  const lookup = toLowerHex(lookupBits);
  lookupBits.fill(0);
  return { lookup, macKey };
}

export function isPairHex(s: unknown): s is string {
  return typeof s === 'string' && PAIR_HEX_RE.test(s);
}

export function pairBridgePayload(identityPub: string, ecdhPub: string, codeChallenge: string): string {
  if (!P256_HEX_RE.test(identityPub) || !P256_HEX_RE.test(ecdhPub) || !/^[A-Za-z0-9_.:-]{1,128}$/.test(codeChallenge)) throw new Error('malformed bridge pairing payload');
  return `${identityPub}|${ecdhPub}|${codeChallenge}`;
}

const keyMsg = (kind: 'browser' | 'bridge', payload: string) => utf8.encode(`heimdall-pair-key/v1|${kind}|${payload}`);

async function approveMsg(approvalStatement: string, rootSignPub: string): Promise<Uint8Array> {
  if (!approvalStatement || !P256_HEX_RE.test(rootSignPub)) throw new Error('malformed pairing approval');
  return utf8.encode(`heimdall-pair-approve/v1|${approvalStatement}|${rootSignPub}|${await logEntryHash(approvalStatement)}`);
}

async function hmacHex(key: CryptoKey, msg: Uint8Array): Promise<string> {
  return toLowerHex(new Uint8Array(await crypto.subtle.sign('HMAC', key, msg as Uint8Array<ArrayBuffer>)));
}

async function hmacVerify(key: CryptoKey, msg: Uint8Array, macHex: unknown): Promise<boolean> {
  if (!isPairHex(macHex)) return false;
  return crypto.subtle.verify('HMAC', key, lowerHexToBytes(macHex, 32) as Uint8Array<ArrayBuffer>, msg as Uint8Array<ArrayBuffer>); // constant time
}

export function pairKeyMac(keys: PairKeys, kind: 'browser' | 'bridge', payload: string): Promise<string> {
  return hmacHex(keys.macKey, keyMsg(kind, payload));
}

export function verifyPairKeyMac(keys: PairKeys, kind: 'browser' | 'bridge', payload: string, mac: unknown): Promise<boolean> {
  return hmacVerify(keys.macKey, keyMsg(kind, payload), mac);
}

export async function pairApproveMac(keys: PairKeys, approvalStatement: string, rootSignPub: string): Promise<string> {
  return hmacHex(keys.macKey, await approveMsg(approvalStatement, rootSignPub));
}

export async function verifyPairApproveMac(keys: PairKeys, approvalStatement: string, rootSignPub: string, mac: unknown): Promise<boolean> {
  return hmacVerify(keys.macKey, await approveMsg(approvalStatement, rootSignPub), mac);
}
