import type { ExperimentFlag } from '../../api/endpoints/settings';

export const PROJECT_VCS_EXPERIMENT_KEY = 'project_vcs';

export type ProjectVcsExperimentState = 'loading' | 'disabled' | 'enabled';

/**
 * Resolves the per-user Project/VCS experiment without conflating a pending
 * request with a loaded response where the key is absent.
 *
 * The API guarantees unique, well-typed flags. If that contract is violated,
 * fail closed: malformed or duplicate Project/VCS entries cannot enable UI.
 */
export function resolveProjectVcsExperiment(
  flags: readonly ExperimentFlag[] | undefined,
): ProjectVcsExperimentState {
  if (flags === undefined) return 'loading';

  const matches = flags.filter(
    (flag) => flag != null && flag.key === PROJECT_VCS_EXPERIMENT_KEY,
  );
  if (matches.length !== 1 || typeof matches[0].enabled !== 'boolean') {
    return 'disabled';
  }
  return matches[0].enabled ? 'enabled' : 'disabled';
}
