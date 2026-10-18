/**
 * MemoryDetail — the detail view's guts, rendered as a full page AND as the
 * two-pane right-hand pane.
 * ------------------------------------------------------------------
 * The redesign puts the same detail on screen in two places (spec › DETAIL VIEW, and
 * the >=1024 master/detail layout). This module is the single implementation of it:
 * `useMemoryDetail` holds the data + verbs, `MemoryDetailActions` is the header's
 * action cluster, and `MemoryDetailBody` is the stack of surface cards. The page and
 * the pane differ only in which heading element wraps them and where the mobile
 * action bar goes — everything else is shared, so the two cannot drift.
 *
 * Sections (spec): Body · Evidence · Scope · Details. Scope MERGES what were two
 * sections (Scope and Linked resources) into one 4-row key/value list, which is the
 * change that stops the page saying the same four dimensions twice.
 *
 * Dropped per the user's rulings, deliberately, and recorded so nobody re-adds them:
 *  - a **Source agent** row and the "Agent" badge — a memory carries no author field,
 *    and `status === 'pending'` is a lifecycle state, not provenance (ruling 4).
 *  - **Created** — `created_at` is not serialised by the hub (F12, ruling 3).
 *  - **Delete** — there is no delete verb in this UI; the menu reads Archive (ruling 2).
 *  - **Auto-linked `file:line` evidence refs** — evidence is unstructured free text and
 *    any linking is heuristic; a link that lies about where it goes is worse than
 *    honest text (ruling 5). Rendered monospace, with copy.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  Icon,
  IconButton,
  Menu,
  MenuItem,
  Panel,
  ResourceDetailHeader,
  ResourceSectionCard,
  StatusPill,
  Text,
  useViewport,
} from '@ui';
import { ScopeChips, SCOPE_DIMS, targetingFromRecord, useMemoryScopeCatalog } from '@ui';
import type { ScopeCatalog, ScopeDimKey } from '@ui';
import { useSelector } from 'react-redux';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { isVaultArmored, decryptVaultText } from '../../utils/vaultContent';
import { VaultText } from '../vault/VaultText';
import MarkdownBody from '../MarkdownBody';
import {
  memoryErrorText,
  useApproveMemoryMutation,
  useArchiveMemoryMutation,
  useGetMemoryQuery,
  useRejectMemoryMutation,
} from '../../api/endpoints/memory';
import { buildRouteHash } from '../../utils/appLocation';
import {
  VERB_LABEL,
  absoluteTime,
  memoryEditHref,
  memoryStatus,
  memoryTitle,
  navigateTo,
  relativeTime,
  statusLabel,
  statusTone,
  verbsForStatus,
  type MemoryVerb,
} from './memoryModel';

/** Where each scope dimension's chips navigate (REQ-UI-12). */
function linkForDimension(dim: ScopeDimKey, id: string): string {
  switch (dim) {
    case 'projectIds':
      // The rebuilt Projects pages address a project as a ROUTE. The old
      // `?projectId=` query form still works (the list page translates it), but
      // nothing in the app should keep minting it.
      return buildRouteHash(`/projects/${encodeURIComponent(id)}`, '');
    case 'agentIds':
      return buildRouteHash(`/agents/${encodeURIComponent(id)}`, '');
    case 'bridgeIds':
      return buildRouteHash('/settings/bridges', '');
    case 'templateIds':
      return buildRouteHash('/settings/templates', '');
  }
}

export function useMemoryDetail(memoryId: string, onAfterVerb?: (verb: MemoryVerb) => void) {
  const query = useGetMemoryQuery({ memoryId }, { skip: !memoryId });
  const [approveMemory] = useApproveMemoryMutation();
  const [rejectMemory] = useRejectMemoryMutation();
  const [archiveMemory] = useArchiveMemoryMutation();
  const [busy, setBusy] = React.useState<MemoryVerb | ''>('');
  const [actionError, setActionError] = React.useState('');

  const runVerb = React.useCallback(
    async (verb: MemoryVerb) => {
      if (verb === 'edit') {
        navigateTo(memoryEditHref(memoryId));
        return;
      }
      setBusy(verb);
      setActionError('');
      try {
        if (verb === 'reject') await rejectMemory({ memoryId }).unwrap();
        else if (verb === 'archive') await archiveMemory({ memoryId }).unwrap();
        else await approveMemory({ memoryId }).unwrap();
        // Auto-advance (spec › GLOBAL FIXES) is the caller's decision, because only
        // the list knows what "next" is.
        onAfterVerb?.(verb);
      } catch (err) {
        // A system memory rejects every write with the hub's own 403 text; the payload
        // carries no read-only signal (BACKEND-DEP-1), so we attempt and report.
        setActionError(memoryErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this memory.`));
      } finally {
        setBusy('');
      }
    },
    [approveMemory, archiveMemory, memoryId, onAfterVerb, rejectMemory],
  );

  return { query, record: query.data, busy, actionError, runVerb };
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

/** The header's action cluster: primary verb, secondary verb, then the `…` menu. */
export function MemoryDetailActions({
  record,
  busy,
  onVerb,
}: {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  record: any;
  busy: MemoryVerb | '';
  onVerb: (verb: MemoryVerb) => void;
}) {
  const status = memoryStatus(record);
  const verbs = verbsForStatus(status);
  // Approve/Reject are the header's buttons; everything else (Edit, Archive) lives in
  // the menu. There is no Delete — archive is the permanent answer to delete.
  const primary = verbs.find((verb) => verb === 'approve');
  const secondary = verbs.find((verb) => verb === 'reject');
  const menuVerbs = verbs.filter((verb) => verb !== primary && verb !== secondary);

  return (
    <>
      {/* Approve/Reject are header buttons on DESKTOP ONLY. Below `md` the same two
          verbs are the sticky bottom bar (`memory-view-mobile-actions`, `md:hidden`),
          and rendering both put two Approve buttons on one phone screen — caught by
          screenshotting the detail view at 390px, not by the type checker.
          `md:contents` rather than `md:flex`: the fragment's children are laid out by
          the header's own flex row, so a wrapper must not become a flex item itself
          or the two buttons collapse into one box with the wrong gap. */}
      {primary ? (
        <span className="hidden md:contents">
          <ActionButton
            label={VERB_LABEL[primary]}
            variant="primary"
            loading={busy === primary}
            data-debug-id={`memory-view-${primary}`}
            onClick={() => onVerb(primary)}
          />
        </span>
      ) : null}
      {secondary ? (
        <span className="hidden md:contents">
          <ActionButton
            label={VERB_LABEL[secondary]}
            variant="secondary"
            loading={busy === secondary}
            data-debug-id={`memory-view-${secondary}`}
            onClick={() => onVerb(secondary)}
          />
        </span>
      ) : null}
      {menuVerbs.length ? (
        <Menu
          label="Memory actions"
          align="end"
          trigger={
            <ActionButton
              icon="more-horizontal"
              label="More"
              aria-label="Memory actions"
              data-debug-id="memory-view-menu"
            />
          }
        >
          {menuVerbs.map((verb) => (
            <MenuItem
              key={verb}
              danger={verb === 'archive'}
              data-debug-id={`memory-view-${verb}`}
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

/** The meta line under the title: type · status · Updated <relative>. */
export function MemoryDetailMeta({ record }: { record: any }) {
  const status = memoryStatus(record);
  return (
    <div className="flex flex-wrap items-center gap-2" data-debug-id="memory-view-meta">
      <Badge data-debug-id="memory-view-type">{String(record.type || 'fact')}</Badge>
      <StatusPill tone={statusTone(status)} data-debug-id="memory-view-status">{statusLabel(status)}</StatusPill>
      {/* Relative at a glance, absolute on hover — the absolute one is what a reader
          cites, and it is the `title` so it survives on desktop; the Details card
          repeats it as text, because a tooltip does not exist on touch. */}
      <Text as="span" role="body-sm" tone="muted" title={absoluteTime(record.updatedAt)}>
        Updated {relativeTime(record.updatedAt)}
      </Text>
    </div>
  );
}

export function MemoryDetailHeader({
  record,
  busy,
  onVerb,
  onBack,
  alert,
}: {
  record: any;
  busy: MemoryVerb | '';
  onVerb: (verb: MemoryVerb) => void;
  onBack?: () => void;
  alert?: React.ReactNode;
}) {
  const status = memoryStatus(record);
  return (
    <ResourceDetailHeader
      dataDebugId="memory-pane-header"
      title={<span data-debug-id="memory-pane-title"><VaultText value={record.title || memoryTitle(record)} as="span" /></span>}
      id={String(record.memoryId || '')}
      status={<StatusPill tone={statusTone(status)} data-debug-id="memory-view-status">{statusLabel(status)}</StatusPill>}
      badges={<Badge data-debug-id="memory-view-type">{String(record.type || 'fact')}</Badge>}
      timestamp={`Updated ${relativeTime(record.updatedAt)}`}
      timestampTooltip={absoluteTime(record.updatedAt)}
      alert={alert}
      onBack={onBack}
      actions={<MemoryDetailActions record={record} busy={busy} onVerb={onVerb} />}
    />
  );
}

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

/** The four scope rows, as a key/value list. Chips, or a muted "All <dimension>". */
function ScopeRows({ record, catalog }: { record: any; catalog: ScopeCatalog }) {
  const targeting = targetingFromRecord(record);
  const allEmpty = SCOPE_DIMS.every((dim) => targeting[dim.key].length === 0);

  if (allEmpty) {
    // One line, not four "All …" rows: the fact worth stating is that it applies
    // everywhere, and the way to change that is right next to it.
    return (
      <div className="flex flex-wrap items-center gap-2" data-debug-id="memory-view-scope-global">
        <Text as="span" role="body-sm">
          <strong>Global:</strong> applies everywhere
        </Text>
        <a
          href={memoryEditHref(String(record.memoryId || ''))}
          className="rounded-[var(--radius-sm)] text-body-sm text-accent underline focus-visible:shadow-focus focus-visible:outline-none"
          data-debug-id="memory-view-scope-edit"
        >
          Edit scope
        </a>
      </div>
    );
  }

  return (
    <dl className="flex flex-col gap-2">
      {SCOPE_DIMS.map((dim) => {
        const ids = targeting[dim.key];
        return (
          <div key={dim.key} data-debug-id={`memory-view-linked-${dim.debug}`} className="flex flex-wrap items-center gap-2">
            <dt className="w-24 shrink-0">
              <Text as="span" role="label" tone="muted">{dim.label}</Text>
            </dt>
            <dd className="m-0 flex min-w-0 flex-wrap items-center gap-2">
              {ids.length === 0 ? (
                // "Applies to everything" is the one thing about a memory a user can
                // misread destructively, so an empty dimension states itself.
                <Text as="span" role="body-sm" tone="muted">{dim.allLabel}</Text>
              ) : (
                ids.map((id) => {
                  const name = catalog[dim.key].byId.get(id);
                  return (
                    <a
                      key={id}
                      href={linkForDimension(dim.key, id)}
                      className="inline-flex items-center rounded-pill border border-subtle px-2 py-0.5 text-body-sm text-primary transition-colors hover:border-strong"
                    >
                      {name || id}
                      {name ? null : <span className="ml-1 text-muted">(not found)</span>}
                    </a>
                  );
                })
              )}
            </dd>
          </div>
        );
      })}
    </dl>
  );
}

export function MemoryDetailBody({
  record,
  actionError,
  /** True when the pane is wide enough for a right rail (spec: >=900px). */
  wide,
}: {
  record: any;
  actionError?: string;
  wide: boolean;
}) {
  const catalog = useMemoryScopeCatalog();
  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1):
  // state.vault.rawVaultKeyHex is never assigned, so the old selectRawVaultKeyHex
  // always returned null. Both the decrypt gates and the render gates below now test
  // the real key, so an unlocked vault can no longer fall through to raw ciphertext.
  const activeKey = useSelector(selectActiveVaultKey);

  const memoryId = String(record.memoryId || '');
  const body = String(record.body || '');
  const evidence = String(record.evidence || '');

  // Seed empty for armored input so the first paint cannot flash ciphertext while the
  // decrypt effect is still in flight.
  const [decryptedBody, setDecryptedBody] = React.useState<string>(isVaultArmored(body) ? '' : body);
  const [decryptedEvidence, setDecryptedEvidence] = React.useState<string>(isVaultArmored(evidence) ? '' : evidence);

  React.useEffect(() => {
    let active = true;
    if (!body || !isVaultArmored(body)) {
      setDecryptedBody(body);
      return;
    }
    if (!activeKey) {
      setDecryptedBody('');
      return;
    }
    decryptVaultText(body, activeKey)
      .then((t) => {
        if (active) setDecryptedBody(t);
      })
      .catch(() => {
        // Never fall back to the armored source: that is how `vault:v2:` strings reach
        // the screen. Empty routes the render below to the VaultText placeholder.
        if (active) setDecryptedBody('');
      });
    return () => {
      active = false;
    };
  }, [body, activeKey]);

  React.useEffect(() => {
    let active = true;
    if (!evidence || !isVaultArmored(evidence)) {
      setDecryptedEvidence(evidence);
      return;
    }
    if (!activeKey) {
      setDecryptedEvidence('');
      return;
    }
    decryptVaultText(evidence, activeKey)
      .then((t) => {
        if (active) setDecryptedEvidence(t);
      })
      .catch(() => {
        if (active) setDecryptedEvidence('');
      });
    return () => {
      active = false;
    };
  }, [evidence, activeKey]);

  const main = (
    <>
      <Card
        title="Body"
        helper="The text your agents receive."
        debugId="memory-view-body-card"
        action={<CopyButton value={decryptedBody} label="Copy body" debugId="memory-view-copy-body" />}
      >
        {isVaultArmored(body) && !decryptedBody ? (
          <div className="py-2">
            <VaultText value={body} as="div" />
          </div>
        ) : (
          <MarkdownBody source={decryptedBody} copyAll={false} data-debug-id="memory-view-body" />
        )}
      </Card>

      {/* Hidden entirely when empty — an empty bordered card says nothing a reader
          needs, and the spec explicitly asks for no dead padding here. */}
      {evidence ? (
        <Card
          title="Evidence"
          debugId="memory-view-evidence-card"
          action={<CopyButton value={decryptedEvidence} label="Copy evidence" debugId="memory-view-copy-evidence" />}
        >
          {isVaultArmored(evidence) && !decryptedEvidence ? (
            <div className="py-2">
              <VaultText value={evidence} as="div" />
            </div>
          ) : (
            <div data-debug-id="memory-view-evidence" className="flex flex-col gap-1 font-mono text-[length:var(--text-code-size)] leading-[var(--text-code-leading)]">
              {decryptedEvidence.split('\n').map((line, i) =>
                line.trim() ? (
                  <div key={i} className="overflow-x-auto whitespace-pre text-primary">
                    <VaultText value={line} as="span" />
                  </div>
                ) : null,
              )}
            </div>
          )}
        </Card>
      ) : null}
    </>
  );

  const rail = (
    <>
      <Card
        title="Scope"
        debugId="memory-view-scope-card"
        action={
          <span
            className="inline-flex items-center"
            // The AND rule is the thing people misread; it rides as a tooltip on an
            // info affordance rather than a permanent paragraph (spec).
            title="A memory applies where ALL four dimensions match — an empty dimension applies to everything in it."
            data-debug-id="memory-view-scope-info"
          >
            <Icon name="info" size="sm" />
            <span className="sr-only">
              A memory applies where all four dimensions match; an empty dimension applies to everything in it.
            </span>
          </span>
        }
      >
        <ScopeRows record={record} catalog={catalog} />
      </Card>

      <Card title="Details" debugId="memory-view-details-card">
        <div className="flex flex-col gap-2">
          {/* Type and Status live in the header; Created and Source agent do not
              exist in the payload (F12, ruling 4). What is left is what is true. */}
          <div>
            <Text as="div" role="label" tone="muted">Updated</Text>
            <Text as="div" role="body-sm">{`${absoluteTime(record.updatedAt)} (${relativeTime(record.updatedAt)})`}</Text>
          </div>
          <div>
            <Text as="div" role="label" tone="muted">Memory ID</Text>
            <div className="flex items-center gap-2">
              <Text as="span" role="body-sm" className="font-mono">{memoryId}</Text>
              <CopyButton value={memoryId} label="Copy memory ID" debugId="memory-view-copy-id" />
            </div>
          </div>
        </div>
      </Card>
    </>
  );

  return (
    <div data-debug-id="memory-view-page" className="flex w-full min-w-0 flex-col gap-3">
      {actionError ? <Alert tone="danger" title="That didn't work">{actionError}</Alert> : null}
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
 * The mobile action bar: Reject | Approve at 50/50, 48px tall, docked ABOVE the app's
 * bottom tab nav via `--ui-bottom-chrome` (the same variable `BulkActionBar` uses —
 * one mechanism for everything pinned to the bottom edge).
 */
export function MemoryDetailMobileActions({
  record,
  busy,
  onVerb,
}: {
  record: any;
  busy: MemoryVerb | '';
  onVerb: (verb: MemoryVerb) => void;
}) {
  const verbs = verbsForStatus(memoryStatus(record));
  const bar = verbs.filter((verb) => verb === 'approve' || verb === 'reject');
  if (bar.length === 0) return null;
  return (
    <div
      data-debug-id="memory-view-mobile-actions"
      role="group"
      aria-label="Memory actions"
      className="fixed inset-x-0 z-sticky flex gap-2 border-t border-subtle bg-surface-raised p-2 md:hidden"
      // REQ-VIEWPORT-SWEEP-1: the occluded height is an ADDEND here, not an alternative —
      // the keyboard covers the tab bar too, so the bar clears the keyboard first and then
      // whatever chrome or safe area remains. `--app-viewport-bottom-offset` is `0px` when
      // nothing is occluding, so this is unchanged on desktop.
      style={{ bottom: 'calc(var(--app-viewport-bottom-offset, 0px) + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
    >
      {bar.map((verb) => (
        <Button
          key={verb}
          width="full"
          variant={verb === 'approve' ? 'primary' : 'secondary'}
          loading={busy === verb}
          data-debug-id={`memory-view-mobile-${verb}`}
          className="h-12 flex-1"
          onClick={() => onVerb(verb)}
        >
          {VERB_LABEL[verb]}
        </Button>
      ))}
    </div>
  );
}

/** True when a pane of this width earns the 320px right rail (spec: >=900px). */
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
    // `viewport` is a dependency because the pane's width changes with the layout.
  }, [ref, viewport]);
  return wide;
}
