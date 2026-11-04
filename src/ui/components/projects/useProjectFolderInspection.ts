// useProjectFolderInspection — what a folder on a bridge says about the project
// that would live there, before the project exists:
//   * its VCS kind: .jj -> 'jj' (a colocated jj repo also has .git), else .git ->
//     'git', else 'none';
//   * a description prefill: the more recently modified of the top-level AGENTS.md /
//     CLAUDE.md (case-sensitive), read through the bridge-scoped file route and
//     decrypted with this device's vault key, capped for a project description.
//
// Detection reads the folder listing (GET /bridges/{id}/fs, which carries hidden
// entries plus size/modified_at); the file read is GET /bridges/{id}/fs/file. Read
// failures (vault locked, too large, bridge error) never throw: they come back as a
// `note` so the caller can show a short status line and keep the form usable.
//
// Used by the launcher's New project modal; written to be adopted by
// ProjectFormPage's Browse flow as well.

import { useCallback, useEffect, useRef, useState } from 'react';
import { useLazyListBridgeDirQuery, useLazyReadBridgeFileQuery, type BridgeFsEntry } from '../../api/endpoints/bridgeFs';
import type { FsReadFileResult } from '../../api/endpoints/projectFs';
import { isVaultArmored } from '../../utils/vaultContent';

export type ProjectVcsKind = 'none' | 'git' | 'jj';
export type InstructionFileName = 'AGENTS.md' | 'CLAUDE.md';

export const INSTRUCTION_FILE_NAMES: readonly InstructionFileName[] = ['AGENTS.md', 'CLAUDE.md'];
/** Longest description the prefill writes. The hub has no limit; a project
 *  description is a summary, and the field is vault-encrypted per save. */
export const PREFILL_MAX_CHARS = 4000;
/** One bridge read page; comfortably more than PREFILL_MAX_CHARS of text. */
export const PREFILL_READ_BYTES = 16 * 1024;

export type FolderPrefill = {
  source: InstructionFileName;
  text: string;
  /** The file was longer than PREFILL_MAX_CHARS and was cut at a line break. */
  truncated: boolean;
};

export type FolderInspection = {
  /** The folder this result describes ('' before any inspection). */
  path: string;
  status: 'idle' | 'loading' | 'done' | 'error';
  vcsKind: ProjectVcsKind | null;
  /** Both .jj and .git exist (a colocated jj repo). */
  colocated: boolean;
  prefill: FolderPrefill | null;
  /** Short, user-facing status when something could not be read; '' otherwise. */
  note: string;
};

export const IDLE_INSPECTION: FolderInspection = { path: '', status: 'idle', vcsKind: null, colocated: false, prefill: null, note: '' };

// --- pure helpers (exported for tests and other callers) ----------------------

/** .jj wins over .git (jj colocates with git); .git may be a file in a worktree. */
export function detectVcsKind(entries: Pick<BridgeFsEntry, 'name'>[]): { kind: ProjectVcsKind; colocated: boolean } {
  const names = new Set(entries.map((e) => e.name));
  const jj = names.has('.jj');
  const git = names.has('.git');
  return { kind: jj ? 'jj' : git ? 'git' : 'none', colocated: jj && git };
}

function mtime(value?: string): number {
  const t = value ? Date.parse(value) : NaN;
  return Number.isFinite(t) ? t : -Infinity;
}

/** Candidate instruction files, newest first (ties keep AGENTS.md first). */
export function rankInstructionFiles(entries: Pick<BridgeFsEntry, 'name' | 'is_dir' | 'modified_at'>[]): { name: InstructionFileName; modified_at?: string }[] {
  const found = INSTRUCTION_FILE_NAMES
    .map((name) => entries.find((e) => e.name === name && !e.is_dir))
    .filter((e): e is NonNullable<typeof e> => Boolean(e))
    .map((e) => ({ name: e.name as InstructionFileName, modified_at: e.modified_at }));
  return found.sort((a, b) => mtime(b.modified_at) - mtime(a.modified_at));
}

/** Trim and cap a file's text for the description, cutting at a line break. */
export function descriptionFromFile(content: string, max = PREFILL_MAX_CHARS, moreInFile = false): { text: string; truncated: boolean } {
  const text = content.replace(/\r\n/g, '\n').trim();
  if (text.length <= max) return { text, truncated: moreInFile };
  const cut = text.slice(0, max);
  const lastBreak = cut.lastIndexOf('\n');
  return { text: (lastBreak > max / 2 ? cut.slice(0, lastBreak) : cut).trimEnd(), truncated: true };
}

export function joinFolderPath(folder: string, name: string): string {
  if (!folder || folder === '/') return `/${name}`;
  return `${folder.replace(/\/+$/, '')}/${name}`;
}

/** The folder's own name: the last path segment. */
export function folderBaseName(path: string): string {
  return path.replace(/[\\/]+$/, '').split(/[\\/]/).filter(Boolean).pop() || '';
}

function errorCause(res: { error?: { code?: string; cause?: string } } | undefined): string {
  return String(res?.error?.cause || res?.error?.code || '');
}

function readFailureNote(name: string, cause: string): string {
  if (cause === 'vault_locked') return `Couldn't read ${name}: the bridge vault is locked.`;
  if (cause === 'file_too_large') return `${name} is too large to read.`;
  if (cause === 'unsupported_type') return `${name} isn't a text file.`;
  return `Couldn't read ${name}.`;
}

// --- the hook -----------------------------------------------------------------

export function useProjectFolderInspection(bridgeId: string) {
  const [listDir] = useLazyListBridgeDirQuery();
  const [readFile] = useLazyReadBridgeFileQuery();
  const [result, setResult] = useState<FolderInspection>(IDLE_INSPECTION);
  const generation = useRef(0);
  useEffect(() => () => { generation.current += 1; }, []);

  const reset = useCallback(() => { generation.current += 1; setResult(IDLE_INSPECTION); }, []);

  const inspect = useCallback(async (folder: string): Promise<FolderInspection> => {
    const gen = ++generation.current;
    const path = folder.trim();
    const settle = (next: FolderInspection) => { if (gen === generation.current) setResult(next); return next; };
    if (!bridgeId || !path) return settle(IDLE_INSPECTION);
    setResult({ ...IDLE_INSPECTION, path, status: 'loading' });

    let entries: BridgeFsEntry[] = [];
    let listingComplete = true;
    try {
      const listing = await listDir({ bridgeId, path }).unwrap();
      if (!listing.ok) {
        return settle({ ...IDLE_INSPECTION, path, status: 'error', note: listing.error?.message ? `Couldn't open the folder: ${listing.error.message}` : "Couldn't open the folder." });
      }
      entries = listing.entries || [];
      listingComplete = !listing.truncated && !(listing as any).has_more;
    } catch {
      return settle({ ...IDLE_INSPECTION, path, status: 'error', note: "Couldn't reach the bridge to inspect the folder." });
    }
    const vcs = detectVcsKind(entries);

    // The listing is capped (dirs sort first); when it was cut, ask for both files
    // directly — the read result carries modified_at too.
    let candidates = rankInstructionFiles(entries).map((c) => c.name);
    const reads = new Map<InstructionFileName, FsReadFileResult>();
    const failed: { name: string; cause: string }[] = [];
    const read = async (name: InstructionFileName) => {
      try {
        const res = await readFile({ bridgeId, path: joinFolderPath(path, name), limit: PREFILL_READ_BYTES }).unwrap();
        if (res.ok && res.viewable && typeof res.content === 'string') { reads.set(name, res); return true; }
        if (errorCause(res) !== 'path_not_found') failed.push({ name, cause: errorCause(res) });
      } catch {
        failed.push({ name, cause: '' });
      }
      return false;
    };
    if (!listingComplete && candidates.length < INSTRUCTION_FILE_NAMES.length) {
      for (const name of INSTRUCTION_FILE_NAMES) await read(name);
      const readEntries = [...reads].map(([name, r]) => ({ name, is_dir: false, modified_at: r.modified_at }));
      candidates = rankInstructionFiles(readEntries).map((c) => c.name);
    } else {
      // Newest first; fall back to the other file only when the newest can't be read.
      const ordered = candidates; candidates = [];
      for (const name of ordered) { if (await read(name)) { candidates = [name]; break; } }
    }

    let prefill: FolderPrefill | null = null;
    let note = '';
    const source = candidates[0];
    const res = source ? reads.get(source) : undefined;
    if (source && res && typeof res.content === 'string') {
      if (isVaultArmored(res.content)) {
        note = `Couldn't decrypt ${source} on this device.`;
      } else {
        const { text, truncated } = descriptionFromFile(res.content, PREFILL_MAX_CHARS, res.eof === false);
        if (text) prefill = { source, text, truncated };
      }
    } else if (failed.length) {
      note = readFailureNote(failed[0].name, failed[0].cause);
    }
    return settle({ path, status: 'done', vcsKind: vcs.kind, colocated: vcs.colocated, prefill, note });
  }, [bridgeId, listDir, readFile]);

  return { result, inspect, reset };
}
