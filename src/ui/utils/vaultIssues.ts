// Zero-Knowledge Vault Transformers for Issues and Comments
// REQ-VAULT-ISSUES-UI-1

import type { VaultKeyring } from './vaultKeyring.ts';
import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';

export interface IssuePayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

export interface CommentPayload {
  body: string;
  [key: string]: any;
}

/**
 * Encrypt issue fields (title, description) if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptIssueFields<T extends IssuePayload>(
  payload: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, resolvedKey);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, resolvedKey);
  }
  return res;
}

/**
 * Encrypt comment body if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptCommentFields<T extends CommentPayload>(
  payload: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !payload.body) return { ...payload };
  const res = { ...payload };
  if (!isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, resolvedKey);
  }
  return res;
}

/**
 * Decrypt issue fields (title, description, description_preview, comments) using active CryptoKey or key string.
 */
export async function decryptIssueRecord<T extends IssuePayload>(
  issue: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return issue;
  let title = issue.title;
  let description = issue.description;
  let descriptionPreview = (issue as any).descriptionPreview || (issue as any).description_preview;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, resolvedKey);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, resolvedKey);
    } catch {}
  }
  if (descriptionPreview && isVaultArmored(descriptionPreview)) {
    try {
      descriptionPreview = await decryptVaultText(descriptionPreview, resolvedKey);
    } catch {}
  }

  let comments = (issue as any).comments;
  if (Array.isArray(comments)) {
    comments = await Promise.all(
      comments.map(async (c: any) => {
        if (c.body && isVaultArmored(c.body)) {
          try {
            return { ...c, body: await decryptVaultText(c.body, resolvedKey) };
          } catch {
            return c;
          }
        }
        return c;
      }),
    );
  }

  return {
    ...issue,
    title,
    description,
    descriptionPreview,
    description_preview: descriptionPreview,
    comments,
  };
}

/**
 * Decrypt comment record body using active CryptoKey or key string.
 */
export async function decryptCommentRecord<T extends CommentPayload>(
  comment: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !isVaultArmored(comment.body)) return comment;
  return {
    ...comment,
    body: await decryptVaultText(comment.body, resolvedKey),
  };
}
