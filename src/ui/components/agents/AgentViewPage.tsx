/**
 * AgentViewPage — `/agents/:id` as a standalone page.
 * ------------------------------------------------------------------
 * Modeled after ProjectViewPage.
 *
 * At >=1024 this route hands off to the list page, which renders list + pane,
 * so a pasted `/agents/:id` link and a click on a row land in the same place
 * and one agent never has two URLs.
 */
import React from 'react';
import { Button, EmptyState, Icon, PageShell, Text, useViewport } from '@ui';
import { agentErrorText } from '../../api/endpoints/agents';
import AgentListPage from './AgentListPage';
import {
  AgentDetailActions,
  AgentDetailBody,
  AgentDetailMeta,
  AgentDetailMobileActions,
  useAgentDetail,
  usePaneIsWide,
} from './AgentDetail';
import {
  detailCrumbs,
  navigateTo,
  parseAgentListUrl,
  agentListHref,
  agentState,
  agentTitle,
  viewCrumbs,
} from './agentModel';
import { getRouteSearch } from '../../utils/appLocation';

export default function AgentViewPage({ agentId }: { agentId: string }) {
  const viewport = useViewport();
  const { query, record, busy, actionError, runVerb } = useAgentDetail(agentId);
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);
  const listState = React.useMemo(() => parseAgentListUrl(getRouteSearch()), []);

  // At >=1024 the detail belongs in the list's right-hand pane.
  if (viewport === 'desktop') {
    return <AgentListPage selectedId={agentId} />;
  }

  if (query.isLoading) {
    return <PageShell rhythm="banded" title="Agents" breadcrumbs={viewCrumbs('Loading…')} loading />;
  }

  if (query.error || !record) {
    return (
      <PageShell rhythm="banded" title="Agents" breadcrumbs={viewCrumbs('Not found')}>
        <EmptyState
          data-debug-id="agent-view-missing"
          icon="search"
          title="That agent doesn't exist"
          description={query.error ? agentErrorText(query.error) : undefined}
          action={<Button variant="secondary" onClick={() => navigateTo(agentListHref())}>Back to Agents</Button>}
        />
      </PageShell>
    );
  }

  const title = agentTitle(record);

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={title}
      breadcrumbs={detailCrumbs(title, agentState(record), listState)}
      description={<AgentDetailMeta record={record} />}
      actions={
        <AgentDetailActions
          record={record}
          busy={busy}
          onVerb={(verb) => void runVerb(verb)}
          onDeleted={() => navigateTo(agentListHref(listState))}
        />
      }
    >
      <div ref={paneRef} className="min-w-0">
        {viewport === 'mobile' ? (
          <a
            href={agentListHref(listState)}
            data-debug-id="agent-view-back"
            className="mb-2 inline-flex items-center gap-1 rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none"
          >
            <Icon name="arrow-left" size="sm" aria-hidden="true" />
            <Text as="span" role="body-sm" tone="muted">Agents</Text>
          </a>
        ) : null}

        <AgentDetailBody record={record} actionError={actionError} wide={wide} />

        <div
          aria-hidden="true"
          className="md:hidden"
          style={{ height: 'calc(3.5rem + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))' }}
        />
      </div>

      <AgentDetailMobileActions record={record} onVerb={(verb) => void runVerb(verb)} />
    </PageShell>
  );
}
