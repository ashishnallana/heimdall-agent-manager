// Browser device identity for the passwordless vault
// (docs/plans/passwordless-vault.md §1 "Device identity (browser)", §2 P3).
//
// Each browser holds two NON-EXTRACTABLE WebCrypto key pairs, persisted in IndexedDB
// (`heimdall_device`): ECDSA P-256 to sign statements and requests, ECDH P-256 to
// receive keyring wraps. Only the public halves ever leave the device.
//
// Next to the identity the device keeps monotonic PINS for the account directory:
// the root device and its signing key (pinned on first verified sight) and the
// highest directory version / epoch it has verified. A directory that moves any of
// them backwards, or names another root, is refused (rollback / root swap).
//
// Everything is keyed by the signed-in user id, so two accounts on one browser never
// share keys or pins. Storage is injectable: tests use `memoryDeviceStore()`, never a
// real IndexedDB.

import { ID_VALUE_RE } from './vaultKeyring.ts';
import {
  SIGN_ALG_ECDSA_P256_SHA256,
  WRAP_ALG_ECDH_P256_HKDF_AES,
  isLowerHex,
  lowerHexToBytes,
  signP256,
  toLowerHex,
  type Statement,
} from './vaultStatements.ts';

const utf8 = new TextEncoder();

// ── storage backend ──────────────────────────────────────────────────────────

/** Minimal async key/value store. Values are structured-cloneable (CryptoKeys included). */
export interface DeviceKeyValueStore {
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
}

/** In-memory store for tests and for contexts without IndexedDB. */
export function memoryDeviceStore(): DeviceKeyValueStore {
  const map = new Map<string, unknown>();
  return {
    async get(key) { return map.get(key); },
    async put(key, value) { map.set(key, value); },
    async delete(key) { map.delete(key); },
  };
}

export const DEVICE_DB_NAME = 'heimdall_device';
const DEVICE_DB_STORE = 'kv';

/** IndexedDB-backed store (`heimdall_device`). Throws when IndexedDB is unavailable. */
export function indexedDbDeviceStore(idb: IDBFactory = globalThis.indexedDB): DeviceKeyValueStore {
  if (!idb) throw new Error('IndexedDB is unavailable in this browser context');
  let dbPromise: Promise<IDBDatabase> | null = null;
  const open = (): Promise<IDBDatabase> => {
    if (!dbPromise) {
      dbPromise = new Promise((resolve, reject) => {
        const req = idb.open(DEVICE_DB_NAME, 1);
        req.onupgradeneeded = () => {
          if (!req.result.objectStoreNames.contains(DEVICE_DB_STORE)) req.result.createObjectStore(DEVICE_DB_STORE);
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => { dbPromise = null; reject(req.error ?? new Error('IndexedDB open failed')); };
      });
    }
    return dbPromise;
  };
  const run = async <T>(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> => {
    const db = await open();
    return new Promise<T>((resolve, reject) => {
      const tx = db.transaction(DEVICE_DB_STORE, mode);
      const req = fn(tx.objectStore(DEVICE_DB_STORE));
      tx.oncomplete = () => resolve(req.result);
      tx.onerror = () => reject(tx.error ?? new Error('IndexedDB transaction failed'));
      tx.onabort = () => reject(tx.error ?? new Error('IndexedDB transaction aborted'));
    });
  };
  return {
    get: (key) => run('readonly', (s) => s.get(key)),
    put: async (key, value) => { await run('readwrite', (s) => s.put(value, key)); },
    delete: async (key) => { await run('readwrite', (s) => s.delete(key)); },
  };
}

// ── derived identifiers ──────────────────────────────────────────────────────

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource));
}

function quads(hex16: string): string {
  return `${hex16.slice(0, 4)} ${hex16.slice(4, 8)} ${hex16.slice(8, 12)} ${hex16.slice(12, 16)}`;
}

/** `dev_` + hex(SHA256(sign_pub_raw65))[0:32]. */
export async function deviceIdFor(signPubHex: string): Promise<string> {
  if (!isLowerHex(signPubHex, 65)) throw new Error('invalid signing public key');
  return `dev_${toLowerHex(await sha256(lowerHexToBytes(signPubHex))).slice(0, 32)}`;
}

/** First 8 bytes of SHA256(sign_pub‖ecdh_pub) as four groups of four hex digits. */
export async function fingerprintFor(signPubHex: string, ecdhPubHex: string): Promise<string> {
  const sign = lowerHexToBytes(signPubHex, 65);
  const ecdh = ecdhPubHex ? lowerHexToBytes(ecdhPubHex, 65) : new Uint8Array(0);
  const both = new Uint8Array(sign.length + ecdh.length);
  both.set(sign, 0);
  both.set(ecdh, sign.length);
  return quads(toLowerHex(await sha256(both)).slice(0, 16));
}

/** The ACCOUNT fingerprint: SHA256(root_sign_pub) truncated to 64 bits, in quads. */
export async function accountFingerprint(rootSignPubHex: string): Promise<string> {
  return quads(toLowerHex(await sha256(lowerHexToBytes(rootSignPubHex, 65))).slice(0, 16));
}

// ── identity ─────────────────────────────────────────────────────────────────

export interface DeviceIdentity {
  readonly userId: string;
  readonly deviceId: string;
  readonly kind: 'browser';
  readonly signAlg: typeof SIGN_ALG_ECDSA_P256_SHA256;
  readonly wrapAlg: typeof WRAP_ALG_ECDH_P256_HKDF_AES;
  /** Non-extractable private keys. */
  readonly signPrivateKey: CryptoKey;
  readonly ecdhPrivateKey: CryptoKey;
  readonly signPub: string;
  readonly ecdhPub: string;
  readonly fingerprint: string;
  readonly createdAt: number;
}

interface StoredIdentity {
  v: 1;
  userId: string;
  signPrivateKey: CryptoKey;
  ecdhPrivateKey: CryptoKey;
  signPub: string;
  ecdhPub: string;
  createdAt: number;
}

const identityKey = (userId: string) => `identity:${userId}`;
const pinsKey = (userId: string) => `pins:${userId}`;

function requireUserId(userId: string): string {
  if (!userId || userId.length > 64 || !ID_VALUE_RE.test(userId)) throw new Error('invalid user id for the device identity');
  return userId;
}

async function exportPubHex(key: CryptoKey): Promise<string> {
  return toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', key)));
}

async function hydrate(stored: StoredIdentity): Promise<DeviceIdentity> {
  if (stored.signPrivateKey.extractable || stored.ecdhPrivateKey.extractable) throw new Error('device private keys must be non-extractable');
  return Object.freeze({
    userId: stored.userId,
    deviceId: await deviceIdFor(stored.signPub),
    kind: 'browser' as const,
    signAlg: SIGN_ALG_ECDSA_P256_SHA256,
    wrapAlg: WRAP_ALG_ECDH_P256_HKDF_AES,
    signPrivateKey: stored.signPrivateKey,
    ecdhPrivateKey: stored.ecdhPrivateKey,
    signPub: stored.signPub,
    ecdhPub: stored.ecdhPub,
    fingerprint: await fingerprintFor(stored.signPub, stored.ecdhPub),
    createdAt: stored.createdAt,
  });
}

function isStoredIdentity(v: unknown, userId: string): v is StoredIdentity {
  const s = v as StoredIdentity;
  return Boolean(s) && s.v === 1 && s.userId === userId
    && s.signPrivateKey instanceof CryptoKey && s.ecdhPrivateKey instanceof CryptoKey
    && isLowerHex(s.signPub, 65) && isLowerHex(s.ecdhPub, 65);
}

/** The stored identity for `userId`, or null when this browser has none. */
export async function loadDeviceIdentity(store: DeviceKeyValueStore, userId: string): Promise<DeviceIdentity | null> {
  const stored = await store.get(identityKey(requireUserId(userId)));
  if (stored === undefined || stored === null) return null;
  if (!isStoredIdentity(stored, userId)) throw new Error('stored device identity is malformed');
  return hydrate(stored);
}

/** Generate and persist a fresh identity (two non-extractable P-256 key pairs). */
export async function createDeviceIdentity(store: DeviceKeyValueStore, userId: string, now: number = Date.now()): Promise<DeviceIdentity> {
  requireUserId(userId);
  const sign = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']) as CryptoKeyPair;
  const ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']) as CryptoKeyPair;
  const stored: StoredIdentity = {
    v: 1,
    userId,
    signPrivateKey: sign.privateKey,
    ecdhPrivateKey: ecdh.privateKey,
    signPub: await exportPubHex(sign.publicKey),
    ecdhPub: await exportPubHex(ecdh.publicKey),
    createdAt: now,
  };
  await store.put(identityKey(userId), stored);
  return hydrate(stored);
}

export async function loadOrCreateDeviceIdentity(store: DeviceKeyValueStore, userId: string): Promise<DeviceIdentity> {
  return (await loadDeviceIdentity(store, userId)) ?? createDeviceIdentity(store, userId);
}

// ── observed vault reset ─────────────────────────────────────────────────────
//
// A reset the hub announced in a directory this device VERIFIED (requested_at,
// due_at, and the head seq it was seen at). Only a recorded reset whose due_at has
// passed lets a "no directory" answer be treated as that reset; anything else is a
// missing vault (fail closed: typed confirmation). Cleared when a verified directory
// no longer carries a reset (cancelled).

export interface ObservedReset {
  readonly requested_at: string;
  readonly due_at: string;
  readonly head_seq: number;
}

const observedResetKey = (userId: string) => `observed-reset:${userId}`;

export async function loadObservedReset(store: DeviceKeyValueStore, userId: string): Promise<ObservedReset | null> {
  const v = await store.get(observedResetKey(requireUserId(userId))) as ObservedReset | undefined;
  if (!v || typeof v.due_at !== 'string' || typeof v.requested_at !== 'string' || !Number.isSafeInteger(v.head_seq)) return null;
  return v;
}

export async function recordObservedReset(store: DeviceKeyValueStore, userId: string, reset: ObservedReset | null): Promise<void> {
  if (reset) await store.put(observedResetKey(requireUserId(userId)), { requested_at: reset.requested_at, due_at: reset.due_at, head_seq: reset.head_seq });
  else await store.delete(observedResetKey(requireUserId(userId)));
}

/** True when `r` is a recorded reset whose due time has passed. */
export function observedResetElapsed(r: ObservedReset | null, now: number = Date.now()): boolean {
  if (!r) return false;
  const due = Date.parse(r.due_at);
  return Number.isFinite(due) && due <= now;
}

const archivedKey = (userId: string, at: number) => `archived:${userId}:${at}`;

/**
 * Start over after a reset: MOVE this browser's identity, pins and observed reset for
 * `userId` under an archived key (never deleted, so a mistaken start-over loses
 * nothing), then clear the live entries. Returns the archive key.
 */
export async function archiveDeviceState(store: DeviceKeyValueStore, userId: string, now: number = Date.now()): Promise<string> {
  requireUserId(userId);
  const key = archivedKey(userId, now);
  await store.put(key, {
    archivedAt: now,
    identity: (await store.get(identityKey(userId))) ?? null,
    pins: (await store.get(pinsKey(userId))) ?? null,
    observedReset: (await store.get(observedResetKey(userId))) ?? null,
  });
  await store.delete(identityKey(userId));
  await store.delete(pinsKey(userId));
  await store.delete(observedResetKey(userId));
  return key;
}

/**
 * Forget only this browser's identity keys for `userId`, KEEPING its pins: used after
 * a revocation verified in the signed log, so the browser can re-enroll under a new
 * identity and still refuses a swapped root or a rolled-back log.
 */
export async function forgetDeviceIdentity(store: DeviceKeyValueStore, userId: string): Promise<void> {
  await store.delete(identityKey(requireUserId(userId)));
}

/** Sign UTF-8 text with the device's identity key; returns the signature object JSON text. */
export async function signDeviceText(identity: DeviceIdentity, text: string): Promise<string> {
  return signP256(identity.signPrivateKey, utf8.encode(text));
}

/** base64url (no padding) of a UTF-8 label, the statement form of free text. */
export function labelB64(label: string): string {
  const bytes = utf8.encode(label);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function labelFromB64(b64: string): string {
  try {
    const std = b64.replace(/-/g, '+').replace(/_/g, '/');
    const bin = atob(std + '='.repeat((4 - (std.length % 4)) % 4));
    return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
  } catch {
    return '';
  }
}

/** The statement subject fields describing this device. */
export function deviceSubject(identity: DeviceIdentity, label: string): Statement {
  return {
    type: 'register',
    subject_device_id: identity.deviceId,
    subject_kind: identity.kind,
    subject_sign_pub: identity.signPub,
    subject_ecdh_pub: identity.ecdhPub,
    subject_sign_alg: identity.signAlg,
    subject_wrap_alg: identity.wrapAlg,
    subject_label_b64: labelB64(label),
  };
}

// ── pins ─────────────────────────────────────────────────────────────────────

/**
 * What this device has verified about the account directory: the root, and the head
 * of the signed log (seq + entry hash). A later directory must keep the root and
 * EXTEND this head (vaultDirectoryVerify checks the op at head_seq hashes to
 * head_hash), so a rollback or a fork is refused.
 */
export interface DevicePins {
  readonly root_device_id: string;
  readonly root_sign_pub: string;
  readonly head_seq: number;
  readonly head_hash: string;
  readonly max_epoch: number;
}

export class PinViolationError extends Error {
  constructor(reason: string) {
    super(`Vault directory refused: ${reason}`);
    this.name = 'PinViolationError';
  }
}

function isPins(v: unknown): v is DevicePins {
  const p = v as DevicePins;
  return Boolean(p) && typeof p.root_device_id === 'string' && isLowerHex(p.root_sign_pub, 65)
    && Number.isSafeInteger(p.head_seq) && p.head_seq >= 1 && isLowerHex(p.head_hash, 32) && Number.isSafeInteger(p.max_epoch);
}

export async function loadPins(store: DeviceKeyValueStore, userId: string): Promise<DevicePins | null> {
  const v = await store.get(pinsKey(requireUserId(userId)));
  if (v === undefined || v === null) return null;
  if (!isPins(v)) throw new PinViolationError('stored pins are malformed');
  return v;
}

/**
 * Throws PinViolationError when `next` swaps the root or moves the head/epoch
 * backwards. (That the log EXTENDS the pinned head is checked by verifyDirectory,
 * which holds every op hash.)
 */
export function checkAgainstPins(pins: DevicePins | null, next: DevicePins): void {
  if (!pins) return;
  if (next.root_device_id !== pins.root_device_id || next.root_sign_pub !== pins.root_sign_pub) {
    throw new PinViolationError('the account root differs from the pinned root');
  }
  if (next.head_seq < pins.head_seq) throw new PinViolationError('directory log rolled back');
  if (next.head_seq === pins.head_seq && next.head_hash !== pins.head_hash) throw new PinViolationError('directory log forked from the pinned head');
  if (next.max_epoch < pins.max_epoch) throw new PinViolationError('epoch rolled back');
}

/** Advance the pins to a verified head (never backwards; refuses a root change). */
export async function advancePins(store: DeviceKeyValueStore, userId: string, next: DevicePins): Promise<DevicePins> {
  const current = await loadPins(store, userId);
  checkAgainstPins(current, next);
  const merged: DevicePins = {
    root_device_id: next.root_device_id,
    root_sign_pub: next.root_sign_pub,
    head_seq: next.head_seq,
    head_hash: next.head_hash,
    max_epoch: Math.max(current?.max_epoch ?? 0, next.max_epoch),
  };
  await store.put(pinsKey(userId), merged);
  await rememberPinnedUser(store, userId);
  return merged;
}

// ── accounts seen on this browser (finding M2) ──────────────────────────────
//
// Identity and pins are keyed per user id, so a hub that changes the /me user id
// would silently get a fresh, unpinned TOFU (genesis or account confirmation) on an
// established browser. This browser therefore remembers every user id it pinned; a
// different id never gets AUTOMATIC genesis/confirmation — the user is warned and
// must explicitly accept it as their other account.

const PINNED_USERS_KEY = 'pinned-users';
const otherAccountAckKey = (userId: string) => `other-account-ack:${userId}`;

async function pinnedUsers(store: DeviceKeyValueStore): Promise<string[]> {
  const v = await store.get(PINNED_USERS_KEY);
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];
}

async function rememberPinnedUser(store: DeviceKeyValueStore, userId: string): Promise<void> {
  const users = await pinnedUsers(store);
  if (!users.includes(userId)) await store.put(PINNED_USERS_KEY, [...users, userId]);
}

/**
 * The other account ids this browser already holds pins for, when `userId` has none
 * and the user has not explicitly accepted it. Empty: no warning is needed.
 */
export async function otherPinnedAccounts(store: DeviceKeyValueStore, userId: string): Promise<string[]> {
  requireUserId(userId);
  if (await store.get(pinsKey(userId))) return [];
  if (await store.get(otherAccountAckKey(userId))) return [];
  return (await pinnedUsers(store)).filter((u) => u !== userId);
}

/** The user explicitly accepted `userId` as a separate account on this browser. */
export async function acknowledgeOtherAccount(store: DeviceKeyValueStore, userId: string): Promise<void> {
  await store.put(otherAccountAckKey(requireUserId(userId)), true);
}
