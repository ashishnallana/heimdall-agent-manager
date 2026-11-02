import type { PaneTreeState } from '../tiling';
import type { MainPaneValue } from '../store/workspaceLayoutSlice';
import { leafAgentIds, getLayoutStorageKey, SPLIT_GROUP_INDEX_STORAGE_KEY, computeUpdatedGroups, readGroupIndex } from '../store/splitGroups';
import { writeClientStorageChecked, AUX_PANES_STORAGE_KEY, WORKSPACE_CHROME_STORAGE_KEY } from './clientPersistence';

/** Flush the same keys used by normal workspace hydration, observing failures. */
export function flushWorkspaceForDesktopUpdate(tree: PaneTreeState<MainPaneValue>, auxPanes: unknown, auxWidth: number | null) {
  const ids = leafAgentIds(tree);
  writeClientStorageChecked(getLayoutStorageKey(ids), JSON.stringify(tree));
  writeClientStorageChecked(SPLIT_GROUP_INDEX_STORAGE_KEY, JSON.stringify(computeUpdatedGroups(readGroupIndex(), ids)));
  writeClientStorageChecked(AUX_PANES_STORAGE_KEY, JSON.stringify(auxPanes));
  writeClientStorageChecked(WORKSPACE_CHROME_STORAGE_KEY, JSON.stringify({ auxWidth }));
}
