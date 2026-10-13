import React, { useCallback, useEffect, useState } from 'react';
import { Icon } from '@ui';
import {
  useGetShellSessionQuery,
  useRestartShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { buildWorkbenchPreviewUrl } from '../../store/workbenchTabId';
import { ShellLogViewer } from '../shells/ShellLogViewer';
import { restartFailureText } from '../shells/shellModel';

const DEAD_STATUSES = new Set(['exited', 'killed', 'failed']);

export function normalizePreviewSubpath(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed || trimmed === '/') return '/';
  return trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
}

function getPreviewFailureCopy(
  session: ShellSession | undefined,
  liveStatus: string,
  effectivePort: number,
  isStatusUnknown: boolean,
): { headline: string; detail: string; canRestart: boolean } {
  if (isStatusUnknown) {
    return {
      headline: 'Bridge is offline — server status unknown',
      detail: `The bridge hosting session ${session?.session_id || ''} is currently disconnected.`,
      canRestart: false,
    };
  }
  return {
    headline: 'Server has stopped',
    detail: `Session (${liveStatus}) is no longer serving on port ${effectivePort}.`,
    canRestart: true,
  };
}

export interface PreviewWorkbenchPaneProps {
  sessionId?: string;
  port?: number;
  currentPath?: string;
  label?: string;
  workspaceKey?: string;
  paneId?: string;
  tabId?: string;
  isActiveTab?: boolean;
  onClose?: () => void;
}

export function PreviewWorkbenchPane({
  sessionId = '',
  port,
  currentPath,
  label,
}: PreviewWorkbenchPaneProps) {
  const { data: sessionData } = useGetShellSessionQuery(
    { sessionId },
    { skip: !sessionId },
  );
  const [restartShell, { isLoading: isRestarting }] = useRestartShellMutation();

  const liveSession = (sessionData as ShellSession | undefined) ?? undefined;
  const effectivePort = liveSession?.server_port ?? port ?? 0;
  const effectiveLabel = liveSession?.label || liveSession?.cmd || label || sessionId;
  const liveStatus = liveSession?.status || 'running';
  const bridgeOnline = liveSession?.bridge_online;

  const initialSubpath = normalizePreviewSubpath(currentPath || '/');
  const [subView, setSubView] = useState<'preview' | 'output'>('preview');
  const [subpath, setSubpath] = useState<string>(initialSubpath);
  const [pathInput, setPathInput] = useState<string>(initialSubpath);
  const [iframeKey, setIframeKey] = useState<number>(0);
  const [copied, setCopied] = useState<boolean>(false);
  const [restartError, setRestartError] = useState<string>('');

  useEffect(() => {
    if (currentPath !== undefined) {
      const normalized = normalizePreviewSubpath(currentPath);
      setSubpath(normalized);
      setPathInput(normalized);
    }
  }, [currentPath]);

  useEffect(() => {
    setRestartError('');
  }, [sessionId, liveStatus]);

  const baseUrl = buildWorkbenchPreviewUrl(sessionId);
  const normalizedSubpath = normalizePreviewSubpath(subpath);
  const fullPreviewUrl =
    normalizedSubpath === '/'
      ? baseUrl
      : `${baseUrl.replace(/\/$/, '')}${normalizedSubpath}`;

  const isStatusUnknown =
    liveSession !== undefined &&
    bridgeOnline === false &&
    !DEAD_STATUSES.has(liveStatus);
  const isDead = DEAD_STATUSES.has(liveStatus) || isStatusUnknown;

  const failureCopy = getPreviewFailureCopy(
    liveSession,
    liveStatus,
    effectivePort,
    isStatusUnknown,
  );

  const handleNavigateSubpath = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault();
      const next = normalizePreviewSubpath(pathInput);
      setSubpath(next);
      setPathInput(next);
    },
    [pathInput],
  );

  const handleReload = useCallback(() => {
    setIframeKey((k) => k + 1);
  }, []);

  const handleCopyUrl = useCallback(async () => {
    try {
      const origin = typeof window !== 'undefined' ? window.location.origin : '';
      await navigator.clipboard?.writeText(`${origin}${fullPreviewUrl}`);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Ignore clipboard failure in non-secure context
    }
  }, [fullPreviewUrl]);

  const handleRestart = useCallback(async () => {
    if (!sessionId || isRestarting) return;
    setRestartError('');
    try {
      await restartShell({ sessionId }).unwrap();
      setIframeKey((k) => k + 1);
    } catch (err) {
      setRestartError(restartFailureText(err));
    }
  }, [sessionId, isRestarting, restartShell]);

  return (
    <div
      data-debug-id={`workbench-preview-pane-${sessionId}`}
      className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-surface text-primary"
    >
      {/* URL & Action Bar */}
      <div
        data-debug-id="workbench-preview-toolbar"
        className="flex h-9 shrink-0 items-center justify-between gap-2 border-b border-subtle bg-surface-raised/60 px-2.5"
      >
        {/* Preview | Stdout view switcher */}
        <div
          data-debug-id="workbench-preview-subview-tabs"
          className="flex shrink-0 items-center rounded border border-subtle bg-surface p-0.5"
        >
          <button
            type="button"
            data-debug-id="workbench-preview-tab-iframe"
            onClick={() => setSubView('preview')}
            className={`rounded px-2 py-0.5 text-[11px] font-medium transition-colors ${
              subView === 'preview'
                ? 'bg-accent/15 text-accent'
                : 'text-muted hover:text-primary'
            }`}
          >
            Preview
          </button>
          <button
            type="button"
            data-debug-id="workbench-preview-tab-stdout"
            onClick={() => setSubView('output')}
            className={`rounded px-2 py-0.5 text-[11px] font-medium transition-colors ${
              subView === 'output'
                ? 'bg-accent/15 text-accent'
                : 'text-muted hover:text-primary'
            }`}
          >
            Stdout
          </button>
        </div>

        {/* Subpath input bar */}
        <form onSubmit={handleNavigateSubpath} className="flex min-w-0 flex-1 items-center gap-1">
          <span
            data-debug-id="workbench-preview-port-badge"
            className="shrink-0 rounded bg-neutral-soft px-1.5 py-0.5 font-mono text-[10px] font-semibold text-muted"
            title={`${effectiveLabel} (port ${effectivePort})`}
          >
            :{effectivePort}
          </span>
          <input
            type="text"
            aria-label="Preview path"
            data-debug-id="workbench-preview-path-input"
            value={pathInput}
            onChange={(e) => setPathInput(e.target.value)}
            placeholder="/"
            className="min-w-0 flex-1 rounded border border-subtle bg-surface px-2 py-0.5 font-mono text-xs text-primary focus:border-accent focus:outline-none"
          />
        </form>

        {/* Controls: Reload, Copy URL, Open External */}
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            onClick={handleReload}
            title="Reload preview"
            aria-label="Reload preview"
            data-debug-id="workbench-preview-reload-btn"
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="refresh" size={13} />
          </button>
          <button
            type="button"
            onClick={() => void handleCopyUrl()}
            title={copied ? 'Copied URL' : 'Copy preview URL'}
            aria-label="Copy preview URL"
            data-debug-id="workbench-preview-copy-url-btn"
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name={copied ? 'check' : 'copy'} size={13} />
          </button>
          <a
            href={fullPreviewUrl}
            target="_blank"
            rel="noopener noreferrer"
            title="Open preview in new browser tab"
            aria-label="Open preview in new browser tab"
            data-debug-id="workbench-preview-open-external"
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="arrow-up" size={13} />
          </a>
        </div>
      </div>

      {/* Dead-Server / Status-Unknown Banner */}
      {isDead ? (
        <div
          data-debug-id="workbench-preview-dead-banner"
          className="flex shrink-0 flex-wrap items-center justify-between gap-2 border-b border-warning/40 bg-warning-soft px-3 py-2 text-xs text-warning"
        >
          <div className="min-w-0 flex-1">
            <div className="font-semibold">{failureCopy.headline}</div>
            <div className="text-[11px] opacity-90">{failureCopy.detail}</div>
            {restartError ? (
              <div data-debug-id="workbench-preview-restart-error" className="mt-1 text-[11px] text-danger">
                {restartError}
              </div>
            ) : null}
          </div>
          <div className="flex shrink-0 items-center gap-1.5">
            <button
              type="button"
              onClick={() => setSubView('output')}
              data-debug-id="workbench-preview-view-stdout-btn"
              className="rounded border border-warning/40 bg-surface px-2 py-1 text-[11px] font-semibold text-primary hover:bg-surface-raised"
            >
              View stdout
            </button>
            {failureCopy.canRestart ? (
              <button
                type="button"
                disabled={isRestarting}
                onClick={() => void handleRestart()}
                data-debug-id="workbench-preview-restart-btn"
                className="rounded bg-accent px-2.5 py-1 text-[11px] font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {isRestarting ? 'Restarting…' : 'Restart server'}
              </button>
            ) : null}
          </div>
        </div>
      ) : null}

      {/* Main Content Area: Keep iframe mounted with hidden class when viewing output */}
      <div className="relative flex flex-1 min-h-0 w-full flex-col overflow-hidden">
        <div
          data-debug-id="workbench-preview-iframe-wrapper"
          className={subView === 'output' ? 'hidden' : 'relative flex flex-1 min-h-0 w-full flex-col'}
        >
          <iframe
            key={`${sessionId}:${iframeKey}`}
            src={fullPreviewUrl}
            title={`Live preview for ${effectiveLabel}`}
            data-debug-id="workbench-preview-iframe"
            className="h-full w-full flex-1 border-0 bg-white"
          />
        </div>

        {subView === 'output' ? (
          <div
            data-debug-id="workbench-preview-stdout-wrapper"
            className="flex flex-1 min-h-0 w-full flex-col overflow-y-auto p-3"
          >
            {liveSession ? (
              <ShellLogViewer session={liveSession} showSessionVerbs={false} />
            ) : (
              <div className="text-xs text-muted">Loading server stdout…</div>
            )}
          </div>
        ) : null}
      </div>
    </div>
  );
}

export default PreviewWorkbenchPane;
