// REQ-BAR: global bottom status bar — slot framework wiring and v1 count rules.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  countConnectedBridges,
  countRunningInstances,
  countShells,
  formatCount,
  isPreviewSession,
} from '../src/ui/components/shell/statusBar/statusBarModel.ts';
import { STATUS_BAR_MODULES } from '../src/ui/components/shell/statusBar/modules.tsx';
import { renderSlot } from '../src/ui/components/shell/statusBar/StatusBar.tsx';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const shellSource = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
const barSource = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/statusBar/StatusBar.tsx'), 'utf8');

const agent = (id: string, runtimeStatus: string) => ({ agentInstanceId: id, displayName: '', runtimeStatus } as any);

test('REQ-BAR-2: running instances are live agents, de-duplicated across projects', () => {
  const projects: any[] = [
    { projectId: 'p1', name: 'A', chains: [{ chainId: 'c1', liveAgents: [agent('i1', 'running'), agent('i2', 'idle'), agent('i3', 'stopped')], members: [] }] },
    // A cross-project chain can surface the same instance again.
    { projectId: 'p2', name: 'B', chains: [{ chainId: 'c2', liveAgents: [agent('i1', 'running'), agent('i4', 'starting')], members: [] }] },
  ];
  assert.equal(countRunningInstances(projects), 3);
  assert.equal(countRunningInstances([]), 0);
  assert.equal(countRunningInstances(undefined), 0);
});

test('REQ-BAR-2: connected bridges must be online with a connected runtime and not revoked', () => {
  assert.equal(countConnectedBridges([
    { bridge_id: 'b1', status: 'online', runtime_connected: true },
    { bridge_id: 'b2', status: 'online', runtime_connected: false },
    { bridge_id: 'b3', status: 'offline', runtime_connected: true },
    { bridge_id: 'b4', status: 'revoked', runtime_connected: true },
  ]), 1);
  assert.equal(countConnectedBridges(null), 0);
});

test('REQ-BAR-2: previews are live server sessions with a port; a full page is capped', () => {
  const sessions: any[] = [
    { session_id: 's1', kind: 'server', server_port: 5173 },
    { session_id: 's2', kind: 'server', server_port: 0 },
    { session_id: 's3', kind: 'run' },
  ];
  assert.equal(isPreviewSession(sessions[0]), true);
  assert.equal(isPreviewSession(sessions[1]), false);
  assert.deepEqual(countShells(sessions), { shells: 3, previews: 1, capped: false });
  assert.deepEqual(countShells(sessions, true), { shells: 3, previews: 1, capped: true });
  assert.equal(formatCount(200, true), '200+');
  assert.equal(formatCount(4), '4');
});

test('REQ-BAR-1/4: the shell is a column with the in-flow bar after the app row', () => {
  assert.match(shellSource, /data-debug-id="app-shell"\s+className="fixed inset-x-0 top-0 app-viewport-height flex w-full max-w-full flex-col/);
  assert.match(shellSource, /data-debug-id="app-shell-row" className="relative flex min-h-0 w-full flex-1 overflow-hidden"/);
  assert.match(shellSource, /<StatusBar\s+modules=\{STATUS_BAR_MODULES\}\s+compact=\{isMobile\}/);
  // In-flow, never fixed to the layout viewport bottom (REQ-KBD-2), and it
  // publishes its height so fixed mobile action bars clear it.
  assert.doesNotMatch(barSource, /fixed bottom-0|inset-0/);
  assert.match(barSource, /useBottomChromeVar\(ref\)/);
  assert.match(barSource, /grid-cols-\[1fr_auto_1fr\]/);
});

const data = {
  runningInstances: 1,
  connectedBridges: 2,
  shells: { shells: 5, previews: 2, capped: false },
  shortcutMode: 'normal' as const,
  renderVaultToggle: (compact: boolean) => `vault:${compact}`,
};

test('BAR-2: registry modules declare slot + order and render per compact context', () => {
  const ids = STATUS_BAR_MODULES.map((m) => m.id);
  assert.deepEqual([...ids].sort(), ['bridges', 'instances', 'previews', 'shells', 'shortcut-mode', 'vault']);
  assert.equal(new Set(ids).size, ids.length, 'module ids are unique');
  const left = renderSlot(STATUS_BAR_MODULES, 'left', { compact: false, data });
  const right = renderSlot(STATUS_BAR_MODULES, 'right', { compact: false, data });
  assert.deepEqual(left.map((e) => e.id), ['shortcut-mode', 'bridges']);
  assert.deepEqual(right.map((e) => e.id), ['instances', 'shells', 'previews', 'vault']);
  assert.deepEqual(renderSlot(STATUS_BAR_MODULES, 'center', { compact: false, data }), []);
  // Every module is told whether it is compact.
  assert.equal(right[3].node, 'vault:false');
  assert.equal(renderSlot(STATUS_BAR_MODULES, 'right', { compact: true, data })[3].node, 'vault:true');
  const count = right[1].node as any;
  assert.equal(count.props.compact, false);
  assert.equal(count.props.value, '5');
  assert.equal((renderSlot(STATUS_BAR_MODULES, 'right', { compact: true, data })[1].node as any).props.compact, true);
});

test('REQ-SHORTCUT-MODE-8 / REQ-SB-1: mode module shows NOR/INS on every viewport as plain colored text', () => {
  const renderMode = (shortcutMode: 'normal' | 'insert', compact: boolean) => (
    renderSlot(STATUS_BAR_MODULES, 'left', { compact, data: { ...data, shortcutMode } })[0].node as any
  );

  const normal = renderMode('normal', false);
  const insert = renderMode('insert', false);
  const compactNormal = renderMode('normal', true);
  const compactInsert = renderMode('insert', true);

  assert.equal(normal.props.children, 'NOR');
  assert.equal(insert.props.children, 'INS');
  assert.equal(compactNormal.props.children, 'NOR');
  assert.equal(compactInsert.props.children, 'INS');
  assert.equal(normal.props.role, 'status');
  assert.equal(normal.props['aria-label'], 'Shortcut mode: Normal');
  assert.equal(insert.props['aria-label'], 'Shortcut mode: Insert');
  assert.equal(normal.props['data-mode'], 'normal');
  assert.equal(insert.props['data-mode'], 'insert');
  assert.match(normal.props.className, /\btext-info\b/);
  assert.match(insert.props.className, /\btext-accent\b/);
  for (const node of [normal, insert, compactNormal, compactInsert]) {
    assert.doesNotMatch(node.props.className, /\b(bg-|border|rounded)/);
  }
  assert.notEqual(normal.props.className, insert.props.className);
});

test('BAR-2: adding a module is one definition; order sorts, null hides', () => {
  const extra = [
    { id: 'ctx-b', slot: 'center' as const, order: 20, render: () => 'b' },
    { id: 'ctx-a', slot: 'center' as const, order: 10, render: () => 'a' },
    { id: 'ctx-hidden', slot: 'center' as const, order: 5, render: ({ compact }: { compact: boolean }) => (compact ? null : 'wide-only') },
  ];
  const all = [...STATUS_BAR_MODULES, ...extra];
  assert.deepEqual(renderSlot(all, 'center', { compact: false, data }).map((e) => e.node), ['wide-only', 'a', 'b']);
  assert.deepEqual(renderSlot(all, 'center', { compact: true, data }).map((e) => e.node), ['a', 'b']);
});
