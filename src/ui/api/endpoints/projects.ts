import { heimdallApi } from '../heimdallApi';
import { loadAllProjectPages } from '../projectPagination';
import { apiErrorText, cookieJsonFetch, cookieJsonFetchEnvelope, cookieMutation } from '../cookieFetch';
import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from '../../utils/vaultContent';
import { encryptProjectFields, decryptProjectRecord, decryptProjectList } from '../../utils/vaultProjects';

export type ProjectBridgePath = {
  bridge_id: string;
  path: string;
  is_validated?: boolean;
  last_validated_at?: string;
  validation_error?: string;
};

export type Project = {
  project_id: string;
  name: string;
  description?: string;
  repo_url?: string;
  vcs_kind?: 'none' | 'git' | 'jj' | string;
  default_path: string;
  is_default_conversations?: boolean;
  created_at?: string;
  updated_at?: string;
  bridge_paths?: ProjectBridgePath[];
};

function projectTagId(project: any, fallback = '') {
  return String(project?.project_id || project?.projectId || fallback || '');
}

export const projectsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listProjects: build.query<any, { scope?: string; allPages?: boolean } | void>({
      queryFn: async (_arg, api) => {
        try {
          const allPages = Boolean(_arg && _arg.allPages);
          const data = allPages ? null : await cookieJsonFetch('/projects');
          const rawProjects = allPages
            ? await loadAllProjectPages((cursor) => {
              const params = new URLSearchParams({ limit: '50' });
              if (cursor) params.set('cursor', cursor);
              return cookieJsonFetchEnvelope('/projects?' + params.toString());
            })
            : Array.isArray(data) ? data : (data?.projects || []);
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const projects = (isUnlocked && activeKey)
            ? await decryptProjectList(rawProjects, activeKey)
            : rawProjects;
          return { data: { projects } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (result) => [
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
        ...((result?.projects || []).map((project: any) => ({ type: 'Project' as const, id: projectTagId(project) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchProject: build.query<any, { projectId: string; scope?: string }>({
      queryFn: async ({ projectId }, api) => {
        if (!projectId) return { data: { project: null, bridge_paths: [] } };
        try {
          const data = await cookieJsonFetch(`/projects/${encodeURIComponent(projectId)}`);
          let project = data?.project || data;
          const bridge_paths = project?.bridge_paths || data?.bridge_paths || [];
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          if (project && isUnlocked && activeKey) {
            project = await decryptProjectRecord(project, activeKey);
          }
          return { data: { project: { ...project, bridge_paths }, bridge_paths } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId }) => [{ type: 'Project' as const, id: projectId }],
    }),
    createProject: build.mutation<any, { name: string; description?: string; repo_url?: string; vcs_kind?: string; default_path?: string }>({
      queryFn: async (payload, api) => {
        try {
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          let name = payload.name;
          let description = payload.description;

          if (isUnlocked && activeKey) {
            if (name && !isVaultArmored(name)) {
              name = await encryptVaultText(name, activeKey);
            }
            if (description && !isVaultArmored(description)) {
              description = await encryptVaultText(description, activeKey);
            }
          }

          const body = {
            ...payload,
            name,
            ...(description !== undefined ? { description } : {}),
          };
          const data = await cookieMutation('/projects', 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
      ],
    }),
    updateProject: build.mutation<any, { projectId: string; name?: string; description?: string; repo_url?: string; vcs_kind?: string; default_path?: string }>({
      queryFn: async ({ projectId, ...payload }, api) => {
        try {
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          let name = payload.name;
          let description = payload.description;

          if (isUnlocked && activeKey) {
            if (name !== undefined && !isVaultArmored(name)) {
              name = await encryptVaultText(name, activeKey);
            }
            if (description !== undefined && !isVaultArmored(description)) {
              description = await encryptVaultText(description, activeKey);
            }
          }

          const body: any = { ...payload };
          if (name !== undefined) body.name = name;
          if (description !== undefined) body.description = description;

          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
      ],
    }),
    // The project destructive verb. There is NO delete route for projects
    // (`wiring.odin:316-323`): archive is the soft-delete, it does not cascade to
    // chains/tasks/instances (`project_service.odin:242-244`), and the hub exposes
    // no way back — `Update_Project_Input` carries no `state` field, so nothing in
    // this API can un-archive.
    archiveProject: build.mutation<any, { projectId: string }>({
      queryFn: async ({ projectId }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/archive`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
      ],
    }),
    setProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string; path: string }>({
      queryFn: async ({ projectId, bridgeId, path }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}`, 'PUT', { path });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'ProjectBridgePaths' as const, id: projectId },
      ],
    }),
    deleteProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: async ({ projectId, bridgeId }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'ProjectBridgePaths' as const, id: projectId },
      ],
    }),
    validateProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: async ({ projectId, bridgeId }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}/validate`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
      ],
    }),
  }),
});

export const {
  useListProjectsQuery,
  useFetchProjectQuery,
  useCreateProjectMutation,
  useArchiveProjectMutation,
  useUpdateProjectMutation,
  useSetProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  useValidateProjectBridgePathMutation,
} = projectsApi;

/* ------------------------------------------------------------------ *
 * The rebuilt Projects pages' data layer
 * ------------------------------------------------------------------ *
 * `useListProjectsQuery` above loads EVERY project in one unpaginated request and
 * is still what the sidebar and the launch modal want. The list page needs the
 * opposite: keyset pages it can scroll (REQ-UI-6), an abortable fetch, and the
 * `page` envelope, so it uses the two imperative helpers below instead.
 */

/** A project as the pages use it: camelCase, every field present, never undefined. */
export type ProjectRecord = {
  projectId: string;
  name: string;
  slug: string;
  description: string;
  repoUrl: string;
  vcsKind: string;
  defaultPath: string;
  /** `active` | `archived` (`domain.project_state_string`). */
  state: string;
  project_type?: 'local' | 'fig' | string;
  workspace_name?: string;
  relative_path?: string;
  projectType?: string;
  workspaceName?: string;
  relativePath?: string;
  updatedAt: string;
  /** Detail-only: the list endpoint never sends these. */
  bridgePaths: ProjectBridgePath[];
};

/**
 * Normalises a wire project.
 *
 * Note what is NOT here: `created_at` and `owner_user_id`. `write_project_json`
 * (`project_handlers.odin:77-79`) serialises neither — even though the list's
 * cursor IS `created_at` — so the pages have exactly one timestamp to show, and
 * per Amendment 6 they render no Created field rather than a permanent blank.
 */
export function normalizeProject(raw: any): ProjectRecord {
  const src = raw?.project || raw || {};
  const paths = Array.isArray(src.bridge_paths) ? src.bridge_paths : Array.isArray(raw?.bridge_paths) ? raw.bridge_paths : [];
  const projectType = String(src.project_type || src.projectType || 'local');
  const workspaceName = String(src.workspace_name || src.workspaceName || '');
  const relativePath = String(src.relative_path || src.relativePath || '');
  return {
    projectId: String(src.project_id || src.projectId || ''),
    name: String(src.name || ''),
    slug: String(src.slug || ''),
    description: String(src.description || ''),
    repoUrl: String(src.repo_url || src.repoUrl || ''),
    vcsKind: String(src.vcs_kind || src.vcsKind || ''),
    defaultPath: String(src.default_path || src.defaultPath || ''),
    state: String(src.state || 'active'),
    project_type: projectType,
    workspace_name: workspaceName,
    relative_path: relativePath,
    projectType,
    workspaceName,
    relativePath,
    updatedAt: String(src.updated_at || src.updatedAt || ''),
    bridgePaths: paths.map((entry: any) => ({
      bridge_id: String(entry?.bridge_id || entry?.bridgeId || ''),
      path: String(entry?.path || ''),
      is_validated: Boolean(entry?.is_validated ?? entry?.isValidated),
      last_validated_at: String(entry?.last_validated_at || entry?.lastValidatedAt || ''),
      validation_error: String(entry?.validation_error || entry?.validationError || ''),
    })),
  };
}

export type ProjectPage = {
  items: ProjectRecord[];
  next_cursor: string;
  has_more: boolean;
};

/**
 * One keyset page of projects.
 *
 * Reads the FULL envelope because `has_more` / `next_cursor` live in the `page`
 * sibling of `data`, which the data-unwrapping fetch strips; honours the abort
 * signal `useInfiniteList` hands it.
 *
 * The endpoint takes `limit` and `cursor` and NOTHING else
 * (`project_handlers.odin:15-25`) — no `state`, no `vcs_kind`, no facet of any
 * kind. That is why the list page's tab and filter are applied in the browser.
 */
export async function fetchProjectPage(
  args: { limit?: number; cursor?: string; signal?: AbortSignal } = {},
): Promise<ProjectPage> {
  const params = new URLSearchParams({ limit: String(args.limit || 50) });
  if (args.cursor) params.set('cursor', args.cursor);
  const body = await cookieJsonFetchEnvelope(`/projects?${params.toString()}`, { signal: args.signal });
  const data = body?.data ?? body;
  const rawItems = Array.isArray(data) ? data : data?.items || data?.projects || [];
  const page = body?.page ?? {};
  return {
    items: rawItems.map(normalizeProject),
    next_cursor: String(page?.next_cursor || ''),
    has_more: Boolean(page?.has_more),
  };
}

/**
 * A project search hit. The search API returns no structured record, so a hit is a
 * label plus a sublabel: `name` and `"<slug> · <vcs_kind>"`
 * (`search_repo_sqlite.odin:708-711`). There is **no state on a hit**, so — exactly
 * as on Memory — a search result is a navigation target and nothing else: no
 * checkbox, no verbs. `route` is ignored; it points at `/settings/projects/<id>`.
 */
export type ProjectHit = {
  id: string;
  label: string;
  slug: string;
  vcsKind: string;
  preview: string;
};

export type ProjectHitPage = {
  items: ProjectHit[];
  next_cursor: string;
  has_more: boolean;
};

function projectHitFrom(raw: any): ProjectHit {
  const sublabel = String(raw?.sublabel || '');
  const [slugPart, vcsPart] = sublabel.split('·').map((part) => part.trim());
  return {
    id: String(raw?.id || ''),
    label: String(raw?.label || ''),
    slug: slugPart || '',
    vcsKind: vcsPart || '',
    preview: String(raw?.preview || raw?.snippet || ''),
  };
}

/**
 * The server-scoped project search (`types=project`, G-2).
 *
 * It matches name, project_id, slug, repo_url and vcs_kind — **not description**
 * (`search_repo_sqlite.odin:708-722`), which is why the search placeholder names
 * what is searchable instead of letting a miss read as a broken search.
 */
export async function searchProjectPage(
  args: { q: string; limit?: number; cursor?: string; signal?: AbortSignal },
): Promise<ProjectHitPage> {
  const query = String(args.q || '').trim();
  if (!query) return { items: [], next_cursor: '', has_more: false };
  const params = new URLSearchParams({ q: query, types: 'project', limit: String(args.limit || 50) });
  if (args.cursor) params.set('cursor', args.cursor);
  const body = await cookieJsonFetchEnvelope(`/search?${params.toString()}`, { signal: args.signal });
  const data = body?.data ?? body;
  const page = body?.page ?? {};
  const groups = Array.isArray(data?.groups) ? data.groups : [];
  const hits = groups
    .filter((group: any) => String(group?.type || '') === 'project')
    .flatMap((group: any) => (Array.isArray(group?.hits) ? group.hits : []));
  return {
    items: hits.map(projectHitFrom).filter((hit: ProjectHit) => Boolean(hit.id)),
    next_cursor: String(page?.next_cursor || ''),
    has_more: Boolean(page?.has_more),
  };
}

/** Human-readable text for anything a project mutation rejects with. */
export function projectErrorText(err: unknown, fallback = 'Something went wrong'): string {
  return apiErrorText(err, fallback);
}

export { encryptProjectFields, decryptProjectRecord, decryptProjectList } from '../../utils/vaultProjects';
