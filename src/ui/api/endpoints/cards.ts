import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { openCardOperations, sealCardOperations } from '../../utils/vaultCardOps';
import { maskVaultArmored } from '../../utils/vaultContent';
export { isCardExpired } from '../../components/cards/CardsPanel';

export type CardStatus = 'pending' | 'accepted' | 'rejected' | 'snoozed' | 'discarded';

export type CardOperation = {
  op: string;
  label?: string;
  args?: Record<string, any>;
  [key: string]: any;
};

/**
 * A source reference / evidence pointer on a card. The hub serializes these as
 * structured objects (e.g. {"type":"task","id":"task_..."}), but older/other
 * providers may emit plain strings, so accept both.
 */
export type CardSourceRef =
  | string
  | { type?: string; id?: string; [key: string]: any };

export type CardGuard = {
  target_type?: string;
  target_id?: string;
  field_conditions?: Record<string, any>;
  expected_version?: number;
  expires_at?: string;
  [key: string]: any;
};

export type Card = {
  card_id: string;
  owner_user_id: string;
  project_id: string;
  title: string;
  rationale: string;
  scope: string;
  provider: string;
  confidence: number;
  source_refs: CardSourceRef[];
  status: CardStatus | string;
  operations: CardOperation[];
  guard?: CardGuard;
  snooze_until?: string;
  ttl_at?: string;
  created_at: string;
  updated_at: string;
};

export type ListCardsQueryArg = {
  projectId?: string;
  status?: string;
  scope?: string;
  provider?: string;
  limit?: number;
} | void;

export type CreateCardInput = {
  project_id?: string;
  title: string;
  rationale?: string;
  scope?: string;
  provider?: string;
  confidence?: number;
  source_refs?: CardSourceRef[];
  operations?: CardOperation[];
  guard?: CardGuard;
  snooze_until?: string;
  ttl_at?: string;
};

export function cardErrorText(err: unknown, fallback = 'Something went wrong'): string {
  if (err == null) return fallback;
  if (typeof err === 'string') return err.trim() || fallback;
  const e = err as any;
  const data = e.data;
  if (data) {
    if (typeof data === 'string' && data.trim()) return data;
    const msg = data?.error?.message || data?.error || data?.message;
    if (typeof msg === 'string' && msg.trim()) return msg;
  }
  const fromError = e.error?.message || e.error;
  if (typeof fromError === 'string' && fromError.trim()) return fromError;
  const fromMessage = e.message;
  if (typeof fromMessage === 'string' && fromMessage.trim()) return fromMessage;
  return fallback;
}

// Arg keys that only carry record ids; `formatOpLabel(op, { withIds: false })` omits them.
const OP_ID_ARGS = new Set(['id', 'memory_id', 'task_id', 'chain_id', 'project_id', 'agent_id', 'instance_id', 'agent_instance_id']);

/**
 * REQ-UX-1: Format human-friendly operation summary.
 * Uses the op's plain-language `label` property if available,
 * or defensively derives a clear human-readable description instead of exposing raw JSON.
 * Vault tokens are masked, never shown; `withIds: false` drops record ids for compact surfaces.
 */
export function formatOpLabel(op: CardOperation, opts: { withIds?: boolean } = {}): string {
  if (op.label && typeof op.label === 'string' && op.label.trim()) {
    return maskVaultArmored(op.label.trim());
  }
  const opName = op.op || 'operation';
  const withIds = opts.withIds ?? true;
  const getArg = (k: string) => {
    if (!withIds && OP_ID_ARGS.has(k)) return '';
    const v = op.args?.[k] ?? op[k] ?? '';
    return typeof v === 'string' ? maskVaultArmored(v) : v;
  };
  switch (opName) {
    case 'memory.delete':
    case 'memory.archive': {
      const mid = getArg('memory_id') || getArg('id');
      return mid ? `Delete memory ${mid}` : 'Delete memory';
    }
    case 'memory.create': {
      const title = getArg('title');
      const type = getArg('type') || 'fact';
      return title ? `Create ${type} memory: "${title}"` : `Create new ${type} memory`;
    }
    case 'memory.update': {
      const mid = getArg('memory_id') || getArg('id');
      const title = getArg('title');
      const target = mid ? `Update memory ${mid}` : 'Update memory';
      return title ? `${target}: "${title}"` : target;
    }
    case 'memory.approve': {
      const mid = getArg('memory_id') || getArg('id');
      return mid ? `Approve memory proposal ${mid}` : 'Approve memory proposal';
    }
    case 'memory.reject': {
      const mid = getArg('memory_id') || getArg('id');
      return mid ? `Reject memory proposal ${mid}` : 'Reject memory proposal';
    }
    case 'issue.create': {
      const title = getArg('title');
      return title ? `Create issue: "${title}"` : 'Create issue';
    }
    case 'task.vote': {
      const tid = getArg('task_id');
      const result = (getArg('result') || 'lgtm').toUpperCase();
      return tid ? `Vote ${result} on task ${tid}` : `Cast task vote (${result})`;
    }
    case 'task_chain.set_status': {
      const cid = getArg('chain_id') || getArg('id');
      const status = getArg('status') || 'completed';
      return cid ? `Set chain ${cid} status to ${status}` : `Update chain status to ${status}`;
    }
    case 'project.update': {
      const name = getArg('name');
      return name ? `Update project settings: "${name}"` : 'Update project settings';
    }
    case 'project.delete': {
      const pid = getArg('project_id') || getArg('id');
      return pid ? `Archive project ${pid}` : 'Archive project';
    }
    case 'agent.update': {
      const aid = getArg('agent_id') || getArg('id');
      return aid ? `Edit agent ${aid}` : 'Edit agent';
    }
    case 'agent.delete': {
      const aid = getArg('agent_id') || getArg('id');
      return aid ? `Archive agent ${aid}` : 'Archive agent';
    }
    case 'agent.prompt': {
      const iid = getArg('instance_id') || getArg('agent_instance_id');
      return iid ? `Dispatch prompt to agent instance ${iid}` : 'Dispatch agent prompt';
    }
    default:
      return `${opName} operation`;
  }
}

/**
 * Render a source reference as a short human string. The hub emits these as
 * {type,id} objects; some providers may emit plain strings. NEVER return a raw
 * object — passing one as a React child throws and blanks the page.
 */
export function formatSourceRef(ref: CardSourceRef): string {
  if (ref == null) return '';
  if (typeof ref === 'string') return ref;
  if (typeof ref === 'object') {
    const type = typeof ref.type === 'string' ? ref.type : '';
    const id = typeof ref.id === 'string' ? ref.id : '';
    if (type && id) return `${type}:${id}`;
    if (id) return id;
    if (type) return type;
    try {
      return JSON.stringify(ref);
    } catch {
      return String(ref);
    }
  }
  return String(ref);
}

/**
 * Coerce an arbitrary operation-arg value into a safe display string. Guards
 * against objects/arrays being rendered directly as React children.
 */
export function toDisplayText(value: unknown): string {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

export const cardsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listCards: build.query<{ cards: Card[] }, ListCardsQueryArg>({
      queryFn: async (arg) => {
        try {
          const params = new URLSearchParams();
          if (arg) {
            if (arg.projectId) params.set('project_id', arg.projectId);
            if (arg.status) params.set('status', arg.status);
            if (arg.scope) params.set('scope', arg.scope);
            if (arg.provider) params.set('provider', arg.provider);
            if (arg.limit) params.set('limit', String(arg.limit));
          }
          const queryStr = params.toString() ? `?${params.toString()}` : '';
          const data = await cookieJsonFetch(`/cards${queryStr}`);
          const raw: Card[] = Array.isArray(data)
            ? data
            : (Array.isArray(data?.data) ? data.data : (data?.cards || []));
          const cards = await Promise.all(raw.map(async (c) => ({ ...c, operations: (await openCardOperations(c.operations)) ?? [] })));
          return { data: { cards } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to list cards') } as any };
        }
      },
      providesTags: (result) => [
        { type: 'Cards' as const, id: 'LIST' },
        ...((result?.cards || []).map((card) => ({ type: 'Card' as const, id: card.card_id }))),
      ],
    }),

    getCard: build.query<{ card: Card | null }, { id?: string; cardId?: string }>({
      queryFn: async (arg) => {
        const id = arg.cardId || arg.id;
        if (!id) return { data: { card: null } };
        try {
          const data = await cookieJsonFetch(`/cards/${encodeURIComponent(id)}`);
          const card = data?.data || data?.card || data || null;
          if (card && Array.isArray(card.operations)) card.operations = await openCardOperations(card.operations);
          return { data: { card } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to get card') } as any };
        }
      },
      providesTags: (_result, _error, arg) => [{ type: 'Card' as const, id: arg.cardId || arg.id || '' }],
    }),

    createCard: build.mutation<Card, CreateCardInput>({
      queryFn: async (input) => {
        try {
          const sealed = input?.operations ? { ...input, operations: await sealCardOperations(input.operations) } : input;
          const card = await cookieMutation('/cards', 'POST', sealed);
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to create card') } as any };
        }
      },
      invalidatesTags: [{ type: 'Cards' as const, id: 'LIST' }],
    }),

    acceptCard: build.mutation<Card, { id?: string; cardId?: string }>({
      queryFn: async (arg) => {
        const id = arg.cardId || arg.id;
        if (!id) return { error: { status: 'CUSTOM_ERROR', error: 'Missing card id' } as any };
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/accept`, 'POST', {});
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to accept card') } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id: arg.cardId || arg.id || '' },
        { type: 'Memory' as const, id: 'LIST' },
        { type: 'Chain' as const, id: 'LIST' },
        { type: 'Task' as const, id: 'LIST' },
      ],
    }),

    rejectCard: build.mutation<Card, { id?: string; cardId?: string }>({
      queryFn: async (arg) => {
        const id = arg.cardId || arg.id;
        if (!id) return { error: { status: 'CUSTOM_ERROR', error: 'Missing card id' } as any };
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/reject`, 'POST', {});
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to reject card') } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id: arg.cardId || arg.id || '' },
      ],
    }),

    discardCard: build.mutation<Card, { id?: string; cardId?: string }>({
      queryFn: async (arg) => {
        const id = arg.cardId || arg.id;
        if (!id) return { error: { status: 'CUSTOM_ERROR', error: 'Missing card id' } as any };
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/discard`, 'POST', {});
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to discard card') } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id: arg.cardId || arg.id || '' },
      ],
    }),

    snoozeCard: build.mutation<Card, { id: string; snoozeUntil: string }>({
      queryFn: async ({ id, snoozeUntil }) => {
        try {
          const card = await cookieMutation(`/cards/${encodeURIComponent(id)}/snooze`, 'POST', { snooze_until: snoozeUntil });
          return { data: card };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: cardErrorText(error, 'Failed to snooze card') } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Cards' as const, id: 'LIST' },
        { type: 'Card' as const, id },
      ],
    }),
  }),
});

export const {
  useListCardsQuery,
  useGetCardQuery,
  useCreateCardMutation,
  useAcceptCardMutation,
  useRejectCardMutation,
  useDiscardCardMutation,
  useSnoozeCardMutation,
} = cardsApi;
