// SH-1: shells as Main workspace panes — id model, aux exclusion, naming,
// attach-list filtering, and the render/picker wiring.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  NEW_PANE_AGENT_ID,
  createInitialMainTree,
  isAgentPaneId,
  isRealAgentId,
  isShellPaneId,
} from '../src/ui/store/workspaceLayoutSlice.ts';
import { resolveAuxTreeId, sanitizeAuxPanesState } from '../src/ui/store/auxPanesSlice.ts';
import { attachableShells, shellPaneName, shellUptime } from '../src/ui/components/shells/shellPaneModel.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel: string) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');

test('pane ids: sh_ is a shell, inst_ an agent, _new the picker', () => {
  assert.equal(isShellPaneId('sh_18dea'), true);
  assert.equal(isShellPaneId('inst_18dea'), false);
  assert.equal(isShellPaneId(NEW_PANE_AGENT_ID), false);
  assert.equal(isAgentPaneId('inst_18dea'), true);
  assert.equal(isAgentPaneId('sh_18dea'), false);
  assert.equal(isAgentPaneId(NEW_PANE_AGENT_ID), false);
  // Both kinds are real pane occupants (URL sync, dedup).
  assert.equal(isRealAgentId('sh_18dea'), true);
});

test('a focused shell pane has no aux tree, and persisted aux state drops shell keys', () => {
  assert.equal(resolveAuxTreeId(createInitialMainTree('sh_abc')), null);
  assert.deepEqual(resolveAuxTreeId(createInitialMainTree('inst_abc')), { kind: 'agent', agentInstanceId: 'inst_abc' });
  const clean = sanitizeAuxPanesState({ agentPanes: { sh_abc: { tabs: [], activeTabId: '', isPaneOpen: true } } });
  assert.deepEqual(Object.keys(clean.agentPanes), []);
});

const shell = (over: Record<string, unknown>) => ({
  session_id: 'sh_1', bridge_id: 'brg_1', project_id: 'proj_a', kind: 'shell', status: 'running', label: '', cwd: '/home/t/app', started_at: '', ...over,
}) as any;

test('shell name: label, else cwd folder, else id', () => {
  assert.equal(shellPaneName(shell({ label: 'web-dev' })), 'web-dev');
  assert.equal(shellPaneName(shell({ cwd: '/home/t/app/' })), 'app');
  assert.equal(shellPaneName(shell({ cwd: '/' })), '/');
  assert.equal(shellPaneName(shell({ cwd: '' })), 'sh_1');
});

test('attach list: live interactive shells, project-scoped unless all projects, searchable', () => {
  const sessions = [
    shell({ session_id: 'sh_a', label: 'web' }),
    shell({ session_id: 'sh_b', project_id: 'proj_b', cwd: '/srv/logs' }),
    shell({ session_id: 'sh_c', kind: 'server', server_port: 5173 }),
    shell({ session_id: 'sh_d', status: 'exited' }),
  ];
  assert.deepEqual(attachableShells(sessions, { projectId: 'proj_a' }).map((s) => s.session_id), ['sh_a']);
  assert.deepEqual(attachableShells(sessions, { projectId: 'proj_a', allProjects: true }).map((s) => s.session_id), ['sh_a', 'sh_b']);
  assert.deepEqual(attachableShells(sessions, { allProjects: true, query: 'logs' }).map((s) => s.session_id), ['sh_b']);
});

test('uptime label', () => {
  const now = Date.parse('2026-10-15T10:00:00Z');
  assert.equal(shellUptime('2026-10-15T09:48:00Z', now), '12m');
  assert.equal(shellUptime('2026-10-15T06:56:00Z', now), '3h 4m');
  assert.equal(shellUptime('2026-10-12T10:00:00Z', now), '3d');
  assert.equal(shellUptime('', now), '');
});

test('wiring: Workspace renders ShellMainPane for shell ids; picker has Agent|Shell modes', () => {
  const ws = read('src/ui/components/mainWorkspace/Workspace.tsx');
  assert.match(ws, /\) : isShellPaneId\(agentId\) \? \(\s*\/\/[^\n]*\n\s*<ShellMainPane/);
  assert.match(ws, /isAgentPaneId\(prevFocused\) &&\s*isAgentPaneId\(focused\)/);
  const pane = read('src/ui/components/mainWorkspace/ShellMainPane.tsx');
  assert.match(pane, /data-debug-id="shell-main-pane-bridge"/);
  assert.match(pane, /data-debug-id="shell-main-pane-switcher-btn"/);
  assert.match(pane, /data-debug-id="shell-main-pane-kill-confirm"/);
  const picker = read('src/ui/components/chat/NewConversationPage.tsx');
  assert.match(picker, /<PaneModeSwitch value=\{paneMode\}/);
  assert.match(picker, /paneMode === 'shell' \? \(\s*<ShellLaunchPanel/);
  const panel = read('src/ui/components/chat/ShellLaunchPanel.tsx');
  assert.match(panel, /<BridgeDirectoryPicker/);
  assert.match(panel, /resolveProjectBridgeShellCwd\(project, bridgeId\)/);
  assert.match(panel, /data-debug-id=\{`new-convo-shell-kill-\$\{s\.session_id\}`\}/);
});

test('SH-2: every header segment follows the active-pane cue (theme tokens)', () => {
  const chat = read('src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(chat, /data-debug-id="conversation-thread-header"\s+data-pane-active=\{isFocusedPane \? 'true' : 'false'\}/);
  for (const id of ['conversation-breadcrumb-project', 'conversation-thread-title', 'conversation-chain-agent-switcher-btn']) {
    assert.match(chat, new RegExp(`data-debug-id="${id}"\\s+data-pane-crumb`));
  }
  const pane = read('src/ui/components/mainWorkspace/ShellMainPane.tsx');
  assert.match(pane, /data-debug-id="shell-main-pane-header"\s+data-pane-active=\{isFocused \? 'true' : 'false'\}/);
  assert.match(pane, /data-debug-id="shell-main-pane-bridge" data-pane-crumb/);
  assert.match(pane, /data-debug-id="shell-main-pane-switcher-btn"\s+data-pane-crumb/);
  assert.match(read('src/ui/components/mainWorkspace/Workspace.tsx'), /<ShellMainPane[\s\S]{0,200}isFocused=\{isFocused\}/);
  const css = read('src/ui/styles.css');
  assert.match(css, /\[data-pane-active='true'\] \[data-pane-crumb\]:not\(:hover\) \{\s*color: var\(--color-text-primary\);/);
  assert.match(css, /\[data-pane-active='false'\] \[data-pane-crumb\]:not\(:hover\) \{\s*color: var\(--color-text-muted\);/);
});

test('SH-3: tmux-style active border on the focused pane or the focused aux dock', () => {
  const ws = read('src/ui/components/mainWorkspace/Workspace.tsx');
  assert.match(ws, /const showActiveBorder = !isMobile && \(mainPaneCount > 1 \|\| auxShown\)/);
  assert.match(ws, /isActive=\{showActiveBorder && isFocused && !auxFocused\}/);
  assert.match(ws, /isActive=\{showActiveBorder && auxFocused\}\s+onActivate=\{\(\) => setAuxFocused\(true\)\}/);
  assert.match(ws, /data-debug-id="workspace-main"\s+onMouseDownCapture=\{\(\) => setAuxFocused\(false\)\}/);
  assert.match(read('src/ui/components/mainWorkspace/MainPaneFrame.tsx'), /\{isActive \? <div aria-hidden="true" data-debug-id=\{`main-pane-active-border-\$\{paneId\}`\} className="ui-pane-active-border" \/> : null\}/);
  assert.match(read('src/ui/components/aux/AuxDock.tsx'), /isActive && !isMobile \? <div aria-hidden="true" data-debug-id="aux-active-border" className="ui-pane-active-border" \/>/);
  const css = read('src/ui/styles.css');
  assert.match(css, /\.ui-pane-active-border \{[^}]*border-color: var\(--color-accent\);[^}]*border-width: 0 1px 1px 1px;/);
});
