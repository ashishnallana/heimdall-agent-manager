import React from 'react';
import {
  EXPERIMENTAL_SETTINGS_HREF,
  actionsUnavailableMessage,
  type ActionsAccess,
} from './actionsExperiment';
import { useActionsAccess } from './useActionsAccess';

/**
 * REQ-EXP-GATE-2: shown in place of an Actions route while Actions is loading,
 * disabled or failed to load. The Actions pages (and their /actions and
 * /scheduled-prompts queries) are never mounted behind it.
 */
export function ActionsUnavailableNotice({ access }: { access: Exclude<ActionsAccess, 'enabled'> }) {
  return (
    <section
      data-debug-id={`actions-unavailable-${access}`}
      role="status"
      className="w-full rounded-2xl border border-subtle bg-surface p-6 text-sm text-muted"
    >
      <div className="space-y-2">
        <p>{actionsUnavailableMessage(access)}</p>
        {access === 'loading' ? null : (
          <a
            href={EXPERIMENTAL_SETTINGS_HREF}
            data-debug-id="actions-unavailable-settings-link"
            className="font-semibold text-accent underline"
          >
            Open Experimental settings
          </a>
        )}
      </div>
    </section>
  );
}

/** Mounts `children` only while the Actions experiment is enabled. */
export function ActionsRouteGate({ children }: { children: React.ReactNode }) {
  const access = useActionsAccess();
  if (access !== 'enabled') return <ActionsUnavailableNotice access={access} />;
  return <>{children}</>;
}

export default ActionsRouteGate;
