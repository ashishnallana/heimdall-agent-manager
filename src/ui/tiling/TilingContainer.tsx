import * as React from 'react';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { calculatePaneLayouts } from './calculatePaneLayout';
import { PaneVisibilityProvider } from '../components/workbench/paneVisibility';
import { toStructureOnly } from './paneTreeState';
import {
  RenderPaneProps,
  SplitterLayout,
  TilingContainerProps,
} from './types';

export const TilingContainerContext = React.createContext<HTMLDivElement | null>(
  null,
);

interface PaneWrapperProps<T> {
  renderPane: (props: RenderPaneProps<T>) => React.ReactNode;
  paneId: string;
  value: T;
  isFocused: boolean;
  isMaximized: boolean;
  isSinglePane: boolean;
  isTopLeftMost: boolean;
  isTopRightMost: boolean;
}

const PaneWrapper = React.memo(function PaneWrapper<T>({
  renderPane,
  paneId,
  value,
  isFocused,
  isMaximized,
  isSinglePane,
  isTopLeftMost,
  isTopRightMost,
}: PaneWrapperProps<T>) {
  return (
    <>
      {renderPane({
        paneId,
        value,
        isFocused,
        isMaximized,
        isSinglePane,
        isTopLeftMost,
        isTopRightMost,
      })}
    </>
  );
}) as <T>(props: PaneWrapperProps<T>) => React.ReactElement;

function joinClasses(...classes: Array<string | false | null | undefined>): string {
  return classes.filter(Boolean).join(' ');
}

export function TilingContainer<T>({
  treeState,
  renderPane,
  renderSash,
  onResizePane,
  onFocusPane,
  paneDividers = true,
  className,
  paneAttributeName,
}: TilingContainerProps<T>): React.ReactElement {
  const structureOnlyState = useMemo(
    () => toStructureOnly(treeState),
    [treeState.rootPaneId, treeState.panes, treeState.maximizedPaneId],
  );
  const { contentLayouts, splitterLayouts } = useMemo(() => {
    return calculatePaneLayouts(structureOnlyState);
  }, [structureOnlyState]);

  const [containerEl, setContainerEl] = useState<HTMLDivElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const handleRef = useCallback((el: HTMLDivElement | null) => {
    containerRef.current = el;
    setContainerEl(el);
  }, []);
  const [activeSplitter, setActiveSplitter] = useState<SplitterLayout | null>(
    null,
  );

  const onResizeRef = useRef(onResizePane);
  onResizeRef.current = onResizePane;

  useEffect(() => {
    let animationFrameId: number | null = null;

    const handleMouseMove = (e: MouseEvent) => {
      if (!activeSplitter || !containerRef.current) return;
      if (e.isTrusted && e.buttons === 0) {
        setActiveSplitter(null);
        return;
      }

      const clientX = e.clientX;
      const clientY = e.clientY;

      const applyResize = () => {
        animationFrameId = null;
        if (!containerRef.current) return;
        const containerRect = containerRef.current.getBoundingClientRect();
        const width = containerRect.width || 1;
        const height = containerRect.height || 1;
        const x = clientX - containerRect.left;
        const y = clientY - containerRect.top;

        const splitPaneBounds = activeSplitter.splitPaneBounds;

        const xPct = (x / width) * 100;
        const yPct = (y / height) * 100;

        let newRatio = 50;
        if (activeSplitter.axis === 'vertical') {
          const localY = yPct - splitPaneBounds.top;
          newRatio = (localY / (splitPaneBounds.height || 100)) * 100;
        } else {
          const localX = xPct - splitPaneBounds.left;
          newRatio = (localX / (splitPaneBounds.width || 100)) * 100;
        }

        newRatio = Math.max(5, Math.min(95, newRatio));

        if (onResizeRef.current) {
          onResizeRef.current(activeSplitter.paneId, newRatio);
        }
      };

      if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
        if (animationFrameId !== null) {
          return;
        }
        animationFrameId = window.requestAnimationFrame(applyResize);
      } else {
        applyResize();
      }
    };

    const handleMouseUp = () => {
      setActiveSplitter(null);
    };

    const originalPointerEvents = new Map<HTMLElement, string>();
    if (activeSplitter && typeof document !== 'undefined') {
      const embeddedFrames: HTMLElement[] = [];
      document
        .querySelectorAll<HTMLElement>('iframe, webview')
        .forEach((frame) => {
          embeddedFrames.push(frame);
          if (frame.parentElement) {
            embeddedFrames.push(frame.parentElement);
          }
          const shadowIframe =
            frame.shadowRoot?.querySelector<HTMLElement>('iframe');
          if (shadowIframe) {
            embeddedFrames.push(shadowIframe);
          }
        });
      embeddedFrames.forEach((frame) => {
        if (!originalPointerEvents.has(frame)) {
          originalPointerEvents.set(frame, frame.style.pointerEvents);
        }
        frame.style.pointerEvents = 'none';
      });
      if (typeof window !== 'undefined') {
        window.addEventListener('mousemove', handleMouseMove);
        window.addEventListener('mouseup', handleMouseUp);
      }
    }

    return () => {
      originalPointerEvents.forEach((prevPointerEvents, frame) => {
        frame.style.pointerEvents = prevPointerEvents || '';
      });
      if (typeof window !== 'undefined') {
        window.removeEventListener('mousemove', handleMouseMove);
        window.removeEventListener('mouseup', handleMouseUp);
        if (
          animationFrameId !== null &&
          typeof window.cancelAnimationFrame === 'function'
        ) {
          window.cancelAnimationFrame(animationFrameId);
        }
      }
    };
  }, [activeSplitter]);

  const isSinglePane = contentLayouts.length <= 1;
  const activeMaximizedPaneId =
    !isSinglePane &&
    treeState.maximizedPaneId &&
    treeState.panes[treeState.maximizedPaneId]?.kind === 'content'
      ? treeState.maximizedPaneId
      : null;

  return (
    <div
      ref={handleRef}
      className={joinClasses('relative h-full w-full overflow-hidden', className)}
    >
      <TilingContainerContext.Provider value={containerEl}>
        {contentLayouts.map((layout) => {
          const pane = treeState.panes[layout.paneId];
          if (!pane || pane.kind !== 'content') {
            return null;
          }
          const isFocused = treeState.focusedPaneId === layout.paneId;
          const isMaximized = activeMaximizedPaneId === layout.paneId;
          const isHiddenByMaximize =
            activeMaximizedPaneId !== null && !isMaximized;

          const extraPaneAttrs =
            paneAttributeName && paneAttributeName !== 'data-pane-id'
              ? { [paneAttributeName]: layout.paneId }
              : undefined;

          return (
            <div
              key={layout.paneId}
              data-pane-id={layout.paneId}
              data-pane-focused={isFocused ? 'true' : 'false'}
              data-pane-maximized={isMaximized ? 'true' : 'false'}
              {...extraPaneAttrs}
              onMouseDown={() => {
                if (onFocusPane && !isFocused) {
                  onFocusPane(layout.paneId);
                }
              }}
              className={joinClasses(
                paneDividers && !isMaximized && 'border-slate-800/80',
                paneDividers &&
                  !isMaximized &&
                  !layout.isRightmostOfRow &&
                  'border-r',
                paneDividers &&
                  !isMaximized &&
                  !layout.isBottommostOfColumn &&
                  'border-b',
              )}
              style={{
                position: 'absolute',
                top: isMaximized ? '0%' : `${layout.top}%`,
                left: isMaximized ? '0%' : `${layout.left}%`,
                width: isMaximized ? '100%' : `${layout.width}%`,
                height: isMaximized ? '100%' : `${layout.height}%`,
                zIndex: isMaximized ? 20 : undefined,
                visibility: isHiddenByMaximize ? 'hidden' : undefined,
                pointerEvents: isHiddenByMaximize ? 'none' : undefined,
                overflow: 'hidden',
              }}
            >
              <PaneVisibilityProvider visible={!isHiddenByMaximize}>
              <PaneWrapper
                renderPane={renderPane}
                paneId={layout.paneId}
                value={pane.value}
                isFocused={isFocused}
                isMaximized={isMaximized}
                isSinglePane={isSinglePane}
                isTopLeftMost={layout.top === 0 && layout.left === 0}
                isTopRightMost={layout.top === 0 && layout.isRightmostOfRow}
              />
              </PaneVisibilityProvider>
            </div>
          );
        })}
      </TilingContainerContext.Provider>
      {!activeMaximizedPaneId &&
        splitterLayouts.map((splitter) => (
          <div
            key={splitter.paneId}
            data-splitter-id={splitter.paneId}
            data-splitter-axis={splitter.axis}
            className={joinClasses(
              'absolute z-10 flex items-center justify-center group select-none',
              splitter.axis === 'vertical'
                ? 'cursor-row-resize'
                : 'cursor-col-resize',
            )}
            style={{
              top: `${splitter.top}%`,
              left: `${splitter.left}%`,
              width: `${splitter.width}%`,
              height: `${splitter.height}%`,
            }}
            onMouseDown={(e) => {
              e.preventDefault();
              setActiveSplitter(splitter);
            }}
          >
            {renderSash ? (
              renderSash({ axis: splitter.axis })
            ) : (
              <div
                className={joinClasses(
                  'transition-colors bg-transparent group-hover:bg-sky-500/40',
                  splitter.axis === 'vertical'
                    ? 'w-full h-1'
                    : 'h-full w-1',
                )}
              />
            )}
          </div>
        ))}
    </div>
  );
}
