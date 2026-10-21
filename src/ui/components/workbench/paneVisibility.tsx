import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

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
