// SearchInFilesDrawer — Scoped Search in Files Drawer (Cmd+Shift+F).
//
// Queries the Ripgrep backend across Project Root, Task Chain Directories,
// and Agent Run Directories with live jump into Monaco (REQ-SEARCH-UI-PANEL-1, REQ-SEARCH-SHORTCUTS-1).
// Provides multi-scope selection, path deduplication for nested subtrees,
// case/word/regex toggles, include/exclude pattern globs, debounced querying,
// amber-highlighted previews, and Monaco editor position navigation.

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@ui';
import {
  orchestrateMultiScopeSearch,
  type FsSearchScope,
  type ScopedSearchMatch,
  type MultiScopeSearchResult,
} from '../../api/endpoints/projectFs';

export type SearchInFilesDrawerProps = {
  isOpen: boolean;
  onClose: () => void;
  scopes: FsSearchScope[];
  activeDirectoryId: string;
  onSelectMatch: (match: ScopedSearchMatch) => void;
  debugPrefix?: string;
  initialQuery?: string;
};

// Grouped matches hierarchy: Scope -> File -> Matches
type FileMatchGroup = {
  filePath: string;
  matches: ScopedSearchMatch[];
};

type ScopeMatchGroup = {
  scopeId: string;
  scopeLabel: string;
  scopeKind: 'primary' | 'chain_directory' | 'agent_run_dir';
  files: FileMatchGroup[];
  totalMatches: number;
};

export default function SearchInFilesDrawer({
  isOpen,
  onClose,
  scopes,
  activeDirectoryId: _activeDirectoryId,
  onSelectMatch,
  debugPrefix = 'search-in-files',
  initialQuery = '',
}: SearchInFilesDrawerProps) {
  const [query, setQuery] = useState(initialQuery);
  const [debouncedQuery, setDebouncedQuery] = useState(initialQuery);
  const [isCaseSensitive, setIsCaseSensitive] = useState(false);
  const [isWholeWord, setIsWholeWord] = useState(false);
  const [isRegex, setIsRegex] = useState(false);
  const [includePattern, setIncludePattern] = useState('');
  const [debouncedIncludePattern, setDebouncedIncludePattern] = useState('');
  const [showPatternInput, setShowPatternInput] = useState(false);

  // Scope selection: 'all' or specific set of scope IDs
  const [selectedScopeIds, setSelectedScopeIds] = useState<Set<string>>(() => new Set(['all']));
  const isAllScopesSelected = selectedScopeIds.has('all') || selectedScopeIds.size === scopes.length;

  const [isLoading, setIsLoading] = useState(false);
  const [searchResult, setSearchResult] = useState<MultiScopeSearchResult | null>(null);

  // Collapsed sections in results
  const [collapsedScopes, setCollapsedScopes] = useState<Set<string>>(new Set());
  const [collapsedFiles, setCollapsedFiles] = useState<Set<string>>(new Set());

  const queryInputRef = useRef<HTMLInputElement | null>(null);
  const searchAbortRef = useRef<AbortController | null>(null);

  // Focus search input when drawer opens
  useEffect(() => {
    if (isOpen) {
      setTimeout(() => {
        queryInputRef.current?.focus();
        queryInputRef.current?.select();
      }, 50);
    }
  }, [isOpen]);

  // Debounce query (150ms)
  useEffect(() => {
    const timer = setTimeout(() => {
      setDebouncedQuery(query);
    }, 150);
    return () => clearTimeout(timer);
  }, [query]);

  // Debounce includePattern (150ms)
  useEffect(() => {
    const timer = setTimeout(() => {
      setDebouncedIncludePattern(includePattern);
    }, 150);
    return () => clearTimeout(timer);
  }, [includePattern]);

  // Active scopes to query
  const targetScopes = useMemo(() => {
    if (isAllScopesSelected) {
      return scopes;
    }
    return scopes.filter((s) => selectedScopeIds.has(s.id));
  }, [isAllScopesSelected, scopes, selectedScopeIds]);

  // Execute search whenever debounced inputs change
  const executeSearch = useCallback(async () => {
    const trimmed = debouncedQuery.trim();
    if (!trimmed || targetScopes.length === 0) {
      setSearchResult(null);
      setIsLoading(false);
      return;
    }

    if (searchAbortRef.current) {
      searchAbortRef.current.abort();
    }
    const abortController = new AbortController();
    searchAbortRef.current = abortController;

    setIsLoading(true);

    try {
      const res = await orchestrateMultiScopeSearch({
        query: debouncedQuery,
        scopes: targetScopes,
        caseSensitive: isCaseSensitive,
        wholeWord: isWholeWord,
        regex: isRegex,
        includePattern: debouncedIncludePattern,
        limitPerScope: 200,
      });

      if (!abortController.signal.aborted) {
        setSearchResult(res);
      }
    } catch {
      // Aborted or network failure
    } finally {
      if (!abortController.signal.aborted) {
        setIsLoading(false);
      }
    }
  }, [debouncedQuery, targetScopes, isCaseSensitive, isWholeWord, isRegex, debouncedIncludePattern]);

  useEffect(() => {
    void executeSearch();
  }, [executeSearch]);

  // Scope toggle handlers
  const handleToggleAllScopes = () => {
    if (isAllScopesSelected) {
      // Select only primary scope if available
      const primary = scopes.find((s) => s.kind === 'primary') || scopes[0];
      setSelectedScopeIds(primary ? new Set([primary.id]) : new Set());
    } else {
      setSelectedScopeIds(new Set(['all']));
    }
  };

  const handleToggleScope = (scopeId: string) => {
    setSelectedScopeIds((prev) => {
      const next = new Set(prev);
      if (next.has('all')) {
        // Break out of 'all' and select all others except this one if there are multiple, or just this one
        next.clear();
        next.add(scopeId);
        return next;
      }

      if (next.has(scopeId)) {
        next.delete(scopeId);
        if (next.size === 0) {
          next.add('all');
        }
      } else {
        next.add(scopeId);
        if (next.size === scopes.length) {
          next.clear();
          next.add('all');
        }
      }
      return next;
    });
  };

  // Group matches by Scope -> File
  const groupedResults = useMemo<ScopeMatchGroup[]>(() => {
    if (!searchResult || searchResult.matches.length === 0) return [];

    const byScope = new Map<string, { label: string; kind: 'primary' | 'chain_directory' | 'agent_run_dir'; filesMap: Map<string, ScopedSearchMatch[]> }>();

    for (const match of searchResult.matches) {
      if (!byScope.has(match.scopeId)) {
        byScope.set(match.scopeId, {
          label: match.scopeLabel,
          kind: match.scopeKind,
          filesMap: new Map(),
        });
      }
      const scopeData = byScope.get(match.scopeId)!;
      if (!scopeData.filesMap.has(match.path)) {
        scopeData.filesMap.set(match.path, []);
      }
      scopeData.filesMap.get(match.path)!.push(match);
    }

    const groups: ScopeMatchGroup[] = [];
    for (const [scopeId, data] of byScope.entries()) {
      const files: FileMatchGroup[] = [];
      let totalMatches = 0;
      for (const [filePath, matches] of data.filesMap.entries()) {
        files.push({ filePath, matches });
        totalMatches += matches.length;
      }
      groups.push({
        scopeId,
        scopeLabel: data.label,
        scopeKind: data.kind,
        files,
        totalMatches,
      });
    }

    return groups;
  }, [searchResult]);

  const toggleScopeCollapse = (scopeId: string) => {
    setCollapsedScopes((prev) => {
      const next = new Set(prev);
      if (next.has(scopeId)) next.delete(scopeId);
      else next.add(scopeId);
      return next;
    });
  };

  const toggleFileCollapse = (fileKey: string) => {
    setCollapsedFiles((prev) => {
      const next = new Set(prev);
      if (next.has(fileKey)) next.delete(fileKey);
      else next.add(fileKey);
      return next;
    });
  };

  if (!isOpen) return null;

  return (
    <div
      data-debug-id={debugPrefix}
      className="flex h-full w-full flex-col bg-surface text-primary select-none overflow-hidden"
    >
      {/* Top Header */}
      <div className="flex items-center justify-between border-b border-subtle px-3 py-2 shrink-0">
        <div className="flex items-center gap-2">
          <Icon name="search" size={14} className="text-accent shrink-0" />
          <span className="text-[12px] font-semibold tracking-wide uppercase text-primary">
            Search in Files
          </span>
          {searchResult && searchResult.totalMatches > 0 ? (
            <span
              data-debug-id={`${debugPrefix}-count-badge`}
              className="rounded-full bg-accent/15 px-2 py-0.5 text-[10px] font-semibold text-accent"
            >
              {searchResult.totalMatches} match{searchResult.totalMatches === 1 ? '' : 'es'} in{' '}
              {searchResult.totalFiles} file{searchResult.totalFiles === 1 ? '' : 's'}
            </span>
          ) : null}
        </div>

        <div className="flex items-center gap-1">
          <button
            type="button"
            data-debug-id={`${debugPrefix}-refresh-btn`}
            onClick={() => void executeSearch()}
            title="Refresh search"
            className="grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
          >
            <Icon name="refresh" size={13} className={isLoading ? 'animate-spin text-accent' : ''} />
          </button>
          <button
            type="button"
            data-debug-id={`${debugPrefix}-close-btn`}
            onClick={onClose}
            title="Close search drawer"
            className="grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
          >
            <Icon name="close" size={14} />
          </button>
        </div>
      </div>

      {/* Scope Selector Bar (Pills) */}
      <div className="flex flex-col gap-1 border-b border-subtle px-3 py-2 shrink-0 bg-surface-raised/40">
        <div className="flex items-center justify-between text-[11px] text-muted">
          <span className="font-semibold uppercase tracking-wider text-[10px]">Scopes</span>
          {searchResult?.scopesDeduplicatedOut && searchResult.scopesDeduplicatedOut.length > 0 ? (
            <span
              data-debug-id={`${debugPrefix}-dedup-note`}
              className="text-[10px] text-warning font-medium"
              title={searchResult.scopesDeduplicatedOut.map((s) => s.label).join(', ')}
            >
              ({searchResult.scopesDeduplicatedOut.length} nested scope deduplicated)
            </span>
          ) : null}
        </div>

        <div className="flex flex-wrap items-center gap-1.5 pt-0.5 max-h-[88px] overflow-y-auto">
          {/* [All Scopes] pill */}
          <button
            type="button"
            data-debug-id="search-scope-pill-all"
            onClick={handleToggleAllScopes}
            className={`rounded-full px-2.5 py-0.5 text-[11px] font-medium transition-colors border ${
              isAllScopesSelected
                ? 'bg-accent text-accent-fg border-accent shadow-xs'
                : 'bg-neutral-soft text-muted border-subtle hover:text-primary'
            }`}
          >
            All Scopes
          </button>

          {/* Individual scopes pills */}
          {scopes.map((scope) => {
            const isSelected = isAllScopesSelected || selectedScopeIds.has(scope.id);
            const isDeduped = searchResult?.scopesDeduplicatedOut.some((d) => d.id === scope.id);

            let prefixLabel = 'Scope';
            if (scope.kind === 'primary') prefixLabel = 'Project';
            else if (scope.kind === 'chain_directory') prefixLabel = 'Chain Dir';
            else if (scope.kind === 'agent_run_dir') prefixLabel = 'Run Dir';

            return (
              <button
                key={scope.id}
                type="button"
                data-debug-id={
                  scope.kind === 'primary' ? 'search-scope-pill-primary' : `search-scope-pill-${scope.id}`
                }
                onClick={() => handleToggleScope(scope.id)}
                title={`${prefixLabel}: ${scope.label}${isDeduped ? ' (nested in parent root)' : ''}`}
                className={`flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] transition-colors border max-w-[190px] truncate ${
                  isSelected
                    ? isDeduped
                      ? 'bg-accent/15 text-accent border-accent/40 opacity-75'
                      : 'bg-accent/20 text-accent font-semibold border-accent/50 shadow-xs'
                    : 'bg-neutral-soft text-muted border-subtle hover:text-primary'
                }`}
              >
                <span className="truncate">{scope.label}</span>
                {isDeduped ? (
                  <span className="text-[9px] text-warning font-mono" title="Nested subtree deduplicated">
                    [dedup]
                  </span>
                ) : null}
              </button>
            );
          })}
        </div>
      </div>

      {/* Search Input and Option Toggles */}
      <div className="flex flex-col gap-1.5 border-b border-subtle p-3 shrink-0">
        <div className="relative flex items-center">
          <input
            ref={queryInputRef}
            data-debug-id="search-in-files-query-input"
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void executeSearch();
              if (e.key === 'Escape') onClose();
            }}
            placeholder="Search files (e.g. function, class, token)…"
            className="w-full rounded-md border border-subtle bg-surface-raised py-1.5 pl-2.5 pr-20 text-[12.5px] font-mono text-primary placeholder:text-muted focus:border-accent focus:outline-none"
          />

          {/* Controls inside search input: Aa, \b, .* */}
          <div className="absolute right-1 flex items-center gap-0.5">
            {/* Match Case */}
            <button
              type="button"
              data-debug-id="search-in-files-toggle-case"
              onClick={() => setIsCaseSensitive((prev) => !prev)}
              aria-pressed={isCaseSensitive}
              title="Match Case (Aa)"
              className={`grid h-5 w-5 place-items-center rounded text-[11px] font-mono font-bold transition-colors ${
                isCaseSensitive
                  ? 'bg-accent text-accent-fg shadow-xs'
                  : 'text-muted hover:bg-neutral-soft hover:text-primary'
              }`}
            >
              Aa
            </button>

            {/* Match Whole Word */}
            <button
              type="button"
              data-debug-id="search-in-files-toggle-word"
              onClick={() => setIsWholeWord((prev) => !prev)}
              aria-pressed={isWholeWord}
              title="Match Whole Word (\b)"
              className={`grid h-5 w-5 place-items-center rounded text-[11px] font-mono font-bold transition-colors ${
                isWholeWord
                  ? 'bg-accent text-accent-fg shadow-xs'
                  : 'text-muted hover:bg-neutral-soft hover:text-primary'
              }`}
            >
              \b
            </button>

            {/* Use Regular Expression */}
            <button
              type="button"
              data-debug-id="search-in-files-toggle-regex"
              onClick={() => setIsRegex((prev) => !prev)}
              aria-pressed={isRegex}
              title="Use Regular Expression (.*)"
              className={`grid h-5 w-5 place-items-center rounded text-[11px] font-mono font-bold transition-colors ${
                isRegex
                  ? 'bg-accent text-accent-fg shadow-xs'
                  : 'text-muted hover:bg-neutral-soft hover:text-primary'
              }`}
            >
              .*
            </button>
          </div>
        </div>

        {/* Toggle file include/exclude patterns */}
        <div className="flex items-center justify-between">
          <button
            type="button"
            onClick={() => setShowPatternInput((prev) => !prev)}
            className="flex items-center gap-1 text-[11px] text-muted hover:text-primary transition-colors"
          >
            <Icon name={showPatternInput ? 'chevron-down' : 'chevron-right'} size={11} />
            <span>Files to include/exclude</span>
            {includePattern ? (
              <span className="rounded bg-accent/15 px-1 py-0.2 text-[9px] font-mono text-accent">
                {includePattern}
              </span>
            ) : null}
          </button>

          {query ? (
            <button
              type="button"
              onClick={() => setQuery('')}
              className="text-[11px] text-muted hover:text-primary"
            >
              Clear
            </button>
          ) : null}
        </div>

        {showPatternInput ? (
          <input
            data-debug-id="search-in-files-glob-input"
            type="text"
            value={includePattern}
            onChange={(e) => setIncludePattern(e.target.value)}
            placeholder="e.g. *.tsx, !*.test.ts, src/**/*.ts"
            className="w-full rounded border border-subtle bg-surface-raised px-2 py-1 text-[11.5px] font-mono text-primary placeholder:text-muted focus:border-accent focus:outline-none"
          />
        ) : null}
      </div>

      {/* Results View */}
      <div className="min-h-0 flex-1 overflow-y-auto p-2" data-debug-id={`${debugPrefix}-results`}>
        {isLoading && (!searchResult || searchResult.matches.length === 0) ? (
          <div className="flex flex-col items-center justify-center p-8 text-center text-muted gap-2">
            <Icon name="refresh" size={18} className="animate-spin text-accent" />
            <span className="text-[12px]">Searching files…</span>
          </div>
        ) : !query.trim() ? (
          <div className="flex flex-col items-center justify-center p-8 text-center text-muted gap-1">
            <Icon name="search" size={20} className="text-muted/60 mb-1" />
            <span className="text-[12px] font-medium text-primary">Search in Files</span>
            <span className="text-[11px] text-faint">
              Type a word, symbol, or regular expression above.
            </span>
            <span className="text-[10px] text-faint font-mono mt-1">
              Shortcut: Cmd+Shift+F / Ctrl+Shift+F
            </span>
          </div>
        ) : groupedResults.length === 0 ? (
          <div className="flex flex-col items-center justify-center p-8 text-center text-muted gap-1">
            <span className="text-[12px] text-primary">No results found</span>
            <span className="text-[11px] text-faint">
              No matching text found for &quot;{query}&quot; in selected scopes.
            </span>
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {groupedResults.map((scopeGroup) => {
              const isScopeCollapsed = collapsedScopes.has(scopeGroup.scopeId);

              return (
                <div
                  key={scopeGroup.scopeId}
                  data-debug-id={`search-scope-group-${scopeGroup.scopeId}`}
                  className="rounded-lg border border-subtle/80 bg-surface-raised/30 overflow-hidden"
                >
                  {/* Scope Group Header */}
                  <button
                    type="button"
                    onClick={() => toggleScopeCollapse(scopeGroup.scopeId)}
                    className="flex w-full items-center justify-between bg-surface-raised/70 px-2.5 py-1.5 text-left hover:bg-neutral-soft transition-colors select-none"
                  >
                    <div className="flex items-center gap-1.5 min-w-0">
                      <Icon
                        name={isScopeCollapsed ? 'chevron-right' : 'chevron-down'}
                        size={11}
                        className="text-muted shrink-0"
                      />
                      <Icon
                        name={scopeGroup.scopeKind === 'agent_run_dir' ? 'bot' : 'folder'}
                        size={13}
                        className="text-accent shrink-0"
                      />
                      <span className="text-[11.5px] font-semibold text-primary truncate">
                        {scopeGroup.scopeLabel}
                      </span>
                    </div>
                    <span className="rounded bg-neutral-soft px-1.5 py-0.2 text-[10px] font-mono text-muted shrink-0">
                      {scopeGroup.totalMatches} match{scopeGroup.totalMatches === 1 ? '' : 'es'}
                    </span>
                  </button>

                  {/* Scope Files */}
                  {!isScopeCollapsed ? (
                    <div className="flex flex-col divide-y divide-subtle/40">
                      {scopeGroup.files.map((fileGroup) => {
                        const fileKey = `${scopeGroup.scopeId}::${fileGroup.filePath}`;
                        const isFileCollapsed = collapsedFiles.has(fileKey);

                        return (
                          <div key={fileKey} className="flex flex-col">
                            {/* File Header */}
                            <button
                              type="button"
                              onClick={() => toggleFileCollapse(fileKey)}
                              className="flex items-center justify-between px-3 py-1 text-left hover:bg-neutral-soft/80 transition-colors select-none"
                            >
                              <div className="flex items-center gap-1.5 min-w-0">
                                <Icon
                                  name={isFileCollapsed ? 'chevron-right' : 'chevron-down'}
                                  size={10}
                                  className="text-muted shrink-0"
                                />
                                <Icon name="file" size={12} className="text-muted shrink-0" />
                                <span className="font-mono text-[11px] font-medium text-primary truncate">
                                  {fileGroup.filePath}
                                </span>
                              </div>
                              <span className="text-[10px] text-faint font-mono shrink-0 ml-1">
                                {fileGroup.matches.length}
                              </span>
                            </button>

                            {/* Match Rows */}
                            {!isFileCollapsed ? (
                              <div className="flex flex-col pl-6 pr-2 py-0.5 space-y-0.5">
                                {fileGroup.matches.map((m, idx) => (
                                  <button
                                    key={`${m.line_number}:${m.column}:${idx}`}
                                    type="button"
                                    data-debug-id="search-in-files-match-row"
                                    onClick={() => onSelectMatch(m)}
                                    title={`Line ${m.line_number}, Col ${m.column} — Click to open in editor`}
                                    className="group flex w-full items-baseline gap-2 rounded px-1.5 py-1 text-left hover:bg-neutral-soft transition-colors font-mono text-[11px]"
                                  >
                                    <span className="shrink-0 text-[10px] tabular-nums text-faint group-hover:text-primary">
                                      {m.line_number}:{m.column}
                                    </span>

                                    <div className="min-w-0 flex-1 truncate text-primary/90">
                                      <HighlightedMatchLine
                                        line={m.line}
                                        matchStart={m.match_start}
                                        matchEnd={m.match_end}
                                        query={debouncedQuery}
                                        isRegex={isRegex}
                                        isCaseSensitive={isCaseSensitive}
                                      />
                                    </div>
                                  </button>
                                ))}
                              </div>
                            ) : null}
                          </div>
                        );
                      })}
                    </div>
                  ) : null}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

// Subcomponent to highlight matching text in amber
function HighlightedMatchLine({
  line,
  matchStart,
  matchEnd,
  query,
  isRegex,
  isCaseSensitive,
}: {
  line: string;
  matchStart: number;
  matchEnd: number;
  query: string;
  isRegex: boolean;
  isCaseSensitive: boolean;
}) {
  const trimmed = line.trimStart();
  const leadingSpaces = line.length - trimmed.length;

  // If backend provided positive match boundaries, use them directly
  if (matchEnd > matchStart && matchStart >= 0) {
    const adjStart = Math.max(0, matchStart - leadingSpaces);
    const adjEnd = Math.max(adjStart, matchEnd - leadingSpaces);

    const prefix = trimmed.slice(0, adjStart);
    const matched = trimmed.slice(adjStart, adjEnd);
    const suffix = trimmed.slice(adjEnd);

    return (
      <span>
        <span>{prefix}</span>
        <mark
          data-debug-id="search-in-files-match-highlight"
          className="bg-warning-soft text-warning font-semibold px-0.5 rounded-xs"
        >
          {matched || query}
        </mark>
        <span>{suffix}</span>
      </span>
    );
  }

  // Fallback: substring / regex matching on trimmed line
  try {
    let re: RegExp;
    if (isRegex) {
      re = new RegExp(query, isCaseSensitive ? 'g' : 'gi');
    } else {
      const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      re = new RegExp(escaped, isCaseSensitive ? 'g' : 'gi');
    }

    const match = re.exec(trimmed);
    if (match) {
      const start = match.index;
      const end = start + match[0].length;
      return (
        <span>
          <span>{trimmed.slice(0, start)}</span>
          <mark
            data-debug-id="search-in-files-match-highlight"
            className="bg-warning-soft text-warning font-semibold px-0.5 rounded-xs"
          >
            {trimmed.slice(start, end)}
          </mark>
          <span>{trimmed.slice(end)}</span>
        </span>
      );
    }
  } catch {}

  return <span>{trimmed}</span>;
}
