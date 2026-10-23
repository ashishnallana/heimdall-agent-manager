import { configureStore } from '@reduxjs/toolkit';
import reducer from '../../src/ui/store/toolActivitySlice.ts';
import { ToolActivityStream, type ToolSocket } from '../../src/ui/api/toolActivityStream.ts';

export const snapshot = (id = 'inst_a', revision = 1, extra: any = {}) => ({
  type: 'tool_activity_live', instance_id: id, agent_id: 'agt_worker', display_name: 'Worker',
  chain_id: 'chain_a', bridge_id: 'brg_a', epoch: '1792670400000000001',
  generation: 1, run_count: 1, revision, availability: 'ready',
  active: [{ call_id: id + ':call', source: 'shell', tool_name: 'Bash', summary: 'rg pattern src',
    summary_truncated: false, shell_session_id: 'sh_' + id, started_at_ms: 0 }],
  completed_since_last: [], ...extra,
});
export class FakeToolSocket implements ToolSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  sent: any[] = [];
  closeCount = 0;
  url: string;
  constructor(url = '') { this.url = url; }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  close() { this.readyState = 3; this.closeCount++; }
  open() { this.readyState = 1; this.onopen?.(); }
  frame(frame: any) { this.onmessage?.({ data: JSON.stringify(frame) }); }
  state(value: any, baseline = true, refresh = false) {
    this.frame({ type: 'state', instance_id: value.instance_id, snapshot: value, baseline, refresh });
  }
}
export function harness() {
  const store = configureStore({ reducer: { toolActivity: reducer } });
  const sockets: FakeToolSocket[] = [];
  const timers = new Set<() => void>();
  let time = 0, resume: (() => void) | undefined, urls = 0, resumes = 0;
  const stream = new ToolActivityStream(store.dispatch, {
    now: () => time,
    url: async () => 'wss://hub.test/tool?ticket=' + ++urls,
    socket: (url) => { const socket = new FakeToolSocket(url); sockets.push(socket); return socket; },
    every: (callback) => { timers.add(callback); return () => { timers.delete(callback); }; },
    onResume: (callback) => { resume = callback; resumes++; return () => { resume = undefined; resumes--; }; },
  });
  const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
  return {
    store, stream, sockets, timers, flush,
    get resumeListeners() { return resumes; },
    resume: () => resume?.(),
    member: (id = 'inst_a') => store.getState().toolActivity.members[id],
    advance: (ms: number, pong = true) => {
      for (let step = 0; step < ms; step += 1000) {
        time += Math.min(1000, ms - step);
        for (const callback of timers) callback();
        if (pong) for (const socket of sockets) {
          if (socket.readyState === 1 && socket.sent.at(-1)?.type === 'ping') socket.frame({ type: 'pong' });
        }
      }
    },
  };
}
