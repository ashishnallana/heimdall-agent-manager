// Hub-blind device pairing (docs/plans/passwordless-vault.md §1 "Pairing"). The Odin
// twin is src/lib/vault/pairing.odin; both are pinned by the `pairing` vectors in
// tests/fixtures/vault_v2_vectors.json.
//
// The NEW device draws a secret code S (14 base32 symbols, 70 bits) and a public
// random 16-byte pair_salt, shows S, and never sends it to the hub (pair_salt goes
// with the registration). The user types S once on an approving device, which
// fetches the public pair_salt back from the hub. Both run the PAIRING STRETCH (the
// pairing-code stretch, not the deleted password-era KDF):
//   K = PBKDF2-HMAC-SHA256(S, "heimdall-pair/v2|<kind>|<user_id>|<hub_origin>|<pair_salt>",
//                          PAIR_STRETCH_ITERATIONS, 32 bytes)
// then, with HKDF-SHA256 (32 zero-byte salt, IKM = K):
//   lookup = HKDF(K, "heimdall-pair/v2|lookup")  — what the hub indexes the request by
//   K_mac  = HKDF(K, "heimdall-pair/v2|mac")     — never leaves the two devices
// key_mac  = HMAC(K_mac, "heimdall-pair-key/v1|<kind>|<payload>") proves to the
//            approver that the hub served the new device's real keys;
// pair_mac = HMAC(K_mac, "heimdall-pair-approve/v1|<approval>|<root_sign_pub>|<head>")
//            proves to the new device that its approval (and so the log prefix and
//            root it chains to) came from a device the user typed S into.
// user_id is the account for a browser and "" for a bridge (it learns its account
// only at approval); hub_origin is pairHubOrigin() of the hub API base.

import { logEntryHash, lowerHexToBytes, toLowerHex } from './vaultStatements.ts';

export const PAIR_CODE_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export const PAIR_CODE_SYMBOLS = 14;
/** Lifetime of a pairing code; the new device refuses to use S after it. */
export const PAIR_CODE_TTL_MS = 10 * 60 * 1000;
/** Pairing stretch (not the password-era KDF): PBKDF2-HMAC-SHA256 iterations. */
export const PAIR_STRETCH_ITERATIONS = 1_000_000;
export const PAIR_SALT_BYTES = 16;

const utf8 = new TextEncoder();
const PAIR_HEX_RE = /^[0-9a-f]{64}$/;
const PAIR_SALT_RE = /^[0-9a-f]{32}$/;
const P256_HEX_RE = /^04[0-9a-f]{128}$/;
const ID_VALUE_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
const CODE_SYMBOL_RE = /^[A-Z2-7]$/;

export type PairKind = 'browser' | 'bridge';

/** The public input of the pairing stretch. */
export interface PairContext {
  kind: PairKind;
  /** The account id for a browser; '' for a bridge. */
  userId: string;
  /** Canonical "scheme://host:port" (see pairHubOrigin). */
  hubOrigin: string;
  /** 32 lowercase hex, random per request. */
  pairSalt: string;
}

/**
 * The 14 canonical symbols (ASCII case folded; spaces, tabs and dashes ignored), or
 * null. ASCII only: no Unicode case folding, so a lookalike never maps onto a symbol.
 */
export function pairCodeSymbols(raw: unknown): string | null {
  const s = String(raw ?? '');
  if (s.length > 64) return null;
  let sym = '';
  for (const ch of s) {
    if (ch === ' ' || ch === '\t' || ch === '-') continue;
    const c = ch >= 'a' && ch <= 'z' ? String.fromCharCode(ch.charCodeAt(0) - 32) : ch;
    if (!CODE_SYMBOL_RE.test(c) || sym.length === PAIR_CODE_SYMBOLS) return null;
    sym += c;
  }
  return sym.length === PAIR_CODE_SYMBOLS ? sym : null;
}

/** "XXXX-XXXX-XXXX-XX", or throws with a message fit for the user. */
export function normalizePairCode(raw: unknown): string {
  const sym = pairCodeSymbols(raw);
  if (!sym) throw new Error('A pairing code has 14 letters and digits (2–7), like ABCD-EFGH-JKLM-NP.');
  return `${sym.slice(0, 4)}-${sym.slice(4, 8)}-${sym.slice(8, 12)}-${sym.slice(12)}`;
}

/** A fresh code from the CSPRNG (256 % 32 === 0: unbiased). */
export function generatePairCode(): string {
  const raw = crypto.getRandomValues(new Uint8Array(PAIR_CODE_SYMBOLS));
  let s = '';
  for (const b of raw) s += PAIR_CODE_ALPHABET[b % 32];
  raw.fill(0);
  return normalizePairCode(s);
}

/** A fresh public pair_salt (32 lowercase hex). */
export function generatePairSalt(): string {
  return toLowerHex(crypto.getRandomValues(new Uint8Array(PAIR_SALT_BYTES)));
}

export function isPairSalt(s: unknown): s is string {
  return typeof s === 'string' && PAIR_SALT_RE.test(s);
}

/**
 * The canonical hub origin a pairing binds: lowercase "scheme://host:port" with an
 * explicit port and no path (WHATWG URL parsing; a trailing dot on the host is
 * dropped). `ham-bridge` computes the same from its --hub. Throws for non-http(s).
 */
export function pairHubOrigin(url: string): string {
  const u = new URL(url);
  if (u.protocol !== 'https:' && u.protocol !== 'http:') throw new Error('The hub address is not http(s)');
  const host = u.hostname.replace(/\.$/, '');
  const port = u.port || (u.protocol === 'https:' ? '443' : '80');
  const origin = `${u.protocol}//${host}:${port}`;
  if (!isPairHubOrigin(origin)) throw new Error('The hub address cannot be used for pairing');
  return origin;
}

/** Mirrors valid_pair_hub_origin in pairing.odin. */
export function isPairHubOrigin(s: unknown): s is string {
  if (typeof s !== 'string' || s.length === 0 || s.length > 255) return false;
  const m = /^https?:\/\/(\[[0-9a-f:.]{2,}\]|[a-z0-9.-]+):([1-9][0-9]{0,4})$/.exec(s);
  if (!m || Number(m[2]) > 65535) return false;
  const host = m[1];
  return host.startsWith('[') || (!host.startsWith('.') && !host.endsWith('.') && !host.includes('..'));
}

/**
 * The origins an approver accepts as a pending device's DECLARED pairing origin: its
 * own API origin plus the aliases the hub is configured with (--pairing-hub-origins).
 * Anything else is refused, so a device tricked into enrolling through a third-party
 * relay (which it then declares) is never approved here. Malformed entries are dropped.
 */
export function acceptedPairOrigins(own: string | null, listed: unknown): Set<string> {
  const out = new Set<string>();
  if (isPairHubOrigin(own)) out.add(own);
  if (Array.isArray(listed)) for (const o of listed) if (isPairHubOrigin(o)) out.add(o);
  return out;
}

/** The PBKDF2 salt string for ctx; throws when ctx is malformed. */
export function pairStretchSalt(ctx: PairContext): string {
  if (ctx.kind === 'browser') {
    if (!ID_VALUE_RE.test(ctx.userId)) throw new Error('Invalid pairing account');
  } else if (ctx.kind !== 'bridge' || ctx.userId !== '') {
    throw new Error('Invalid pairing kind');
  }
  if (!isPairHubOrigin(ctx.hubOrigin) || !isPairSalt(ctx.pairSalt)) throw new Error('Invalid pairing context');
  return `heimdall-pair/v2|${ctx.kind}|${ctx.userId}|${ctx.hubOrigin}|${ctx.pairSalt}`;
}

export interface PairKeys {
  /** 64 lowercase hex: what the hub resolves the pending request by. */
  lookup: string;
  /** Non-extractable HMAC-SHA256 key (sign + verify). */
  macKey: CryptoKey;
}

/** Runs the pairing stretch for `code` under `ctx`, then derives lookup and K_mac. */
export async function derivePairKeys(code: string, ctx: PairContext): Promise<PairKeys> {
  const sym = pairCodeSymbols(code);
  if (!sym) throw new Error('Invalid pairing code');
  const salt = utf8.encode(pairStretchSalt(ctx));
  const password = await crypto.subtle.importKey('raw', utf8.encode(sym), 'PBKDF2', false, ['deriveBits']);
  // Pairing stretch (not password-era): PBKDF2-HMAC-SHA256 over the pairing code.
  const k = new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: PAIR_STRETCH_ITERATIONS }, password, 256));
  try {
    const ikm = await crypto.subtle.importKey('raw', k, 'HKDF', false, ['deriveBits', 'deriveKey']);
    const zero = new Uint8Array(32);
    const lookupBits = new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: zero, info: utf8.encode('heimdall-pair/v2|lookup') }, ikm, 256));
    const macKey = await crypto.subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: zero, info: utf8.encode('heimdall-pair/v2|mac') },
      ikm,
      { name: 'HMAC', hash: 'SHA-256', length: 256 },
      false,
      ['sign', 'verify'],
    );
    const lookup = toLowerHex(lookupBits);
    lookupBits.fill(0);
    return { lookup, macKey };
  } finally {
    k.fill(0);
  }
}

export function isPairHex(s: unknown): s is string {
  return typeof s === 'string' && PAIR_HEX_RE.test(s);
}

export function pairBridgePayload(identityPub: string, ecdhPub: string, codeChallenge: string): string {
  if (!P256_HEX_RE.test(identityPub) || !P256_HEX_RE.test(ecdhPub) || !ID_VALUE_RE.test(codeChallenge)) throw new Error('malformed bridge pairing payload');
  return `${identityPub}|${ecdhPub}|${codeChallenge}`;
}

const keyMsg = (kind: PairKind, payload: string) => utf8.encode(`heimdall-pair-key/v1|${kind}|${payload}`);

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

export function pairKeyMac(keys: PairKeys, kind: PairKind, payload: string): Promise<string> {
  return hmacHex(keys.macKey, keyMsg(kind, payload));
}

export function verifyPairKeyMac(keys: PairKeys, kind: PairKind, payload: string, mac: unknown): Promise<boolean> {
  return hmacVerify(keys.macKey, keyMsg(kind, payload), mac);
}

export async function pairApproveMac(keys: PairKeys, approvalStatement: string, rootSignPub: string): Promise<string> {
  return hmacHex(keys.macKey, await approveMsg(approvalStatement, rootSignPub));
}

export async function verifyPairApproveMac(keys: PairKeys, approvalStatement: string, rootSignPub: string, mac: unknown): Promise<boolean> {
  return hmacVerify(keys.macKey, await approveMsg(approvalStatement, rootSignPub), mac);
}
