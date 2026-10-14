import React, { useCallback, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Icon, Menu, StatusDot, runtimeStatusToTone } from '@ui';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import { useSendConversationMessageMutation } from '../../api/endpoints/chats';
import {
  NEW_TAB_ID,
  type AuxContent,
  type AuxTab,
} from '../../store/auxTabId';
import { isAuxContentAllowed } from '../../store/auxTabGuards';
import {
  auxTreeKey,
  closeAuxTab,
  moveAuxTab,
  openAuxNewTab,
  openAuxTab,
  rekeyAuxTab,
  resolveActiveAuxTab,
  selectAuxPane,
  setActiveAuxTab,
  setAuxPaneOpen,
  updateAuxTabContent,
  visibleAuxTabs,
  type AuxTreeId,
} from '../../store/auxPanesSlice';
import { buildConversationHash, navigateToHash } from '../../utils/conversationUrl';
import {
  AUX_DEFAULT_WIDTH,
  clampAuxWidth,
  selectAuxWidth,
  selectIsAuxMaximized,
  setAuxWidth,
  toggleAuxMaximized,
} from '../../store/workspaceChromeSlice';
import { getActiveVaultKey, selectIsVaultUnlocked } from '../../store/vaultSlice';
import { encryptVaultText } from '../../utils/vaultContent';
import { AuxNewTabLauncher } from './AuxNewTabLauncher';
import { AuxTabContent } from './AuxTabContent';
import { AuxTabStrip } from './AuxTabStrip';
import { AuxTabActionsProvider, useAuxTabActionsHost } from './auxTabActions';
import type { AgentAuxContext } from './useAgentAuxContext';

function AgentStatusDotWithApi({ agentInstanceId }: { agentInstanceId: string }) {
  const { data } = useGetAgentsLiveQuery(undefined, { pollingInterval: 30000, skipPollingIfUnfocused: true });
  const status = useMemo(() => {
    for (const p of data || []) {
      for (const c of p.chains || []) {
        const a = (c.liveAgents || []).find((x) => x.agentInstanceId === agentInstanceId);
        if (a) return String(a.runtimeStatus || '');
      }
    }
    return '';
  }, [data, agentInstanceId]);
  if (!status) return null;
  return <StatusDot size="sm" tone={runtimeStatusToTone(status)} label={status} />;
}

/** Runtime status dot on PTY / sub-agent tabs (replaces in-content status pills). */
function AuxTabStatusDot({ tab }: { tab: AuxTab }) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  const c = tab.content;
  if (!hasApiStore || (c.type !== 'agentPty' && c.type !== 'subagentChat')) return null;
  return <AgentStatusDotWithApi agentInstanceId={c.agentInstanceId} />;
}

function usePublishComments(ctx: AgentAuxContext) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const [send] = useSendConversationMessageMutation();
  return useCallback(
    async (markdown: string): Promise<boolean> => {
      const text = markdown.trim();
      if (!hasApiStore || !text || !ctx.agentInstanceId) return false;
      let body = text;
      const key = getActiveVaultKey();
      if (isVaultUnlocked && key) {
        try {
          body = await encryptVaultText(text, key);
        } catch {
          // Fall back to plaintext if encryption fails.
        }
      }
      await send({ conversationId: ctx.conversationId || ctx.agentInstanceId, body }).unwrap();
      return true;
    },
    [ctx.agentInstanceId, ctx.conversationId, hasApiStore, isVaultUnlocked, send],
  );
}

export interface AuxDockProps {
  treeId: AuxTreeId;
  /** false while sliding open / closed (the dock animates its width / transform). */
  shown?: boolean;
  /** Width of the fixed top-right window cluster the tab strip must not run under. */
  reserveRight?: number;
  /** Context agent: the focused Main pane's agent (owner of the shown strip). */
  ctx: AgentAuxContext;
  isMobile?: boolean;
}

/**
 * The ONE aux dock on the right of the workspace, showing the focused agent's
 * strip: a single tab strip (no splits),
 * the active tab's content (only the active tab is mounted), a `+` launcher and
 * a ⋮ menu with the active tab's actions. Resizable (width persisted) and
 * maximizable on desktop; a full-screen sheet on mobile.
 */
export function AuxDock({ treeId, ctx, isMobile = false, shown = true, reserveRight = 0 }: AuxDockProps) {
  const dispatch = useDispatch();
  const pane = useSelector((state: any) => selectAuxPane(state, treeId));
  const storedWidth = useSelector(selectAuxWidth);
  const isMaximized = useSelector(selectIsAuxMaximized);
  const treeKey = auxTreeKey(treeId);
  const publishComments = usePublishComments(ctx);
  const { actions, setActions } = useAuxTabActionsHost();

  const tabs = visibleAuxTabs(pane);
  const activeTab = resolveActiveAuxTab(pane);
  const activeTabId = activeTab?.id ?? NEW_TAB_ID;
  const hasChain = Boolean(ctx.chainId);

  const openTab = useCallback(
    (content: AuxContent, title?: string) => {
      const allowed = isAuxContentAllowed(content, {
        ownerAgentId: ctx.agentInstanceId,
        chainId: ctx.chainId,
        participantIds: ctx.participantIds,
      });
      if (!allowed) return;
      dispatch(openAuxTab({ treeId, content, title, hasChain }));
    },
    [ctx.agentInstanceId, ctx.chainId, ctx.participantIds, dispatch, hasChain, treeId],
  );

  const fullView = useCallback(
    (agentInstanceId: string) => {
      // Jetski "Full View": a navigation to the agent (its saved split group
      // focused on it if it has one, else its single view), never nesting.
      navigateToHash(buildConversationHash([agentInstanceId]));
    },
    [],
  );

  // ---- Desktop resize (left edge drag) ----
  const [dragWidth, setDragWidth] = useState<number | null>(null);
  const dockRef = useRef<HTMLDivElement | null>(null);
  const handleResizeStart = useCallback(
    (e: React.PointerEvent) => {
      e.preventDefault();
      const right = dockRef.current?.getBoundingClientRect().right ?? window.innerWidth;
      let latest = storedWidth ?? AUX_DEFAULT_WIDTH;
      const onMove = (ev: PointerEvent) => {
        latest = clampAuxWidth(right - ev.clientX);
        setDragWidth(latest);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        setDragWidth(null);
        dispatch(setAuxWidth(latest));
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    },
    [dispatch, storedWidth],
  );

  const closeDock = useCallback(
    () => dispatch(setAuxPaneOpen({ treeId, open: false })),
    [dispatch, treeId],
  );

  const menuContent = (
    <>
      {actions.map((a) => (
        <Menu.Item
          key={a.id}
          data-debug-id={`aux-menu-action-${a.id}`}
          disabled={a.disabled}
          danger={a.tone === 'danger'}
          onClick={a.onSelect}
        >
          {a.icon ? <Icon name={a.icon} size={15} /> : null}
          <span>{a.label}</span>
        </Menu.Item>
      ))}
      {activeTab?.content.type === 'subagentChat' ? (
        <Menu.Item
          data-debug-id="aux-menu-action-full-view"
          onClick={() => {
            if (activeTab.content.type === 'subagentChat') fullView(activeTab.content.agentInstanceId);
          }}
        >
          <Icon name="maximize" size={15} />
          <span>Full View</span>
        </Menu.Item>
      ) : null}
      {actions.length > 0 || activeTab?.content.type === 'subagentChat' ? <Menu.Separator /> : null}
      <Menu.Item
        data-debug-id="aux-menu-action-new-tab"
        onClick={() => dispatch(openAuxNewTab({ treeId, hasChain }))}
      >
        <Icon name="plus" size={15} />
        <span>New Tab</span>
      </Menu.Item>
      {activeTab ? (
        <Menu.Item
          data-debug-id="aux-menu-action-close-tab"
          onClick={() => dispatch(closeAuxTab({ treeId, tabId: activeTab.id }))}
        >
          <Icon name="close" size={15} />
          <span>Close Tab</span>
        </Menu.Item>
      ) : null}
    </>
  );

  const width = dragWidth ?? storedWidth ?? AUX_DEFAULT_WIDTH;
  const animating = dragWidth === null;
  const containerClass = isMobile
    ? `fixed inset-0 z-40 flex flex-col bg-canvas transition-transform duration-200 ease-out motion-reduce:transition-none ${
        shown ? 'translate-y-0' : 'translate-y-full'
      }`
    : isMaximized
      ? 'relative flex min-w-0 flex-1 flex-col bg-canvas'
      : `relative flex shrink-0 flex-col overflow-hidden bg-canvas ${shown ? 'border-l border-subtle' : ''} ${
          animating ? 'transition-[width] duration-200 ease-out motion-reduce:transition-none' : ''
        }`;

  return (
    <aside
      ref={dockRef}
      data-debug-id="aux-dock"
      data-aux-tree={treeKey}
      data-aux-mobile-sheet={isMobile ? 'true' : 'false'}
      data-aux-shown={shown ? 'true' : 'false'}
      aria-label="Side panel"
      className={containerClass}
      style={!isMobile && !isMaximized ? { width: shown ? width : 0, maxWidth: '75%' } : undefined}
    >
      {/* Fixed-width inner column so the content doesn't reflow while sliding. */}
      <div
        className="flex h-full min-h-0 flex-col"
        style={!isMobile && !isMaximized ? { width, minWidth: width } : { width: '100%' }}
      >
      {!isMobile && !isMaximized ? (
        <div
          data-debug-id="aux-resize-handle"
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize side panel"
          onPointerDown={handleResizeStart}
          onDoubleClick={() => dispatch(setAuxWidth(null))}
          className="absolute inset-y-0 left-0 z-20 w-1.5 cursor-col-resize hover:bg-accent/30"
        />
      ) : null}
      <AuxTabStrip
        treeKey={treeKey}
        tabs={tabs}
        activeTabId={activeTabId}
        isMobile={isMobile}
        isMaximized={isMaximized}
        reserveRight={isMobile ? 0 : reserveRight}
        onSelectTab={(tabId) => dispatch(setActiveAuxTab({ treeId, tabId }))}
        onCloseTab={(tabId) => dispatch(closeAuxTab({ treeId, tabId }))}
        onOpenNewTab={() => dispatch(openAuxNewTab({ treeId, hasChain }))}
        onMoveTab={(tabId, toIndex) => dispatch(moveAuxTab({ treeId, tabId, toIndex }))}
        onToggleMaximize={() => dispatch(toggleAuxMaximized())}
        onCloseDock={closeDock}
        menuContent={menuContent}
        renderTabStatus={(tab) => <AuxTabStatusDot tab={tab} />}
      />
      <div
        data-debug-id="aux-dock-body"
        className="relative flex min-h-0 w-full min-w-0 flex-1 flex-col overflow-hidden"
      >
        <AuxTabActionsProvider setActions={setActions}>
          {activeTab ? (
            // Jetski keep-alive parity: ONLY the active tab is mounted (key = tab id).
            <div
              key={activeTab.id}
              data-debug-id={`aux-tab-panel-${activeTab.id}`}
              className="flex h-full min-h-0 w-full min-w-0 flex-1 flex-col overflow-hidden"
            >
              <AuxTabContent
                tab={activeTab}
                ctx={ctx}
                isMobile={isMobile}
                onOpenTab={openTab}
                onUpdateTab={(tabId, patch) =>
                  dispatch(updateAuxTabContent({ treeId, tabId, patch: patch as any }))
                }
                onRekeyTab={(tabId, content, title) =>
                  dispatch(rekeyAuxTab({ treeId, tabId, content, title }))
                }
                onPublishComments={publishComments}
              />
            </div>
          ) : (
            <div
              key={NEW_TAB_ID}
              data-debug-id={`aux-tab-panel-${NEW_TAB_ID}`}
              className="flex h-full min-h-0 w-full min-w-0 flex-1 flex-col overflow-hidden"
            >
              <AuxNewTabLauncher
                treeKey={treeKey}
                ownerAgentId={ctx.agentInstanceId}
                chainId={ctx.chainId}
                projectId={ctx.projectId}
                bridgeId={ctx.bridgeId}
                projectVcsEnabled={ctx.projectVcsEnabled}
                members={ctx.members}
                onSelect={openTab}
              />
            </div>
          )}
        </AuxTabActionsProvider>
      </div>
      </div>
    </aside>
  );
}

export default AuxDock;
