// Zero-Knowledge VaultText Reusable Component & Decryption Hooks
// REQ-VAULT-ISSUES-UI-1
import React, { useState, useEffect } from 'react';
import { useSelector } from 'react-redux';
import {
  selectIsVaultUnlocked,
  selectActiveVaultKey,
} from '../../store/vaultSlice';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  decryptList,
  getActiveVaultKey,
  maskVaultArmored,
} from '../../utils/vaultContent';
import Markdown from '../Markdown';
import Icon from '../Icon';

/**
 * Mask the vault-armored fields of a list of records. Returns the input array
 * untouched when nothing is armored, so referential equality is preserved.
 */
function maskVaultFields<T extends Record<string, any>>(items: T[], fields: string[]): T[] {
  let changed = false;
  const masked = items.map((item) => {
    let next: T | null = null;
    for (const field of fields) {
      const value = item[field];
      if (typeof value === 'string' && containsVaultArmored(value)) {
        next = next ?? ({ ...item } as T);
        (next as Record<string, any>)[field] = maskVaultArmored(value);
      }
    }
    if (next) {
      changed = true;
      return next;
    }
    return item;
  });
  return changed ? masked : items;
}

const VAULT_LIST_FIELDS = ['title', 'description', 'description_preview', 'descriptionPreview'];

export interface VaultTextProps {
  value?: string | null;
  fallback?: string;
  as?: 'span' | 'p' | 'div';
  className?: string;
  title?: string;
}

/**
 * Reusable VaultText component:
 * - If value is unencrypted / not armored, renders plaintext directly.
 * - If value is armored and vault is unlocked, decrypts and renders plaintext.
 * - If value is armored and this device holds no key for it, renders a static
 *   placeholder (data-debug-id='vault-locked-placeholder'). There is no unlock action:
 *   keys arrive only through device approval (passwordless vault).
 */
export function VaultText({
  value,
  fallback = '',
  as = 'span',
  className,
  title,
}: VaultTextProps) {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useSelector(selectActiveVaultKey) || getActiveVaultKey();

  const rawString = value ?? '';
  const isArmored = isVaultArmored(rawString);
  const isEmbedded = !isArmored && containsVaultArmored(rawString);
  const hasVault = isArmored || isEmbedded;

  const [decryptedText, setDecryptedText] = useState<string | null>(null);
  const [isDecrypting, setIsDecrypting] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    if (!hasVault) {
      setDecryptedText(rawString);
      setIsDecrypting(false);
      return;
    }

    const activeKey = activeVaultKey || getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      setDecryptedText(
        isEmbedded ? maskVaultArmored(rawString) : null
      );
      setIsDecrypting(false);
      return;
    }

    setIsDecrypting(true);
    const p = isArmored
      ? decryptVaultText(rawString, activeKey)
      : decryptEmbeddedVaultTokens(rawString, activeKey);
    p.then((decrypted) => {
      if (mounted) {
        setDecryptedText(decrypted);
        setIsDecrypting(false);
      }
    }).catch((err) => {
      if (mounted) {
        console.error('Failed to decrypt vault armored text:', err);
        setDecryptedText(fallback || maskVaultArmored(rawString));
        setIsDecrypting(false);
      }
    });

    return () => {
      mounted = false;
    };
  }, [rawString, hasVault, isArmored, isEmbedded, isUnlocked, activeVaultKey, fallback]);

  const Tag = as;

  // 1. Not armored or embedded: render plaintext directly
  if (!hasVault) {
    return (
      <Tag className={className} title={title}>
        {rawString || fallback}
      </Tag>
    );
  }

  // 2. Vault content and vault is locked
  const activeKey = activeVaultKey || getActiveVaultKey();
  if (!isUnlocked || !activeKey) {
    if (isArmored) {
      return (
        <span
          data-debug-id="vault-locked-placeholder"
          title={title || 'Encrypted with a key this device does not hold'}
          aria-label="Encrypted content"
          className={`inline-flex max-w-full items-center gap-1.5 rounded text-xs font-medium text-muted ${className || ''}`}
        >
          <Icon name="lock" size={12} />
          <span className="truncate">Encrypted content</span>
        </span>
      );
    }
    return (
      <Tag className={className} title={title}>
        {decryptedText !== null ? decryptedText : maskVaultArmored(rawString)}
      </Tag>
    );
  }

  // 3. Vault content and currently decrypting
  if (isDecrypting && decryptedText === null) {
    return (
      <Tag className={`${className || ''} opacity-60 italic`} title={title}>
        {fallback || 'Decrypting...'}
      </Tag>
    );
  }

  // 4. Decrypted: render plaintext
  return (
    <Tag className={className} title={title}>
      {decryptedText !== null ? decryptedText : fallback}
    </Tag>
  );
}

/**
 * Hook to decrypt an individual string value reactively.
 */
export function useDecryptedText(value?: string | null): {
  text: string;
  isArmored: boolean;
  isLocked: boolean;
  isDecrypting: boolean;
} {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useSelector(selectActiveVaultKey) || getActiveVaultKey();
  const raw = value ?? '';
  const isArmored = isVaultArmored(raw);
  const isEmbedded = !isArmored && containsVaultArmored(raw);
  const hasVault = isArmored || isEmbedded;

  // Seed masked, never raw: React commits initial state before effects run, so
  // seeding `raw` paints one frame of vault:v2: ciphertext on every consumer --
  // locked vaults included (iss_18db4e292b0c5b57).
  const [text, setText] = useState<string>(() => (hasVault ? maskVaultArmored(raw) : raw));
  const [isDecrypting, setIsDecrypting] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    if (!hasVault) {
      setText(raw);
      setIsDecrypting(false);
      return;
    }
    const activeKey = activeVaultKey || getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      setText(maskVaultArmored(raw));
      setIsDecrypting(false);
      return;
    }
    setIsDecrypting(true);
    const p = isArmored
      ? decryptVaultText(raw, activeKey)
      : decryptEmbeddedVaultTokens(raw, activeKey);
    p.then((decrypted) => {
      if (mounted) {
        setText(maskVaultArmored(decrypted));
        setIsDecrypting(false);
      }
    }).catch(() => {
      if (mounted) {
        setText(maskVaultArmored(raw));
        setIsDecrypting(false);
      }
    });
    return () => {
      mounted = false;
    };
  }, [raw, isArmored, isEmbedded, hasVault, isUnlocked, activeVaultKey]);

  return {
    text,
    isArmored: hasVault,
    isLocked: hasVault && !isUnlocked,
    isDecrypting,
  };
}

/**
 * Hook to decrypt an array of issue objects reactively when vault is unlocked.
 */
export function useDecryptedIssues<T extends { title?: string; description?: string; description_preview?: string; descriptionPreview?: string }>(
  items: T[],
): T[] {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useSelector(selectActiveVaultKey) || getActiveVaultKey();
  // Same reason as useDecryptedText above: seed masked so no consumer paints a
  // frame of ciphertext before the decryption effect runs.
  const [decryptedList, setDecryptedList] = useState<T[]>(() =>
    maskVaultFields(items, VAULT_LIST_FIELDS),
  );

  useEffect(() => {
    let mounted = true;
    const activeKey = activeVaultKey || getActiveVaultKey();
    if (!isUnlocked || !activeKey || items.length === 0) {
      // Locked or keyless: mask rather than render the armored values. Returning
      // `items` here left ciphertext on screen for as long as the vault stayed locked.
      setDecryptedList(maskVaultFields(items, VAULT_LIST_FIELDS));
      return;
    }

    const hasArmored = items.some(
      (item) =>
        isVaultArmored(item.title) ||
        isVaultArmored(item.description) ||
        isVaultArmored(item.description_preview) ||
        isVaultArmored(item.descriptionPreview),
    );

    if (!hasArmored) {
      setDecryptedList(items);
      return;
    }

    decryptList(
      items,
      ['title', 'description', 'description_preview', 'descriptionPreview'] as (keyof T)[],
      activeKey,
    )
      .then((res) => {
        if (mounted) setDecryptedList(res);
      })
      .catch((err) => {
        console.error('Failed to decrypt issues list:', err);
        if (mounted) setDecryptedList(maskVaultFields(items, VAULT_LIST_FIELDS));
      });

    return () => {
      mounted = false;
    };
  }, [items, isUnlocked, activeVaultKey]);

  return decryptedList;
}

export interface DecryptedMarkdownProps {
  source?: string | null;
  className?: string;
  compact?: boolean;
  copyAll?: boolean;
  'data-debug-id'?: string;
  fallback?: string;
}

/**
 * Reactive Markdown component that decrypts armored or embedded vault tokens in `source`
 * using `useDecryptedText` before rendering with `Markdown`.
 */
export function DecryptedMarkdown({
  source,
  fallback = '',
  ...props
}: DecryptedMarkdownProps) {
  const { text } = useDecryptedText(source ?? '');
  return <Markdown source={text || fallback} {...props} />;
}

export default VaultText;
