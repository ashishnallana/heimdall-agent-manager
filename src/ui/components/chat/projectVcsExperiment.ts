import type { ExperimentFlag } from '../../api/endpoints/settings';
import {
  PROJECT_VCS_EXPERIMENT_KEY,
  resolveExperimentFlag,
  type ExperimentFlagState,
} from '../settings/experimentFlags';

export { PROJECT_VCS_EXPERIMENT_KEY };

export type ProjectVcsExperimentState = ExperimentFlagState;

/**
 * Resolves the per-user Project/VCS experiment; see resolveExperimentFlag for
 * the loading/absent/malformed (fail closed) rules.
 */
export function resolveProjectVcsExperiment(
  flags: readonly ExperimentFlag[] | undefined,
): ProjectVcsExperimentState {
  return resolveExperimentFlag(flags, PROJECT_VCS_EXPERIMENT_KEY);
}

/** Project Explorer access: the flag state, or 'error' when flags failed to load. */
export type ProjectExplorerAccess = ProjectVcsExperimentState | 'error';

/**
 * REQ-EXP-GATE-2: resolves explorer access for the UI. Only 'enabled' may mount
 * explorer content or run its file/VCS/search queries; a failed experiments fetch
 * never falls through to stale or default flags.
 */
export function resolveProjectExplorerAccess(
  flags: readonly ExperimentFlag[] | undefined,
  isError: boolean,
): ProjectExplorerAccess {
  if (isError) return 'error';
  return resolveProjectVcsExperiment(flags);
}

/** Settings route the explorer unavailable screen links to. */
export const EXPERIMENTAL_SETTINGS_HREF = '#/settings/experimental';

/** Copy for a restored or direct explorer view that may not mount its content. */
export function projectExplorerUnavailableMessage(access: Exclude<ProjectExplorerAccess, 'enabled'>): string {
  switch (access) {
    case 'loading':
      return 'Checking whether Project Explorer is enabled…';
    case 'error':
      return 'Project Explorer is unavailable because experimental settings could not be loaded.';
    default:
      return 'Project Explorer is experimental. Enable it in Settings > Experimental to use it.';
  }
}
