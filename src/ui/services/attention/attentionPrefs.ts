// Per-user attention deck preferences (localStorage). The `heimdall:` prefix puts
// the key under APP_STORAGE_PREFIXES, so it is cleared on logout.
import { ATTENTION_RANGES, type AttentionRange } from '../../api/endpoints/attention';

export const ATTENTION_RANGE_KEY = 'heimdall:attention:range';
export const DEFAULT_ATTENTION_RANGE: AttentionRange = '24h';

export function readAttentionRange(storage: Pick<Storage, 'getItem'> | undefined = globalThis.localStorage): AttentionRange {
  try {
    const raw = storage?.getItem(ATTENTION_RANGE_KEY);
    return (ATTENTION_RANGES as readonly string[]).includes(raw ?? '') ? (raw as AttentionRange) : DEFAULT_ATTENTION_RANGE;
  } catch {
    return DEFAULT_ATTENTION_RANGE;
  }
}

export function writeAttentionRange(range: AttentionRange, storage: Pick<Storage, 'setItem'> | undefined = globalThis.localStorage): void {
  try {
    storage?.setItem(ATTENTION_RANGE_KEY, range);
  } catch {
    /* private mode / quota: the choice simply does not persist */
  }
}

export const ATTENTION_RANGE_LABELS: Record<AttentionRange, string> = { '6h': '6h', '24h': '24h', '7d': '7d', all: 'All time' };
