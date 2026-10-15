import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import {
  getSequenceCommitAction,
  isActionEnabled,
  isEditableShortcutTarget,
  isShortcutOverrideTrigger,
  matchSequence,
  normalizeShortcutKey,
  resolveShortcutMode,
  shouldIgnoreEvent,
  type AppAction,
  type ShortcutMode,
} from './shortcutLogic';

type ShortcutContextValue = {
  actions: readonly AppAction[];
  buffer: readonly string[];
  matchingActions: readonly AppAction[];
  mode: ShortcutMode;
  cheatsheetOpen: boolean;
  setCheatsheetOpen: (open: boolean) => void;
  registerActions: (actions: readonly AppAction[]) => () => void;
  runAction: (actionId: string) => boolean;
  clearSequence: () => void;
};

const ShortcutContext = createContext<ShortcutContextValue | null>(null);

export function ShortcutProvider({ children }: { children: ReactNode }) {
  const registrationsRef = useRef(new Map<symbol, readonly AppAction[]>());
  const actionsRef = useRef<readonly AppAction[]>([]);
  const bufferRef = useRef<readonly string[]>([]);
  const editableOverrideRef = useRef(false);
  const [registryVersion, setRegistryVersion] = useState(0);
  const [buffer, setBuffer] = useState<readonly string[]>([]);
  const [mode, setMode] = useState<ShortcutMode>('normal');
  const [cheatsheetOpen, setCheatsheetOpen] = useState(false);

  const syncMode = useCallback((editableOverride = editableOverrideRef.current) => {
    const activeTarget = typeof document === 'undefined' ? null : document.activeElement;
    setMode(resolveShortcutMode(activeTarget, editableOverride));
  }, []);

  const setEditableOverride = useCallback((enabled: boolean) => {
    editableOverrideRef.current = enabled;
    syncMode(enabled);
  }, [syncMode]);

  const clearSequence = useCallback(() => {
    bufferRef.current = [];
    setEditableOverride(false);
    setBuffer([]);
  }, [setEditableOverride]);

  useEffect(() => {
    const onFocusIn = (event: FocusEvent) => {
      editableOverrideRef.current = false;
      setMode(resolveShortcutMode(event.target, false));
    };
    const onFocusOut = (event: FocusEvent) => {
      editableOverrideRef.current = false;
      setMode(resolveShortcutMode(event.relatedTarget, false));
    };

    syncMode();
    window.addEventListener('focusin', onFocusIn, true);
    window.addEventListener('focusout', onFocusOut, true);
    return () => {
      window.removeEventListener('focusin', onFocusIn, true);
      window.removeEventListener('focusout', onFocusOut, true);
    };
  }, [syncMode]);

  const registerActions = useCallback((registeredActions: readonly AppAction[]) => {
    const token = Symbol('shortcut-registration');
    registrationsRef.current.set(token, registeredActions);
    setRegistryVersion((version) => version + 1);

    return () => {
      if (!registrationsRef.current.delete(token)) return;
      setRegistryVersion((version) => version + 1);
    };
  }, []);

  const actions = useMemo(() => {
    const byId = new Map<string, AppAction>();
    const builtInActions: AppAction[] = [{
      id: 'shortcut.cheatsheet',
      title: 'Show keyboard shortcuts',
      category: 'General',
      sequence: ['?'],
      run: () => setCheatsheetOpen((open) => !open),
    }];

    for (const action of builtInActions) byId.set(action.id, action);
    for (const registration of registrationsRef.current.values()) {
      for (const action of registration) byId.set(action.id, action);
    }
    return Array.from(byId.values());
  }, [registryVersion]);
  actionsRef.current = actions;

  const runAction = useCallback((actionId: string) => {
    const action = actionsRef.current.find((candidate) => candidate.id === actionId);
    if (!action || !isActionEnabled(action)) return false;
    action.run();
    return true;
  }, []);

  useEffect(() => {
    const applyMatch = (event: KeyboardEvent, keys: readonly string[]) => {
      const match = matchSequence(keys, actionsRef.current);
      if (match.kind === 'none') return match.kind;

      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      if (match.kind === 'exact') {
        clearSequence();
        match.action.run();
      } else {
        bufferRef.current = keys;
        setBuffer(keys);
      }
      return match.kind;
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (isShortcutOverrideTrigger(event) && isEditableShortcutTarget(event.target)) {
        clearSequence();
        setEditableOverride(true);
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        return;
      }

      if (
        event.key === 'Enter'
        && bufferRef.current.length > 0
        && !shouldIgnoreEvent(event, editableOverrideRef.current)
      ) {
        const action = getSequenceCommitAction(bufferRef.current, actionsRef.current);
        clearSequence();
        if (action && isActionEnabled(action)) {
          event.preventDefault();
          event.stopPropagation();
          event.stopImmediatePropagation();
          action.run();
        }
        return;
      }

      const key = normalizeShortcutKey(event.key);
      if (key === 'escape') {
        clearSequence();
        return;
      }
      if (!key || shouldIgnoreEvent(event, editableOverrideRef.current)) {
        if (bufferRef.current.length > 0) clearSequence();
        return;
      }

      const candidate = [...bufferRef.current, key];
      if (applyMatch(event, candidate) !== 'none') return;

      // A mismatch ends the old chord, but the same key may begin another one.
      const preserveOverride = editableOverrideRef.current;
      clearSequence();
      const restarted = applyMatch(event, [key]);
      if (preserveOverride && restarted === 'prefix') setEditableOverride(true);
    };

    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [clearSequence, setEditableOverride]);

  const matchingActions = useMemo(() => {
    if (buffer.length === 0) return [];
    return actions.filter((action) => (
      isActionEnabled(action)
      && action.sequence.length > buffer.length
      && buffer.every((key, index) => action.sequence[index] === key)
    ));
  }, [actions, buffer]);

  const value = useMemo<ShortcutContextValue>(() => ({
    actions,
    buffer,
    matchingActions,
    mode,
    cheatsheetOpen,
    setCheatsheetOpen,
    registerActions,
    runAction,
    clearSequence,
  }), [actions, buffer, matchingActions, mode, cheatsheetOpen, registerActions, runAction, clearSequence]);

  return <ShortcutContext.Provider value={value}>{children}</ShortcutContext.Provider>;
}

export function useShortcuts(): ShortcutContextValue {
  const context = useContext(ShortcutContext);
  if (!context) throw new Error('useShortcuts must be used within ShortcutProvider');
  return context;
}
