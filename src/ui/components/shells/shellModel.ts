/**
 * shellModel — the Shells pages' shared vocabulary.
 * ------------------------------------------------------------------
 * Inherited silently from actionModel/agentModel; only what DIFFERS is remarked.
 * A **shell session** is a live process the bridge is running on a host — started by
 * an agent, by `ham-ctl shell`, or by a chain — not something a person creates in the
 * UI. Everything below was verified in source; the citations are load-bearing.
 *
 * What differs for this resource, and why:
 *
 *  1. **No create, no edit (REQ-UI-15).** Sessions are runtime. The single mutable
 *     field, `server_port`, is a menu item plus the existing `SetShellPortDialog`,
 *     not a form page. §7 of the plan template is N/A here and deliberately so.
 *
 *  2. **The row's bottom-right time switches field with the row's own state.**
 *     A live session's meaningful time is `last_activity_at` — when it last spoke.
 *     A terminal one's is `finished_at` — when it stopped; its activity clock froze
 *     at that moment and reading it as "active 4h ago" would imply a process that is
 *     not there. `started_at` is the absolute in the `title` for both. Every other
 *     resource has one time field; this one honestly has two.
 *
 *  3. **Tabs are Live | Finished**, the `shell_session_is_terminal` split
 *     (`src/hub/domain/shell_session.odin:51`). Status itself is not a tab: a session
 *     moves starting -> running -> exited while it is being read, and a status tab
 *     would carry rows out from under the reader. The terminal split is the one line
 *     a row crosses exactly once.
 *
 *  4. **Verbs are asymmetric across that split, because the HUB is asymmetric** and
 *     this was checked rather than assumed:
 *       - kill    409s on a terminal session — `shell_session_service.odin:236`,
 *                 "session has already terminated". So Kill is not offered there.
 *       - signal  has NO terminal guard (`:249`) but a signal to a dead pid is a
 *                 no-op, so Interrupt is not offered there either.
 *       - restart has NO terminal guard (`:268`) and IS meaningful there — it is the
 *                 main reason to want it. It can still fail, because the bridge looks
 *                 the session up in an IN-MEMORY map (`hub_runtime_client.odin:2414`)
 *                 that a bridge restart empties. That failure gets its own copy
 *                 (`restartFailureText`) rather than a generic "Restart failed",
 *                 which would leave a user retrying something that cannot succeed.
 *       - port    is a property of a live session; the hub refuses it once terminal.
 *
 *  5. **No markdown anywhere.** REQ-UI-11 says a view page renders markdown "where the
 *     field is markdown". A shell has no such field — its body is a byte stream, and
 *     rendering a stream as markdown would mangle it. Read-only here means the user
 *     WATCHES output and cannot type into it: `/shells/:id/input` and `/resize` exist
 *     and these pages never call them.
 */
import { buildRouteHash } from '../../utils/appLocation';
import { isVaultArmored } from '../../utils/vaultContent.ts';
import type { IconName, Tone } from '@ui';
import type { ShellSession, ShellSessionKind, ShellSessionStatus, ShellStatusFilter } from '../../api/endpoints/shells';

/* ------------------------------------------------------------------ *
 * Status
 * ------------------------------------------------------------------ */

/** Mirrors `shell_session_is_terminal` (src/hub/domain/shell_session.odin:51). */
const TERMINAL_STATUSES: ReadonlySet<ShellSessionStatus> = new Set<ShellSessionStatus>([
  'exited',
  'killed',
  'failed',
]);

export function isTerminal(session: Pick<ShellSession, 'status'>): boolean {
  return TERMINAL_STATUSES.has(session.status);
}

export function statusLabel(status: ShellSessionStatus): string {
  switch (status) {
    case 'starting': return 'Starting';
    case 'running': return 'Running';
    case 'exited': return 'Exited';
    case 'killed': return 'Killed';
    case 'failed': return 'Failed';
    default: return status;
  }
}

export function statusTone(status: ShellSessionStatus): Tone {
  switch (status) {
    case 'running': return 'success';
    case 'starting': return 'warning';
    case 'killed':
    case 'failed': return 'danger';
    case 'exited':
    default: return 'neutral';
  }
}

/* ------------------------------------------------------------------ *
 * REQ-SHELL-6 §2/§4 — which sessions a surface may show
 * ------------------------------------------------------------------ *
 * Both predicates below are pure and live here rather than inside their components, so
 * the decisions they encode can be tested as REAL CODE over a matrix instead of being
 * read and believed. That distinction is not academic in this file: the row-predicate
 * truth table exists because a render gap once survived review by looking right in
 * isolation.
 */

/** A run's marker message, reduced to what the pin decision needs. */
export interface ShellRunMarker {
  messageId: string;
  sessionId: string;
  /** When the marker was posted; the fallback for a session with no finished_at. */
  createdUnixMs: number;
}

/**
 * REQ-SHELL-6 §2 — which runs are PINNED above the composer.
 *
 * The user's sequencing is easy to implement backwards, so it is spelled out:
 *
 *   "the pinned indicator should disappear once new message from user/agent comes in
 *    IF ITS NOT RUNNING ANYMORE"
 *
 * So a finished run does NOT vanish when it exits. It stays on screen, now past tense,
 * until the NEXT user or agent message arrives — meaning a run that finishes while
 * nobody is talking remains readable instead of disappearing before it can be noticed.
 *
 * Hence the comparison is against `finished_at` and NOT against the marker's own
 * timestamp: a message that arrived while the run was still going must not unpin it,
 * because at that moment the run was still running and the user's condition was unmet.
 *
 * A session that is not terminal always pins — status_unknown included, since "the
 * bridge is gone" is not the same claim as "the run is over".
 */
export function pinnedRunSessions(
  sessions: ShellSession[],
  markers: ShellRunMarker[],
  lastMessageUnixMs: number,
): ShellSession[] {
  const markerBySession = new Map(markers.map((m) => [m.sessionId, m]));
  return sessions.filter((session) => {
    const marker = markerBySession.get(session.session_id);
    // No marker means no run marker in THIS conversation — the chain's CONVERSATION
    // SCOPE decision says a run appears only where it was triggered.
    if (!marker) return false;
    if (!isTerminal(session)) return true;
    const parsed = session.finished_at ? Date.parse(session.finished_at) : NaN;
    const finishedMs = Number.isFinite(parsed) ? parsed : marker.createdUnixMs;
    return finishedMs > lastMessageUnixMs;
  });
}

/* ------------------------------------------------------------------ *
 * REQ-SHELL-6 §8 / REQ-SHELL-10 — the bridge-offline session state
 * ------------------------------------------------------------------ *
 * REQ-SHELL-10 deliberately did NOT add a sixth status value; a stored status would
 * have been a durable write triggered by a bare WS disconnect. Instead the API reports
 * two DERIVED booleans alongside the verbatim `status`:
 *
 *   status_unknown  the owning bridge is gone, so this row's status cannot be vouched
 *                   for until it returns. A TERMINAL session is never status_unknown —
 *                   a finished job's status is a fact about the past and needs no bridge
 *                   to confirm it.
 *   bridge_online   the raw fact the above derives from, so the UI can say WHY.
 *
 * They QUALIFY status and never replace it, so nothing below branches on a status enum
 * value that does not exist. §8 is explicit about what must not happen: this state may
 * be rendered neither as plain `running` (which asserts something we do not know to be
 * true) nor as `failed`/`killed` (which assert something we know to be false).
 */

/** What to actually show for a session's state, status_unknown included. */
export interface ShellStatusPresentation {
  label: string;
  tone: Tone;
  /** Hover text explaining the state; always says WHY when the status is unknown. */
  title: string;
  /** True when the bridge is gone and the stored status cannot be trusted. */
  unknown: boolean;
}

export function statusPresentation(session: ShellSession): ShellStatusPresentation {
  if (session.status_unknown) {
    return {
      // Its own word, not one of the five statuses. "Unknown" is the honest claim: we
      // are not asserting it died and not asserting it lives.
      label: 'Status unknown',
      // `warning`, not `danger`: danger would read as a failure, which is precisely the
      // thing we do not know.
      tone: 'warning',
      title:
        `The bridge hosting this session is offline, so its status cannot be confirmed. ` +
        `It was last known to be ${statusLabel(session.status).toLowerCase()}; that will be ` +
        `re-confirmed or corrected when the bridge reconnects.`,
      unknown: true,
    };
  }
  return {
    label: statusLabel(session.status),
    tone: statusTone(session.status),
    title: statusLabel(session.status),
    unknown: false,
  };
}

/**
 * How to describe a kill on this session, honestly (§8 + REQ-SHELL-3).
 *
 * `offered` is false only where a kill is genuinely meaningless: a session already
 * terminal has no process left and the hub 409s.
 *
 * ON THE OFFLINE WORDING — this states §8 AT FULL STRENGTH: the kill is DURABLE and
 * WILL be carried out when the bridge returns.
 *
 * It did not always say that. This copy was deliberately softened on 2026-09-28
 * (coordinator ruling) because the delivery half genuinely did not happen: a kill
 * accepted while the bridge was offline was still pending after the bridge reconnected
 * — process alive, row still `running`, intent still stamped. The hub answered 202 with
 * a promise it did not keep, so the UI refused to repeat it.
 *
 * REQ-SHELL-23 fixed that, and the wording is restored as its AC6. Verified on an
 * isolated stack across TWO disconnect/reconnect cycles: the process is gone, the row is
 * terminal, the intent is cleared, and shell_session_exited lands on the user bus.
 *
 * WHAT THE COPY MUST GET RIGHT NOW IS TIMING, WHICH IS THE OTHER WAY TO LIE. Delivery
 * happens ON RECONNECT, not immediately, and the bridge may be gone for a long time.
 * So the wording commits to the OUTCOME while being explicit that it is pending until
 * the bridge is back — it must not imply the process dies the moment the user clicks.
 * The old failure was under-promising; the tempting new one is over-promising.
 */
export interface ShellKillAffordance {
  offered: boolean;
  label: string;
  title: string;
  /** Set when accepting the kill will queue rather than deliver it. */
  queuedNote?: string;
}

export function killAffordance(session: ShellSession): ShellKillAffordance {
  if (isTerminal(session)) {
    return {
      offered: false,
      label: 'Kill',
      title: `Already ${session.status} — nothing to kill`,
    };
  }
  if (!session.bridge_online) {
    return {
      offered: true,
      // Commits to the OUTCOME, explicit that it is pending until the bridge is back.
      label: 'Queue kill',
      title:
        'The bridge hosting this session is offline, so this kill will not take effect yet. ' +
        'It is queued and will be carried out as soon as the bridge reconnects.',
      queuedNote: 'Queued. This session will be killed when the bridge reconnects.',
    };
  }
  return {
    offered: true,
    label: 'Kill',
    title: 'Terminate this session',
  };
}

export function kindLabel(kind: ShellSessionKind): string {
  switch (kind) {
    case 'run': return 'Run';
    case 'shell': return 'Shell';
    case 'server': return 'Server';
    default: return kind;
  }
}

/**
 * The kind FILTER, which deliberately includes `run` even though AC1 says a user can
 * never start one. Filtering is not starting: a user who can SEE run rows (the owner-wide
 * listing returns them) must be able to narrow to them, and removing the option would
 * only make those rows harder to find, not harder to create.
 *
 * The line AC1 actually draws is in `verbsForSession`, which withholds every start-shaped
 * verb from a run — restart included — so no run ROW offers a way to start one. Keep the
 * two apart when editing: adding `run` here is correct, offering it in `NewShellDialog`
 * or handing a run row a restart is not.
 */
export const KIND_FILTER_OPTIONS: { value: ShellSessionKind; label: string }[] = [
  { value: 'run', label: 'Run' },
  { value: 'shell', label: 'Shell' },
  { value: 'server', label: 'Server' },
];

/* ------------------------------------------------------------------ *
 * Tabs
 * ------------------------------------------------------------------ */

export type ShellTab = 'live' | 'finished';

export const SHELL_TABS: { value: ShellTab; label: string }[] = [
  { value: 'live', label: 'Live' },
  { value: 'finished', label: 'Finished' },
];

/**
 * The statuses a tab can contain. The Status filter offers only these, because a
 * Status of "exited" under the Live tab is a filter that can only ever return nothing
 * — the same "offer only the verbs that mean something in this state" rule the row
 * menu follows, applied to a filter.
 */
export function statusOptionsForTab(tab: ShellTab): { value: ShellSessionStatus; label: string }[] {
  return tab === 'live'
    ? [
        { value: 'starting', label: 'Starting' },
        { value: 'running', label: 'Running' },
      ]
    : [
        { value: 'exited', label: 'Exited' },
        { value: 'killed', label: 'Killed' },
        { value: 'failed', label: 'Failed' },
      ];
}

/**
 * The single `status` value to send for a given tab + Status filter. The tab is the
 * composite (`live`/`finished`); an explicit Status narrows it to one exact value.
 * One value, never a CSV — Amendment 8: the hub honours only the first token of a
 * CSV filter, so sending one would display three chips and apply one.
 */
export function statusParamFor(tab: ShellTab, status: ShellSessionStatus | ''): ShellStatusFilter {
  return status || tab;
}

/* ------------------------------------------------------------------ *
 * Verbs
 * ------------------------------------------------------------------ */

export type ShellVerb = 'preview' | 'copy-url' | 'set-port' | 'interrupt' | 'restart' | 'kill';

export const VERB_LABEL: Record<ShellVerb, string> = {
  preview: 'Open preview',
  'copy-url': 'Copy access URL',
  'set-port': 'Set server port…',
  interrupt: 'Interrupt (SIGINT)',
  restart: 'Restart',
  kill: 'Kill',
};

/**
 * Icons are distinct per tone so a destructive verb is never one ambiguous glyph away
 * from a constructive one (Amendment 6). Inside a menu these ride BESIDE the label,
 * never instead of it.
 */
export const VERB_ICON: Record<ShellVerb, IconName> = {
  preview: 'eye',
  'copy-url': 'copy',
  'set-port': 'gear',
  interrupt: 'zap',
  restart: 'refresh',
  kill: 'stop',
};

export function isDestructive(verb: ShellVerb): boolean {
  return verb === 'kill';
}

/** T11-UI-5 / XM-8: reachable exactly when the hub has a live port to proxy. */
export function canPreview(session: ShellSession): boolean {
  return session.status === 'running' && session.server_port > 0;
}

/**
 * Offer only the verbs that mean something in this state — see the header for the
 * hub citation behind every exclusion.
 *
 * RESTART IS GATED ON KIND, AND IT IS AN AC1 CONTROL, NOT A COSMETIC ONE.
 * AC1 is "a user cannot start a run from the UI by ANY path". Fixing the picker closes
 * the obvious path; Restart is the second one, and it was open. The owner-wide shells
 * list is deliberately UNSCOPED (per the chain description, "nothing may hide a user's
 * own runs"), so a user's `run` rows really do appear in this UI — and restart respawns
 * with run_seq+1, which is starting a run. A run is a one-shot command owned by the
 * agent that triggered it; re-running it is that agent's call.
 *
 * This is a UI gate and is NOT the enforcement point. shell_session_restart checks
 * ownership and nothing else — no starter rule, no kind branch — so the hub-side
 * backstop is still missing; that is REQ-SHELL-24, deliberately not fixed here. The
 * start path's own comment says why this matters: the rule "must be enforced at the API,
 * not only in the UI". Do not let this gate's existence read as that job being done.
 *
 * A TERMINAL RUN THEREFORE HAS NO VERBS AT ALL, and the empty array is the correct
 * answer rather than an oversight: kill 409s, a signal reaches no pid, a port cannot be
 * declared, there is nothing to preview, and restart belongs to the agent. Both call
 * sites already guard on `.length` (ShellRow.tsx:78, ShellDetail.tsx:287), so an empty
 * list renders no menu rather than an empty one.
 */
export function verbsForSession(session: ShellSession): ShellVerb[] {
  const mayRestart = session.kind !== 'run';
  if (isTerminal(session)) {
    // Restart is the only verb a dead session can still honour. Kill 409s, a signal
    // reaches no pid, a port cannot be declared, and there is nothing to preview.
    return mayRestart ? ['restart'] : [];
  }
  const verbs: ShellVerb[] = [];
  if (canPreview(session)) verbs.push('preview', 'copy-url');
  verbs.push('set-port', 'interrupt');
  if (mayRestart) verbs.push('restart');
  // A LIVE run keeps kill: §8 depends on the user being able to stop a run, and stopping
  // one is not starting one. Only restart is withheld.
  verbs.push('kill');
  return verbs;
}

/**
 * Whether the preview affordance applies to this session at all, as distinct from
 * whether it can be used right now.
 *
 * The split turns on TRANSIENT vs PERMANENT unreachability, and the rule is not
 * arbitrary. XM-8 rendered nothing for a running portless session, on the premise that
 * a port could only be set at start and so such a session could never become
 * reachable. XM-9 falsified that premise: a port CAN be declared after start. So a
 * LIVE session without a port is only transiently unreachable — the port can still be
 * declared, and the verb that declares it (`set-port`) sits in the same menu as the
 * control itself — and it gets a DISABLED control carrying the reason, the same
 * rendering as a session whose port is declared but which has not finished starting.
 *
 * A TERMINAL portless session stays unrendered, because that case really is permanent:
 * the hub refuses set-port on it with 409 and the bridge holds no live record to
 * update, so nothing about it can ever become reachable, and a permanently disabled
 * control would lie about being actionable.
 *
 * (Originally written for the `ShellsPanel` component; that file was unmounted dead
 * code and was deleted under REQ-SHELL-22, so the reasoning lives here now. The live
 * caller is `PreviewCard` in ShellDetail.tsx, which renders the card this gates.)
 */
export function hasPreviewAffordance(session: ShellSession): boolean {
  return session.server_port > 0 || !isTerminal(session);
}

/**
 * REQ-SHELL-6 §5 — does this session SUPPORT live preview at all?
 *
 * Distinct from `canPreview`, and the difference is the point. `canPreview` asks whether
 * a preview can be opened RIGHT NOW (running, with a port). This asks whether preview is
 * a property of the session at all, which is what an INDICATOR claims — a server that
 * declares a port supports preview even while it is still starting, and saying so is
 * useful rather than misleading.
 *
 * Keyed on kind AND port. A server with no port is explicitly valid per the redesign
 * (the port is OPTIONAL), and §5 requires it to show NO indicator: a preview affordance
 * for a session with nothing to serve would be a dead control. `run` and `shell` never
 * support preview — a run has no port at all, and a shell is a terminal.
 */
export function supportsLivePreview(session: ShellSession): boolean {
  return session.kind === 'server' && session.server_port > 0;
}

export function previewUnavailableReason(session: ShellSession): string {
  if (canPreview(session)) return '';
  if (isTerminal(session)) return `This session ${session.status} — there is nothing left to preview.`;
  if (session.server_port <= 0) return 'No port declared yet. Set one from the menu and the preview opens.';
  return `The session is ${session.status}; the preview opens once it is running.`;
}

/**
 * The browser-openable preview URL: the hub's own preview path, made absolute against
 * the origin the UI is served from. Deliberately NOT the bridge-local proxy URL from
 * `ham-ctl shell --help` — that one only resolves from a process on the bridge host
 * and would be dead text in a browser.
 */
export function previewAccessUrl(session: ShellSession): string {
  if (session.preview_url) return session.preview_url;
  const origin = typeof window === 'undefined' ? '' : window.location.origin;
  return `${origin}/api/v1/preview/${encodeURIComponent(session.session_id)}/`;
}

export type OpenPreviewResult = { opened: true; url: string } | { opened: false; url: string };

/**
 * Open a session's preview in a new browser tab. This is for surfaces outside the
 * conversation workspace (the Shells pages, the chain summary), where there is no aux dock.
 * `openPreviewInAux` only adds a tab to the focused conversation's dock, so on those pages
 * it does nothing visible.
 *
 * WHY NOT `window.open(url, '_blank', 'noopener,noreferrer')`: with `noopener` the spec
 * makes window.open return null EVEN ON SUCCESS. A null would then never tell us the
 * popup was blocked, so every click would look like a block. Instead we open a blank,
 * same-origin tab (a null handle here really does mean blocked), cut `opener` BEFORE the
 * preview loads (the noopener guarantee: the previewed app can't reach back into the UI),
 * and only then navigate. The caller gets the URL back so a block can show it, the same
 * way the copy-url failure does.
 */
export interface PreviewTabHandle {
  opener: unknown;
  location: { replace(url: string): void };
}

export function openPreviewInNewTab(
  session: ShellSession,
  open: (url: string, target: string) => PreviewTabHandle | null = (url, target) => window.open(url, target),
): OpenPreviewResult {
  const url = previewAccessUrl(session);
  const tab = open('', '_blank');
  if (!tab) return { opened: false, url };
  tab.opener = null;
  tab.location.replace(url);
  return { opened: true, url };
}

export function previewBlockedText(url: string): string {
  return `The browser blocked the new tab. Open the preview at ${url}`;
}

/* ------------------------------------------------------------------ *
 * Confirm + failure copy
 * ------------------------------------------------------------------ *
 * REQ-UI-18, proportional: the three verbs are NOT equally destructive.
 *   Interrupt — no confirm. SIGINT to a dev server is routine and recoverable, and a
 *     confirm on a routine act trains people to dismiss confirms.
 *   Restart   — confirms only while the session is LIVE, where it destroys running
 *     work. Restarting something already dead destroys nothing, so it asks nothing.
 *   Kill      — always confirms.
 */

export function needsConfirm(session: ShellSession, verb: ShellVerb): boolean {
  if (verb === 'kill') return true;
  if (verb === 'restart') return !isTerminal(session);
  return false;
}

export function confirmTitle(session: ShellSession, verb: ShellVerb): string {
  const name = shellTitle(session);
  return verb === 'kill' ? `Kill "${name}"?` : `Restart "${name}"?`;
}

export function confirmBody(session: ShellSession, verb: ShellVerb): string {
  if (verb === 'kill') {
    return 'The process is terminated immediately and anything it was doing is lost. Its output stays readable afterwards.';
  }
  return 'The running process is stopped and re-spawned with the same command and working directory. Anything it was part-way through is lost.';
}

export function bulkKillTitle(count: number): string {
  return count === 1 ? 'Kill 1 session?' : `Kill ${count} sessions?`;
}

/**
 * The bulk confirm names what it will act on AND what it will skip. A selection can
 * contain rows that have terminated since they were ticked — the hub 409s on those —
 * so saying "3 of these 5 have already finished and will be left alone" before the
 * fact is better than reporting three failures after it.
 */
export function bulkKillBody(names: string[], skipped: number): string {
  const subject = names.length === 1 ? `"${names[0]}"` : `${names.length} sessions`;
  const head = `Killing ${subject} terminates ${names.length === 1 ? 'its process' : 'their processes'} immediately. Their output stays readable afterwards.`;
  if (skipped <= 0) return head;
  return `${head} ${skipped} selected ${skipped === 1 ? 'session has' : 'sessions have'} already finished and will be left alone.`;
}

/**
 * Why a restart failed, in words that tell the user whether to retry.
 *
 * The bridge resolves a restart against an IN-MEMORY session map
 * (`hub_runtime_client.odin:2414`); a bridge that has restarted since the session
 * died no longer holds it, replies `ok:false`, and the hub turns that into
 * "bridge failed to restart shell session" (`shell_session_service.odin:290`).
 * That is a permanent condition for this session, so the copy says so instead of
 * inviting a retry that cannot work. Anything else keeps the server's own words.
 */
export function restartFailureText(err: unknown): string {
  const raw = shellErrorText(err, '');
  if (/failed to restart shell session/i.test(raw)) {
    return "This session's bridge no longer has it, so it can't be restarted. Start a new shell instead.";
  }
  return raw || "Ninjy couldn't reach the bridge to restart this session.";
}

/* ------------------------------------------------------------------ *
 * Display helpers
 * ------------------------------------------------------------------ */

/** The row title. Unlike an action, a shell HAS a name field; `cmd` is the fallback. */
export function shellTitle(session: Pick<ShellSession, 'label' | 'cmd' | 'session_id'> | null | undefined): string {
  const label = String(session?.label || '').trim();
  if (label) return label;
  const cmd = String(session?.cmd || '').trim();
  if (cmd) return cmd;
  return String(session?.session_id || 'Untitled session');
}

/**
 * The two reserved body lines: the command, then the working directory. Both are
 * paths and shell strings rather than prose — long, unbroken, and meaningful at both
 * ends — so the row truncates them and keeps the full text in a `title`.
 * The command is omitted when it IS the title, so a label-less row does not say the
 * same thing twice.
 */
export function shellBodyLines(session: ShellSession): { cmd: string; cwd: string } {
  const cmd = String(session.cmd || '').trim();
  const usedAsTitle = !String(session.label || '').trim() && Boolean(cmd);
  return {
    cmd: usedAsTitle ? '' : cmd,
    cwd: String(session.cwd || '').trim(),
  };
}

export function absoluteTime(iso?: string): string {
  if (!iso) return '';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  return new Date(ms).toLocaleString();
}

export function relativeTime(iso?: string): string {
  if (!iso) return '';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  const delta = Date.now() - ms;
  if (delta < 45000) return 'just now';
  const mins = Math.floor(delta / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString();
}

/**
 * The row's bottom-right label. Which FIELD it reads depends on the row's own state —
 * see the header, point 2. Returns the text and the absolute form for its `title`.
 */
export function shellTimeLabel(session: ShellSession): { text: string; title: string } {
  const started = session.started_at ? `Started ${absoluteTime(session.started_at)}` : '';
  // The LAST resort is `started_at`, never the status word. `last_activity_at` and
  // `finished_at` are both optional in the envelope — a session the bridge has not
  // reported activity on since it was created comes back with an empty string — but
  // `started_at` is the repo's ORDER BY column and is therefore always populated.
  // Falling back to the status instead printed a word that merely repeated the pill
  // immediately to its left and gave the slot's only job — when — to nobody.
  const fallback = relativeTime(session.started_at);
  if (isTerminal(session)) {
    const iso = session.finished_at || session.last_activity_at;
    const when = relativeTime(iso);
    const verb = statusLabel(session.status).toLowerCase();
    return {
      text: when ? `${verb} ${when}` : fallback ? `started ${fallback}` : verb,
      title: [started, iso ? `Finished ${absoluteTime(iso)}` : ''].filter(Boolean).join(' · '),
    };
  }
  const when = relativeTime(session.last_activity_at);
  return {
    text: when ? `active ${when}` : fallback ? `started ${fallback}` : statusLabel(session.status).toLowerCase(),
    title: [started, session.last_activity_at ? `Last activity ${absoluteTime(session.last_activity_at)}` : '']
      .filter(Boolean)
      .join(' · '),
  };
}

/** The exit-code pill's text, or '' when there is no exit code to report. */
export function exitLabel(session: ShellSession): string {
  if (!session.exit_code_set || session.exit_code === null || session.exit_code === undefined) return '';
  return session.exit_code === 0 ? 'exit 0' : `exit ${session.exit_code}`;
}

export function exitTone(session: ShellSession): Tone {
  return session.exit_code === 0 ? 'neutral' : 'danger';
}

/* ------------------------------------------------------------------ *
 * Client-side search (REQ-UI-4)
 * ------------------------------------------------------------------ *
 * There is no `shell` scope in the hub's search (`src/hub/domain/search.odin:11`), so
 * this is the whole of it. Same shape as the Actions search: every whitespace-separated
 * term must appear somewhere in the row's searchable text, so narrowing by adding a
 * word is predictable. The reach is named in the placeholder and in the no-results
 * copy, because a search whose reach is invisible reads as "it isn't there".
 *
 * NOTE the honest limit, stated wherever the user can act on it: this searches the
 * sessions ALREADY LOADED, not the server's whole table. The list is keyset-paged, so
 * scrolling loads more and widens the reach.
 */
export function shellSearchableText(session: ShellSession): string {
  return [
    session.label && !isVaultArmored(session.label) ? session.label : '',
    session.cmd && !isVaultArmored(session.cmd) ? session.cmd : '',
    session.cwd,
    session.session_id,
    session.kind,
    session.status,
    session.server_port > 0 ? String(session.server_port) : '',
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

export function matchesQuery(session: ShellSession, query: string): boolean {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return true;
  const haystack = shellSearchableText(session);
  return terms.every((term) => haystack.includes(term));
}

/* ------------------------------------------------------------------ *
 * URL state (REQ-UI-17)
 * ------------------------------------------------------------------ */

export interface ShellListUrlState {
  tab: ShellTab | '';
  q: string;
  /** Exact status within the tab. Server-side (`status=`), single-select. */
  status: ShellSessionStatus | '';
  /** Server-side (`bridge_id=` / `project_id=`), single-select per Amendment 8. */
  bridge: string;
  project: string;
  /** CLIENT-side: `kind` is not a query parameter the list endpoint accepts. */
  kind: ShellSessionKind | '';
}

export const EMPTY_LIST_URL_STATE: ShellListUrlState = {
  tab: '',
  q: '',
  status: '',
  bridge: '',
  project: '',
  kind: '',
};

export function parseShellListUrl(search: string): ShellListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const status = String(params.get('status') || '');
  const kind = String(params.get('kind') || '');
  const validStatus = ['starting', 'running', 'exited', 'killed', 'failed'].includes(status);
  const validKind = KIND_FILTER_OPTIONS.some((entry) => entry.value === kind);
  return {
    tab: (SHELL_TABS.some((entry) => entry.value === tab) ? tab : '') as ShellTab | '',
    q: String(params.get('q') || ''),
    status: (validStatus ? status : '') as ShellSessionStatus | '',
    bridge: String(params.get('bridge') || ''),
    project: String(params.get('project') || ''),
    kind: (validKind ? kind : '') as ShellSessionKind | '',
  };
}

export function shellListSearch(state: ShellListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.q) params.set('q', state.q);
  if (state.status) params.set('status', state.status);
  if (state.bridge) params.set('bridge', state.bridge);
  if (state.project) params.set('project', state.project);
  if (state.kind) params.set('kind', state.kind);
  const query = params.toString();
  return query ? `?${query}` : '';
}

export function hasActiveFilters(state: ShellListUrlState): boolean {
  return Boolean(state.status || state.bridge || state.project || state.kind);
}

/** An active-VALUE count, not a count of filter controls (Amendment 6). */
export function activeFilterCount(state: ShellListUrlState): number {
  return [state.status, state.bridge, state.project, state.kind].filter(Boolean).length;
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs
 * ------------------------------------------------------------------ */

export const SHELL_LIST_PATH = '/shells';

export function shellListHref(state?: ShellListUrlState): string {
  return buildRouteHash(SHELL_LIST_PATH, state ? shellListSearch(state) : '');
}

/** The detail href carries the LIST's state, so opening a row does not reset the
 *  list underneath the user at >=1024 where both are on screen (Amendment 6). */
export function shellViewHref(sessionId: string, listState?: ShellListUrlState): string {
  return buildRouteHash(
    `${SHELL_LIST_PATH}/${encodeURIComponent(sessionId)}`,
    listState ? shellListSearch(listState) : '',
  );
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

export function replaceListSearch(state: ShellListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(SHELL_LIST_PATH, shellListSearch(state)),
  );
}

export interface ShellCrumb {
  label: string;
  href?: string;
}

/** A list page is the root of its own section — one heading, no trail (Amendment 5). */
export function listCrumbs(): ShellCrumb[] {
  return [{ label: 'Shells' }];
}

export function detailCrumbs(title: string, session: ShellSession | null, listState?: ShellListUrlState): ShellCrumb[] {
  const tab: ShellTab = listState?.tab || (session && isTerminal(session) ? 'finished' : 'live');
  const label = SHELL_TABS.find((entry) => entry.value === tab)?.label || 'Live';
  const full: ShellListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Shells', href: shellListHref({ ...full, tab: '' }) },
    { label, href: shellListHref(full) },
    { label: title },
  ];
}

export function viewCrumbs(title: string, listState?: ShellListUrlState): ShellCrumb[] {
  return [{ label: 'Shells', href: shellListHref(listState) }, { label: title }];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:shells:last-row';

export function rememberRow(sessionId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, sessionId);
  } catch {
    /* Private mode / blocked storage: restoration is a convenience, not a contract. */
  }
}

export function takeRememberedRow(): string {
  try {
    const value = window.sessionStorage.getItem(LAST_ROW_KEY) || '';
    window.sessionStorage.removeItem(LAST_ROW_KEY);
    return value;
  } catch {
    return '';
  }
}

/* ------------------------------------------------------------------ *
 * Errors
 * ------------------------------------------------------------------ */

export function shellErrorText(err: unknown, fallback = 'Something went wrong.'): string {
  if (!err) return fallback;
  const anyErr = err as any;
  const message = String(
    anyErr?.data?.error?.message || anyErr?.data?.error || anyErr?.error || anyErr?.message || '',
  ).trim();
  return message || fallback;
}
