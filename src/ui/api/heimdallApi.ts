import { createApi, fakeBaseQuery, setupListeners } from '@reduxjs/toolkit/query/react';

export const HEIMDALL_TAG_TYPES = [
  'planLimitReached',
  'TaskLog',
  'Task',
  'TaskComments',
  'ChainTasks',
  'Chain',
  'ChainList',
  'Chat',
  'GuideChat',
  'CoordinatorChat',
  'ConversationSummaries',
  'Agents',
  'AgentTemplate',
  'AgentInstances',
  'Memory',
  'Project',
  'Projects',
  'Workspace',
  'WorkspaceDiff',
  'Artifact',
  'ArtifactContent',
  'ArtifactVersions',
  'ArtifactAnnotations',
  'Preferences',
  'UserTokens',
  'Attention',
  'BridgeSupport',
  'ChainFleets',
  'ChainMembers',
  'Bridges',
  'BridgeProviders',
  'ProjectBridgePaths',
  // Provider extension (ham.ext.v1): timeline events/rollups and the in-memory agent
  // blockers (permission cards), per instance id.
  'ExtensionEvents',
  'AgentBlockers',
  // Project Directory Browser: project-scoped FS listings, keyed by (project, bridge, path).
  'ProjectFs',
  // VCS Integration: project-scoped VCS capabilities/status/changed-files/diff,
  // keyed by (project, bridge[, file]).
  'ProjectVcs',
  'InstanceFs',
  // UI-14: cookie-auth sidebar data owned by the live shell.
  'SidebarConversations',
  'SidebarProjects',
  'Actions',
  'Action',
  'Cards',
  'Card',
  'BridgeFigWorkspaces',
  'WorkflowDefinitions',
  'ShellSessions',
  'ShellSession',
  'Experiments',
  'LspServerConfigs',
  'Issue',
  'IssueComments',
  'TaskChainFleets',
] as const;

type QueryError = {
  status: string;
  error: string;
};

function queryError(error: any): QueryError & { message: string } {
  return {
    status: 'CUSTOM_ERROR',
    error: String(error?.message || error || 'Request failed'),
    message: String(error?.message || error || 'Request failed'),
  } as any;
}

function hasOwn(value: any, key: string): boolean {
  return Boolean(value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, key));
}

function sessionWithRequestOverrides(session: any, arg: any) {
  if (!arg || typeof arg !== 'object') return session || {};
  const next = { ...(session || {}) };
  if (hasOwn(arg, 'daemonUrl')) next.daemonUrl = arg.daemonUrl;
  if (hasOwn(arg, 'clientToken')) next.clientToken = arg.clientToken;
  if (hasOwn(arg, 'clientInstanceId')) next.clientInstanceId = arg.clientInstanceId;
  return next;
}

export function withSessionQuery<Arg, Result>(
  run: (arg: Arg, context: { state: any; session: any }) => Promise<Result>,
) {
  return async (arg: Arg, api: { getState: () => unknown }) => {
    const state = api.getState() as any;
    const session = sessionWithRequestOverrides(state?.chat?.session || {}, arg);
    try {
      return { data: await run(arg, { state, session }) };
    } catch (error: any) {
      return { error: queryError(error) };
    }
  };
}

export const heimdallApi = createApi({
  reducerPath: 'heimdallApi',
  baseQuery: fakeBaseQuery<QueryError>(),
  tagTypes: [...HEIMDALL_TAG_TYPES],
  keepUnusedDataFor: 30,
  refetchOnReconnect: true,
  endpoints: () => ({}),
});

export function setupHeimdallApiListeners(dispatch: Parameters<typeof setupListeners>[0]) {
  setupListeners(dispatch);
}
