/**
 * Aux tab codec (Jetski `auxPaneV2/store/tabId.ts` equivalent).
 *
 * Every aux tab id is DERIVED from its content by this single codec, never
 * generated at random. That keeps ids deterministic (opening the same thing
 * focuses the existing tab), URL-safe and persistable.
 *
 *   chainOverview            -> 'overview'                 (fixed)
 *   files                    -> 'files'                    (fixed)
 *   vcs                      -> 'vcs'                      (fixed)
 *   tasks                    -> 'tasks'                    (fixed)
 *   shell {sessionId}        -> 'shell__<sessionId>'       (one interactive shell per tab; a fresh tab
 *                                                           uses a unique provisional 'new-<nonce>' id, rekeyed
 *                                                           to the real session once started, so several new
 *                                                           shell tabs can coexist)
 *   agentPty {agentId}       -> 'pty__<agentInstanceId>'
 *   preview {session, port}  -> 'preview__<sessionId>:<port>' (or 'preview__<sessionId>' when the port is unknown)
 *   subagentChat {agentId}   -> 'subagent_convo__<agentInstanceId>'
 *
 * `__` separates the type tag from the payload; payloads are embedded
 * verbatim, so decoding is by prefix only. Transient parameters (a file path to
 * open, a task to focus, ...) live on the content but never in the id.
 */

export const NEW_TAB_ID = 'newTab__empty';

export const AUX_TAB_KINDS = [
  'chainOverview',
  'files',
  'vcs',
  'tasks',
  'shell',
  'agentPty',
  'preview',
  'subagentChat',
] as const;

export type AuxTabKind = (typeof AUX_TAB_KINDS)[number];

export type AuxContent =
  | { type: 'chainOverview' }
  | {
      type: 'files';
      /** Transient: a file/dir to reveal once the explorer mounts. */
      path?: string | null;
      /** Transient: open the search-in-files drawer once. */
      openSearch?: boolean;
      /** Transient: open the command palette once. */
      openCommandPalette?: boolean;
    }
  | { type: 'vcs'; filePath?: string | null }
  | { type: 'tasks'; taskId?: string }
  | { type: 'shell'; sessionId: string; bridgeId?: string; cwd?: string }
  | { type: 'agentPty'; agentInstanceId: string }
  | { type: 'preview'; sessionId: string; port?: number; path?: string }
  | { type: 'subagentChat'; agentInstanceId: string };

export interface AuxTab {
  /** Content-derived id, see {@link auxTabId}. */
  id: string;
  content: AuxContent;
  /** Optional display title override (e.g. a server label). */
  title?: string;
}

/** Fixed (payload-less) ids. */
export const OVERVIEW_TAB_ID = 'overview';
export const FILES_TAB_ID = 'files';
export const VCS_TAB_ID = 'vcs';
export const TASKS_TAB_ID = 'tasks';

/** Provisional shell session sentinel: the tab is rekeyed once a session is bound. */
export const NEW_SHELL_SESSION_ID = 'new';

/** True for an unbound (not yet started) shell tab session id. */
export function isProvisionalShellSessionId(sessionId: string | null | undefined): boolean {
  const id = typeof sessionId === 'string' ? sessionId.trim() : '';
  return !id || id === NEW_SHELL_SESSION_ID || id.startsWith(`${NEW_SHELL_SESSION_ID}-`);
}

/**
 * Content for a NEW interactive shell tab. Each call yields a distinct
 * provisional id, so every "New shell" opens its own tab instead of focusing
 * an existing one.
 */
export function newShellTabContent(extra: { bridgeId?: string; cwd?: string } = {}): AuxContent {
  const nonce = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
  return { type: 'shell', sessionId: `${NEW_SHELL_SESSION_ID}-${nonce}`, ...extra };
}

const TAB_ID_PREFIXES = {
  shell: 'shell__',
  agentPty: 'pty__',
  preview: 'preview__',
  subagentChat: 'subagent_convo__',
} as const;

const FIXED_TAB_IDS: Record<string, AuxContent> = {
  [OVERVIEW_TAB_ID]: { type: 'chainOverview' },
  [FILES_TAB_ID]: { type: 'files' },
  [VCS_TAB_ID]: { type: 'vcs' },
  [TASKS_TAB_ID]: { type: 'tasks' },
};

function clean(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/** Canonical aux tab id for a piece of content. */
export function auxTabId(content: AuxContent): string {
  switch (content.type) {
    case 'chainOverview':
      return OVERVIEW_TAB_ID;
    case 'files':
      return FILES_TAB_ID;
    case 'vcs':
      return VCS_TAB_ID;
    case 'tasks':
      return TASKS_TAB_ID;
    case 'shell':
      return `${TAB_ID_PREFIXES.shell}${clean(content.sessionId) || NEW_SHELL_SESSION_ID}`;
    case 'agentPty':
      return `${TAB_ID_PREFIXES.agentPty}${clean(content.agentInstanceId)}`;
    case 'preview': {
      const sessionId = clean(content.sessionId);
      const port = Number(content.port);
      return Number.isFinite(port) && port > 0
        ? `${TAB_ID_PREFIXES.preview}${sessionId}:${port}`
        : `${TAB_ID_PREFIXES.preview}${sessionId}`;
    }
    case 'subagentChat':
      return `${TAB_ID_PREFIXES.subagentChat}${clean(content.agentInstanceId)}`;
  }
}

/** True if `id` is one of the fixed, payload-less tab ids. */
export function isFixedAuxTabId(id: string | null | undefined): boolean {
  return Boolean(id && Object.prototype.hasOwnProperty.call(FIXED_TAB_IDS, id));
}

/**
 * Decodes a tab id back into its identity content. Returns null for
 * `NEW_TAB_ID`, empty payloads and unknown ids.
 */
export function decodeAuxTabId(id: string | null | undefined): AuxContent | null {
  if (!id || id === NEW_TAB_ID) return null;
  if (isFixedAuxTabId(id)) return { ...FIXED_TAB_IDS[id] } as AuxContent;
  if (id.startsWith(TAB_ID_PREFIXES.subagentChat)) {
    const agentInstanceId = id.slice(TAB_ID_PREFIXES.subagentChat.length);
    return agentInstanceId ? { type: 'subagentChat', agentInstanceId } : null;
  }
  if (id.startsWith(TAB_ID_PREFIXES.shell)) {
    const sessionId = id.slice(TAB_ID_PREFIXES.shell.length);
    return sessionId ? { type: 'shell', sessionId } : null;
  }
  if (id.startsWith(TAB_ID_PREFIXES.agentPty)) {
    const agentInstanceId = id.slice(TAB_ID_PREFIXES.agentPty.length);
    return agentInstanceId ? { type: 'agentPty', agentInstanceId } : null;
  }
  if (id.startsWith(TAB_ID_PREFIXES.preview)) {
    const payload = id.slice(TAB_ID_PREFIXES.preview.length);
    if (!payload) return null;
    const sep = payload.lastIndexOf(':');
    if (sep > 0) {
      const port = Number(payload.slice(sep + 1));
      if (Number.isFinite(port) && port > 0) {
        return { type: 'preview', sessionId: payload.slice(0, sep), port };
      }
    }
    return { type: 'preview', sessionId: payload };
  }
  return null;
}

/** Structural validation for persisted / external content. */
export function isAuxContent(value: unknown): value is AuxContent {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  switch (v.type) {
    case 'chainOverview':
    case 'files':
    case 'vcs':
    case 'tasks':
      return true;
    case 'shell':
    case 'preview':
      return clean(v.sessionId).length > 0;
    case 'agentPty':
    case 'subagentChat':
      return clean(v.agentInstanceId).length > 0;
    default:
      return false;
  }
}

/** Creates a normalized tab (id derived from content). */
export function createAuxTab(content: AuxContent, title?: string): AuxTab {
  const normalized = normalizeAuxContent(content);
  const tab: AuxTab = { id: auxTabId(normalized), content: normalized };
  const t = clean(title);
  if (t) tab.title = t;
  return tab;
}

export function normalizeAuxContent(content: AuxContent): AuxContent {
  switch (content.type) {
    case 'shell':
      return {
        ...content,
        sessionId: clean(content.sessionId) || NEW_SHELL_SESSION_ID,
      };
    case 'preview':
      return {
        ...content,
        sessionId: clean(content.sessionId),
        ...(content.path !== undefined
          ? { path: String(content.path || '').replace(/^\/+/, '') }
          : {}),
      };
    case 'agentPty':
    case 'subagentChat':
      return { ...content, agentInstanceId: clean(content.agentInstanceId) };
    default:
      return { ...content };
  }
}

export interface AuxTabDescriptor {
  kind: AuxTabKind;
  label: string;
  shortLabel: string;
  description: string;
  multiInstance: boolean;
}

export const AUX_TAB_REGISTRY: Record<AuxTabKind, AuxTabDescriptor> = {
  chainOverview: {
    kind: 'chainOverview',
    label: 'Chain Overview',
    shortLabel: 'Overview',
    description: 'Task chain agents, attention, tasks, artifacts and changes.',
    multiInstance: false,
  },
  files: {
    kind: 'files',
    label: 'Files',
    shortLabel: 'Files',
    description: 'Browse the project, chain, or agent directory tree and edit files.',
    multiInstance: false,
  },
  vcs: {
    kind: 'vcs',
    label: 'VCS & Diffs',
    shortLabel: 'VCS',
    description: 'Inspect working tree status, commit history, and diffs.',
    multiInstance: false,
  },
  tasks: {
    kind: 'tasks',
    label: 'Tasks',
    shortLabel: 'Tasks',
    description: 'Inspect and manage tasks, dependencies, and deliverables in the chain.',
    multiInstance: false,
  },
  shell: {
    kind: 'shell',
    label: 'Interactive Shell',
    shortLabel: 'Shell',
    description: 'Start a new interactive terminal on the agent bridge.',
    multiInstance: true,
  },
  agentPty: {
    kind: 'agentPty',
    label: 'Agent Terminal (PTY)',
    shortLabel: 'PTY',
    description: 'Live streaming PTY terminal of the agent.',
    multiInstance: true,
  },
  preview: {
    kind: 'preview',
    label: 'Web Preview',
    shortLabel: 'Preview',
    description: 'Preview a running server port.',
    multiInstance: true,
  },
  subagentChat: {
    kind: 'subagentChat',
    label: 'Sub-agent Chat',
    shortLabel: 'Sub-agent',
    description: 'Chat with another participant of the task chain.',
    multiInstance: true,
  },
};

/** Default human title for a tab (the strip renders this). */
export function auxTabTitle(tab: Pick<AuxTab, 'content' | 'title'>): string {
  const explicit = clean(tab.title);
  if (explicit) return explicit;
  const c = tab.content;
  switch (c.type) {
    case 'shell':
      return isProvisionalShellSessionId(c.sessionId)
        ? 'Shell'
        : `Shell (${c.sessionId.slice(0, 8)})`;
    case 'agentPty':
      return 'Terminal';
    case 'preview':
      return c.port ? `Preview :${c.port}` : `Preview (${c.sessionId.slice(0, 8)})`;
    case 'subagentChat':
      return c.agentInstanceId.slice(0, 12) || 'Sub-agent';
    default:
      return AUX_TAB_REGISTRY[c.type].label;
  }
}

/**
 * Maps legacy `?panel=` deep-link values to aux content.
 */
export function resolveLegacyPanelToAuxContent(
  panel: string | null | undefined,
  params: { filePath?: string | null; taskId?: string | null } = {},
): AuxContent | null {
  switch ((panel || '').trim()) {
    case 'files':
    case 'rundir':
      return { type: 'files', path: params.filePath || null };
    case 'vcs':
      return { type: 'vcs', filePath: params.filePath || null };
    case 'chain':
    case 'chainOverview':
    case 'overview':
      return { type: 'chainOverview' };
    case 'tasks':
      return { type: 'tasks', ...(params.taskId ? { taskId: params.taskId } : {}) };
    default:
      return null;
  }
}

/** Same-origin proxy URL for a preview session. */
export function buildPreviewUrl(sessionId: string, currentPath = ''): string {
  const normalized = String(currentPath || '').replace(/^\/+/, '');
  return `/api/v1/preview/${encodeURIComponent(sessionId)}/${normalized}`;
}
