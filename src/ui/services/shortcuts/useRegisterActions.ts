import { useEffect, useRef } from 'react';
import { useShortcuts } from './ShortcutContext';
import { actionDescriptorKey, type AppAction } from './shortcutLogic';

/**
 * Registers component-scoped actions without re-registering inline arrays whose
 * descriptors are unchanged. Execution and enablement always read fresh callbacks.
 */
export function useRegisterActions(actions: readonly AppAction[]): void {
  const { registerActions } = useShortcuts();
  const latestActionsRef = useRef(actions);
  latestActionsRef.current = actions;

  const descriptorKey = actionDescriptorKey(actions);
  useEffect(() => {
    const registeredActions = actions.map<AppAction>((action) => ({
      id: action.id,
      title: action.title,
      category: action.category,
      sequence: [...action.sequence],
      isEnabled: action.isEnabled
        ? () => latestActionsRef.current.find((candidate) => candidate.id === action.id)?.isEnabled?.() !== false
        : undefined,
      run: () => latestActionsRef.current.find((candidate) => candidate.id === action.id)?.run(),
    }));

    return registerActions(registeredActions);
    // descriptorKey intentionally captures every registration field except callbacks.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [registerActions, descriptorKey]);
}
