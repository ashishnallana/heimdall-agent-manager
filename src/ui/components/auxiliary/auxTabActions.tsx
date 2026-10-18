import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import type { IconName } from '@ui';

/**
 * Per-active-tab actions for the aux ⋮ menu.
 *
 * Aux tabs render ONLY their content; the few actions worth keeping (reload a
 * preview, restart an agent, kill a shell, ...) are registered by the mounted
 * tab with {@link useAuxTabActions} and rendered by the dock's ⋮ menu. Only the
 * active tab is mounted, so the menu always reflects the active tab.
 */
export interface AuxTabAction {
  id: string;
  label: string;
  icon?: IconName;
  disabled?: boolean;
  tone?: 'danger';
  onSelect: () => void;
}

type Setter = (actions: AuxTabAction[] | null) => void;

const AuxTabActionsContext = createContext<Setter | null>(null);

function signature(actions: AuxTabAction[] | null): string {
  if (!actions) return '';
  return actions.map((a) => `${a.id}|${a.label}|${a.icon || ''}|${a.disabled ? 1 : 0}|${a.tone || ''}`).join('\n');
}

/**
 * Holds the active tab's registered actions. Re-renders only when the action
 * list visibly changes (ids/labels/disabled), never on closure identity, so a
 * tab re-registering every render cannot loop.
 */
export function useAuxTabActionsHost(): {
  actions: AuxTabAction[];
  setActions: Setter;
} {
  const ref = useRef<AuxTabAction[] | null>(null);
  const [sig, setSig] = useState('');
  const setActions = useCallback<Setter>((next) => {
    ref.current = next;
    const s = signature(next);
    setSig((prev) => (prev === s ? prev : s));
  }, []);
  const actions = useMemo(() => {
    void sig;
    return (ref.current || []).map((a) => ({
      ...a,
      // Always invoke the latest closure registered for this id.
      onSelect: () => ref.current?.find((x) => x.id === a.id)?.onSelect(),
    }));
  }, [sig]);
  return { actions, setActions };
}

export function AuxTabActionsProvider({
  setActions,
  children,
}: {
  setActions: Setter;
  children: React.ReactNode;
}) {
  return (
    <AuxTabActionsContext.Provider value={setActions}>{children}</AuxTabActionsContext.Provider>
  );
}

/** Registers the mounted tab's ⋮ menu actions (no-op outside an aux dock). */
export function useAuxTabActions(actions: AuxTabAction[]): void {
  const set = useContext(AuxTabActionsContext);
  useEffect(() => {
    set?.(actions);
  });
  useEffect(() => () => set?.(null), [set]);
}
