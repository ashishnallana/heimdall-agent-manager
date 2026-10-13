export const NEW_TAB_ID = 'newTab__empty';

export const WORKBENCH_SURFACE_KINDS = [
  'agentChat',
  'agentPty',
  'shell',
  'preview',
  'files',
  'vcs',
  'chainOverview',
  'tasks',
] as const;

export type WorkbenchSurfaceKind = (typeof WORKBENCH_SURFACE_KINDS)[number];

export interface WorkbenchTabState {
  id: string; // canonical tab ID, e.g. 'agentChat__inst-1', 'agentPty__inst-1', 'shell__sess-1', 'preview__sess-1', 'files', 'vcs', 'chainOverview', 'tasks'
  kind: WorkbenchSurfaceKind;
  title: string;
  agentInstanceId?: string;
  focusMessageId?: string;
  sessionId?: string;
  port?: number;
  bridgeId?: string;
  currentPath?: string;
  openFilePath?: string | null;
  initialOpenSearchInFiles?: boolean;
  initialOpenCommandPalette?: boolean;
  initialFilePath?: string | null;
  focusTaskId?: string;
  closable?: boolean;
}

export type WorkbenchTabSpec = Omit<WorkbenchTabState, 'id' | 'title'> & {
  id?: string;
  title?: string;
};

export interface WorkbenchSurfaceDescriptor {
  kind: WorkbenchSurfaceKind;
  label: string;
  shortLabel: string;
  description: string;
  multiInstance: boolean;
  idPrefix: string;
  defaultTitle: (spec: Partial<WorkbenchTabState>) => string;
}

export const WORKBENCH_SURFACE_REGISTRY: Record<
  WorkbenchSurfaceKind,
  WorkbenchSurfaceDescriptor
> = {
  agentChat: {
    kind: 'agentChat',
    label: 'Agent Chat',
    shortLabel: 'Chat',
    description:
      'Open an agent conversation transcript and message composer in this pane.',
    multiInstance: true,
    idPrefix: 'agentChat__',
    defaultTitle: (spec) =>
      spec.title ||
      (spec.agentInstanceId
        ? `Chat (${spec.agentInstanceId.slice(0, 8)})`
        : 'Agent Chat'),
  },
  agentPty: {
    kind: 'agentPty',
    label: 'Agent Live Terminal (PTY)',
    shortLabel: 'Agent PTY',
    description:
      'View live streaming PTY terminal output for any agent instance.',
    multiInstance: true,
    idPrefix: 'agentPty__',
    defaultTitle: (spec) =>
      spec.title ||
      (spec.agentInstanceId
        ? `PTY (${spec.agentInstanceId.slice(0, 8)})`
        : 'Agent PTY'),
  },
  shell: {
    kind: 'shell',
    label: 'Interactive Shell',
    shortLabel: 'Shell',
    description:
      'Connect to a live bridge shell session or spawn a new interactive terminal.',
    multiInstance: true,
    idPrefix: 'shell__',
    defaultTitle: (spec) =>
      spec.title ||
      (spec.sessionId ? `Shell (${spec.sessionId.slice(0, 8)})` : 'Shell'),
  },
  preview: {
    kind: 'preview',
    label: 'Live Web Preview',
    shortLabel: 'Preview',
    description:
      'Preview a running server port with URL navigation and stdout log toggle.',
    multiInstance: true,
    idPrefix: 'preview__',
    defaultTitle: (spec) =>
      spec.title ||
      (spec.port
        ? `Preview :${spec.port}`
        : spec.sessionId
          ? `Preview (${spec.sessionId.slice(0, 8)})`
          : 'Web Preview'),
  },
  files: {
    kind: 'files',
    label: 'File Explorer & Editor',
    shortLabel: 'Files',
    description:
      'Browse the project, chain, or agent directory tree and edit files.',
    multiInstance: false,
    idPrefix: 'files',
    defaultTitle: (spec) => spec.title || 'Files',
  },
  vcs: {
    kind: 'vcs',
    label: 'VCS & Diffs',
    shortLabel: 'VCS',
    description:
      'Inspect working tree status, commit history, and side-by-side diffs.',
    multiInstance: false,
    idPrefix: 'vcs',
    defaultTitle: (spec) => spec.title || 'VCS & Diffs',
  },
  chainOverview: {
    kind: 'chainOverview',
    label: 'Task Chain Overview',
    shortLabel: 'Chain',
    description:
      'View the multi-agent task chain topology, member roles, and status.',
    multiInstance: false,
    idPrefix: 'chainOverview',
    defaultTitle: (spec) => spec.title || 'Chain Overview',
  },
  tasks: {
    kind: 'tasks',
    label: 'Tasks Board',
    shortLabel: 'Tasks',
    description:
      'Inspect and manage tasks, dependencies, and deliverables in the chain.',
    multiInstance: false,
    idPrefix: 'tasks',
    defaultTitle: (spec) => spec.title || 'Tasks',
  },
};

export function isWorkbenchSurfaceKind(
  value: unknown,
): value is WorkbenchSurfaceKind {
  return (
    typeof value === 'string' &&
    (WORKBENCH_SURFACE_KINDS as readonly string[]).includes(value)
  );
}

/**
 * Builds the canonical tab ID for a given WorkbenchTabSpec.
 */
export function buildWorkbenchTabId(spec: {
  id?: string;
  kind: WorkbenchSurfaceKind;
  agentInstanceId?: string;
  sessionId?: string;
}): string {
  const rawId = typeof spec.id === 'string' ? spec.id.trim() : '';
  if (rawId && rawId !== NEW_TAB_ID) {
    return rawId;
  }
  const safeAgentId =
    typeof spec.agentInstanceId === 'string'
      ? spec.agentInstanceId.trim()
      : '';
  const safeSessionId =
    typeof spec.sessionId === 'string' ? spec.sessionId.trim() : '';

  switch (spec.kind) {
    case 'agentChat': {
      const target = safeAgentId || 'default';
      return `agentChat__${target}`;
    }
    case 'agentPty': {
      const target = safeAgentId || 'default';
      return `agentPty__${target}`;
    }
    case 'shell': {
      const target = safeSessionId || 'new';
      return `shell__${target}`;
    }
    case 'preview': {
      const target = safeSessionId || 'default';
      return `preview__${target}`;
    }
    case 'files':
      return 'files';
    case 'vcs':
      return 'vcs';
    case 'chainOverview':
      return 'chainOverview';
    case 'tasks':
    default:
      return 'tasks';
  }
}

export interface ParsedWorkbenchTabId {
  kind: WorkbenchSurfaceKind;
  targetId?: string;
  agentInstanceId?: string;
  sessionId?: string;
}

/**
 * Parses a canonical workbench tab ID back into its surface kind and entity target ID.
 * Returns null if `tabId` is `NEW_TAB_ID` or unrecognized.
 */
export function parseWorkbenchTabId(
  tabId: string | null | undefined,
): ParsedWorkbenchTabId | null {
  if (!tabId || tabId === NEW_TAB_ID) {
    return null;
  }

  if (tabId === 'files' || tabId.startsWith('files__')) {
    const targetId = tabId.startsWith('files__')
      ? tabId.slice('files__'.length)
      : undefined;
    return { kind: 'files', targetId };
  }
  if (tabId === 'vcs' || tabId.startsWith('vcs__')) {
    const targetId = tabId.startsWith('vcs__')
      ? tabId.slice('vcs__'.length)
      : undefined;
    return { kind: 'vcs', targetId };
  }
  if (tabId === 'chainOverview' || tabId.startsWith('chainOverview__')) {
    const targetId = tabId.startsWith('chainOverview__')
      ? tabId.slice('chainOverview__'.length)
      : undefined;
    return { kind: 'chainOverview', targetId };
  }
  if (tabId === 'tasks' || tabId.startsWith('tasks__')) {
    const targetId = tabId.startsWith('tasks__')
      ? tabId.slice('tasks__'.length)
      : undefined;
    return { kind: 'tasks', targetId };
  }

  if (tabId.startsWith('agentChat__')) {
    const agentInstanceId = tabId.slice('agentChat__'.length);
    return {
      kind: 'agentChat',
      targetId: agentInstanceId,
      agentInstanceId,
    };
  }
  if (tabId.startsWith('agentPty__')) {
    const agentInstanceId = tabId.slice('agentPty__'.length);
    return {
      kind: 'agentPty',
      targetId: agentInstanceId,
      agentInstanceId,
    };
  }
  if (tabId.startsWith('shell__')) {
    const sessionId = tabId.slice('shell__'.length);
    return {
      kind: 'shell',
      targetId: sessionId,
      sessionId,
    };
  }
  if (tabId.startsWith('preview__')) {
    const sessionId = tabId.slice('preview__'.length);
    return {
      kind: 'preview',
      targetId: sessionId,
      sessionId,
    };
  }

  return null;
}

function normalizePreviewPath(path: string | undefined): string | undefined {
  if (path === undefined) return undefined;
  return String(path || '').replace(/^\/+/, '');
}

/**
 * Constructs a normalized `WorkbenchTabState` from a `WorkbenchTabSpec`.
 */
export function createWorkbenchTabState(
  spec: WorkbenchTabSpec,
): WorkbenchTabState {
  const safeKind: WorkbenchSurfaceKind = isWorkbenchSurfaceKind(spec?.kind)
    ? spec.kind
    : 'agentChat';
  const safeAgentInstanceId =
    typeof spec?.agentInstanceId === 'string'
      ? spec.agentInstanceId.trim() || undefined
      : undefined;
  const safeSessionId =
    typeof spec?.sessionId === 'string'
      ? spec.sessionId.trim() || undefined
      : undefined;
  const safeTitle =
    typeof spec?.title === 'string' ? spec.title.trim() : '';

  const normalizedSpec: WorkbenchTabSpec = {
    ...spec,
    kind: safeKind,
  };
  if (safeAgentInstanceId !== undefined) {
    normalizedSpec.agentInstanceId = safeAgentInstanceId;
  } else {
    delete normalizedSpec.agentInstanceId;
  }
  if (safeSessionId !== undefined) {
    normalizedSpec.sessionId = safeSessionId;
  } else {
    delete normalizedSpec.sessionId;
  }
  if (safeTitle) {
    normalizedSpec.title = safeTitle;
  } else {
    delete normalizedSpec.title;
  }

  const id = buildWorkbenchTabId(normalizedSpec);
  const descriptor = WORKBENCH_SURFACE_REGISTRY[safeKind];
  const title =
    safeTitle.length > 0
      ? safeTitle
      : descriptor
        ? descriptor.defaultTitle(normalizedSpec)
        : safeKind;

  const result: WorkbenchTabState = {
    ...normalizedSpec,
    id,
    kind: safeKind,
    title,
    closable: typeof spec?.closable === 'boolean' ? spec.closable : true,
  };

  if (safeKind === 'preview' || spec?.currentPath !== undefined) {
    result.currentPath = normalizePreviewPath(spec?.currentPath) ?? '';
  }

  return result;
}

/**
 * Maps legacy right-sidebar / URL `?panel=` values to canonical `WorkbenchSurfaceKind`.
 */
export function resolveLegacyPanelToSurfaceKind(
  panel: string | null | undefined,
): WorkbenchSurfaceKind | null {
  if (!panel) return null;
  const normalized = panel.trim();
  switch (normalized) {
    case 'files':
    case 'rundir':
      return 'files';
    case 'vcs':
      return 'vcs';
    case 'chain':
    case 'chainOverview':
      return 'chainOverview';
    case 'tasks':
      return 'tasks';
    case 'shells':
    case 'shell':
      return 'shell';
    case 'preview':
      return 'preview';
    case 'agentPty':
    case 'pty':
      return 'agentPty';
    case 'agentChat':
    case 'chat':
      return 'agentChat';
    default:
      return null;
  }
}

/**
 * Same-origin proxy URL helper for a `preview` workbench tab or session.
 */
export function buildWorkbenchPreviewUrl(
  sessionId: string,
  currentPath = '',
): string {
  const normalized = String(currentPath || '').replace(/^\/+/, '');
  return `/api/v1/preview/${encodeURIComponent(sessionId)}/${normalized}`;
}
