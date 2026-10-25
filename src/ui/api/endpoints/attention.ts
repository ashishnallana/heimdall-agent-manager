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
//
// kind 'agent_blocker' items are LIVE agent blockers (a provider permission
// prompt, or a prompt detected in the agent terminal) that the hub merges in
// from its in-memory map at read time. They are the only permission-approval
// surface: Allow / Deny call POST /agent-instances/{id}/blockers/{id}/resolve.
import { cookieJsonFetch, customQueryError } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';

export type AttentionRange = '6h' | '24h' | '7d' | 'all';
export type AttentionKind = 'message' | 'task' | 'memory' | 'agent_blocker';
export const ATTENTION_RANGES: readonly AttentionRange[] = ['6h', '24h', '7d', 'all'];

/** total = message + task + memory + agent_blocker (the bar pill); snoozed is separate and never in total. */
export type AttentionCounts = { total: number; older: number; message: number; task: number; memory: number; snoozed: number; agent_blocker: number };

export type AttentionExcerpt = { author_name: string; body: string; at: string };

export type AttentionTaskDetails = {
  priority: string;
  status: string;
  bridge_id: string;
  assignee_name: string;
  excerpt: AttentionExcerpt | null;
  /** Task System v2: why the task needs the user. */
  attention?: 'review' | 'blocked';
  /** review | gate | question | agent_not_running | merge_conflict | budget_exhausted | oscillation */
  badge?: string;
  state?: string;
  task_kind?: string;
  attempt_no?: number;
  /** Identity of the block a blocked card shows; sent back with Answer. */
  block_id?: string;
  holder_instance_id?: string;
};

export type AttentionMessageDetails = {
  excerpt: AttentionExcerpt;
  options: string[];
  other_unread: number;
};

/** A memory proposal. title/description/body may be vault ciphertext. */
export type AttentionMemoryDetails = {
  type: string;
  title: string;
  description: string;
  body: string;
  expires_at: string;
  proposer_name: string;
};

/** Who/what a memory applies to, by name (names may be ciphertext). [] = all. */
export type AttentionScope = { agents: string[]; projects: string[]; bridges: string[]; templates: string[] };

/** A live agent blocker (never stored). input is the capped tool input object. */
export type AttentionBlockerDetails = {
  blocker_kind: 'permission' | 'terminal_prompt';
  tool_name: string;
  summary: string;
  input: Record<string, unknown>;
  agent_id: string;
  agent_instance_id: string;
  created_at: string;
  expires_at: string;
};

export type AttentionTaskRefs = { chain_id: string; task_id: string };
/** chain_id is '' for an instance outside any chain. */
export type AttentionBlockerRefs = { agent_instance_id: string; chain_id: string; blocker_id: string };
export type AttentionMemoryRefs = { memory_id: string; agent_instance_id: string; chain_id: string };
export type AttentionMessageRefs = { conversation_id: string; agent_instance_id: string; message_id: string };

type AttentionItemBase = {
  card_id: string;
  provider: string;
  reason: string;
  urgency: 'error' | 'warn' | 'info';
  status: string;
  /** In the Snoozed tab: its snooze is still running (snooze_until '' = until woken). */
  snoozed: boolean;
  snooze_until: string;
  attention_since: string;
  /** May be vault ciphertext; render through the vault helpers. */
  title: string;
  rationale: string;
  primary_op: string | null;
  operations: Array<{ op: string; label?: string }>;
  context: { chain_title: string; agent_name: string; project_name: string; scope?: AttentionScope };
};

export type AttentionTaskItem = AttentionItemBase & { kind: 'task'; details: AttentionTaskDetails; action_refs: AttentionTaskRefs };
export type AttentionMessageItem = AttentionItemBase & { kind: 'message'; details: AttentionMessageDetails; action_refs: AttentionMessageRefs };
export type AttentionMemoryItem = AttentionItemBase & { kind: 'memory'; details: AttentionMemoryDetails; action_refs: AttentionMemoryRefs };
export type AttentionBlockerItem = AttentionItemBase & { kind: 'agent_blocker'; details: AttentionBlockerDetails; action_refs: AttentionBlockerRefs };
export type AttentionItem = AttentionTaskItem | AttentionMessageItem | AttentionMemoryItem | AttentionBlockerItem;

export type AttentionSummary = { since: AttentionRange; counts: AttentionCounts };
export type AttentionResult = AttentionSummary & { items: AttentionItem[] };

export const EMPTY_ATTENTION_COUNTS: AttentionCounts = { total: 0, older: 0, message: 0, task: 0, memory: 0, snoozed: 0, agent_blocker: 0 };
const EMPTY_COUNTS = EMPTY_ATTENTION_COUNTS;

export function normalizeAttentionCounts(raw: any): AttentionCounts {
  const n = (v: any) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);
  if (!raw || typeof raw !== 'object') return { ...EMPTY_COUNTS };
  return { total: n(raw.total), older: n(raw.older), message: n(raw.message), task: n(raw.task), memory: n(raw.memory), snoozed: n(raw.snoozed), agent_blocker: n(raw.agent_blocker) };
}

/** Keeps only well-formed items of the kinds v1 renders. */
export function normalizeAttentionItems(raw: any): AttentionItem[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((item: any) =>
      item && typeof item.card_id === 'string' && (item.kind === 'task' || item.kind === 'message' || item.kind === 'memory' || item.kind === 'agent_blocker') &&
      item.details && typeof item.details === 'object' && item.action_refs && typeof item.action_refs === 'object')
    .map((item: any) => ({ ...item, snoozed: item.snoozed === true, snooze_until: typeof item.snooze_until === 'string' ? item.snooze_until : '' }));
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
