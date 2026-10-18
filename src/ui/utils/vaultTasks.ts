// Zero-Knowledge Vault Transformers for Tasks and Task Comments
// REQ-VAULT-TASKS-1

import type { VaultKeyring } from './vaultKeyring.ts';
import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  getActiveVaultKey,
} from './vaultContent.ts';

export interface TaskPayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

export interface TaskCommentPayload {
  body: string;
  [key: string]: any;
}

/**
 * Encrypt task fields (title, description) if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptTaskFields<T extends TaskPayload>(
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
 * Encrypt task comment body if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptTaskCommentFields<T extends TaskCommentPayload>(
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
 * Decrypt task fields (title, description, last_comment_preview) using active CryptoKey or key string.
 */
export async function decryptTaskRecord<T extends TaskPayload>(
  task: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return task;
  let title = task.title;
  let description = task.description;

  if (title) {
    if (isVaultArmored(title)) {
      try {
        title = await decryptVaultText(title, resolvedKey);
      } catch {}
    } else if (containsVaultArmored(title)) {
      try {
        title = await decryptEmbeddedVaultTokens(title, resolvedKey);
      } catch {}
    }
  }
  if (description) {
    if (isVaultArmored(description)) {
      try {
        description = await decryptVaultText(description, resolvedKey);
      } catch {}
    } else if (containsVaultArmored(description)) {
      try {
        description = await decryptEmbeddedVaultTokens(description, resolvedKey);
      } catch {}
    }
  }

  // Also decrypt comment summary if present
  let commentSummary = (task as any).comment_summary || (task as any).commentSummary;
  if (commentSummary && typeof commentSummary === 'object') {
    const preview = commentSummary.last_comment_preview || commentSummary.lastCommentPreview;
    if (preview) {
      if (isVaultArmored(preview)) {
        try {
          const decryptedPreview = await decryptVaultText(preview, resolvedKey);
          commentSummary = {
            ...commentSummary,
            last_comment_preview: decryptedPreview,
            lastCommentPreview: decryptedPreview,
          };
        } catch {}
      } else if (containsVaultArmored(preview)) {
        try {
          const decryptedPreview = await decryptEmbeddedVaultTokens(preview, resolvedKey);
          commentSummary = {
            ...commentSummary,
            last_comment_preview: decryptedPreview,
            lastCommentPreview: decryptedPreview,
          };
        } catch {}
      }
    }
  }

  return {
    ...task,
    title,
    description,
    ...(commentSummary ? { comment_summary: commentSummary, commentSummary } : {}),
  };
}

/**
 * Decrypt task comment record body using active CryptoKey or key string.
 */
export async function decryptTaskCommentRecord<T extends TaskCommentPayload>(
  comment: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || (!isVaultArmored(comment.body) && !containsVaultArmored(comment.body))) return comment;
  try {
    const decrypted = isVaultArmored(comment.body)
      ? await decryptVaultText(comment.body, resolvedKey)
      : await decryptEmbeddedVaultTokens(comment.body, resolvedKey);
    return {
      ...comment,
      body: decrypted,
    };
  } catch {
    return comment;
  }
}

export async function decryptTaskList<T extends TaskPayload>(
  tasks: T[],
  activeKey?: VaultKeyring | null,
): Promise<T[]> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !Array.isArray(tasks)) return tasks;
  return Promise.all(tasks.map((t) => decryptTaskRecord(t, resolvedKey)));
}

export async function decryptTaskComments<T extends TaskCommentPayload>(
  comments: T[],
  activeKey?: VaultKeyring | null,
): Promise<T[]> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !Array.isArray(comments)) return comments;
  return Promise.all(comments.map((c) => decryptTaskCommentRecord(c, resolvedKey)));
}
