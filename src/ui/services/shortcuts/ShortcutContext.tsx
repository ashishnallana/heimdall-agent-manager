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
  SHORTCUT_SEQUENCE_TIMEOUT_MS,
  isActionEnabled,
  matchSequence,
  normalizeShortcutKey,
  shouldIgnoreEvent,
  type AppAction,
} from './shortcutLogic';

type ShortcutContextValue = {
  actions: readonly AppAction[];
  buffer: readonly string[];
  matchingActions: readonly AppAction[];
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
  const timeoutRef = useRef<number | null>(null);
  const [registryVersion, setRegistryVersion] = useState(0);
  const [buffer, setBuffer] = useState<readonly string[]>([]);
  const [cheatsheetOpen, setCheatsheetOpen] = useState(false);

  const clearSequence = useCallback(() => {
    if (timeoutRef.current !== null) window.clearTimeout(timeoutRef.current);
    timeoutRef.current = null;
    bufferRef.current = [];
    setBuffer([]);
  }, []);

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
    const scheduleClear = () => {
      if (timeoutRef.current !== null) window.clearTimeout(timeoutRef.current);
      timeoutRef.current = window.setTimeout(clearSequence, SHORTCUT_SEQUENCE_TIMEOUT_MS);
    };

    const applyMatch = (event: KeyboardEvent, keys: readonly string[]) => {
      const match = matchSequence(keys, actionsRef.current);
      if (match.kind === 'none') return false;

      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      if (match.kind === 'exact') {
        clearSequence();
        match.action.run();
      } else {
        bufferRef.current = keys;
        setBuffer(keys);
        scheduleClear();
      }
      return true;
    };

    const onKeyDown = (event: KeyboardEvent) => {
      const key = normalizeShortcutKey(event.key);
      if (key === 'escape') {
        clearSequence();
        return;
      }
      if (!key || shouldIgnoreEvent(event)) {
        if (bufferRef.current.length > 0) clearSequence();
        return;
      }

      const candidate = [...bufferRef.current, key];
      if (applyMatch(event, candidate)) return;

      // A mismatch ends the old chord, but the same key may begin another one.
      clearSequence();
      applyMatch(event, [key]);
    };

    window.addEventListener('keydown', onKeyDown, true);
    return () => {
      window.removeEventListener('keydown', onKeyDown, true);
      if (timeoutRef.current !== null) window.clearTimeout(timeoutRef.current);
    };
  }, [clearSequence]);

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
    cheatsheetOpen,
    setCheatsheetOpen,
    registerActions,
    runAction,
    clearSequence,
  }), [actions, buffer, matchingActions, cheatsheetOpen, registerActions, runAction, clearSequence]);

  return <ShortcutContext.Provider value={value}>{children}</ShortcutContext.Provider>;
}

export function useShortcuts(): ShortcutContextValue {
  const context = useContext(ShortcutContext);
  if (!context) throw new Error('useShortcuts must be used within ShortcutProvider');
  return context;
}
