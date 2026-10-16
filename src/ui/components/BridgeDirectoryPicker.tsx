// BridgeDirectoryPicker — a bridge-aware directory browser + creator.
//
// Lets the user pick (or create) a directory on a specific bridge's machine,
// sandboxed to that bridge's fs_root. Used for overriding a project's per-bridge
// path. Browse into dirs, breadcrumb up (bounded to root), toggle hidden entries,
// create a new folder, or create a typed-but-missing path.

import { useEffect, useMemo, useState } from 'react';
import { useLazyListBridgeDirQuery, useMkdirBridgePathMutation, type BridgeFsEntry } from '../api/endpoints/bridgeFs';
import { Badge, Button, Icon, IconButton, Input, Panel } from '@ui';
function str(v: any): string { return String(v ?? '').trim(); }

export default function BridgeDirectoryPicker({
  bridgeId,
  bridgeLabel,
  initialPath = '',
  onPick,
  onClose,
  debugId,
}: {
  bridgeId: string;
  bridgeLabel?: string;
  initialPath?: string;
  onPick: (path: string) => void;
  onClose?: () => void;
  debugId: string;
}) {
  const [listDir, listState] = useLazyListBridgeDirQuery();
  const [mkdir, mkdirState] = useMkdirBridgePathMutation();

  const [cwd, setCwd] = useState('');            // canonical path currently shown
  const [root, setRoot] = useState('');
  const [parent, setParent] = useState('');
  const [entries, setEntries] = useState<BridgeFsEntry[]>([]);
  const [error, setError] = useState('');
  const [showHidden, setShowHidden] = useState(false);
  const [pathInput, setPathInput] = useState(initialPath);
  const [newFolder, setNewFolder] = useState('');
  const [showNewFolder, setShowNewFolder] = useState(false);

  async function load(path: string, opts?: { fromFallback?: boolean }) {
    setError('');
    try {
      const res = await listDir({ bridgeId, path }).unwrap();
      if (!res.ok) {
        // Friendlier: if the requested path is outside the bridge's allowed root
        // (or just missing), fall back to opening the root instead of erroring —
        // so the picker always shows something useful. Only note it, don't block.
        if (!opts?.fromFallback && (res.error?.cause === 'path_outside_root' || res.error?.cause === 'path_not_found')) {
          const reason = res.error?.cause === 'path_outside_root' ? 'outside the allowed root' : 'not found';
          await load('', { fromFallback: true }); // '' => the bridge's root
          setError(`Opened the root — "${path}" is ${reason} on this device.`);
          return;
        }
        setError(str(res.error?.message) || 'Could not open directory');
        return;
      }
      setCwd(res.path); setRoot(res.root); setParent(res.parent); setEntries(res.entries || []);
      setPathInput(res.path);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Bridge unavailable');
    }
  }

  useEffect(() => { void load(initialPath); /* open at initial path, else falls back to root */ }, [bridgeId]);

  const visibleEntries = useMemo(() => {
    const dirs = entries.filter((e) => e.is_dir && (showHidden || !e.hidden));
    return dirs.sort((a, b) => a.name.localeCompare(b.name));
  }, [entries, showHidden]);

  function joinPath(base: string, name: string): string {
    if (!base || base === '/') return `/${name}`;
    return `${base.replace(/\/+$/, '')}/${name}`;
  }

  async function createFolder() {
    const name = newFolder.trim();
    if (!name) return;
    setError('');
    try {
      const target = cwd ? joinPath(cwd, name) : name;
      const res = await mkdir({ bridgeId, path: target }).unwrap();
      if (!res.ok) { setError(str(res.error?.message) || 'Could not create folder'); return; }
      setNewFolder(''); setShowNewFolder(false);
      await load(cwd);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Create failed');
    }
  }

  async function createTypedPath() {
    const p = pathInput.trim();
    if (!p) return;
    setError('');
    try {
      const res = await mkdir({ bridgeId, path: p }).unwrap();
      if (!res.ok) { setError(str(res.error?.message) || 'Could not create path'); return; }
      onPick(res.path);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Create failed');
    }
  }

  // Breadcrumb crumbs from root -> cwd (bounded to root).
  const crumbs = useMemo(() => {
    if (!cwd || !root) return [] as { label: string; path: string }[];
    const out: { label: string; path: string }[] = [{ label: root.split('/').filter(Boolean).slice(-1)[0] || '/', path: root }];
    if (cwd !== root && cwd.startsWith(root)) {
      const rest = cwd.slice(root.length).split('/').filter(Boolean);
      let acc = root === '/' ? '' : root;
      for (const seg of rest) { acc = `${acc}/${seg}`; out.push({ label: seg, path: acc }); }
    }
    return out;
  }, [cwd, root]);

  return (
    <Panel data-debug-id={debugId} tone="raised" padding="md" className="w-full shadow-2xl">
      <div className="mb-3 flex items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-[0.14em] text-muted">
            <Icon name="folder" size={14} className="text-accent" />
            <span>Browse{bridgeLabel ? ` · ${bridgeLabel}` : ''}</span>
          </div>
          {root ? <div className="mt-0.5 truncate font-mono text-[10px] text-faint" title={`Allowed root: ${root}`}>root: {root}</div> : null}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <Button data-debug-id={`${debugId}-home-btn`} variant="secondary" size="sm" onClick={() => void load('')} title="Go to root">Root</Button>
          {onClose ? <IconButton icon="close" label="Close" size="sm" data-debug-id={`${debugId}-close-btn`} onClick={onClose} /> : null}
        </div>
      </div>

      {/* breadcrumb */}
      <div data-debug-id={`${debugId}-breadcrumb`} className="mb-2.5 flex flex-wrap items-center gap-1 text-xs text-muted">
        {crumbs.map((c, i) => (
          <span key={c.path} className="flex items-center gap-1">
            {i > 0 ? <Icon name="chevron-right" size={12} className="text-faint" /> : null}
            <button data-debug-id={`${debugId}-crumb-${i}`} type="button" onClick={() => void load(c.path)} className="max-w-[160px] truncate rounded px-1.5 py-0.5 font-mono text-xs font-medium text-primary hover:bg-neutral-soft transition">{c.label}</button>
          </span>
        ))}
      </div>

      {/* directory list */}
      <div data-debug-id={`${debugId}-list`} className="max-h-[240px] overflow-y-auto rounded-xl border border-subtle bg-surface p-1 space-y-0.5">
        {listState.isFetching ? (
          <div data-debug-id={`${debugId}-loading`} className="p-4 text-center text-xs text-muted">Loading…</div>
        ) : visibleEntries.length === 0 ? (
          <div data-debug-id={`${debugId}-empty`} className="p-4 text-center text-xs text-faint">No subfolders here.</div>
        ) : visibleEntries.map((e) => (
          <button
            key={e.name}
            data-debug-id={`${debugId}-entry-${e.name}`}
            type="button"
            onClick={() => void load(cwd ? joinPath(cwd, e.name) : e.name)}
            className="flex w-full items-center justify-between gap-3 px-3 py-2 rounded-lg hover:bg-surface-raised transition cursor-pointer text-left group"
          >
            <div className="flex items-center gap-2.5 min-w-0">
              <Icon name="folder" size={15} className="shrink-0 text-accent group-hover:scale-105 transition-transform" />
              <span className="text-primary text-xs font-mono truncate">{e.name}</span>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              {e.has_git ? <Badge tone="success" emphasis="soft" className="font-mono text-[10px]">git</Badge> : null}
              {e.hidden ? <Badge tone="neutral" emphasis="soft" className="font-mono text-[10px]">hidden</Badge> : null}
              <Icon name="chevron-right" size={14} className="shrink-0 text-faint group-hover:text-muted transition-colors" />
            </div>
          </button>
        ))}
      </div>

      {/* controls row */}
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <Button data-debug-id={`${debugId}-hidden-toggle`} variant="secondary" size="sm" onClick={() => setShowHidden((v) => !v)}>{showHidden ? 'Hide hidden' : 'Show hidden'}</Button>
        {showNewFolder ? (
          <div className="flex items-center gap-1.5">
            <Input data-debug-id={`${debugId}-new-folder-input`} value={newFolder} onChange={setNewFolder} placeholder="folder name" size="sm" className="w-32" />
            <Button data-debug-id={`${debugId}-new-folder-create-btn`} variant="primary" size="sm" disabled={mkdirState.isLoading} onClick={createFolder}>Create</Button>
            <Button variant="ghost" size="sm" onClick={() => { setShowNewFolder(false); setNewFolder(''); }}>Cancel</Button>
          </div>
        ) : (
          <Button data-debug-id={`${debugId}-new-folder-btn`} variant="secondary" size="sm" onClick={() => setShowNewFolder(true)} leading={<Icon name="plus" size={12} />}>New folder</Button>
        )}
      </div>

      {/* path input + actions */}
      <div className="mt-2">
        <Input
          data-debug-id={`${debugId}-path-input`}
          value={pathInput}
          onChange={setPathInput}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              if (pathInput.trim()) void load(pathInput.trim());
            }
          }}
          placeholder="~/path/on/this/device"
          width="full"
          className="font-mono"
        />
      </div>

      {error ? <p data-debug-id={`${debugId}-error`} className="mt-2 text-caption text-danger">{error}</p> : null}

      <div className="mt-3 flex items-center justify-end gap-2">
        <Button data-debug-id={`${debugId}-create-typed-btn`} variant="secondary" onClick={createTypedPath}>Create typed path</Button>
        <Button data-debug-id={`${debugId}-pick-btn`} variant="primary" onClick={() => onPick(str(pathInput) || cwd)}>Use this folder</Button>
      </div>
    </Panel>
  );
}
