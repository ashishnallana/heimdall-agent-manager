/**
 * Relinquish browser focus when it is still owned by a Main pane that is no
 * longer focused. Focus in the destination pane (or outside the Main
 * workspace, such as a modal) is intentionally preserved.
 */
export function blurInactiveMainPaneFocus(
  focusedPaneId: string,
  doc: Document = document,
): boolean {
  const activeElement = doc.activeElement;
  const ownerPane = activeElement?.closest<HTMLElement>('[data-main-pane-id]');
  if (!ownerPane || ownerPane.dataset.mainPaneId === focusedPaneId) return false;

  const blur = (activeElement as HTMLElement).blur;
  if (typeof blur !== 'function') return false;
  blur.call(activeElement);
  return true;
}
