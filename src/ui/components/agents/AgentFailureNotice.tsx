import React from 'react';
import { Text } from '@ui';
import { agentFailureSummary } from '../../utils/agentStatus';

// REQ-ERR-PROTO-A: a failed instance's typed last_error, worded by its class
// ("Needs attention" / "Retrying automatically" / "Failed") with its cause.
export function AgentFailureNotice({ runtimeStatus, lastError }: { runtimeStatus: string; lastError: unknown }) {
  const failure = runtimeStatus.toLowerCase() === 'failed' ? agentFailureSummary(lastError) : null;
  if (!failure) return null;
  return (
    <Text as="div" role="caption" tone="muted" className="mt-1" data-debug-id="live-instance-last-error" title={failure.detail}>
      {failure.label}: {failure.detail}
    </Text>
  );
}
