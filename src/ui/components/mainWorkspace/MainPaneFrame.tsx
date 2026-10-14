import React, { useCallback, useState } from 'react';
import { useDispatch } from 'react-redux';
import { Icon } from '@ui';
import { resolvePaneTarget } from '../../tiling';
import { moveMainPane, swapMainPanes } from '../../store/workspaceLayoutSlice';
import { setPendingSplitDrop } from '../../store/workspaceChromeSlice';

export const MAIN_PANE_DRAG_MIME = 'application/x-heimdall-main-pane';
export const MAIN_PANE_SELECTOR = '[data-main-pane-id]';

export interface MainPaneFrameProps {
  paneId: string;
  isFocused: boolean;
  isSinglePane: boolean;
  isPicker: boolean;
  isMobile?: boolean;
  onFocus: (paneId: string) => void;
  onClose: (paneId: string) => void;
  /** Plays the close animation (the pane is removed right after). */
  isClosing?: boolean;
  /** Picker header: hidden-sidebar control (top-left pane). */
  headerLeading?: React.ReactNode;
  /** Picker header: update badge + side-panel toggle (top-right pane). */
  headerTrailing?: React.ReactNode;
  children: React.ReactNode;
}

/**
 * Chrome-light frame around a Main leaf. The chat header is the pane's only
 * top bar; in split view a slim drag grip lets the pane be dragged onto another
 * pane to split it (Alt+drop swaps). A picker pane gets a small title row with
 * close.
 */
export function MainPaneFrame({
  paneId,
  isFocused,
  isSinglePane,
  isPicker,
  isMobile = false,
  onFocus,
  onClose,
  headerLeading,
  headerTrailing,
  isClosing = false,
  children,
}: MainPaneFrameProps) {
  const dispatch = useDispatch();
  const [isDragging, setIsDragging] = useState(false);

  const handleDragStart = useCallback(
    (event: React.DragEvent<HTMLElement>) => {
      if (isSinglePane) {
        event.preventDefault();
        return;
      }
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData(MAIN_PANE_DRAG_MIME, paneId);
      event.dataTransfer.setData('text/plain', paneId);
      setIsDragging(true);
      onFocus(paneId);

      const cleanup = () => {
        window.removeEventListener('dragover', onDragOver);
        window.removeEventListener('drop', onDrop);
        window.removeEventListener('dragend', onDragEnd);
      };
      const onDragOver = (e: DragEvent) => {
        e.preventDefault();
        const target = resolvePaneTarget(e.clientX, e.clientY, MAIN_PANE_SELECTOR);
        dispatch(
          setPendingSplitDrop(
            target && target.paneId !== paneId
              ? { paneId: target.paneId, direction: target.direction }
              : null,
          ),
        );
      };
      const onDrop = (e: DragEvent) => {
        e.preventDefault();
        const target = resolvePaneTarget(e.clientX, e.clientY, MAIN_PANE_SELECTOR);
        dispatch(setPendingSplitDrop(null));
        if (target && target.paneId !== paneId) {
          dispatch(
            e.altKey
              ? swapMainPanes({ paneIdA: paneId, paneIdB: target.paneId })
              : moveMainPane({ sourcePaneId: paneId, targetPaneId: target.paneId, direction: target.direction }),
          );
        }
        cleanup();
      };
      const onDragEnd = () => {
        setIsDragging(false);
        dispatch(setPendingSplitDrop(null));
        cleanup();
      };
      window.addEventListener('dragover', onDragOver);
      window.addEventListener('drop', onDrop);
      window.addEventListener('dragend', onDragEnd);
    },
    [dispatch, isSinglePane, onFocus, paneId],
  );

  return (
    <section
      data-debug-id={`main-pane-frame-${paneId}`}
      data-main-pane-focused={isFocused ? 'true' : 'false'}
      onMouseDownCapture={() => {
        if (!isFocused) onFocus(paneId);
      }}
      data-main-pane-closing={isClosing ? 'true' : undefined}
      className={`relative flex h-full w-full min-h-0 min-w-0 flex-col overflow-hidden bg-canvas ${
        isClosing ? 'heimdall-pane-exit' : 'heimdall-pane-enter'
      } ${
        !isSinglePane && !isMobile
          ? isFocused
            ? 'ring-1 ring-inset ring-accent/50'
            : 'ring-1 ring-inset ring-subtle/70'
          : ''
      } ${isDragging ? 'opacity-60' : ''}`}
    >
      {!isSinglePane && !isMobile && !isPicker ? (
        <div
          draggable
          onDragStart={handleDragStart}
          data-debug-id={`main-pane-drag-grip-${paneId}`}
          title="Drag onto another pane to split (Alt+drop swaps)"
          aria-label="Drag pane"
          className="absolute left-1/2 top-0 z-30 h-2 w-12 -translate-x-1/2 cursor-grab rounded-b-md bg-subtle/60 hover:bg-accent/60 active:cursor-grabbing"
        />
      ) : null}
      {isPicker ? (
        <header
          draggable={!isSinglePane && !isMobile}
          onDragStart={handleDragStart}
          className="flex h-12 shrink-0 select-none items-center justify-between gap-2 border-b border-subtle bg-surface px-3 text-xs text-muted"
        >
          <span className="flex min-w-0 items-center gap-1.5 font-medium">
            {headerLeading}
            <Icon name="plus" size={13} className="text-accent" />
            New conversation
          </span>
          <span className="flex shrink-0 items-center gap-1">
          {!isSinglePane ? (
            <button
              type="button"
              data-debug-id={`main-pane-close-${paneId}`}
              aria-label="Close pane"
              title="Close pane"
              onClick={() => onClose(paneId)}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="close" size={12} />
            </button>
          ) : null}
          {headerTrailing}
          </span>
        </header>
      ) : null}
      <div className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">{children}</div>
    </section>
  );
}

export default MainPaneFrame;
