import { useEffect, useState } from 'react';
import { useSelector } from 'react-redux';
import { useToolActivityStream } from '../../api/useToolActivityStream';
import { validInstanceId, type ToolActivityState, type ToolSummary } from '../../store/toolActivitySlice';

export const formatToolDuration = (ms: number) => {
  ms = Math.max(0, ms);
  if (ms < 1000) return Math.round(ms) + ' ms';
  if (ms < 60_000) return (ms / 1000).toFixed(1) + ' s';
  return Math.floor(ms / 60_000) + 'm ' + Math.floor(ms % 60_000 / 1000) + 's';
};
const colors = [
  'text-sky-700 dark:text-sky-300', 'text-violet-700 dark:text-violet-300',
  'text-amber-700 dark:text-amber-300', 'text-teal-700 dark:text-teal-300',
  'text-rose-700 dark:text-rose-300', 'text-indigo-700 dark:text-indigo-300',
  'text-orange-700 dark:text-orange-300', 'text-cyan-700 dark:text-cyan-300',
  'text-fuchsia-700 dark:text-fuchsia-300', 'text-lime-700 dark:text-lime-300',
];
const commonTools = ['bash', 'read', 'edit', 'write', 'grep', 'glob', 'agent', 'webfetch', 'websearch', 'exec_command'];
export function toolNameColor(name: string): string {
  const normalized = name.trim().toLowerCase();
  const common = commonTools.indexOf(normalized);
  let hash = 0;
  for (const char of normalized) hash = (Math.imul(hash, 31) + char.charCodeAt(0)) >>> 0;
  return colors[common < 0 ? hash % colors.length : common];
}
export type ToolMemberLabel = { instanceId: string; displayName: string };

export default function LiveToolActivity({ instanceId, members, onOpenShell }: {
  instanceId: string; members?: ToolMemberLabel[]; onOpenShell: (sessionId: string) => void;
}) {
  const roster = (members || [{ instanceId, displayName: '' }]).filter((m) => validInstanceId(m.instanceId));
  const ids = [...new Set(roster.map((member) => member.instanceId))].sort();
  useToolActivityStream(ids);
  const live = useSelector((state: any) => (state.toolActivity as ToolActivityState)?.members);
  const capacityExceeded = useSelector((state: any) => Boolean(state.toolActivity?.capacityExceeded));
  const hasActive = ids.some((id) => Boolean(live?.[id]?.snapshot?.active.length));
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!hasActive) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [hasActive]);

  const row = (id: string, call: ToolSummary, active: boolean, duration: number, shell = '') => {
    const snapshot = live?.[id]?.snapshot;
    const name = snapshot?.display_name || roster.find((m) => m.instanceId === id)?.displayName || 'Agent';
    const content = <>
      <span aria-label={active ? 'Running' : 'Finished'} className={
        'h-1.5 w-1.5 shrink-0 rounded-full ' + (active ? 'animate-pulse bg-accent' : 'bg-muted')} />
      <span className={'max-w-[22%] shrink-0 truncate font-medium ' + toolNameColor(call.tool_name)}
        title={call.tool_name}>{call.tool_name || 'Tool'}</span>
      <span data-debug-id="live-tools-summary" className="min-w-0 flex-1 truncate text-muted"
        title={call.summary + (call.summary_truncated ? '…' : '')}>
        {call.summary}{call.summary_truncated ? '…' : ''}
      </span>
      <span data-debug-id="live-tools-duration" className="shrink-0 tabular-nums text-faint">
        {formatToolDuration(duration)}
      </span>
      <span data-debug-id="live-tools-agent" title={name + ' · ' + id}
        className="ml-auto max-w-[25%] shrink-0 truncate rounded bg-neutral-soft px-1.5 py-0.5 text-faint">{name}</span>
    </>;
    const className = 'flex w-full min-w-0 max-w-full flex-nowrap items-center whitespace-nowrap gap-2 overflow-hidden text-left text-xs';
    return shell
      ? <button key={id + ':active:' + call.call_id} type="button" className={className}
          data-debug-id={'live-tools-shell-' + shell} aria-label={'Open shell: ' + call.summary}
          onClick={() => onOpenShell(shell)}>{content}</button>
      : <div key={id + ':' + (active ? 'active:' : 'finished:') + call.call_id}
          data-debug-id="live-tools-row" className={className}>{content}</div>;
  };

  const rows = ids.flatMap((id) => {
    const member = live?.[id];
    if (member?.availability === 'unavailable') return [
      <div key={id + ':unavailable'} role="status" className="flex min-w-0 items-center gap-2 text-xs text-muted">
        <span aria-label="Unknown" className="h-1.5 w-1.5 shrink-0 rounded-full bg-muted" />
        <span className="min-w-0 flex-1 truncate">Tools unavailable</span>
        <span data-debug-id="live-tools-agent" className="ml-auto max-w-[25%] shrink-0 truncate rounded bg-neutral-soft px-1.5 py-0.5 text-faint">
          {roster.find((m) => m.instanceId === id)?.displayName || 'Agent'}
        </span>
      </div>,
    ];
    const snapshot = member?.snapshot;
    if (!snapshot) return [];
    return [
      ...snapshot.active.map((call) => row(id, call, true, Math.max(0, now - call.started_at_ms),
        call.source === 'shell' ? call.shell_session_id : '')),
      ...snapshot.completed_since_last.map((call) => row(id, call, false, call.duration_ms)),
    ];
  });
  if (capacityExceeded) return <div role="status" className="text-xs text-muted">Tools unavailable: too many agents</div>;
  return rows.length ? <div data-debug-id="live-tool-activity" aria-label="Tool activity"
    className="min-w-0 max-w-full space-y-1.5">{rows}</div> : null;
}
