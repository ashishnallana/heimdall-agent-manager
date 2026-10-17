// Attention deck v1: the hub's card-backed attention API.
//
//   GET /api/v1/attention/summary?since=   counts only (the always-visible bar)
//   GET /api/v1/attention?since=&kind=     counts + the cards the deck renders
//
// Both carry the 'Attention' tag; the hub's attention_changed WebSocket hint
// invalidates it (coalesced, wsInvalidation.ts). Nothing polls. Exactly one of
// the two is subscribed at a time, so a change costs one request: the summary
// while the deck is closed, the deck's query while it is open (the deck upserts
// its counts into the summary cache, so the bar stays current and closing the
// deck needs no fetch). Opening the deck always revalidates.
import { cookieJsonFetch, customQueryError } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';

export type AttentionRange = '6h' | '24h' | '7d' | 'all';
export type AttentionKind = 'message' | 'task';
export const ATTENTION_RANGES: readonly AttentionRange[] = ['6h', '24h', '7d', 'all'];

export type AttentionCounts = { total: number; older: number; message: number; task: number };

export type AttentionExcerpt = { author_name: string; body: string; at: string };

export type AttentionTaskDetails = {
  priority: string;
  status: string;
  bridge_id: string;
  assignee_name: string;
  excerpt: AttentionExcerpt | null;
};

export type AttentionMessageDetails = {
  excerpt: AttentionExcerpt;
  options: string[];
  other_unread: number;
};

export type AttentionTaskRefs = { chain_id: string; task_id: string };
export type AttentionMessageRefs = { conversation_id: string; agent_instance_id: string; message_id: string };

type AttentionItemBase = {
  card_id: string;
  provider: string;
  reason: string;
  urgency: 'error' | 'warn' | 'info';
  status: string;
  attention_since: string;
  /** May be vault ciphertext; render through the vault helpers. */
  title: string;
  rationale: string;
  primary_op: string | null;
  operations: Array<{ op: string; label?: string }>;
  context: { chain_title: string; agent_name: string; project_name: string };
};

export type AttentionTaskItem = AttentionItemBase & { kind: 'task'; details: AttentionTaskDetails; action_refs: AttentionTaskRefs };
export type AttentionMessageItem = AttentionItemBase & { kind: 'message'; details: AttentionMessageDetails; action_refs: AttentionMessageRefs };
export type AttentionItem = AttentionTaskItem | AttentionMessageItem;

export type AttentionSummary = { since: AttentionRange; counts: AttentionCounts };
export type AttentionResult = AttentionSummary & { items: AttentionItem[] };

const EMPTY_COUNTS: AttentionCounts = { total: 0, older: 0, message: 0, task: 0 };

export function normalizeAttentionCounts(raw: any): AttentionCounts {
  const n = (v: any) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);
  if (!raw || typeof raw !== 'object') return { ...EMPTY_COUNTS };
  return { total: n(raw.total), older: n(raw.older), message: n(raw.message), task: n(raw.task) };
}

/** Keeps only well-formed items of the kinds v1 renders. */
export function normalizeAttentionItems(raw: any): AttentionItem[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((item: any) =>
    item && typeof item.card_id === 'string' && (item.kind === 'task' || item.kind === 'message') &&
    item.details && typeof item.details === 'object' && item.action_refs && typeof item.action_refs === 'object');
}

function attentionQuery(path: string, range: AttentionRange, kind?: AttentionKind) {
  const params = new URLSearchParams({ since: range });
  if (kind) params.set('kind', kind);
  return cookieJsonFetch(`${path}?${params.toString()}`);
}

export const attentionApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getAttentionSummary: build.query<AttentionSummary, { since: AttentionRange }>({
      queryFn: async ({ since }) => {
        try {
          const data = await attentionQuery('/attention/summary', since);
          return { data: { since: (data?.since || since) as AttentionRange, counts: normalizeAttentionCounts(data?.counts) } };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: [{ type: 'Attention' as const, id: 'ALL' }],
      // Paused while the deck is open (the deck's counts are upserted here
      // instead), so the cached value must outlive that pause.
      keepUnusedDataFor: 3600,
    }),
    getAttention: build.query<AttentionResult, { since: AttentionRange; kind?: AttentionKind }>({
      queryFn: async ({ since, kind }) => {
        try {
          const data = await attentionQuery('/attention', since, kind);
          return {
            data: {
              since: (data?.since || since) as AttentionRange,
              counts: normalizeAttentionCounts(data?.counts),
              items: normalizeAttentionItems(data?.items),
            },
          };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: [{ type: 'Attention' as const, id: 'ALL' }],
    }),
  }),
});

export const { useGetAttentionSummaryQuery, useGetAttentionQuery } = attentionApi;
