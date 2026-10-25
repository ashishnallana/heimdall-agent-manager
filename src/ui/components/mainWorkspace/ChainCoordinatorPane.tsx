import React from 'react';
import { useFetchTaskChainConversationQuery } from '../../api/endpoints/tasks';
import { buildRouteHash } from '../../utils/appLocation';
import { VaultText } from '../vault/VaultText';

export interface ChainCoordinatorPaneProps {
  chainId: string;
  /** Renders the chat for the chain's CURRENT coordinator instance. */
  children: (coordinatorAgentInstanceId: string, chainTitle: string) => React.ReactNode;
}

/**
 * A Main pane addressed by chain (`chain:<id>`, REQ-TV2-7). It resolves the
 * chain's current coordinator through GET /task-chains/{id}/conversation, and
 * the hub re-resolves it on chain changes, so the pane follows a coordinator
 * replacement without the URL or the layout changing.
 */
export function ChainCoordinatorPane({ chainId, children }: ChainCoordinatorPaneProps) {
  const { data, isLoading, isError } = useFetchTaskChainConversationQuery({ chainId }, { skip: !chainId });
  const coordinator = data?.coordinatorAgentInstanceId || '';
  if (coordinator) {
    // `contents`: a layout-neutral wrapper that names the resolved coordinator.
    return (
      <div className="contents" data-debug-id={`chain-pane-${chainId}`} data-coordinator-instance-id={coordinator}>
        {children(coordinator, data?.title || '')}
      </div>
    );
  }
  if (isLoading) {
    return (
      <div data-debug-id="chain-pane-loading" className="flex h-full w-full items-center justify-center text-sm text-muted">
        Loading task chain…
      </div>
    );
  }
  return (
    <div
      data-debug-id="chain-pane-no-coordinator"
      role="status"
      className="flex h-full w-full flex-col items-center justify-center gap-3 px-6 text-center text-sm text-muted"
    >
      <p>
        {isError ? 'This task chain could not be loaded.' : (
          <>
            <VaultText value={data?.title || ''} fallback="This task chain" as="span" /> has no coordinator conversation.
          </>
        )}
      </p>
      <a
        href={buildRouteHash(`/chains/${encodeURIComponent(chainId)}`, '')}
        className="rounded-lg border border-subtle px-3 py-1.5 text-primary hover:bg-neutral-soft"
      >
        Open task chain
      </a>
    </div>
  );
}

export default ChainCoordinatorPane;
