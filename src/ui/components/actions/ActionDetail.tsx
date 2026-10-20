/**
 * ActionDetail — the action view's guts, rendered as a full page AND as the
 * two-pane right-hand pane. Modeled after AgentDetail/ProjectDetail.
 * ------------------------------------------------------------------
 * One implementation, two mounts, so the page and the pane cannot drift apart.
 *
 * Cards: Prompt · Schedule · Target · Details.
 *
 * **The prompt is NOT rendered as markdown**, and that is a deliberate divergence
 * from Memory. `prompt_text` is transmitted to the agent VERBATIM — rendering it
 * would show the reader something other than what the agent receives, which on a
 * page whose whole job is "what will this send?" is a lie of formatting. It is
 * shown pre-wrapped and monospaced, with a copy button.
 *
 * What is deliberately absent:
 *  - **Restore.** Delete is permanent to the UI: `deleted_at` is never serialised
 *    and no route reverses it.
 *  - **Pause.** A state write WOULD stop the scheduler
 *    (`action_scheduler.odin:392` refuses to claim a `completed` action), but
 *    `completed` already means "ran, no next slot" — reusing it as Pause makes a
 *    paused action read as a finished one everywhere. The active-until window is
 *    the honest pause and lives in the form. See actionModel's header.
 *  - **A bridge link.** The shell has no per-bridge route, so the bridge is named
 *    rather than linked somewhere that does not land on it.
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
  ResourceDetailHeader,
  ResourceSectionCard,
  StatusPill,
  Text,
} from '@ui';
import {
  parseBlackoutDates,
  useDeleteActionMutation,
  useFetchActionQuery,
  useRunActionMutation,
  type Action,
} from '../../api/endpoints/actions';
import { calculateNextRuns, describeCron, formatInTimeZone, timeZoneLabel } from './scheduleUtils';
import { bridgeLabel, projectLabel, useActionCatalog, type ActionCatalog } from './actionCatalog';
import {
  VERB_LABEL,
  absoluteRun,
  absoluteTime,
  actionEditHref,
  actionErrorText,
  actionState,
  actionTitle,
  actionViewHref,
  isScheduled,
  navigateTo,
  relativeTime,
  scheduleLabel,
  stateLabel,
  stateTone,
  targetMode,
  verbsForState,
  type ActionVerb,
} from './actionModel';

/* ------------------------------------------------------------------ *
 * ResizeObserver-based wide detection (same as AgentDetail)
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

export function useActionDetail(actionId: string, onAfterVerb?: (verb: ActionVerb) => void) {
  const query = useFetchActionQuery({ id: actionId }, { skip: !actionId });
  const [runAction] = useRunActionMutation();
  const [deleteAction] = useDeleteActionMutation();
  const [busy, setBusy] = React.useState<ActionVerb | ''>('');
  const [actionError, setActionError] = React.useState('');
  const [runNotice, setRunNotice] = React.useState('');

  const record: Action | null = (query.data?.action as Action | null) || null;

  const runVerb = React.useCallback(
    async (verb: ActionVerb) => {
      if (verb === 'edit') {
        navigateTo(actionEditHref(actionId));
        return;
      }
      setBusy(verb);
      setActionError('');
      setRunNotice('');
      try {
        if (verb === 'run') {
          await runAction({ id: actionId }).unwrap();
          setRunNotice('Dispatched. The run happens on the bridge — this page will show it as in flight once the lease is taken.');
        } else {
          await deleteAction({ id: actionId }).unwrap();
        }
        onAfterVerb?.(verb);
      } catch (err) {
        setActionError(actionErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this action.`));
      } finally {
        setBusy('');
      }
    },
    [actionId, deleteAction, onAfterVerb, runAction],
  );

  return { query, record, busy, actionError, runNotice, dismissRunNotice: () => setRunNotice(''), runVerb };
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

export function ActionDetailActions({
  record,
  busy,
  onVerb,
}: {
  record: Action;
  busy: ActionVerb | '';
  onVerb: (verb: ActionVerb) => void;
}) {
  const verbs = verbsForState(actionState(record));
  // Edit is the primary and gets its own button on desktop; everything else lives in
  // the menu. Run and Delete are NOT duplicated into the mobile bar below — Memory
  // shipped two Approve buttons on one phone screen by doing exactly that.
  const menuVerbs = verbs.filter((verb) => verb !== 'edit');

  return (
    <>
      {verbs.includes('edit') ? (
        <span className="hidden md:contents">
          <ActionButton
            label="Edit"
            variant="primary"
            data-debug-id="action-view-edit"
            onClick={() => onVerb('edit')}
          />
        </span>
      ) : null}
      {menuVerbs.length ? (
        <Menu
          label="Action actions"
          align="end"
          trigger={
            <ActionButton
              icon="more-horizontal"
              label="More"
              iconOnly
              aria-label="Action actions"
              loading={Boolean(busy)}
              data-debug-id="action-view-menu"
            />
          }
        >
          {menuVerbs.map((verb) => (
            <MenuItem
              key={verb}
              danger={verb === 'delete'}
              data-debug-id={`action-view-${verb}`}
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

/** The meta line under the title: schedule · state · next run. */
export function ActionDetailMeta({ record }: { record: Action }) {
  const state = actionState(record);
  const scheduled = isScheduled(record);
  return (
    <div className="flex flex-wrap items-center gap-2" data-debug-id="action-view-meta">
      <Badge data-debug-id="action-view-schedule-pill">{scheduleLabel(record)}</Badge>
      {state !== 'active' ? (
        <StatusPill tone={stateTone(state)} data-debug-id="action-view-state">{stateLabel(state)}</StatusPill>
      ) : null}
      {scheduled ? (
        <Text as="span" role="body-sm" tone="muted" data-debug-id="action-view-next-run">
          {/* An em-dash after "Next run" reads as a missing value rather than a
              state. Until the bridge syncs, the honest sentence is that there is
              no computed time yet. */}
          {record.target_run_at
            ? `Next run ${absoluteRun(record.target_run_at, record.timezone)}`
            : 'Next run not computed yet'}
        </Text>
      ) : (
        <Text as="span" role="body-sm" tone="muted">Runs only when you run it</Text>
      )}
    </div>
  );
}

export function ActionDetailHeader({
  record,
  busy,
  onVerb,
  onBack,
  alert,
}: {
  record: Action;
  busy: ActionVerb | '';
  onVerb: (verb: ActionVerb) => void;
  onBack?: () => void;
  alert?: React.ReactNode;
}) {
  const state = actionState(record);
  const scheduled = isScheduled(record);
  const title = actionTitle(record);

  return (
    <ResourceDetailHeader
      dataDebugId="action-pane-header"
      title={
        <a
          href={actionViewHref(record.id)}
          data-debug-id="action-pane-title"
          className="rounded-[var(--radius-sm)] hover:underline focus-visible:shadow-focus focus-visible:outline-none"
        >
          {title}
        </a>
      }
      id={record.id}
      status={
        state !== 'active' ? (
          <StatusPill tone={stateTone(state)} data-debug-id="action-view-state">
            {stateLabel(state)}
          </StatusPill>
        ) : undefined
      }
      badges={<Badge data-debug-id="action-view-schedule-pill">{scheduleLabel(record)}</Badge>}
      timestamp={
        scheduled ? (
          <Text as="span" role="body-sm" tone="muted" data-debug-id="action-view-next-run">
            {record.target_run_at
              ? `Next run ${absoluteRun(record.target_run_at, record.timezone)}`
              : 'Next run not computed yet'}
          </Text>
        ) : (
          <Text as="span" role="body-sm" tone="muted">Runs only when you run it</Text>
        )
      }
      alert={alert}
      onBack={onBack}
      actions={<ActionDetailActions record={record} busy={busy} onVerb={onVerb} />}
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
function TargetLink({
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

function TargetCard({ record, catalog }: { record: Action; catalog: ActionCatalog }) {
  const mode = targetMode(record);
  const instanceId = String(record.target_instance_id || '');
  const agentId = String(record.target_agent_id || '');
  const instance = catalog.instances.byId.get(instanceId);
  const agent = catalog.agents.byId.get(agentId);
  const bridge = bridgeLabel(record.target_bridge_id, catalog);
  const project = projectLabel(record.target_project_id, catalog);

  return (
    <Card
      title="Target"
      helper={
        mode === 'instance'
          ? 'This action runs against one specific instance.'
          : 'This action targets an agent identity. The scheduler finds or launches an instance on the bridge when it fires.'
      }
      debugId="action-view-target-card"
    >
      <div className="flex flex-col gap-2">
        {mode === 'instance' ? (
          <TargetLink
            label="Instance"
            value={instance?.label || instanceId}
            sub={instance?.sub || undefined}
            href={instance?.href}
            debugId="action-view-target-instance"
          />
        ) : (
          <>
            <TargetLink
              label="Agent"
              value={agent?.label || agentId || '—'}
              sub={agent?.sub || undefined}
              href={agent?.href}
              debugId="action-view-target-agent"
            />
            {/* No per-bridge route exists in the shell, so this is named, not linked. */}
            <DetailRow label="Bridge">
              <Text as="div" role="body-sm" data-debug-id="action-view-target-bridge">{bridge || '—'}</Text>
            </DetailRow>
            {record.target_provider ? (
              <DetailRow label="Provider">
                <Text as="div" role="body-sm">{record.target_provider}</Text>
              </DetailRow>
            ) : null}
            {record.target_model ? (
              <DetailRow label="Model">
                <Text as="div" role="body-sm">{record.target_model}</Text>
              </DetailRow>
            ) : null}
            {record.target_project_id ? (
              <TargetLink
                label="Project"
                value={project}
                href={catalog.projects.byId.get(String(record.target_project_id))?.href}
                debugId="action-view-target-project"
              />
            ) : null}
            <DetailRow label="Instance strategy">
              <Text as="div" role="body-sm" data-debug-id="action-view-strategy">
                {record.instance_strategy === 'fresh_per_run'
                  ? 'A fresh instance per run — the previous one is reaped'
                  : 'Reuse an instance across runs'}
              </Text>
            </DetailRow>
            {record.last_spawned_instance_id ? (
              <TargetLink
                label="Last spawned instance"
                value={
                  catalog.instances.byId.get(String(record.last_spawned_instance_id))?.label ||
                  String(record.last_spawned_instance_id)
                }
                href={catalog.instances.byId.get(String(record.last_spawned_instance_id))?.href}
                debugId="action-view-last-spawned"
              />
            ) : null}
          </>
        )}
      </div>
    </Card>
  );
}

const NEXT_RUN_PREVIEW = 3;

function ScheduleCard({ record }: { record: Action }) {
  const cron = String(record.cron_expr || '').trim();
  const timezone = String(record.timezone || '').trim() || 'UTC';
  const blackouts = parseBlackoutDates(record.blackout_dates);

  const upcoming = React.useMemo(() => {
    if (!cron) return [];
    try {
      return calculateNextRuns(
        cron,
        timezone,
        blackouts,
        NEXT_RUN_PREVIEW,
        new Date(),
        record.active_from,
        record.active_until,
      );
    } catch {
      // A cron the hub accepted but this client cannot project should not take the
      // page down — the expression itself is still shown above.
      return [];
    }
  }, [cron, timezone, blackouts, record.active_from, record.active_until]);

  if (!isScheduled(record)) {
    return (
      <Card
        title="Schedule"
        helper="This action has no schedule — it runs only when you run it."
        debugId="action-view-schedule-card"
      >
        <Text as="div" role="body-sm" tone="muted" data-debug-id="action-view-schedule-none">
          On demand.
        </Text>
      </Card>
    );
  }

  return (
    <Card title="Schedule" debugId="action-view-schedule-card">
      <div className="flex flex-col gap-2">
        {cron ? (
          <>
            <DetailRow label="Runs">
              <Text as="div" role="body-sm" data-debug-id="action-view-cron-description">{describeCron(cron)}</Text>
            </DetailRow>
            <DetailRow label="Expression">
              <div className="flex items-center gap-2">
                <Text as="span" role="body-sm" className="font-mono">{cron}</Text>
                <CopyButton value={cron} label="Copy cron expression" debugId="action-view-copy-cron" />
              </div>
            </DetailRow>
          </>
        ) : (
          <DetailRow label="Interval">
            {/* `interval` is the legacy scheduling field. It is shown where an action
                still carries one, but the form offers no way to create a new one. */}
            <Text as="div" role="body-sm" data-debug-id="action-view-interval">
              Every {record.interval} <Text as="span" role="caption" tone="muted">(legacy interval)</Text>
            </Text>
          </DetailRow>
        )}

        <DetailRow label="Timezone">
          <Text as="div" role="body-sm" data-debug-id="action-view-timezone">{timezone}</Text>
        </DetailRow>

        <DetailRow label="Next run">
          <Text as="div" role="body-sm" data-debug-id="action-view-next-run-absolute">
            {record.target_run_at
              ? absoluteRun(record.target_run_at, timezone)
              : 'Not computed yet — the bridge sets this when it next syncs.'}
          </Text>
        </DetailRow>

        {upcoming.length > 1 ? (
          <DetailRow label="Then">
            <ul className="flex flex-col" data-debug-id="action-view-upcoming">
              {upcoming.slice(1).map((date, i) => (
                <li key={i}>
                  <Text as="span" role="body-sm" tone="muted">
                    {formatInTimeZone(date, timezone)} ({timeZoneLabel(date, timezone)})
                  </Text>
                </li>
              ))}
            </ul>
          </DetailRow>
        ) : null}

        {record.active_from || record.active_until ? (
          <DetailRow label="Active window">
            <Text as="div" role="body-sm" data-debug-id="action-view-window">
              {record.active_from ? absoluteTime(record.active_from) : 'No start'}
              {' → '}
              {record.active_until ? absoluteTime(record.active_until) : 'No end'}
            </Text>
          </DetailRow>
        ) : null}

        {blackouts.length ? (
          <DetailRow label="Blackout dates">
            <div className="flex flex-wrap gap-1.5" data-debug-id="action-view-blackouts">
              {blackouts.map((date) => (
                <Badge key={date}>{date}</Badge>
              ))}
            </div>
          </DetailRow>
        ) : null}
      </div>
    </Card>
  );
}

/* ------------------------------------------------------------------ *
 * The body
 * ------------------------------------------------------------------ */

export function ActionDetailBody({
  record,
  actionError,
  runNotice,
  wide,
}: {
  record: Action;
  actionError?: string;
  runNotice?: string;
  wide: boolean;
}) {
  const catalog = useActionCatalog();
  const state = actionState(record);

  const main = (
    <>
      <Card
        title="Prompt"
        helper="Sent to the agent exactly as written — this is not rendered markdown."
        action={<CopyButton value={record.prompt_text} label="Copy prompt" debugId="action-view-copy-prompt" />}
        debugId="action-view-prompt-card"
      >
        {record.prompt_text ? (
          // Amendment 4: the page must never scroll horizontally. `pre-wrap` +
          // `break-words` makes this pre WRAP rather than overflow, so it needs no
          // scroll region of its own and introduces no nested scroller.
          <pre
            data-debug-id="action-view-prompt"
            className="whitespace-pre-wrap break-words font-mono text-body-sm text-primary"
          >
            {record.prompt_text}
          </pre>
        ) : (
          <Text as="div" role="body-sm" tone="muted" data-debug-id="action-view-prompt-empty">
            No prompt set.
          </Text>
        )}
      </Card>

      <ScheduleCard record={record} />
    </>
  );

  const rail = (
    <>
      <TargetCard record={record} catalog={catalog} />
      <Card title="Details" debugId="action-view-details-card">
        <div className="flex flex-col gap-2">
          <DetailRow label="State">
            <Text as="div" role="body-sm">{stateLabel(state)}</Text>
          </DetailRow>
          {record.leased_at ? (
            <DetailRow label="Leased">
              <Text as="div" role="body-sm">{`${absoluteTime(record.leased_at)} (${relativeTime(record.leased_at)})`}</Text>
            </DetailRow>
          ) : null}
          <DetailRow label="Created">
            <Text as="div" role="body-sm">{`${absoluteTime(record.created_at)} (${relativeTime(record.created_at)})`}</Text>
          </DetailRow>
          <DetailRow label="Updated">
            <Text as="div" role="body-sm">{`${absoluteTime(record.updated_at)} (${relativeTime(record.updated_at)})`}</Text>
          </DetailRow>
          <DetailRow label="Action ID">
            <div className="flex items-center gap-2">
              <Text as="span" role="body-sm" className="font-mono">{record.id}</Text>
              <CopyButton value={record.id} label="Copy action ID" debugId="action-view-copy-id" />
            </div>
          </DetailRow>
        </div>
      </Card>
    </>
  );

  return (
    <div data-debug-id="action-view-page" className="flex w-full min-w-0 flex-col gap-3">
      {actionError ? <Alert tone="danger" title="That didn't work">{actionError}</Alert> : null}
      {runNotice ? <Alert tone="info" title="Run requested">{runNotice}</Alert> : null}
      {state === 'in_flight' ? (
        <Alert tone="warning" title="This action is running now">
          The scheduler holds a lease on it. Run now is unavailable until the run finishes.
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
 * The mobile action bar: Edit, full width, docked above the app's bottom tab nav.
 * Run and Delete are NOT here — they stay in the `…` menu, so no verb appears twice
 * on one phone screen (Amendment 6's two-Approve-buttons rule).
 */
export function ActionDetailMobileActions({
  record,
  onVerb,
}: {
  record: Action;
  onVerb: (verb: ActionVerb) => void;
}) {
  if (!verbsForState(actionState(record)).includes('edit')) return null;
  return (
    <div
      className="fixed inset-x-0 app-viewport-bottom z-sticky border-t border-subtle bg-surface px-4 pb-[max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px))] pt-2 md:hidden"
      data-debug-id="action-view-mobile-bar"
    >
      <Button
        variant="primary"
        width="full"
        data-debug-id="action-view-mobile-edit"
        onClick={() => onVerb('edit')}
      >
        Edit
      </Button>
    </div>
  );
}

/** Skeleton for the two-pane pane while the detail query is loading. */
export function ActionDetailPaneSkeleton() {
  return (
    <div className="flex flex-col gap-3" role="status" aria-busy="true" data-debug-id="action-pane-skeleton">
      <span className="sr-only">Loading action…</span>
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

export { actionTitle };
