import type { VaultKeyring } from '../../utils/vaultKeyring.ts';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  decryptList,
  getActiveVaultKey,
} from '../../utils/vaultContent.ts';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';

export interface VaultTextModelProps {
  value?: string | null;
  fallback?: string;
  as?: 'span' | 'p' | 'div';
  className?: string;
  onUnlockClick?: () => void;
  title?: string;
}

export type VaultTextMode = 'plaintext' | 'locked' | 'unlocked';

export interface VaultTextResolved {
  mode: VaultTextMode;
  isArmored: boolean;
  displayText: string;
  dataDebugId?: string;
  isLocked: boolean;
}

/**
 * Pure function to resolve VaultText state and placeholder configuration.
 */
export function resolveVaultText(
  value: string | null | undefined,
  isUnlocked: boolean,
  fallback = '',
): VaultTextResolved {
  const raw = value ?? '';
  const armored = isVaultArmored(raw);
  if (!armored) {
    return {
      mode: 'plaintext',
      isArmored: false,
      displayText: raw || fallback,
      isLocked: false,
    };
  }
  if (!isUnlocked) {
    return {
      mode: 'locked',
      isArmored: true,
      displayText: 'Encrypted content',
      dataDebugId: 'vault-locked-placeholder',
      isLocked: true,
    };
  }
  return {
    mode: 'unlocked',
    isArmored: true,
    displayText: raw,
    isLocked: false,
  };
}

/**
 * Async decryption helper for vault armored text strings.
 *
 * `key` accepts a non-extractable CryptoKey (the hardened path), a 64-char hex
 * string (legacy/tests), or null. It defaults to the module-held active vault
 * key, so callers no longer need to thread key material through props or state
 * (REQ-RAWKEY-A5).
 */
export async function decryptVaultTextContent(
  value: string | null | undefined,
  key?: VaultKeyring | null,
  fallback = '',
): Promise<string> {
  // Omitting `key` resolves the active vault key; passing an explicit null still
  // means "no key available", which existing callers rely on for the locked state.
  const resolvedKey = key === undefined ? getActiveVaultKey() : key;
  const raw = value ?? '';
  if (!isVaultArmored(raw)) return raw || fallback;
  if (!resolvedKey) return fallback || '[Locked content]';
  return await decryptVaultText(raw, resolvedKey);
}

export interface DecryptedMarkdownResolved {
  text: string;
  isArmored: boolean;
  isLocked: boolean;
}

/**
 * Pure helper function to resolve DecryptedMarkdown content reactively.
 *
 * `key` follows the same contract as decryptVaultTextContent: CryptoKey, hex
 * string, or null, defaulting to the active vault key (REQ-RAWKEY-A5).
 */
export async function resolveDecryptedMarkdownContent(
  source: string | null | undefined,
  key: VaultKeyring | null | undefined,
  isUnlocked: boolean,
  fallback = '',
): Promise<DecryptedMarkdownResolved> {
  // See decryptVaultTextContent: undefined => active key, explicit null => no key.
  const resolvedKey = key === undefined ? getActiveVaultKey() : key;
  const raw = source ?? '';
  const isArmored = isVaultArmored(raw);
  const isEmbedded = !isArmored && containsVaultArmored(raw);
  const hasVault = isArmored || isEmbedded;

  if (!hasVault) {
    return {
      text: raw || fallback,
      isArmored: false,
      isLocked: false,
    };
  }

  if (!isUnlocked || !resolvedKey) {
    return {
      text: replaceVaultTokens(raw, '[🔒 Encrypted]'),
      isArmored: true,
      isLocked: true,
    };
  }

  const decrypted = isArmored
    ? await decryptVaultText(raw, resolvedKey)
    : await decryptEmbeddedVaultTokens(raw, resolvedKey);

  return {
    text: replaceVaultTokens(decrypted, '[🔒 Encrypted]'),
    isArmored: true,
    isLocked: false,
  };
}

export {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  decryptList,
};
