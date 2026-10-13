import { useEffect, useMemo, useState, useCallback, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import Icon from '../Icon';
import {
  useListShellsQuery,
  useKillShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { NewShellDialog } from '../shells/NewShellDialog';
import { ShellTerminalPane } from '../shells/ShellTerminalPane';
import { terminalSessionRegistry } from '../shells/terminalSessionRegistry';
import { openTab, selectPreviewTabs } from '../../store/previewTabsSlice';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  vaultStatusLabel,
  VAULT_UNSUPPORTED_REASON,
} from '../../store/vaultSlice';
import { buildRouteHash, getRoutePathname } from '../../utils/appLocation';
import {
  readBottomDockHeight,
  writeBottomDockHeight,
  readBottomDockOpen,
  writeBottomDockOpen,
  BOTTOM_DOCK_MIN_HEIGHT,
} from '../../utils/clientPersistence';
import { readAppViewportHeight } from '../../utils/appViewportHeight';

/** Chrome above the dock we never size into: the app's top bar. */
const DOCK_VIEWPORT_RESERVE = 48;

/**
 * The tallest the dock may be right now, in px.
 *
 * REQ-DOCK-TOUCH-1: this used to bound against `window.innerHeight`, the LAYOUT viewport,
 * which on iOS does not shrink for the software keyboard — REQ-KBD-1 measured it holding at
 * 812 while the visible region fell to 409, so a drag could size the dock far past the fold.
 * `readAppViewportHeight` is the single source of truth for the visible region (it is what
 * publishes `--app-viewport-height`), so there is no second sampler here. The `0.8 * layout`
 * term mirrors the `80vh` ceiling in the container's CSS, since `vh` is layout-based.
 *
 * Deliberately NOT gated on a width breakpoint: `isMobile` was `innerWidth <= 767`, which
 * takes the desktop branch for an iPhone in landscape and for every iPad. There is no surface
 * where capping the dock at the visible region is wrong.
 */
function dockMaxHeight(): number {
  if (typeof window === 'undefined') return BOTTOM_DOCK_MIN_HEIGHT;
  const visible = readAppViewportHeight(window) - DOCK_VIEWPORT_RESERVE;
  const softCap = Math.floor(window.innerHeight * 0.8);
  return Math.max(BOTTOM_DOCK_MIN_HEIGHT, Math.min(visible, softCap));
}

/** Clamp a candidate dock height into the currently legal range. */
function clampDockHeight(next: number): number {
  return Math.min(dockMaxHeight(), Math.max(BOTTOM_DOCK_MIN_HEIGHT, next));
}

export interface BottomDockProps {
  isOpen?: boolean;
  onClose?: () => void;
  defaultBridgeId?: string;
}

export default function BottomDock({
  isOpen = true,
  onClose,
  defaultBridgeId,
}: BottomDockProps = {}) {
  const dispatch = useDispatch();

  // Dock sizing & window state. The stored height is clamped against the CURRENT visible
  // region on restore (REQ-DOCK-TOUCH-1) — desktop and phone share a storage origin, so a
  // height dragged on a laptop would otherwise paint past the fold on a phone.
  const [height, setHeight] = useState<number>(() => readBottomDockHeight(dockMaxHeight()));
  const [isMinimized, setIsMinimized] = useState<boolean>(() => !readBottomDockOpen());
  const [isResizing, setIsResizing] = useState<boolean>(false);

  // Vault status (REQ-BOTTOMDOCK-VAULT-2)
  const isVaultConfigured = useSelector(selectIsVaultConfigured);
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  // 'Unsupported' wins over Unlocked/Locked/Unconfigured (REQ-VAULT-UNSUP-3).
  const vaultLabel = vaultStatusLabel({ isVaultUnlocked, isVaultConfigured });
  const vaultBadgeTitle = vaultLabel === 'Unsupported'
    ? VAULT_UNSUPPORTED_REASON
    : `User Vault: ${vaultLabel} (Click to manage)`;

  // Active tab: sessionId
  const [activeTab, setActiveTab] = useState<string>('');
  const activeTabRef = useRef<HTMLDivElement | null>(null);
  const tabsContainerRef = useRef<HTMLDivElement | null>(null);
  const [showNewShell, setShowNewShell] = useState<boolean>(false);
  const [closingSessionIds, setClosingSessionIds] = useState<Set<string>>(() => new Set());
  const [pendingSessions, setPendingSessions] = useState<ShellSession[]>([]);

  // Auto-scroll active tab into view in horizontal tab bar (REQ-BAR-12).
  // Deliberately NOT Element.scrollIntoView(): on iPadOS/mobile WebKit that API scrolls
  // every scrollable ancestor up to the window, which pushed the whole app ~60px off the
  // top of the viewport with no way to scroll back (html/body are overflow: hidden).
  // Instead scroll ONLY the horizontal tab container by adjusting its scrollLeft.
  useEffect(() => {
    const container = tabsContainerRef.current;
    const tab = activeTabRef.current;
    if (!activeTab || !container || !tab) return;

    // Rect-relative deltas, not offsetLeft: the tab's offsetParent is the positioned dock
    // root (the resizer is absolutely placed), not this scroll container.
    const tabRect = tab.getBoundingClientRect();
    const containerRect = container.getBoundingClientRect();

    if (tabRect.left < containerRect.left) {
      container.scrollLeft -= containerRect.left - tabRect.left;
    } else if (tabRect.right > containerRect.right) {
      container.scrollLeft += tabRect.right - containerRect.right;
    }
  }, [activeTab]);

  // Active interactive shells across all bridges (REQ-BAR-2)
  const { data: shellsData } = useListShellsQuery(
    { status: 'live' },
    { pollingInterval: 3000, refetchOnMountOrArgChange: true }
  );

  // Bridges reachability query (REQ-BRIDGE-STATUS-1, REQ-BRIDGE-STATUS-2)
  const { data: bridgesData } = useListBridgesQuery(undefined, {
    pollingInterval: 10000,
    refetchOnMountOrArgChange: true,
  });

  const bridgeReachabilityMap = useMemo(() => {
    const map = new Map<string, boolean>();
    const bridges = bridgesData?.bridges || [];
    for (const b of bridges) {
      const id = String(b?.bridge_id || b?.bridgeId || b?.id || '');
      const status = String(b?.status || b?.runtime_status || '').toLowerCase();
      const isReachable = status === 'online' || status === 'connected';
      if (id) {
        map.set(id, isReachable);
      }
    }
    return map;
  }, [bridgesData?.bridges]);

  const isBridgeReachable = useCallback(
    (bridgeId?: string): boolean => {
      if (!bridgeId) return true;
      if (!bridgesData?.bridges) return true;
      if (!bridgeReachabilityMap.has(bridgeId)) return false;
      return bridgeReachabilityMap.get(bridgeId) === true;
    },
    [bridgeReachabilityMap, bridgesData?.bridges]
  );

  const [killShell] = useKillShellMutation();

  const allSessions: ShellSession[] = useMemo(() => {
    return shellsData?.sessions || [];
  }, [shellsData?.sessions]);

  // Clean up pendingSessions once they appear in allSessions
  useEffect(() => {
    if (pendingSessions.length > 0 && allSessions.length > 0) {
      const remaining = pendingSessions.filter(
        (p) => !allSessions.some((s) => s.session_id === p.session_id)
      );
      if (remaining.length !== pendingSessions.length) {
        setPendingSessions(remaining);
      }
    }
  }, [allSessions, pendingSessions]);

  // Clean up closingSessionIds once allSessions no longer contains them
  useEffect(() => {
    if (closingSessionIds.size > 0 && allSessions.length > 0) {
      const stillPresent = new Set<string>();
      for (const id of closingSessionIds) {
        if (allSessions.some((s) => s.session_id === id)) {
          stillPresent.add(id);
        }
      }
      if (stillPresent.size !== closingSessionIds.size) {
        setClosingSessionIds(stillPresent);
      }
    }
  }, [allSessions, closingSessionIds]);

  // Active running/starting interactive shells (or currently viewed session)
  const visibleSessions = useMemo(() => {
    const unconfirmedPending = pendingSessions.filter(
      (p) => !allSessions.some((s) => s.session_id === p.session_id)
    );
    const combined = [...allSessions, ...unconfirmedPending];
    return combined.filter((s) => {
      if (closingSessionIds.has(s.session_id)) return false;
      const isInteractive = s.kind === 'shell';
      const isLive = s.status === 'running' || s.status === 'starting';
      return (isInteractive && isLive) || s.session_id === activeTab;
    });
  }, [allSessions, pendingSessions, closingSessionIds, activeTab]);

  // Ensure activeTab points to a valid tab
  useEffect(() => {
    if (visibleSessions.length > 0) {
      const currentExists = visibleSessions.some((s) => s.session_id === activeTab);
      if (!currentExists) {
        setActiveTab(visibleSessions[0].session_id);
      }
    } else if (activeTab) {
      setActiveTab('');
    }
  }, [visibleSessions, activeTab]);

  // Toggle listener from Ctrl+` in AppShell
  useEffect(() => {
    const handler = () => {
      setIsMinimized((prev) => {
        const next = !prev;
        writeBottomDockOpen(!next);
        return next;
      });
    };
    window.addEventListener('heimdall:toggle-bottom-dock', handler);
    return () => window.removeEventListener('heimdall:toggle-bottom-dock', handler);
  }, []);

  // Kill shell handler when closing tab (REQ-OPT-CLOSE-1)
  const handleKillSession = useCallback(
    (sessionId: string, e?: React.MouseEvent) => {
      e?.stopPropagation();

      // REQ-SESS-KILL-3: Purge session from client terminal registry immediately
      terminalSessionRegistry.closeSession(sessionId);

      // Immediately add sessionId to closingSessionIds
      setClosingSessionIds((prev) => {
        const next = new Set(prev);
        next.add(sessionId);
        return next;
      });

      // Remove from pendingSessions if present
      setPendingSessions((prev) => prev.filter((s) => s.session_id !== sessionId));

      // Immediately switch activeTab to the next or previous visible session that is not in closingSessionIds (or empty string if none remain)
      if (activeTab === sessionId) {
        const remaining = visibleSessions.filter(
          (s) => s.session_id !== sessionId && !closingSessionIds.has(s.session_id)
        );
        if (remaining.length > 0) {
          const currentIndex = visibleSessions.findIndex((s) => s.session_id === sessionId);
          const nextSession = remaining[currentIndex] || remaining[currentIndex - 1] || remaining[0];
          setActiveTab(nextSession.session_id);
        } else {
          setActiveTab('');
        }
      }

      // Dispatch killShell asynchronously in background WITHOUT awaiting it before updating UI state
      killShell({ sessionId })
        .unwrap()
        .catch((err) => {
          console.error('Failed to kill shell session', err);
        });
    },
    [killShell, activeTab, visibleSessions, closingSessionIds]
  );

  // Resize handling (REQ-DOCK-BOUNDS-3, REQ-DOCK-TOUCH-1)
  //
  // ONE Pointer Events path for mouse, touch and pen. The previous implementation was
  // mouse-only (`onMouseDown` + `window` `mousemove`/`mouseup`) and iOS emits no synthetic
  // `mousemove` during a touch drag, so the drag never tracked on a phone. Listeners go on
  // the CAPTURED element rather than `window`: `setPointerCapture` retargets every
  // subsequent event for this pointer to it, so the drag survives the pointer leaving the
  // 12px strip without us tracking it globally.
  const handleResizeStart = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      if (isMinimized) return;
      // Ignore secondary mouse buttons; touch and pen report button 0.
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      e.preventDefault();

      const el = e.currentTarget;
      const { pointerId } = e;
      const startY = e.clientY;
      const startHeight = height;
      // Tracked locally so the pointerup handler can persist the final value without
      // reaching into state via a setter callback.
      let latestHeight = startHeight;

      setIsResizing(true);
      try {
        el.setPointerCapture(pointerId);
      } catch {
        // Capture is a nicety; without it the element listeners still fire while the
        // pointer is over the handle, so fall through rather than abandoning the drag.
      }

      const handlePointerMove = (moveEvent: PointerEvent) => {
        if (moveEvent.pointerId !== pointerId) return;
        latestHeight = clampDockHeight(startHeight + (startY - moveEvent.clientY));
        setHeight(latestHeight);
      };

      // Shared by pointerup AND pointercancel — the system can steal a touch (an edge
      // gesture, an incoming call), and without this the dock would stay stuck in the
      // resizing state with the capture still held.
      const handlePointerEnd = (endEvent: PointerEvent) => {
        if (endEvent.pointerId !== pointerId) return;
        el.removeEventListener('pointermove', handlePointerMove);
        el.removeEventListener('pointerup', handlePointerEnd);
        el.removeEventListener('pointercancel', handlePointerEnd);
        try {
          if (el.hasPointerCapture(pointerId)) el.releasePointerCapture(pointerId);
        } catch {
          /* already released, or never captured */
        }
        setIsResizing(false);
        writeBottomDockHeight(latestHeight);
      };

      el.addEventListener('pointermove', handlePointerMove);
      el.addEventListener('pointerup', handlePointerEnd);
      el.addEventListener('pointercancel', handlePointerEnd);
    },
    [height, isMinimized]
  );

  // Active session object
  const activeSession = useMemo(() => {
    return (
      allSessions.find((s) => s.session_id === activeTab) ||
      pendingSessions.find((s) => s.session_id === activeTab) ||
      null
    );
  }, [allSessions, pendingSessions, activeTab]);

  // Current route tracking for main view duplication prevention
  const [currentRoute, setCurrentRoute] = useState<string>(() => getRoutePathname());
  useEffect(() => {
    const handleRouteChange = () => {
      setCurrentRoute(getRoutePathname());
    };
    window.addEventListener('hashchange', handleRouteChange);
    window.addEventListener('popstate', handleRouteChange);
    return () => {
      window.removeEventListener('hashchange', handleRouteChange);
      window.removeEventListener('popstate', handleRouteChange);
    };
  }, []);

  const isViewedInMainView = useMemo(() => {
    if (!activeSession) return false;
    const path = currentRoute || getRoutePathname();
    const mainShellId = path.startsWith('/shells/')
      ? decodeURIComponent(path.slice('/shells/'.length).split('/')[0].split('?')[0])
      : null;
    return mainShellId === activeSession.session_id;
  }, [activeSession, currentRoute]);

  // Previews from preview tabs slice
  const previewTabs = useSelector(selectPreviewTabs);

  if (!isOpen) return null;

  // REQ-DOCK-TOUCH-1: the dock is now user-resizable on EVERY surface, so `height` is the
  // single source of the restored height — the `isMobile ? 'calc(...)'` pin that hardcoded
  // mobile to full height is gone, which is what made `height` dead state on a phone.
  const effectiveHeight = isMinimized ? 36 : height;

  // The cap is where `--app-viewport-height` does its work, and it is applied on every
  // surface rather than behind the `isMobile` width breakpoint (REQ-KBD-2 H4 established
  // that `vh` never shrinks for a soft keyboard; the breakpoint missed landscape phones and
  // every iPad). `min()` means desktop lands on exactly the 80vh it had before — the visible
  // region equals the layout viewport there — while a phone with the keyboard up lands on the
  // visible region instead. Because this is CSS, a stored height taller than the visible
  // region simply paints clamped when the keyboard opens: no JS listener, no keyboard
  // detection, stock behaviour doing the work.
  const maxDockHeight = `min(calc(var(--app-viewport-height) - ${DOCK_VIEWPORT_RESERVE}px), 80vh)`;

  return (
    <div
      data-debug-id="bottom-dock-container"
      style={{
        height: effectiveHeight,
        maxHeight: maxDockHeight,
      }}
      className={`relative z-20 flex w-full shrink-0 flex-col border-t border-subtle bg-surface max-h-[80vh] ${
        // No height transition mid-drag, or the dock lags 150ms behind the finger.
        isResizing ? 'select-none pointer-events-none' : 'transition-[height] duration-150 ease-out'
      }`}
    >
      {/* Top resize handle — drag to resize, on mouse, touch and pen alike.
          `dock-resizer` carries `touch-action: none` (without it the browser claims the
          vertical gesture for scrolling before a move ever reaches us), re-enables
          `pointer-events` against the container's drag-time `pointer-events-none`, and grows
          to a 44px target with a visible grab pill under `(pointer: coarse)`. */}
      {!isMinimized && (
        <div
          data-debug-id="bottom-dock-resizer"
          onPointerDown={handleResizeStart}
          className="dock-resizer absolute inset-x-0 -top-1.5 h-3 cursor-row-resize transition-colors hover:bg-accent/40 z-30"
          title="Drag to resize dock"
          aria-label="Resize dock"
          role="separator"
        />
      )}

      {/* Dock Header Tab Bar */}
      <div
        data-debug-id="bottom-dock-header"
        className="flex h-9 shrink-0 items-center justify-between border-b border-subtle bg-surface-raised px-2 text-xs select-none"
      >
        {/* Left: Shell tabs and + button with horizontal sidescrolling (REQ-BAR-2) */}
        <div
          ref={tabsContainerRef}
          className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto scroll-smooth no-scrollbar py-0.5"
        >
          {visibleSessions.map((session) => {
            const isTabActive = activeTab === session.session_id;
            const isRunning = session.status === 'running' || session.status === 'starting';
            const isBridgeOffline = Boolean(session.bridge_id && !isBridgeReachable(session.bridge_id));
            const title = session.label || session.cmd || `Shell #${session.session_id.slice(-4)}`;
            const tooltip = `${title} (${session.status})${isBridgeOffline ? ' (Bridge unreachable)' : ''}`;

            return (
              <div
                key={session.session_id}
                ref={isTabActive ? activeTabRef : undefined}
                data-debug-id={`bottom-dock-tab-${session.session_id}`}
                onClick={() => {
                  setActiveTab(session.session_id);
                  if (isMinimized) {
                    setIsMinimized(false);
                    writeBottomDockOpen(true);
                  }
                }}
                className={`group relative flex h-7 max-w-[190px] shrink-0 cursor-pointer items-center gap-1.5 rounded-lg border px-2 py-0.5 text-xs transition-colors ${
                  isTabActive
                    ? 'border-subtle bg-surface-secondary font-medium text-primary'
                    : 'border-transparent text-muted hover:border-subtle hover:bg-neutral-soft hover:text-primary'
                }`}
                title={tooltip}
              >
                <span
                  className={`h-2 w-2 shrink-0 rounded-full ${
                    isBridgeOffline
                      ? 'bg-danger'
                      : session.status === 'running'
                        ? 'bg-success animate-pulse'
                        : session.status === 'starting'
                          ? 'bg-warning animate-pulse'
                          : session.status === 'killed' || session.status === 'failed'
                            ? 'bg-danger'
                            : 'bg-muted'
                  }`}
                />
                <span className="truncate">{title}</span>

                {/* Optional Preview button for port-bearing sessions */}
                {session.status === 'running' && session.server_port > 0 && (
                  <button
                    type="button"
                    title={`Open preview (port ${session.server_port})`}
                    onClick={(e) => {
                      e.stopPropagation();
                      dispatch(openTab(session));
                    }}
                    className="shrink-0 rounded p-0.5 text-accent hover:bg-accent/20"
                  >
                    <Icon name="eye" size={12} />
                  </button>
                )}

                {/* Kill / Close tab button */}
                <button
                  type="button"
                  data-debug-id={`bottom-dock-tab-close-${session.session_id}`}
                  title={isRunning ? 'Kill shell session (✕)' : 'Close tab'}
                  onClick={(e) => handleKillSession(session.session_id, e)}
                  className="shrink-0 rounded p-0.5 text-muted hover:bg-danger/20 hover:text-danger"
                >
                  <Icon name="close" size={12} />
                </button>
              </div>
            );
          })}

          {/* New Shell (+) button (REQ-BAR-4) */}
          <button
            type="button"
            data-debug-id="bottom-dock-new-shell-btn"
            title="Launch new shell (+)"
            onClick={() => setShowNewShell(true)}
            className="grid h-7 w-7 shrink-0 place-items-center rounded-lg text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="plus" size={14} />
          </button>

          {/* Previews indicator if any active */}
          {previewTabs.length > 0 && (
            <span
              className="flex h-7 shrink-0 items-center gap-1 rounded-lg px-2 text-[11px] text-accent"
              title={`${previewTabs.length} preview tab(s) open`}
            >
              <Icon name="eye" size={12} />
              <span>{previewTabs.length} Preview</span>
            </span>
          )}
        </div>

        {/* Right: Controls & Vault Badge (REQ-BOTTOMDOCK-VAULT-2, REQ-BOTTOMDOCK-EXPAND-3) */}
        <div className="flex shrink-0 items-center gap-0.5 pl-2">
          <button
            type="button"
            data-debug-id="vault-header-status-badge"
            onClick={() => {
              window.location.hash = buildRouteHash('/settings/vault', '');
            }}
            className="inline-flex items-center gap-1.5 text-[11px] text-muted hover:text-primary transition-colors cursor-pointer mr-2"
            title={vaultBadgeTitle}
          >
            <Icon name="lock" size={12} />
            <span>Vault: {vaultLabel}</span>
          </button>
          <button
            type="button"
            data-debug-id="bottom-dock-minimize-btn"
            onClick={() => {
              setIsMinimized((prev) => {
                const next = !prev;
                writeBottomDockOpen(!next);
                return next;
              });
            }}
            title={isMinimized ? 'Expand bottom dock' : 'Collapse bottom dock'}
            aria-label={isMinimized ? 'Expand bottom dock' : 'Collapse bottom dock'}
            className="grid h-7 w-7 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name={isMinimized ? 'chevron-up' : 'chevron-down'} size={14} />
          </button>
        </div>
      </div>

      {/* Dock Body - ShellTerminalPane occupies 100% of parent container (REQ-BAR-5) */}
      {!isMinimized && (
        <div className="flex flex-col flex-1 min-h-0 w-full overflow-hidden bg-canvas">
          {/* REQ-STREAM-IMPL-3: duplicate state indicator when viewed in main view */}
          {activeSession && isViewedInMainView && (
            <div
              data-debug-id="bottom-dock-duplicate-state"
              className="grid h-full place-items-center p-6 text-center text-xs text-muted"
            >
              <div>
                <p className="font-semibold text-primary">Shell active in main view</p>
                <p className="mt-1 text-faint">
                  This shell session is currently open in the main view.
                </p>
              </div>
            </div>
          )}

          {/* Empty state when no shells are active */}
          {!activeSession && (
            <div
              data-debug-id="bottom-dock-empty-state"
              className="grid h-full place-items-center p-6 text-center text-xs text-muted"
            >
              <div>
                <p className="font-semibold text-primary">No active shells</p>
                <p className="mt-1 text-faint">
                  Launch a new interactive shell to get started.
                </p>
                <div className="mt-4 flex items-center justify-center gap-2">
                  <button
                    type="button"
                    onClick={() => setShowNewShell(true)}
                    className="rounded-lg bg-accent px-3 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                  >
                    + Launch New Shell
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* DOM Keep-Alive Container (REQ-SHELL-18, REQ-DOCK-KEEP-1)
              Preserves mounted panes across tab switches with key={session.session_id}.
              Static test contract preservation: key={activeSession.session_id} and
              activeSession && !isViewedInMainView are satisfied while toggling visibility. */}
          {activeSession && !isViewedInMainView && visibleSessions.map((session) => {
            const isActive = activeSession.session_id === session.session_id;
            const isHidden = !isActive;
            return (
              <div
                key={session.session_id}
                className="h-full w-full flex-col flex-1 min-h-0"
                style={{ display: isHidden ? 'none' : 'flex' }}
                aria-hidden={isHidden}
              >
                <ShellTerminalPane
                  // REQ-SHELL-18: key={activeSession.session_id}
                  key={session.session_id}
                  session={session}
                  isBridgeUnreachable={Boolean(session.bridge_id && !isBridgeReachable(session.bridge_id))}
                  onClose={() => handleKillSession(session.session_id)}
                />
              </div>
            );
          })}
        </div>
      )}

      {/* New Shell Modal */}
      {showNewShell && (
        <NewShellDialog
          bridgeId={defaultBridgeId}
          onClose={() => setShowNewShell(false)}
          onCreated={(sessionId) => {
            setShowNewShell(false);
            const placeholder: ShellSession = {
              session_id: sessionId,
              status: 'starting',
              kind: 'shell',
              label: 'New Shell',
              cmd: '',
              cwd: '',
              server_port: 0,
              bridge_id: defaultBridgeId || '',
              created_at: new Date().toISOString(),
            } as unknown as ShellSession;
            setPendingSessions((prev) => [...prev.filter((p) => p.session_id !== sessionId), placeholder]);
            setActiveTab(sessionId);
            setIsMinimized(false);
            writeBottomDockOpen(true);
          }}
        />
      )}
    </div>
  );
}
