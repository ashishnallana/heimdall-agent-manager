import { useCallback, useEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  AgentActionItem,
  agentActionSurfaced,
  selectAgentActivityBuffer,
  selectAgentShownIds,
  selectReplayableActions,
} from '../../store/agentActivitySlice';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../../utils/vaultContent';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';
import WorkingRings from './WorkingRings';
import { agentActionLine } from './agentActionLabels';

// Push-only, ephemeral activity row rendered just above the chat composer, for the
// CURRENTLY-VIEWED instance only. It shows the agent's latest ham-ctl action the way
// a tool call is shown (LiveToolActivity): the working rings, a verb in the accent
// colour and the rest of the hub's id-free summary (composed hub-side in P1,
// buffered in the transient slice in P2; verbs in agentActionLabels.ts).
//
// Animation: one line; each new action slides up in place of the previous one
// (keyed by action id), and the last one collapses out when its lifetime ends.
// Under prefers-reduced-motion it is a plain fade (see styles.css). Lifetime is
// owned HERE (not redux): each action lives BUBBLE_LIFETIME_MS. On mount/open (Q2:
// open-conversation replay ONLY) we replay buffered actions <5min old, staggered at
// REPLAY_STAGGER_MS, "as if just arrived".

const BUBBLE_LIFETIME_MS = 4000;
const REPLAY_STAGGER_MS = 400;
// Matches the CSS .agent-action-exit duration — how long an exiting row stays
// mounted so the collapse/fade can play before removal.
const EXIT_ANIM_MS = 220;
// Guard: never surface a "live" buffer entry already older than one lifetime.
const LIVE_FRESHNESS_MS = BUBBLE_LIFETIME_MS + 1000;

type BubblePhase = 'shown' | 'exiting';
type VisibleBubble = AgentActionItem & { phase: BubblePhase };

function ActivityBubbleItem({ bubble }: { bubble: VisibleBubble }) {
  const activeKey = useSelector(selectActiveVaultKey);
  const [summary, setSummary] = useState(bubble.summary);

  useEffect(() => {
    let active = true;
    const raw = bubble.summary || '';
    if (!containsVaultArmored(raw) && !isVaultArmored(raw)) {
      setSummary(raw);
      return;
    }
    // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1),
    // so the gate is the real key, not the permanently-null state.vault.rawVaultKeyHex.
    if (!activeKey) {
      setSummary(replaceVaultTokens(raw, '[🔒 Encrypted]'));
      return;
    }
    const p = isVaultArmored(raw)
      ? decryptVaultText(raw, activeKey)
      : decryptEmbeddedVaultTokens(raw, activeKey);
    p.then((res) => {
      if (active) setSummary(replaceVaultTokens(res, '[🔒 Encrypted]'));
    }).catch(() => {
      if (active) setSummary(replaceVaultTokens(raw, '[🔒 Encrypted]'));
    });
    return () => {
      active = false;
    };
  }, [bubble.summary, activeKey]);

  const line = agentActionLine(bubble.action, summary);
  // A row is never clickable. Exactly one action ever was — the background-job
  // report, which opened a jobs panel — and REQ-SHELL-7 deleted that whole stack; the
  // panel it opened had already been unmounted before then. Shell sessions are
  // surfaced by the shells UI (REQ-SHELL-6), not by an activity row.
  return (
    <div
      data-debug-id={`conversation-activity-bubble-${bubble.action || 'action'}`}
      title={summary}
      className={`flex w-full min-w-0 items-center gap-2 overflow-hidden whitespace-nowrap text-xs ${bubble.phase === 'exiting' ? 'agent-action-exit' : 'agent-action-in'}`}
    >
      <WorkingRings size={16} />
      <span className="shrink-0 font-medium text-accent">{line.verb}</span>
      {line.detail ? <span className="agent-action-detail min-w-0 flex-1 truncate text-muted">{line.detail}</span> : null}
    </div>
  );
}

export default function AgentActivityBubbles({ instanceId }: { instanceId: string }) {
  const dispatch = useDispatch();
  const buffer = useSelector((state: any) => selectAgentActivityBuffer(state, instanceId));
  // Ids already surfaced for this instance, persisted in redux so it survives
  // conversation switches/remounts within the session (fixes bubbles replaying on
  // re-open). Read here so replay/live effects can exclude already-seen ids.
  const shownIds = useSelector((state: any) => selectAgentShownIds(state, instanceId));
  const [visible, setVisible] = useState<VisibleBubble[]>([]);

  // (rest of component hooks and effects)

  // Latest redux shown-id map, mirrored into a ref so the effects can read the
  // current value without re-subscribing / re-running on every change.
  const shownIdsRef = useRef(shownIds);
  shownIdsRef.current = shownIds;

  // Ids scheduled/surfaced during THIS mount so the live effect never double-shows
  // a buffered item within a single mount. (Cross-mount dedup lives in redux via
  // shownIds.) Reset when the viewed instance changes.
  const seenIdsRef = useRef<Set<string>>(new Set());
  // All pending timers, cleared on unmount / instance switch.
  const timersRef = useRef<number[]>([]);

  const removeBubble = useCallback((id: string) => {
    setVisible((prev) => prev.filter((b) => b.id !== id));
  }, []);

  // Show one bubble now and schedule its fade-out (exiting) + removal after its
  // lifetime. Stable across renders (only touches refs/setState), so both the
  // replay and live effects share it.
  const pushVisible = useCallback((item: AgentActionItem) => {
    // Record the item as surfaced at the moment it actually appears on screen (not
    // when it was merely scheduled), so items staged during replay but never shown
    // (user switched away mid-stagger) stay replayable, while anything shown once
    // is excluded from future replays.
    dispatch(agentActionSurfaced({ instanceId, id: item.id, ts: item.ts }));
    // Prepend so the newest action is first; only the newest is drawn.
    setVisible((prev) => (prev.some((b) => b.id === item.id) ? prev : [{ ...item, phase: 'shown' }, ...prev]));

    const hide = window.setTimeout(() => {
      setVisible((prev) => prev.map((b) => (b.id === item.id ? { ...b, phase: 'exiting' } : b)));
      const remove = window.setTimeout(() => removeBubble(item.id), EXIT_ANIM_MS);
      timersRef.current.push(remove);
    }, BUBBLE_LIFETIME_MS);
    timersRef.current.push(hide);
  }, [dispatch, instanceId, removeBubble]);

  // Fresh mount / instance switch: reset, then replay recent buffered actions
  // (<5min) staggered, "as if they just arrived", EXCLUDING ids already surfaced
  // in a prior mount (redux shownIds). Marking them locally seen up front so the
  // live effect below skips the same entries already present in the buffer.
  useEffect(() => {
    const timers = timersRef.current;
    const clearAllTimers = () => {
      for (const t of timers) window.clearTimeout(t);
      timers.length = 0;
    };

    clearAllTimers();
    seenIdsRef.current = new Set();
    setVisible([]);

    selectReplayableActions(buffer, Date.now(), shownIdsRef.current).forEach((item, index) => {
      seenIdsRef.current.add(item.id);
      timers.push(window.setTimeout(() => pushVisible(item), index * REPLAY_STAGGER_MS));
    });

    return clearAllTimers;
    // Replay is intentionally keyed on the viewed instance only; the buffer
    // snapshot is read at mount. Live growth is handled by the effect below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId, pushVisible]);

  // Live append: when the buffer grows, surface genuinely new + fresh entries.
  // Skips ids already surfaced in a prior mount (redux shownIds) so a live item
  // shown once is never re-surfaced after a remount.
  useEffect(() => {
    const now = Date.now();
    const shown = shownIdsRef.current;
    for (const item of buffer) {
      if (seenIdsRef.current.has(item.id)) continue;
      seenIdsRef.current.add(item.id);
      if (Object.prototype.hasOwnProperty.call(shown, item.id)) continue; // already surfaced before
      if (now - Number(item.ts || 0) > LIVE_FRESHNESS_MS) continue; // stale catch-up, skip
      pushVisible(item);
    }
  }, [buffer, pushVisible]);

  // One line: the newest action still showing, else the last one on its way out.
  const current = visible.find((b) => b.phase !== 'exiting') || visible[0];
  if (!current) return null;

  return (
    <div
      data-debug-id="conversation-activity-bubbles"
      aria-hidden="true"
      className="mb-1 flex h-6 items-center overflow-hidden px-1"
    >
      <ActivityBubbleItem key={current.id} bubble={current} />
    </div>
  );
}
