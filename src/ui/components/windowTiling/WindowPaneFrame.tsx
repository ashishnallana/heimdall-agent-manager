import React, { useCallback, useState } from 'react';
import { useDispatch } from 'react-redux';
import { Icon } from '@ui';
import {
  moveWindowPane,
  NEW_WINDOW_PANE_ID,
  setWindowPendingDropTarget,
  swapWindowPanes,
  type WindowPaneValue,
} from '../../store/windowLayoutSlice';
import { resolvePaneTarget, type SplitDirection } from '../../tiling';

export const WINDOW_PANE_DRAG_MIME = 'application/x-heimdall-window-pane';

export interface WindowPaneFrameProps {
  paneId: string;
  paneValue: WindowPaneValue;
  title?: string;
  subtitle?: string;
  badgeText?: string;
  isFocused: boolean;
  isSinglePane: boolean;
  isMaximized: boolean;
  onFocus: (paneId: string) => void;
  onSplit: (paneId: string, direction: SplitDirection) => void;
  onMaximize: (paneId: string) => void;
  onClose: (paneId: string) => void;
  onStartDrag?: (paneId: string, event: React.DragEvent<HTMLElement>) => void;
  onResetToNewPicker?: (paneId: string) => void;
  headerActions?: React.ReactNode;
  children: React.ReactNode;
}

export function WindowPaneFrame({
  paneId,
  paneValue,
  title,
  subtitle,
  badgeText,
  isFocused,
  isSinglePane,
  isMaximized,
  onFocus,
  onSplit,
  onMaximize,
  onClose,
  onStartDrag,
  onResetToNewPicker,
  headerActions,
  children,
}: WindowPaneFrameProps) {
  const dispatch = useDispatch();
  const [isDraggingSelf, setIsDraggingSelf] = useState(false);

  const isNewPane =
    paneValue.kind === 'new' || paneValue.agentInstanceId === NEW_WINDOW_PANE_ID;
  const displayTitle =
    title?.trim() ||
    paneValue.title?.trim() ||
    (isNewPane ? 'New Conversation Pane' : paneValue.agentInstanceId || 'Conversation');

  const handleMouseDown = useCallback(() => {
    if (!isFocused) {
      onFocus(paneId);
    }
  }, [isFocused, onFocus, paneId]);

  const handleDragStart = useCallback(
    (event: React.DragEvent<HTMLElement>) => {
      if (isSinglePane) {
        event.preventDefault();
        return;
      }
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData(WINDOW_PANE_DRAG_MIME, paneId);
      event.dataTransfer.setData('text/plain', paneId);
      setIsDraggingSelf(true);
      onFocus(paneId);
      onStartDrag?.(paneId, event);

      const handleDragOver = (dragEvent: DragEvent) => {
        dragEvent.preventDefault();
        const target = resolvePaneTarget(
          dragEvent.clientX,
          dragEvent.clientY,
          '[data-window-pane-id]',
        );
        if (!target || target.paneId === paneId) {
          dispatch(setWindowPendingDropTarget(null));
          return;
        }
        dispatch(
          setWindowPendingDropTarget({
            paneId: target.paneId,
            direction: target.direction,
          }),
        );
      };

      const handleDrop = (dropEvent: DragEvent) => {
        dropEvent.preventDefault();
        const target = resolvePaneTarget(
          dropEvent.clientX,
          dropEvent.clientY,
          '[data-window-pane-id]',
        );
        dispatch(setWindowPendingDropTarget(null));
        if (target && target.paneId !== paneId) {
          if (dropEvent.altKey) {
            dispatch(
              swapWindowPanes({
                paneIdA: paneId,
                paneIdB: target.paneId,
              }),
            );
          } else {
            dispatch(
              moveWindowPane({
                sourcePaneId: paneId,
                targetPaneId: target.paneId,
                direction: target.direction,
              }),
            );
          }
        }
        cleanupWindowListeners();
      };

      const handleDragEnd = () => {
        setIsDraggingSelf(false);
        dispatch(setWindowPendingDropTarget(null));
        cleanupWindowListeners();
      };

      const cleanupWindowListeners = () => {
        window.removeEventListener('dragover', handleDragOver);
        window.removeEventListener('drop', handleDrop);
        window.removeEventListener('dragend', handleDragEnd);
      };

      window.addEventListener('dragover', handleDragOver);
      window.addEventListener('drop', handleDrop);
      window.addEventListener('dragend', handleDragEnd);
    },
    [dispatch, isSinglePane, onFocus, onStartDrag, paneId],
  );

  return (
    <section
      data-testid={`window-pane-frame-${paneId}`}
      data-debug-id={`window-pane-frame-${paneId}`}
      data-window-pane-focused={isFocused ? 'true' : 'false'}
      data-window-pane-single={isSinglePane ? 'true' : 'false'}
      onMouseDown={handleMouseDown}
      className={`flex h-full w-full min-w-0 min-h-0 flex-col overflow-hidden bg-canvas transition-colors ${
        !isSinglePane
          ? isFocused
            ? 'ring-1 ring-inset ring-accent/50'
            : 'ring-1 ring-inset ring-subtle/70'
          : ''
      } ${isDraggingSelf ? 'opacity-60' : ''}`}
    >
      {/* Window Pane Header Bar (hidden in single-pane conversation view so the chat header is the sole top bar, matching Jetski) */}
      <header
        draggable={!isSinglePane}
        onDragStart={handleDragStart}
        className={`${
          isSinglePane && !isNewPane ? 'hidden' : 'flex'
        } h-8 shrink-0 select-none items-center justify-between gap-2 border-b border-subtle px-2.5 text-xs transition-colors ${
          isFocused
            ? 'bg-surface-raised text-primary'
            : 'bg-surface text-muted'
        } ${!isSinglePane ? 'cursor-grab active:cursor-grabbing' : ''}`}
      >
        {/* Left: Active focus indicator + Conversation identity */}
        <div className="flex min-w-0 flex-1 items-center gap-2">
          <span
            className={`inline-flex h-2 w-2 shrink-0 rounded-full ${
              isFocused ? 'bg-accent' : 'bg-subtle'
            }`}
            aria-hidden="true"
          />
          <Icon
            name={isNewPane ? 'spark' : 'chat'}
            size={13}
            className={isNewPane ? 'shrink-0 text-accent' : 'shrink-0 text-muted'}
          />
          <span className="truncate font-medium" title={displayTitle}>
            {displayTitle}
          </span>
          {subtitle ? (
            <span className="hidden truncate text-[11px] text-muted sm:inline">
              · {subtitle}
            </span>
          ) : null}
          {badgeText ? (
            <span className="rounded bg-neutral-soft px-1.5 py-0.5 font-mono text-[10px] text-muted">
              {badgeText}
            </span>
          ) : null}
        </div>

        {/* Right: Window Split / Maximize / Close Controls */}
        <div
          className="flex shrink-0 items-center gap-0.5"
          onMouseDown={(e) => e.stopPropagation()}
        >
          {headerActions}
          {!isNewPane && onResetToNewPicker && !isSinglePane ? (
            <button
              type="button"
              onClick={() => onResetToNewPicker(paneId)}
              title="Switch conversation in this window pane"
              aria-label="Switch conversation in this window pane"
              data-testid={`window-pane-switch-conv-${paneId}`}
              className="grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="plus" size={12} />
            </button>
          ) : null}
          <button
            type="button"
            data-testid={`window-pane-split-right-${paneId}`}
            onClick={() => onSplit(paneId, 'right')}
            title="Split Window Right"
            aria-label="Split Window Right"
            className="grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="panel-right" size={12} />
          </button>
          <button
            type="button"
            data-testid={`window-pane-split-bottom-${paneId}`}
            onClick={() => onSplit(paneId, 'bottom')}
            title="Split Window Down"
            aria-label="Split Window Down"
            className="grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="chevron-down" size={12} />
          </button>
          <button
            type="button"
            data-testid={`window-pane-split-left-${paneId}`}
            onClick={() => onSplit(paneId, 'left')}
            title="Split Window Left"
            aria-label="Split Window Left"
            className="hidden sm:grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="chevron-left" size={12} />
          </button>
          <button
            type="button"
            data-testid={`window-pane-split-top-${paneId}`}
            onClick={() => onSplit(paneId, 'top')}
            title="Split Window Up"
            aria-label="Split Window Up"
            className="hidden sm:grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="chevron-up" size={12} />
          </button>
          {(!isSinglePane || isMaximized) ? (
            <button
              type="button"
              data-testid={`window-pane-maximize-${paneId}`}
              onClick={() => onMaximize(paneId)}
              title={isMaximized ? 'Restore Window Pane' : 'Maximize Window Pane'}
              aria-label={isMaximized ? 'Restore Window Pane' : 'Maximize Window Pane'}
              className="grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
            >
              <Icon
                name={isMaximized ? 'minimize' : 'maximize'}
                size={12}
                className={isMaximized ? 'text-accent' : ''}
              />
            </button>
          ) : null}
          {!isSinglePane ? (
            <button
              type="button"
              data-testid={`window-pane-close-${paneId}`}
              onClick={() => onClose(paneId)}
              title="Close Window Pane"
              aria-label="Close Window Pane"
              className="grid h-6 w-6 place-items-center rounded text-muted transition-colors hover:bg-danger-soft hover:text-danger"
            >
              <Icon name="close" size={12} />
            </button>
          ) : null}
        </div>
      </header>

      {/* Window Pane Content */}
      <div className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
        {children}
      </div>
    </section>
  );
}

export default WindowPaneFrame;
