// Provider extension (ham.ext.v1) data for the UI: the activity timeline
// (events, subagent and file rollups) and the permission approval cards.
//
//   GET  /api/v1/agent-instances/{id}/extension/events?after_seq=&limit=
//   GET  /api/v1/agent-instances/{id}/extension/subagents
//   GET  /api/v1/agent-instances/{id}/extension/files
//   GET  /api/v1/agent-instances/{id}/permission-requests?status=pending
//   GET  /api/v1/permission-requests?status=pending
//   POST /api/v1/permission-requests/{id}/decision {decision, message?}
//
// Nothing polls. The hub announces changes as resource_changed(agent_instance)
// with change 'extension_events' or 'permission_requests'; wsInvalidation.ts
// invalidates 'ExtensionEvents' (the timeline refetches only events after the
// last seq it holds) and patches the permission caches in place.
import { cookieJsonFetch, cookieMutation, customQueryError } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';
import {
  mergeExtensionEvents,
  normalizeExtensionEvents,
  normalizeFileSummaries,
  normalizeSubagentSummaries,
  type ExtensionEvent,
  type FileSummary,
  type SubagentSummary,
} from '../../components/extension/extensionTimelineModel';
import {
  normalizePermissionRequest,
  normalizePermissionRequests,
  upsertPermissionRequest,
  type PermissionDecision,
  type PermissionRequest,
} from '../../components/extension/permissionCardModel';

export interface ExtensionTimelineData {
  events: ExtensionEvent[];
  subagents: SubagentSummary[];
  files: FileSummary[];
  lastSeq: number;
}

/** Page size for the events endpoint, and how many pages one refetch may walk. */
const EVENTS_PAGE = 500;
const EVENTS_MAX_PAGES = 10;

function instancePath(instanceId: string, leaf: string): string {
  return `/agent-instances/${encodeURIComponent(instanceId)}/${leaf}`;
}

async function fetchEventsAfter(instanceId: string, afterSeq: number): Promise<ExtensionEvent[]> {
  let after = afterSeq;
  let out: ExtensionEvent[] = [];
  for (let page = 0; page < EVENTS_MAX_PAGES; page += 1) {
    const raw = await cookieJsonFetch(`${instancePath(instanceId, 'extension/events')}?after_seq=${after}&limit=${EVENTS_PAGE}`);
    const events = normalizeExtensionEvents(raw);
    out = mergeExtensionEvents(out, events);
    const next = Number(raw?.next_after_seq) || (events.length ? events[events.length - 1].seq : after);
    if (events.length < EVENTS_PAGE || next <= after) break;
    after = next;
  }
  return out;
}

export const extensionApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getExtensionTimeline: build.query<ExtensionTimelineData, string>({
      queryFn: async (instanceId, api) => {
        try {
          // Incremental: refetches after an invalidation only ask for events past
          // the last seq already cached.
          const cached = (extensionApi.endpoints.getExtensionTimeline.select(instanceId)(api.getState() as any) as any)?.data as ExtensionTimelineData | undefined;
          const afterSeq = cached?.lastSeq || 0;
          const [fresh, subagents, files] = await Promise.all([
            fetchEventsAfter(instanceId, afterSeq),
            cookieJsonFetch(instancePath(instanceId, 'extension/subagents')),
            cookieJsonFetch(instancePath(instanceId, 'extension/files')),
          ]);
          const events = mergeExtensionEvents(cached?.events || [], fresh);
          return {
            data: {
              events,
              subagents: normalizeSubagentSummaries(subagents),
              files: normalizeFileSummaries(files),
              lastSeq: events.length ? events[events.length - 1].seq : afterSeq,
            },
          };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: (_r, _e, instanceId) => [{ type: 'ExtensionEvents' as const, id: instanceId }],
    }),
    listInstancePermissionRequests: build.query<PermissionRequest[], string>({
      queryFn: async (instanceId) => {
        try {
          const raw = await cookieJsonFetch(`${instancePath(instanceId, 'permission-requests')}?status=pending`);
          return { data: normalizePermissionRequests(raw) };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: (_r, _e, instanceId) => [{ type: 'PermissionRequests' as const, id: instanceId }],
    }),
    listPendingPermissionRequests: build.query<PermissionRequest[], void>({
      queryFn: async () => {
        try {
          const raw = await cookieJsonFetch('/permission-requests?status=pending&limit=50');
          return { data: normalizePermissionRequests(raw) };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: [{ type: 'PermissionRequests' as const, id: 'LIST' }],
    }),
    decidePermissionRequest: build.mutation<
      { delivered: boolean; permission_request: PermissionRequest | null },
      { id: string; instanceId: string; decision: PermissionDecision; message?: string }
    >({
      queryFn: async ({ id, decision, message }) => {
        try {
          const raw = await cookieMutation(`/permission-requests/${encodeURIComponent(id)}/decision`, 'POST', message ? { decision, message } : { decision });
          return { data: { delivered: Boolean(raw?.delivered), permission_request: normalizePermissionRequest(raw?.permission_request) } };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      // Patch both caches with the outcome instead of refetching; the realtime
      // frame lands the same state for other clients.
      async onQueryStarted({ instanceId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          if (data.permission_request) dispatch(applyPermissionRealtime(instanceId, data.permission_request) as any);
        } catch {
          /* the card shows the error from the mutation result */
        }
      },
    }),
  }),
});

/**
 * Upserts one permission request into the per-instance and owner-wide caches
 * (thunk; used by the realtime handler and the decision mutation). A closed
 * request never reopens (see upsertPermissionRequest).
 */
export function applyPermissionRealtime(instanceId: string, request: PermissionRequest) {
  return (dispatch: any) => {
    const patch = (draft: PermissionRequest[]) => {
      const next = upsertPermissionRequest(draft as PermissionRequest[], request);
      draft.splice(0, draft.length, ...next);
    };
    if (instanceId) dispatch(extensionApi.util.updateQueryData('listInstancePermissionRequests', instanceId, patch as any));
    dispatch(extensionApi.util.updateQueryData('listPendingPermissionRequests', undefined, patch as any));
  };
}

export const {
  useGetExtensionTimelineQuery,
  useListInstancePermissionRequestsQuery,
  useListPendingPermissionRequestsQuery,
  useDecidePermissionRequestMutation,
} = extensionApi;
