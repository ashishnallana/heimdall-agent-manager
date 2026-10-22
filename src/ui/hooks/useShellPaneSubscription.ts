import { useCallback, useEffect, useRef, useState } from 'react';
import { useLazyGetShellPaneQuery } from '../api/endpoints/shells';

export interface UseShellPaneSubscriptionOptions {
  sessionId?: string | null;
  isExpanded?: boolean;
  isActiveTab?: boolean;
  status?: string;
  width?: number;
  lineLimit?: number;
}

export interface UseShellPaneSubscriptionResult {
  output: string;
  hash: string;
  isLoading: boolean;
  isFetching: boolean;
  lastUpdatedAt: number | null;
  polling: boolean;
  isBridgeUnreachable: boolean;
  error?: any;
  refetch: () => void;
}

/** Statuses after which a shell session can never produce new output again. */
export const SHELL_TERMINAL_STATUSES = ['exited', 'killed', 'failed'];

export function isShellTerminalStatus(status?: string): boolean {
  return Boolean(status && SHELL_TERMINAL_STATUSES.includes(status));
}

/**
 * Computes the polling interval for a shell session's pane feed. Mirrors
 * computeAgentPanePollingInterval, with runtime_status replaced by the shell session
 * status vocabulary:
 * - sessionId: null/empty pauses polling (0)
 * - status: a terminal status (exited/killed/failed) pauses polling (0)
 * - isActiveTab: false pauses polling (0)
 * - isDocumentHidden: true pauses polling (0)
 * - isExpanded: true => 500 ms (continuous feed), false => 300000 ms (5m)
 */
export function computeShellPanePollingInterval(options: {
  sessionId?: string | null;
  isExpanded?: boolean;
  isActiveTab?: boolean;
  status?: string;
  isDocumentHidden?: boolean;
}): number {
  const {
    sessionId,
    isExpanded = true,
    isActiveTab = true,
    status,
    isDocumentHidden = false,
  } = options;

  if (!sessionId || isShellTerminalStatus(status) || !isActiveTab || isDocumentHidden) {
    return 0;
  }

  return isExpanded ? 500 : 300000;
}

/**
 * Subscribes to a shell session's terminal pane feed by polled capture with hash
 * diffing — the same model the agent pane uses (useAgentPaneSubscription), deliberately
 * NOT a PTY output stream: no Attach, no per-instance Output flood on the bridge's
 * single-threaded event loop.
 *
 * - 500ms feed while the pane is open, 300s when collapsed
 * - 0 (paused) when the tab is inactive, the document is hidden, or the session has
 *   reached a terminal status
 * - Tracks the last seen hash and sends it as since_hash; an unchanged reply carries no
 *   output and leaves the retained buffer untouched
 * - Cleans up timers and aborts in-flight queries on unmount
 */
export function useShellPaneSubscription({
  sessionId,
  isExpanded = true,
  isActiveTab = true,
  status,
  width = 80,
  lineLimit = 120,
}: UseShellPaneSubscriptionOptions): UseShellPaneSubscriptionResult {
  const [output, setOutput] = useState<string>('');
  const [hash, setHash] = useState<string>('');
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);
  const [isBridgeUnreachable, setIsBridgeUnreachable] = useState<boolean>(false);
  const [error, setError] = useState<any>(null);

  const lastSeenHashRef = useRef<string>('');
  const activeRequestRef = useRef<{ abort?: () => void } | null>(null);
  const prevSessionIdRef = useRef<string | null | undefined>(sessionId);
  const prevExpandedRef = useRef<boolean>(isExpanded);
  const wasActiveRef = useRef<boolean>(false);

  const [trigger, result] = useLazyGetShellPaneQuery();

  const [isDocumentHidden, setIsDocumentHidden] = useState<boolean>(() => {
    if (typeof document !== 'undefined') {
      return document.hidden;
    }
    return false;
  });

  useEffect(() => {
    if (typeof document === 'undefined') return;
    const handleVisibilityChange = () => {
      setIsDocumentHidden(document.hidden);
    };
    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, []);

  const interval = computeShellPanePollingInterval({
    sessionId,
    isExpanded,
    isActiveTab,
    status,
    isDocumentHidden,
  });

  // Reset state when the session changes.
  useEffect(() => {
    if (prevSessionIdRef.current !== sessionId) {
      prevSessionIdRef.current = sessionId;
      lastSeenHashRef.current = '';
      wasActiveRef.current = false;
      setOutput('');
      setHash('');
      setLastUpdatedAt(null);
      setIsBridgeUnreachable(false);
      setError(null);
    }
  }, [sessionId]);

  const doFetch = useCallback(
    async (customSinceHash?: string) => {
      if (!sessionId || isShellTerminalStatus(status)) {
        return;
      }

      const sinceHashToSend = customSinceHash !== undefined ? customSinceHash : lastSeenHashRef.current;

      try {
        const request = trigger({
          sessionId,
          sinceHash: sinceHashToSend,
          width,
          lineLimit,
        });
        activeRequestRef.current = request;

        const res = await request.unwrap();
        if (res) {
          setIsBridgeUnreachable(false);
          setError(null);
          if (res.hash) {
            lastSeenHashRef.current = res.hash;
            setHash(res.hash);
          }
          // Retain the previous screen when the bridge short-circuits on since_hash.
          if (!res.unchanged && res.output !== undefined) {
            setOutput(res.output);
          }
          setLastUpdatedAt(Date.now());
        }
      } catch (err: any) {
        if (err?.name === 'AbortError') {
          return;
        }
        // A shared capture budget can skip a poll; retain the last good screen.
        if (err?.status === 429 || err?.originalStatus === 429) {
          return;
        }
        const is503 = err?.status === 503 || err?.originalStatus === 503;
        const errMsg = String(err?.data?.error || err?.data?.message || err?.message || '').toLowerCase();
        const unreachable = is503 || errMsg.includes('bridge') || errMsg.includes('unreachable') || errMsg.includes('offline');
        if (unreachable) {
          setIsBridgeUnreachable(true);
        }
        setError(err);
        // Polling errors do not overwrite the cached screen.
      } finally {
        activeRequestRef.current = null;
      }
    },
    [sessionId, status, width, lineLimit, trigger]
  );

  const doFetchRef = useRef(doFetch);
  useEffect(() => {
    doFetchRef.current = doFetch;
  });

  // Immediate fetch when becoming active, so the prompt appears without typing.
  useEffect(() => {
    const isActive = Boolean(
      sessionId && !isShellTerminalStatus(status) && isActiveTab && !isDocumentHidden
    );

    if (isActive && !wasActiveRef.current) {
      doFetchRef.current();
    }
    wasActiveRef.current = isActive;
  }, [sessionId, status, isActiveTab, isDocumentHidden]);

  // Immediate refetch when the pane expands.
  useEffect(() => {
    const prevExpanded = prevExpandedRef.current;
    prevExpandedRef.current = isExpanded;

    if (!prevExpanded && isExpanded) {
      if (sessionId && !isShellTerminalStatus(status) && isActiveTab && !isDocumentHidden) {
        doFetchRef.current();
      }
    }
  }, [isExpanded, sessionId, status, isActiveTab, isDocumentHidden]);

  // REQ-SHELL-6 §6 — JUSTIFIED EXCEPTION 2 of 2, kept by explicit coordinator ruling
  // rather than by my own judgement. This timer is NOT a status poller: it is the
  // LEGACY TRANSPORT that paints the interactive terminal SCREEN, and the no-polling
  // decision is about how STATUS reaches the UI.
  //
  // It cannot be deleted yet because its replacement is still gated server-side:
  // ShellTerminalPane uses the WebSocket path (useShellStream) only when the
  // `streaming_terminal_pane` experiment is enabled, and the hub REFUSES the stream
  // route with 403 for anyone else. shell_stream_experiment_enabled defaults to ON
  // when the user has no stored row, but an explicit opt-out is respected
  // (shell_session_handlers.odin:34-52, :86-90). Removing this timer would therefore
  // leave every user who turned the experiment off with a `shell` session whose
  // terminal never paints, which is a worse regression than the polling.
  //
  // Retiring it is REQ-SHELL-19, deliberately sequenced: prove the WS path works with
  // the experiment OFF, then remove the hub gate, then delete this transport and the
  // fallback branch. Do not delete it ahead of step 1.
  useEffect(() => {
    if (interval <= 0 || !sessionId) {
      return;
    }

    const timerId = setInterval(() => {
      doFetchRef.current();
    }, interval);

    return () => {
      clearInterval(timerId);
    };
  }, [interval, sessionId]);

  useEffect(() => {
    return () => {
      if (activeRequestRef.current?.abort) {
        activeRequestRef.current.abort();
      }
    };
  }, []);

  const refetch = useCallback(() => {
    doFetchRef.current();
  }, []);

  const currentOutput = output || result.data?.output || '';
  const currentHash = hash || result.data?.hash || '';
  const isLoading =
    result.isLoading ||
    (Boolean(sessionId) && interval > 0 && lastUpdatedAt === null && result.isFetching);

  const rawQueryError = result.error as any;
  const queryError = rawQueryError?.status === 429 || rawQueryError?.originalStatus === 429
    ? undefined
    : rawQueryError;
  const isQuery503 = queryError?.status === 503 || queryError?.originalStatus === 503;
  const queryErrMsg = String(queryError?.data?.error || queryError?.data?.message || queryError?.message || '').toLowerCase();
  const queryUnreachable = Boolean(
    isQuery503 ||
    queryErrMsg.includes('bridge') ||
    queryErrMsg.includes('unreachable') ||
    queryErrMsg.includes('offline')
  );

  const effectiveIsBridgeUnreachable = isBridgeUnreachable || queryUnreachable;

  return {
    output: currentOutput,
    hash: currentHash,
    isLoading,
    isFetching: result.isFetching,
    lastUpdatedAt,
    polling: interval > 0,
    isBridgeUnreachable: effectiveIsBridgeUnreachable,
    error: error || queryError,
    refetch,
  };
}
