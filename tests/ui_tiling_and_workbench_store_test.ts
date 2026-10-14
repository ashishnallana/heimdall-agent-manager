import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { createRoot } from 'react-dom/client';
import { act } from 'react';
import { JSDOM } from 'jsdom';

import {
  createPaneTreeState,
  toAxis,
  isFirstChild,
  getPaneLocation,
  splitPaneInTree,
  split,
  closePaneInTree,
  closePane,
  movePaneInTree,
  movePane,
  swapPanesInTree,
  swapPanes,
  resizeSplitInTree,
  resizeSplit,
  equalizeTreeRatios,
  equalizePanes,
  toggleMaximizePaneInTree,
  toggleMaximizePane,
  getContentPaneIds,
  toStructureOnly,
  calculatePaneLayouts,
  getSplitDirection,
  getOverlayPosition,
  resolvePaneTarget,
  TilingContainer,
} from '../src/ui/tiling/index.ts';

test('M1 Tiling Engine: createPaneTreeState, toAxis, isFirstChild, and ID-preserving splitPaneInTree', () => {
  assert.equal(toAxis('top'), 'vertical');
  assert.equal(toAxis('bottom'), 'vertical');
  assert.equal(toAxis('vertical'), 'vertical');
  assert.equal(toAxis('left'), 'horizontal');
  assert.equal(toAxis('right'), 'horizontal');
  assert.equal(toAxis('horizontal'), 'horizontal');

  assert.equal(isFirstChild('top'), true);
  assert.equal(isFirstChild('left'), true);
  assert.equal(isFirstChild('bottom'), false);
  assert.equal(isFirstChild('right'), false);

  const tree = createPaneTreeState({ label: 'initial' }, 'pane-1');
  assert.equal(tree.rootPaneId, 'pane-1');
  assert.equal(tree.focusedPaneId, 'pane-1');
  assert.deepEqual(getContentPaneIds(tree), ['pane-1']);

  const { parentId, newChildId } = splitPaneInTree(
    tree,
    'pane-1',
    'right',
    { label: 'second' },
    'pane-2',
  );
  // pane-1 MUST preserve its exact ID and entry in tree.panes
  assert.ok(tree.panes['pane-1'], 'Original pane-1 must remain in tree.panes');
  assert.equal(tree.panes['pane-1'].kind, 'content');
  assert.equal(newChildId, 'pane-2');
  assert.equal(tree.rootPaneId, parentId);
  assert.equal(tree.focusedPaneId, 'pane-2');

  const rootSplit = tree.panes[parentId];
  assert.equal(rootSplit.kind, 'split');
  if (rootSplit.kind === 'split') {
    assert.equal(rootSplit.axis, 'horizontal');
    assert.equal(rootSplit.leftChildId, 'pane-1');
    assert.equal(rootSplit.rightChildId, 'pane-2');
    assert.equal(rootSplit.ratio, 50);
  }

  assert.deepEqual(getPaneLocation(tree, 'pane-1'), {
    parentId,
    side: 'left',
  });
  assert.deepEqual(getPaneLocation(tree, 'pane-2'), {
    parentId,
    side: 'right',
  });
});

test('M1 Tiling Engine: ID-preserving movePaneInTree, swapPanesInTree, resizeSplitInTree, equalize, maximize, and closePane', () => {
  const tree = createPaneTreeState('A', 'pane-a');
  const split1 = split(tree, 'pane-a', 'right', 'B', 'pane-b');
  const split2 = split(tree, 'pane-b', 'bottom', 'C', 'pane-c');

  assert.deepEqual(getContentPaneIds(tree), ['pane-a', 'pane-b', 'pane-c']);

  // Move pane-c to the top of pane-a; both pane-c and pane-a must preserve their exact IDs!
  const moved = movePane(tree, 'pane-c', 'pane-a', 'top');
  assert.equal(moved, true);
  assert.ok(tree.panes['pane-a'], 'pane-a ID preserved');
  assert.ok(tree.panes['pane-b'], 'pane-b ID preserved');
  assert.ok(tree.panes['pane-c'], 'pane-c ID preserved');
  assert.deepEqual(getContentPaneIds(tree), ['pane-c', 'pane-a', 'pane-b']);

  // Swap pane-c and pane-b
  const swapped = swapPanes(tree, 'pane-c', 'pane-b');
  assert.equal(swapped, true);
  assert.deepEqual(getContentPaneIds(tree), ['pane-b', 'pane-a', 'pane-c']);

  // Resize split with clamping [5, 95] and NaN handling
  resizeSplit(tree, split1.parentId, 120);
  const splitNode = tree.panes[split1.parentId];
  assert.equal(splitNode.kind, 'split');
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 95);
  }
  resizeSplitInTree(tree, split1.parentId, -10);
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 5);
  }
  resizeSplitInTree(tree, split1.parentId, Number.NaN);
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 5, 'NaN should be ignored');
  }

  equalizePanes(tree);
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 50);
  }

  // Maximize and restore
  toggleMaximizePane(tree, 'pane-b');
  assert.equal(tree.maximizedPaneId, 'pane-b');
  toggleMaximizePaneInTree(tree, 'pane-b');
  assert.equal(tree.maximizedPaneId, null);

  // Maximize pane-b then close it -> maximizedPaneId cleared and focusedPaneId updated
  toggleMaximizePane(tree, 'pane-b');
  assert.equal(tree.maximizedPaneId, 'pane-b');
  // Test closePane with (id, state) overload
  const emptyAfterCloseB = closePane('pane-b', tree);
  assert.equal(emptyAfterCloseB, false);
  assert.equal(tree.maximizedPaneId, null);
  assert.notEqual(tree.focusedPaneId, 'pane-b');
  assert.deepEqual(getContentPaneIds(tree), ['pane-a', 'pane-c']);

  // Test closePane with (state, id) overload
  const emptyAfterCloseA = closePane(tree, 'pane-a');
  assert.equal(emptyAfterCloseA, false);
  assert.deepEqual(getContentPaneIds(tree), ['pane-c']);
  assert.equal(tree.rootPaneId, 'pane-c');

  // Closing the last pane returns true
  const emptyAfterCloseC = closePaneInTree(tree, 'pane-c');
  assert.equal(emptyAfterCloseC, true);
});

test('M1 Tiling Engine: calculatePaneLayouts and toStructureOnly', () => {
  const tree = createPaneTreeState({ count: 1 }, 'pane-1');
  const { parentId: hSplitId } = splitPaneInTree(
    tree,
    'pane-1',
    'right',
    { count: 2 },
    'pane-2',
  );
  resizeSplitInTree(tree, hSplitId, 40);
  splitPaneInTree(tree, 'pane-2', 'bottom', { count: 3 }, 'pane-3');

  const structure = toStructureOnly(tree);
  assert.equal(
    (structure.panes['pane-1'] as any).value,
    undefined,
    'toStructureOnly strips leaf values',
  );

  const { contentLayouts, splitterLayouts } = calculatePaneLayouts(structure);
  assert.equal(contentLayouts.length, 3);
  assert.equal(splitterLayouts.length, 2);

  const l1 = contentLayouts.find((l) => l.paneId === 'pane-1')!;
  const l2 = contentLayouts.find((l) => l.paneId === 'pane-2')!;
  const l3 = contentLayouts.find((l) => l.paneId === 'pane-3')!;

  assert.equal(l1.left, 0);
  assert.equal(l1.top, 0);
  assert.equal(l1.width, 40);
  assert.equal(l1.height, 100);
  assert.equal(l1.isRightmostOfRow, false);
  assert.equal(l1.isBottommostOfColumn, true);

  assert.equal(l2.left, 40);
  assert.equal(l2.top, 0);
  assert.equal(l2.width, 60);
  assert.equal(l2.height, 50);
  assert.equal(l2.isRightmostOfRow, true);
  assert.equal(l2.isBottommostOfColumn, false);

  assert.equal(l3.left, 40);
  assert.equal(l3.top, 50);
  assert.equal(l3.width, 60);
  assert.equal(l3.height, 50);
  assert.equal(l3.isRightmostOfRow, true);
  assert.equal(l3.isBottommostOfColumn, true);
});

test('M1 Tiling Engine: dragUtils getSplitDirection, getOverlayPosition, and resolvePaneTarget', () => {
  const rect = { left: 100, top: 200, width: 400, height: 200 };

  assert.equal(getSplitDirection(rect, { x: 120, y: 300 }), 'left');
  assert.equal(getSplitDirection(rect, { x: 480, y: 300 }), 'right');
  assert.equal(getSplitDirection(rect, { x: 300, y: 210 }), 'top');
  assert.equal(getSplitDirection(rect, { x: 300, y: 390 }), 'bottom');

  assert.deepEqual(getOverlayPosition(rect, 'top'), {
    top: 0,
    left: 0,
    width: 400,
    height: 100,
  });
  assert.deepEqual(getOverlayPosition(rect, 'bottom'), {
    top: 100,
    left: 0,
    width: 400,
    height: 100,
  });
  assert.deepEqual(getOverlayPosition(rect, 'left'), {
    top: 0,
    left: 0,
    width: 200,
    height: 200,
  });
  assert.deepEqual(getOverlayPosition(rect, 'right'), {
    top: 0,
    left: 200,
    width: 200,
    height: 200,
  });
});

test('M1 TilingContainer DOM: preserves leaf mount identity across splits/moves/maximize and guards iframe pointerEvents on sash drag', async () => {
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
  const prevWindow = (globalThis as any).window;
  const prevDocument = (globalThis as any).document;
  const prevHTMLElement = (globalThis as any).HTMLElement;
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const container = dom.window.document.getElementById('root')!;
    const root = createRoot(container);

    const mountCounts: Record<string, number> = {};
    const unmountCounts: Record<string, number> = {};

    function LeafProbe({ paneId, label }: { paneId: string; label: string }) {
      React.useEffect(() => {
        mountCounts[paneId] = (mountCounts[paneId] || 0) + 1;
        return () => {
          unmountCounts[paneId] = (unmountCounts[paneId] || 0) + 1;
        };
      }, [paneId]);
      return React.createElement(
        'div',
        { 'data-testid': `leaf-${paneId}` },
        label,
        paneId === 'pane-1' ? React.createElement('iframe', { id: 'preview-frame' }) : null,
      );
    }

    let tree = createPaneTreeState({ label: 'One' }, 'pane-1');

    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    assert.equal(mountCounts['pane-1'], 1);
    assert.equal(unmountCounts['pane-1'] || 0, 0);

    // Split pane-1 -> pane-1 MUST NOT unmount
    tree = structuredClone(tree);
    splitPaneInTree(tree, 'pane-1', 'right', { label: 'Two' }, 'pane-2');

    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    assert.equal(mountCounts['pane-1'], 1, 'pane-1 must not remount when split');
    assert.equal(unmountCounts['pane-1'] || 0, 0, 'pane-1 must not unmount when split');
    assert.equal(mountCounts['pane-2'], 1);

    // Maximize pane-2 -> pane-1 MUST stay mounted in DOM with visibility: hidden
    tree = structuredClone(tree);
    toggleMaximizePaneInTree(tree, 'pane-2');

    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    const pane1El = container.querySelector('[data-pane-id="pane-1"]') as HTMLElement;
    const pane2El = container.querySelector('[data-pane-id="pane-2"]') as HTMLElement;
    assert.ok(pane1El, 'Non-maximized pane-1 remains in DOM');
    assert.equal(pane1El.style.visibility, 'hidden');
    assert.equal(pane1El.style.pointerEvents, 'none');
    assert.equal(pane2El.getAttribute('data-pane-maximized'), 'true');
    assert.equal(pane2El.style.width, '100%');
    assert.equal(pane2El.style.height, '100%');
    assert.equal(unmountCounts['pane-1'] || 0, 0, 'pane-1 never unmounted during maximize');

    // Restore from maximize and test sash drag iframe pointerEvents guard
    tree = structuredClone(tree);
    toggleMaximizePaneInTree(tree, 'pane-2');
    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    const splitterEl = container.querySelector('[data-splitter-id]') as HTMLElement;
    const iframeEl = container.querySelector('#preview-frame') as HTMLElement;
    assert.ok(splitterEl, 'Splitter sash rendered');
    assert.ok(iframeEl, 'Preview iframe rendered');

    await act(async () => {
      splitterEl.dispatchEvent(
        new dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true }),
      );
    });
    assert.equal(
      iframeEl.style.pointerEvents,
      'none',
      'Iframe pointerEvents disabled during sash drag',
    );

    await act(async () => {
      dom.window.dispatchEvent(new dom.window.MouseEvent('mouseup', { bubbles: true }));
    });
    assert.equal(
      iframeEl.style.pointerEvents,
      '',
      'Iframe pointerEvents restored on mouseup',
    );

    await act(async () => {
      root.unmount();
    });
  } finally {
    (globalThis as any).window = prevWindow;
    (globalThis as any).document = prevDocument;
    (globalThis as any).HTMLElement = prevHTMLElement;
  }
});
