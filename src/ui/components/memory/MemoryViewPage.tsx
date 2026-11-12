/**
 * MemoryViewPage — `/memory/:id` as a standalone page.
 * ------------------------------------------------------------------
 * Read-only (REQ-UI-11): every mutation is a verb in the header, the mobile action
 * bar, or a trip to `/memory/:id/edit`. Spec: `docs/ui-rebuild/memory-redesign-spec.md`
 * › DETAIL VIEW.
 *
 * This file is now only the PAGE FRAME. Everything that draws a memory lives in
 * `MemoryDetail.tsx`, because the same detail also renders as the right-hand pane of
 * the two-pane list at >=1024 — one implementation, so the page and the pane cannot
 * drift apart.
 *
 * At >=1024 this route hands off to the list page, which renders list + pane; a
 * pasted `/memory/:id` link and a click on a row therefore land in the same place.
 * Below that, this page is the detail.
 *
 * The three free-text fields render as markdown because that is how agents author
 * them; `title` stays plain text — it is a row label and a search label.
 */
import React from 'react';
import { Button, EmptyState, Icon, PageShell, Text, useViewport } from '@ui';
import { maskVaultArmored, memoryErrorText } from '../../api/endpoints/memory';
import MemoryListPage from './MemoryListPage';
import {
  MemoryDetailActions,
  MemoryDetailBody,
  MemoryDetailMeta,
  MemoryDetailMobileActions,
  useMemoryDetail,
  usePaneIsWide,
} from './MemoryDetail';
import {
  detailCrumbs,
  memoryListHref,
  memoryStatus,
  memoryTitle,
  navigateTo,
  parseMemoryListUrl,
  viewCrumbs,
} from './memoryModel';
import { useDecryptedText } from '../vault/VaultText';
import { getRouteSearch } from '../../utils/appLocation';

export default function MemoryViewPage({ memoryId }: { memoryId: string }) {
  const viewport = useViewport();
  const { query, record, busy, actionError, runVerb } = useMemoryDetail(memoryId);
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);
  // The trail's terminal tab comes from the URL the user arrived with; a pasted link
  // carries none, and `detailCrumbs` falls back to the tab the record's own status
  // belongs to rather than rendering an empty crumb.
  const listState = React.useMemo(() => parseMemoryListUrl(getRouteSearch()), []);
  // `PageShell` promotes the terminal crumb into the <h1> and `detailCrumbs` takes a
  // STRING, so `VaultText` (which renders JSX) fits neither consumer. The endpoint
  // decrypts whenever the vault is unlocked; the hook covers the state it cannot
  // reach — enabled but LOCKED — and re-runs on unlock, so a record cached while
  // locked still resolves without a refetch. The mask covers the hook's own first
  // synchronous render, where `useState(raw)` returns the token before the effect
  // replaces it. Declared above the desktop early return so hook order never shifts.
  const title = maskVaultArmored(useDecryptedText(memoryTitle(record)).text);

  // At >=1024 the detail belongs in the list's right-hand pane (spec › Desktop
  // layout). The ROUTE stays `#/memory/:id`, so a pasted link and a row click land in
  // the same place and one memory never has two URLs — the layout differs, not the
  // address. Every hook above runs first, so this early return cannot reorder them.
  if (viewport === 'desktop') {
    return <MemoryListPage selectedId={memoryId} />;
  }

  if (query.isLoading) {
    return <PageShell rhythm="banded" title="Memory" breadcrumbs={viewCrumbs('Loading…')} loading />;
  }

  if (query.error || !record) {
    return (
      <PageShell rhythm="banded" title="Memory" breadcrumbs={viewCrumbs('Not found')}>
        <EmptyState
          data-debug-id="memory-view-missing"
          icon="search"
          title="That memory doesn't exist"
          description={query.error ? memoryErrorText(query.error) : undefined}
          action={<Button variant="secondary" onClick={() => navigateTo(memoryListHref())}>Back to Memory</Button>}
        />
      </PageShell>
    );
  }

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={title}
      // "Memory / Proposals" — ancestors only. `PageShell` promotes the terminal
      // crumb into the <h1>, so the title is never printed twice.
      breadcrumbs={detailCrumbs(title, memoryStatus(record), listState)}
      description={<MemoryDetailMeta record={record} />}
      actions={
        <MemoryDetailActions
          record={record}
          busy={busy}
          onVerb={(verb) => void runVerb(verb)}
          onDeleted={() => navigateTo(memoryListHref(listState))}
        />
      }
    >
      <div ref={paneRef} className="min-w-0">
        {/* Mobile: a back link, because the trail collapses to one step that matters. */}
        {viewport === 'mobile' ? (
          <a
            href={memoryListHref(listState)}
            data-debug-id="memory-view-back"
            className="mb-2 inline-flex items-center gap-1 rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Icon name="arrow-left" size="sm" aria-hidden="true" />
            <Text as="span" role="body-sm" tone="muted">Memory</Text>
          </a>
        ) : null}

        <MemoryDetailBody record={record} actionError={actionError} wide={wide} />

        {/* The bar is fixed, so the page needs room under it — plus the tab nav and
            the device's safe area — or the last card sits under the buttons. */}
        <div
          aria-hidden="true"
          className="md:hidden"
          style={{ height: 'calc(3.5rem + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
        />
      </div>

      <MemoryDetailMobileActions record={record} busy={busy} onVerb={(verb) => void runVerb(verb)} />
    </PageShell>
  );
}
