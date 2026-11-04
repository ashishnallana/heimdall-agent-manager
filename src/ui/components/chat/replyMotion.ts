import { useLayoutEffect, useRef, useSyncExternalStore } from 'react';
import { STREAM_MAX_TOTAL_MS } from './streamReveal';
import type { ChatMessage } from './types';

// Shared state for the incoming-reply animation. It is module-level, so a remounted
// row never replays its motion.
//
// - A "scope" is a conversation (ChatMessageList's conversationKey).
// - A reply that arrives live runs revealing -> settled. History rows never enter the
//   map and render instantly. The working indicator (AgentActivityBubbles) is untouched.
// - A reply settles when its body finishes the reveal (or renders without one). A safety
//   timer settles it anyway after REPLY_SETTLE_DEADLINE_MS, so a body that never reports
//   back cannot hold its chrome forever.
// - When a list leaves a scope (conversation switch or unmount), the scope's replies are
//   forgotten: on return they are history and render instantly, and the map stays small.

export type ReplyPhase = 'revealing' | 'settled';
type ReplyState = { scope: string; phase: ReplyPhase };

const replies = new Map<string, ReplyState>();
const deadlines = new Map<string, ReturnType<typeof setTimeout>>();
/** A live reply settles no later than this after it begins (the reveal's own bound plus margin). */
export const REPLY_SETTLE_DEADLINE_MS = STREAM_MAX_TOTAL_MS + 1000;
const clearDeadline = (key: string) => {
  const timer = deadlines.get(key);
  if (timer === undefined) return;
  clearTimeout(timer);
  deadlines.delete(key);
};
const listeners = new Set<() => void>();
let version = 0;
const emit = () => {
  version += 1;
  for (const listener of [...listeners]) listener();
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
};
const getVersion = () => version;

/** Starts a live reply's motion. */
export function beginReply(scope: string, key: string): void {
  if (replies.has(key)) return;
  replies.set(key, { scope, phase: 'revealing' });
  deadlines.set(key, setTimeout(() => settleReply(key), REPLY_SETTLE_DEADLINE_MS));
  emit();
}

export function settleReply(key: string): void {
  clearDeadline(key);
  const reply = replies.get(key);
  if (!reply || reply.phase === 'settled') return;
  replies.set(key, { ...reply, phase: 'settled' });
  emit();
}

/** Forgets every reply in `scope`, so they render as history from now on. */
export function forgetScopeReplies(scope: string): void {
  let changed = false;
  for (const [key, reply] of replies) {
    if (reply.scope !== scope) continue;
    clearDeadline(key);
    replies.delete(key);
    changed = true;
  }
  if (changed) emit();
}

export function replyPhase(key: string): ReplyPhase | null {
  return replies.get(key)?.phase || null;
}

/** Re-renders the caller whenever any reply-motion state changes. */
export function useReplyMotionVersion(): number {
  return useSyncExternalStore(subscribe, getVersion, getVersion);
}

/** Test hook: forget all motion state. */
export function resetReplyMotion(): void {
  for (const key of [...deadlines.keys()]) clearDeadline(key);
  replies.clear();
  emit();
}

/** A reply eligible for the reveal: the agent's own plain text (not cards, dividers or groups). */
export function isRevealableReply(message: ChatMessage): boolean {
  return !message.isUser && (!message.messageType || message.messageType === 'text');
}

/**
 * Marks agent replies that arrive live in `scope`. The first non-empty page of a
 * conversation (and any switch to another one) is history. After that, a revealable
 * message appended below the previously last row begins its motion. Older pages are
 * prepended above and never animate. When `disabled` (reduced motion), nothing is
 * marked, so everything renders instantly.
 */
export function useLiveReplies(scope: string, messages: ChatMessage[], disabled: boolean): void {
  const baseline = useRef<{ scope: string; keys: Set<string> | null; last: string | null }>({ scope, keys: null, last: null });
  useLayoutEffect(() => {
    const state = baseline.current;
    if (state.scope !== scope) {
      state.scope = scope;
      state.keys = null;
      state.last = null;
    }
    if (messages.length === 0) return;
    if (!state.keys) {
      state.keys = new Set(messages.map((message) => message.key));
      state.last = messages[messages.length - 1].key;
      return;
    }
    const lastIndex = state.last ? messages.findIndex((message) => message.key === state.last) : -1;
    messages.forEach((message, index) => {
      if (state.keys!.has(message.key)) return;
      state.keys!.add(message.key);
      if (!disabled && index > lastIndex && isRevealableReply(message)) beginReply(scope, message.key);
    });
    state.last = messages[messages.length - 1].key;
  }, [scope, messages, disabled]);
  // Leaving a scope (switch or unmount) mid-reveal must not replay it on return.
  useLayoutEffect(() => () => forgetScopeReplies(scope), [scope]);
}
