/**
 * AgentDetail — the agent view's guts, rendered as a full page AND as the
 * two-pane right-hand pane. Modeled after ProjectDetail.
 * ------------------------------------------------------------------
 * One implementation, two mounts, so the page and the pane cannot drift apart.
 *
 * Cards: Instructions · Details · Instances · Memory.
 *
 * What is deliberately absent:
 *  - **Created.** `created_at` is not serialised by `write_agent_json`
 *    (`agent_handlers.odin:338-351`). Amendment 6: do not render what the
 *    API does not send.
 *  - **Owner.** Same reason — `owner_user_id` is never emitted.
 *  - **Restore / Unarchive.** No endpoint reverses an archive.
 *  - **Delete.** There is no DELETE route for an agent identity at all.
 *
 * Agent→Memories: kept (Amendment 9). The asymmetric ruling removed the
 * Project→Agent link; the Agent→Memory link is intentionally preserved.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  EmptyState,
  Icon,
  IconButton,
  Menu,
  MenuItem,
  Panel,
  ResourceDetailHeader,
  ResourceSectionCard,
  Spinner,
  StatusPill,
  Text,
  useViewport,
  type Tone,
} from '@ui';
import MarkdownBody from '../MarkdownBody';
import {
  agentErrorText,
  normalizeAgent,
  useArchiveAgentIdentityMutation,
  useFetchAgentIdentityQuery,
  useListAgentInstancesQuery,
  useFetchAgentInstanceQuery,
  useStopAgentInstanceMutation,
  useRestartAgentInstanceMutation,
  type AgentRecord,
} from '../../api/endpoints/agents';
import { useListProjectsQuery } from '../../api/endpoints/projects';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { VaultText } from '../vault/VaultText';
import PaginatedMemoriesSection from '../shared/PaginatedMemoriesSection';
import { buildRouteHash } from '../../utils/appLocation';
import { agentFailureSummary } from '../../utils/agentStatus';
import { AgentFailureNotice } from './AgentFailureNotice';
import {
  VERB_LABEL,
  absoluteTime,
  agentEditHref,
  agentListHref,
  agentState,
  agentTitle,
  agentViewHref,
  navigateTo,
  relativeTime,
  stateLabel,
  stateTone,
  verbsForState,
  type AgentVerb,
} from './agentModel';

/* ------------------------------------------------------------------ *
 * ResizeObserver-based wide detection (copied from ProjectDetail)
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

export function useAgentDetail(agentId: string, onAfterVerb?: (verb: AgentVerb) => void) {
  const query = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const [archiveAgent] = useArchiveAgentIdentityMutation();
  const [busy, setBusy] = React.useState<AgentVerb | ''>('');
  const [actionError, setActionError] = React.useState('');

  const record: AgentRecord | null = React.useMemo(() => {
    const raw = query.data?.agent;
    return raw ? normalizeAgent(raw) : null;
  }, [query.data]);

  const runVerb = React.useCallback(
    async (verb: AgentVerb) => {
      if (verb === 'edit') {
        navigateTo(agentEditHref(agentId));
        return;
      }
      setBusy(verb);
      setActionError('');
      try {
        await archiveAgent({ agentId }).unwrap();
        onAfterVerb?.(verb);
      } catch (err) {
        setActionError(agentErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this agent.`));
      } finally {
        setBusy('');
      }
    },
    [archiveAgent, onAfterVerb, agentId],
  );

  return { query, record, busy, actionError, runVerb };
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

export function AgentDetailActions({
  record,
  busy,
  onVerb,
}: {
  record: AgentRecord;
  busy: AgentVerb | '';
  onVerb: (verb: AgentVerb) => void;
}) {
  const verbs = verbsForState(agentState(record));
  const menuVerbs = verbs.filter((verb) => verb !== 'edit');

  return (
    <>
      {verbs.includes('edit') ? (
        <span className="hidden md:contents">
          <ActionButton
            label="Edit"
            variant="primary"
            data-debug-id="agent-view-edit"
            onClick={() => onVerb('edit')}
          />
        </span>
      ) : null}
      {menuVerbs.length ? (
        <Menu
          label="Agent actions"
          align="end"
          trigger={
            <ActionButton
              icon="more-horizontal"
              label="More"
              iconOnly
              aria-label="Agent actions"
              data-debug-id="agent-view-menu"
            />
          }
        >
          {menuVerbs.map((verb) => (
            <MenuItem
              key={verb}
              danger={verb === 'archive'}
              data-debug-id={`agent-view-${verb}`}
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

/** The meta line under the title: state · Updated <relative>. */
export function AgentDetailMeta({ record }: { record: AgentRecord }) {
  const state = agentState(record);
  return (
    <div className="flex flex-wrap items-center gap-2" data-debug-id="agent-view-meta">
      {state === 'archived' ? (
        <StatusPill tone={stateTone(state)} data-debug-id="agent-view-state">{stateLabel(state)}</StatusPill>
      ) : null}
      <Text as="span" role="body-sm" tone="muted" title={absoluteTime(record.updatedAt)}>
        Updated {relativeTime(record.updatedAt)}
      </Text>
    </div>
  );
}

export function AgentDetailHeader({
  record,
  busy,
  onVerb,
  onBack,
  alert,
}: {
  record: AgentRecord;
  busy: AgentVerb | '';
  onVerb: (verb: AgentVerb) => void;
  onBack?: () => void;
  alert?: React.ReactNode;
}) {
  const state = agentState(record);
  const title = agentTitle(record);

  return (
    <ResourceDetailHeader
      dataDebugId="agent-pane-header"
      title={
        <a
          href={agentViewHref(record.agentId)}
          data-debug-id="agent-pane-title"
          className="rounded-[var(--radius-sm)] hover:underline focus-visible:shadow-focus focus-visible:outline-none"
        >
          {title}
        </a>
      }
      id={record.agentId}
      status={
        state === 'archived' ? (
          <StatusPill tone={stateTone(state)} data-debug-id="agent-view-state">
            {stateLabel(state)}
          </StatusPill>
        ) : undefined
      }
      timestamp={`Updated ${relativeTime(record.updatedAt)}`}
      timestampTooltip={absoluteTime(record.updatedAt)}
      alert={alert}
      onBack={onBack}
      actions={<AgentDetailActions record={record} busy={busy} onVerb={onVerb} />}
    />
  );
}

/* ------------------------------------------------------------------ *
 * Cards
 * ------------------------------------------------------------------ */

export function Card({
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

export function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <Text as="div" role="label" tone="muted">{label}</Text>
      {children}
    </div>
  );
}

/** One linked-resource list — degrades rather than errors (same as ProjectDetail). */
function LinkedList({
  items,
  loading,
  failed,
  emptyLabel,
  debugId,
}: {
  items: { id: string; label: string; sub?: string; href: string }[];
  loading: boolean;
  failed: boolean;
  emptyLabel: string;
  debugId: string;
}) {
  if (loading) {
    return (
      <div className="flex items-center gap-2" data-debug-id={`${debugId}-loading`}>
        <Spinner size="sm" />
        <Text as="span" role="body-sm" tone="muted">Loading…</Text>
      </div>
    );
  }
  if (failed) {
    return (
      <Text as="div" role="body-sm" tone="muted" data-debug-id={`${debugId}-failed`}>
        Couldn&apos;t load these right now.
      </Text>
    );
  }
  if (items.length === 0) {
    return (
      <Text as="div" role="body-sm" tone="muted" data-debug-id={`${debugId}-empty`}>
        {emptyLabel}
      </Text>
    );
  }
  return (
    <ul className="flex flex-col" data-debug-id={debugId}>
      {items.map((item) => (
        <li key={item.id} className="border-t border-subtle py-1.5 first:border-0 first:pt-0">
          <a
            href={item.href}
            data-debug-id={`${debugId}-${item.id}`}
            className="flex min-w-0 flex-col rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Text as="span" role="body-sm" className="truncate">{item.label}</Text>
            {item.sub ? <Text as="span" role="caption" tone="muted" className="truncate">{item.sub}</Text> : null}
          </a>
        </li>
      ))}
    </ul>
  );
}

const LINKED_PREVIEW = 5;

function InstancesCard({ agentId }: { agentId: string }) {
  const instancesQuery = useListAgentInstancesQuery({ agentId, limit: LINKED_PREVIEW }, { skip: !agentId });
  const rawInstances = (instancesQuery.data?.instances || []).slice(0, LINKED_PREVIEW);

  const instances = rawInstances.map((inst: any) => ({
    id: String(inst.agent_instance_id || inst.agentInstanceId || inst.id || ''),
    label: String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '').slice(0, 24),
    sub: String(inst.runtime_status || inst.runtimeStatus || ''),
    href: buildRouteHash(`/chains/${encodeURIComponent(String(inst.chain_id || inst.chainId || ''))}`, ''),
  }));

  return (
    <Card
      title="Instances"
      helper="Currently running and recently stopped instances."
      debugId="agent-view-instances-card"
    >
      <LinkedList
        items={instances}
        loading={instancesQuery.isLoading}
        failed={Boolean(instancesQuery.error)}
        emptyLabel="No instances right now."
        debugId="agent-view-instances"
      />
    </Card>
  );
}

/* ------------------------------------------------------------------ *
 * The body
 * ------------------------------------------------------------------ */

export function AgentDetailBody({
  record,
  actionError,
  wide,
}: {
  record: AgentRecord;
  actionError?: string;
  wide: boolean;
}) {
  const instructions = record.instructions;

  const main = (
    <>
      <Card title="Instructions" debugId="agent-view-instructions-card">
        {instructions ? (
          <MarkdownBody source={instructions} copyAll={false} data-debug-id="agent-view-instructions" />
        ) : (
          <Text as="div" role="body-sm" tone="muted" data-debug-id="agent-view-instructions-empty">
            No instructions set.
          </Text>
        )}
      </Card>

      <InstancesCard agentId={record.agentId} />
    </>
  );

  const rail = (
    <Card title="Details" debugId="agent-view-details-card">
      <div className="flex flex-col gap-2">
        {record.templateId ? (
          <DetailRow label="Template">
            <Text as="div" role="body-sm" className="font-mono">{record.templateId}</Text>
          </DetailRow>
        ) : null}
        <DetailRow label="Slug">
          <Text as="div" role="body-sm" className="font-mono">{record.slug || '—'}</Text>
        </DetailRow>
        <DetailRow label="Updated">
          <Text as="div" role="body-sm">{`${absoluteTime(record.updatedAt)} (${relativeTime(record.updatedAt)})`}</Text>
        </DetailRow>
        <DetailRow label="Agent ID">
          <div className="flex items-center gap-2">
            <Text as="span" role="body-sm" className="font-mono">{record.agentId}</Text>
            <CopyButton value={record.agentId} label="Copy agent ID" debugId="agent-view-copy-id" />
          </div>
        </DetailRow>
      </div>
    </Card>
  );

  return (
    <div data-debug-id="agent-view-page" className="flex w-full min-w-0 flex-col gap-3">
      {actionError ? <Alert tone="danger" title="That didn't work">{actionError}</Alert> : null}
      {agentState(record) === 'archived' ? (
        <Alert tone="warning" title="This agent is archived">
          It still works — running instances and memories are untouched. Heimdall can&apos;t un-archive from here.
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
      {/* Amendment 9: Agent→Memories link kept. Full-width below the layout so the
          intersection-observer sentinel lives in the page's main scroll flow. */}
      <PaginatedMemoriesSection agentId={record.agentId} debugPrefix="agent-view-memories" />
    </div>
  );
}

/**
 * The mobile action bar: Edit, full width, docked above the app's bottom tab nav.
 * Archive is NOT here — destructive verbs stay in the `…` menu.
 */
export function AgentDetailMobileActions({
  record,
  onVerb,
}: {
  record: AgentRecord;
  onVerb: (verb: AgentVerb) => void;
}) {
  if (!verbsForState(agentState(record)).includes('edit')) return null;
  return (
    <div
      className="fixed inset-x-0 app-viewport-bottom z-sticky border-t border-subtle bg-surface px-4 pb-[max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px))] pt-2 md:hidden"
      data-debug-id="agent-view-mobile-bar"
    >
      <Button
        variant="primary"
        width="full"
        data-debug-id="agent-view-mobile-edit"
        onClick={() => onVerb('edit')}
      >
        Edit
      </Button>
    </div>
  );
}

/**
 * Skeleton for the two-pane pane while the detail query is loading.
 * Mirrors the real layout's card structure so there is no shift on load.
 */
export function AgentDetailPaneSkeleton() {
  return (
    <div className="flex flex-col gap-3" role="status" aria-busy="true" data-debug-id="agent-pane-skeleton">
      <span className="sr-only">Loading agent…</span>
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

/* ------------------------------------------------------------------ *
 * Live Instance Detail Pane
 * ------------------------------------------------------------------ */

export function LiveInstanceDetailPane({
  instanceId,
  onStopped,
}: {
  instanceId: string;
  onStopped?: () => void;
}) {
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  const instanceQuery = useFetchAgentInstanceQuery({ instanceId }, { skip: !instanceId });
  const listQuery = useListAgentInstancesQuery({ limit: 200 }, { skip: Boolean(instanceQuery.data?.instance) });
  const inst = instanceQuery.data?.instance || (listQuery.data?.instances || []).find(
    (i: any) => (i.agent_instance_id || i.instanceId || i.id) === instanceId,
  );

  const agentId = String(inst?.agent_id || inst?.agentId || '');
  const chainId = String(inst?.chain_id || inst?.chainId || '');
  const projectId = String(inst?.project_id || inst?.projectId || '');
  const projectPath = String(inst?.project_path || inst?.projectPath || '');
  const displayName = String(inst?.display_name || inst?.displayName || agentId || instanceId);
  const runtimeStatus = String(inst?.runtime_status || inst?.runtimeStatus || '');
  const activityStatus = String(inst?.activity_status || inst?.activityStatus || '');
  const provider = String(inst?.provider || '');
  const model = String(inst?.model || '');
  const currentTaskId = String(inst?.current_task_id || inst?.currentTaskId || '');
  const currentTaskRole = String(inst?.current_task_role || inst?.currentTaskRole || '');
  const bridgeId = String(inst?.bridge_id || inst?.bridgeId || '');
  const startedAt = String(inst?.started_at || inst?.startedAt || '');
  const lastSeenAt = String(inst?.last_seen_at || inst?.lastSeenAt || '');

  const projectsQuery = useListProjectsQuery();
  const project = (projectsQuery.data?.projects || []).find(
    (p: any) => (p.project_id || p.projectId || p.id) === projectId,
  );
  const projectName = project?.name || projectId;
  const displayProjectPath = projectPath || project?.default_path || project?.defaultPath || '';

  const chainQuery = useFetchTaskChainDetailQuery({ chainId }, { skip: !chainId });
  const chain = chainQuery.data?.chain;
  const chainTitle = chain?.title || chain?.name || chainId;

  const agentIdentityQuery = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentRecord = agentIdentityQuery.data?.agent ? normalizeAgent(agentIdentityQuery.data.agent) : null;
  const agentDisplayName = agentRecord?.name || agentId;

  const [restartInstance, { isLoading: isRestarting }] = useRestartAgentInstanceMutation();
  const [stopInstance, { isLoading: isStopping }] = useStopAgentInstanceMutation();
  const [actionError, setActionError] = React.useState('');
  const [actionSuccess, setActionSuccess] = React.useState('');

  const handleRestart = async () => {
    setActionError('');
    setActionSuccess('');
    try {
      await restartInstance({ agentId, instanceId }).unwrap();
      setActionSuccess('Restart initiated successfully.');
    } catch (err: any) {
      setActionError(agentErrorText(err, "Couldn't restart this instance."));
    }
  };

  const handleStop = async () => {
    setActionError('');
    setActionSuccess('');
    try {
      await stopInstance({ agentId, instanceId }).unwrap();
      setActionSuccess('Instance stopped.');
      onStopped?.();
    } catch (err: any) {
      setActionError(agentErrorText(err, "Couldn't stop this instance."));
    }
  };

  if (instanceQuery.isLoading && !inst) {
    return <AgentDetailPaneSkeleton />;
  }

  if (!instanceQuery.isLoading && !inst) {
    return (
      <EmptyState
        data-debug-id="live-instance-missing"
        icon="search"
        title="Instance not found"
        description={`Could not find live instance "${instanceId}".`}
        action={<Button variant="secondary" onClick={() => navigateTo(agentListHref({ tab: 'live', q: '' }))}>Back to Live Instances</Button>}
      />
    );
  }

  const failure = runtimeStatus.toLowerCase() === 'failed' ? agentFailureSummary(inst?.last_error) : null;
  const runtimeTone: Tone = failure ? failure.tone : (runtimeStatus.toLowerCase() === 'running' || runtimeStatus.toLowerCase() === 'ready')
    ? 'success'
    : (runtimeStatus.toLowerCase() === 'starting' || runtimeStatus.toLowerCase() === 'launching')
      ? 'warning'
      : (runtimeStatus.toLowerCase() === 'stopped' || runtimeStatus.toLowerCase() === 'failed' || runtimeStatus.toLowerCase() === 'terminated')
        ? 'danger'
        : 'neutral';

  const activityTone: Tone = (activityStatus.toLowerCase() === 'busy' || activityStatus.toLowerCase() === 'working')
    ? 'info'
    : 'neutral';

  const contextLinksCard = (
    <Card title="Context Links" helper="Project, task chain, and identity running this instance." debugId="live-instance-links-card">
      <div className="flex flex-col gap-3">
        <DetailRow label="Project">
          {projectId ? (
            <a
              href={buildRouteHash('/projects/' + encodeURIComponent(projectId), '')}
              data-debug-id="live-instance-project-link"
              className="group block min-w-0"
            >
              <Text as="div" role="body" className="font-medium text-primary hover:underline truncate">
                {projectName}
              </Text>
              {displayProjectPath ? (
                <Text as="div" role="caption" tone="muted" className="truncate" title={displayProjectPath}>
                  {displayProjectPath}
                </Text>
              ) : null}
            </a>
          ) : (
            <Text role="body" tone="muted">—</Text>
          )}
        </DetailRow>

        <DetailRow label="Task Chain">
          {chainId ? (
            <a
              href={buildRouteHash('/chains/' + encodeURIComponent(chainId), '')}
              data-debug-id="live-instance-chain-link"
              className="group block min-w-0"
            >
              <Text as="div" role="body" className="font-medium text-primary hover:underline truncate">
                <VaultText value={chainTitle} fallback={chainId} />
              </Text>
              <Text as="div" role="caption" tone="muted" className="truncate font-mono">
                {chainId}
              </Text>
            </a>
          ) : (
            <Text role="body" tone="muted">—</Text>
          )}
        </DetailRow>

        <DetailRow label="Agent Identity">
          {agentId ? (
            <a
              href={agentViewHref(agentId)}
              data-debug-id="live-instance-agent-link"
              className="group block min-w-0"
            >
              <Text as="div" role="body" className="font-medium text-primary hover:underline truncate">
                {agentDisplayName}
              </Text>
              <Text as="div" role="caption" tone="muted" className="truncate font-mono">
                {agentId}
              </Text>
            </a>
          ) : (
            <Text role="body" tone="muted">—</Text>
          )}
        </DetailRow>
      </div>
    </Card>
  );

  const runtimeDetailsCard = (
    <Card title="Runtime Details" helper="Live status, task assignment, and runtime metadata." debugId="live-instance-details-card">
      <div className="flex flex-col gap-2.5">
        <DetailRow label="Runtime Status">
          <div className="flex items-center gap-2 mt-0.5">
            <StatusPill tone={runtimeTone} data-debug-id="live-instance-runtime-status">
              {runtimeStatus || 'unknown'}
            </StatusPill>
            {activityStatus ? (
              <StatusPill tone={activityTone} data-debug-id="live-instance-activity-status">
                {activityStatus}
              </StatusPill>
            ) : null}
          </div>
          <AgentFailureNotice runtimeStatus={runtimeStatus} lastError={inst?.last_error} />
        </DetailRow>

        <DetailRow label="Provider & Model">
          <div className="flex items-center gap-1.5 mt-0.5">
            {provider ? <Badge data-debug-id="live-instance-provider">{provider}</Badge> : null}
            {model ? <Badge data-debug-id="live-instance-model">{model}</Badge> : null}
            {!provider && !model ? <Text role="body" tone="muted">—</Text> : null}
          </div>
        </DetailRow>

        <DetailRow label="Current Task">
          {currentTaskId ? (
            <div className="flex items-center gap-2 mt-0.5">
              <span className="font-mono text-body-sm" data-debug-id="live-instance-task-id">{currentTaskId}</span>
              {currentTaskRole ? <Badge data-debug-id="live-instance-task-role">{currentTaskRole}</Badge> : null}
            </div>
          ) : (
            <Text role="body" tone="muted">—</Text>
          )}
        </DetailRow>

        <DetailRow label="Bridge">
          {bridgeId ? (
            <span className="font-mono text-body-sm" data-debug-id="live-instance-bridge-id">{bridgeId}</span>
          ) : (
            <Text role="body" tone="muted">—</Text>
          )}
        </DetailRow>

        <DetailRow label="Started">
          <Text role="body-sm" tone="muted" title={absoluteTime(startedAt)} data-debug-id="live-instance-started">
            {startedAt ? `${relativeTime(startedAt)} (${absoluteTime(startedAt)})` : '—'}
          </Text>
        </DetailRow>

        <DetailRow label="Last Seen">
          <Text role="body-sm" tone="muted" title={absoluteTime(lastSeenAt)} data-debug-id="live-instance-last-seen">
            {lastSeenAt ? `${relativeTime(lastSeenAt)} (${absoluteTime(lastSeenAt)})` : '—'}
          </Text>
        </DetailRow>

        <DetailRow label="Instance ID">
          <div className="flex items-center gap-2 mt-0.5">
            <span className="font-mono text-body-sm truncate" data-debug-id="live-instance-id">{instanceId}</span>
            <CopyButton value={instanceId} label="Copy instance ID" debugId="live-instance-copy-id" />
          </div>
        </DetailRow>
      </div>
    </Card>
  );

  return (
    <div ref={paneRef} className="min-w-0 flex flex-col min-h-0 h-full overflow-hidden" data-debug-id="live-instance-detail-pane">
      <div className="mb-3 shrink-0">
        <ResourceDetailHeader
          dataDebugId="live-instance-header"
          title={<span data-debug-id="live-instance-title">{displayName}</span>}
          id={instanceId}
          status={
            <StatusPill tone={runtimeTone} data-debug-id="live-instance-header-status">
              {runtimeStatus || 'unknown'}
            </StatusPill>
          }
          badges={
            <>
              {provider ? <Badge data-debug-id="live-instance-header-provider">{provider}</Badge> : null}
              {model ? <Badge data-debug-id="live-instance-header-model">{model}</Badge> : null}
            </>
          }
          timestamp={startedAt ? `Started ${relativeTime(startedAt)}` : undefined}
          timestampTooltip={startedAt ? absoluteTime(startedAt) : undefined}
          actions={
            <div className="flex shrink-0 items-center gap-2">
              <Button
                variant="secondary"
                data-debug-id="live-instance-chat-link"
                leading={<Icon name="chat" size="sm" />}
                onClick={() => navigateTo(buildRouteHash('/conversations/' + encodeURIComponent(instanceId), ''))}
              >
                Open Chat
              </Button>
              <Button
                variant="secondary"
                data-debug-id="live-instance-restart-btn"
                loading={isRestarting}
                onClick={handleRestart}
              >
                Restart
              </Button>
              <Button
                variant="danger"
                data-debug-id="live-instance-stop-btn"
                loading={isStopping}
                onClick={handleStop}
              >
                Stop
              </Button>
            </div>
          }
        />
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto pr-1">
        <div className="flex flex-col gap-3">
          {actionError ? <Alert tone="danger" title="Operation failed">{actionError}</Alert> : null}
          {actionSuccess ? <Alert tone="success" title={actionSuccess} /> : null}
          {wide ? (
            <div className="flex min-w-0 items-start gap-3">
              <div className="flex min-w-0 flex-1 flex-col gap-3">{contextLinksCard}</div>
              <div className="flex min-w-0 flex-1 flex-col gap-3">{runtimeDetailsCard}</div>
            </div>
          ) : (
            <>
              {contextLinksCard}
              {runtimeDetailsCard}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
