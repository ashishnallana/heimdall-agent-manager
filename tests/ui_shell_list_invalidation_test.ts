// GET /shells request counts per shell lifecycle, through the REAL wsInvalidation
// handler, the real listShells endpoint and RTK Query, against a fake hub that applies
// the repo's list semantics (shell_session_list_by_owner_sqlite: scope column equality
// plus the SHELL_SESSION_SCOPE_RULES kind restriction, status=live as NOT terminal).
//
// The mounted set is the standard one a tab holds while a conversation is open:
//   AppShell status bar          { status: 'live', limit: 200 }   (AppShell.tsx:1531;
//                                 ShellLaunchPanel, ShellMainPane and
//                                 RunningShellSelectorModal share this key)
//   AuxNewTabLauncher            { chainId, status: 'live' }       (AuxNewTabLauncher.tsx:56)
//   useConversationRuns          { agentInstanceId, limit: 50 }    (ShellRunIndicator.tsx:53)
//
// Each scenario also checks correctness: once the frames settle every mounted list must
// equal what the hub returns now, i.e. no list the event could change was skipped.
//
// DEDUP_BASELINE=1 prints and asserts the counts of the pre-change handler (every frame
// invalidated ShellSessions:LIST at once); run it against the previous commit.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeVaultStore, installFetchCapture, installWindowShim } from './helpers/vaultEndpointHarness.ts';

const baseline = process.env.DEDUP_BASELINE === '1';
const TERMINAL = new Set(['exited', 'killed', 'failed']);
const SCOPED_KINDS: Record<string, string[]> = {
  bridge_id: ['server', 'shell'], chain_id: ['server', 'shell'], agent_instance_id: ['run'],
};

type Row = { session_id: string; kind: string; status: string; bridge_id: string; project_id: string; chain_id: string; agent_instance_id: string };

function hubList(rows: Row[], url: string): Row[] {
  const q = new URL(url, 'http://hub').searchParams;
  return rows.filter((r) => {
    for (const col of ['bridge_id', 'project_id', 'chain_id', 'agent_instance_id'] as const) {
      const want = q.get(col);
      if (!want) continue;
      if ((r as any)[col] !== want) return false;
      if (SCOPED_KINDS[col] && !SCOPED_KINDS[col].includes(r.kind)) return false;
    }
    const status = q.get('status');
    if (status === 'live' && TERMINAL.has(r.status)) return false;
    return true;
  });
}

const settle = (ms = 250) => new Promise((resolve) => setTimeout(resolve, ms));

test('GET /shells per shell lifecycle with the standard mounted set', async () => {
  installWindowShim();
  const store = await makeVaultStore();
  const net = installFetchCapture();
  const rows: Row[] = [];
  (globalThis as any).fetch = ((captured) => async (input: any, init: any) => {
    const url = String(input?.url ?? input);
    if (url.includes('/shells')) net.setNextResponse({ data: { sessions: hubList(rows, url), next_cursor: '' } });
    return captured(input, init);
  })((globalThis as any).fetch);

  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { shellsApi } = await import('../src/ui/api/endpoints/shells.ts');
  const ws = await import('../src/ui/api/wsInvalidation.ts');
  const mounted = [
    { status: 'live', limit: 200 },
    { chainId: 'chain1', status: 'live' },
    { agentInstanceId: 'inst1', limit: 50 },
  ] as const;
  const shellGets = () => net.requests.filter((r) => r.method === 'GET' && r.url.includes('/shells')).length;

  async function scenario(label: string, row: Row, frames: Array<{ apply: () => void; frame: any }>, burst: boolean, expected: { before: number; after: number }) {
    store.dispatch(heimdallApi.util.resetApiState());
    rows.length = 0;
    const subs = mounted.map((arg) => store.dispatch(shellsApi.endpoints.listShells.initiate(arg as any)));
    await Promise.all(subs);
    net.reset();
    for (const { apply, frame } of frames) {
      apply();
      ws.handleUserWsEvent(store.dispatch, { ...frame, session_id: frame.session_id ?? row.session_id });
      if (!burst) await settle();
    }
    await settle();
    const count = shellGets();
    console.log(`${label}: GET /shells=${count}`);
    assert.equal(count, baseline ? expected.before : expected.after, label);
    for (const arg of mounted) {
      const data = shellsApi.endpoints.listShells.select(arg as any)(store.getState())?.data;
      const url = '/shells?' + new URLSearchParams(Object.entries({
        chain_id: (arg as any).chainId, agent_instance_id: (arg as any).agentInstanceId, status: (arg as any).status, limit: (arg as any).limit,
      }).filter(([, v]) => v !== undefined).map(([k, v]) => [k, String(v)])).toString();
      assert.deepEqual(data?.sessions?.map((s: any) => `${s.session_id}:${s.status}`),
        hubList(rows, url).map((s) => `${s.session_id}:${s.status}`), `${label}: ${JSON.stringify(arg)} is current`);
    }
    subs.forEach((sub) => sub.unsubscribe());
  }

  // One `ham-ctl shell run` is three user-bus frames: shell_session_started (kind, and
  // chain_id only when set), resource_changed/shell_session "running" (REQ-2 change
  // frame, chain_id always present), shell_session_exited (no scope fields).
  function runLifecycle(row: Row) {
    return [
      { apply: () => { rows.push(row); }, frame: { type: 'shell_session_started', kind: row.kind, status: 'starting', ...(row.chain_id ? { chain_id: row.chain_id } : {}) } },
      { apply: () => { row.status = 'running'; }, frame: { type: 'resource_changed', resource: 'shell_session', resource_id: row.session_id, change: 'running', status: 'running', chain_id: row.chain_id } },
      { apply: () => { row.status = 'exited'; }, frame: { type: 'shell_session_exited', status: 'exited', exit_code: 0 } },
    ];
  }
  const run = (id: string, agent: string): Row => ({ session_id: id, kind: 'run', status: 'starting', bridge_id: 'b1', project_id: '', chain_id: '', agent_instance_id: agent });

  try {
    // This conversation's agent: status bar + run list are affected; the chain list can
    // never hold a run.
    const own = run('sh_own', 'inst1');
    await scenario('own-agent run, frames spaced', own, runLifecycle(own), false, { before: 9, after: 6 });
    // Another agent's run: after the started frame the row is cached in the status bar,
    // so the running/exited frames know its agent and skip this conversation's run list.
    const other = run('sh_other', 'inst2');
    await scenario('other-agent run, frames spaced', other, runLifecycle(other), false, { before: 9, after: 4 });
    // A short run whose three frames land inside one burst window.
    const fast = run('sh_fast', 'inst1');
    await scenario('own-agent run, one burst', fast, runLifecycle(fast), true, { before: 6, after: 3 });
    // A chain server: chain list + status bar, never an agent's run list.
    const server: Row = { session_id: 'sh_srv', kind: 'server', status: 'starting', bridge_id: 'b1', project_id: '', chain_id: 'chain1', agent_instance_id: '' };
    await scenario('chain server, frames spaced', server, runLifecycle(server), false, { before: 9, after: 6 });
    // Unknown session (e.g. a refused start, nothing cached): every list, as before.
    await scenario('unknown session exit', run('sh_unknown', 'inst9'), [
      { apply: () => {}, frame: { type: 'shell_session_exited', status: 'failed' } },
    ], false, { before: 3, after: 3 });
  } finally {
    store.dispatch(heimdallApi.util.resetApiState());
  }
});
