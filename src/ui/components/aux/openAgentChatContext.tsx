import { createContext, useContext } from 'react';

/**
 * Lets surfaces rendered inside the aux dock (chain overview, tasks) open an
 * agent's chat as an aux sub-agent tab instead of navigating Main to it.
 * Returns true when the click was handled.
 */
export type OpenAgentChatHandler = (agentInstanceId: string, title?: string) => boolean;

export const OpenAgentChatContext = createContext<OpenAgentChatHandler | null>(null);

export function useOpenAgentChat(): OpenAgentChatHandler | null {
  return useContext(OpenAgentChatContext);
}
