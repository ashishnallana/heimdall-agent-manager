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
