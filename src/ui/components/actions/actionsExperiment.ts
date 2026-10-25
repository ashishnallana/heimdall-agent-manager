import type { ExperimentFlag } from '../../api/endpoints/settings';
import { EXPERIMENTAL_SETTINGS_HREF } from '../chat/projectVcsExperiment';
import {
  ACTIONS_EXPERIMENT_KEY,
  resolveActionsExperiment,
  type ExperimentFlagState,
} from '../settings/experimentFlags';

export { ACTIONS_EXPERIMENT_KEY, EXPERIMENTAL_SETTINGS_HREF };

/** Actions access: the flag state, or 'error' when flags failed to load. */
export type ActionsAccess = ExperimentFlagState | 'error';

/**
 * REQ-EXP-GATE-2: resolves Actions access for the UI. Only 'enabled' may show
 * Actions entry points, mount Actions pages or run /actions and
 * /scheduled-prompts queries; a failed experiments fetch never falls through to
 * stale or default flags.
 */
export function resolveActionsAccess(
  flags: readonly ExperimentFlag[] | undefined,
  isError: boolean,
): ActionsAccess {
  if (isError) return 'error';
  return resolveActionsExperiment(flags);
}

/** Shell routes owned by the Actions feature (#/actions, #/actions/new, #/actions/:id[/edit]). */
export function isActionsRoute(path: string): boolean {
  return path === '/actions' || path.startsWith('/actions/');
}

/** Copy for a direct Actions route that may not mount its content. */
export function actionsUnavailableMessage(access: Exclude<ActionsAccess, 'enabled'>): string {
  switch (access) {
    case 'loading':
      return 'Checking whether Actions is enabled…';
    case 'error':
      return 'Actions is unavailable because experimental settings could not be loaded.';
    default:
      return 'Actions is experimental. Enable it in Settings > Experimental to use it.';
  }
}

/**
 * REQ-EXP-GATE-2: drops Actions destinations from a nav list (sidebar, mobile
 * drawer) unless Actions is enabled. Other entries keep their order.
 */
export function filterActionsNavEntries<T extends { path: string }>(items: readonly T[], access: ActionsAccess): T[] {
  return access === 'enabled' ? [...items] : items.filter((item) => !isActionsRoute(item.path));
}
