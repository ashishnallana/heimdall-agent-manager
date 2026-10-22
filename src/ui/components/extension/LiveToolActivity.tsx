import { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  liveScopeKey, liveScopeMounted, liveScopeUnmounted, liveResyncRequested,
  type LiveScope, type ToolActivityState,
} from '../../store/toolActivitySlice';
import { fetchLiveScope } from '../../api/toolActivityLive';

export const formatToolDuration = (ms: number) =>
  ms < 1000 ? Math.round(ms) + ' ms' : (ms / 1000).toFixed(1) + ' s';

export default function LiveToolActivity({ instanceId, chainId = '', onOpenShell }: {
  instanceId: string; chainId?: string; onOpenShell: (sessionId: string) => void;
}) {
  const dispatch = useDispatch<any>();
  const key = liveScopeKey(instanceId, chainId);
  const scope = useSelector((state: any): LiveScope | undefined => state.toolActivity?.scopes[key]);
  const connected = useSelector((state: any) => Boolean(state.toolActivity?.connected));
  const refresh = useSelector((state: any) => (state.toolActivity as ToolActivityState)?.refresh || 0);
  const [collapsed, setCollapsed] = useState(false);
  const [collapsedAgents, setCollapsedAgents] = useState<Record<string, boolean>>({});
  useEffect(() => {
    if (!instanceId) return;
    dispatch(liveScopeMounted({ instanceId, chainId }));
    return () => { dispatch(liveScopeUnmounted(key)); };
  }, [dispatch, key, instanceId, chainId]);
  const mounted = Boolean(scope);
  useEffect(() => {
    if (connected && mounted) dispatch(fetchLiveScope(key));
  }, [dispatch, key, connected, refresh, mounted]);
  useEffect(() => { setCollapsedAgents({}); }, [key]);

  useEffect(() => {
    setCollapsedAgents((prior) => {
      const next = Object.fromEntries(Object.entries(prior).filter(([id]) => scope?.members[id]));
      return Object.keys(next).length === Object.keys(prior).length ? prior : next;
    });
  }, [scope?.members]);
  const members = Object.values(scope?.members || {});
  const count = members.reduce((sum, member) => sum + (member.snapshot?.active.length || 0), 0);
  const visible = members.filter((member) => member.snapshot &&
    (member.snapshot.active.length > 0 || member.snapshot.last_completion !== null));
  if (!instanceId || (!visible.length && !scope?.error)) return null;
  return <section data-debug-id="live-tool-activity" aria-label="Live tools"
    className="pointer-events-auto mx-3 mb-2 max-h-64 overflow-y-auto rounded-xl border border-border bg-surface px-3 py-2 text-xs text-muted">
    <button type="button" data-debug-id="live-tools-toggle" aria-expanded={!collapsed}
      onClick={() => setCollapsed((value) => !value)} className="flex w-full items-center justify-between text-primary">
      <span>{collapsed ? '▸' : '▾'} Running tools</span><span>{count} running</span>
    </button>
    {!collapsed && <>
      {scope?.error && <div role="status" className="mt-2 flex items-center justify-between gap-2">
        <span>Live tools unavailable</span>
        <button type="button" data-debug-id="live-tools-retry"
          onClick={() => dispatch(liveResyncRequested())} disabled={!connected}>Retry</button>
      </div>}
      {visible.map((member) => {
        const snapshot = member.snapshot!;
        const closed = Boolean(collapsedAgents[member.instance_id]);
        return <div key={member.instance_id} className="mt-2 border-t border-border pt-2">
          <button type="button" data-debug-id={'live-tools-agent-toggle-' + member.instance_id}
            aria-expanded={!closed} className="flex w-full items-center justify-between gap-2 text-left"
            onClick={() => setCollapsedAgents((prior) => ({ ...prior, [member.instance_id]: !closed }))}>
            <span className="min-w-0 truncate">{closed ? '▸' : '▾'} {member.display_name || 'Agent'} · {member.instance_id}</span>
            <span className="shrink-0">{snapshot.active.length} running</span>
          </button>
          {!closed && <div className="mt-1 space-y-1 pl-3">
            {snapshot.active.map((call) => <div key={call.call_id} className="flex items-center justify-between gap-2">
              <span className="truncate">{call.tool_name || (call.source === 'shell' ? 'Shell' : 'Tool')} · running</span>
              {call.source === 'shell' && call.shell_session_id &&
                <button type="button" data-debug-id={'live-tools-shell-' + call.shell_session_id}
                  onClick={() => onOpenShell(call.shell_session_id)} className="shrink-0 text-accent">Open shell</button>}
            </div>)}
            {snapshot.last_completion && <div data-debug-id={'live-tools-last-duration-' + member.instance_id}>
              Last call · {formatToolDuration(snapshot.last_completion.duration_ms)}
            </div>}
          </div>}
        </div>;
      })}
    </>}
  </section>;
}
