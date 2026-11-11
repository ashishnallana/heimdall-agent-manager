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
  // A shell pane has no aux tree, so it hides the dock without touching the
  // global open state the agent conversations share.
  assert.match(ws, /const auxOpen = Boolean\(auxTreeId && auxOpenGlobal\)/);
  const pane = read('src/ui/components/mainWorkspace/ShellMainPane.tsx');
  assert.match(pane, /data-debug-id="shell-main-pane-bridge"/);
  assert.match(pane, /data-debug-id="shell-main-pane-switcher-btn"/);
  assert.match(pane, /data-debug-id="shell-main-pane-kill-confirm"/);
  const picker = read('src/ui/components/chat/NewConversationPage.tsx');
  // The mode is the headline's mode token; shell mode is the shared composer's shell body.
  assert.match(picker, /<LaunchHeadline\s+mode=\{paneMode\}\s+onModeChange=\{setPaneMode\}/);
  assert.match(picker, /<ShellComposerBody/);
  assert.match(picker, /useShellLaunch\(\{/);
  const panel = read('src/ui/components/chat/ShellLaunchPanel.tsx');
  assert.match(panel, /<BridgeDirectoryPicker/);
  // Launch logic (bridge, cwd default, start) lives in the shared hook.
  assert.match(panel, /useShellLaunch\(\{/);
  const launch = read('src/ui/components/shells/useShellLaunch.ts');
  assert.match(launch, /resolveProjectBridgeShellCwd\(project, bridgeId\)/);
  assert.match(panel, /data-debug-id=\{`new-convo-shell-kill-\$\{s\.session_id\}`\}/);
});

test('resource chooser and explicit launcher-intent wiring is reusable', () => {
  const conversations = read('src/ui/components/chat/ConversationSelectorModal.tsx');
  assert.match(conversations, /onSelectConversation/);
  assert.match(conversations, /autoFocusSearch/);
  const conversationPage = read('src/ui/components/chat/ConversationsHomePage.tsx');
  assert.match(conversationPage, /selectionDirectionForEvent\(event\)/);
  assert.match(conversationPage, /role="combobox"/);
  assert.match(conversationPage, /role="listbox"/);
  assert.match(conversationPage, /aria-selected/);
  assert.match(conversationPage, /event\.key === 'Enter'/);
  const shells = read('src/ui/components/chat/RunningShellSelectorModal.tsx');
  assert.match(shells, /allProjects: true/);
  assert.match(shells, /onSelectShell/);
  assert.match(shells, /selectionDirectionForEvent\(event\)/);
  assert.match(shells, /role="combobox"/);
  assert.match(shells, /role="listbox"/);
  assert.match(shells, /aria-selected/);
  assert.match(shells, /event\.key === 'Enter'/);
  const launcher = read('src/ui/components/chat/NewConversationPage.tsx');
  assert.match(launcher, /launchIntent\?: LauncherIntent/);
  // An explicit shell shortcut focuses "Open shell" once it can be pressed.
  assert.match(launcher, /if \(launchIntent !== 'shell' \|\| paneMode !== 'shell' \|\| openShellDisabled\) return;/);
  assert.match(launcher, /openShellRef\.current\?\.focus\(\)/);
  const workspace = read('src/ui/components/mainWorkspace/Workspace.tsx');
  assert.match(workspace, /launchIntent: value\.launchIntent/);
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

test('SH-3: the selected pane (or focused aux dock) shows a thin accent line at its top edge', () => {
  const ws = read('src/ui/components/mainWorkspace/Workspace.tsx');
  assert.match(ws, /const showActiveBorder = !isMobile && \(mainPaneCount > 1 \|\| auxShown\)/);
  assert.match(ws, /isActive=\{showActiveBorder && isFocused && !auxFocused\}/);
  assert.match(ws, /isActive=\{showActiveBorder && auxFocused\}\s+onActivate=\{\(\) => setAuxFocused\(true\)\}/);
  assert.match(ws, /data-debug-id="workspace-main"\s+onMouseDownCapture=\{\(\) => setAuxFocused\(false\)\}/);
  const frame = read('src/ui/components/mainWorkspace/MainPaneFrame.tsx');
  const dock = read('src/ui/components/auxiliary/AuxDock.tsx');
  assert.match(frame, /data-pane-selected=\{isActive \? 'true' : 'false'\}/);
  assert.match(dock, /data-pane-selected=\{isActive && !isMobile \? 'true' : 'false'\}/);
  // Both frames are positioned, so the line anchors to the pane's own top edge.
  assert.match(frame, /className=\{`relative flex h-full w-full/);
  assert.match(dock, /'relative flex min-w-0 flex-1 flex-col bg-canvas'/);
  // No layout shift: focus only flips an attribute; nothing is mounted or unmounted for it.
  assert.doesNotMatch(frame, /\{isActive \? </);
  assert.doesNotMatch(dock, /\{isActive && !isMobile \? </);
  const css = read('src/ui/styles.css');
  assert.doesNotMatch(css, /ui-pane-active-border/);
  // The header is not tinted or underlined any more (the line is the only cue).
  assert.doesNotMatch(css, /data-pane-header/);
  for (const file of ['src/ui/components/workbench/AgentChatPane.tsx', 'src/ui/components/mainWorkspace/ShellMainPane.tsx', 'src/ui/components/auxiliary/AuxTabStrip.tsx', 'src/ui/components/mainWorkspace/MainPaneFrame.tsx']) {
    assert.doesNotMatch(read(file), /data-pane-header/, file);
  }
  const rule = css.match(/\[data-pane-selected='true'\]::before \{([^}]*)\}/);
  assert.ok(rule, 'selected-pane line rule');
  const decl = Object.fromEntries(rule![1].split(';').map((d) => d.split(':').map((x) => x.trim())).filter((d) => d[0]));
  // Out of flow (absolute) and click-through: it cannot change any height or take input.
  assert.equal(decl.position, 'absolute');
  assert.equal(decl['pointer-events'], 'none');
  // Mock art_18e6ead45be6d34c: ~3px, top edge, inset 16px to the content padding, theme accent.
  assert.equal(decl.top, '0');
  assert.equal(decl.height, '3px');
  assert.equal(decl.left, '16px');
  assert.equal(decl.right, '16px');
  assert.equal(decl['background-color'], 'var(--color-accent)');
  assert.ok(!('border-radius' in decl), 'square ends');
});
