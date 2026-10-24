import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { useToolActivityStream } from '../../api/useToolActivityStream';
import { validInstanceId, toolCompletionObserverOpened, toolCompletionObserverClosed, toolCompletionsObserved,
  type LiveCall, type LiveCompletion, type ToolActivityState } from '../../store/toolActivitySlice';

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

type DisplayCall = { key: string; id: string; stream: string; name: string; call: LiveCall; completion?: LiveCompletion };
const streamKey = (epoch: string, generation: number) => JSON.stringify([epoch, generation]);

function useReducedMotion() {
  const [reduced, setReduced] = useState(() => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || false);
  useEffect(() => {
    const media = window.matchMedia?.('(prefers-reduced-motion: reduce)');
    if (!media) return;
    const update = () => setReduced(media.matches);
    update();
    media.addEventListener('change', update);
    return () => media.removeEventListener('change', update);
  }, []);
  return reduced;
}

const MIN_VISIBLE_MS = 1000;

// Activity controls the outcome/actions immediately. Presentation has its own
// lifecycle so even a call completed before its first paint remains readable.
function ToolRow({ item, active, completion, now, reduced, remove, onOpenShell }: {
  item: DisplayCall; active: boolean; completion?: LiveCompletion; now: number;
  reduced: boolean; remove: (key: string) => void; onOpenShell: (id: string) => void;
}) {
  const outer = useRef<HTMLDivElement>(null);
  const inner = useRef<HTMLDivElement>(null);
  // React owns only the initial dimensions. Effects retarget subsequent motion;
  // changing the OS preference must not reset an already-visible row to zero.
  const initialStyle = useRef({ height: reduced ? 'auto' : '0px', opacity: reduced ? 1 : 0 });
  const duration = useRef(0);
  if (active) duration.current = Math.max(0, now - item.call.started_at_ms);
  const [moving, setMoving] = useState(!reduced);
  const [visibleAt, setVisibleAt] = useState<number | null>(null);
  const [exiting, setExiting] = useState(false);
  const collapse = exiting && !active;
  useLayoutEffect(() => {
    if (active) { setExiting(false); return; }
    if (visibleAt === null) return;
    const remaining = Math.max(0, MIN_VISIBLE_MS - (performance.now() - visibleAt));
    const timer = window.setTimeout(() => setExiting(true), remaining);
    return () => window.clearTimeout(timer);
  }, [active, visibleAt]);
  useLayoutEffect(() => {
    const node = outer.current!, content = inner.current!;
    let frame = 0, timer = 0, cancelled = false;
    let finished = false;
    const finish = () => {
      if (cancelled || finished) return;
      finished = true;
      window.clearTimeout(timer);
      setMoving(false);
      if (collapse) { remove(item.key); return; }
      node.style.height = 'auto';
      // Entry time (including opacity/height interpolation) earns no residence.
      // rAF runs before paint. Cross a full-size paint before starting the
      // monotonic clock, including when reduced motion skips entry entirely.
      frame = requestAnimationFrame(() => {
        if (cancelled) return;
        frame = requestAnimationFrame(() => {
          if (!cancelled) setVisibleAt((prior) => prior ?? performance.now());
        });
      });
    };
    if (collapse) setVisibleAt(null);
    if (reduced) {
      node.style.height = collapse ? '0px' : 'auto';
      node.style.opacity = collapse ? '0' : '1';
      finish();
    } else {
      // Retarget from the current interpolated height when an exit is reversed.
      node.style.height = node.getBoundingClientRect().height + 'px';
      void node.offsetHeight;
      setMoving(true);
      frame = requestAnimationFrame(() => {
        if (cancelled) return;
        node.style.height = (collapse ? 0 : content.getBoundingClientRect().height) + 'px';
        node.style.opacity = collapse ? '0' : '1';
        timer = window.setTimeout(finish, 220);
      });
    }
    const ended = (event: TransitionEvent) => {
      if (event.target === node && event.propertyName === 'height') finish();
    };
    node.addEventListener('transitionend', ended);
    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
      window.clearTimeout(timer);
      node.removeEventListener('transitionend', ended);
    };
  }, [collapse, reduced, item.key, remove]);

  const call = item.call;
  const status = active ? 'Running' : completion?.status || 'Finished';
  const success = ['completed', 'success', 'succeeded', 'exited'].includes(status);
  const failure = ['failed', 'error', 'failure', 'killed'].includes(status);
  const label = active ? 'Running' : success ? 'Succeeded' : failure ? 'Failed' : 'Finished';
  const content = <>
    <span role="img" aria-label={label} title={label} className={
      'h-1.5 w-1.5 shrink-0 rounded-full ' + (active
        ? (reduced ? '' : 'animate-pulse motion-reduce:animate-none ') + 'bg-accent'
        : success ? 'bg-green-500' : failure ? 'bg-red-500' : 'bg-muted')} />
    <span className={'max-w-[22%] shrink-0 truncate font-medium ' + toolNameColor(call.tool_name)}
      title={call.tool_name}>{call.tool_name || 'Tool'}</span>
    <span data-debug-id="live-tools-summary" className="min-w-0 flex-1 truncate text-muted"
      title={call.summary + (call.summary_truncated ? '…' : '')}>
      {call.summary}{call.summary_truncated ? '…' : ''}
    </span>
    <span data-debug-id="live-tools-duration" className="shrink-0 tabular-nums text-faint">
      {formatToolDuration(active ? duration.current : completion?.duration_ms ?? duration.current)}
    </span>
    <span data-debug-id="live-tools-agent" title={item.name + ' · ' + item.id}
      className="ml-auto max-w-[25%] shrink-0 truncate rounded bg-neutral-soft px-1.5 py-0.5 text-faint">{item.name}</span>
  </>;
  const className = 'flex w-full min-w-0 max-w-full flex-nowrap items-center whitespace-nowrap gap-2 overflow-hidden text-left text-xs';
  const shell = active && call.source === 'shell' ? call.shell_session_id : '';
  return <div ref={outer} data-tool-motion={moving ? 'true' : undefined} data-tool-key={item.key}
    data-tool-phase={active ? 'active' : collapse ? 'exiting' : 'holding'}
    className="min-w-0 overflow-hidden" style={{ ...initialStyle.current,
      transition: reduced ? 'none' : 'height 200ms ease-out, opacity 120ms ease-out' }}>
    <div ref={inner} style={{ paddingTop: 6 }}>
      {shell ? <button type="button" className={className} data-debug-id={'live-tools-shell-' + shell}
        aria-label={'Open shell: ' + call.summary} onClick={() => { if (active) onOpenShell(shell); }}>{content}</button>
        : <div data-debug-id="live-tools-row" className={className}>{content}</div>}
    </div>
  </div>;
}

// Keep the inter-message gap independent of row order. Moving it from one row
// to the next when the first call finishes would otherwise add a layout jump.
function TailGap({ active, reduced }: { active: boolean; reduced: boolean }) {
  const [expanded, setExpanded] = useState(false);
  useLayoutEffect(() => {
    if (reduced || !active) { setExpanded(active); return; }
    const frame = requestAnimationFrame(() => setExpanded(true));
    return () => cancelAnimationFrame(frame);
  }, [active, reduced]);
  return <div aria-hidden="true" style={{ height: (reduced ? active : expanded)
    ? 'max(0px, calc(var(--live-tools-tail-gap, 6px) - 6px))' : 0,
    transition: reduced ? 'none' : 'height 200ms ease-out' }} />;
}

export default function LiveToolActivity(props: {
  instanceId: string; conversationId?: string; enabled?: boolean; members?: ToolMemberLabel[]; onOpenShell: (sessionId: string) => void;
}) {
  const auth = useSelector((state: any) => JSON.stringify([
    state.chat?.session?.userId, state.chat?.session?.daemonUrl, state.chat?.session?.clientToken,
  ]));
  const roster = (props.members || [{ instanceId: props.instanceId, displayName: '' }])
    .filter((member) => validInstanceId(member.instanceId));
  const idsKey = JSON.stringify([...new Set(roster.map((member) => member.instanceId))].sort());
  // Remount retained visuals on conversation/roster/auth changes, before paint.
  return <ToolRows key={JSON.stringify([props.instanceId, idsKey, auth])} {...props} roster={roster} idsKey={idsKey} />;
}

function ToolRows({ roster, idsKey, onOpenShell, conversationId = '', enabled = true }: {
  roster: ToolMemberLabel[]; idsKey: string; conversationId?: string; enabled?: boolean; onOpenShell: (sessionId: string) => void;
}) {
  const ids: string[] = useMemo(() => JSON.parse(idsKey), [idsKey]);
  const observerKey = useId();
  const dispatch = useDispatch();
  useToolActivityStream(ids, conversationId, enabled);
  // The shared stream clears the old user's store during its subscription
  // effect. Until that has run, never seed a new view from the previous store.
  const [subscribed, setSubscribed] = useState(false);
  useEffect(() => {
    dispatch(toolCompletionObserverOpened({ key: observerKey, ids }));
    setSubscribed(true);
    return () => { dispatch(toolCompletionObserverClosed(observerKey)); };
  }, [dispatch, observerKey, ids]);
  const live = useSelector((state: any) => (state.toolActivity as ToolActivityState)?.members);
  const pending = useSelector((state: any) =>
    (state.toolActivity as ToolActivityState)?.completionObservers?.[observerKey]?.pending);
  const through = pending?.at(-1)?.sequence;
  useEffect(() => {
    if (through !== undefined) dispatch(toolCompletionsObserved({ key: observerKey, through }));
  }, [dispatch, observerKey, through]);
  const capacity = useSelector((state: any) => Boolean(state.toolActivity?.capacityExceeded));
  const reduced = useReducedMotion();
  const desired = new Map<string, DisplayCall>();
  for (const id of ids) {
    const member = live?.[id], snapshot = member?.snapshot;
    if (!subscribed || capacity || member?.availability !== 'ready' || !snapshot) continue;
    const stream = streamKey(snapshot.epoch, snapshot.generation);
    for (const call of snapshot.active) {
      const key = JSON.stringify([id, stream, call.source, call.call_id]);
      desired.set(key, { key, id, stream, call,
        name: snapshot.display_name || roster.find((member) => member.instanceId === id)?.displayName || 'Agent' });
    }
  }
  const [retained, setRetained] = useState<DisplayCall[]>(() => [...desired.values()]);
  const [seen, setSeen] = useState(() => new Set<string>());
  const valid = (item: DisplayCall) => {
    const member = live?.[item.id];
    return member?.availability === 'unavailable' || capacity || Boolean(member?.snapshot &&
      streamKey(member.snapshot.epoch, member.snapshot.generation) === item.stream);
  };
  // Reconcile during render so a removed shell link cannot survive until an effect.
  const [previous, setPrevious] = useState(live);
  const [previousCapacity, setPreviousCapacity] = useState(capacity);
  const [previousSubscribed, setPreviousSubscribed] = useState(subscribed);
  const [previousPending, setPreviousPending] = useState(pending);
  if (previous !== live || previousCapacity !== capacity || previousSubscribed !== subscribed || previousPending !== pending) {
    setPrevious(live); setPreviousCapacity(capacity);
    setPreviousSubscribed(subscribed);
    setPreviousPending(pending);
    const observed = new Set(seen);
    const fresh: DisplayCall[] = [];
    const completions = new Map<string, LiveCompletion>();
    for (const event of pending || []) {
      const { instanceId: id, call } = event;
      const stream = streamKey(event.epoch, event.generation);
      const key = JSON.stringify([id, stream, call.source, call.call_id]);
      const member = live?.[id];
      completions.set(key, call);
      if (subscribed && !capacity && member?.availability === 'ready' && member.snapshot &&
          streamKey(member.snapshot.epoch, member.snapshot.generation) === stream &&
          event.fresh && !observed.has(key) && !desired.has(key)) {
        fresh.push({ key, id, stream, name: event.displayName ||
          roster.find((member) => member.instanceId === id)?.displayName || 'Agent',
          call: { ...call, shell_session_id: '', started_at_ms: call.completed_at_ms - call.duration_ms },
          completion: call });
      }
      observed.add(key);
    }
    for (const id of ids) {
      const member = live?.[id], snapshot = member?.snapshot;
      if (!subscribed || capacity || member?.availability !== 'ready' || !snapshot) continue;
      const stream = streamKey(snapshot.epoch, snapshot.generation);
      for (const call of [...snapshot.active, ...snapshot.completed_since_last]) {
        const key = JSON.stringify([id, stream, call.source, call.call_id]);
        observed.add(key);
      }
    }
    setSeen(observed);
    setRetained((rows) => [
      ...rows.filter(valid).map((item) => {
        // Active snapshots replace the retained copy, clearing any old outcome
        // on reentry. Completion batches are transient, so keep the latest known
        // terminal metadata until this exit ends without restarting its motion.
        const active = desired.get(item.key);
        if (active) return active;
        const completion = completions.get(item.key) || live?.[item.id]?.snapshot?.completed_since_last.find(
          (call) => call.source === item.call.source && call.call_id === item.call.call_id);
        return completion ? { ...item, completion } : item;
      }),
      ...[...desired.values()].filter((item) => !rows.some((old) => old.key === item.key)),
      ...fresh,
    ]);
  }
  const remove = useMemo(() => (key: string) => setRetained((rows) => rows.filter((item) => item.key !== key)), []);
  const hasActive = desired.size > 0;
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!hasActive) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [hasActive]);
  const rows = retained.filter(valid);
  if (!rows.length) return null;
  return <div data-debug-id="live-tool-activity" aria-label="Tool activity" className="!mt-0 min-w-0 max-w-full">
    <TailGap active={hasActive} reduced={reduced} />
    {rows.map((old) => {
      const item = desired.get(old.key) || old;
      return <ToolRow key={item.key} item={item} active={desired.has(item.key)} completion={item.completion}
        reduced={reduced} now={now} remove={remove} onOpenShell={onOpenShell} />;
    })}
  </div>;
}
