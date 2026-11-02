// Projects found in past agent sessions on a bridge, for the setup wizard's
// Projects step. Unit-tested in tests/ui_setup_wizard_test.ts.
//
// Claude Code keeps one folder per working directory under ~/.claude/projects,
// named after the directory with every path separator and other non-alphanumeric
// character replaced by "-" (/home/me/my-app → -home-me-my-app, C:\Users\me\app →
// C--Users-me-app). That name is lossy ("-" may have been "/", "-", "." or "_"),
// so each candidate is resolved against the bridge with fs/stat, one path
// component at a time; anything that does not resolve to an existing folder is
// dropped. Only the bridge's own sandboxed fs API is used (GET /bridges/{id}/fs and
// /fs/stat), so nothing outside the bridge's fs_root is read.
//
// The authorized session-projects endpoint supplies counts and mtimes without
// returning session bodies. Claude encoded names still use sandboxed fs/stat.

export interface FsEntry { name: string; is_dir: boolean }
export interface FsListing { ok: boolean; path: string; entries: FsEntry[] }
export interface FsStat { ok: boolean; exists: boolean; is_dir: boolean; path?: string }

export interface SessionFs {
  list(path: string): Promise<FsListing | null>;
  stat(path: string): Promise<FsStat | null>;
}

export interface DiscoveredProject {
  /** Folder name, used as the project name. */
  name: string;
  /** Absolute path on the bridge. */
  path: string;
  sessions: number;
  source: 'Claude Code' | 'Codex' | 'Claude Code + Codex';
  lastSessionAt?: string;
  description?: string;
}

const JOINERS = ['-', '.', '_', ' '];
/** Stat calls one folder name may spend before it is given up on. */
const MAX_STATS_PER_ENTRY = 48;

interface Encoded { root: string; sep: string; tokens: string[] }

/** Split a Claude project folder name into its root and "-"-separated tokens. */
export function parseClaudeProjectDir(name: string): Encoded | null {
  const drive = /^([A-Za-z])--(.*)$/.exec(name);
  if (drive) return { root: `${drive[1].toUpperCase()}:\\`, sep: '\\', tokens: drive[2].split('-') };
  if (name.startsWith('-')) return { root: '/', sep: '/', tokens: name.slice(1).split('-') };
  return null;
}

/**
 * Resolve an encoded folder name to the directory it came from, or '' when no
 * existing directory matches. Depth-first: at each "-" either a new path component
 * starts (its parent must be an existing folder) or the current component goes on
 * with one of the characters "-" also stands for. An empty token (two "-" in a row)
 * starts a component with "." (a hidden folder such as .config).
 *
 * Limit: each name gets at most MAX_STATS_PER_ENTRY stat calls, and the search
 * stops as soon as they are spent (even if later lookups would be cache hits).
 * So '' means "not resolved": the folder may be absent, or it may exist but need
 * more stats than the budget allows (a deep path with many "-"-joined names).
 */
export async function resolveClaudeProjectDir(name: string, stat: SessionFs['stat']): Promise<string> {
  const parsed = parseClaudeProjectDir(name);
  if (!parsed || parsed.tokens.length === 0 || parsed.tokens.every((t) => !t)) return '';
  const { root, sep, tokens } = parsed;
  const cache = new Map<string, boolean>();
  let budget = MAX_STATS_PER_ENTRY;
  const isDir = async (path: string): Promise<boolean> => {
    if (cache.has(path)) return cache.get(path) as boolean;
    if (budget-- <= 0) return false;
    const result = await stat(path).catch(() => null);
    const ok = Boolean(result?.ok && result.exists && result.is_dir);
    cache.set(path, ok);
    return ok;
  };
  const join = (base: string, part: string) => (base.endsWith(sep) ? base + part : base + sep + part);

  // base: the resolved folders so far; current: the component being built.
  const walk = async (i: number, base: string, current: string): Promise<string> => {
    // Out of stats: give up on the whole name. Without this the search keeps
    // branching on cached/refused lookups (JOINERS^tokens) and never returns.
    if (budget <= 0) return '';
    if (i === tokens.length) {
      const full = join(base, current);
      return current && (await isDir(full)) ? full : '';
    }
    const token = tokens[i];
    if (!current) {
      // Start of a component: an empty token is the "." of a hidden folder.
      if (!token) return i + 1 < tokens.length ? walk(i + 2, base, `.${tokens[i + 1]}`) : '';
      return walk(i + 1, base, token);
    }
    // Close the current component and start a new one…
    const closed = join(base, current);
    if (await isDir(closed)) {
      const found = await walk(i, closed, '');
      if (found) return found;
    }
    // …or keep building it with a character "-" stood for.
    if (!token) return '';
    for (const joiner of JOINERS) {
      const found = await walk(i + 1, base, current + joiner + token);
      if (found) return found;
    }
    return '';
  };
  return walk(0, root, '');
}

function lastSegment(path: string): string {
  const parts = path.split(/[\\/]+/).filter(Boolean);
  return parts[parts.length - 1] || path;
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      out[index] = await fn(items[index]);
    }
  });
  await Promise.all(workers);
  return out;
}

/**
 * Folders that have Claude Code sessions on this bridge, most sessions first.
 * Returns [] when the bridge has no ~/.claude/projects.
 */
export async function discoverClaudeProjects(fs: SessionFs, limit = 40): Promise<DiscoveredProject[]> {
  const listing = await fs.list('~/.claude/projects').catch(() => null);
  if (!listing?.ok) return [];
  const sep = listing.path.includes('\\') ? '\\' : '/';
  const dirs = listing.entries.filter((e) => e.is_dir && parseClaudeProjectDir(e.name)).slice(0, limit);
  const found = await mapLimit<FsEntry, DiscoveredProject | null>(dirs, 4, async (entry) => {
    const sessionsDir = listing.path.endsWith(sep) ? listing.path + entry.name : listing.path + sep + entry.name;
    const [inside, path] = await Promise.all([
      fs.list(sessionsDir).catch(() => null),
      resolveClaudeProjectDir(entry.name, fs.stat),
    ]);
    if (!path) return null;
    const sessions = (inside?.entries || []).filter((e) => !e.is_dir && e.name.endsWith('.jsonl')).length;
    if (sessions === 0) return null;
    return { name: lastSegment(path), path, sessions, source: 'Claude Code' };
  });
  const byPath = new Map<string, DiscoveredProject>();
  for (const project of found) if (project && !byPath.has(project.path)) byPath.set(project.path, project);
  return [...byPath.values()].sort((a, b) => b.sessions - a.sessions || a.name.localeCompare(b.name));
}

/** List records omit bridge_paths. Resolve details before offering imports, and
 * fail closed if any mapping cannot be checked rather than offering duplicates. */
export async function loadProjectBridgeMappings(
  existing: { project_id: string }[],
  fetchDetail: (projectId: string) => Promise<any>,
  canonical?: { bridgeId: string; stat: SessionFs['stat'] },
): Promise<{ bridge_paths: { bridge_id: string; path: string }[] }[]> {
  return mapLimit(existing, 4, async (project) => {
    if (!project || typeof project.project_id !== 'string' || !project.project_id.trim()) throw new Error('Could not identify an existing project.');
    const detail = await fetchDetail(project.project_id);
    const paths = detail?.project?.bridge_paths ?? detail?.bridge_paths;
    if (detail?.project && (typeof detail.project !== 'object' ||
      detail.project.project_id !== project.project_id)) {
      throw new Error('Could not identify an existing project.');
    }
    if (!Array.isArray(paths) || paths.some((mapping) =>
      !mapping || typeof mapping.bridge_id !== 'string' || !mapping.bridge_id.trim() ||
      typeof mapping.path !== 'string' || !mapping.path.trim())) {
      throw new Error('Could not check existing project folders.');
    }
    const checked = await Promise.all(paths.map(async (mapping) => {
      if (!canonical || mapping.bridge_id !== canonical.bridgeId) return mapping;
      const stat = await canonical.stat(mapping.path);
      if (!stat?.ok) throw new Error('Could not check existing project folders.');
      return { ...mapping, path: stat.exists && stat.is_dir && stat.path ? stat.path : mapping.path };
    }));
    return { bridge_paths: checked };
  });
}

/** Drop the discovered folders that are already a project on this bridge. */
export function newProjectsOnly(found: DiscoveredProject[], existing: any[] | null | undefined, bridgeId: string): DiscoveredProject[] {
  const norm = projectPathKey;
  const taken = new Set<string>();
  for (const project of Array.isArray(existing) ? existing : []) {
    for (const bp of Array.isArray(project?.bridge_paths) ? project.bridge_paths : []) {
      if (String(bp?.bridge_id || '') === bridgeId && bp?.path) taken.add(norm(String(bp.path)));
    }
    // default_path has no bridge identity; the same path on another machine
    // must remain eligible until it has a mapping on this bridge.
  }
  return found.filter((p) => !taken.has(norm(p.path)));
}

export function projectPathKey(path: string): string {
  const windows = /^[A-Za-z]:[\\/]/.test(path) || path.startsWith('\\\\');
  const normalized = (windows ? path.replace(/\\/g, '/') : path).replace(/\/+$/, '');
  return windows ? normalized.toLowerCase() : normalized;
}

export interface SessionProjectMetadata {
  source: 'Claude Code' | 'Codex';
  path: string;
  sessions: number;
  last_session_at: string;
  canonical_path?: string;
  description?: string;
}
export interface SessionProjectListing {
  ok: boolean;
  projects: SessionProjectMetadata[];
  truncated?: boolean;
}

/** Resolve Claude's lossy names; combine providers sharing the same real cwd. */
export async function discoverSessionProjects(metadata: SessionProjectListing, fs: SessionFs): Promise<DiscoveredProject[]> {
  if (!metadata?.ok || !Array.isArray(metadata.projects)) throw new Error('Could not read session project history.');
  const resolved = await mapLimit(metadata.projects, 4, async (entry): Promise<DiscoveredProject | null> => {
    if (!entry || !['Codex', 'Claude Code'].includes(entry.source) || typeof entry.path !== 'string' || !(entry.sessions > 0)) return null;
    if ('canonical_path' in entry && (typeof entry.canonical_path !== 'string' || !entry.canonical_path)) return null;
    const requested = entry.canonical_path || (entry.source === 'Claude Code' ? await resolveClaudeProjectDir(entry.path, fs.stat) : entry.path);
    if (!requested) return null;
    const stat = await fs.stat(requested).catch(() => null);
    if (!stat?.ok || !stat.exists || !stat.is_dir) return null;
    const path = stat.path || requested;
    const stamp = typeof entry.last_session_at === 'string' && Number.isFinite(Date.parse(entry.last_session_at)) ? entry.last_session_at : undefined;
    const description = typeof entry.description === 'string' ? entry.description.slice(0, 320) : undefined;
    return { name: lastSegment(path), path, sessions: entry.sessions, source: entry.source, lastSessionAt: stamp, ...(description ? { description } : {}) };
  });
  const byPath = new Map<string, DiscoveredProject>();
  for (const project of resolved) {
    if (!project) continue;
    const key = projectPathKey(project.path);
    const previous = byPath.get(key);
    if (!previous) { byPath.set(key, project); continue; }
    previous.description ||= project.description;
    previous.sessions += project.sessions;
    if (previous.source !== project.source) previous.source = 'Claude Code + Codex';
    if (Date.parse(project.lastSessionAt || '') > Date.parse(previous.lastSessionAt || '') || !previous.lastSessionAt) previous.lastSessionAt = project.lastSessionAt;
  }
  return [...byPath.values()].sort((a, b) => (Date.parse(b.lastSessionAt || '') || 0) - (Date.parse(a.lastSessionAt || '') || 0) || b.sessions - a.sessions || a.path.localeCompare(b.path));
}

/** Reserve names as imports run, including same-basename folders in one batch. */
export function reserveProjectName(name: string, taken: Set<string>): string {
  let candidate = name;
  for (let suffix = 2; taken.has(candidate.toLocaleLowerCase()); suffix += 1) candidate = name + ' (' + suffix + ')';
  taken.add(candidate.toLocaleLowerCase());
  return candidate;
}

export function sessionTimeLabel(stamp?: string): string {
  if (!stamp || !Number.isFinite(Date.parse(stamp))) return 'Last session unknown';
  return 'Last session ' + new Date(stamp).toLocaleString();
}

export type ImportedSessionProjects = Record<string, { id: string; name: string }>;

/** Keep created IDs when attaching a bridge path fails, so retry cannot create
 * another project. Successful rows are returned for removal from the selection. */
export async function importSessionProjects(
  chosen: DiscoveredProject[],
  existingNames: string[],
  created: ImportedSessionProjects,
  api: {
    create(name: string, path: string, description?: string): Promise<string>;
    attach(id: string, path: string): Promise<void>;
    errorText(error: unknown): string;
  },
): Promise<{ imported: Set<string>; errors: Record<string, string> }> {
  const taken = new Set([...existingNames, ...Object.values(created).map((p) => p.name)].map((name) => name.toLocaleLowerCase()));
  const imported = new Set<string>();
  const errors: Record<string, string> = {};
  for (const project of chosen) {
    try {
      let state = created[project.path];
      if (!state) {
        const name = reserveProjectName(project.name, taken);
        const id = await api.create(name, project.path, project.description);
        if (!id) throw new Error('The hub did not return the new project id.');
        state = created[project.path] = { id, name };
      }
      await api.attach(state.id, project.path);
      imported.add(project.path);
    } catch (error) {
      errors[project.path] = api.errorText(error);
    }
  }
  return { imported, errors };
}
