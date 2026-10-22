import React from 'react';
import { planLimitMessage, type PlanLimitDetails } from '../../utils/planLimit';

export default function UpgradePrompt({ details = {}, debugId = 'upgrade-prompt', subtle = false, onDismiss, onRetry }: {
  details?: PlanLimitDetails;
  debugId?: string;
  subtle?: boolean;
  onDismiss?: () => void;
  onRetry?: () => void;
}) {
  return (
    <div role="status" data-debug-id={debugId} className={`flex shrink-0 flex-wrap items-center gap-2 rounded-lg px-3 py-2 text-xs ${subtle ? 'bg-surface-raised text-muted' : 'border border-warning/30 bg-warning-soft text-primary'}`}>
      <span>{subtle && details.limit === 'terminal_input_enabled' ? <><strong className="font-medium text-primary">View-only</strong><span className="ml-2">Terminal input is disabled on your plan.</span></> : planLimitMessage(details)}</span>
      <a data-debug-id={`${debugId}-upgrade`} href="#/settings/account" className={subtle ? 'ml-auto text-muted underline underline-offset-2 hover:text-primary' : 'font-semibold text-accent underline'}>{subtle ? 'Upgrade plan' : 'Upgrade'}</a>
      {onRetry && <button type="button" data-debug-id={`${debugId}-retry`} onClick={onRetry} className="font-medium text-primary underline">Retry</button>}
      {onDismiss && <button type="button" data-debug-id={`${debugId}-dismiss`} onClick={onDismiss} className="ml-auto text-muted" aria-label="Dismiss upgrade prompt">Dismiss</button>}
    </div>
  );
}
