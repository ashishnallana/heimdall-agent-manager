// ProjectFilesPanel — the "Files" tab peer to the Task Chain panel.
//
// Project-scoped directory browser for the current conversation's project, built
// against the LOCKED API contract (art_18d23e8bfc65311a). Single-directory
// listing + breadcrumb to project root (not an expand-tree), server-side hidden
// filtering via one toggle, cursor pagination ("Load more"), and the four
// mutations: create file, create dir, rename/move, delete. A read-only bounded
// file view (size cap + type gate) is available by clicking a file.
//
// Cache is keyed by (projectId, bridgeId, path) in projectFs.ts, so navigating or
// mutating only refetches the affected directory.
//
// PHASE-4 FOLLOW-UP (Spec 4.3/6 — list virtualization): large directories are
// currently bounded by the contract's cursor pagination (limit 200 + "Load more"
// via next_cursor/has_more) inside a scroll container, which keeps the mounted
// DOM small in practice. True windowing (react-window/equiv) is deferred because
// the pinned virtualizers require React 19 while this app is on React 18;
// adding one needs either a React-18 compatible virtualizer or a React bump.
// Tracked as a Phase-4 follow-up.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import Editor, { DiffEditor, useMonaco, type OnMount, type DiffOnMount, type EditorProps, type DiffEditorProps } from '@monaco-editor/react';
import { initVimMode, VimMode } from 'monaco-vim';

import MarkdownBody from '../MarkdownBody';
import { highlightToLines, languageForFile, type CodeToken } from '../../utils/codeHighlight';
import { useTheme } from '../../store/themeSlice';
import { LspNoticeBanner } from '../../lsp/LspNoticeBanner';
import { lspServerNoticeKey } from '../../lsp/lspServerNotice';
import { useMonacoLsp } from '../../lsp/useMonacoLsp';
import { Icon, IconButton } from '@ui';
import { VaultText } from '../vault/VaultText';
import { useDialogA11y } from '../ui/composites/useDialogA11y';
import {
  useLazyListProjectDirQuery,
  useLazyReadProjectFileQuery,
  useLazyQuickOpenProjectFilesQuery,
  useCreateProjectFileMutation,
  useCreateProjectDirMutation,
  useMoveProjectPathMutation,
  useDeleteProjectPathMutation,
  useWriteProjectFileMutation,
  useBatchWriteProjectFilesMutation,
  type FsEntry,
  type FsListResult,
  type FsReadFileResult,
  type FsQuickOpenResult,
  type FsScopeArgs,
  type FsSearchScope,
  type ScopedSearchMatch,
} from '../../api/endpoints/projectFs';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useFetchTaskChainDetailQuery, useAddChainDirectoryMutation, type TaskChainDirectory } from '../../api/endpoints/tasks';
import BridgeDirectoryPicker from '../BridgeDirectoryPicker';
import SearchInFilesDrawer from './SearchInFilesDrawer';
import { ProjectCommandPaletteModal } from './ProjectCommandPaletteModal';
import { type EditorCommandContext } from '../../commands/editorCommands';

export type DirectoryItem = {
  id: string; // 'primary' | dir.directoryId | `agent-rundir:${agentInstanceId}`
  label: string;
  path: string;
  bridgeId: string;
  vcsKind?: string;
  isPrimary: boolean;
  kind?: 'primary' | 'chain_directory' | 'agent_run_dir';
  agentInstanceId?: string;
  isReadOnly?: boolean;
};

export function getBridgeDisplay(bridgeId?: string, bridges: any[] = []): { name: string; id: string; isOnline: boolean } {
  const bId = String(bridgeId || '').trim();
  if (!bId) return { name: 'local', id: 'local', isOnline: true };
  const found = (bridges || []).find((b: any) => (b.bridge_id || b.bridgeId) === bId);
  if (found) {
    const name = found.name || found.label || (bId.startsWith('brg_') ? bId.slice(4, 12) : bId);
    return { name, id: bId, isOnline: found.status === 'online' };
  }
  const name = bId.startsWith('brg_') ? bId.slice(4, 12) : bId;
  return { name, id: bId, isOnline: false };
}

export function TaskChainDirectorySelector({
  activeDirectory,
  directories,
  bridges,
  onSelectDirectory,
  debugPrefix = 'project-files',
}: {
  activeDirectory: DirectoryItem;
  directories: DirectoryItem[];
  bridges: any[];
  onSelectDirectory: (dirId: string) => void;
  debugPrefix?: string;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const [coords, setCoords] = useState<{ top: number; left: number }>({ top: 0, left: 0 });
  const containerRef = useRef<HTMLDivElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const dropdownRef = useRef<HTMLDivElement | null>(null);

  const updateCoords = useCallback(() => {
    if (!buttonRef.current || typeof window === 'undefined') return;
    const rect = buttonRef.current.getBoundingClientRect();
    setCoords({
      top: rect.bottom + 4,
      left: Math.max(8, Math.min(rect.left, window.innerWidth - 300)),
    });
  }, []);

  useEffect(() => {
    if (!isOpen) return;
    updateCoords();

    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as Node;
      const inContainer = containerRef.current ? containerRef.current.contains(target) : false;
      const inDropdown = dropdownRef.current ? dropdownRef.current.contains(target) : false;
      if (!inContainer && !inDropdown) {
        setIsOpen(false);
      }
    };

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setIsOpen(false);
      }
    };

    const handleScrollOrResize = () => {
      updateCoords();
    };

    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('keydown', handleKeyDown);
    window.addEventListener('resize', handleScrollOrResize);
    window.addEventListener('scroll', handleScrollOrResize, true);

    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('keydown', handleKeyDown);
      window.removeEventListener('resize', handleScrollOrResize);
      window.removeEventListener('scroll', handleScrollOrResize, true);
    };
  }, [isOpen, updateCoords]);

  const handleToggle = () => {
    updateCoords();
    setIsOpen((prev) => !prev);
  };

  return (
    <div ref={containerRef} className="relative shrink-0">
      <button
        ref={buttonRef}
        data-debug-id="task-chain-directory-selector-btn"
        type="button"
        onClick={handleToggle}
        aria-haspopup="true"
        aria-expanded={isOpen ? 'true' : 'false'}
        title={`Select Directory: ${activeDirectory.label} (${activeDirectory.path || 'root'})`}
        className={`inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-[11.5px] font-medium transition-colors max-w-[160px] sm:max-w-[220px] ${
          isOpen
            ? 'bg-neutral-soft text-primary shadow-xs'
            : 'text-primary hover:bg-neutral-soft'
        }`}
      >
        <Icon name="folder" size={13} className="text-accent shrink-0" />
        <span className="truncate font-semibold"><VaultText value={activeDirectory.label} /></span>
        <Icon name="chevron-down" size={10} className="text-muted shrink-0 ml-0.5" />
      </button>

      {isOpen && typeof document !== 'undefined'
        ? createPortal(
            <div
              ref={dropdownRef}
              data-debug-id="task-chain-directory-dropdown"
              style={{
                position: 'fixed',
                top: coords.top,
                left: coords.left,
                zIndex: 9999,
              }}
              className="w-72 rounded-lg border border-subtle bg-surface-overlay p-1 shadow-overlay text-[12px] flex flex-col gap-0.5 backdrop-blur-sm"
            >
              <div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-wider text-muted border-b border-subtle/50 mb-0.5">
                Directories ({directories.length})
              </div>
              {directories.map((dir) => {
                const isSelected = dir.id === activeDirectory.id;
                const bridgeInfo = getBridgeDisplay(dir.bridgeId, bridges);
                return (
                  <button
                    key={dir.id}
                    data-debug-id={dir.isPrimary ? 'directory-option-primary' : `directory-option-${dir.id}`}
                    type="button"
                    onClick={() => {
                      onSelectDirectory(dir.id);
                      setIsOpen(false);
                    }}
                    className={`flex w-full items-center gap-2 rounded px-2 py-1.5 text-left transition-colors ${
                      isSelected
                        ? 'bg-neutral-soft text-primary font-semibold'
                        : 'text-muted hover:bg-neutral-soft hover:text-primary'
                    }`}
                  >
                    <Icon name="folder" size={14} className={isSelected ? 'text-accent shrink-0' : 'text-muted shrink-0'} />
                    <div className="flex min-w-0 flex-1 flex-col">
                      <div className="flex items-center gap-1.5">
                        <span className="truncate font-medium text-primary"><VaultText value={dir.label} /></span>
                        {dir.isPrimary ? (
                          <span className="rounded bg-accent/15 px-1 py-0.2 text-[9px] font-medium text-accent">primary</span>
                        ) : dir.kind === 'agent_run_dir' ? (
                          <span className="rounded bg-neutral-soft px-1 py-0.2 text-[9px] font-medium text-muted">run dir</span>
                        ) : null}
                      </div>
                      {dir.path ? (
                        <span className="truncate font-mono text-[10px] text-faint">{dir.path}</span>
                      ) : null}
                    </div>
                    <span
                      data-debug-id={`directory-option-bridge-${dir.id}`}
                      className="rounded bg-neutral-soft px-1.5 py-0.5 text-[9.5px] font-mono text-muted shrink-0"
                      title={`Bridge: ${bridgeInfo.name}`}
                    >
                      {bridgeInfo.name}
                    </span>
                    {isSelected ? <Icon name="check" size={13} className="text-accent shrink-0 ml-1" /> : null}
                  </button>
                );
              })}
            </div>,
            document.body
          )
        : null}
    </div>
  );
}

export type EditorTab = {
  path: string;
  content: string;
  initialContent: string;
  isDirty: boolean;
  isNew?: boolean;
  isImage?: boolean;
  mime?: string;
  isUnviewable?: boolean;
  unviewableReason?: string;
};

function getLanguageForMonaco(filePath: string): string {
  const lang = languageForFile(filePath);
  const map: Record<string, string> = {
    bash: 'shell',
    zsh: 'shell',
    sh: 'shell',
    fish: 'shell',
    docker: 'dockerfile',
    yml: 'yaml',
    yaml: 'yaml',
    js: 'javascript',
    ts: 'typescript',
    tsx: 'typescript',
    jsx: 'javascript',
    md: 'markdown',
    markdown: 'markdown',
    py: 'python',
    rb: 'ruby',
    rs: 'rust',
    cs: 'csharp',
    go: 'go',
    json: 'json',
    jsonc: 'json',
    html: 'html',
    xml: 'xml',
    css: 'css',
    scss: 'scss',
    less: 'less',
    sql: 'sql',
    graphql: 'graphql',
    proto: 'protobuf',
    odin: 'c',
    zig: 'c',
    toml: 'ini',
    ini: 'ini',
  };
  return map[lang] || lang || 'plaintext';
}

/**
 * Configures Monaco's built-in TypeScript and JavaScript compiler defaults (REQ-PREVIEW-LSP-1).
 * Sets ReactJSX and NodeJs module resolution so .tsx and .ts files do not trigger false-positive
 * TS17004 ("Cannot use JSX unless the '--jsx' flag is provided") or TS2792 module resolution errors.
 */
export function configureMonacoTypeScriptDefaults(monacoInstance: any) {
  if (!monacoInstance?.languages?.typescript) return;
  const ts = monacoInstance.languages.typescript;
  const compilerOptions = {
    jsx: ts.JsxEmit.ReactJSX,
    moduleResolution: ts.ModuleResolutionKind.NodeJs,
    allowNonTsExtensions: true,
    target: ts.ScriptTarget.Latest,
    allowJs: true,
    esModuleInterop: true,
  };
  ts.typescriptDefaults.setCompilerOptions(compilerOptions);
  ts.javascriptDefaults.setCompilerOptions(compilerOptions);
}

function str(v: any): string {
  return String(v ?? '').trim();
}

// Format all pending line comments into a single markdown chat message, grouped
// by file and ordered by line, with the source line as context.
function formatCommentsMarkdown(comments: FileLineComment[]): string {
  const byPath = new Map<string, FileLineComment[]>();
  for (const c of comments) {
    const list = byPath.get(c.path) || [];
    list.push(c);
    byPath.set(c.path, list);
  }
  const parts: string[] = ['Code review comments:', ''];
  for (const [path, list] of byPath) {
    parts.push(`**${path}**`);
    for (const c of [...list].sort((a, b) => a.line - b.line || a.createdAt - b.createdAt)) {
      if (c.line > 0) {
        parts.push(`- L${c.line}: \`${c.lineText.trim()}\``);
      } else {
        // Line 0 = file/folder-level comment (no specific line).
        parts.push(`- (${c.lineText.trim() || 'general'})`);
      }
      for (const bodyLine of c.body.split('\n')) parts.push(`  > ${bodyLine}`);
    }
    parts.push('');
  }
  return parts.join('\n').trim();
}

// Human-friendly byte size for the entry rows + file viewer header.
function formatBytes(value: number): string {
  const n = Number(value) || 0;
  if (n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const scaled = n / Math.pow(1024, i);
  return `${scaled >= 100 || i === 0 ? Math.round(scaled) : scaled.toFixed(1)} ${units[i]}`;
}

// Compact relative time (falls back to the raw string if unparseable).
function formatModified(iso: string): string {
  const s = str(iso);
  if (!s) return '';
  const t = Date.parse(s);
  if (Number.isNaN(t)) return s;
  const diff = Date.now() - t;
  const min = Math.floor(diff / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  return new Date(t).toLocaleDateString();
}

// Join a project-root-relative dir with a child name.
function joinPath(dir: string, name: string): string {
  return dir ? `${dir}/${name}` : name;
}

// Parent of a project-root-relative path ('' = project root).
function parentPath(path: string): string {
  const clean = str(path).replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx <= 0 ? '' : clean.slice(0, idx);
}

// Basename of a path.
function baseName(path: string): string {
  const clean = str(path).replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx < 0 ? clean : clean.slice(idx + 1);
}

// Subsequence fuzzy match: checks if all characters of pattern appear in text in order.
// Satisfies Duckie recommendation: e.g. 'RTK' matches 'ReducerToolKit.ts'.
export function subsequenceFuzzyMatch(pattern: string, text: string): boolean {
  if (!pattern) return true;
  const p = pattern.toLowerCase();
  const t = text.toLowerCase();
  let pIdx = 0;
  for (let tIdx = 0; tIdx < t.length; tIdx++) {
    if (t[tIdx] === p[pIdx]) {
      pIdx++;
      if (pIdx === p.length) return true;
    }
  }
  return false;
}

// Ranking score for fuzzy search results (higher score = better match)
export function fuzzyMatchScore(pattern: string, text: string): number {
  if (!pattern) return 1;
  const p = pattern.toLowerCase();
  const t = text.toLowerCase();
  const base = baseName(text).toLowerCase();
  if (base === p) return 1000;
  if (base.startsWith(p)) return 500;
  if (base.includes(p)) return 300;
  if (t.includes(p)) return 200;
  if (subsequenceFuzzyMatch(pattern, text)) {
    return 100 - Math.min(text.length - pattern.length, 90);
  }
  return 0;
}

const LIST_LIMIT = 200;

type PendingAction =
  | { kind: 'new-file' }
  | { kind: 'new-dir' }
  | { kind: 'rename'; entry: FsEntry }
  | null;

// A single line comment (UI-local, in-memory), anchored to a file path + line.
export type FileLineComment = {
  id: string;
  path: string; // project-root-relative file path
  line: number; // 1-based
  lineText: string; // snapshot of the source line for message context
  body: string;
  createdAt: number;
};

export type ProjectFilesPanelProps = {
  projectId: string;
  bridgeId?: string;
  chainId?: string;
  directories?: TaskChainDirectory[];
  members?: any[];
  projectName?: string;
  agentInstanceId?: string;
  // Scope key for the in-memory comment store: comments reset when this changes
  // (e.g. switching conversations) so review notes never leak across chats.
  conversationKey?: string;
  // Publish the collected comments as a single chat message. Returns true on
  // success (the panel then clears the local store). Parent owns the send.
  onPublishComments?: (markdown: string) => Promise<boolean>;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
  openFilePath?: string | null;
  onFileOpened?: () => void;
  onOpenQuickOpen?: () => void;
  onOpenSearchInFiles?: () => void;
  initialOpenSearchInFiles?: boolean;
  onSearchDrawerConsumed?: () => void;
  onOpenCommandPalette?: () => void;
  initialOpenCommandPalette?: boolean;
  onCommandPaletteConsumed?: () => void;
};

export default function ProjectFilesPanel({
  projectId,
  bridgeId = '',
  chainId,
  directories: propDirectories,
  members: propMembers,
  projectName,
  agentInstanceId,
  conversationKey = '',
  onPublishComments,
  onClose,
  isMobile = false,
  debugPrefix = 'project-files',
  openFilePath,
  onFileOpened,
  onOpenQuickOpen,
  onOpenSearchInFiles,
  initialOpenSearchInFiles = false,
  onSearchDrawerConsumed,
  onOpenCommandPalette,
  initialOpenCommandPalette = false,
  onCommandPaletteConsumed,
}: ProjectFilesPanelProps) {
  const [listDir] = useLazyListProjectDirQuery();
  const [readFile, readState] = useLazyReadProjectFileQuery();
  const monaco = useMonaco();

  useEffect(() => {
    configureMonacoTypeScriptDefaults(monaco);
  }, [monaco]);

  const [createFile, createFileState] = useCreateProjectFileMutation();
  const [createDir, createDirState] = useCreateProjectDirMutation();
  const [movePath, moveState] = useMoveProjectPathMutation();
  const [deletePath, deleteState] = useDeleteProjectPathMutation();
  const [writeProjectFile, writeState] = useWriteProjectFileMutation();
  const [batchWriteProjectFiles, batchWriteState] = useBatchWriteProjectFilesMutation();
  const { theme } = useTheme();

  // Task Chain Directories & Bridge Resolution (REQ-UI-TASK-CHAIN-DIRECTORY-SELECTOR, REQ-UI-DIRECTORY-BRIDGE-DISPLAY)
  const chainDetailQuery = useFetchTaskChainDetailQuery(
    { chainId: chainId || '' },
    { skip: !chainId, pollingInterval: 120000 }
  );
  const taskChainDirectories: TaskChainDirectory[] = useMemo(() => {
    if (propDirectories && propDirectories.length > 0) return propDirectories;
    return chainDetailQuery.data?.chain?.directories || [];
  }, [propDirectories, chainDetailQuery.data?.chain?.directories]);

  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000 });
  const bridges = useMemo(() => bridgesQuery.data?.bridges || [], [bridgesQuery.data?.bridges]);

  const [activeDirectoryId, setActiveDirectoryId] = useState<string>('primary');
  const [mountedDirIds, setMountedDirIds] = useState<Set<string>>(() => new Set(['primary']));

  // Quick Open Modal state (Cmd+P / Ctrl+P) (REQ-UI-GLOBAL-QUICK-OPEN)
  const [isQuickOpenOpen, setIsQuickOpenOpen] = useState(false);

  // Add Directory Modal state (REQ-UI-ADD-DIRECTORY-MODAL)
  const [isAddDirectoryOpen, setIsAddDirectoryOpen] = useState(false);

  // Scoped Search in Files Drawer state (Cmd+Shift+F / Ctrl+Shift+F) (REQ-SEARCH-UI-PANEL-1, REQ-SEARCH-SHORTCUTS-1)
  const [isSearchDrawerOpen, setIsSearchDrawerOpen] = useState(Boolean(initialOpenSearchInFiles));

  // Editor Command Palette state (Cmd+Shift+P / Ctrl+Shift+P / F1 / >) (REQ-EDITOR-COMMAND-PALETTE-1)
  const [isCommandPaletteOpen, setIsCommandPaletteOpen] = useState(Boolean(initialOpenCommandPalette));
  const [commandPaletteInitialQuery, setCommandPaletteInitialQuery] = useState('');

  const monacoEditorRef = useRef<any>(null);
  const pendingNavigationRef = useRef<{ path: string; line: number; column: number; length: number } | null>(null);

  type DirectorySessionState = {
    openTabs: EditorTab[];
    activeTabPath: string;
    cwd: string;
    isDiffMode: boolean;
  };

  const [directorySessions, setDirectorySessions] = useState<Record<string, DirectorySessionState>>(() => {
    const initial: Record<string, DirectorySessionState> = {};
    const scopeKey = chainId || agentInstanceId || projectId;
    if (typeof window !== 'undefined' && scopeKey) {
      try {
        let primTabs: EditorTab[] = [];
        let primActive = '';
        const primRaw =
          localStorage.getItem(`heimdall:editor:tabs:${scopeKey}:primary`) ||
          (agentInstanceId ? localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`) : null);
        if (primRaw) {
          const parsed = JSON.parse(primRaw);
          if (Array.isArray(parsed?.openTabs)) primTabs = parsed.openTabs;
          else if (Array.isArray(parsed)) primTabs = parsed;
          primActive = typeof parsed?.activeTabPath === 'string' ? parsed.activeTabPath : (primTabs[0]?.path || '');
        }
        let primCwd = '';
        const primTree = agentInstanceId ? localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`) : null;
        if (primTree) {
          const parsed = JSON.parse(primTree);
          if (typeof parsed?.cwd === 'string') primCwd = parsed.cwd;
        }
        initial['primary'] = {
          openTabs: primTabs,
          activeTabPath: primActive,
          cwd: primCwd,
          isDiffMode: false,
        };
      } catch {}
    }
    return initial;
  });

  // Multi-file editor state (REQ-UI-INSTANCE-MONACO-PERSISTENCE, REQ-UI-PER-DIRECTORY-MONACO-INSTANCES)
  const [openTabs, setOpenTabs] = useState<EditorTab[]>(() => {
    if (!agentInstanceId || typeof window === 'undefined') return [];
    try {
      const scopeKey = chainId || agentInstanceId || projectId;
      const raw =
        (scopeKey ? localStorage.getItem(`heimdall:editor:tabs:${scopeKey}:primary`) : null) ||
        localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed?.openTabs)) return parsed.openTabs;
        if (Array.isArray(parsed)) return parsed;
      }
    } catch {}
    return [];
  });
  const [activeTabPath, setActiveTabPath] = useState<string>(() => {
    if (!agentInstanceId || typeof window === 'undefined') return '';
    try {
      const scopeKey = chainId || agentInstanceId || projectId;
      const raw =
        (scopeKey ? localStorage.getItem(`heimdall:editor:tabs:${scopeKey}:primary`) : null) ||
        localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (typeof parsed?.activeTabPath === 'string') return parsed.activeTabPath;
        if (Array.isArray(parsed?.openTabs) && parsed.openTabs.length > 0) return parsed.openTabs[0].path;
        if (Array.isArray(parsed) && parsed.length > 0) return parsed[0].path;
      }
    } catch {}
    return '';
  });
  const [isEditMode, setIsEditMode] = useState<boolean>(() => {
    if (!agentInstanceId || typeof window === 'undefined') return false;
    try {
      const scopeKey = chainId || agentInstanceId || projectId;
      const raw =
        (scopeKey ? localStorage.getItem(`heimdall:editor:tabs:${scopeKey}:primary`) : null) ||
        localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed?.openTabs)) return parsed.openTabs.length > 0;
        if (Array.isArray(parsed)) return parsed.length > 0;
      }
    } catch {}
    return false;
  });
  const [saveFeedback, setSaveFeedback] = useState<{
    type: 'success' | 'warning' | 'error';
    message: string;
  } | null>(null);
  const [confirmClosePath, setConfirmClosePath] = useState<string | null>(null);
  const [openingInEditor, setOpeningInEditor] = useState<string>('');

  // Track active agentInstanceId for tab state to guard against cross-saving during instance transitions
  const activeInstanceRef = useRef(agentInstanceId);

  // Persist openTabs and activeTabPath per directory and per agentInstanceId (REQ-UI-INSTANCE-MONACO-PERSISTENCE, REQ-UI-PER-DIRECTORY-MONACO-INSTANCES)
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const scopeKey = chainId || agentInstanceId || projectId;
    if (!scopeKey) return;
    try {
      const payload = JSON.stringify({ openTabs, activeTabPath });
      localStorage.setItem(`heimdall:editor:tabs:${scopeKey}:${activeDirectoryId}`, payload);
      if (activeDirectoryId === 'primary' && agentInstanceId) {
        localStorage.setItem(`heimdall:editor:tabs:${agentInstanceId}`, payload);
      }
      setDirectorySessions((prev) => ({
        ...prev,
        [activeDirectoryId]: {
          ...(prev[activeDirectoryId] || { cwd: '', isDiffMode: false }),
          openTabs,
          activeTabPath,
        },
      }));
    } catch {}
  }, [chainId, agentInstanceId, projectId, activeDirectoryId, openTabs, activeTabPath]);

  // Split-pane & explorer collapse/resizing state (REQ-IDE-SPLIT-PANE, REQ-IDE-FILE-TREE, REQ-UI-SIDEBAR-PERSISTENCE, REQ-UI-INSTANCE-TREE-PERSISTENCE)
  const [isExplorerCollapsed, setIsExplorerCollapsed] = useState<boolean>(() => {
    try {
      if (agentInstanceId) {
        const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
        if (treeRaw) {
          const parsed = JSON.parse(treeRaw);
          if (typeof parsed?.isExplorerCollapsed === 'boolean') {
            return parsed.isExplorerCollapsed;
          }
        }
      }
      return localStorage.getItem('heimdall:editor:explorer_collapsed') === 'true';
    } catch {
      return false;
    }
  });

  const updateExplorerCollapsed = useCallback((nextOrUpdater: boolean | ((prev: boolean) => boolean)) => {
    setIsExplorerCollapsed((prev) => {
      const next = typeof nextOrUpdater === 'function' ? nextOrUpdater(prev) : nextOrUpdater;
      try {
        localStorage.setItem('heimdall:editor:explorer_collapsed', String(next));
        if (agentInstanceId) {
          const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
          const parsed = treeRaw ? JSON.parse(treeRaw) : {};
          parsed.isExplorerCollapsed = next;
          localStorage.setItem(`heimdall:editor:tree:${agentInstanceId}`, JSON.stringify(parsed));
        }
      } catch {}
      return next;
    });
  }, [agentInstanceId]);

  useEffect(() => {
    if (initialOpenSearchInFiles) {
      setIsSearchDrawerOpen(true);
      updateExplorerCollapsed(false);
      onSearchDrawerConsumed?.();
    }
  }, [initialOpenSearchInFiles, updateExplorerCollapsed, onSearchDrawerConsumed]);

  useEffect(() => {
    if (initialOpenCommandPalette) {
      setIsCommandPaletteOpen(true);
      onCommandPaletteConsumed?.();
    }
  }, [initialOpenCommandPalette, onCommandPaletteConsumed]);
  const [explorerWidth, setExplorerWidth] = useState<number>(280);
  const [isDiffMode, setIsDiffMode] = useState<boolean>(false);
  const [isResizing, setIsResizing] = useState<boolean>(false);
  const resizerRef = useRef<{ startX: number; startWidth: number } | null>(null);

  // REQ-VIM-KEYBINDINGS: Persisted Vim mode toggle ('heimdall:editor:vim_mode')
  const [isVimMode, setIsVimMode] = useState<boolean>(() => {
    try {
      return localStorage.getItem('heimdall:editor:vim_mode') === 'true';
    } catch {
      return false;
    }
  });

  const toggleVimMode = useCallback(() => {
    setIsVimMode((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('heimdall:editor:vim_mode', String(next));
      } catch {}
      return next;
    });
  }, []);

  // REQ-UI-RESPONSIVE-TOP-BAR: 3-dots overflow menu
  const [isOverflowOpen, setIsOverflowOpen] = useState<boolean>(false);
  const overflowRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!isOverflowOpen) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (overflowRef.current && !overflowRef.current.contains(e.target as Node)) {
        setIsOverflowOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isOverflowOpen]);

  // REQ-UI-MOBILE-SINGLE-PANE: Viewport < 640px or sidebar width < 480px single-pane layout
  const [containerWidth, setContainerWidth] = useState<number>(800);
  const [viewportWidth, setViewportWidth] = useState<number>(1024);
  const panelRootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const updateDimensions = () => {
      setViewportWidth(window.innerWidth);
      if (panelRootRef.current) {
        setContainerWidth(panelRootRef.current.clientWidth);
      }
    };
    updateDimensions();
    window.addEventListener('resize', updateDimensions);
    let ro: ResizeObserver | null = null;
    if (typeof ResizeObserver !== 'undefined' && panelRootRef.current) {
      ro = new ResizeObserver((entries) => {
        for (const entry of entries) {
          if (entry.contentRect) {
            setContainerWidth(entry.contentRect.width);
          }
        }
      });
      ro.observe(panelRootRef.current);
    }
    return () => {
      window.removeEventListener('resize', updateDimensions);
      ro?.disconnect();
    };
  }, []);

  const isSinglePane = isMobile || viewportWidth < 640 || containerWidth < 480;
  const isNarrowExplorer = isMobile || isSinglePane || explorerWidth < 320;
  const [activePane, setActivePane] = useState<'files' | 'editor'>('files');

  // REQ-UI-MOBILE-WORD-WRAP: Line wrapping in Monaco editor ('heimdall:editor:word_wrap'), defaults to 'on' in mobile view
  const [isWordWrap, setIsWordWrap] = useState<boolean>(() => {
    try {
      const stored = localStorage.getItem('heimdall:editor:word_wrap');
      if (stored !== null) return stored === 'true';
    } catch {}
    return true;
  });

  useEffect(() => {
    try {
      const stored = localStorage.getItem('heimdall:editor:word_wrap');
      if (stored === null && isSinglePane) {
        setIsWordWrap(true);
      }
    } catch {}
  }, [isSinglePane]);

  const toggleWordWrap = useCallback(() => {
    setIsWordWrap((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('heimdall:editor:word_wrap', String(next));
      } catch {}
      return next;
    });
  }, []);

  // Minimap in Monaco editor ('heimdall:editor:minimap'), defaults to true
  const [isMinimapEnabled, setIsMinimapEnabled] = useState<boolean>(() => {
    try {
      const stored = localStorage.getItem('heimdall:editor:minimap');
      if (stored !== null) return stored === 'true';
    } catch {}
    return true;
  });

  const toggleMinimap = useCallback(() => {
    setIsMinimapEnabled((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('heimdall:editor:minimap', String(next));
      } catch {}
      return next;
    });
  }, []);

  const startResizing = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      setIsResizing(true);
      resizerRef.current = { startX: e.clientX, startWidth: explorerWidth };
    },
    [explorerWidth]
  );

  useEffect(() => {
    if (!isResizing) return;
    const handleMouseMove = (e: MouseEvent) => {
      if (!resizerRef.current) return;
      const delta = e.clientX - resizerRef.current.startX;
      const newWidth = Math.max(200, Math.min(600, resizerRef.current.startWidth + delta));
      setExplorerWidth(newWidth);
    };
    const handleMouseUp = () => {
      setIsResizing(false);
      resizerRef.current = null;
    };
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isResizing]);

  const [cwd, setCwd] = useState<string>(() => {
    try {
      const scopeKey = chainId || agentInstanceId || projectId;
      if (scopeKey) {
        const treeRaw =
          localStorage.getItem(`heimdall:editor:tree:${scopeKey}:primary`) ||
          (agentInstanceId ? localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`) : null);
        if (treeRaw) {
          const parsed = JSON.parse(treeRaw);
          if (typeof parsed?.cwd === 'string') {
            return parsed.cwd;
          }
        }
      }
    } catch {}
    return '';
  }); // project-root-relative path ('' = root)

  // REQ-LSP-MERGE-1 / REQ-LSP-XBRIDGE-1: roots are PER DIRECTORY, not panel-wide.
  // This used to be a single `rootAbs` that load() overwrote for whichever
  // directory was listed last, while the `primary` entry read it as "the project
  // root". Listing a chain directory therefore rewrote the PROJECT's root, so
  // switching chain -> primary resolved the project's files against the chain
  // directory's root: wrong root, plausible config, confident wrong completions.
  // The outbound switch looked correct, which is what made it survive review.
  // Keyed by directory id ('primary' | <directoryId> | agent-rundir:<instanceId>).
  const [dirRoots, setDirRoots] = useState<Record<string, string>>({});

  // The PROJECT's own root. Stable no matter which directory is on screen.
  const primaryRoot = dirRoots['primary'] || '';
  // The root of the directory CURRENTLY displayed -- the other meaning that used
  // to share one variable with the line above. Empty until that directory has
  // been listed once, which is honest: we do not know its root yet, and the LSP
  // `active` gate below already declines to start a server without one.
  const rootAbs = dirRoots[activeDirectoryId] || '';

  // Available directories (primary project root + extra task chain directories + member agent run dirs)
  const availableDirectories = useMemo<DirectoryItem[]>(() => {
    const primary: DirectoryItem = {
      id: 'primary',
      label: projectName || (primaryRoot ? baseName(primaryRoot) : 'Primary Project'),
      path: primaryRoot,
      bridgeId: bridgeId || '',
      isPrimary: true,
      kind: 'primary',
      isReadOnly: false,
    };
    const extras: DirectoryItem[] = (taskChainDirectories || []).map((d) => ({
      id: d.directoryId,
      label: baseName(d.path) || d.path || d.directoryId,
      path: d.path,
      bridgeId: d.bridgeId,
      vcsKind: d.vcsKind,
      isPrimary: false,
      kind: 'chain_directory',
      isReadOnly: false,
    }));

    const memberRoster = propMembers || chainDetailQuery.data?.chain?.members || [];
    const agentRunDirs: DirectoryItem[] = [];
    const seenInstances = new Set<string>();

    for (const m of memberRoster) {
      const instId = m.agentInstanceId || m.agent_instance_id || m.id;
      if (!instId || seenInstances.has(instId)) continue;
      seenInstances.add(instId);
      const dispName = m.displayName || m.display_name || m.name || instId;
      agentRunDirs.push({
        id: `agent-rundir:${instId}`,
        label: `Run dir — ${dispName}`,
        path: '',
        bridgeId: m.bridgeId || m.bridge_id || bridgeId || '',
        isPrimary: false,
        kind: 'agent_run_dir',
        agentInstanceId: instId,
        isReadOnly: true,
      });
    }

    if (agentInstanceId && !seenInstances.has(agentInstanceId)) {
      agentRunDirs.push({
        id: `agent-rundir:${agentInstanceId}`,
        label: `Run dir — ${agentInstanceId}`,
        path: '',
        bridgeId: bridgeId || '',
        isPrimary: false,
        kind: 'agent_run_dir',
        agentInstanceId: agentInstanceId,
        isReadOnly: true,
      });
    }

    return [primary, ...extras, ...agentRunDirs];
  }, [projectName, primaryRoot, bridgeId, taskChainDirectories, propMembers, chainDetailQuery.data?.chain?.members, agentInstanceId]);

  const activeDirectory = useMemo(() => {
    return availableDirectories.find((d) => d.id === activeDirectoryId) || availableDirectories[0];
  }, [availableDirectories, activeDirectoryId]);

  const activeFsTarget = useMemo<FsScopeArgs>(() => {
    if (activeDirectory?.agentInstanceId) {
      return {
        agentInstanceId: activeDirectory.agentInstanceId,
        bridgeId: activeDirectory.bridgeId || bridgeId || '',
      };
    }
    if (!activeDirectory || activeDirectory.id === 'primary') {
      return {
        projectId,
        chainId: undefined,
        directoryId: undefined,
        bridgeId: bridgeId || '',
      };
    }
    return {
      projectId: undefined,
      chainId,
      directoryId: activeDirectory.id,
      bridgeId: activeDirectory.bridgeId || bridgeId || '',
    };
  }, [activeDirectory, projectId, chainId, bridgeId]);

  const searchScopes = useMemo<FsSearchScope[]>(() => {
    return availableDirectories.map((dir) => {
      const scopeArgs: FsScopeArgs = dir.agentInstanceId
        ? { agentInstanceId: dir.agentInstanceId, bridgeId: dir.bridgeId || bridgeId || '' }
        : dir.id === 'primary'
        ? { projectId, bridgeId: dir.bridgeId || bridgeId || '' }
        : { chainId, directoryId: dir.id, bridgeId: dir.bridgeId || bridgeId || '' };

      let kind: 'primary' | 'chain_directory' | 'agent_run_dir' = 'chain_directory';
      if (dir.isPrimary || dir.id === 'primary') kind = 'primary';
      else if (dir.kind === 'agent_run_dir' || dir.agentInstanceId) kind = 'agent_run_dir';

      return {
        id: dir.id,
        label: dir.label,
        kind,
        path: dirRoots[dir.id] || dir.path || '',
        bridgeId: dir.bridgeId || bridgeId || '',
        scopeArgs,
      };
    });
  }, [availableDirectories, projectId, chainId, bridgeId, dirRoots]);

  const isReadOnlyDirectory = Boolean(activeDirectory?.isReadOnly || activeDirectory?.kind === 'agent_run_dir');

  const activeBridgeDisplay = useMemo(
    () => getBridgeDisplay(activeDirectory?.bridgeId || bridgeId, bridges),
    [activeDirectory?.bridgeId, bridgeId, bridges]
  );


  // Persist cwd and isExplorerCollapsed per directory and per agentInstanceId (REQ-UI-INSTANCE-TREE-PERSISTENCE)
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const scopeKey = chainId || agentInstanceId || projectId;
    if (!scopeKey) return;
    try {
      const treeRaw = localStorage.getItem(`heimdall:editor:tree:${scopeKey}:${activeDirectoryId}`);
      const parsed = treeRaw ? JSON.parse(treeRaw) : {};
      parsed.cwd = cwd;
      parsed.isExplorerCollapsed = isExplorerCollapsed;
      localStorage.setItem(`heimdall:editor:tree:${scopeKey}:${activeDirectoryId}`, JSON.stringify(parsed));
      if (activeDirectoryId === 'primary' && agentInstanceId) {
        localStorage.setItem(`heimdall:editor:tree:${agentInstanceId}`, JSON.stringify(parsed));
      }
      setDirectorySessions((prev) => ({
        ...prev,
        [activeDirectoryId]: {
          ...(prev[activeDirectoryId] || { openTabs: [], activeTabPath: '', isDiffMode: false }),
          cwd,
        },
      }));
    } catch {}
  }, [chainId, agentInstanceId, projectId, activeDirectoryId, cwd, isExplorerCollapsed]);
  const [entries, setEntries] = useState<FsEntry[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [truncated, setTruncated] = useState(false);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');
  const [includeHidden, setIncludeHidden] = useState(() => {
    return activeDirectory?.kind === 'agent_run_dir' || Boolean(activeDirectory?.agentInstanceId);
  });
  // Timestamp of the last successful listing fetch, shown as "refreshed HH:MM".
  const [lastRefreshed, setLastRefreshed] = useState<number | null>(null);

  const [pending, setPending] = useState<PendingAction>(null);
  const [nameDraft, setNameDraft] = useState('');


  // In-memory review comments, tracked ACROSS all files in this conversation.
  // Reset when the conversation scope changes so notes never leak between chats.
  const [comments, setComments] = useState<FileLineComment[]>([]);
  const [publishing, setPublishing] = useState(false);
  const [publishError, setPublishError] = useState('');
  useEffect(() => {
    setComments([]);
    setPublishError('');
  }, [conversationKey, projectId]);

  const addComment = useCallback((path: string, line: number, lineText: string, body: string) => {
    const text = str(body);
    if (!text) return;
    setComments((prev) => [
      ...prev,
      { id: `flc_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`, path, line, lineText, body: text, createdAt: Date.now() },
    ]);
  }, []);
  const editComment = useCallback((id: string, body: string) => {
    const text = str(body);
    setComments((prev) => prev.map((c) => (c.id === id ? { ...c, body: text } : c)).filter((c) => c.body));
  }, []);
  const deleteComment = useCallback((id: string) => {
    setComments((prev) => prev.filter((c) => c.id !== id));
  }, []);

  // Path-level (file/folder) comment composer: the target path (or null when
  // closed) and its draft. line 0 marks a path-scoped comment.
  const [pathCommentFor, setPathCommentFor] = useState<{ path: string; label: string } | null>(null);
  const [pathCommentDraft, setPathCommentDraft] = useState('');

  const commentsForPath = useCallback(
    (path: string) => comments.filter((c) => c.path === path),
    [comments],
  );
  const filesWithComments = useMemo(() => new Set(comments.map((c) => c.path)).size, [comments]);

  const publishComments = useCallback(async () => {
    if (!onPublishComments || comments.length === 0) return;
    setPublishError('');
    setPublishing(true);
    try {
      const ok = await onPublishComments(formatCommentsMarkdown(comments));
      if (ok) setComments([]);
      else setPublishError('Could not send comments.');
    } catch (e: any) {
      setPublishError(str(e?.message) || 'Could not send comments.');
    } finally {
      setPublishing(false);
    }
  }, [onPublishComments, comments]);

  const mutating =
    createFileState.isLoading || createDirState.isLoading || moveState.isLoading || deleteState.isLoading;

  // Load a directory listing (optionally appending a paginated page).
  const load = useCallback(
    async (
      path: string,
      opts?: { cursor?: string | null; append?: boolean; includeHidden?: boolean },
      scopeOverride?: FsScopeArgs,
      dirIdOverride?: string
    ) => {
      const scope = scopeOverride || activeFsTarget;
      // switchDirectory calls load() for the directory it is moving TO, which is
      // not necessarily activeDirectoryId yet, so it passes the id explicitly.
      const loadedDirId = dirIdOverride || activeDirectoryId;
      if (!scope.projectId && (!scope.chainId || !scope.directoryId) && !scope.agentInstanceId) return;
      const append = Boolean(opts?.append);
      setError('');
      if (append) setLoadingMore(true);
      else setLoading(true);
      try {
        const res: FsListResult = await listDir({
          projectId: scope.projectId,
          chainId: scope.chainId,
          directoryId: scope.directoryId,
          agentInstanceId: scope.agentInstanceId,
          bridgeId: scope.bridgeId,
          path,
          includeHidden: opts?.includeHidden !== undefined ? opts.includeHidden : includeHidden,
          cursor: opts?.cursor ?? null,
          limit: LIST_LIMIT,
        }).unwrap();
        if (!res.ok) {
          setError(str(res.error?.message) || 'Could not open directory');
          if (!append) setEntries([]);
          return;
        }
        // Record under the directory that was LISTED, not the one that happens to
        // be active when the response lands -- a switch can change that mid-flight.
        setDirRoots((prev) => {
          const next = res.root || '';
          return prev[loadedDirId] === next ? prev : { ...prev, [loadedDirId]: next };
        });
        setTruncated(Boolean(res.truncated));
        setHasMore(Boolean(res.has_more));
        setNextCursor(res.next_cursor ?? null);
        setEntries((prev) => (append ? [...prev, ...(res.entries || [])] : res.entries || []));
        if (!append) setCwd(path);
        setLastRefreshed(Date.now());
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Bridge unavailable');
        if (!append) setEntries([]);
      } finally {
        if (append) setLoadingMore(false);
        else setLoading(false);
      }
    },
    [activeFsTarget, includeHidden, listDir],
  );

  // Switch active directory while preserving Monaco state, undo buffers, tabs, and cwd per directory
  const switchDirectory = useCallback(
    (newDirId: string) => {
      if (newDirId === activeDirectoryId) return;

      const prevDirId = activeDirectoryId;
      const currentSnapshot: DirectorySessionState = {
        openTabs,
        activeTabPath,
        cwd,
        isDiffMode,
      };
      setDirectorySessions((prev) => ({
        ...prev,
        [prevDirId]: currentSnapshot,
      }));

      const scopeKey = chainId || agentInstanceId || projectId;
      if (scopeKey && typeof window !== 'undefined') {
        try {
          localStorage.setItem(
            `heimdall:editor:tabs:${scopeKey}:${prevDirId}`,
            JSON.stringify({ openTabs, activeTabPath })
          );
          localStorage.setItem(
            `heimdall:editor:tree:${scopeKey}:${prevDirId}`,
            JSON.stringify({ cwd, isExplorerCollapsed })
          );
        } catch {}
      }

      setMountedDirIds((prev) => new Set(prev).add(newDirId));

      let nextSession = directorySessions[newDirId];
      if (!nextSession && scopeKey && typeof window !== 'undefined') {
        try {
          const rawTabs = localStorage.getItem(`heimdall:editor:tabs:${scopeKey}:${newDirId}`);
          const rawTree = localStorage.getItem(`heimdall:editor:tree:${scopeKey}:${newDirId}`);
          let restoredTabs: EditorTab[] = [];
          let restoredActive = '';
          let restoredCwd = '';
          if (rawTabs) {
            const parsed = JSON.parse(rawTabs);
            if (Array.isArray(parsed?.openTabs)) restoredTabs = parsed.openTabs;
            else if (Array.isArray(parsed)) restoredTabs = parsed;
            restoredActive = typeof parsed?.activeTabPath === 'string' ? parsed.activeTabPath : (restoredTabs[0]?.path || '');
          }
          if (rawTree) {
            const parsed = JSON.parse(rawTree);
            if (typeof parsed?.cwd === 'string') restoredCwd = parsed.cwd;
          }
          nextSession = {
            openTabs: restoredTabs,
            activeTabPath: restoredActive,
            cwd: restoredCwd,
            isDiffMode: false,
          };
        } catch {}
      }

      const nextTabs = nextSession?.openTabs || [];
      const nextActive = nextSession?.activeTabPath || (nextTabs[0]?.path || '');
      const nextCwd = nextSession?.cwd || '';
      const nextDiffMode = Boolean(nextSession?.isDiffMode);

      setActiveDirectoryId(newDirId);
      setOpenTabs(nextTabs);
      setActiveTabPath(nextActive);
      setIsEditMode(nextTabs.length > 0);
      setCwd(nextCwd);
      setIsDiffMode(nextDiffMode);
      setPending(null);
      setSaveFeedback(null);
      setConfirmClosePath(null);

      const nextTargetDir = availableDirectories.find((d) => d.id === newDirId);
      const isAgentRunDir = nextTargetDir?.kind === 'agent_run_dir' || Boolean(nextTargetDir?.agentInstanceId);
      if (isAgentRunDir) {
        setIncludeHidden(true);
      }

      const nextScope: FsScopeArgs = isAgentRunDir
        ? { agentInstanceId: nextTargetDir?.agentInstanceId, bridgeId: nextTargetDir?.bridgeId || bridgeId || '' }
        : !nextTargetDir || nextTargetDir.id === 'primary'
        ? { projectId, bridgeId: bridgeId || '' }
        : { chainId, directoryId: nextTargetDir.id, bridgeId: nextTargetDir.bridgeId || bridgeId || '' };

      void load(nextCwd, isAgentRunDir ? { includeHidden: true } : undefined, nextScope, newDirId);
    },
    [
      activeDirectoryId,
      openTabs,
      activeTabPath,
      cwd,
      isDiffMode,
      directorySessions,
      chainId,
      agentInstanceId,
      projectId,
      isExplorerCollapsed,
      availableDirectories,
      bridgeId,
      load,
    ]
  );

  const cwdRef = useRef(cwd);
  useEffect(() => {
    cwdRef.current = cwd;
  }, [cwd]);

  // Synchronize explorer directory to file location (REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS)
  const revealInExplorer = useCallback(
    (filePath: string) => {
      if (!filePath) return;
      const dir = parentPath(filePath);
      if (dir !== cwdRef.current) {
        void load(dir);
      }
    },
    [load],
  );

  // Auto-scroll active file entry in explorer into view (REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS)
  const activeEntryRef = useRef<HTMLLIElement | null>(null);
  useEffect(() => {
    if (activeEntryRef.current) {
      activeEntryRef.current.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' });
    }
  }, [activeTabPath, cwd, entries]);

  // Keep explorer directory in sync with active editor tab (REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS)
  useEffect(() => {
    if (activeTabPath) {
      revealInExplorer(activeTabPath);
    }
  }, [activeTabPath, revealInExplorer]);

  // Restore / load directory and editor state for current project & instance (REQ-UI-INSTANCE-MONACO-PERSISTENCE, REQ-UI-INSTANCE-TREE-PERSISTENCE)
  const isProjectMountedRef = useRef(false);
  useEffect(() => {
    if (!isProjectMountedRef.current) {
      isProjectMountedRef.current = true;
      void load(cwd);
      return;
    }
    setPending(null);
    setSaveFeedback(null);
    setConfirmClosePath(null);

    let restoredTabs: EditorTab[] = [];
    let restoredActive = '';
    let restoredCwd = '';
    let restoredCollapsed = false;

    if (agentInstanceId && typeof window !== 'undefined') {
      try {
        const tabsRaw = localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
        if (tabsRaw) {
          const parsed = JSON.parse(tabsRaw);
          if (Array.isArray(parsed?.openTabs)) {
            restoredTabs = parsed.openTabs;
            restoredActive = typeof parsed.activeTabPath === 'string' ? parsed.activeTabPath : (restoredTabs[0]?.path || '');
          } else if (Array.isArray(parsed)) {
            restoredTabs = parsed;
            restoredActive = restoredTabs[0]?.path || '';
          }
        }
        const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
        if (treeRaw) {
          const parsed = JSON.parse(treeRaw);
          if (typeof parsed?.cwd === 'string') restoredCwd = parsed.cwd;
          if (typeof parsed?.isExplorerCollapsed === 'boolean') restoredCollapsed = parsed.isExplorerCollapsed;
        } else {
          restoredCollapsed = localStorage.getItem('heimdall:editor:explorer_collapsed') === 'true';
        }
      } catch {}
    }

    if (restoredActive) {
      const activeParent = parentPath(restoredActive);
      if (activeParent) restoredCwd = activeParent;
    }

    setOpenTabs(restoredTabs);
    setActiveTabPath(restoredActive);
    setIsEditMode(restoredTabs.length > 0);
    setCwd(restoredCwd);
    setIsExplorerCollapsed(restoredCollapsed);
    activeInstanceRef.current = agentInstanceId;
    void load(restoredCwd);
    if (restoredActive) {
      revealInExplorer(restoredActive);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, bridgeId, agentInstanceId]);

  // Global keydown listener for Quick Open (Cmd+P / Ctrl+P) scoped to current project (REQ-UI-GLOBAL-QUICK-OPEN)
  useEffect(() => {
    if (!projectId) return;
    const handleQuickOpenKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'p' || e.key === 'P') && !e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        if (onOpenQuickOpen) {
          onOpenQuickOpen();
        } else {
          setIsQuickOpenOpen((prev) => !prev);
        }
      }
    };
    window.addEventListener('keydown', handleQuickOpenKeyDown, true);
    return () => window.removeEventListener('keydown', handleQuickOpenKeyDown, true);
  }, [projectId, onOpenQuickOpen]);

  // Global keydown listener for Search in Files (Cmd+Shift+F / Ctrl+Shift+F) (REQ-SEARCH-SHORTCUTS-1)
  useEffect(() => {
    if (!projectId) return;
    const handleSearchInFilesKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'f' || e.key === 'F') && e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        if (onOpenSearchInFiles) {
          onOpenSearchInFiles();
        } else {
          setIsSearchDrawerOpen((prev) => {
            const next = !prev;
            if (next) {
              if (isExplorerCollapsed) updateExplorerCollapsed(false);
              if (isSinglePane) setActivePane('files');
            }
            return next;
          });
        }
      }
    };
    window.addEventListener('keydown', handleSearchInFilesKeyDown, true);
    return () => window.removeEventListener('keydown', handleSearchInFilesKeyDown, true);
  }, [projectId, onOpenSearchInFiles, isExplorerCollapsed, updateExplorerCollapsed, isSinglePane]);

  // Global keydown listener for Command Palette (Cmd+Shift+P / Ctrl+Shift+P and F1) (REQ-EDITOR-COMMAND-PALETTE-1)
  useEffect(() => {
    if (!projectId) return;
    const handleCommandPaletteKeyDown = (e: KeyboardEvent) => {
      const isCmdShiftP = (e.metaKey || e.ctrlKey) && (e.key === 'p' || e.key === 'P') && e.shiftKey;
      const isF1 = e.key === 'F1';
      if (isCmdShiftP || isF1) {
        e.preventDefault();
        e.stopPropagation();
        if (onOpenCommandPalette) {
          onOpenCommandPalette();
        } else {
          setCommandPaletteInitialQuery('');
          setIsCommandPaletteOpen((prev) => !prev);
        }
      }
    };
    window.addEventListener('keydown', handleCommandPaletteKeyDown, true);
    return () => window.removeEventListener('keydown', handleCommandPaletteKeyDown, true);
  }, [projectId, onOpenCommandPalette]);

  // Global keydown listener for Toggle Word Wrap (Alt+Z)
  useEffect(() => {
    const handleWordWrapKeyDown = (e: KeyboardEvent) => {
      if (e.altKey && (e.key === 'z' || e.key === 'Z') && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        toggleWordWrap();
      }
    };
    window.addEventListener('keydown', handleWordWrapKeyDown, true);
    return () => window.removeEventListener('keydown', handleWordWrapKeyDown, true);
  }, [toggleWordWrap]);

  // Show/hide-hidden refetches the CURRENT directory in place (Spec 4.2/4.3) —
  // it must not jump back to root. Skip the initial mount so this doesn't
  // double-fire alongside the project/bridge effect on first render.
  const hiddenMounted = useRef(false);
  useEffect(() => {
    if (!hiddenMounted.current) {
      hiddenMounted.current = true;
      return;
    }
    void load(cwd);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [includeHidden]);

  const openDir = useCallback(
    (path: string) => {
      setPending(null);
      void load(path);
    },
    [load],
  );

  const refresh = useCallback(() => {
    void load(cwd);
  }, [cwd, load]);

  // Breadcrumb crumbs: project root -> cwd.
  const crumbs = useMemo(() => {
    const out: { label: string; path: string }[] = [
      { label: projectName ? projectName : baseName(rootAbs) || 'project', path: '' },
    ];
    if (cwd) {
      const segs = cwd.split('/').filter(Boolean);
      let acc = '';
      for (const seg of segs) {
        acc = acc ? `${acc}/${seg}` : seg;
        out.push({ label: seg, path: acc });
      }
    }
    return out;
  }, [cwd, rootAbs, projectName]);

  // Dirs first, then files; names asc (server already sorts this way, but keep it
  // stable client-side for appended pages too).
  const sortedEntries = useMemo(() => {
    return [...entries].sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [entries]);

  // Auto-dismiss save feedback after 3s
  useEffect(() => {
    if (saveFeedback) {
      const timer = setTimeout(() => {
        setSaveFeedback(null);
      }, 3000);
      return () => clearTimeout(timer);
    }
  }, [saveFeedback]);

  const activeEditorTab = useMemo(
    () => openTabs.find((t) => t.path === activeTabPath),
    [openTabs, activeTabPath]
  );

  // REQ-LSP-UI-1: language-server features for the active tab.
  //
  // Gated on the "lsp" experiment flag INSIDE the hook: with the flag off it
  // returns before minting a ticket, opening a socket or registering a single
  // provider, so the editor behaves exactly as it did before this feature. The
  // hook is called unconditionally because hooks must be — the gate is in its
  // body, not at this call site.
  //
  // Disabled for image and unviewable tabs: there is no text document to sync.
  // REQ-LSP-MERGE-1: EVERY directory carries its OWN bridge and its OWN root --
  // a chain directory can live on a different bridge from the project and its path
  // is not under rootAbs. The panel-level `bridgeId`/`rootAbs` describe the PRIMARY
  // project only, so feeding them to the hook while the user edits a file in a chain
  // directory resolves the server config against the wrong bridge, rooted in the wrong
  // place. That does not error -- it starts a plausible language server and returns
  // confident WRONG completions, which is the exact failure this chain exists to remove.
  // Resolve both from activeDirectory, matching how upstream resolves every other
  // directory-scoped value (see activeFsTarget and bridgeDisplay above).
  const lspBridgeId = activeDirectory?.bridgeId || bridgeId || '';
  // activeDirectory.path is rootAbs for 'primary' and the directory's own path for a
  // chain directory. It is deliberately '' for an agent_run_dir, which has no editable
  // root; `active` below gates on it so those mount an editor but never start a server
  // (an empty root would otherwise make joinAbs emit a RELATIVE path to the resolver).
  const lspRootAbs = activeDirectory?.path || '';
  // REQ-LSP-ENV-1: THE RETURN VALUE IS LOAD-BEARING AND USED TO BE DISCARDED.
  // This was a bare `useMonacoLsp({...})` call statement, so the hook's `status`
  // and `detail` were computed every render and thrown away — nothing in the app
  // rendered either one. Capturing it here and rendering `notice` below is ONE
  // fix, not two edits: the language server's own explanation of why it is dead
  // had nowhere to surface precisely because this call ignored its result.
  const lsp = useMonacoLsp({
    monaco,
    bridgeId: lspBridgeId,
    rootAbs: lspRootAbs,
    activePath: activeEditorTab?.isImage || activeEditorTab?.isUnviewable ? '' : activeTabPath,
    monacoLanguageId: activeEditorTab ? getLanguageForMonaco(activeEditorTab.path) : '',
    content: activeEditorTab?.content ?? '',
    active:
      Boolean(activeEditorTab) &&
      !activeEditorTab?.isImage &&
      !activeEditorTab?.isUnviewable &&
      Boolean(lspRootAbs),
  });

  // Fetch full file content across all byte pages before editing
  const fetchAllFileContent = useCallback(
    async (
      filePath: string,
      scopeOverride?: FsScopeArgs
    ): Promise<{
      content: string;
      isImage?: boolean;
      mime?: string;
      isUnviewable?: boolean;
      unviewableReason?: string;
    }> => {
      let acc = '';
      let offset = 0;
      let eof = false;
      let iterations = 0;
      let isImage = false;
      let mime = '';

      const target = scopeOverride || activeFsTarget;

      while (!eof && iterations < 100) {
        iterations++;
        const res: FsReadFileResult = await readFile({
          ...target,
          path: filePath,
          offset,
        }).unwrap();

        if (!res.ok) {
          throw new Error(res.error?.message || 'Could not read file');
        }

        if (iterations === 1) {
          mime = res.mime || '';
          if (res.viewable && res.encoding === 'base64') {
            return {
              content: res.content || '',
              isImage: true,
              mime: res.mime || 'image/png',
            };
          }
          if ((res.size || 0) > 5 * 1024 * 1024) {
            return {
              content: '',
              isUnviewable: true,
              unviewableReason: `This file is too large to edit (${formatBytes(res.size || 0)} > 5 MB).`,
            };
          }
          if (!res.viewable) {
            return {
              content: '',
              isUnviewable: true,
              unviewableReason:
                res.error?.cause === 'file_too_large'
                  ? `This file is too large to preview (${formatBytes(res.size || 0)}).`
                  : res.error?.cause === 'unsupported_type'
                    ? 'This file type cannot be previewed.'
                    : str(res.error?.message) || 'This file cannot be previewed.',
            };
          }
        }

        acc += res.content || '';
        if (acc.length > 5 * 1024 * 1024) {
          return {
            content: '',
            isUnviewable: true,
            unviewableReason: 'This file exceeds the 5 MB editor safety threshold.',
          };
        }
        const bytesReturned = Number(
          res.bytes_returned ?? (res.content ? res.content.length : 0)
        );
        offset = Number(res.offset ?? 0) + bytesReturned;
        eof = res.eof !== false || bytesReturned === 0;
      }
      return { content: acc, isImage, mime };
    },
    [readFile, activeFsTarget]
  );

  const openFileInEditor = useCallback(
    async (inputPath: string, scopeOverride?: FsScopeArgs) => {
      setError('');
      const filePath = inputPath;

      const existing = openTabs.find((t) => t.path === filePath);
      if (existing) {
        setActiveTabPath(filePath);
        setIsEditMode(true);
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
        revealInExplorer(filePath);
        return;
      }
      setOpeningInEditor(filePath);
      try {
        const fileRes = await fetchAllFileContent(filePath, scopeOverride);
        const newTab: EditorTab = {
          path: filePath,
          content: fileRes.content,
          initialContent: fileRes.content,
          isDirty: false,
          isNew: false,
          isImage: fileRes.isImage,
          mime: fileRes.mime,
          isUnviewable: fileRes.isUnviewable,
          unviewableReason: fileRes.unviewableReason,
        };
        setOpenTabs((prev) => [...prev, newTab]);
        setActiveTabPath(filePath);
        setIsEditMode(true);
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
        revealInExplorer(filePath);
      } catch (e: any) {
        setError(str(e?.message) || 'Could not open file in editor');
      } finally {
        setOpeningInEditor('');
      }
    },
    [cwd, openTabs, fetchAllFileContent, isMobile, isSinglePane, revealInExplorer]
  );

  useEffect(() => {
    if (openFilePath) {
      void openFileInEditor(openFilePath);
      revealInExplorer(openFilePath);
      onFileOpened?.();
    }
  }, [openFilePath, openFileInEditor, revealInExplorer, onFileOpened]);

  // Navigate to match position from Search In Files
  const handleSelectSearchMatch = useCallback(
    async (match: ScopedSearchMatch) => {
      // 1. Switch directory if match comes from another scope
      const targetDirId = match.scopeId || (
        match.scopeArgs.directoryId
          ? match.scopeArgs.directoryId
          : match.scopeArgs.agentInstanceId
          ? `agent-rundir:${match.scopeArgs.agentInstanceId}`
          : 'primary'
      );
      if (targetDirId !== activeDirectoryId) {
        switchDirectory(targetDirId);
      }

      // 2. Open file in editor passing scopeArgs override so read target doesn't depend on stale closure
      await openFileInEditor(match.path, match.scopeArgs);

      // 3. Reveal and select position in Monaco
      const matchLength =
        match.match_end > match.match_start ? match.match_end - match.match_start : 0;

      pendingNavigationRef.current = {
        path: match.path,
        line: match.line_number,
        column: match.column,
        length: matchLength,
      };

      const editor = monacoEditorRef.current;
      if (editor && activeTabPath === match.path) {
        try {
          editor.revealPositionInCenter({ lineNumber: match.line_number, column: match.column }, 0);
          editor.setSelection({
            startLineNumber: match.line_number,
            startColumn: match.column,
            endLineNumber: match.line_number,
            endColumn: match.column + Math.max(1, matchLength),
          });
          editor.focus();
          pendingNavigationRef.current = null;
        } catch {}
      }

      // 4. In mobile or single-pane mode, navigate to editor view
      if (isSinglePane) {
        setActivePane('editor');
      }
    },
    [activeDirectoryId, switchDirectory, openFileInEditor, activeTabPath, isSinglePane]
  );

  // Apply pending jump to line/column when Monaco editor mounts or active tab changes
  useEffect(() => {
    if (
      pendingNavigationRef.current &&
      pendingNavigationRef.current.path === activeTabPath &&
      monacoEditorRef.current
    ) {
      const { line, column, length } = pendingNavigationRef.current;
      const timer = setTimeout(() => {
        try {
          const ed = monacoEditorRef.current;
          if (ed) {
            ed.revealPositionInCenter({ lineNumber: line, column }, 0);
            ed.setSelection({
              startLineNumber: line,
              startColumn: column,
              endLineNumber: line,
              endColumn: column + Math.max(1, length),
            });
            ed.focus();
          }
        } catch {}
        pendingNavigationRef.current = null;
      }, 50);
      return () => clearTimeout(timer);
    }
  }, [activeTabPath]);

  const handleEditorNewFile = useCallback(
    async (inputPath: string) => {
      if (isReadOnlyDirectory) return;
      setError('');
      const raw = inputPath.trim().replace(/^\/+/, '');
      if (!raw) return;
      const targetPath = cwd && !raw.includes('/') ? joinPath(cwd, raw) : raw;

      const existing = openTabs.find((t) => t.path === targetPath);
      if (existing) {
        setActiveTabPath(targetPath);
        setIsEditMode(true);
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
        revealInExplorer(targetPath);
        return;
      }

      setOpeningInEditor(targetPath);
      try {
        const fileRes = await fetchAllFileContent(targetPath);
        const newTab: EditorTab = {
          path: targetPath,
          content: fileRes.content,
          initialContent: fileRes.content,
          isDirty: false,
          isNew: false,
          isImage: fileRes.isImage,
          mime: fileRes.mime,
          isUnviewable: fileRes.isUnviewable,
          unviewableReason: fileRes.unviewableReason,
        };
        setOpenTabs((prev) => [...prev, newTab]);
        setActiveTabPath(targetPath);
        setIsEditMode(true);
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
        revealInExplorer(targetPath);
      } catch {
        const newTab: EditorTab = {
          path: targetPath,
          content: '',
          initialContent: '',
          isDirty: true,
          isNew: true,
        };
        setOpenTabs((prev) => [...prev, newTab]);
        setActiveTabPath(targetPath);
        setIsEditMode(true);
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
        revealInExplorer(targetPath);
      } finally {
        setOpeningInEditor('');
      }
    },
    [isReadOnlyDirectory, cwd, openTabs, fetchAllFileContent, isMobile, isSinglePane, revealInExplorer]
  );

  // When no tabs are open, pressing '+' creates a new file (REQ-IDE-SPLIT-PANE)
  useEffect(() => {
    if (openTabs.length > 0 || isReadOnlyDirectory) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const isInput = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA');
      if (!isInput && (e.key === '+' || e.key === '=')) {
        e.preventDefault();
        void handleEditorNewFile('untitled.txt');
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [openTabs.length, isReadOnlyDirectory, handleEditorNewFile]);

  const saveActiveFile = useCallback(async () => {
    if (isReadOnlyDirectory || !activeEditorTab || activeEditorTab.isImage || activeEditorTab.isUnviewable || writeState.isLoading) return;
    setSaveFeedback(null);
    try {
      const res = await writeProjectFile({
        ...activeFsTarget,
        path: activeEditorTab.path,
        content: activeEditorTab.content,
        encoding: 'utf8',
      }).unwrap();

      if (res.ok) {
        setOpenTabs((prev) =>
          prev.map((t) =>
            t.path === activeEditorTab.path
              ? { ...t, initialContent: t.content, isDirty: false, isNew: false }
              : t
          )
        );
        setSaveFeedback({
          type: 'success',
          message: `Saved ${baseName(activeEditorTab.path)}`,
        });
        void load(cwd);
      } else {
        setSaveFeedback({
          type: 'error',
          message: res.error?.message || res.error?.cause || 'Failed to save file',
        });
      }
    } catch (err: any) {
      setSaveFeedback({
        type: 'error',
        message: str(err?.message || err?.error) || 'Failed to save file',
      });
    }
  }, [isReadOnlyDirectory, activeEditorTab, writeState.isLoading, writeProjectFile, activeFsTarget, cwd, load]);

  const saveAllFiles = useCallback(async () => {
    if (isReadOnlyDirectory) return;
    const dirtyTabs = openTabs.filter((t) => t.isDirty && !t.isImage && !t.isUnviewable);
    if (dirtyTabs.length === 0 || batchWriteState.isLoading) return;
    setSaveFeedback(null);
    try {
      const res = await batchWriteProjectFiles({
        ...activeFsTarget,
        files: dirtyTabs.map((t) => ({ path: t.path, content: t.content })),
      }).unwrap();

      if (res.ok) {
        const errorPaths = new Set((res.errors || []).map((e) => e.path));
        setOpenTabs((prev) =>
          prev.map((t) => {
            if (dirtyTabs.some((d) => d.path === t.path) && !errorPaths.has(t.path)) {
              return { ...t, initialContent: t.content, isDirty: false, isNew: false };
            }
            return t;
          })
        );
        void load(cwd);
        if (res.errors && res.errors.length > 0) {
          setSaveFeedback({
            type: 'warning',
            message: `Saved ${res.saved?.length || 0} files with ${res.errors.length} errors`,
          });
        } else {
          setSaveFeedback({
            type: 'success',
            message: `Saved all ${dirtyTabs.length} modified file${dirtyTabs.length === 1 ? '' : 's'}`,
          });
        }
      } else {
        setSaveFeedback({
          type: 'error',
          message: res.error?.message || res.error?.cause || 'Failed to save files',
        });
      }
    } catch (err: any) {
      setSaveFeedback({
        type: 'error',
        message: str(err?.message || err?.error) || 'Failed to save files',
      });
    }
  }, [isReadOnlyDirectory, openTabs, batchWriteState.isLoading, batchWriteProjectFiles, activeFsTarget, cwd, load]);

  const handleContentChange = useCallback(
    (path: string, newContent: string) => {
      setOpenTabs((prev) =>
        prev.map((t) => {
          if (t.path !== path) return t;
          const isDirty = t.isNew ? true : newContent !== t.initialContent;
          return { ...t, content: newContent, isDirty };
        })
      );
    },
    []
  );

  const selectTab = useCallback(
    (path: string) => {
      setActiveTabPath(path);
      setActivePane('editor');
      revealInExplorer(path);
    },
    [revealInExplorer]
  );

  const closeTab = useCallback(
    (path: string, force = false) => {
      const tab = openTabs.find((t) => t.path === path);
      if (!tab) return;
      if (!force && tab.isDirty) {
        setConfirmClosePath(path);
        return;
      }
      // Monaco Lifecycle: Dispose models matching this closed tab to prevent memory leaks
      if (monaco) {
        const models = monaco.editor.getModels();
        for (const model of models) {
          const modelPath = model.uri.path;
          if (
            modelPath === path ||
            modelPath.endsWith(`/${path}`) ||
            modelPath.endsWith(path) ||
            model.uri.toString().includes(encodeURIComponent(path))
          ) {
            model.dispose();
          }
        }
      }
      setOpenTabs((prev) => {
        const next = prev.filter((t) => t.path !== path);
        if (activeTabPath === path) {
          if (next.length > 0) {
            const idx = prev.findIndex((t) => t.path === path);
            const nextActive = next[Math.min(idx, next.length - 1)].path;
            setActiveTabPath(nextActive);
            revealInExplorer(nextActive);
          } else {
            setActiveTabPath('');
            setIsEditMode(false);
            setActivePane('files');
          }
        }
        return next;
      });
    },
    [openTabs, activeTabPath, monaco, revealInExplorer]
  );

  // Global keyboard shortcuts for Cmd+S / Ctrl+S and Cmd+Shift+S / Ctrl+Shift+S
  useEffect(() => {
    if (!isEditMode || isReadOnlyDirectory) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        e.stopPropagation();
        if (e.shiftKey) {
          void saveAllFiles();
        } else {
          void saveActiveFile();
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown, true);
    return () => window.removeEventListener('keydown', handleKeyDown, true);
  }, [isEditMode, isReadOnlyDirectory, saveActiveFile, saveAllFiles]);

  // ---- Mutations ------------------------------------------------------------

  async function submitPending() {
    if (isReadOnlyDirectory) return;
    const name = nameDraft.trim();
    if (!pending) return;
    setError('');
    try {
      if (pending.kind === 'new-file') {
        if (!name) return;
        const targetPath = joinPath(cwd, name);
        const res = await createFile({ ...activeFsTarget, path: targetPath }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.cause, res.error?.message) || 'Could not create file');
        setPending(null);
        setNameDraft('');
        await load(cwd);
        void openFileInEditor(targetPath);
        return;
      } else if (pending.kind === 'new-dir') {
        if (!name) return;
        const res = await createDir({ ...activeFsTarget, path: joinPath(cwd, name) }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.cause, res.error?.message) || 'Could not create folder');
      } else if (pending.kind === 'rename') {
        if (!name || name === pending.entry.name) {
          setPending(null);
          return;
        }
        const from = joinPath(cwd, pending.entry.name);
        const to = joinPath(cwd, name);
        const res = await movePath({ ...activeFsTarget, from, to }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.cause, res.error?.message) || 'Could not rename');
      }
      setPending(null);
      setNameDraft('');
      await load(cwd);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Action failed');
    }
  }

  async function removeEntry(entry: FsEntry) {
    if (isReadOnlyDirectory) return;
    setError('');
    const target = joinPath(cwd, entry.name);
    const label = entry.is_dir ? 'folder' : 'file';
    // eslint-disable-next-line no-alert
    if (!window.confirm(`Delete ${label} "${entry.name}"?${entry.is_dir ? ' This removes everything inside it.' : ''}`)) {
      return;
    }
    try {
      const res = await deletePath({ ...activeFsTarget, path: target, recursive: entry.is_dir }).unwrap();
      if (!res.ok) {
        setError(mutationError(res.error?.cause, res.error?.message) || 'Could not delete');
        return;
      }
      await load(cwd);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Delete failed');
    }
  }

  function beginAction(action: PendingAction) {
    if (isReadOnlyDirectory && action?.kind !== null) return;
    setPending(action);
    setNameDraft(action?.kind === 'rename' ? action.entry.name : '');
  }

  const commandPaletteContext = useMemo<EditorCommandContext>(() => {
    return {
      editor: monacoEditorRef.current,
      monaco,
      activeTab: activeEditorTab,
      openSearchInFiles: () => {
        setIsSearchDrawerOpen(true);
        if (isExplorerCollapsed) updateExplorerCollapsed(false);
        if (isSinglePane) setActivePane('files');
      },
      openQuickOpen: () => {
        setIsQuickOpenOpen(true);
      },
      saveActiveFile: () => {
        void saveActiveFile();
      },
      saveAllFiles: () => {
        void saveAllFiles();
      },
      toggleWordWrap,
      toggleMinimap,
      isWordWrap,
      isMinimapEnabled,
      restartLsp: () => {
        lsp.restart?.();
      },
      switchDirectoryScope: () => {
        if (availableDirectories.length > 1) {
          const currIdx = availableDirectories.findIndex((d) => d.id === activeDirectoryId);
          const nextIdx = (currIdx + 1) % availableDirectories.length;
          switchDirectory(availableDirectories[nextIdx].id);
        }
      },
      switchDirectory,
      availableDirectories,
      activeDirectoryId,
    };
  }, [
    monaco,
    activeEditorTab,
    isExplorerCollapsed,
    updateExplorerCollapsed,
    isSinglePane,
    saveActiveFile,
    saveAllFiles,
    toggleWordWrap,
    toggleMinimap,
    isWordWrap,
    isMinimapEnabled,
    lsp,
    availableDirectories,
    activeDirectoryId,
    switchDirectory,
  ]);

  // ---- Render ---------------------------------------------------------------

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-surface';

  return (
    <div ref={panelRootRef} data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>

      {/* Pending review comments bar — spans ALL files in this conversation. */}
      {comments.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-comments-bar`} className="flex items-center gap-2 border-b border-accent/30 bg-accent/10 px-3 py-2">
          <div data-debug-id={`${debugPrefix}-comments-count`} className="min-w-0 flex-1 text-[11.5px] text-accent">
            {comments.length} comment{comments.length === 1 ? '' : 's'} on {filesWithComments} file{filesWithComments === 1 ? '' : 's'}
            {publishError ? <span className="ml-2 text-danger">{publishError}</span> : null}
          </div>
          <button
            data-debug-id={`${debugPrefix}-comments-clear-btn`}
            type="button"
            onClick={() => { setComments([]); setPublishError(''); }}
            disabled={publishing}
            className="shrink-0 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
          >
            Clear
          </button>
          <button
            data-debug-id={`${debugPrefix}-comments-send-btn`}
            type="button"
            onClick={() => void publishComments()}
            disabled={publishing || !onPublishComments}
            className="shrink-0 rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
            title={onPublishComments ? 'Send all comments to the agent' : 'Sending is unavailable here'}
          >
            {publishing ? 'Sending…' : 'Send to agent'}
          </button>
        </div>
      ) : null}

      {!projectId ? (
        <div data-debug-id={`${debugPrefix}-no-project`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No project is associated with this conversation.
        </div>
      ) : (
        <>
          {/* Unified 34px Top Icon Bar */}
          <div
            data-debug-id={`${debugPrefix}-unified-top-bar`}
            className="flex h-[34px] min-h-[34px] max-h-[34px] w-full shrink-0 items-center justify-between border-b border-subtle bg-surface px-2 gap-1 text-[12px] select-none"
          >
            {/* Left section: Strictly 3 primary icons + breadcrumb:
                1) Explorer / Back to Files toggle button
                2) Quick Open (search icon)
                3) Save active file (save icon, highlighted when dirty)
                4) Active file path breadcrumb (with ellipsis on narrow widths)
            */}
            <div className="flex min-w-0 flex-1 items-center gap-1 overflow-hidden">
              {/* 1) Explorer / Back to Files toggle button */}
              <button
                data-debug-id={`${debugPrefix}-explorer-toggle-btn`}
                type="button"
                onClick={() => {
                  if (isSinglePane) {
                    setActivePane((p) => (p === 'files' ? 'editor' : 'files'));
                  } else {
                    updateExplorerCollapsed((prev) => !prev);
                  }
                }}
                title={
                  isSinglePane
                    ? activePane === 'files'
                      ? 'Switch to editor'
                      : 'Back to files'
                    : isExplorerCollapsed
                    ? 'Expand file explorer'
                    : 'Collapse file explorer'
                }
                aria-label={
                  isSinglePane
                    ? activePane === 'files'
                      ? 'Switch to editor'
                      : 'Back to files'
                    : isExplorerCollapsed
                    ? 'Expand file explorer'
                    : 'Collapse file explorer'
                }
                className="grid h-6 w-6 shrink-0 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
              >
                <Icon name="panel-left" size={14} />
              </button>

              {/* 2) Quick Open (search icon, Cmd+P / Ctrl+P) */}
              <button
                data-debug-id={`${debugPrefix}-quick-open-btn`}
                type="button"
                onClick={() => (onOpenQuickOpen ? onOpenQuickOpen() : setIsQuickOpenOpen(true))}
                title="Quick open file (Cmd+P / Ctrl+P)"
                aria-label="Quick open file"
                className="grid h-6 w-6 shrink-0 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
              >
                <Icon name="search" size={14} />
              </button>

              {/* 2b) Search in Files (Cmd+Shift+F / Ctrl+Shift+F) */}
              <button
                data-debug-id={`${debugPrefix}-search-in-files-btn`}
                type="button"
                onClick={() => {
                  if (onOpenSearchInFiles) {
                    onOpenSearchInFiles();
                  } else {
                    setIsSearchDrawerOpen((prev) => {
                      const next = !prev;
                      if (next) {
                        if (isExplorerCollapsed) updateExplorerCollapsed(false);
                        if (isSinglePane) setActivePane('files');
                      }
                      return next;
                    });
                  }
                }}
                title="Search in files (Cmd+Shift+F / Ctrl+Shift+F)"
                aria-label="Search in files"
                aria-pressed={isSearchDrawerOpen ? 'true' : 'false'}
                className={`grid h-6 w-6 shrink-0 place-items-center rounded transition-colors ${
                  isSearchDrawerOpen
                    ? 'bg-accent/20 text-accent font-semibold shadow-xs'
                    : 'hover:bg-neutral-soft text-muted hover:text-primary'
                }`}
              >
                <Icon name="search" size={14} />
              </button>

              {/* 3) Save active file (save icon, highlighted when dirty) */}
              {!isReadOnlyDirectory ? (
                <button
                  data-debug-id="editor-save-btn"
                  type="button"
                  disabled={!activeEditorTab || writeState.isLoading || !activeEditorTab.isDirty || activeEditorTab.isImage || activeEditorTab.isUnviewable}
                  onClick={saveActiveFile}
                  className={`inline-flex items-center justify-center gap-1 h-6 px-2 rounded text-[11px] font-semibold transition-colors disabled:opacity-40 shrink-0 ${
                    activeEditorTab?.isDirty
                      ? 'bg-accent text-accent-fg hover:opacity-90 shadow-xs'
                      : 'hover:bg-neutral-soft text-muted hover:text-primary'
                  }`}
                  title="Save active file (Cmd+S / Ctrl+S)"
                  aria-label="Save active file"
                >
                  {writeState.isLoading ? (
                    <Icon name="refresh" size={12} className="animate-spin" />
                  ) : (
                    <Icon name="save" size={13} />
                  )}
                  <span className="hidden sm:inline">Save</span>
                </button>
              ) : null}

              {/* 4) Directory selector, bridge badge & active file path breadcrumb */}
              <div data-debug-id={`${debugPrefix}-breadcrumb`} className="flex min-w-0 flex-1 items-center gap-1.5 pl-1 text-[11.5px] text-muted">
                {/* Task Chain Directory Selector Dropdown */}
                <TaskChainDirectorySelector
                  activeDirectory={activeDirectory}
                  directories={availableDirectories}
                  bridges={bridges}
                  onSelectDirectory={switchDirectory}
                  debugPrefix={debugPrefix}
                />

                {/* '+' icon button to open Add Chain Directory modal (REQ-UI-ADD-DIRECTORY-MODAL) */}
                <button
                  data-debug-id="add-task-chain-directory-btn"
                  type="button"
                  onClick={() => setIsAddDirectoryOpen(true)}
                  title="Add Directory to Task Chain"
                  aria-label="Add Directory to Task Chain"
                  className="grid h-5 w-5 shrink-0 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
                >
                  <Icon name="plus" size={12} />
                </button>

                {/* Dedicated Bridge Name Badge for Active Directory */}
                <span
                  data-debug-id="active-directory-bridge-badge"
                  className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-medium text-muted shrink-0"
                  title={`Bridge: ${activeBridgeDisplay.name} (${activeBridgeDisplay.id})`}
                >
                  {activeBridgeDisplay.name}
                </span>

                <span className="text-faint shrink-0">/</span>

                {activeEditorTab ? (
                  <div className="flex min-w-0 items-center gap-1 overflow-hidden">
                    {/* Locate button: reveal active file in explorer and expand if collapsed (REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS) */}
                    <button
                      data-debug-id="project-files-locate-file-btn"
                      type="button"
                      onClick={() => {
                        revealInExplorer(activeEditorTab.path);
                        if (isExplorerCollapsed) updateExplorerCollapsed(false);
                        if (isSinglePane) setActivePane('files');
                      }}
                      title="Locate active file in explorer"
                      aria-label="Locate active file in explorer"
                      className="grid h-5 w-5 shrink-0 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-accent transition-colors"
                    >
                      <Icon name="folder-open" size={13} />
                    </button>
                    <span className="truncate font-mono text-[11.5px] text-primary/80" title={activeEditorTab.path}>
                      {activeEditorTab.path}
                    </span>
                    {isReadOnlyDirectory ? (
                      <span
                        data-debug-id={`${debugPrefix}-read-only-badge`}
                        className="rounded bg-neutral-soft px-1.5 py-0.5 text-[9.5px] font-medium text-muted shrink-0"
                      >
                        Read-only
                      </span>
                    ) : null}
                  </div>
                ) : (
                  <div className="flex min-w-0 items-center gap-0.5 overflow-hidden truncate">
                    {crumbs.map((c, i) => (
                      <span key={c.path || 'root'} className="flex shrink-0 items-center gap-0.5">
                        {i > 0 ? <Icon name="chevron-right" size={10} className="text-faint" /> : null}
                        <button
                          data-debug-id={`${debugPrefix}-crumb-${i}`}
                          type="button"
                          onClick={() => openDir(c.path)}
                          disabled={i === crumbs.length - 1}
                          className="max-w-[120px] truncate rounded px-1 py-0.5 hover:bg-neutral-soft hover:text-primary disabled:cursor-default disabled:text-primary disabled:hover:bg-transparent"
                        >
                          <VaultText value={i === 0 ? activeDirectory.label : c.label} />
                        </button>
                      </span>
                    ))}
                  </div>
                )}
              </div>

              {openTabs.length > 0 && !isExplorerCollapsed && !isSinglePane ? (
                <button
                  data-debug-id={`${debugPrefix}-toolbar-editor-btn`}
                  type="button"
                  onClick={() => {
                    setIsEditMode(true);
                  }}
                  className="hidden md:inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-medium text-accent hover:bg-accent/15 shrink-0"
                  title="Focus open editor tab"
                >
                  <Icon name="pencil" size={11} /> Editor ({openTabs.length}){openTabs.some((t) => t.isDirty) ? ' •' : ''}
                </button>
              ) : null}
            </div>

            {/* Right section: Toast feedback, Vim badge, and 3-dots overflow menu */}
            <div className="flex shrink-0 items-center gap-1.5 pl-2">
              {/* Save toast feedback */}
              {saveFeedback ? (
                <div
                  data-debug-id={`${debugPrefix}-save-toast`}
                  className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[11px] font-medium transition-all shrink-0 ${
                    saveFeedback.type === 'success'
                      ? 'bg-success-soft text-success border border-success/30'
                      : saveFeedback.type === 'warning'
                      ? 'bg-warning-soft text-warning border border-warning/30'
                      : 'bg-danger-soft text-danger border border-danger/30'
                  }`}
                >
                  <Icon name={saveFeedback.type === 'success' ? 'check' : 'alert'} size={11} />
                  <span className="truncate max-w-[120px]">{saveFeedback.message}</span>
                </div>
              ) : null}

              {/* Optional compact VIM badge in top bar */}
              {isVimMode ? (
                <button
                  data-debug-id={`${debugPrefix}-vim-badge`}
                  type="button"
                  onClick={toggleVimMode}
                  title="Vim mode active (click to toggle)"
                  className="rounded bg-accent/20 px-1.5 py-0.5 text-[10px] font-mono font-bold text-accent hover:bg-accent/30 transition-colors shrink-0"
                >
                  VIM
                </button>
              ) : null}

              {/* Clean 3-dots overflow dropdown menu */}
              <div className="relative shrink-0" ref={overflowRef}>
                <button
                  data-debug-id={`${debugPrefix}-overflow-menu-btn`}
                  type="button"
                  onClick={() => setIsOverflowOpen((prev) => !prev)}
                  aria-haspopup="true"
                  aria-expanded={isOverflowOpen ? 'true' : 'false'}
                  title="More actions"
                  aria-label="More actions"
                  className={`grid h-6 w-6 place-items-center rounded transition-colors ${
                    isOverflowOpen ? 'bg-neutral-soft text-primary' : 'hover:bg-neutral-soft text-muted hover:text-primary'
                  }`}
                >
                  <Icon name="more-vertical" size={14} />
                </button>

                {isOverflowOpen ? (
                  <div
                    data-debug-id={`${debugPrefix}-overflow-dropdown`}
                    className="absolute right-0 top-full mt-1 w-56 rounded-lg border border-subtle bg-surface-raised p-1 shadow-lg z-50 text-[12px] flex flex-col gap-0.5"
                  >
                    {/* 1. New File */}
                    {!isReadOnlyDirectory ? (
                      <button
                        data-debug-id={`${debugPrefix}-new-file-btn`}
                        type="button"
                        onClick={() => {
                          setIsOverflowOpen(false);
                          if (isExplorerCollapsed) updateExplorerCollapsed(false);
                          if (isSinglePane) setActivePane('files');
                          beginAction({ kind: 'new-file' });
                        }}
                        className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                      >
                        <Icon name="plus" size={14} />
                        <span>New File</span>
                      </button>
                    ) : null}

                    {/* 2. New Folder */}
                    {!isReadOnlyDirectory ? (
                      <button
                        data-debug-id={`${debugPrefix}-new-dir-btn`}
                        type="button"
                        onClick={() => {
                          setIsOverflowOpen(false);
                          if (isExplorerCollapsed) updateExplorerCollapsed(false);
                          if (isSinglePane) setActivePane('files');
                          beginAction({ kind: 'new-dir' });
                        }}
                        className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                      >
                        <Icon name="folder" size={14} />
                        <span>New Folder</span>
                      </button>
                    ) : null}

                    {/* 3. Toggle Hidden Files */}
                    <button
                      data-debug-id={`${debugPrefix}-hidden-toggle`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        setIncludeHidden((v) => !v);
                      }}
                      aria-pressed={includeHidden ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name={includeHidden ? 'eye' : 'eye-off'} size={14} />
                      <span>{includeHidden ? 'Hide Hidden Files' : 'Show Hidden Files'}</span>
                    </button>

                    {/* 4. Refresh Explorer */}
                    <button
                      data-debug-id={`${debugPrefix}-refresh-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        refresh();
                      }}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name="refresh" size={14} />
                      <span>Refresh Explorer</span>
                    </button>

                    <div className="my-1 border-t border-subtle/60" />

                    {/* 5. Toggle In-Editor Diff */}
                    <button
                      data-debug-id="editor-toggle-diff-btn"
                      type="button"
                      disabled={!activeEditorTab || activeEditorTab.isImage || activeEditorTab.isUnviewable}
                      onClick={() => {
                        setIsOverflowOpen(false);
                        setIsDiffMode((prev) => !prev);
                      }}
                      aria-pressed={isDiffMode ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors disabled:opacity-40"
                    >
                      <span className="font-mono font-bold text-xs leading-none">±</span>
                      <span>{isDiffMode ? 'Standard Editor' : 'Toggle In-Editor Diff'}</span>
                      {isDiffMode ? <Icon name="check" size={13} className="ml-auto text-accent" /> : null}
                    </button>

                    {/* 6. Toggle Vim Mode */}
                    <button
                      data-debug-id={`${debugPrefix}-toggle-vim-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        toggleVimMode();
                      }}
                      aria-pressed={isVimMode ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <span className="font-mono font-bold text-xs leading-none">V</span>
                      <span>Toggle Vim Mode</span>
                      {isVimMode ? <Icon name="check" size={13} className="ml-auto text-accent" /> : null}
                    </button>

                    {/* Toggle Word Wrap (REQ-UI-MOBILE-WORD-WRAP) */}
                    <button
                      data-debug-id={`${debugPrefix}-toggle-word-wrap-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        toggleWordWrap();
                      }}
                      aria-pressed={isWordWrap ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name="pencil" size={14} />
                      <span>Toggle Word Wrap</span>
                      {isWordWrap ? <Icon name="check" size={13} className="ml-auto text-accent" /> : null}
                    </button>

                    {/* 7. Save All Files */}
                    <button
                      data-debug-id="editor-save-all-btn"
                      type="button"
                      disabled={batchWriteState.isLoading || openTabs.filter((t) => t.isDirty).length === 0}
                      onClick={() => {
                        setIsOverflowOpen(false);
                        saveAllFiles();
                      }}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors disabled:opacity-40"
                    >
                      <Icon name="save" size={14} />
                      <span>Save All Files {openTabs.filter((t) => t.isDirty).length > 0 ? `(${openTabs.filter((t) => t.isDirty).length})` : ''}</span>
                    </button>

                    <div className="my-1 border-t border-subtle/60" />

                    {/* 8. Comment on Current File / Folder */}
                    {activeEditorTab ? (
                      <button
                        data-debug-id={`${debugPrefix}-file-comment-btn`}
                        type="button"
                        onClick={() => {
                          setIsOverflowOpen(false);
                          setPathCommentDraft('');
                          setPathCommentFor({
                            path: activeEditorTab.path,
                            label: `file: ${baseName(activeEditorTab.path)}`,
                          });
                        }}
                        className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                      >
                        <Icon name="chat" size={14} />
                        <span>Comment on Active File</span>
                      </button>
                    ) : (
                      <button
                        data-debug-id={`${debugPrefix}-folder-comment-btn`}
                        type="button"
                        onClick={() => {
                          setIsOverflowOpen(false);
                          setPathCommentDraft('');
                          setPathCommentFor({
                            path: cwd || '/',
                            label: `folder: ${cwd || 'project root'}`,
                          });
                        }}
                        className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                      >
                        <Icon name="chat" size={14} />
                        <span>Comment on Current Folder</span>
                      </button>
                    )}
                  </div>
                ) : null}
              </div>
            </div>
          </div>

          {/* Split Container */}
          <div data-debug-id={`${debugPrefix}-split-container`} className="flex min-h-0 flex-1 w-full flex-row overflow-hidden">
            {/* Left Column: Directory Explorer */}
            <div
              data-debug-id={`${debugPrefix}-explorer-pane`}
              style={!isSinglePane && !isExplorerCollapsed ? { width: explorerWidth } : undefined}
              className={`${
                isSinglePane
                  ? activePane === 'files'
                    ? 'w-full flex-1'
                    : 'hidden'
                  : isExplorerCollapsed
                  ? 'hidden'
                  : 'flex'
              } min-h-0 flex-col border-r border-subtle bg-surface shrink-0`}
            >
              {/* Explorer / Search Mode Tabs */}
              <div className="flex items-center border-b border-subtle px-2 py-1 gap-1 shrink-0 bg-surface-raised/40">
                <button
                  type="button"
                  data-debug-id={`${debugPrefix}-tab-files`}
                  onClick={() => setIsSearchDrawerOpen(false)}
                  className={`flex items-center gap-1.5 px-2 py-0.5 rounded text-[11px] font-medium transition-colors ${
                    !isSearchDrawerOpen
                      ? 'bg-neutral-soft text-primary font-semibold shadow-xs'
                      : 'text-muted hover:bg-neutral-soft hover:text-primary'
                  }`}
                >
                  <Icon name="folder" size={12} className={!isSearchDrawerOpen ? 'text-accent' : 'text-muted'} />
                  <span>Files</span>
                </button>
                <button
                  type="button"
                  data-debug-id={`${debugPrefix}-tab-search`}
                  onClick={() => setIsSearchDrawerOpen(true)}
                  className={`flex items-center gap-1.5 px-2 py-0.5 rounded text-[11px] font-medium transition-colors ${
                    isSearchDrawerOpen
                      ? 'bg-neutral-soft text-primary font-semibold shadow-xs'
                      : 'text-muted hover:bg-neutral-soft hover:text-primary'
                  }`}
                >
                  <Icon name="search" size={12} className={isSearchDrawerOpen ? 'text-accent' : 'text-muted'} />
                  <span>Search</span>
                </button>
              </div>

              {isSearchDrawerOpen ? (
                <div className="flex-1 min-h-0 flex flex-col">
                  <SearchInFilesDrawer
                    isOpen={isSearchDrawerOpen}
                    onClose={() => setIsSearchDrawerOpen(false)}
                    scopes={searchScopes}
                    activeDirectoryId={activeDirectoryId}
                    onSelectMatch={handleSelectSearchMatch}
                    debugPrefix="search-in-files"
                  />
                </div>
              ) : (
                <>
                  {/* Inline create/rename input */}
              {pending ? (
                <div data-debug-id={`${debugPrefix}-name-editor`} className="flex items-center gap-1.5 border-b border-subtle bg-surface-raised px-3 py-2">
                  <Icon name={pending.kind === 'new-dir' ? 'folder' : 'file'} size={13} className="text-muted" />
                  <input
                    data-debug-id={`${debugPrefix}-name-input`}
                    autoFocus
                    value={nameDraft}
                    onChange={(e) => setNameDraft(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') void submitPending();
                      if (e.key === 'Escape') { setPending(null); setNameDraft(''); }
                    }}
                    placeholder={pending.kind === 'rename' ? 'new name' : pending.kind === 'new-dir' ? 'folder name' : 'file name'}
                    className="min-w-0 flex-1 rounded-lg border border-subtle bg-surface-raised px-2 py-1 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
                  />
                  <button
                    data-debug-id={`${debugPrefix}-name-submit-btn`}
                    type="button"
                    disabled={mutating || !nameDraft.trim()}
                    onClick={() => void submitPending()}
                    className="rounded-lg bg-accent px-2 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
                  >
                    {pending.kind === 'rename' ? 'Rename' : 'Create'}
                  </button>
                  <button
                    type="button"
                    onClick={() => { setPending(null); setNameDraft(''); }}
                    className="rounded-lg px-1.5 py-1 text-caption text-muted hover:text-primary"
                  >
                    Cancel
                  </button>
                </div>
              ) : null}

              {/* Directory list */}
              <div data-debug-id={`${debugPrefix}-list`} className="min-h-0 flex-1 overflow-y-auto p-1">
                {loading ? (
                  <div data-debug-id={`${debugPrefix}-loading`} className="p-4 text-center text-xs text-muted">Loading…</div>
                ) : error && sortedEntries.length === 0 ? (
                  <div data-debug-id={`${debugPrefix}-load-error`} className="p-6 text-center text-xs text-muted">Couldn’t load files — see the message below.</div>
                ) : sortedEntries.length === 0 && cwd === '' ? (
                  <div data-debug-id={`${debugPrefix}-empty`} className="p-6 text-center text-xs text-faint">This folder is empty.</div>
                ) : (
                  <ul className="space-y-0.5">
                    {/* Compact .. (parent folder) row when in subfolder */}
                    {cwd !== '' ? (
                      <li key="..-parent-folder" className="group flex items-center h-7 py-0.5 px-2 text-[12px] hover:bg-neutral-soft rounded cursor-pointer select-none">
                        <button
                          data-debug-id={`${debugPrefix}-parent-dir`}
                          type="button"
                          onClick={() => openDir(parentPath(cwd))}
                          className="flex min-w-0 flex-1 items-center gap-2 text-left text-muted hover:text-primary"
                          title="Navigate to parent folder"
                        >
                          <Icon name="folder" size={14} className="shrink-0 text-muted" />
                          <span className="min-w-0 flex-1 truncate font-medium">.. (parent folder)</span>
                        </button>
                      </li>
                    ) : null}

                    {sortedEntries.map((e) => {
                      const isOpening = !e.is_dir && openingInEditor === joinPath(cwd, e.name);
                      const isActiveFile = !e.is_dir && activeTabPath === joinPath(cwd, e.name);
                      return (
                        <li
                          key={`${e.is_dir ? 'd' : 'f'}:${e.name}`}
                          ref={isActiveFile ? activeEntryRef : undefined}
                          data-debug-id={isActiveFile ? 'project-files-active-entry' : undefined}
                          data-active-file={isActiveFile ? 'true' : 'false'}
                          className={`group flex items-center h-7 py-0.5 px-2 text-[12px] rounded select-none ${
                            isActiveFile ? 'bg-accent/15 text-accent font-medium ring-1 ring-accent/30 shadow-xs' : 'hover:bg-neutral-soft text-primary'
                          }`}
                        >
                          <button
                            data-debug-id={`${debugPrefix}-entry-${e.name}`}
                            type="button"
                            disabled={isOpening}
                            onClick={() => (e.is_dir ? openDir(joinPath(cwd, e.name)) : void openFileInEditor(joinPath(cwd, e.name)))}
                            className="flex min-w-0 flex-1 items-center gap-2 text-left"
                          >
                            {isOpening ? (
                              <Icon name="refresh" size={14} className="shrink-0 animate-spin text-accent" title="Loading file…" />
                            ) : (
                              <Icon name={e.is_dir ? 'folder' : 'file'} size={14} className={`shrink-0 ${e.is_dir ? 'text-accent' : isActiveFile ? 'text-accent' : 'text-muted'}`} />
                            )}
                            <span className={`min-w-0 flex-1 truncate text-[12px] ${isActiveFile ? 'font-medium text-accent' : e.hidden ? 'text-faint' : 'text-primary'}`}>{e.name}</span>
                            {e.has_git ? <span className="shrink-0 rounded bg-success-soft px-1.5 py-0.2 text-[9px] font-bold text-success">git</span> : null}
                            {!isNarrowExplorer && !e.is_dir ? <span className="shrink-0 text-[10px] tabular-nums text-faint">{formatBytes(e.size)}</span> : null}
                            {!isNarrowExplorer && e.modified_at ? <span className="hidden shrink-0 text-[10px] text-faint sm:inline">{formatModified(e.modified_at)}</span> : null}
                          </button>
                          {/* Row actions (edit / rename / delete) — visible on hover/focus. */}
                          <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
                            {!e.is_dir ? (
                              <button
                                data-debug-id={`${debugPrefix}-edit-${e.name}`}
                                type="button"
                                onClick={() => void openFileInEditor(joinPath(cwd, e.name))}
                                title={isReadOnlyDirectory ? `View ${e.name}` : `Edit ${e.name}`}
                                aria-label={isReadOnlyDirectory ? `View ${e.name}` : `Edit ${e.name}`}
                                className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
                              >
                                <Icon name={isReadOnlyDirectory ? 'eye' : 'pencil'} size={12} />
                              </button>
                            ) : null}
                            {!isReadOnlyDirectory ? (
                              <>
                                <IconButton icon="pencil" label={`Rename ${e.name}`} size="sm" data-debug-id={`${debugPrefix}-rename-${e.name}`} onClick={() => beginAction({ kind: 'rename', entry: e })} />
                                <button
                                  data-debug-id={`${debugPrefix}-delete-${e.name}`}
                                  type="button"
                                  disabled={mutating}
                                  onClick={() => void removeEntry(e)}
                                  title={`Delete ${e.name}`}
                                  aria-label={`Delete ${e.name}`}
                                  className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-danger-soft hover:text-danger disabled:opacity-40"
                                >
                                  <Icon name="trash" size={12} />
                                </button>
                              </>
                            ) : null}
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                )}

                {/* Load more (cursor pagination) */}
                {hasMore ? (
                  <div className="p-3 text-center">
                    <button
                      data-debug-id={`${debugPrefix}-load-more-btn`}
                      type="button"
                      disabled={loadingMore}
                      onClick={() => void load(cwd, { cursor: nextCursor, append: true })}
                      className="rounded-lg border border-subtle px-3 py-1.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
                    >
                      {loadingMore ? 'Loading…' : 'Load more'}
                    </button>
                  </div>
                ) : null}
                {truncated ? (
                  <div data-debug-id={`${debugPrefix}-truncated`} className="px-3 pb-3 text-center text-[10px] text-warning">
                    Listing truncated to the server maximum.
                  </div>
                ) : null}
              </div>
            </>
          )}
        </div>

            {/* Resizer Divider */}
            {!isExplorerCollapsed && !isSinglePane ? (
              <div
                data-debug-id={`${debugPrefix}-resizer`}
                onMouseDown={startResizing}
                className="w-1 cursor-col-resize hover:bg-accent/40 active:bg-accent transition-colors shrink-0 select-none bg-subtle/20"
                title="Drag to resize explorer"
              />
            ) : null}

            {/* Right Column: Monaco Editor or Empty State */}
            <div
              data-debug-id={`${debugPrefix}-editor-pane`}
              className={`${
                isSinglePane
                  ? activePane === 'editor'
                    ? 'w-full flex-1 flex'
                    : 'hidden'
                  : 'flex flex-1'
              } min-h-0 flex-col overflow-hidden bg-surface`}
            >
              {Array.from(mountedDirIds).map((dirId) => {
                const isCurrent = dirId === activeDirectoryId;
                const dirTabs = isCurrent ? openTabs : (directorySessions[dirId]?.openTabs || []);
                const dirActivePath = isCurrent ? activeTabPath : (directorySessions[dirId]?.activeTabPath || '');
                const dirActiveTab = dirTabs.find((t) => t.path === dirActivePath);
                const dirCwd = isCurrent ? cwd : (directorySessions[dirId]?.cwd || '');
                const dirDiffMode = isCurrent ? isDiffMode : Boolean(directorySessions[dirId]?.isDiffMode);

                return (
                  <div
                    key={dirId}
                    data-debug-id={`directory-editor-container-${dirId}`}
                    style={{ display: isCurrent ? 'flex' : 'none' }}
                    className="min-h-0 flex-1 flex-col w-full h-full"
                  >
                    {/*
                      REQ-LSP-ENV-1: the language server's own complaint, where a
                      user who has never opened a trace file will see it. The
                      markup lives in LspNoticeBanner so it can be mounted and
                      PHOTOGRAPHED on its own — this task exists because a
                      message reached a render path that no user ever saw, and a
                      banner buried in this 4000-line component could not be
                      proven to display without standing up the whole panel.
                    */}
                    {/*
                      ONE BANNER PER OUTSTANDING NOTICE, NOT JUST THE LATEST.
                      gopls reports the CAUSE and the SYMPTOM as two separate
                      messages; rendering only one of them leaves the user with
                      "Error loading workspace folders", which names nothing they
                      can act on. See the list in useMonacoLsp.
                    */}
                    {isCurrent
                      ? lsp.notices.map((n) => (
                          <LspNoticeBanner
                            key={lspServerNoticeKey(n)}
                            notice={n}
                            onDismiss={() => lsp.dismissNotice(lspServerNoticeKey(n))}
                            debugPrefix={debugPrefix}
                          />
                        ))
                      : null}
                    {dirTabs.length > 0 && dirActiveTab ? (
                      <MonacoMultiFileEditor
                        tabs={dirTabs}
                        activeTab={dirActiveTab}
                        onSelectTab={selectTab}
                        onCloseTab={closeTab}
                        onContentChange={handleContentChange}
                        onSaveActive={saveActiveFile}
                        onSaveAll={saveAllFiles}
                        isSaving={writeState.isLoading}
                        isBatchSaving={batchWriteState.isLoading}
                        saveFeedback={saveFeedback}
                        onBackToFiles={() => {
                          if (isSinglePane) setActivePane('files');
                          else updateExplorerCollapsed((prev) => !prev);
                        }}
                        onToggleExplorer={() => {
                          if (isSinglePane) setActivePane('files');
                          else updateExplorerCollapsed((prev) => !prev);
                        }}
                        isExplorerCollapsed={isExplorerCollapsed}
                        onNewFile={handleEditorNewFile}
                        cwd={dirCwd}
                        debugPrefix={debugPrefix}
                        themeAppearance={theme?.appearance}
                        isVimMode={isVimMode}
                        isWordWrap={isWordWrap}
                        isMinimapEnabled={isMinimapEnabled}
                        isReadOnly={isReadOnlyDirectory}
                        comments={commentsForPath(dirActiveTab.path)}
                        onAddComment={(line, lineText, body) => addComment(dirActiveTab.path, line, lineText, body)}
                        onEditComment={editComment}
                        onDeleteComment={deleteComment}
                        onCommentFile={() => {
                          setPathCommentDraft('');
                          setPathCommentFor({
                            path: dirActiveTab.path,
                            label: `file: ${baseName(dirActiveTab.path)}`,
                          });
                        }}
                        isDiffMode={dirDiffMode}
                        onToggleDiff={() => setIsDiffMode((prev) => !prev)}
                        onEditorMount={(ed) => {
                          monacoEditorRef.current = ed;
                        }}
                      />
                    ) : (
                      <div
                        data-debug-id={`${debugPrefix}-editor-empty-state`}
                        className="flex min-h-0 flex-1 flex-col bg-surface"
                      >
                        <div className="flex min-h-0 flex-1 flex-col items-center justify-center p-8 text-center">
                          <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-neutral-soft text-muted mb-3">
                            <Icon name="file" size={28} />
                          </div>
                          <h3 className="text-body font-semibold text-primary mb-1">No Files Open</h3>
                          <p
                            data-debug-id={`${debugPrefix}-empty-prompt`}
                            className="max-w-md text-caption text-muted mb-4"
                          >
                            {isReadOnlyDirectory
                              ? 'Select a file from the explorer to view'
                              : 'Select a file from the explorer to view or edit, or press + to create a new file'}
                          </p>
                          {!isReadOnlyDirectory ? (
                            <button
                              data-debug-id={`${debugPrefix}-empty-new-file-btn`}
                              type="button"
                              onClick={() => void handleEditorNewFile('untitled.txt')}
                              className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-3 py-1.5 text-caption font-semibold text-accent-fg hover:opacity-90"
                              title="Create new file (+)"
                            >
                              <Icon name="plus" size={14} /> + New File
                            </button>
                          ) : null}
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        </>
      )}

      {/* Path-level (file/folder) comment composer overlay. */}
      {pathCommentFor ? (
        <div className="absolute inset-x-0 bottom-0 z-10 border-t border-accent/40 bg-surface p-3 shadow-panel">
          <div data-debug-id={`${debugPrefix}-path-composer`} className="mx-auto max-w-2xl">
            <div className="mb-1 text-caption text-muted">Comment on {pathCommentFor.label}</div>
            <textarea
              data-debug-id={`${debugPrefix}-path-composer-input`}
              autoFocus
              value={pathCommentDraft}
              onChange={(e) => setPathCommentDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') { e.preventDefault(); setPathCommentFor(null); }
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && pathCommentDraft.trim()) {
                  e.preventDefault();
                  addComment(pathCommentFor.path, 0, pathCommentFor.label, pathCommentDraft);
                  setPathCommentFor(null);
                }
              }}
              rows={3}
              placeholder={`Comment on ${pathCommentFor.label}… (Cmd/Ctrl+Enter to save)`}
              className="w-full resize-y rounded border border-subtle bg-surface-raised p-2 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
            />
            <div className="mt-1.5 flex justify-end gap-1.5">
              <button data-debug-id={`${debugPrefix}-path-composer-cancel`} type="button" onClick={() => setPathCommentFor(null)} className="rounded-lg border border-subtle px-2.5 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
              <button
                data-debug-id={`${debugPrefix}-path-composer-save`}
                type="button"
                disabled={!pathCommentDraft.trim()}
                onClick={() => { addComment(pathCommentFor.path, 0, pathCommentFor.label, pathCommentDraft); setPathCommentFor(null); }}
                className="rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                Comment
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {error ? (
        <div data-debug-id={`${debugPrefix}-error`} className="border-t border-danger/30 bg-danger-soft px-3 py-2 text-caption text-danger">
          {error}
        </div>
      ) : null}

      {/* Confirmation modal for closing dirty tabs */}
      {confirmClosePath ? (
        <div
          data-debug-id={`${debugPrefix}-close-confirm-modal`}
          className="absolute inset-0 z-50 flex items-center justify-center bg-canvas/80 backdrop-blur-sm p-4"
        >
          <div className="w-full max-w-sm rounded-xl border border-subtle bg-surface-raised p-4 shadow-xl">
            <div className="flex items-center gap-2 text-warning mb-2">
              <Icon name="alert" size={16} />
              <h4 className="text-body font-semibold text-primary">Unsaved Changes</h4>
            </div>
            <p className="text-caption text-muted mb-4">
              You have unsaved changes in{' '}
              <span className="font-mono text-primary font-medium">
                {baseName(confirmClosePath)}
              </span>
              . Are you sure you want to discard your changes and close this tab?
            </p>
            <div className="flex justify-end gap-2">
              <button
                data-debug-id={`${debugPrefix}-confirm-close-cancel`}
                type="button"
                onClick={() => setConfirmClosePath(null)}
                className="rounded-lg border border-subtle px-3 py-1.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
              >
                Cancel
              </button>
              <button
                data-debug-id={`${debugPrefix}-confirm-close-discard`}
                type="button"
                onClick={() => {
                  closeTab(confirmClosePath, true);
                  setConfirmClosePath(null);
                }}
                className="rounded-lg bg-danger px-3 py-1.5 text-caption font-semibold text-accent-fg hover:opacity-90"
              >
                Discard & Close
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {/* Quick Open Modal (Cmd+P / Ctrl+P) (REQ-UI-GLOBAL-QUICK-OPEN, REQ-UI-DIRECTORY-SCOPED-QUICK-OPEN) */}
      <ProjectQuickOpenModal
        projectId={activeFsTarget.projectId || projectId}
        chainId={activeFsTarget.chainId}
        directoryId={activeFsTarget.directoryId}
        directories={taskChainDirectories}
        activeDirectoryId={activeDirectoryId}
        bridgeId={activeFsTarget.bridgeId || bridgeId}
        isOpen={isQuickOpenOpen}
        onClose={() => setIsQuickOpenOpen(false)}
        onSelectFile={(file) => void openFileInEditor(file)}
        onSwitchToCommandPalette={(initialQuery) => {
          setCommandPaletteInitialQuery(initialQuery ? `>${initialQuery}` : '>');
          setIsCommandPaletteOpen(true);
        }}
      />

      {/* Command Palette Modal (Cmd+Shift+P / Ctrl+Shift+P / F1 / >) (REQ-EDITOR-COMMAND-PALETTE-1) */}
      <ProjectCommandPaletteModal
        isOpen={isCommandPaletteOpen}
        onClose={() => setIsCommandPaletteOpen(false)}
        context={commandPaletteContext}
        initialQuery={commandPaletteInitialQuery}
      />

      {/* Add Directory Modal (REQ-UI-ADD-DIRECTORY-MODAL) */}
      <AddChainDirectoryModal
        isOpen={isAddDirectoryOpen}
        onClose={() => setIsAddDirectoryOpen(false)}
        chainId={chainId}
        bridges={bridges}
        initialBridgeId={bridgeId || activeDirectory.bridgeId}
        onDirectoryAdded={(newDirId) => {
          switchDirectory(newDirId);
        }}
      />
    </div>
  );
}

export function ProjectQuickOpenModal({
  projectId,
  chainId,
  directoryId,
  directories = [],
  activeDirectoryId: propActiveDirId,
  bridgeId = '',
  isOpen,
  onClose,
  onSelectFile,
  onSwitchToCommandPalette,
}: {
  projectId?: string;
  chainId?: string;
  directoryId?: string;
  directories?: TaskChainDirectory[];
  activeDirectoryId?: string;
  bridgeId?: string;
  isOpen: boolean;
  onClose: () => void;
  onSelectFile: (filePath: string) => void;
  onSwitchToCommandPalette?: (initialQuery?: string) => void;
}) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const [fetchQuickOpen, quickOpenState] = useLazyQuickOpenProjectFilesQuery();
  const [quickOpenQuery, setQuickOpenQuery] = useState('');
  const [quickOpenSelectedIndex, setQuickOpenSelectedIndex] = useState(0);
  const [quickOpenAllFiles, setQuickOpenAllFiles] = useState<string[]>([]);

  useDialogA11y(isOpen, onClose, panelRef);

  const activeDirId = propActiveDirId || directoryId || 'primary';
  const targetDir = (directories || []).find((d) => d.directoryId === activeDirId);
  const isPrimary = activeDirId === 'primary' || !targetDir;

  const scopeArgs: FsScopeArgs = useMemo(() => {
    if (isPrimary) {
      return {
        projectId,
        bridgeId,
      };
    }
    return {
      chainId,
      directoryId: targetDir?.directoryId,
      bridgeId: targetDir?.bridgeId || bridgeId,
    };
  }, [isPrimary, projectId, bridgeId, chainId, targetDir]);

  const scopeLabel = useMemo(() => {
    if (isPrimary) return 'Primary Project';
    return baseName(targetDir?.path || '') || targetDir?.directoryId || 'Directory';
  }, [isPrimary, targetDir]);

  useEffect(() => {
    if (isOpen && (scopeArgs.projectId || (scopeArgs.chainId && scopeArgs.directoryId))) {
      setQuickOpenQuery('');
      setQuickOpenSelectedIndex(0);
      window.setTimeout(() => inputRef.current?.focus(), 0);
      void fetchQuickOpen({ ...scopeArgs, query: '', limit: 1000 })
        .unwrap()
        .then((res) => {
          if (res?.ok && Array.isArray(res.files)) {
            setQuickOpenAllFiles(res.files);
          }
        })
        .catch(() => {});
    }
  }, [isOpen, scopeArgs, fetchQuickOpen]);

  useEffect(() => {
    if (!isOpen || (!scopeArgs.projectId && (!scopeArgs.chainId || !scopeArgs.directoryId))) return;
    const q = quickOpenQuery.trim();
    if (!q) return;
    const timer = setTimeout(() => {
      void fetchQuickOpen({ ...scopeArgs, query: q, limit: 500 })
        .unwrap()
        .then((res) => {
          if (res?.ok && Array.isArray(res.files)) {
            setQuickOpenAllFiles((prev) => {
              const set = new Set([...prev, ...res.files]);
              return Array.from(set);
            });
          }
        })
        .catch(() => {});
    }, 150);
    return () => clearTimeout(timer);
  }, [quickOpenQuery, isOpen, scopeArgs, fetchQuickOpen]);

  useEffect(() => {
    if (!listRef.current) return;
    const el = listRef.current.querySelector<HTMLElement>(`[data-quick-open-index="${quickOpenSelectedIndex}"]`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [quickOpenSelectedIndex]);

  const filteredQuickOpenFiles = useMemo(() => {
    if (!quickOpenQuery.trim()) return quickOpenAllFiles.slice(0, 50);
    const q = quickOpenQuery.trim();
    return quickOpenAllFiles
      .filter((file) => subsequenceFuzzyMatch(q, file))
      .sort((a, b) => fuzzyMatchScore(q, b) - fuzzyMatchScore(q, a))
      .slice(0, 50);
  }, [quickOpenAllFiles, quickOpenQuery]);

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="project-quick-open-modal"
      role="presentation"
      className="fixed inset-x-0 top-0 app-viewport-height z-modal flex items-start justify-center bg-surface-overlay/80 px-2 pt-[max(env(safe-area-inset-top),0.5rem)] backdrop-blur-sm sm:px-4 sm:pt-[calc(var(--app-viewport-height)*0.12)]"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Quick open files"
        className="flex max-h-[calc(var(--app-viewport-height)-1rem)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface-overlay shadow-overlay outline-none sm:max-h-[calc(var(--app-viewport-height)*0.7)]"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-subtle px-4 py-3">
          <span aria-hidden="true" className="text-muted"><Icon name="search" size={16} /></span>
          <span
            data-debug-id="quick-open-scope-badge"
            className="rounded bg-neutral-soft px-2 py-0.5 text-[11px] font-medium text-muted shrink-0"
            title={`Scope: ${scopeLabel}`}
          >
            {scopeLabel}
          </span>
          <input
            ref={inputRef}
            data-debug-id="project-quick-open-input"
            type="text"
            value={quickOpenQuery}
            onChange={(e) => {
              const val = e.target.value;
              if (val.startsWith('>')) {
                onClose();
                onSwitchToCommandPalette?.(val.slice(1).trimStart());
                return;
              }
              setQuickOpenQuery(val);
              setQuickOpenSelectedIndex(0);
            }}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setQuickOpenSelectedIndex((prev) =>
                  filteredQuickOpenFiles.length > 0 ? (prev + 1) % filteredQuickOpenFiles.length : 0
                );
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setQuickOpenSelectedIndex((prev) =>
                  filteredQuickOpenFiles.length > 0
                    ? (prev - 1 + filteredQuickOpenFiles.length) % filteredQuickOpenFiles.length
                    : 0
                );
              } else if (e.key === 'Enter') {
                e.preventDefault();
                if (filteredQuickOpenFiles.length > 0) {
                  const selected = filteredQuickOpenFiles[quickOpenSelectedIndex] || filteredQuickOpenFiles[0];
                  if (selected) {
                    onClose();
                    onSelectFile(selected);
                  }
                }
              }
            }}
            placeholder="Search files by name or path (Cmd+P / Ctrl+P)…"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-primary outline-none placeholder:text-faint"
            autoComplete="off"
            spellCheck={false}
          />
          <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted">esc</kbd>
        </div>

        <div
          ref={listRef}
          data-debug-id="project-quick-open-results"
          className="flex-1 overflow-y-auto p-2"
        >
          {filteredQuickOpenFiles.length === 0 ? (
            <div className="px-3 py-8 text-center text-sm text-muted">
              {quickOpenState.isLoading ? 'Searching project files…' : 'No matching files found.'}
            </div>
          ) : (
            filteredQuickOpenFiles.map((file, idx) => {
              const isSelected = idx === quickOpenSelectedIndex;
              const name = baseName(file);
              const dir = parentPath(file);
              return (
                <div
                  key={file}
                  data-debug-id={`quick-open-item-${file}`}
                  data-selected={isSelected ? 'true' : 'false'}
                  data-quick-open-index={idx}
                  onClick={() => {
                    onClose();
                    onSelectFile(file);
                  }}
                  onMouseEnter={() => setQuickOpenSelectedIndex(idx)}
                  className={`flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm ${
                    isSelected ? 'bg-neutral-soft text-primary font-semibold' : 'text-muted hover:bg-neutral-soft hover:text-primary'
                  }`}
                >
                  <span aria-hidden="true" className="grid w-5 place-items-center text-muted opacity-80">
                    <Icon name="file" size={16} className={isSelected ? 'text-primary' : 'text-muted'} />
                  </span>
                  <span className="flex min-w-0 flex-1 items-center gap-2">
                    <span className="truncate text-primary">{name}</span>
                    {dir ? <span className="truncate text-caption text-faint ml-auto font-mono text-[11px]">{dir}</span> : null}
                  </span>
                </div>
              );
            })
          )}
        </div>

        <div className="flex items-center justify-between border-t border-subtle bg-surface-raised px-4 py-2 text-[11px] text-muted">
          <span>{filteredQuickOpenFiles.length} file{filteredQuickOpenFiles.length === 1 ? '' : 's'}</span>
          <div className="flex items-center gap-2">
            <span><kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↑↓</kbd> navigate</span>
            <span><kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↵</kbd> select</span>
          </div>
        </div>
      </div>
    </div>
  );
}

export function AddChainDirectoryModal({
  isOpen,
  onClose,
  chainId,
  bridges = [],
  initialBridgeId = '',
  onDirectoryAdded,
}: {
  isOpen: boolean;
  onClose: () => void;
  chainId?: string;
  bridges?: any[];
  initialBridgeId?: string;
  onDirectoryAdded: (newDirId: string) => void;
}) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  useDialogA11y(isOpen, onClose, panelRef);

  const [addChainDirectory] = useAddChainDirectoryMutation();
  const [error, setError] = useState<string>('');

  const normalizedBridges = useMemo(() => {
    const list = Array.isArray(bridges) ? bridges : [];
    if (list.length > 0) return list;
    return [{ bridge_id: 'local', name: 'local', status: 'online' }];
  }, [bridges]);

  const [selectedBridgeId, setSelectedBridgeId] = useState<string>(() => {
    if (initialBridgeId) return initialBridgeId;
    const online = normalizedBridges.find(
      (b: any) => b.status === 'online' || b.runtime_status === 'online'
    );
    return String(
      online?.bridge_id ||
        online?.bridgeId ||
        online?.id ||
        normalizedBridges[0]?.bridge_id ||
        normalizedBridges[0]?.bridgeId ||
        normalizedBridges[0]?.id ||
        'local'
    );
  });

  useEffect(() => {
    if (isOpen) {
      setError('');
      if (initialBridgeId) {
        setSelectedBridgeId(initialBridgeId);
      } else if (!selectedBridgeId && normalizedBridges.length > 0) {
        const online = normalizedBridges.find(
          (b: any) => b.status === 'online' || b.runtime_status === 'online'
        );
        setSelectedBridgeId(
          String(
            online?.bridge_id ||
              online?.bridgeId ||
              online?.id ||
              normalizedBridges[0]?.bridge_id ||
              normalizedBridges[0]?.bridgeId ||
              normalizedBridges[0]?.id ||
              'local'
          )
        );
      }
    }
  }, [isOpen, initialBridgeId, normalizedBridges]);

  const activeBridgeInfo = useMemo(() => {
    return getBridgeDisplay(selectedBridgeId, normalizedBridges);
  }, [selectedBridgeId, normalizedBridges]);

  const handlePick = async (chosenPath: string) => {
    if (!chainId) {
      setError('Task chain ID is required to link directory');
      return;
    }
    if (!chosenPath) {
      setError('Please choose a valid directory path');
      return;
    }
    setError('');
    try {
      const res = await addChainDirectory({
        chainId,
        path: chosenPath,
        bridgeId: selectedBridgeId,
      }).unwrap();

      const newDirId =
        res?.directory_id ||
        res?.directoryId ||
        res?.data?.directory_id ||
        res?.data?.directoryId;

      onClose();
      if (newDirId) {
        onDirectoryAdded(String(newDirId));
      }
    } catch (err: any) {
      setError(
        String(err?.data?.error || err?.error || err?.message || 'Failed to add directory')
      );
    }
  };

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="add-chain-directory-modal-backdrop"
      role="presentation"
      // REQ-MODAL-2: `app-viewport-height`, not `inset-0` — see the OVERLAYS note in `src/ui/styles.css`.
      className="fixed inset-x-0 top-0 app-viewport-height z-modal flex items-center justify-center bg-surface-overlay/80 p-4 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Add Directory to Task Chain"
        data-debug-id="add-chain-directory-modal"
        className="flex max-h-[calc(var(--app-viewport-height)*0.9)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface shadow-overlay outline-none"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-subtle px-4 py-3">
          <div className="flex items-center gap-2">
            <span className="grid h-7 w-7 place-items-center rounded-md bg-accent/15 text-accent">
              <Icon name="folder" size={16} />
            </span>
            <div>
              <h2 className="text-sm font-semibold text-primary">Add Directory to Task Chain</h2>
              <p className="text-[11px] text-muted">Select a bridge host and browse to link a workspace directory</p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close dialog"
            className="grid h-7 w-7 place-items-center rounded-md text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
          >
            <Icon name="close" size={14} />
          </button>
        </div>

        {/* Bridge Selector (strictly NO native select tags) */}
        <div className="flex flex-col gap-2 border-b border-subtle bg-surface-overlay/40 px-4 py-3">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-muted">Select Bridge Host:</span>
            <span className="text-[11px] text-faint">
              Active: <span className="font-semibold text-primary">{activeBridgeInfo.name}</span>
            </span>
          </div>
          <div data-debug-id="add-chain-dir-bridge-selector" className="flex flex-wrap items-center gap-2">
            {normalizedBridges.map((b: any) => {
              const bId = String(b.bridge_id || b.bridgeId || b.id || '');
              const bInfo = getBridgeDisplay(bId, normalizedBridges);
              const isSelected = selectedBridgeId === bInfo.id;
              return (
                <button
                  key={bInfo.id}
                  type="button"
                  data-debug-id={`add-chain-dir-bridge-option-${bInfo.id}`}
                  onClick={() => setSelectedBridgeId(bInfo.id)}
                  className={`inline-flex items-center gap-2 rounded-lg border px-3 py-1.5 text-xs transition-colors ${
                    isSelected
                      ? 'border-accent bg-accent/10 text-primary font-semibold shadow-xs'
                      : 'border-subtle bg-surface text-muted hover:border-subtle-hover hover:text-primary'
                  }`}
                >
                  <span
                    className={`h-2 w-2 rounded-full shrink-0 ${
                      bInfo.isOnline ? 'bg-success shadow-xs' : 'bg-muted/40'
                    }`}
                  />
                  <span className="truncate">{bInfo.name}</span>
                  <span className="font-mono text-[10.5px] text-faint">({bInfo.id})</span>
                  <span
                    data-debug-id={`bridge-online-badge-${bInfo.id}`}
                    className={`rounded px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wider ${
                      bInfo.isOnline
                        ? 'bg-success/15 text-success'
                        : 'bg-muted/15 text-muted'
                    }`}
                  >
                    {bInfo.isOnline ? 'online' : 'offline'}
                  </span>
                </button>
              );
            })}
          </div>
        </div>

        {error ? (
          <div
            data-debug-id="add-chain-dir-error"
            className="flex items-center gap-2 border-b border-danger/30 bg-danger/10 px-4 py-2 text-xs text-danger"
          >
            <Icon name="alert" size={14} className="shrink-0" />
            <span className="flex-1">{error}</span>
            <button
              type="button"
              onClick={() => setError('')}
              className="text-danger hover:opacity-80"
            >
              <Icon name="close" size={12} />
            </button>
          </div>
        ) : null}

        <div className="flex-1 overflow-y-auto p-4">
          <BridgeDirectoryPicker
            debugId="add-chain-dir-picker"
            bridgeId={selectedBridgeId}
            bridgeLabel={activeBridgeInfo.name}
            onPick={handlePick}
            onClose={onClose}
          />
        </div>
      </div>
    </div>
  );
}

// Map contract error codes to friendly messages, falling back to the server text.
function mutationError(code?: string, message?: string): string {
  switch (code) {
    case 'path_exists':
      return 'A file or folder with that name already exists.';
    case 'dest_exists':
      return 'The destination name is already taken.';
    case 'dir_not_empty':
      return 'That folder is not empty.';
    case 'cannot_delete_root':
      return 'The project root cannot be deleted.';
    case 'path_outside_root':
      return 'That path is outside the project root.';
    case 'path_not_found':
      return 'That path no longer exists.';
    default:
      return str(message);
  }
}

// ---- Multi-file Monaco Code Editor ------------------------------------------

function MonacoMultiFileEditor({
  tabs,
  activeTab,
  onSelectTab,
  onCloseTab,
  onContentChange,
  onSaveActive,
  onSaveAll,
  isSaving: _isSaving,
  isBatchSaving: _isBatchSaving,
  saveFeedback: _saveFeedback,
  onBackToFiles: _onBackToFiles,
  onToggleExplorer: _onToggleExplorer,
  isExplorerCollapsed: _isExplorerCollapsed = false,
  onNewFile,
  debugPrefix,
  themeAppearance,
  cwd,
  comments = [],
  onAddComment,
  onEditComment,
  onDeleteComment,
  onCommentFile: _onCommentFile,
  isDiffMode = false,
  onToggleDiff: _onToggleDiff,
  isVimMode = false,
  isWordWrap = true,
  isMinimapEnabled = true,
  isReadOnly = false,
  onEditorMount,
}: {
  tabs: EditorTab[];
  activeTab: EditorTab;
  onSelectTab: (path: string) => void;
  onCloseTab: (path: string) => void;
  onContentChange: (path: string, content: string) => void;
  onSaveActive: () => void;
  onSaveAll: () => void;
  isSaving?: boolean;
  isBatchSaving?: boolean;
  saveFeedback?: { type: 'success' | 'warning' | 'error'; message: string } | null;
  onBackToFiles?: () => void;
  onToggleExplorer?: () => void;
  isExplorerCollapsed?: boolean;
  onNewFile: (path: string) => void;
  debugPrefix: string;
  themeAppearance?: string;
  cwd?: string;
  comments?: FileLineComment[];
  onAddComment?: (line: number, lineText: string, body: string) => void;
  onEditComment?: (id: string, body: string) => void;
  onDeleteComment?: (id: string) => void;
  onCommentFile?: () => void;
  isDiffMode?: boolean;
  onToggleDiff?: () => void;
  isVimMode?: boolean;
  isWordWrap?: boolean;
  isMinimapEnabled?: boolean;
  isReadOnly?: boolean;
  onEditorMount?: (editor: any) => void;
}) {
  const monaco = useMonaco();
  useEffect(() => {
    configureMonacoTypeScriptDefaults(monaco);
  }, [monaco]);
  const monacoTheme = themeAppearance === 'light' ? 'light' : 'vs-dark';
  const language = useMemo(() => getLanguageForMonaco(activeTab.path), [activeTab.path]);

  const [isPromptingNewFile, setIsPromptingNewFile] = useState(false);
  const [newFileName, setNewFileName] = useState('');
  const diffListenerRef = useRef<{ dispose: () => void } | null>(null);

  const editorRef = useRef<any>(null);
  const [editorInstance, setEditorInstance] = useState<any>(null);
  const statusNodeRef = useRef<HTMLDivElement | null>(null);
  const vimModeRef = useRef<any>(null);

  useEffect(() => {
    return () => {
      diffListenerRef.current?.dispose();
    };
  }, []);

  const onSaveActiveRef = useRef(onSaveActive);
  const onSaveAllRef = useRef(onSaveAll);
  useEffect(() => {
    onSaveActiveRef.current = onSaveActive;
  }, [onSaveActive]);
  useEffect(() => {
    onSaveAllRef.current = onSaveAll;
  }, [onSaveAll]);

  const activeTabPathRef = useRef(activeTab.path);
  useEffect(() => {
    activeTabPathRef.current = activeTab.path;
  }, [activeTab.path]);

  const onCloseTabRef = useRef(onCloseTab);
  useEffect(() => {
    onCloseTabRef.current = onCloseTab;
  }, [onCloseTab]);

  // REQ-VIM-KEYBINDINGS: Wire custom Ex commands via Vim.defineEx:
  // ':w' -> onSaveActiveRef.current()
  // ':q' -> close active tab onCloseTab(activeTabPath)
  // ':wq' -> onSaveActiveRef.current() and close active tab
  useEffect(() => {
    const Vim = (VimMode as any)?.Vim;
    if (!Vim?.defineEx) return;
    try {
      Vim.defineEx('write', 'w', () => {
        onSaveActiveRef.current();
      });
    } catch {}
    try {
      Vim.defineEx('quit', 'q', () => {
        onCloseTabRef.current(activeTabPathRef.current);
      });
    } catch {}
    try {
      Vim.defineEx('wq', 'wq', () => {
        onSaveActiveRef.current();
        onCloseTabRef.current(activeTabPathRef.current);
      });
    } catch {}
  }, []);

  // REQ-VIM-INSERT-MODE-FIX: Single unified lifecycle hook for Monaco Vim mode.
  // Handles clean initialization and disposal on mode toggle, tab switch, and editor mount/unmount.
  useEffect(() => {
    if (!isVimMode || !editorInstance || !statusNodeRef.current) {
      if (vimModeRef.current) {
        vimModeRef.current.dispose();
        vimModeRef.current = null;
      }
      return;
    }

    if (vimModeRef.current) {
      vimModeRef.current.dispose();
      vimModeRef.current = null;
    }

    try {
      const vim = initVimMode(editorInstance, statusNodeRef.current);
      const origGetOption = vim.getOption;
      vim.getOption = function(key: string) {
        if (key === "readOnly") {
          const monacoEditorOption = (monaco as any)?.editor?.EditorOption?.readOnly;
          if (typeof monacoEditorOption === "number") {
            return Boolean(editorInstance.getOption(monacoEditorOption));
          }
          return Boolean(editorInstance.getRawOptions?.()?.readOnly);
        }
        return origGetOption.call(this, key);
      };
      vimModeRef.current = vim;
    } catch (e) {
      console.error('Failed to initialize monaco-vim:', e);
    }

    return () => {
      if (vimModeRef.current) {
        vimModeRef.current.dispose();
        vimModeRef.current = null;
      }
    };
  }, [isVimMode, activeTab.path, editorInstance]);

  // Auto-focus Monaco editor on open (REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS)
  useEffect(() => {
    if (editorRef.current) {
      try {
        editorRef.current.focus();
      } catch {}
      const timer = setTimeout(() => {
        try {
          editorRef.current?.focus();
        } catch {}
      }, 50);
      return () => clearTimeout(timer);
    }
  }, [activeTab.path]);

  const handleEditorMount: OnMount = (editor, monaco) => {
    editorRef.current = editor;
    setEditorInstance(editor);
    onEditorMount?.(editor);
    try {
      editor.focus();
    } catch {}
    setTimeout(() => {
      try {
        editor.focus();
      } catch {}
    }, 50);
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      onSaveActiveRef.current();
    });
    editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyS,
      () => {
        onSaveAllRef.current();
      }
    );
  };

  const handleDiffMount: DiffOnMount = (diffEditor, monaco) => {
    handleEditorMount(diffEditor.getModifiedEditor(), monaco);
    diffListenerRef.current?.dispose();
    const modifiedModel = diffEditor.getModifiedEditor().getModel();
    diffListenerRef.current = modifiedModel?.onDidChangeContent(() => {
      const val = diffEditor.getModifiedEditor().getValue();
      onContentChange(activeTab.path, val);
    }) ?? null;
  };

  const options: EditorProps['options'] = {
    minimap: { enabled: isMinimapEnabled },
    wordWrap: isWordWrap ? 'on' : 'off',
    lineNumbers: 'on',
    scrollBeyondLastLine: false,
    automaticLayout: true,
    fontSize: 13,
    fontFamily:
      'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
    tabSize: 2,
    renderWhitespace: 'selection',
    smoothScrolling: true,
    readOnly: Boolean(isReadOnly),
  };

  return (
    <div
      data-debug-id={`${debugPrefix}-monaco-editor`}
      className="flex min-h-0 flex-1 flex-col bg-surface"
    >
      {/* Tab Strip */}
      <div
        data-debug-id={`${debugPrefix}-tab-strip`}
        className="flex items-center overflow-x-auto border-b border-subtle bg-surface-raised px-1 py-1 gap-1 text-[12px] select-none"
      >
        {tabs.map((tab) => {
          const isActive = tab.path === activeTab.path;
          const name = baseName(tab.path);
          return (
            <div
              key={tab.path}
              data-debug-id={`${debugPrefix}-editor-tab-${name}`}
              data-active={isActive ? 'true' : 'false'}
              onClick={() => onSelectTab(tab.path)}
              title={tab.path}
              className={`group relative flex items-center gap-1.5 rounded-md px-2.5 py-1 cursor-pointer transition-colors ${
                isActive
                  ? 'bg-surface text-primary font-medium border border-subtle shadow-sm'
                  : 'text-muted hover:bg-neutral-soft hover:text-primary border border-transparent'
              }`}
            >
              <Icon name="file" size={12} className={isActive ? 'text-accent' : 'text-muted'} />
              <span className="max-w-[140px] truncate">{name}</span>
              {tab.isDirty ? (
                <span
                  data-debug-id={`${debugPrefix}-tab-dirty-bullet-${name}`}
                  className="text-accent font-bold text-[14px] leading-none"
                  title="Unsaved changes"
                >
                  •
                </span>
              ) : null}
              <button
                data-debug-id={`${debugPrefix}-tab-close-btn-${name}`}
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab(tab.path);
                }}
                title={tab.isDirty ? 'Close (unsaved changes)' : 'Close'}
                className="grid h-4 w-4 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary ml-0.5 opacity-60 group-hover:opacity-100"
              >
                <Icon name="close" size={10} />
              </button>
            </div>
          );
        })}

        {/* Tab strip new file prompt / plus button or read-only indicator */}
        {isReadOnly ? (
          <span
            data-debug-id={`${debugPrefix}-read-only-badge`}
            className="ml-auto mr-2 rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-medium text-muted uppercase tracking-wider"
          >
            Read-only
          </span>
        ) : isPromptingNewFile ? (
          <div
            data-debug-id={`${debugPrefix}-new-file-inline-prompt`}
            className="flex items-center gap-1 rounded bg-surface border border-accent/40 px-1.5 py-0.5 shadow-sm"
          >
            <Icon name="file" size={12} className="text-accent" />
            <input
              data-debug-id={`${debugPrefix}-new-file-input`}
              autoFocus
              type="text"
              value={newFileName}
              onChange={(e) => setNewFileName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  const target = newFileName.trim();
                  if (target) {
                    onNewFile(target);
                    setIsPromptingNewFile(false);
                    setNewFileName('');
                  }
                } else if (e.key === 'Escape') {
                  setIsPromptingNewFile(false);
                  setNewFileName('');
                }
              }}
              placeholder={cwd ? `${cwd}/filename` : 'path/to/file'}
              className="w-36 bg-transparent text-[12px] text-primary placeholder:text-muted focus:outline-none"
            />
            <button
              data-debug-id={`${debugPrefix}-new-file-confirm-btn`}
              type="button"
              disabled={!newFileName.trim()}
              onClick={() => {
                const target = newFileName.trim();
                if (target) {
                  onNewFile(target);
                  setIsPromptingNewFile(false);
                  setNewFileName('');
                }
              }}
              className="text-accent hover:text-accent/80 p-0.5 disabled:opacity-40"
              title="Create"
            >
              <Icon name="check" size={12} />
            </button>
            <button
              data-debug-id={`${debugPrefix}-new-file-cancel-btn`}
              type="button"
              onClick={() => {
                setIsPromptingNewFile(false);
                setNewFileName('');
              }}
              className="text-muted hover:text-primary p-0.5"
              title="Cancel"
            >
              <Icon name="close" size={10} />
            </button>
          </div>
        ) : (
          <button
            data-debug-id={`${debugPrefix}-new-tab-btn`}
            type="button"
            onClick={() => setIsPromptingNewFile(true)}
            title="New file"
            className="grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors ml-0.5"
          >
            <Icon name="plus" size={12} />
          </button>
        )}
      </div>

      {/* File-level & line comments for active tab */}
      {comments.length > 0 && onEditComment && onDeleteComment ? (
        <div data-debug-id={`${debugPrefix}-file-comments`} className="border-b border-subtle bg-surface-raised p-2 max-h-36 overflow-y-auto">
          {comments.map((c) => (
            <LineComment
              key={c.id}
              comment={c}
              debugPrefix={debugPrefix}
              gutterWidthCh={0}
              onEdit={onEditComment}
              onDelete={onDeleteComment}
            />
          ))}
        </div>
      ) : null}

      {/* Monaco Editor Canvas or Image / Unviewable Preview or DiffEditor */}
      <div className="relative min-h-0 flex-1 overflow-hidden">
        {activeTab.isImage ? (
          <div
            data-debug-id={`${debugPrefix}-image-preview`}
            className="flex h-full w-full items-center justify-center overflow-auto bg-canvas p-4"
          >
            <img
              data-debug-id={`${debugPrefix}-file-image`}
              src={`data:${activeTab.mime || 'image/png'};base64,${activeTab.content}`}
              alt={baseName(activeTab.path)}
              className="max-h-full max-w-full rounded-lg object-contain shadow-sm"
            />
          </div>
        ) : activeTab.isUnviewable ? (
          <div
            data-debug-id={`${debugPrefix}-file-unviewable`}
            className="flex h-full flex-col items-center justify-center p-6 text-center text-xs text-muted gap-2"
          >
            <div className="inline-flex items-center gap-1.5 rounded-full border border-warning/40 bg-warning/10 px-3 py-1 text-warning font-medium">
              <Icon name="alert" size={14} />
              <span>{activeTab.unviewableReason || 'This file cannot be previewed or edited.'}</span>
            </div>
            <p className="text-faint max-w-sm">Files larger than 5MB or with binary encodings are restricted from Monaco tokenization for safety and performance.</p>
          </div>
        ) : isDiffMode ? (
          <DiffEditor
            beforeMount={configureMonacoTypeScriptDefaults}
            original={activeTab.initialContent}
            modified={activeTab.content}
            language={language}
            theme={monacoTheme}
            options={{
              minimap: { enabled: isMinimapEnabled },
              wordWrap: isWordWrap ? 'on' : 'off',
              lineNumbers: 'on',
              scrollBeyondLastLine: false,
              automaticLayout: true,
              fontSize: 13,
              fontFamily:
                'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
              renderWhitespace: 'selection',
              smoothScrolling: true,
              readOnly: Boolean(isReadOnly),
              originalEditable: false,
            }}
            onMount={handleDiffMount}
            loading={
              <div className="p-4 text-center text-xs text-muted">
                Loading diff editor…
              </div>
            }
          />
        ) : (
          <Editor
            beforeMount={configureMonacoTypeScriptDefaults}
            path={activeTab.path}
            value={activeTab.content}
            language={language}
            theme={monacoTheme}
            options={options}
            onChange={(val) => onContentChange(activeTab.path, val ?? '')}
            onMount={handleEditorMount}
            loading={
              <div className="p-4 text-center text-xs text-muted">
                Loading editor…
              </div>
            }
          />
        )}
      </div>

      {/* REQ-VIM-KEYBINDINGS: Themed 20-22px Vim status line below Monaco Editor container */}
      <div
        ref={statusNodeRef}
        data-debug-id={`${debugPrefix}-vim-statusbar`}
        className={`${
          isVimMode ? '' : 'hidden'
        } h-[22px] min-h-[22px] max-h-[22px] w-full px-2 text-[11.5px] font-mono bg-surface-raised border-t border-subtle text-muted select-none overflow-hidden shrink-0 leading-[22px] [&_input]:bg-transparent [&_input]:border-none [&_input]:outline-none [&_input]:text-primary [&_input]:font-mono [&_input]:text-[11.5px] [&_input]:p-0 [&_input]:m-0`}
      />
    </div>
  );
}

// CodeLines renders text/code as ONE ROW PER LINE (gutter cell + highlighted code
// cell), which enables the interactive line gutter (hover comment button) and
// inline comment widgets that a monolithic <pre> can't host. Highlighting comes
// from Shiki per-line tokens; it degrades gracefully to plain text (same row
// structure) while tokens resolve or when the language is unknown/unsupported.
function CodeLines({
  content,
  path,
  wrap,
  debugPrefix,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
}: {
  content: string;
  path: string;
  wrap: boolean;
  debugPrefix: string;
  comments: FileLineComment[];
  onAddComment: (line: number, lineText: string, body: string) => void;
  onEditComment: (id: string, body: string) => void;
  onDeleteComment: (id: string) => void;
}) {
  const [tokenLines, setTokenLines] = useState<CodeToken[][] | null>(null);
  const lang = useMemo(() => languageForFile(path), [path]);

  // Raw source split into lines (the fallback + the source-of-truth for line text
  // used in the published message). Drop a single trailing empty line so a final
  // newline doesn't render a phantom row.
  const rawLines = useMemo(() => {
    const arr = (content || '').split('\n');
    if (arr.length > 1 && arr[arr.length - 1] === '') arr.pop();
    return arr;
  }, [content]);

  useEffect(() => {
    let cancelled = false;
    setTokenLines(null);
    if (!content || !lang) return;
    highlightToLines(content, lang).then((out) => {
      if (!cancelled) setTokenLines(out);
    });
    return () => {
      cancelled = true;
    };
  }, [content, lang]);

  // line (1-based) -> comments; and which line has an open composer.
  const commentsByLine = useMemo(() => {
    const m = new Map<number, FileLineComment[]>();
    for (const c of comments) {
      const list = m.get(c.line) || [];
      list.push(c);
      m.set(c.line, list);
    }
    return m;
  }, [comments]);
  const [composerLine, setComposerLine] = useState<number | null>(null);

  const lineCount = Math.max(1, rawLines.length);
  const gutterWidthCh = Math.max(2, String(lineCount).length) + 1;

  return (
    <div data-debug-id={`${debugPrefix}-file-code`} className="min-w-0 py-2 font-mono text-[12px] leading-5">
      {Array.from({ length: lineCount }, (_, i) => {
        const lineNo = i + 1;
        const lineText = rawLines[i] ?? '';
        const tokens = tokenLines?.[i];
        const lineComments = commentsByLine.get(lineNo) || [];
        return (
          <div key={lineNo} data-debug-id={`${debugPrefix}-line-${lineNo}`}>
            <div className="group flex items-start hover:bg-neutral-soft">
              {/* Gutter: line number + hover comment button */}
              <div
                className="relative flex shrink-0 select-none items-center justify-end border-r border-subtle bg-surface pr-2 text-right text-faint"
                style={{ width: `calc(${gutterWidthCh}ch + 22px)` }}
              >
                <button
                  data-debug-id={`${debugPrefix}-line-comment-btn-${lineNo}`}
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  title="Comment on this line"
                  aria-label={`Comment on line ${lineNo}`}
                  className={`absolute left-1 grid h-4 w-4 place-items-center rounded text-accent ${lineComments.length > 0 ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'} hover:bg-accent/20`}
                >
                  {lineComments.length > 0 ? (
                    <span className="text-[9px] font-bold">{lineComments.length}</span>
                  ) : (
                    <Icon name="chat" size={11} />
                  )}
                </button>
                <button
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  className="cursor-pointer tabular-nums hover:text-primary"
                >
                  {lineNo}
                </button>
              </div>
              {/* Code cell */}
              <div className={`min-w-0 flex-1 overflow-x-auto px-3 text-primary ${wrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre'}`}>
                {tokens ? (
                  tokens.length > 0 ? (
                    tokens.map((t, ti) => (
                      <span key={ti} style={t.color ? { color: t.color } : undefined}>{t.content}</span>
                    ))
                  ) : (
                    // Preserve blank-line height.
                    <span>{'\u00a0'}</span>
                  )
                ) : (
                  <span>{lineText || '\u00a0'}</span>
                )}
              </div>
            </div>

            {/* Existing comments for this line */}
            {lineComments.map((c) => (
              <LineComment
                key={c.id}
                comment={c}
                debugPrefix={debugPrefix}
                gutterWidthCh={gutterWidthCh}
                onEdit={onEditComment}
                onDelete={onDeleteComment}
              />
            ))}

            {/* Inline composer for a new comment */}
            {composerLine === lineNo ? (
              <LineComposer
                debugPrefix={debugPrefix}
                lineNo={lineNo}
                gutterWidthCh={gutterWidthCh}
                onCancel={() => setComposerLine(null)}
                onSave={(body) => {
                  onAddComment(lineNo, lineText, body);
                  setComposerLine(null);
                }}
              />
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

// A saved line comment bubble with edit/delete, indented under its line.
function LineComment({
  comment,
  debugPrefix,
  gutterWidthCh,
  onEdit,
  onDelete,
}: {
  comment: FileLineComment;
  debugPrefix: string;
  gutterWidthCh: number;
  onEdit: (id: string, body: string) => void;
  onDelete: (id: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(comment.body);
  return (
    <div className="flex" style={{ paddingLeft: `calc(${gutterWidthCh}ch + 22px)` }}>
      <div data-debug-id={`${debugPrefix}-line-comment-${comment.id}`} className="my-1 mr-3 min-w-0 flex-1 rounded-lg border border-accent/30 bg-accent/10 px-2.5 py-1.5 font-sans text-[12px]">
        {editing ? (
          <div>
            <textarea
              data-debug-id={`${debugPrefix}-line-comment-edit-input-${comment.id}`}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              rows={2}
              className="w-full resize-y rounded border border-subtle bg-surface-raised p-1.5 text-[12px] text-primary focus:border-accent focus:outline-none"
            />
            <div className="mt-1 flex justify-end gap-1.5">
              <button type="button" onClick={() => { setDraft(comment.body); setEditing(false); }} className="rounded border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
              <button data-debug-id={`${debugPrefix}-line-comment-edit-save-${comment.id}`} type="button" onClick={() => { onEdit(comment.id, draft); setEditing(false); }} className="rounded bg-accent px-2 py-0.5 text-caption font-semibold text-accent-fg hover:opacity-90">Save</button>
            </div>
          </div>
        ) : (
          <div className="flex items-start gap-2">
            <div className="min-w-0 flex-1 whitespace-pre-wrap break-words text-primary">{comment.body}</div>
            <div className="flex shrink-0 items-center gap-1">
              <button data-debug-id={`${debugPrefix}-line-comment-edit-${comment.id}`} type="button" onClick={() => { setDraft(comment.body); setEditing(true); }} title="Edit" className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"><Icon name="pencil" size={12} /></button>
              <button data-debug-id={`${debugPrefix}-line-comment-delete-${comment.id}`} type="button" onClick={() => onDelete(comment.id)} title="Delete" className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-danger-soft hover:text-danger"><Icon name="trash" size={12} /></button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// Inline new-comment composer, indented under its line.
function LineComposer({
  debugPrefix,
  lineNo,
  gutterWidthCh,
  onSave,
  onCancel,
}: {
  debugPrefix: string;
  lineNo: number;
  gutterWidthCh: number;
  onSave: (body: string) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState('');
  const ref = useRef<HTMLTextAreaElement | null>(null);
  useEffect(() => { ref.current?.focus(); }, []);
  return (
    <div data-debug-id={`${debugPrefix}-line-composer-${lineNo}`} className="flex" style={{ paddingLeft: `calc(${gutterWidthCh}ch + 22px)` }}>
      <div className="my-1 mr-3 min-w-0 flex-1 font-sans">
        <textarea
          ref={ref}
          data-debug-id={`${debugPrefix}-line-composer-input-${lineNo}`}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); if (draft.trim()) onSave(draft); }
          }}
          rows={2}
          placeholder={`Comment on line ${lineNo}… (Cmd/Ctrl+Enter to save)`}
          className="w-full resize-y rounded border border-subtle bg-surface-raised p-1.5 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
        />
        <div className="mt-1 flex justify-end gap-1.5">
          <button data-debug-id={`${debugPrefix}-line-composer-cancel-${lineNo}`} type="button" onClick={onCancel} className="rounded border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
          <button data-debug-id={`${debugPrefix}-line-composer-save-${lineNo}`} type="button" onClick={() => { if (draft.trim()) onSave(draft); }} disabled={!draft.trim()} className="rounded bg-accent px-2 py-0.5 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50">Comment</button>
        </div>
      </div>
    </div>
  );
}
