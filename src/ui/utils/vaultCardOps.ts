// Card operations (plan P4 backlog): the hub EXECUTES a card's operations on accept,
// so the fields it acts on (ids, status, result, scope, type, ...) stay in clear, but
// the content fields it only STORES are sealed. Mirrors ham-ctl CARD_OP_SEALED_FIELDS
// (src/ctl/vault.odin).

import {
  containsVaultArmored,
  decryptVaultText,
  encryptVaultText,
  getActiveVaultKey,
  isVaultArmored,
  VAULT_LOCKED_MARKER,
  VAULT_OTHER_VAULT_MARKER,
  type VaultKeyring,
} from './vaultCrypto.ts';
import { resolveCopyableVaultText } from './vaultContent.ts';

export const CARD_OP_SEALED_FIELDS: Readonly<Record<string, readonly string[]>> = Object.freeze({
  'issue.create': ['title', 'description'],
  'memory.create': ['title', 'body', 'description', 'evidence'],
  'memory.update': ['title', 'body', 'description', 'evidence'],
  'project.update': ['name', 'description'],
});

type Op = { op?: string; args?: Record<string, unknown>; [k: string]: unknown };

async function mapFields(op: Op, fn: (v: string) => Promise<string>): Promise<Op> {
  const fields = CARD_OP_SEALED_FIELDS[String(op?.op ?? '')] ?? [];
  if (fields.length === 0) return op;
  const out: Op = { ...op };
  const apply = async (obj: Record<string, unknown>) => {
    for (const f of fields) if (typeof obj[f] === 'string' && obj[f] !== '') obj[f] = await fn(obj[f] as string);
  };
  await apply(out);
  if (out.args && typeof out.args === 'object') {
    out.args = { ...out.args };
    await apply(out.args);
  }
  return out;
}

/** Seal the store-only content fields of each operation (throws without a keyring). */
export async function sealCardOperations<T extends Op>(ops: readonly T[] | undefined): Promise<T[] | undefined> {
  if (!ops) return undefined;
  const kr = getActiveVaultKey();
  if (!kr) throw new Error('Vault key unavailable: card content cannot be encrypted');
  return Promise.all(ops.map((op) => mapFields(op, (v) => (isVaultArmored(v) ? Promise.resolve(v) : encryptVaultText(v, kr))) as Promise<T>));
}

/** Decrypt sealed operation fields for display; anything that does not open shows the locked marker. */
export async function openCardOperations<T extends Op>(ops: readonly T[] | undefined): Promise<T[] | undefined> {
  if (!ops) return undefined;
  const kr = getActiveVaultKey();
  return Promise.all(ops.map((op) => mapFields(op, async (v) => {
    if (!isVaultArmored(v)) return v;
    if (!kr) return VAULT_LOCKED_MARKER;
    try {
      return await decryptVaultText(v, kr);
    } catch {
      return VAULT_LOCKED_MARKER;
    }
  }) as Promise<T>));
}

/** Display name for a card whose title is missing or cannot be decrypted. */
export const UNTITLED_CARD = 'Untitled card';

/**
 * Plaintext card title for text that leaves the render tree: feedback messages sent to
 * agents and toasts. The title is sealed like any other vault field, so
 * interpolating `card.title` directly leaks its ciphertext (and a chat message built from
 * it is re-encrypted on send, persisting the token as the message's "plaintext").
 *
 * Returns the decrypted title, or `fallback` when the title is missing or does not open
 * with `keyring` (locked, wrong or previous vault, corrupt). Never returns a vault token.
 */
export async function resolveCardTitle(
  title: string | null | undefined,
  fallback: string = UNTITLED_CARD,
  keyring: VaultKeyring | null = getActiveVaultKey(),
): Promise<string> {
  if (!title) return fallback;
  if (!containsVaultArmored(title)) return title;
  if (!keyring) return fallback;
  const plain = await resolveCopyableVaultText(title, keyring);
  if (plain.includes(VAULT_LOCKED_MARKER) || plain.includes(VAULT_OTHER_VAULT_MARKER)) return fallback;
  return plain;
}
