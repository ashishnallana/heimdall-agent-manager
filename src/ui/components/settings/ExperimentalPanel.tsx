import { useState } from 'react';
import { useFetchExperimentsQuery, useSetExperimentMutation } from '../../api/endpoints/settings';
import { apiErrorText } from '../../api/cookieFetch';
import { EXPERIMENTAL_FLAGS } from './experimentFlags';
import { PageShell, Panel, Toggle } from '@ui';

// REQ-EXP-2: Experimental flags panel. Absent key from the API means disabled —
// we never treat absence as indeterminate or as an error. Default-on flags (today:
// streaming_terminal_pane) are listed by the hub as enabled until the user turns them off.
const KNOWN_FLAGS = EXPERIMENTAL_FLAGS;

export default function ExperimentalPanel() {
  const { data, isLoading, isError } = useFetchExperimentsQuery();
  const [setExperiment] = useSetExperimentMutation();
  const [toggleError, setToggleError] = useState<string | null>(null);

  function isEnabled(key: string): boolean {
    if (!data?.flags) return false;
    const match = data.flags.find((f) => f.key === key);
    return match ? match.enabled : false;
  }

  async function onToggle(key: string, next: boolean) {
    setToggleError(null);
    try {
      await setExperiment({ key, enabled: next }).unwrap();
    } catch (err: any) {
      setToggleError(apiErrorText(err, 'Failed to save. Please try again.'));
    }
  }

  return (
    <PageShell
      title="Experimental"
      description="These features are under active development. They may change, break, or be removed without notice."
    >
      <div data-debug-id="settings-experimental-panel" className="space-y-4 text-left">
        {isLoading ? (
          <p className="text-sm text-muted">Loading…</p>
        ) : isError ? (
          <p className="text-sm text-danger" data-debug-id="settings-experimental-error">
            Could not load experimental features. Check your connection and reload.
          </p>
        ) : KNOWN_FLAGS.length === 0 ? (
          <p className="text-sm text-muted">No experimental features are available.</p>
        ) : (
          <>
            {toggleError && (
              <p className="text-sm text-danger" data-debug-id="settings-experimental-toggle-error">{toggleError}</p>
            )}
            <Panel>
              <div className="space-y-5">
                {KNOWN_FLAGS.map((flag, idx) => (
                  <div key={flag.key}>
                    {idx > 0 && <div className="border-t border-subtle -mx-5 mb-5" />}
                    <div className="flex items-start justify-between gap-4">
                      <div>
                        <div className="text-sm font-semibold text-primary">{flag.label}</div>
                        <p className="mt-1 text-xs text-muted">{flag.description}</p>
                      </div>
                      <Toggle
                        checked={isEnabled(flag.key)}
                        onChange={(next) => void onToggle(flag.key, next)}
                        data-debug-id={`settings-experimental-toggle-${flag.key}`}
                        aria-label={flag.label}
                      />
                    </div>
                  </div>
                ))}
              </div>
            </Panel>
          </>
        )}
      </div>
    </PageShell>
  );
}
