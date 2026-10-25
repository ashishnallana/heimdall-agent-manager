import { useMemo } from 'react';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { resolveActionsAccess, type ActionsAccess } from './actionsExperiment';

/** Live Actions access from the shared experiments query (toggles apply without reload). */
export function useActionsAccess(): ActionsAccess {
  const { data, isError } = useFetchExperimentsQuery();
  return useMemo(() => resolveActionsAccess(data?.flags, isError), [data?.flags, isError]);
}
