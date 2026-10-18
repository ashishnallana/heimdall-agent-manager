import React from 'react';
import { useFetchAgentInstanceQuery } from '../../api/endpoints/agents';
import { useOpenAgentChat } from '../auxiliary/openAgentChatContext';
import { useIsMobile } from '../shell/responsive';
import { GENERIC_AGENT_LABEL, type TaskNames } from './taskNames';

/**
 * The name of the agent instance holding a lease (e.g. "Backend Dev #15"),
 * never its raw id, as a link that opens the chat with that instance.
 *
 * The instance's own display name wins: names.instance() may only know the
 * agent template ("Backend Dev"), which does not say WHICH running instance
 * holds the task, so the instance is fetched (one cached RTK query per
 * distinct instance, the same pattern as InstanceIdLink). Until it loads, the
 * names.instance() answer stands in. The id stays available on hover only.
 */
export function HolderName({ instanceId, names, className }: { instanceId: string; names: TaskNames; className?: string }) {
  const id = String(instanceId || '').trim();
  const openAgentChat = useOpenAgentChat();
  const isMobile = useIsMobile();
  const known = id ? names.instance(id) : null;
  const { data } = useFetchAgentInstanceQuery({ instanceId: id }, { skip: !id });
  const inst: any = data?.instance || null;
  const fetchedAgentId = String(inst?.agent_id || inst?.agentId || '');
  const label =
    String(inst?.display_name || inst?.displayName || '').trim() ||
    known ||
    (fetchedAgentId ? names.agent(fetchedAgentId) : '') ||
    GENERIC_AGENT_LABEL;
  if (!id) return <span className={className}>{label}</span>;
  const path = `/conversations/${encodeURIComponent(id)}${isMobile ? '' : '?panel=tasks'}`;
  return (
    <a
      data-debug-id={`task-holder-link-${id}`}
      href={`#${path}`}
      title={`Open chat with ${label}`}
      className={`hover:underline ${className || ''}`}
      onClick={(event) => {
        event.stopPropagation();
        if (openAgentChat && openAgentChat(id, label)) {
          event.preventDefault();
          return;
        }
        if (isMobile) window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
      }}
    >
      {label}
    </a>
  );
}

export default HolderName;
