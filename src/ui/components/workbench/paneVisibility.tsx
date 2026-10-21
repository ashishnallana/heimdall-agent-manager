import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { isTerminalQueryError } from '../../api/cookieFetch';
import { registerPane, takeDirty, unregisterPane, updatePane } from '../../api/paneDeferral';

/**
 * Whether a pane is actually on screen. Panes stay MOUNTED when the layout hides
 * them: a tile hidden behind a maximised one (TilingContainer), the main area under
 * a maximised aux dock (Workspace), an off-screen mobile pager page
 * (MobileMainPager) and a hidden aux dock. RTK's focus gate only sees
 * `document.visibilityState`, so without this every hidden pane kept polling and
 * marked its conversation read while nobody could see it.
 *
 * Each hiding container wraps its panes in a provider; nested providers AND together,
 * so a pane is visible only when every container above it shows it.
 */
const PaneVisibilityContext = createContext(true);

export function PaneVisibilityProvider({ visible, children }: { visible: boolean; children: ReactNode }) {
  const parentVisible = useContext(PaneVisibilityContext);
  return (
    <PaneVisibilityContext.Provider value={parentVisible && visible}>
      {children}
    </PaneVisibilityContext.Provider>
  );
}

function documentVisible(): boolean {
  return typeof document === 'undefined' || document.visibilityState !== 'hidden';
}

/** The browser tab is visible (not minimised or in a background tab). */
export function useDocumentVisible(): boolean {
  const [visible, setVisible] = useState(documentVisible);
  useEffect(() => {
    if (typeof document === 'undefined') return undefined;
    const onChange = () => setVisible(documentVisible());
    document.addEventListener('visibilitychange', onChange);
    return () => document.removeEventListener('visibilitychange', onChange);
  }, []);
  return visible;
}

/** The pane is laid out on screen AND the browser tab is visible. */
export function usePaneVisible(): boolean {
  const layoutVisible = useContext(PaneVisibilityContext);
  const docVisible = useDocumentVisible();
  return layoutVisible && docVisible;
}

/**
 * A pane may clear unread only when a person can see it: it is the selected tab in
 * its container (`isActiveTab`), it is on screen, and there is something unread.
 */
export function paneShouldMarkRead(input: {
  isActiveTab: boolean;
  paneVisible: boolean;
  conversationId: string;
  agentInstanceId: string;
  unreadCount: number;
}): boolean {
  return Boolean(
    input.isActiveTab &&
      input.paneVisible &&
      input.conversationId &&
      input.agentInstanceId &&
      input.unreadCount > 0,
  );
}

/** Per-pane poll cadence: hidden panes do not poll; they refetch when shown. */
export function visiblePollInterval(paneVisible: boolean, intervalMs: number): number {
  return paneVisible ? intervalMs : 0;
}

/**
 * Clears unread for a pane's conversation whenever paneShouldMarkRead allows it: on
 * mount, when new unread arrives, and when a hidden pane is shown again.
 */
export function usePaneMarkRead(input: {
  isActiveTab: boolean;
  paneVisible: boolean;
  conversationId: string;
  agentInstanceId: string;
  unreadCount: number;
  markRead: (conversationId: string) => void;
}): void {
  const { isActiveTab, paneVisible, conversationId, agentInstanceId, unreadCount } = input;
  const markReadRef = useRef(input.markRead);
  markReadRef.current = input.markRead;
  useEffect(() => {
    if (paneShouldMarkRead({ isActiveTab, paneVisible, conversationId, agentInstanceId, unreadCount })) {
      markReadRef.current(conversationId);
    }
  }, [isActiveTab, paneVisible, conversationId, agentInstanceId, unreadCount]);
}

export type PanePollPolicy = {
  /** Poll interval for the named query: 0 while hidden or after a terminal error. */
  interval: (key: string, intervalMs: number) => number;
  isTerminal: (key: string) => boolean;
  /** Feed each named query's current error; call once per render after the queries. */
  useReportErrors: (errors: Record<string, unknown>) => void;
};

/**
 * Per-pane polling: nothing polls while the pane is hidden, and a query stops polling
 * once it answers 401/403/404/410 (isTerminalQueryError) because repeating the
 * request cannot help. Invalidations and refetch-on-show still try once, and a
 * success clears the flag so polling resumes.
 */
export function usePanePollPolicy(paneVisible: boolean): PanePollPolicy {
  const [terminal, setTerminal] = useState<Record<string, boolean>>({});
  return {
    interval: (key, intervalMs) => (terminal[key] ? 0 : visiblePollInterval(paneVisible, intervalMs)),
    isTerminal: (key) => Boolean(terminal[key]),
    useReportErrors: (errors) => {
      const now: Record<string, boolean> = {};
      for (const [key, error] of Object.entries(errors)) if (isTerminalQueryError(error)) now[key] = true;
      const signature = Object.keys(now).sort().join(',');
      useEffect(() => {
        setTerminal((prev) => (Object.keys(prev).sort().join(',') === signature ? prev : now));
      }, [signature]);
    },
  };
}

/**
 * Registers the pane's conversation and visibility with paneDeferral, so a new message
 * reaching only hidden panes is recorded instead of refetched. When the pane is shown
 * and its conversation missed a refresh, `refresh` runs once (the deferred refetch).
 */
export function usePaneDeferredRefresh(conversationId: string, paneVisible: boolean, refresh: () => void): void {
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  const idRef = useRef<number | null>(null);
  useEffect(() => {
    if (!conversationId) return undefined;
    const id = registerPane(conversationId, paneVisible);
    idRef.current = id;
    return () => {
      unregisterPane(id);
      idRef.current = null;
    };
    // Visibility changes are applied below without re-registering the pane.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationId]);
  useEffect(() => {
    if (idRef.current === null || !conversationId) return;
    updatePane(idRef.current, conversationId, paneVisible);
    if (paneVisible && takeDirty(conversationId)) refreshRef.current();
  }, [conversationId, paneVisible]);
}
