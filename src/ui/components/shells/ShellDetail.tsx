/**
 * ShellDetail — the shell view's guts, rendered as a full page AND as the two-pane
 * right-hand pane. Modeled after ActionDetail/AgentDetail.
 * ------------------------------------------------------------------
 * One implementation, two mounts, so the page and the pane cannot drift apart.
 *
 * Cards: Output · Preview · Details · Linked resources.
 *
 * **There is no markdown on this page, and no field that could carry any.** REQ-UI-11
 * asks a view page to render markdown "where the field is markdown"; a shell session
 * has no such field. Its body is a byte stream from a live process, and running a
 * stream through a markdown renderer would mangle the very thing the reader came for.
 * Read-only therefore means something specific here, and it is worth naming: the user
 * WATCHES the output and cannot type into it. `/shells/:id/input` and `/shells/:id/resize`
 * both exist and are wired up elsewhere (`ShellTerminalPane`); this page calls neither.
 *
 * **The output pane is the one justified nested vertical scroller in the rebuild.**
 * Amendment 4 forbids them because infinite scroll's sentinel depends on the page
 * scroller — but that argument is about a LIST, and this is a detail page with no
 * sentinel. A tailing log viewer cannot work without its own scroll region: following
 * output means pinning to the bottom of a region, which the page scroller cannot do
 * without dragging the rest of the page with it.
 *
 * **There is no create or edit route to reach from here (REQ-UI-15).** The single
 * mutable field, `server_port`, is a menu verb plus the existing `SetShellPortDialog`.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  IconButton,
  Menu,
  MenuItem,
  Modal,
  ModalBody,
  ModalFooter,
  ResourceDetailHeader,
  ResourceSectionCard,
  StatusPill,
  Text,
} from '@ui';
import {
  useGetShellSessionQuery,
  useKillShellMutation,
  useRestartShellMutation,
  useSignalShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { ShellLogViewer } from './ShellLogViewer';
import { ShellTerminalPane } from './ShellTerminalPane';
import { SetShellPortDialog } from './SetShellPortDialog';
import { openTab } from '../../store/previewTabsSlice';
import { useDispatch } from 'react-redux';
import { buildRouteHash } from '../../utils/appLocation';
// Reused rather than duplicated: `useActionCatalog` resolves instance / agent /
// bridge / project ids to names and carries Amendment 5's loading/empty/failed
// states. It is named for the page that first needed it, but it knows nothing about
// actions — copying 200 lines of it under a shells-shaped name would be the kind of
// snowflake this rebuild exists to remove.
import { bridgeLabel, catalogNote, projectLabel, useActionCatalog } from '../actions/actionCatalog';
import {
  VERB_ICON,
  VERB_LABEL,
  absoluteTime,
  canPreview,
  confirmBody,
  confirmTitle,
  exitLabel,
  exitTone,
  hasPreviewAffordance,
  isDestructive,
  isTerminal,
  kindLabel,
  needsConfirm,
  previewAccessUrl,
  previewUnavailableReason,
  relativeTime,
  restartFailureText,
  shellErrorText,
  shellTimeLabel,
  shellTitle,
  shellViewHref,
  statusLabel,
  statusPresentation,
  supportsLivePreview,
  verbsForSession,
  type ShellVerb,
} from './shellModel';

/* ------------------------------------------------------------------ *
 * ResizeObserver-based wide detection (same as ActionDetail)
 * ------------------------------------------------------------------ */

export function usePaneIsWide(ref: React.RefObject<HTMLElement | null>): boolean {
  const [wide, setWide] = React.useState(false);
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new ResizeObserver((entries) => {
      setWide((entries[0]?.contentRect.width ?? 0) >= 900);
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [ref]);
  return wide;
}

/* ------------------------------------------------------------------ *
 * Data + verbs
 * ------------------------------------------------------------------ */

export interface PendingConfirm {
  verb: ShellVerb;
  session: ShellSession;
}

/**
 * The detail's data and its verb runner.
 *
 * REQ-UI-20: a shell session mutates constantly and nothing here polls it into a
 * different order — the record is one row fetched by id, so a status change repaints
 * in place. The poll interval is the same one the log viewer runs on, so the status
 * pill and the output it explains never disagree by more than a second.
 */
export function useShellDetail(sessionId: string, onAfterVerb?: (verb: ShellVerb) => void) {
  // REQ-SHELL-6 §6: no pollingInterval. Repaints when a shell event invalidates this
  // session's `ShellSession` tag (wsInvalidation.ts, invalidateShellSession).
  const query = useGetShellSessionQuery({ sessionId }, { skip: !sessionId });
  const [killShell] = useKillShellMutation();
  const [restartShell] = useRestartShellMutation();
  const [signalShell] = useSignalShellMutation();
  const dispatch = useDispatch();

  const [busy, setBusy] = React.useState<ShellVerb | ''>('');
  const [actionError, setActionError] = React.useState('');
  const [notice, setNotice] = React.useState('');
  const [confirm, setConfirm] = React.useState<PendingConfirm | null>(null);
  const [portDialogOpen, setPortDialogOpen] = React.useState(false);

  const record: ShellSession | null = (query.data as ShellSession | null) || null;

  /** Fire a verb that has already cleared whatever confirm it needed. */
  const execute = React.useCallback(
    async (verb: ShellVerb, session: ShellSession) => {
      setBusy(verb);
      setActionError('');
      setNotice('');
      try {
        if (verb === 'kill') {
          await killShell({ sessionId: session.session_id }).unwrap();
          setNotice('Killed. The output above stays readable.');
        } else if (verb === 'restart') {
          await restartShell({ sessionId: session.session_id }).unwrap();
          setNotice('Restarted with the same command and working directory.');
        } else if (verb === 'interrupt') {
          // SIGINT = 2. The hub forwards the number straight to the bridge.
          await signalShell({ sessionId: session.session_id, signal: 2 }).unwrap();
          setNotice('SIGINT sent. Whether the process stops is up to the process.');
        }
        onAfterVerb?.(verb);
      } catch (err) {
        // Restart gets copy that says whether retrying can work; see shellModel.
        setActionError(
          verb === 'restart'
            ? restartFailureText(err)
            : shellErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this session.`),
        );
      } finally {
        setBusy('');
      }
    },
    [killShell, onAfterVerb, restartShell, signalShell],
  );

  const runVerb = React.useCallback(
    (verb: ShellVerb) => {
      const session = record;
      if (!session) return;
      if (verb === 'set-port') {
        setPortDialogOpen(true);
        return;
      }
      if (verb === 'preview') {
        // `openTab` takes the whole session — the slice reads its port, label and
        // status to build the tab, so handing it a two-field shape would not compile.
        dispatch(openTab(session));
        return;
      }
      if (verb === 'copy-url') {
        const url = previewAccessUrl(session);
        // A clipboard write rejects in an insecure context or on a permissions denial.
        // Either way the user is told, and told what the URL was, so the failure never
        // swallows the only copy of it.
        void (async () => {
          try {
            if (!navigator.clipboard?.writeText) throw new Error('clipboard unavailable');
            await navigator.clipboard.writeText(url);
            setNotice('Access URL copied.');
          } catch {
            setActionError(`Couldn't copy to the clipboard. The URL is ${url}`);
          }
        })();
        return;
      }
      if (needsConfirm(session, verb)) {
        setConfirm({ verb, session });
        return;
      }
      void execute(verb, session);
    },
    [dispatch, execute, record],
  );

  const resolveConfirm = React.useCallback(
    (proceed: boolean) => {
      const pending = confirm;
      setConfirm(null);
      if (proceed && pending) void execute(pending.verb, pending.session);
    },
    [confirm, execute],
  );

  return {
    query,
    record,
    busy,
    actionError,
    notice,
    dismissNotice: () => setNotice(''),
    runVerb,
    confirm,
    resolveConfirm,
    portDialogOpen,
    closePortDialog: () => setPortDialogOpen(false),
  };
}

/* ------------------------------------------------------------------ *
 * Copy-to-clipboard helper
 * ------------------------------------------------------------------ */

export function CopyButton({ value, label, debugId }: { value: string; label: string; debugId: string }) {
  const [copied, setCopied] = React.useState(false);
  return (
    <IconButton
      icon={copied ? 'check' : 'copy'}
      size="sm"
      label={copied ? 'Copied' : label}
      data-debug-id={debugId}
      onClick={() => {
        void navigator.clipboard?.writeText(value).then(() => {
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1500);
        });
      }}
    />
  );
}

/* ------------------------------------------------------------------ *
 * Header
 * ------------------------------------------------------------------ */

/**
 * The detail header's verbs.
 *
 * Open preview is the primary and gets its own desktop button; everything else lives
 * in the `…` menu, where the verbs carry WORDS. The primary is hidden below `md`
 * because the sticky mobile bar carries it instead — Amendment 6's rule that a verb
 * in the bottom bar is gated out of the header, which is how Memory came to ship two
 * Approve buttons on one phone screen.
 */
export function ShellDetailActions({
  record,
  busy,
  onVerb,
}: {
  record: ShellSession;
  busy: ShellVerb | '';
  onVerb: (verb: ShellVerb) => void;
}) {
  const verbs = verbsForSession(record);
  const primary = verbs.includes('preview') ? 'preview' : '';
  const menuVerbs = verbs.filter((verb) => verb !== primary);

  return (
    <>
      {primary ? (
        <span className="hidden md:contents">
          <ActionButton
            label={VERB_LABEL.preview}
            variant="primary"
            data-debug-id="shell-view-preview"
            onClick={() => onVerb('preview')}
          />
        </span>
      ) : null}
      {menuVerbs.length ? (
        <Menu
          label="Shell session actions"
          align="end"
          trigger={
            <ActionButton
              icon="more-horizontal"
              label="More"
              iconOnly
              aria-label="Shell session actions"
              loading={Boolean(busy)}
              data-debug-id="shell-view-menu"
            />
          }
        >
          {menuVerbs.map((verb) => (
            <MenuItem
              key={verb}
              danger={isDestructive(verb)}
              data-debug-id={`shell-view-${verb}`}
              onClick={() => onVerb(verb)}
            >
              {VERB_LABEL[verb]}
            </MenuItem>
          ))}
        </Menu>
      ) : null}
    </>
  );
}

/** The meta line under the title: status · kind · port · pid · time. */
export function ShellDetailMeta({ record }: { record: ShellSession }) {
  const presentation = statusPresentation(record);
  const time = shellTimeLabel(record);
  const exit = exitLabel(record);
  return (
    <div className="flex flex-wrap items-center gap-2" data-debug-id="shell-view-meta">
      <StatusPill tone={presentation.tone} title={presentation.title} data-debug-id="shell-view-status">
        {presentation.label}
      </StatusPill>
      <Badge data-debug-id="shell-view-kind">{kindLabel(record.kind)}</Badge>
      {record.server_port > 0 ? (
        <Badge data-debug-id="shell-view-port">:{record.server_port}</Badge>
      ) : null}
      {/* REQ-SHELL-6 §5: only a server WITH a port advertises live preview. */}
      {supportsLivePreview(record) ? (
        <Badge data-debug-id="shell-view-live-preview" title={`Supports live preview — serves on port ${record.server_port}`}>
          preview
        </Badge>
      ) : null}
      {exit ? (
        <StatusPill tone={exitTone(record)} data-debug-id="shell-view-exit">{exit}</StatusPill>
      ) : null}
      <Text as="span" role="body-sm" tone="muted" title={time.title || undefined} data-debug-id="shell-view-time">
        {time.text}
      </Text>
    </div>
  );
}

export function ShellDetailHeader({
  record,
  busy,
  onVerb,
  onBack,
  alert,
}: {
  record: ShellSession;
  busy: ShellVerb | '';
  onVerb: (verb: ShellVerb) => void;
  onBack?: () => void;
  alert?: React.ReactNode;
}) {
  const title = shellTitle(record);
  const presentation = statusPresentation(record);
  const time = shellTimeLabel(record);
  const exit = exitLabel(record);

  return (
    <ResourceDetailHeader
      dataDebugId="shell-pane-header"
      title={
        <a
          href={shellViewHref(record.session_id)}
          data-debug-id="shell-pane-title"
          className="rounded-[var(--radius-sm)] hover:underline focus-visible:shadow-focus focus-visible:outline-none"
        >
          {title}
        </a>
      }
      id={record.session_id}
      status={
        <StatusPill tone={presentation.tone} title={presentation.title} data-debug-id="shell-view-status">
          {presentation.label}
        </StatusPill>
      }
      badges={
        <>
          <Badge data-debug-id="shell-view-kind">{kindLabel(record.kind)}</Badge>
          {supportsLivePreview(record) ? (
            <Badge data-debug-id="shell-view-live-preview" title={`Supports live preview — serves on port ${record.server_port}`}>
              preview
            </Badge>
          ) : null}
          {record.server_port > 0 ? (
            <Badge data-debug-id="shell-view-port">:{record.server_port}</Badge>
          ) : null}
          {exit ? (
            <StatusPill tone={exitTone(record)} data-debug-id="shell-view-exit">{exit}</StatusPill>
          ) : null}
        </>
      }
      timestamp={time.text}
      timestampTooltip={time.title || undefined}
      alert={alert}
      onBack={onBack}
      actions={<ShellDetailActions record={record} busy={busy} onVerb={onVerb} />}
    />
  );
}

/* ------------------------------------------------------------------ *
 * Cards
 * ------------------------------------------------------------------ */

function Card({
  title,
  helper,
  action,
  children,
  debugId,
}: {
  title: string;
  helper?: string;
  action?: React.ReactNode;
  children: React.ReactNode;
  debugId: string;
}) {
  return (
    <ResourceSectionCard
      title={title}
      subtitle={helper}
      action={action}
      dataDebugId={debugId}
    >
      {children}
    </ResourceSectionCard>
  );
}

function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <Text as="div" role="label" tone="muted">{label}</Text>
      {children}
    </div>
  );
}

/** One resolved foreign key. Links only when a route for it actually exists. */
function LinkedRow({
  label,
  value,
  sub,
  href,
  debugId,
}: {
  label: string;
  value: string;
  sub?: string;
  href?: string;
  debugId: string;
}) {
  const body = (
    <>
      <Text as="span" role="body-sm" className="truncate">{value}</Text>
      {sub ? <Text as="span" role="caption" tone="muted" className="truncate">{sub}</Text> : null}
    </>
  );
  return (
    <DetailRow label={label}>
      {href ? (
        <a
          href={href}
          data-debug-id={debugId}
          className="flex min-w-0 flex-col rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
        >
          {body}
        </a>
      ) : (
        <div className="flex min-w-0 flex-col" data-debug-id={debugId}>{body}</div>
      )}
    </DetailRow>
  );
}

/**
 * REQ-UI-12's linked resources. Every link here comes from an id the session itself
 * carries and lands on a route that exists:
 *   agent instance -> its CHAIN's route (an instance has no route of its own)
 *   project        -> /projects/:id          (useListProjectsQuery for the name)
 *   chain          -> /chains/:id
 *   bridge         -> named, NOT linked: the shell has no per-bridge route, and a link
 *                     that does not land is worse than a name.
 * A lookup that fails degrades to the raw id; the section never errors the page.
 */
function LinkedResourcesCard({ record }: { record: ShellSession }) {
  const catalog = useActionCatalog();
  const instanceId = String(record.agent_instance_id || '');
  const instance = catalog.instances.byId.get(instanceId);
  const projectId = String(record.project_id || '');
  const chainId = String(record.chain_id || '');
  const bridge = bridgeLabel(record.bridge_id, catalog);

  const notes = [
    catalogNote(catalog.projects.state, 'projects'),
    catalogNote(catalog.bridges.state, 'bridges'),
  ].filter(Boolean);

  const anything = instanceId || projectId || chainId || record.bridge_id;

  return (
    <Card
      title="Linked resources"
      helper={notes.length ? notes.join(' ') : undefined}
      debugId="shell-view-linked-card"
    >
      {anything ? (
        <div className="flex flex-col gap-2">
          {instanceId ? (
            <LinkedRow
              label="Agent instance"
              value={instance?.label || instanceId}
              sub={instance?.sub || undefined}
              href={instance?.href}
              debugId="shell-view-linked-instance"
            />
          ) : null}
          {chainId ? (
            <LinkedRow
              label="Task chain"
              value={chainId}
              href={buildRouteHash(`/chains/${encodeURIComponent(chainId)}`, '')}
              debugId="shell-view-linked-chain"
            />
          ) : null}
          {projectId ? (
            <LinkedRow
              label="Project"
              value={projectLabel(projectId, catalog) || projectId}
              href={catalog.projects.byId.get(projectId)?.href}
              debugId="shell-view-linked-project"
            />
          ) : null}
          {record.bridge_id ? (
            <DetailRow label="Bridge">
              <Text as="div" role="body-sm" data-debug-id="shell-view-linked-bridge">
                {bridge || record.bridge_id}
              </Text>
            </DetailRow>
          ) : null}
        </div>
      ) : (
        <Text as="div" role="body-sm" tone="muted" data-debug-id="shell-view-linked-empty">
          This session was started outside any project, chain or agent — there is nothing to link it to.
        </Text>
      )}
    </Card>
  );
}

/** The preview card. Absent entirely when nothing could ever make it reachable. */
function PreviewCard({ record, onVerb }: { record: ShellSession; onVerb: (verb: ShellVerb) => void }) {
  if (!hasPreviewAffordance(record)) return null;
  const available = canPreview(record);
  const reason = previewUnavailableReason(record);
  const url = previewAccessUrl(record);

  return (
    <Card
      title="Preview"
      helper="A session that declares a port is reachable through the hub in a browser tab."
      action={
        <ActionButton
          icon={VERB_ICON.preview}
          label={VERB_LABEL.preview}
          showIconOnDesktop
          disabled={!available}
          title={available ? undefined : reason}
          data-debug-id="shell-view-preview-open"
          onClick={() => onVerb('preview')}
        />
      }
      debugId="shell-view-preview-card"
    >
      {available ? (
        <div className="flex min-w-0 items-center gap-2">
          <Text as="span" role="body-sm" className="min-w-0 truncate font-mono" data-debug-id="shell-view-preview-url">
            {url}
          </Text>
          <CopyButton value={url} label="Copy access URL" debugId="shell-view-copy-url" />
        </div>
      ) : (
        // Disabled-with-a-reason, not hidden: the verb that fixes it (Set server port)
        // is one menu away, so the control is genuinely actionable soon.
        <Text as="div" role="body-sm" tone="muted" className="ui-measure" data-debug-id="shell-view-preview-reason">
          {reason}
        </Text>
      )}
    </Card>
  );
}

/* ------------------------------------------------------------------ *
 * The body
 * ------------------------------------------------------------------ */

export function ShellDetailBody({
  record,
  actionError,
  notice,
  wide,
  onVerb,
}: {
  record: ShellSession;
  actionError?: string;
  notice?: string;
  wide: boolean;
  onVerb: (verb: ShellVerb) => void;
}) {
  const presentation = statusPresentation(record);
  // TWO DIFFERENT QUESTIONS that happen to share an answer today, kept apart on
  // purpose rather than collapsed into one flag:
  //
  //   isInteractiveCapable — can the user TYPE into this session? A `shell` is the
  //       only kind with an interactive form; a run/server pane is a read-only view
  //       of a process nobody is at the keyboard of.
  //   isCaptureless (below) — does a tee'd output log exist for it AT ALL?
  //
  // These are independent properties of a kind, and `shell` is simply the one kind
  // that is currently both. An interactive REPL the bridge tees would be interactive
  // and NOT captureless; a captureless non-interactive kind would be the reverse.
  // Collapsed into a single `isShell`, either addition would have to rename a concept
  // instead of adding a value — so the duplication is the cheaper of the two.
  const isInteractiveCapable = record.kind === 'shell';
  const isRunning = record.status === 'running' || record.status === 'starting';

  // REQ-SHELL-6A AC4. A `shell` has NO OUTPUT CAPTURE AT ALL — the bridge tees
  // nothing for it, and `shell log` on one answers internal_error rather than an
  // empty log. So the log pane is not merely empty for this kind, it is a pane for
  // something that does not exist: its own helper text promises "the session's
  // stdout as the bridge tees it", which for a shell is a claim about nothing.
  //
  // Hence no tab pair and no ShellLogViewer for a shell, ever. Before this the pair
  // was offered unconditionally, and the effect below actively FORCED a terminated
  // shell into the log tab — so the one state where the user is most likely to go
  // looking (the session is over, what happened?) was exactly the state that showed
  // them the broken pane.
  //
  // `run` and `server` are unchanged: both capture, both keep both tabs.
  const isCaptureless = record.kind === 'shell';

  // ONE PLACE decides the default pane, so the FIRST render and every later
  // record change cannot disagree about it. They did: the guard for a captureless
  // session lived only in the effect, while the useState initializer still fell
  // through to 'log' for a TERMINATED shell. That is not a cosmetic one-frame flash
  // — ShellLogViewer's useGetShellLogQuery has no `skip`, so it fires on mount, and
  // a log request for a `shell` is one the bridge can only refuse. Opening a
  // finished shell session therefore issued a guaranteed-failing request every time.
  //
  // A captureless session stays on the terminal whatever its status: there is no log
  // to fall back to when it stops, only the scrollback already on screen.
  const defaultViewMode: 'log' | 'terminal' =
    isCaptureless || (isInteractiveCapable && isRunning) ? 'terminal' : 'log';

  const [viewMode, setViewMode] = React.useState<'log' | 'terminal'>(defaultViewMode);

  // session_id is a dep in its own right: switching to a different session of the
  // same kind and status must still reset a pane the user had switched by hand.
  React.useEffect(() => {
    setViewMode(defaultViewMode);
  }, [record.session_id, defaultViewMode]);

  const outputAction = isCaptureless ? null : (
    <div
      className="flex items-center gap-1 bg-neutral-soft p-0.5 rounded-[var(--radius-sm)] border border-subtle"
      data-debug-id="shell-view-output-tabs"
    >
      <button
        type="button"
        onClick={() => setViewMode('log')}
        data-debug-id="shell-output-tab-log"
        className={[
          'px-2 py-0.5 text-xs font-medium rounded transition-colors',
          viewMode === 'log'
            ? 'bg-surface text-primary shadow-sm'
            : 'text-muted hover:text-primary',
        ].join(' ')}
      >
        Log Viewer
      </button>
      <button
        type="button"
        onClick={() => setViewMode('terminal')}
        data-debug-id="shell-output-tab-terminal"
        className={[
          'px-2 py-0.5 text-xs font-medium rounded transition-colors',
          viewMode === 'terminal'
            ? 'bg-surface text-primary shadow-sm'
            : 'text-muted hover:text-primary',
        ].join(' ')}
      >
        Interactive Terminal
      </button>
    </div>
  );

  const main = (
    <>
      <Card
        title={viewMode === 'terminal' ? 'Terminal' : 'Output'}
        helper={
          isCaptureless
            ? 'Interactive PTY terminal: type directly into the terminal below with input and resize support. A shell session keeps no output log — what you see here is all there is.'
            : viewMode === 'terminal'
              ? 'Interactive PTY terminal: type directly into the terminal below with input and resize support.'
              : "Read-only: this is the session's stdout as the bridge tees it. You can follow it, page back through it and filter it — you cannot type into it from here."
        }
        action={outputAction}
        debugId="shell-view-output-card"
      >
        {viewMode === 'terminal' ? (
          <div data-debug-id="shell-view-terminal" className="mt-1">
            {/* REQ-SHELL-18: keyed, because this pane is NOT single-session by construction.
                In the desktop two-pane layout ShellListPage renders <ShellDetailPane
                sessionId={selectedId}> unkeyed, so selecting a different row swaps `record`
                through this component instead of remounting it. */}
            <ShellTerminalPane key={record.session_id} session={record} />
          </div>
        ) : (
          /* showSessionVerbs={false}: this page's header already carries Restart and
             Kill, with the confirm policy the viewer's inline buttons do not have. */
          <ShellLogViewer session={record} showSessionVerbs={false} />
        )}
      </Card>

      <PreviewCard record={record} onVerb={onVerb} />
    </>
  );

  const rail = (
    <>
      <Card title="Details" debugId="shell-view-details-card">
        <div className="flex flex-col gap-2">
          <DetailRow label="Command">
            <div className="flex min-w-0 items-start gap-2">
              {/* Amendment 4: `pre-wrap` + `break-words` WRAPS rather than overflows,
                  so a long command needs no scroll region and adds no nested scroller. */}
              <pre className="min-w-0 flex-1 whitespace-pre-wrap break-words font-mono text-body-sm text-primary" data-debug-id="shell-view-cmd">
                {record.cmd || '—'}
              </pre>
              {record.cmd ? <CopyButton value={record.cmd} label="Copy command" debugId="shell-view-copy-cmd" /> : null}
            </div>
          </DetailRow>
          <DetailRow label="Working directory">
            <Text as="div" role="body-sm" className="break-words font-mono" data-debug-id="shell-view-cwd">
              {record.cwd || '—'}
            </Text>
          </DetailRow>
          <DetailRow label="Status">
            {/* REQ-SHELL-6 §8: the derived state leads, and the STORED status is still
                shown beside it as "last known" rather than being hidden. The detail view
                is the one place both belong — the pill has to pick one word, but here
                there is room to say we cannot confirm it AND what it was. */}
            <Text as="div" role="body-sm" data-debug-id="shell-view-status-detail">
              {presentation.label}
              {presentation.unknown ? (
                <span className="text-muted"> · last known {statusLabel(record.status).toLowerCase()}</span>
              ) : null}
            </Text>
          </DetailRow>
          {record.pid > 0 ? (
            <DetailRow label="PID">
              <Text as="div" role="body-sm" className="font-mono" data-debug-id="shell-view-pid">{record.pid}</Text>
            </DetailRow>
          ) : null}
          {record.exit_code_set ? (
            <DetailRow label="Exit code">
              <Text as="div" role="body-sm" className="font-mono" data-debug-id="shell-view-exit-code">
                {String(record.exit_code)}
              </Text>
            </DetailRow>
          ) : null}
          <DetailRow label="Started">
            <Text as="div" role="body-sm">
              {record.started_at ? `${absoluteTime(record.started_at)} (${relativeTime(record.started_at)})` : '—'}
            </Text>
          </DetailRow>
          {/* Only rendered once there IS one — Amendment 6: do not render a field the
              API does not send, and a live session genuinely has no finish time. */}
          {record.finished_at ? (
            <DetailRow label="Finished">
              <Text as="div" role="body-sm" data-debug-id="shell-view-finished">
                {`${absoluteTime(record.finished_at)} (${relativeTime(record.finished_at)})`}
              </Text>
            </DetailRow>
          ) : (
            <DetailRow label="Last activity">
              <Text as="div" role="body-sm" data-debug-id="shell-view-activity">
                {record.last_activity_at
                  ? `${absoluteTime(record.last_activity_at)} (${relativeTime(record.last_activity_at)})`
                  : '—'}
              </Text>
            </DetailRow>
          )}
          <DetailRow label="Session ID">
            <div className="flex items-center gap-2">
              <Text as="span" role="body-sm" className="font-mono">{record.session_id}</Text>
              <CopyButton value={record.session_id} label="Copy session ID" debugId="shell-view-copy-id" />
            </div>
          </DetailRow>
        </div>
      </Card>

      <LinkedResourcesCard record={record} />
    </>
  );

  return (
    <div data-debug-id="shell-view-page" className="flex w-full min-w-0 flex-col gap-3">
      {actionError ? <Alert tone="danger" title="That didn't work">{actionError}</Alert> : null}
      {notice ? <Alert tone="info" title="Done">{notice}</Alert> : null}
      {isTerminal(record) ? (
        <Alert tone="neutral" title={`This session has ${record.status === 'exited' ? 'exited' : record.status}`}>
          Its output is kept and stays readable. Restart re-spawns the same command — if the bridge
          has restarted since, it no longer holds the session and cannot.
        </Alert>
      ) : null}
      {wide ? (
        <div className="flex min-w-0 items-start gap-3">
          <div className="flex min-w-0 flex-1 flex-col gap-3">{main}</div>
          <div className="flex w-[320px] shrink-0 flex-col gap-3">{rail}</div>
        </div>
      ) : (
        <>
          {main}
          {rail}
        </>
      )}
    </div>
  );
}

/**
 * The mobile action bar: Open preview, full width, docked above the app's bottom tab
 * nav. It is the ONLY verb here, and it is gated out of the header below `md` so no
 * verb appears twice on one phone screen. Bottom clearance is the measured
 * `--ui-bottom-chrome`, never a hard-coded padding.
 */
export function ShellDetailMobileActions({
  record,
  onVerb,
}: {
  record: ShellSession;
  onVerb: (verb: ShellVerb) => void;
}) {
  if (!verbsForSession(record).includes('preview')) return null;
  return (
    <div
      className="fixed inset-x-0 app-viewport-bottom z-sticky border-t border-subtle bg-surface px-4 pb-[max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px))] pt-2 md:hidden"
      data-debug-id="shell-view-mobile-bar"
    >
      <Button
        variant="primary"
        width="full"
        data-debug-id="shell-view-mobile-preview"
        onClick={() => onVerb('preview')}
      >
        {VERB_LABEL.preview}
      </Button>
    </div>
  );
}

/**
 * The confirm modal and the port dialog, rendered by whichever mount owns the detail.
 * Kept here so the page and the pane cannot diverge on the confirm policy.
 */
export function ShellDetailOverlays({
  confirm,
  onResolve,
  portSession,
  portDialogOpen,
  onClosePortDialog,
  busy,
}: {
  confirm: PendingConfirm | null;
  onResolve: (proceed: boolean) => void;
  portSession: ShellSession | null;
  portDialogOpen: boolean;
  onClosePortDialog: () => void;
  busy: ShellVerb | '';
}) {
  return (
    <>
      {confirm ? (
        <ConfirmModal confirm={confirm} onResolve={onResolve} busy={busy} />
      ) : null}
      {portDialogOpen && portSession ? (
        <SetShellPortDialog session={portSession} onClose={onClosePortDialog} />
      ) : null}
    </>
  );
}

export function ConfirmModal({
  confirm,
  onResolve,
  busy,
}: {
  confirm: PendingConfirm;
  onResolve: (proceed: boolean) => void;
  busy: ShellVerb | '';
}) {
  return (
    <Modal
      open
      onOpenChange={(next) => { if (!next) onResolve(false); }}
      title={confirmTitle(confirm.session, confirm.verb)}
      size="sm"
      data-debug-id="shell-confirm-modal"
    >
      <ModalBody>
        <Text role="body">{confirmBody(confirm.session, confirm.verb)}</Text>
      </ModalBody>
      <ModalFooter>
        <Button variant="secondary" data-debug-id="shell-confirm-cancel" onClick={() => onResolve(false)}>
          Cancel
        </Button>
        <Button
          variant={isDestructive(confirm.verb) ? 'danger' : 'primary'}
          loading={Boolean(busy)}
          data-debug-id="shell-confirm-accept"
          onClick={() => onResolve(true)}
        >
          {VERB_LABEL[confirm.verb]}
        </Button>
      </ModalFooter>
    </Modal>
  );
}

/** Skeleton for the two-pane pane while the detail query is loading. */
export function ShellDetailPaneSkeleton() {
  return (
    <div className="flex flex-col gap-3" role="status" aria-busy="true" data-debug-id="shell-pane-skeleton">
      <span className="sr-only">Loading shell session…</span>
      <div className="h-6 w-2/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
      <div className="h-4 w-1/2 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
      <div className="mt-2 flex flex-col gap-2">
        {[0, 1, 2].map((i) => (
          <div key={i} className="h-4 w-full animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
        ))}
      </div>
    </div>
  );
}

export { shellTitle, Card as ShellDetailCard };
