import { useCallback, useSyncExternalStore, type Dispatch, type SetStateAction, type MutableRefObject } from 'react';
import { deviceVaultUserId } from '../services/deviceVault';
import { desktopBridgeSession } from './desktopBridgeSession';

// One in-memory review per local run. No keys, pairing codes or choices are
// written to routes/storage. Keeping the controller alive lets either host
// resume approval/wait/cancellation after navigating away.
type ReviewStore = { run: unknown; owner: string; fields: Map<string, unknown>; listeners: Set<() => void> };
let current: ReviewStore = { run: null, owner: '', fields: new Map(), listeners: new Set() };
function reviewStore() {
  const run = desktopBridgeSession().lastRun;
  const owner = deviceVaultUserId();
  if (current.run !== run || current.owner !== owner) current = { run, owner, fields: new Map(), listeners: new Set() };
  return current;
}

export function useBridgeIdentityState<T>(key: string, initial: T): [T, Dispatch<SetStateAction<T>>] {
  const store = reviewStore();
  if (!store.fields.has(key)) store.fields.set(key, initial);
  const subscribe = useCallback((listener: () => void) => {
    store.listeners.add(listener);
    return () => { store.listeners.delete(listener); };
  }, [store]);
  const snapshot = useCallback(() => store.fields.get(key) as T, [store, key]);
  const value = useSyncExternalStore(subscribe, snapshot);
  const set = useCallback<Dispatch<SetStateAction<T>>>((next) => {
    const value = typeof next === 'function' ? (next as (previous: T) => T)(store.fields.get(key) as T) : next;
    if (Object.is(store.fields.get(key), value)) return;
    store.fields.set(key, value);
    store.listeners.forEach((listener) => listener());
  }, [store, key]);
  return [value, set];
}

export function useBridgeIdentityRef<T>(key: string, initial: T): MutableRefObject<T> {
  const store = reviewStore();
  if (!store.fields.has(key)) store.fields.set(key, { current: initial });
  return store.fields.get(key) as MutableRefObject<T>;
}

export function hasBridgeIdentityReview(): boolean {
  const store = reviewStore();
  return Boolean(store.fields.get('code') && !store.fields.get('finished'));
}
export function finishBridgeIdentityReview() {
  reviewStore().fields.set('finished', true);
}
