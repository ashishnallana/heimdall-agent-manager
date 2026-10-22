import { isPlanLimitError } from '../utils/planLimit';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useLazyGetAgentPaneQuery } from '../api/endpoints/agents';

export interface UseAgentPaneSubscriptionOptions {
  onPlanLimit?: (error: unknown) => void;
  agentInstanceId?: string | null;
  isExpanded: boolean;
  isActiveTab?: boolean;
  runtimeStatus?: string;
  width?: number;
  lineLimit?: number;
}

export interface UseAgentPaneSubscriptionResult {
  planLimitError: unknown;
  output: string;
  hash: string;
  isLoading: boolean;
  isFetching: boolean;
  lastUpdatedAt: number | null;
  refetch: () => void;
}

/**
 * Computes the polling interval for the agent pane feed based on:
 * - agentInstanceId: null/empty pauses polling (0)
 * - runtimeStatus: 'stopped' or 'failed' pauses polling (0)
 * - isActiveTab: false pauses polling (0)
 * - isDocumentHidden: true pauses polling (0)
 * - isExpanded: true => 500 ms (continuous feed), false => 300000 ms (5m)
 */
export function computeAgentPanePollingInterval(options: {
  agentInstanceId?: string | null;
  isExpanded: boolean;
  isActiveTab?: boolean;
  runtimeStatus?: string;
  isDocumentHidden?: boolean;
}): number {
  const {
    agentInstanceId,
    isExpanded,
    isActiveTab = true,
    runtimeStatus,
    isDocumentHidden = false,
  } = options;

  if (!agentInstanceId || runtimeStatus === 'stopped' || runtimeStatus === 'failed' || !isActiveTab || isDocumentHidden) {
    return 0;
  }

  return isExpanded ? 500 : 300000;
}

/**
 * Custom React hook that subscribes to an agent instance's terminal pane feed.
 *
 * Implements dynamic polling:
 * - 500ms continuous feed when panel is expanded
 * - 300s (5 minutes) when panel is collapsed
 * - 0 (paused) when tab is inactive, window is hidden, or agent is stopped
 * - Tracks last seen hash and passes as since_hash
 * - Triggers an immediate refetch when isExpanded transitions from false to true
 * - Retains output buffer across unchanged responses
 * - Cleans up timers and aborts in-flight queries on component unmount
 */
export function useAgentPaneSubscription({
  onPlanLimit,
  agentInstanceId,
  isExpanded,
  isActiveTab = true,
  runtimeStatus,
  width = 80,
  lineLimit = 120,
}: UseAgentPaneSubscriptionOptions): UseAgentPaneSubscriptionResult {
  const [planLimitError, setPlanLimitError] = useState<unknown>(null);
  const planBlockedRef = useRef(false);
  const onPlanLimitRef = useRef(onPlanLimit);
  onPlanLimitRef.current = onPlanLimit;
  const [output, setOutput] = useState<string>('');
  const [hash, setHash] = useState<string>('');
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);

  const lastSeenHashRef = useRef<string>('');
  const activeRequestRef = useRef<{ abort?: () => void } | null>(null);
  const prevInstanceIdRef = useRef<string | null | undefined>(agentInstanceId);
  const prevExpandedRef = useRef<boolean>(isExpanded);
  const wasActiveRef = useRef<boolean>(false);

  const [trigger, result] = useLazyGetAgentPaneQuery();

  // Track window visibility (document.hidden)
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

  // Compute dynamic interval
  const interval = planLimitError ? 0 : computeAgentPanePollingInterval({
    agentInstanceId,
    isExpanded,
    isActiveTab,
    runtimeStatus,
    isDocumentHidden,
  });

  // Reset state when agentInstanceId changes
  useEffect(() => {
    if (prevInstanceIdRef.current !== agentInstanceId) {
      prevInstanceIdRef.current = agentInstanceId;
      activeRequestRef.current?.abort?.();
      activeRequestRef.current = null;
      planBlockedRef.current = false;
      setPlanLimitError(null);
      lastSeenHashRef.current = '';
      wasActiveRef.current = false;
      setOutput('');
      setHash('');
      setLastUpdatedAt(null);
    }
  }, [agentInstanceId]);

  // Execute fetch function
  const doFetch = useCallback(
    async (customSinceHash?: string) => {
      if (planBlockedRef.current || activeRequestRef.current || !agentInstanceId || runtimeStatus === 'stopped' || runtimeStatus === 'failed') {
        return;
      }

      const sinceHashToSend = customSinceHash !== undefined ? customSinceHash : lastSeenHashRef.current;

      let request: ReturnType<typeof trigger> | undefined;
      try {
        request = trigger({
          agentInstanceId,
          sinceHash: sinceHashToSend,
          width,
          lineLimit,
        });
        activeRequestRef.current = request;

        const res = await request.unwrap();
        if (prevInstanceIdRef.current !== agentInstanceId) return;
        if (res) {
          if (res.hash) {
            lastSeenHashRef.current = res.hash;
            setHash(res.hash);
          }
          // Retain previous output buffer when unchanged is true
          if (!res.unchanged && res.output !== undefined) {
            setOutput(res.output);
          }
          setLastUpdatedAt(Date.now());
        }
      } catch (err: any) {
        if (prevInstanceIdRef.current !== agentInstanceId) return;
        if (err?.name === 'AbortError') {
          return;
        }
        if (isPlanLimitError(err)) {
          planBlockedRef.current = true;
          setPlanLimitError(err);
          onPlanLimitRef.current?.(err);
          return;
        }
        // Polling errors do not overwrite cached output
      } finally {
        if (activeRequestRef.current === request) activeRequestRef.current = null;
      }
    },
    [agentInstanceId, runtimeStatus, width, lineLimit, trigger]
  );

  const doFetchRef = useRef(doFetch);
  useEffect(() => {
    doFetchRef.current = doFetch;
  });

  // Initial fetch when active, or when transitioning from inactive/hidden/stopped to active
  useEffect(() => {
    const isActive = Boolean(
      agentInstanceId &&
        runtimeStatus !== 'stopped' &&
        runtimeStatus !== 'failed' &&
        isActiveTab &&
        !isDocumentHidden
    );

    if (isActive && !wasActiveRef.current) {
      doFetchRef.current();
    }
    wasActiveRef.current = isActive;
  }, [agentInstanceId, runtimeStatus, isActiveTab, isDocumentHidden]);

  // Immediate refetch when isExpanded changes from false to true
  useEffect(() => {
    const prevExpanded = prevExpandedRef.current;
    prevExpandedRef.current = isExpanded;

    if (!prevExpanded && isExpanded) {
      if (
        agentInstanceId &&
        runtimeStatus !== 'stopped' &&
        runtimeStatus !== 'failed' &&
        isActiveTab &&
        !isDocumentHidden
      ) {
        doFetchRef.current();
      }
    }
  }, [isExpanded, agentInstanceId, runtimeStatus, isActiveTab, isDocumentHidden]);

  // Dynamic interval timer
  useEffect(() => {
    if (interval <= 0 || !agentInstanceId) {
      return;
    }

    const timerId = setInterval(() => {
      doFetchRef.current();
    }, interval);

    return () => {
      clearInterval(timerId);
    };
  }, [interval, agentInstanceId]);

  // Cleanup in-flight requests on unmount
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
    (Boolean(agentInstanceId) && interval > 0 && lastUpdatedAt === null && result.isFetching);

  return {
    planLimitError,
    output: currentOutput,
    hash: currentHash,
    isLoading,
    isFetching: result.isFetching,
    lastUpdatedAt,
    refetch,
  };
}
