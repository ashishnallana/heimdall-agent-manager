import type { VaultKeyring } from './vaultKeyring.ts';
import { isVaultArmored, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';
import type { SearchItem } from '../store/searchTitleSlice.ts';

export const SEARCH_DECRYPT_BATCH_SIZE = 50;

export interface RawSearchItemInput {
  id: string;
  type: 'chain' | 'conversation';
  rawTitle?: string;
  title?: string;
  decryptedTitle?: string;
  projectId?: string;
  status?: string;
  updatedAt?: string;
  [key: string]: any;
}

const yieldEventLoop = (): Promise<void> =>
  new Promise<void>((resolve) => {
    if (typeof setImmediate === 'function') {
      setImmediate(resolve);
    } else {
      setTimeout(resolve, 0);
    }
  });

export async function decryptSearchTitle(
  rawTitle: string,
  activeKey?: VaultKeyring | null,
): Promise<string> {
  if (!rawTitle) return '';
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !isVaultArmored(rawTitle)) return rawTitle;
  try {
    return await decryptVaultText(rawTitle, resolvedKey);
  } catch {
    return rawTitle;
  }
}

export async function batchDecryptTitles(
  items: RawSearchItemInput[],
  activeKey?: VaultKeyring | null,
  batchSize: number = SEARCH_DECRYPT_BATCH_SIZE,
): Promise<SearchItem[]> {
  if (!items || items.length === 0) {
    return [];
  }

  const resolvedKey = activeKey || getActiveVaultKey();
  const results: SearchItem[] = [];

  for (let i = 0; i < items.length; i += batchSize) {
    if (i > 0) {
      await yieldEventLoop();
    }
    const chunk = items.slice(i, i + batchSize);
    const decryptedChunk = await Promise.all(
      chunk.map(async (item): Promise<SearchItem> => {
        const rawTitle = String(item.rawTitle ?? item.title ?? '');
        let decryptedTitle = rawTitle;
        if (resolvedKey && isVaultArmored(rawTitle)) {
          try {
            decryptedTitle = await decryptVaultText(rawTitle, resolvedKey);
          } catch {
            decryptedTitle = rawTitle;
          }
        } else if (item.decryptedTitle && !isVaultArmored(item.decryptedTitle)) {
          decryptedTitle = item.decryptedTitle;
        }

        return {
          id: String(item.id),
          type: item.type,
          rawTitle,
          decryptedTitle,
          projectId: item.projectId,
          status: item.status,
          updatedAt: item.updatedAt,
        };
      }),
    );
    results.push(...decryptedChunk);
  }

  return results;
}
