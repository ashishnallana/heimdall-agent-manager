/**
 * ProjectDetail — the detail view's guts, rendered as a full page AND as the
 * two-pane right-hand pane.
 * ------------------------------------------------------------------
 * One implementation, two mounts, so the page and the pane cannot drift apart —
 * the Memory arrangement, inherited. `useProjectDetail` holds the data + verbs,
 * `ProjectDetailActions` is the header cluster, `ProjectDetailBody` is the stack of
 * surface cards.
 *
 * Cards: Overview (markdown description) · Bridge paths · Details · Linked
 * resources.
 *
 * What is deliberately absent, so nobody re-adds it:
 *  - **Created.** `created_at` is not serialised (`project_handlers.odin:77-79`),
 *    even though the list's cursor is keyed on it. Amendment 6: do not render a
 *    field the API does not send.
 *  - **Owner.** Same reason — `owner_user_id` is never emitted either.
 *  - **Restore / Unarchive.** No endpoint exists (`project_service.odin:245-250`,
 *    and `Update_Project_Input` has no `state`). A button that cannot work is worse
 *    than no button.
 *  - **Delete.** There is no DELETE route for a project at all
 *    (`wiring.odin:316-323`). Archive is the destructive verb, and it says what it
 *    does.
 *
 * Bridge paths are READ-ONLY here (REQ-UI-11): the card shows each bridge's path
 * and the hub's own validation verdict, and sends the user to the edit page to
 * change one. It is the one part of a project that is not a form field, because
 * each path is its own endpoint and only exists once the project does.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  Icon,
  IconButton,
  Link,
  Menu,
  MenuItem,
  Panel,
  ResourceDetailHeader,
  ResourceSectionCard,
  Spinner,
  StatusPill,
  Text,
  useViewport,
} from '@ui';
import MarkdownBody from '../MarkdownBody';
import { useSelector } from 'react-redux';
import { VaultText } from '../vault/VaultText';
import { isVaultArmored, decryptVaultText } from '../../utils/vaultContent';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import {
  projectErrorText,
  useArchiveProjectMutation,
  useFetchProjectQuery,
  normalizeProject,
  type ProjectBridgePath,
  type ProjectRecord,
} from '../../api/endpoints/projects';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListTaskChainsQuery } from '../../api/endpoints/tasks';
import PaginatedMemoriesSection from '../shared/PaginatedMemoriesSection';
import { buildRouteHash } from '../../utils/appLocation';
import {
  VERB_LABEL,
  absoluteTime,
  navigateTo,
  projectEditHref,
  projectState,
  projectTitle,
  projectViewHref,
  relativeTime,
  stateLabel,
  stateTone,
  vcsLabel,
  verbsForState,
  type ProjectVerb,
} from './projectModel';

/* ------------------------------------------------------------------ *
 * Data + verbs
 * ------------------------------------------------------------------ */

export function useProjectDetail(projectId: string, onAfterVerb?: (verb: ProjectVerb) => void) {
  const query = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const [archiveProject] = useArchiveProjectMutation();
  const [busy, setBusy] = React.useState<ProjectVerb | ''>('');
  const [actionError, setActionError] = React.useState('');

  // `fetchProject` returns `{ project, bridge_paths }`; normalise once here so the
  // whole detail works in the same camelCase shape the list rows use.
  const record: ProjectRecord | null = React.useMemo(() => {
    const raw = query.data?.project;
    return raw ? normalizeProject(raw) : null;
  }, [query.data]);

  const runVerb = React.useCallback(
    async (verb: ProjectVerb) => {
      if (verb === 'edit') {
        navigateTo(projectEditHref(projectId));
        return;
      }
      setBusy(verb);
      setActionError('');
      try {
        await archiveProject({ projectId }).unwrap();
        onAfterVerb?.(verb);
      } catch (err) {
        setActionError(projectErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this project.`));
      } finally {
        setBusy('');
      }
    },
    [archiveProject, onAfterVerb, projectId],
  );

  return { query, record, busy, actionError, runVerb };
}

/** A copy-to-clipboard affordance that says it worked. Inline with a card's label. */
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
 * The header's action cluster: Edit as the primary verb, Archive in the `…` menu.
 *
 * Edit is rendered on DESKTOP ONLY. Below `md` the same verb is the sticky bottom
 * bar (`ProjectDetailMobileActions`), and Amendment 6 is explicit about the failure
 * it prevents: a verb in both places puts two of the same button on one phone
 * screen. Archive is not duplicated — it stays in the menu at every width, because
 * a destructive verb should not be the easiest thing to hit with a thumb.
 */
export function ProjectDetailActions({
  record,
  busy,
  onVerb,
}: {
  record: ProjectRecord;
  busy: ProjectVerb | '';
  onVerb: (verb: ProjectVerb) => void;
}) {
  const verbs = verbsForState(projectState(record));
  const menuVerbs = verbs.filter((verb) => verb !== 'edit');

  return (
    <>
      {verbs.includes('edit') ? (
        <span className="hidden md:contents">
          <ActionButton
            label="Edit"
            variant="primary"
            data-debug-id="project-view-edit"
            onClick={() => onVerb('edit')}
          />
        </span>
      ) : null}
      {menuVerbs.length ? (
        <Menu
          label="Project actions"
          align="end"
          trigger={
            <ActionButton
              icon="more-horizontal"
              label="More"
              iconOnly
              aria-label="Project actions"
              data-debug-id="project-view-menu"
            />
          }
        >
          {menuVerbs.map((verb) => (
            <MenuItem
              key={verb}
              danger={verb === 'archive'}
              data-debug-id={`project-view-${verb}`}
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

/** The meta line under the title: vcs · state · Updated <relative>. */
export function ProjectDetailMeta({ record }: { record: ProjectRecord }) {
  const state = projectState(record);
  return (
    <div className="flex flex-wrap items-center gap-2" data-debug-id="project-view-meta">
      {record.vcsKind ? <Badge data-debug-id="project-view-vcs">{vcsLabel(record.vcsKind)}</Badge> : null}
      {/* Only the archived state prints. "Active" on an active project is a pill
          that never varies, which is a pill that says nothing. */}
      {state === 'archived' ? (
        <StatusPill tone={stateTone(state)} data-debug-id="project-view-state">{stateLabel(state)}</StatusPill>
      ) : null}
      <Text as="span" role="body-sm" tone="muted" title={absoluteTime(record.updatedAt)}>
        Updated {relativeTime(record.updatedAt)}
      </Text>
    </div>
  );
}

export function ProjectDetailHeader({
  record,
  busy,
  onVerb,
  onBack,
  alert,
}: {
  record: ProjectRecord;
  busy: ProjectVerb | '';
  onVerb: (verb: ProjectVerb) => void;
  onBack?: () => void;
  alert?: React.ReactNode;
}) {
  const project = record;
  const state = projectState(record);
  const isFig = project.project_type === 'fig';
  const title = projectTitle(record);

  return (
    <ResourceDetailHeader
      dataDebugId="project-pane-header"
      title={
        <a
          href={projectViewHref(record.projectId)}
          data-debug-id="project-pane-title"
          className="rounded-[var(--radius-sm)] hover:underline focus-visible:shadow-focus focus-visible:outline-none"
        >
          <VaultText value={record.name || title} fallback={record.projectId} />
        </a>
      }
      id={record.projectId}
      status={
        state === 'archived' ? (
          <StatusPill tone={stateTone(state)} data-debug-id="project-view-state">
            {stateLabel(state)}
          </StatusPill>
        ) : undefined
      }
      badges={
        <>
          {isFig ? (
            <Badge tone="warning" data-debug-id="project-view-fig-badge">
              Fig (CitC)
            </Badge>
          ) : null}
          {isFig && project.workspace_name ? (
            <Text as="span" role="caption" tone="warning" className="font-mono text-warning" data-debug-id="project-view-meta-workspace">
              {project.workspace_name}
            </Text>
          ) : null}
          {record.vcsKind ? (
            <Badge data-debug-id="project-view-vcs">{vcsLabel(record.vcsKind)}</Badge>
          ) : null}
        </>
      }
      timestamp={`Updated ${relativeTime(record.updatedAt)}`}
      timestampTooltip={absoluteTime(record.updatedAt)}
      alert={alert}
      onBack={onBack}
      actions={<ProjectDetailActions record={record} busy={busy} onVerb={onVerb} />}
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

/** One key/value row inside the Details card. */
function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <Text as="div" role="label" tone="muted">{label}</Text>
      {children}
    </div>
  );
}

/**
 * The per-bridge paths card.
 *
 * A project has a default path AND a path per bridge, because the same checkout
 * sits at a different place on each machine. Each row shows the hub's own
 * verdict — `is_validated` / `validation_error` / `last_validated_at`
 * (`domain/project.odin:30-41`) — which is the fact a user actually needs: a path
 * that has never been validated is not the same as one that failed.
 */
function BridgePathsCard({ record }: { record: ProjectRecord }) {
  const bridgesQuery = useListBridgesQuery();
  const bridges = bridgesQuery.data?.bridges || [];
  const labelFor = React.useCallback(
    (bridgeId: string) => {
      const match = bridges.find((b: any) => String(b?.bridge_id || b?.bridgeId || b?.id || '') === bridgeId);
      return String(match?.label || match?.machine_hostname || bridgeId);
    },
    [bridges],
  );

  const paths = record.bridgePaths;

  return (
    <Card
      title="Bridge paths"
      helper="Where this project lives on each machine. The default path is used when a bridge has no override."
      debugId="project-view-paths-card"
      action={
        <Button
          size="sm"
          variant="secondary"
          data-debug-id="project-view-paths-edit"
          onClick={() => navigateTo(projectEditHref(record.projectId))}
        >
          Manage
        </Button>
      }
    >
      <div className="flex flex-col gap-3">
        <div data-debug-id="project-view-default-path">
          <Text as="div" role="label" tone="muted">Default path</Text>
          <div className="flex items-center gap-2">
            <Text as="span" role="body-sm" className="min-w-0 break-all font-mono">{record.defaultPath || '—'}</Text>
            {record.defaultPath ? (
              <CopyButton value={record.defaultPath} label="Copy default path" debugId="project-view-copy-path" />
            ) : null}
          </div>
        </div>

        {paths.length === 0 ? (
          // Not an error and not a failure: most projects have no override at all.
          <Text as="div" role="body-sm" tone="muted" data-debug-id="project-view-paths-empty">
            No per-bridge overrides — every bridge uses the default path.
          </Text>
        ) : (
          <ul className="flex flex-col gap-2" data-debug-id="project-view-paths">
            {paths.map((entry: ProjectBridgePath) => (
              <li
                key={entry.bridge_id}
                data-debug-id={`project-view-path-${entry.bridge_id}`}
                className="flex flex-col gap-1 border-t border-subtle pt-2 first:border-0 first:pt-0"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <Text as="span" role="label">{labelFor(entry.bridge_id)}</Text>
                  {/* Three states, not two: validated, failed, and never checked. */}
                  {entry.is_validated ? (
                    <StatusPill tone="success" data-debug-id={`project-view-path-ok-${entry.bridge_id}`}>Validated</StatusPill>
                  ) : entry.validation_error ? (
                    <StatusPill tone="danger" data-debug-id={`project-view-path-bad-${entry.bridge_id}`}>Failed</StatusPill>
                  ) : (
                    <StatusPill tone="neutral" data-debug-id={`project-view-path-new-${entry.bridge_id}`}>Not checked</StatusPill>
                  )}
                </div>
                <Text as="div" role="body-sm" className="break-all font-mono">{entry.path}</Text>
                {entry.validation_error ? (
                  <Text as="div" role="body-sm" tone="danger">{entry.validation_error}</Text>
                ) : null}
                {entry.last_validated_at ? (
                  <Text as="div" role="caption" tone="muted" title={absoluteTime(entry.last_validated_at)}>
                    Checked {relativeTime(entry.last_validated_at)}
                  </Text>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  );
}

/**
 * One linked-resource list (REQ-UI-12).
 *
 * Every one of these degrades rather than errors: a project page is still useful
 * when the chains endpoint is down, and an `Alert` per card would bury the project
 * under other resources' problems.
 */
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
    // "Couldn't load" and "there are none" are different facts — the catalog-state
    // rule from Amendment 5, applied to a linked list.
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

/** How many of each linked resource a card previews before linking out. */
const LINKED_PREVIEW = 5;

function LinkedResources({ record }: { record: ProjectRecord }) {
  const projectId = record.projectId;

  const chainsQuery = useListTaskChainsQuery({ projectId, limit: LINKED_PREVIEW });

  const chains = (chainsQuery.data?.chains || []).slice(0, LINKED_PREVIEW).map((chain: any) => ({
    id: String(chain.chainId),
    label: String(chain.title || chain.chainId),
    sub: String(chain.status || ''),
    href: buildRouteHash(`/chains/${encodeURIComponent(String(chain.chainId))}`, ''),
  }));

  return (
    <Card
      title="Chains"
      debugId="project-view-chains-card"
      action={
        <Link href={buildRouteHash('/chains', `project=${encodeURIComponent(projectId)}`)} data-debug-id="project-view-chains-all">
          All chains
        </Link>
      }
    >
      <LinkedList
        items={chains}
        loading={chainsQuery.isLoading}
        failed={Boolean(chainsQuery.error)}
        emptyLabel="No chains on this project yet."
        debugId="project-view-chains"
      />
    </Card>
  );
}

/* ------------------------------------------------------------------ *
 * The body
 * ------------------------------------------------------------------ */

export function ProjectDetailBody({
  record,
  actionError,
  /** True when the pane is wide enough for a right rail (>=900px). */
  wide,
}: {
  record: ProjectRecord;
  actionError?: string;
  wide: boolean;
}) {
  const description = record.description;
  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1):
  // state.vault.rawVaultKeyHex is never assigned, so the old selectRawVaultKeyHex
  // always returned null. Both gates now test the real key.
  const activeKey = useSelector(selectActiveVaultKey);
  const [decryptedDescription, setDecryptedDescription] = React.useState<string | null>(null);

  React.useEffect(() => {
    let active = true;
    if (description && isVaultArmored(description) && activeKey) {
      decryptVaultText(description, activeKey)
        .then((text) => {
          if (active) setDecryptedDescription(text);
        })
        .catch(() => {
          // Never fall back to the armored source: null routes the render below to the
          // VaultText placeholder instead of printing `vault:v2:` on screen.
          if (active) setDecryptedDescription(null);
        });
    } else {
      setDecryptedDescription(null);
    }
    return () => {
      active = false;
    };
  }, [description, activeKey]);

  const main = (
    <>
      <Card title="Description" debugId="project-view-description-card">
        {description ? (
          isVaultArmored(description) && !decryptedDescription ? (
            <div data-debug-id="project-view-description">
              <VaultText value={description} as="div" />
            </div>
          ) : (
            <MarkdownBody source={decryptedDescription || description} copyAll={false} data-debug-id="project-view-description" />
          )
        ) : (
          <Text as="div" role="body-sm" tone="muted" data-debug-id="project-view-description-empty">
            No description yet.
          </Text>
        )}
      </Card>

      <BridgePathsCard record={record} />
    </>
  );

  const rail = (
    <>
      <Card title="Details" debugId="project-view-details-card">
        <div className="flex flex-col gap-2">
          <DetailRow label="Repository">
            {record.repoUrl ? (
              // An external URL, so a real anchor rather than a hash route.
              <a
                href={record.repoUrl}
                target="_blank"
                rel="noreferrer noopener"
                data-debug-id="project-view-repo"
                className="break-all rounded-[var(--radius-sm)] text-body-sm text-accent underline focus-visible:shadow-focus focus-visible:outline-none"
              >
                {record.repoUrl}
              </a>
            ) : (
              <Text as="div" role="body-sm" tone="muted">Not set</Text>
            )}
          </DetailRow>
          <DetailRow label="Version control">
            <Text as="div" role="body-sm">{vcsLabel(record.vcsKind)}</Text>
          </DetailRow>
          <DetailRow label="Slug">
            <Text as="div" role="body-sm" className="font-mono">{record.slug || '—'}</Text>
          </DetailRow>
          {/* No Created row and no Owner row: neither field is on the wire. */}
          <DetailRow label="Updated">
            <Text as="div" role="body-sm">{`${absoluteTime(record.updatedAt)} (${relativeTime(record.updatedAt)})`}</Text>
          </DetailRow>
          <DetailRow label="Project ID">
            <div className="flex items-center gap-2">
              <Text as="span" role="body-sm" className="font-mono">{record.projectId}</Text>
              <CopyButton value={record.projectId} label="Copy project ID" debugId="project-view-copy-id" />
            </div>
          </DetailRow>
        </div>
      </Card>

      <LinkedResources record={record} />
    </>
  );

  return (
    <div data-debug-id="project-view-page" className="flex w-full min-w-0 flex-col gap-3">
      {actionError ? <Alert tone="danger" title="That didn't work">{actionError}</Alert> : null}
      {projectState(record) === 'archived' ? (
        // The one thing a user cannot discover by looking: this cannot be undone
        // from Heimdall, so the page says it where the state is visible.
        <Alert tone="warning" title="This project is archived">
          It still works — chains, agents and memories on it are untouched. Heimdall can&apos;t un-archive from here.
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
      {/* Full-width below the layout so the intersection-observer sentinel lives in
          the page's main scroll flow — never a nested scroller. */}
      <PaginatedMemoriesSection projectId={record.projectId} debugPrefix="project-view-memories" />
    </div>
  );
}

/**
 * The mobile action bar: Edit, full width, docked ABOVE the app's bottom tab nav
 * via `--ui-bottom-chrome` (the same variable `BulkActionBar` reads — one mechanism
 * for everything pinned to the bottom edge).
 *
 * Archive is NOT here. It is in the `…` menu at every width: a one-way destructive
 * verb does not belong under a thumb, and Amendment 6's rule is that a verb appears
 * in the sticky bar or the header, never both.
 */
export function ProjectDetailMobileActions({
  record,
  onVerb,
}: {
  record: ProjectRecord;
  onVerb: (verb: ProjectVerb) => void;
}) {
  if (!verbsForState(projectState(record)).includes('edit')) return null;
  return (
    <div
      data-debug-id="project-view-mobile-actions"
      role="group"
      aria-label="Project actions"
      className="fixed inset-x-0 z-sticky flex gap-2 border-t border-subtle bg-surface-raised p-2 md:hidden"
      // REQ-VIEWPORT-SWEEP-1: the occluded height is an ADDEND here, not an alternative —
      // the keyboard covers the tab bar too, so the bar clears the keyboard first and then
      // whatever chrome or safe area remains. `--app-viewport-bottom-offset` is `0px` when
      // nothing is occluding, so this is unchanged on desktop.
      style={{ bottom: 'calc(var(--app-viewport-bottom-offset, 0px) + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
    >
      <Button
        width="full"
        variant="primary"
        data-debug-id="project-view-mobile-edit"
        className="h-12 flex-1"
        onClick={() => onVerb('edit')}
      >
        Edit
      </Button>
    </div>
  );
}

/** True when a pane of this width earns the 320px right rail (>=900px). */
export function usePaneIsWide(ref: React.RefObject<HTMLElement | null>): boolean {
  const viewport = useViewport();
  const [wide, setWide] = React.useState(false);
  React.useEffect(() => {
    const node = ref.current;
    if (!node || typeof ResizeObserver === 'undefined') return undefined;
    const update = () => setWide(node.getBoundingClientRect().width >= 900);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(node);
    return () => observer.disconnect();
  }, [ref, viewport]);
  return wide;
}

/** Shown while the detail is loading inside the two-pane layout. */
export function ProjectDetailPaneSkeleton() {
  return (
    <div className="flex items-center gap-2 p-6" data-debug-id="project-detail-pane-loading">
      <Spinner size="sm" />
      <Text as="span" role="body-sm" tone="muted">Loading project…</Text>
    </div>
  );
}

export { Card as ProjectDetailCard };
