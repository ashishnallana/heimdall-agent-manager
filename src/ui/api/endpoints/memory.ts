import { apiErrorText, cookieJsonFetch, cookieJsonFetchEnvelope, cookieMutation } from "../cookieFetch";
import { heimdallApi } from "../heimdallApi";
import { normalizeMemory } from "../memoryCatalog";
import { encryptVaultText, decryptVaultText, isVaultArmored, getActiveVaultKey } from "../../utils/vaultContent";
import { encryptMemoryFields, decryptMemoryRecord } from "../../utils/vaultMemories";
export { type Memory, isMemoryExpired } from "../../components/memory/memoryModel";

// Memory targeting is a LIST per dimension (T1 contract): agent_ids/project_ids/
// bridge_ids/template_ids as JSON string arrays where empty = applies to all.
// The TS API exposes these as camelCase string[] (agentIds/projectIds/
// bridgeIds/templateIds) and sends the snake_case arrays on the wire. The old
// scalar/target_* single-value fields are gone (no back-compat).
export type MemoryTargeting = {
  agentIds?: string[];
  projectIds?: string[];
  bridgeIds?: string[];
  templateIds?: string[];
};

// List FILTERS are one id per dimension, deliberately — and deliberately NOT
// `MemoryTargeting`. The hub's `memory_filter_query` (content_handlers.odin:690-698)
// splits a dimension's value on the first comma and uses ONLY that token, so a
// multi-value filter is silently truncated: sending three ids filters by one. A
// single id per dimension is the honest match to the endpoint. (Writes are a
// different matter — POST/PATCH really do take lists, so `MemoryTargeting` stays
// on the mutation inputs.)
export type MemoryListFilter = {
  status?: string;
  type?: string;
  agentId?: string;
  projectId?: string;
  bridgeId?: string;
  templateId?: string;
};

export type ListMemoriesQueryArg = (MemoryListFilter & {
  limit?: number;
  cursor?: string;
}) | void;

// One page of the list endpoint, in the API's own field names — the shape
// `useInfiniteList` consumes.
export type MemoryPage = {
  items: any[];
  next_cursor: string;
  has_more: boolean;
};

// memoryListPath builds `/memories?…`. A filter matches when the memory's
// dimension list is EMPTY (global) or contains the value (content_service.odin:
// 139-144), so filtering by a project also returns the global memories that apply
// to it. Defaults are expressed by OMITTING the param.
function memoryListPath(arg: (MemoryListFilter & { limit?: number; cursor?: string }) | void | null): string {
  const params = new URLSearchParams();
  if (arg) {
    if (arg.status) params.set("status", arg.status);
    if (arg.type) params.set("type", arg.type);
    if (arg.agentId) params.set("agent_id", arg.agentId);
    if (arg.projectId) params.set("project_id", arg.projectId);
    if (arg.bridgeId) params.set("bridge_id", arg.bridgeId);
    if (arg.templateId) params.set("template_id", arg.templateId);
    if (arg.limit) params.set("limit", String(arg.limit));
    if (arg.cursor) params.set("cursor", arg.cursor);
  }
  const queryString = params.toString();
  return `/memories${queryString ? `?${queryString}` : ""}`;
}

// fetchMemoryPage is the imperative page fetch the infinite list drives. It reads
// the FULL envelope because `has_more` / `next_cursor` live in the `page` sibling
// of `data` (respond_list), which the data-unwrapping fetch strips — and it honours
// an AbortSignal, because changing tab or filters supersedes the page in flight.
export async function fetchMemoryPage(
  args: MemoryListFilter & { limit?: number; cursor?: string; signal?: AbortSignal },
): Promise<MemoryPage> {
  const { signal, ...arg } = args;
  const body = await cookieJsonFetchEnvelope(memoryListPath(arg), { signal });
  const data = body?.data ?? body;
  const page = body?.page ?? {};
  const rawItems = Array.isArray(data) ? data : data?.items || [];
  return {
    items: rawItems.map(normalizeMemory),
    next_cursor: String(page?.next_cursor || ""),
    has_more: Boolean(page?.has_more),
  };
}

// A memory search hit. The search API carries no structured record (search_fts.odin:
// 115-122): `label` is the title (or the type when the title is empty) and
// `sublabel` is "<type> · <status>", so type and status are PARSED back out of it
// and the row renders a reduced shape. `route` is deliberately ignored — it points
// at the legacy `/settings/memory?memory_id=…`.
export type MemoryHit = {
  id: string;
  label: string;
  type: string;
  status: string;
  preview: string;
  matchedField: string;
};

export type MemoryHitPage = {
  items: MemoryHit[];
  next_cursor: string;
  has_more: boolean;
};

function hitFromSearch(raw: any): MemoryHit {
  const sublabel = String(raw?.sublabel || "");
  const [typePart, statusPart] = sublabel.split("·").map((part) => part.trim());
  return {
    id: String(raw?.id || ""),
    label: String(raw?.label || ""),
    type: typePart || "",
    status: statusPart || "",
    preview: String(raw?.preview || raw?.snippet || ""),
    matchedField: String(raw?.matched_field || ""),
  };
}

// searchMemoryPage runs the server-scoped memory search (types=memory). Memory's
// FTS index covers TITLE and BODY only (migrations/030_search_fts_all.sql:155-175),
// and search accepts no status/type/scope facet — which is why an active query
// disregards the tabs and filters.
export async function searchMemoryPage(
  args: { q: string; limit?: number; cursor?: string; signal?: AbortSignal },
): Promise<MemoryHitPage> {
  const query = String(args.q || "").trim();
  if (!query) return { items: [], next_cursor: "", has_more: false };
  const params = new URLSearchParams({ q: query, types: "memory", limit: String(args.limit || 50) });
  if (args.cursor) params.set("cursor", args.cursor);
  const body = await cookieJsonFetchEnvelope(`/search?${params.toString()}`, { signal: args.signal });
  const data = body?.data ?? body;
  const page = body?.page ?? {};
  const groups = Array.isArray(data?.groups) ? data.groups : [];
  const hits = groups
    .filter((group: any) => String(group?.type || "") === "memory")
    .flatMap((group: any) => (Array.isArray(group?.hits) ? group.hits : []));
  return {
    items: hits.map(hitFromSearch).filter((hit: MemoryHit) => Boolean(hit.id)),
    next_cursor: String(page?.next_cursor || ""),
    has_more: Boolean(page?.has_more),
  };
}

export type CreateMemoryInput = {
  title?: string;
  description?: string;
  body?: string;
  evidence?: string;
  type?: string;
  expectedVersion?: number;
  metadataJson?: string;
  sourceTaskId?: string;
  reason?: string;
  status?: string;
  proposalAction?: string;
  memoryId?: string;
} & MemoryTargeting;

export type UpdateMemoryInput = {
  memoryId: string;
  title?: string;
  description?: string;
  body?: string;
  evidence?: string;
  type?: string;
  expectedVersion?: number;
} & MemoryTargeting;

export type ApproveMemoryInput = {
  memoryId?: string;
  proposalId?: string;
  decision?: "approve" | "reject" | string;
  reason?: string;
  title?: string;
  description?: string;
  body?: string;
  evidence?: string;
  type?: string;
} & MemoryTargeting;

// buildTargetingBody maps the camelCase targeting lists to the wire field names,
// emitting an array (possibly empty) only for dimensions the caller provided.
// Empty/blank ids are dropped. Omitting a dimension lets the hub default apply.
function buildTargetingBody(input: MemoryTargeting): Record<string, string[]> {
  const clean = (ids?: string[]) => (ids || []).map((id) => String(id || "").trim()).filter(Boolean);
  const out: Record<string, string[]> = {};
  if (input.agentIds !== undefined) out.agent_ids = clean(input.agentIds);
  if (input.projectIds !== undefined) out.project_ids = clean(input.projectIds);
  if (input.bridgeIds !== undefined) out.bridge_ids = clean(input.bridgeIds);
  if (input.templateIds !== undefined) out.template_ids = clean(input.templateIds);
  return out;
}

// memoryErrorText is the shared `apiErrorText` under the name memory's callers
// already use. The unwrapping is not memory-specific (every queryFn endpoint
// rejects the same way), so it lives in `cookieFetch` and this is a thin alias
// rather than a second copy to keep in step.
export function memoryErrorText(err: unknown, fallback = "Something went wrong"): string {
  return apiErrorText(err, fallback);
}

/**
 * Collapse any surviving `vault:v2:` token to the locked marker.
 *
 * The decrypt above is the real fix and covers every record fetched while the vault
 * is unlocked. This is the guard for the states it cannot reach, and it exists
 * because a memory title is consumed as a plain STRING in several places —
 * `PageShell`'s `<h1>`, a breadcrumb label, an `aria-label`, toast and modal prose —
 * where `VaultText` cannot be used because there is no element to render into.
 *
 * Two states need it. (1) Vault enabled but LOCKED: no key, so the record stays
 * armored by design. (2) The first synchronous render of `useDecryptedText`, whose
 * `useState(raw)` initializer returns the raw value and only masks inside its
 * `useEffect` — so a token is in the committed DOM until effects flush. Brief, but an
 * `aria-label` is exactly where a brief leak goes unnoticed: it is invisible to both
 * a screenshot and a text-content assertion.
 *
 * It is a mask, never a decrypt — it only ever removes information.
 */
// Single definition lives in utils/vaultContent.ts; re-exported here so existing
// `from '../../api/endpoints/memory'` importers keep working.
export { maskVaultArmored } from '../../utils/vaultContent.ts';

export type RejectMemoryInput = {
  memoryId: string;
  reason?: string;
};

export type ArchiveMemoryInput = {
  memoryId: string;
  reason?: string;
};

export const memoryApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listMemories: build.query<any, ListMemoriesQueryArg>({
      queryFn: async (arg) => {
        try {
          const res = await cookieJsonFetch(memoryListPath(arg));
          const rawItems = res?.items || res?.memories || (Array.isArray(res) ? res : []);
          let items = rawItems.map(normalizeMemory);
          // The vault stores title/description/body/evidence armored, so the query
          // layer is the single choke point that has to undo it — mirroring
          // `issues.ts`. Decrypting here (rather than per render site) is what keeps
          // a sibling path from quietly rendering ciphertext.
          const activeKey = getActiveVaultKey();
          if (activeKey) {
            items = await Promise.all(items.map((mem: any) => decryptMemoryRecord(mem, activeKey)));
          }
          return { data: { items, next_cursor: res?.next_cursor || res?.nextCursor || "" } };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      providesTags: (result) => [
        { type: "Memory" as const, id: "ALL" },
        ...((result?.items || []).map((m: any) => ({ type: "Memory" as const, id: String(m.id || m.memoryId) })).filter((t: any) => Boolean(t.id))),
      ],
    }),
    getMemory: build.query<any, { memoryId: string } | string>({
      queryFn: async (arg) => {
        const memoryId = typeof arg === "string" ? arg : arg?.memoryId;
        if (!memoryId) return { data: null };
        try {
          const res = await cookieJsonFetch(`/memories/${encodeURIComponent(memoryId)}`);
          const record = res?.memory || res?.record || res;
          if (!record) return { data: null };
          let memory = normalizeMemory(record);
          const activeKey = getActiveVaultKey();
          if (activeKey) {
            memory = await decryptMemoryRecord(memory, activeKey);
          }
          return { data: memory };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => [
        { type: "Memory" as const, id: typeof arg === "string" ? arg : arg?.memoryId },
      ],
    }),
    createMemory: build.mutation<any, CreateMemoryInput>({
      queryFn: async (payload, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let title = payload.title;
          let description = payload.description;
          let body = payload.body;
          let evidence = payload.evidence;

          if (isUnlocked && activeKey) {
            if (title && !isVaultArmored(title)) {
              title = await encryptVaultText(title, activeKey);
            }
            if (description && !isVaultArmored(description)) {
              description = await encryptVaultText(description, activeKey);
            }
            if (body && !isVaultArmored(body)) {
              body = await encryptVaultText(body, activeKey);
            }
            if (evidence && !isVaultArmored(evidence)) {
              evidence = await encryptVaultText(evidence, activeKey);
            }
          }

          const { agentIds, projectIds, bridgeIds, templateIds, ...rest } = payload;
          const data = await cookieMutation("/memories", "POST", {
            ...rest,
            ...(title !== undefined ? { title } : {}),
            ...(description !== undefined ? { description } : {}),
            ...(body !== undefined ? { body } : {}),
            ...(evidence !== undefined ? { evidence } : {}),
            ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }),
          });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: "Memory" as const, id: "ALL" }],
    }),
    proposeMemory: build.mutation<any, CreateMemoryInput>({
      queryFn: async (payload, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let title = payload.title;
          let description = payload.description;
          let body = payload.body;
          let evidence = payload.evidence;

          if (isUnlocked && activeKey) {
            if (title && !isVaultArmored(title)) {
              title = await encryptVaultText(title, activeKey);
            }
            if (description && !isVaultArmored(description)) {
              description = await encryptVaultText(description, activeKey);
            }
            if (body && !isVaultArmored(body)) {
              body = await encryptVaultText(body, activeKey);
            }
            if (evidence && !isVaultArmored(evidence)) {
              evidence = await encryptVaultText(evidence, activeKey);
            }
          }

          const { agentIds, projectIds, bridgeIds, templateIds, ...rest } = payload;
          const data = await cookieMutation("/memories", "POST", {
            ...rest,
            ...(title !== undefined ? { title } : {}),
            ...(description !== undefined ? { description } : {}),
            ...(body !== undefined ? { body } : {}),
            ...(evidence !== undefined ? { evidence } : {}),
            ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }),
          });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: "Memory" as const, id: "ALL" }],
    }),
    updateMemory: build.mutation<any, UpdateMemoryInput>({
      queryFn: async ({ memoryId, ...payload }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          const { agentIds, projectIds, bridgeIds, templateIds, ...rest } = payload;
          const body: Record<string, any> = { ...rest };
          if (payload.title !== undefined) {
            body.title =
              isUnlocked && activeKey && payload.title && !isVaultArmored(payload.title)
                ? await encryptVaultText(payload.title, activeKey)
                : payload.title;
          }
          if (payload.description !== undefined) {
            body.description =
              isUnlocked && activeKey && payload.description && !isVaultArmored(payload.description)
                ? await encryptVaultText(payload.description, activeKey)
                : payload.description;
          }
          if (payload.body !== undefined) {
            body.body =
              isUnlocked && activeKey && payload.body && !isVaultArmored(payload.body)
                ? await encryptVaultText(payload.body, activeKey)
                : payload.body;
          }
          if (payload.evidence !== undefined) {
            body.evidence =
              isUnlocked && activeKey && payload.evidence && !isVaultArmored(payload.evidence)
                ? await encryptVaultText(payload.evidence, activeKey)
                : payload.evidence;
          }

          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}`, "PATCH", { ...body, ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }) });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { memoryId }) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: memoryId },
      ],
    }),
    approveMemory: build.mutation<any, ApproveMemoryInput>({
      queryFn: async (arg, api) => {
        try {
          const memoryId = arg.memoryId || arg.proposalId || "";
          if (arg.decision === "reject") {
            const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/reject`, "POST", { reason: arg.reason });
            return { data };
          }
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          const { memoryId: _m, proposalId: _p, decision: _d, agentIds, projectIds, bridgeIds, templateIds, ...edits } = arg;
          const body: Record<string, any> = { ...edits };
          if (edits.title !== undefined) {
            body.title =
              isUnlocked && activeKey && edits.title && !isVaultArmored(edits.title)
                ? await encryptVaultText(edits.title, activeKey)
                : edits.title;
          }
          if (edits.description !== undefined) {
            body.description =
              isUnlocked && activeKey && edits.description && !isVaultArmored(edits.description)
                ? await encryptVaultText(edits.description, activeKey)
                : edits.description;
          }
          if (edits.body !== undefined) {
            body.body =
              isUnlocked && activeKey && edits.body && !isVaultArmored(edits.body)
                ? await encryptVaultText(edits.body, activeKey)
                : edits.body;
          }
          if (edits.evidence !== undefined) {
            body.evidence =
              isUnlocked && activeKey && edits.evidence && !isVaultArmored(edits.evidence)
                ? await encryptVaultText(edits.evidence, activeKey)
                : edits.evidence;
          }

          const postBody = { ...body, ...buildTargetingBody({ agentIds, projectIds, bridgeIds, templateIds }) };
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/approve`, "POST", postBody);
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: arg.memoryId || arg.proposalId || "" },
      ],
    }),
    rejectMemory: build.mutation<any, RejectMemoryInput>({
      queryFn: async ({ memoryId, reason }) => {
        try {
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/reject`, "POST", { reason });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { memoryId }) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: memoryId },
      ],
    }),
    archiveMemory: build.mutation<any, ArchiveMemoryInput>({
      queryFn: async ({ memoryId, reason }) => {
        try {
          const data = await cookieMutation(`/memories/${encodeURIComponent(memoryId)}/archive`, "POST", { reason });
          return { data };
        } catch (error: any) {
          return { error: { status: "CUSTOM_ERROR", error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { memoryId }) => [
        { type: "Memory" as const, id: "ALL" },
        { type: "Memory" as const, id: memoryId },
      ],
    }),
  }),
});

export function patchMemoryCachesFromWs(dispatch: any, payload: any) {
  const memoryId = String(payload?.memory_id || payload?.memoryId || payload?.record?.memory_id || payload?.record?.id || "");
  const tags: any[] = [{ type: "Memory", id: "ALL" }];
  if (memoryId) {
    tags.push({ type: "Memory", id: memoryId });
  }
  dispatch(heimdallApi.util.invalidateTags(tags));
}

export const {
  useListMemoriesQuery,
  useGetMemoryQuery,
  useCreateMemoryMutation,
  useProposeMemoryMutation,
  useUpdateMemoryMutation,
  useApproveMemoryMutation,
  useRejectMemoryMutation,
  useArchiveMemoryMutation,
} = memoryApi;

export { encryptMemoryFields, decryptMemoryRecord } from "../../utils/vaultMemories";

