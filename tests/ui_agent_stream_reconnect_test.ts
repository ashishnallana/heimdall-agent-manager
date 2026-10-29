import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';

// Stub external UI/services, while executing the real hook, composer, and PTY decoder.
const boundaryModules: Record<string, string> = {
  '/hooks/useEntitlements.ts': 'export const useEntitlements = () => ({ terminal_input_enabled: true, terminal_streaming_enabled: true });',
  '/api/endpoints/agents.ts': `
    export const useFetchAgentInstanceQuery = () => ({});
    export const useSendAgentPaneInputMutation = () => [() => Promise.resolve()];
    export const useSendAgentPaneResizeMutation = () => [() => Promise.resolve()];
  `,
  '/api/endpoints/settings.ts': 'export const useFetchExperimentsQuery = () => ({data: {flags: [{key: "streaming_terminal_pane", enabled: true}]}});',
  '/hooks/useAgentPaneSubscription.ts': `
    export function useAgentPaneSubscription(options) {
      globalThis.__agentReconnectHarness.pollingIds.push(options.agentInstanceId);
      return { output: "", isLoading: false, refetch() {} };
    }
  `,
  '/store/themeSlice.ts': 'const theme = {terminal: {background: "#000"}}; export const useTheme = () => ({theme});',
  '/shells/usePaneVaultLock.ts': `
    import {useState} from 'react';
    export function usePaneVaultLock() {
      const [locked, setLocked] = useState(false);
      return {locked, bridgeId: "", report: () => setLocked(true), markUnsealed: () => setLocked(false)};
    }
  `,
  '/shells/VaultLockedOverlay.tsx': 'export default function VaultLockedOverlay() { return null; }',
  '/billing/UpgradePrompt.tsx': 'export default function UpgradePrompt() { return null; }',
};
registerHooks({
  load(url, context, nextLoad) {
    const match = Object.entries(boundaryModules).find(([suffix]) => url.endsWith(suffix));
    if (match) return {format: 'module', source: match[1], shortCircuit: true};
    if (url.includes('/node_modules/@xterm/xterm/')) {
      return {format: 'module', source: `
        export class Terminal {
          constructor(options) {
            this.options = options; this.cols = 80; this.rows = 24; this.text = ""; this.resets = 0;
            this.buffer = {active: {viewportY: 0, baseY: 0, type: "normal"}};
            globalThis.__agentReconnectHarness.terminals.push(this);
          }
          open(container) { this.container = container; }
          loadAddon() {} onScroll() {} onData() { return {dispose() {}}; }
          onResize() { return {dispose() {}}; } resize() {} scrollToBottom() {} focus() {}
          write(text, done) { this.text += text; this.container.textContent = this.text; done?.(); }
          reset() { this.resets++; this.text = ""; this.container.textContent = ""; }
          dispose() { this.disposed = true; }
        }
      `, shortCircuit: true};
    }
    if (url.includes('/node_modules/@xterm/addon-fit/')) {
      return {format: 'module', source: 'export class FitAddon { fit() {} }', shortCircuit: true};
    }
    return nextLoad(url, context);
  },
});

class Socket {
  static OPEN = 1;
  static instances: Socket[] = [];
  static rejectSetup = false;
  readyState = 0;
  onopen: any = null;
  onclose: any = null;
  onmessage: any = null;
  onerror: any = null;
  sent: any[] = [];
  url: string;
  constructor(url: string) {
    this.url = url;
    if (Socket.rejectSetup) throw new Error('connection setup rejected');
    Socket.instances.push(this);
  }
  send(data: any) { this.sent.push(data); }
  close() { this.readyState = 3; }
  open() { this.readyState = Socket.OPEN; this.onopen?.(); }
  fail(reason = '', code = 1006) { this.readyState = 3; this.onclose?.({reason, code}); }
  control(message: any) { this.onmessage?.({data: JSON.stringify(message)}); }
}

async function harness(panel = false) {
  const dom = new JSDOM('<div id="root"></div>', {url: 'http://localhost/', pretendToBeVisual: true});
  const keys = ['window', 'document', 'WebSocket', 'ResizeObserver', 'requestAnimationFrame', 'IS_REACT_ACT_ENVIRONMENT', '__agentReconnectHarness'];
  const saved = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)] as const);
  const state = {terminals: [] as any[], pollingIds: [] as any[]};
  Object.assign(globalThis, {
    window: dom.window, document: dom.window.document, WebSocket: Socket,
    ResizeObserver: class { observe() {} disconnect() {} },
    requestAnimationFrame: (fn: () => void) => { queueMicrotask(fn); return 1; },
    IS_REACT_ACT_ENVIRONMENT: true, __agentReconnectHarness: state,
  });
  Socket.instances = [];
  Socket.rejectSetup = false;
  let sequence = 0;
  const timers = new Map<number, {fn: () => void; ms: number; interval: boolean}>();
  dom.window.setTimeout = ((fn: () => void, ms: number) => {
    const id = ++sequence; timers.set(id, {fn, ms, interval: false}); return id;
  }) as any;
  dom.window.setInterval = ((fn: () => void, ms: number) => {
    const id = ++sequence; timers.set(id, {fn, ms, interval: true}); return id;
  }) as any;
  dom.window.clearTimeout = dom.window.clearInterval = ((id: number) => timers.delete(id)) as any;
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { useAgentStream } = await import('../src/ui/components/chat/useAgentStream.ts');
  const { AgentPaneComposerPanel } = await import('../src/ui/components/chat/AgentPaneComposerPanel.tsx');
  const store = {getState: () => ({}), subscribe: () => () => {}, dispatch: () => {}};
  let result: ReturnType<typeof useAgentStream>;
  let closes = 0;
  let locks = 0;
  let props: any = panel
    ? {agentInstanceId: 'inst-test', isExpanded: true, runtimeStatus: 'running'}
    : {agentInstanceId: 'inst-test', onClose: () => closes++, onVaultLocked: () => locks++};
  function Probe() { result = useAgentStream(props); return null; }
  const root = createRoot(dom.window.document.getElementById('root')!);
  const render = async (patch = {}) => {
    props = {...props, ...patch};
    await act(async () => root.render(React.createElement(Provider as any, {store},
      React.createElement(panel ? AgentPaneComposerPanel : Probe, panel ? props : {}))));
  };
  await render();
  return {
    dom, state, timers, render,
    get result() { return result!; },
    get closes() { return closes; },
    get locks() { return locks; },
    get latest() { return Socket.instances.at(-1)!; },
    async step(fn: () => void) { await act(async () => { fn(); }); },
    async timer(ms: number) {
      const entries = [...timers].filter(([, t]) => t.ms === ms && !t.interval);
      assert.equal(entries.length, 1, 'exactly one timer at ' + ms + 'ms');
      const [id, timer] = entries[0];
      timers.delete(id);
      await act(async () => timer.fn());
    },
    async exhaust() {
      await this.step(() => this.latest.fail());
      for (const delay of [1000, 2000, 4000]) {
        if (panel) {
          assert.equal(dom.window.document.querySelector('[data-debug-id="agent-pane-stream-disconnected"]'), null);
        } else {
          assert.equal(this.result.disconnected, false);
        }
        await this.timer(delay);
        await this.step(() => this.latest.fail());
      }
    },
    async cleanup() {
      await act(async () => root.unmount());
      assert.equal(timers.size, 0, 'unmount cancels all hook timers');
      dom.window.close();
      for (const [key, descriptor] of saved) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor);
        else delete (globalThis as any)[key];
      }
    },
  };
}

test('three backoff retries exhaust; manual retry recovers and earns another full cycle', async () => {
  const h = await harness();
  try {
    assert.equal(h.result.disconnected, false, 'initial connection is not exhausted');
    await h.step(() => h.latest.open());
    assert.equal(h.result.connected, true);
    await h.exhaust();
    assert.equal(Socket.instances.length, 4);
    assert.equal(h.result.disconnected, true);
    assert.equal(h.closes, 1);
    assert.equal(h.timers.size, 0);
    await h.step(() => h.result.reconnect());
    assert.equal(Socket.instances.length, 5, 'manual retry starts without a timer');
    assert.equal(h.result.disconnected, false);
    await h.step(() => h.latest.open());
    assert.equal(h.result.connected, true);
    await h.exhaust();
    assert.equal(Socket.instances.length, 8);
    assert.equal(h.result.disconnected, true);
    assert.equal(h.closes, 2);
    await h.step(() => h.result.reconnect());
    await h.step(() => h.latest.open());
    assert.equal(h.result.disconnected, false);
    assert.equal(h.result.connected, true);
  } finally { await h.cleanup(); }
});

test('rejected WebSocket setup consumes three retries and manual retry resets that budget', async () => {
  Socket.rejectSetup = false;
  const h = await harness();
  try {
    Socket.rejectSetup = true;
    await h.step(() => h.latest.fail());
    for (const delay of [1000, 2000, 4000]) await h.timer(delay);
    assert.equal(h.result.disconnected, true);
    assert.equal(h.timers.size, 0);
    await h.step(() => h.result.reconnect());
    assert.equal(h.result.disconnected, false);
    await h.timer(1000);
    Socket.rejectSetup = false;
    await h.timer(2000);
    await h.step(() => h.latest.open());
    assert.equal(h.result.connected, true);
  } finally { await h.cleanup(); }
});

test('manual retry cancels backoff and stale close/timer callbacks cannot replace the new socket', async () => {
  const h = await harness();
  try {
    const oldClose = h.latest.onclose;
    await h.step(() => h.latest.fail());
    const oldTimer = [...h.timers.values()][0].fn;
    await h.step(() => { h.result.reconnect(); h.result.reconnect(); });
    assert.equal(h.timers.size, 0);
    assert.equal(Socket.instances.length, 2, 'superseded async connect creates no socket');
    const current = h.latest;
    await h.step(() => { oldClose({code: 1006}); oldTimer(); });
    assert.equal(h.latest, current);
    assert.equal(h.timers.size, 0);
    await h.step(() => current.fail());
    await h.step(() => oldTimer());
    await h.step(() => h.result.reconnect());
    assert.equal(h.timers.size, 0, 'stale timer must not orphan the current backoff');
    await h.step(() => h.latest.open());
    assert.equal(h.result.connected, true);
  } finally { await h.cleanup(); }
});

test('disabled, target changes and unmount cancel pending work without exhausted state', async () => {
  const h = await harness();
  try {
    await h.step(() => h.latest.fail());
    await h.render({enabled: false});
    assert.equal(h.result.disconnected, false);
    assert.equal(h.timers.size, 0);
    await h.step(() => h.result.reconnect());
    assert.equal(Socket.instances.length, 1);
    await h.render({enabled: true});
    await h.exhaust();
    assert.equal(h.result.disconnected, true);
    await h.render({agentInstanceId: 'inst-other'});
    assert.equal(h.result.disconnected, false);
    assert.match(h.latest.url, /inst-other/);
    await h.step(() => h.latest.fail());
  } finally { await h.cleanup(); }
});

test('vault close and typed vault error pause without consuming transport retries', async () => {
  for (const typed of [false, true]) {
    const h = await harness();
    try {
      const staleClose = h.latest.onclose;
      await h.step(() => typed
        ? h.latest.control({type: 'error', code: 'vault_locked', message: 'locked'})
        : h.latest.fail('vault_locked'));
      await h.step(() => staleClose({code: 1006}));
      assert.equal(h.locks, 1);
      assert.equal(h.result.disconnected, false);
      assert.equal(h.timers.size, 0);
      await h.step(() => h.result.reconnect());
      await h.step(() => h.latest.open());
      assert.equal(h.result.connected, true);
    } finally { await h.cleanup(); }
  }
});

test('intentional stream exit never schedules reconnect or shows exhausted state', async () => {
  const h = await harness();
  try {
    await h.step(() => h.latest.open());
    const staleClose = h.latest.onclose;
    await h.step(() => h.latest.control({type: 'stream_closed', exit_code: 0}));
    await h.step(() => staleClose({code: 1000}));
    assert.equal(h.result.connected, false);
    assert.equal(h.result.isStreamReady, false);
    assert.equal(h.result.disconnected, false);
    assert.equal(h.timers.size, 0);
    assert.equal(h.closes, 0);
  } finally { await h.cleanup(); }
});

test('hidden document pause clears retry state and resumes immediately', async (t) => {
  const h = await harness();
  t.mock.timers.enable({apis: ['setTimeout']});
  try {
    await h.step(() => h.latest.fail());
    Object.defineProperty(h.dom.window.document, 'hidden', {value: true, configurable: true});
    await h.step(() => h.dom.window.document.dispatchEvent(new h.dom.window.Event('visibilitychange')));
    await h.step(() => t.mock.timers.tick(10000));
    assert.equal(h.timers.size, 0);
    assert.equal(h.result.disconnected, false);
    await h.step(() => h.result.reconnect());
    assert.equal(Socket.instances.length, 1, 'manual retry cannot resurrect paused pane');
    Object.defineProperty(h.dom.window.document, 'hidden', {value: false, configurable: true});
    await h.step(() => h.dom.window.document.dispatchEvent(new h.dom.window.Event('visibilitychange')));
    assert.equal(Socket.instances.length, 2);
    await h.step(() => h.latest.open());
    assert.equal(h.result.connected, true);
  } finally { t.mock.timers.reset(); await h.cleanup(); }
});

test('composer shows accessible retry, preserves terminal and output through two retry cycles, hides it for stopped/disabled panes', async () => {
  const h = await harness(true);
  try {
    const {encodePtyViewerFrame, PTY_WIRE_KIND_OUTPUT} = await import('../src/ui/components/shells/ptyWire.ts');
    const node = h.dom.window.document.querySelector('[data-debug-id="agent-pane-terminal"]');
    const term = h.state.terminals[0];
    await h.step(() => h.latest.open());
    await h.step(() => h.latest.onmessage({data: encodePtyViewerFrame(PTY_WIRE_KIND_OUTPUT, 0, new TextEncoder().encode('PRESERVED OUTPUT')).buffer}));
    assert.match(term.text, /PRESERVED OUTPUT/);
    for (let cycle = 0; cycle < 2; cycle++) {
      await h.exhaust();
      const banner = h.dom.window.document.querySelector('[data-debug-id="agent-pane-stream-disconnected"]');
      assert.equal(banner?.getAttribute('role'), 'status');
      assert.match(banner!.textContent!, /Stream disconnected/);
      const button = banner!.querySelector('button')!;
      assert.equal(button.textContent?.trim(), 'Retry Connection');
      assert.equal(button.disabled, false);
      const before = Socket.instances.length;
      await h.step(() => button.click());
      assert.equal(Socket.instances.length, before + 1);
      await h.step(() => h.latest.open());
      assert.equal(h.dom.window.document.querySelector('[data-debug-id="agent-pane-stream-disconnected"]'), null);
      assert.equal(h.dom.window.document.querySelector('[data-debug-id="agent-pane-terminal"]'), node);
      assert.match(term.text, /PRESERVED OUTPUT/);
      assert.equal(term.resets, 0);
      assert.equal(term.disposed, undefined);
      assert.ok(h.state.pollingIds.every(id => id === null), 'disconnect never enables capture polling');
    }
    await h.step(() => h.latest.control({type: 'status', status: 'running'}));
    await h.exhaust();
    await h.render({runtimeStatus: 'stopped'});
    assert.equal(h.dom.window.document.querySelector('[data-debug-id="agent-pane-stream-disconnected"]'), null);
    assert.equal(h.latest.readyState, 3);
    await h.render({runtimeStatus: 'running'});
    await h.exhaust();
    await h.render({isActiveTab: false});
    assert.equal(h.dom.window.document.querySelector('[data-debug-id="agent-pane-stream-disconnected"]'), null);
    assert.match(term.text, /PRESERVED OUTPUT/);
  } finally { await h.cleanup(); }
});

test('composer clears previous agent output on target change before the new stream connects', async () => {
  const h = await harness(true);
  try {
    const {encodePtyViewerFrame, PTY_WIRE_KIND_OUTPUT} = await import('../src/ui/components/shells/ptyWire.ts');
    const node = h.dom.window.document.querySelector('[data-debug-id="agent-pane-terminal"]');
    const term = h.state.terminals[0];
    await h.step(() => h.latest.open());
    await h.step(() => h.latest.onmessage({data: encodePtyViewerFrame(
      PTY_WIRE_KIND_OUTPUT, 0, new TextEncoder().encode('OLD AGENT OUTPUT'),
    ).buffer}));
    assert.match(term.text, /OLD AGENT OUTPUT/);

    // Hold the next animation-frame write until after the target has changed.
    const pendingFrames: Array<() => void> = [];
    globalThis.requestAnimationFrame = ((fn: () => void) => {
      pendingFrames.push(fn); return pendingFrames.length;
    }) as any;
    await h.step(() => h.latest.onmessage({data: encodePtyViewerFrame(
      PTY_WIRE_KIND_OUTPUT, 0, new TextEncoder().encode('QUEUED OLD OUTPUT'),
    ).buffer}));
    assert.ok(pendingFrames.length > 0, 'old output is pending delivery');

    await h.render({agentInstanceId: 'inst-other'});
    assert.equal(h.dom.window.document.querySelector('[data-debug-id="agent-pane-terminal"]'), node);
    assert.equal(h.state.terminals.length, 1, 'target changes reuse the mounted terminal');
    assert.equal(term.text, '', 'previous agent is cleared even before a new connection succeeds');
    assert.equal(term.resets, 1);
    await h.step(() => pendingFrames.splice(0).forEach(fn => fn()));
    assert.equal(term.text, '', 'pending output from the old stream cannot repaint the terminal');

    await h.step(() => h.latest.open());
    await h.step(() => h.latest.onmessage({data: encodePtyViewerFrame(
      PTY_WIRE_KIND_OUTPUT, 0, new TextEncoder().encode('NEW AGENT OUTPUT'),
    ).buffer}));
    await h.step(() => pendingFrames.splice(0).forEach(fn => fn()));
    assert.equal(term.text, 'NEW AGENT OUTPUT');
    assert.equal(term.disposed, undefined);
  } finally { await h.cleanup(); }
});
