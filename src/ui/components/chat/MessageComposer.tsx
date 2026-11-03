import { forwardRef, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef, useState, type TextareaHTMLAttributes, type ReactNode } from 'react';
import { Icon, StatusDot, type StatusDotProps } from '@ui';
import ProviderIcon from '../providers/ProviderIcon';
import { useSelector } from 'react-redux';
import { selectUseExternalKeyboard } from '../../store/inputPreferencesSlice';

/**
 * `appearance`: `pane` (default) is the conversation pane's compact field. `launch`
 * is the new-conversation composer's field: flush (no padding), 72px tall on
 * desktop, body 14/20; `mono` sets it in the code face (the shell command field).
 */
export type MessageComposerInputProps = TextareaHTMLAttributes<HTMLTextAreaElement> & { mobile: boolean; debugId: string; appearance?: 'pane' | 'launch'; mono?: boolean };
const COMPOSER_INPUT_BASE = 'w-full resize-none bg-transparent text-primary outline-none placeholder:text-muted';
function composerInputClassName(mobile: boolean, appearance: 'pane' | 'launch', mono: boolean): string {
  const face = mono ? 'font-mono text-code leading-5' : '';
  if (mobile) return `block min-h-6 max-h-[72px] ${COMPOSER_INPUT_BASE} p-0 ${mono ? face : 'text-base leading-6'}`;
  if (appearance === 'launch') return `block min-h-[72px] ${COMPOSER_INPUT_BASE} p-0 ${mono ? face : 'text-sm leading-5'}`;
  return `min-h-[44px] ${COMPOSER_INPUT_BASE} px-1 py-1 ${mono ? face : 'text-sm'}`;
}

export const MessageComposerInput = forwardRef<HTMLTextAreaElement, MessageComposerInputProps>(function MessageComposerInput({ mobile, debugId, appearance = 'pane', mono = false, ...props }, forwardedRef) {
  const useExternalKeyboard = useSelector(selectUseExternalKeyboard);
  const ref = useRef<HTMLTextAreaElement>(null);
  const requestedMode = useExternalKeyboard ? 'none' : 'text';
  const [inputMode, setInputMode] = useState<'none' | 'text'>(requestedMode);
  const composing = useRef(false);
  const latestMode = useRef<'none' | 'text'>(requestedMode);
  const compositionTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useLayoutEffect(() => {
    latestMode.current = requestedMode;
    if (!composing.current) setInputMode(requestedMode);
  }, [requestedMode]);
  useEffect(() => () => clearTimeout(compositionTimer.current), []);
  const previousEditor = useRef<{
    value: string; start: number; end: number;
    direction: 'forward' | 'backward' | 'none'; focused: boolean; scrollTop: number;
  } | null>(null);
  const attachInput = useCallback((input: HTMLTextAreaElement | null) => {
    const previous = ref.current;
    if (!input && previous) {
      previousEditor.current = {
        value: previous.value, start: previous.selectionStart, end: previous.selectionEnd,
        direction: previous.selectionDirection, focused: document.activeElement === previous,
        scrollTop: previous.scrollTop,
      };
    }
    ref.current = input;
  }, []);
  useImperativeHandle(forwardedRef, () => ref.current!, [inputMode]);
  useLayoutEffect(() => {
    const input = ref.current;
    const previous = previousEditor.current;
    previousEditor.current = null;
    if (!input || !previous) return;
    // Controlled drafts live in the caller; also retain native uncontrolled edits.
    if (props.value === undefined) input.value = previous.value;
    input.setSelectionRange(previous.start, previous.end, previous.direction);
    if (previous.focused && !input.disabled) input.focus({ preventScroll: true });
    input.scrollTop = previous.scrollTop;
  }, [inputMode, props.value]);
  useEffect(() => {
    const input = ref.current; if (!input) return;
    const resize = () => { input.style.height = mobile ? 'auto' : ''; if (mobile) input.style.height = `${Math.min(72, Math.max(24, input.scrollHeight))}px`; input.style.overflowY = mobile && input.scrollHeight > 72 ? 'auto' : ''; };
    resize();
    // Height is owned by resize(); react only to width changes, outside the
    // observer delivery, to avoid a resize/notification feedback loop.
    let width = input.clientWidth;
    let frame = 0;
    const observer = new ResizeObserver(() => {
      if (input.clientWidth === width) return;
      width = input.clientWidth;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(resize);
    });
    observer.observe(input);
    return () => { observer.disconnect(); cancelAnimationFrame(frame); };
  }, [mobile, props.value, inputMode]);
  // Replace the native editor so a mode change starts a fresh input connection,
  // just as mounting the original forced-none experiment did.
  return <textarea {...props} key={inputMode} inputMode={inputMode} ref={attachInput}
    onCompositionStart={event => {
      clearTimeout(compositionTimer.current);
      composing.current = true;
      props.onCompositionStart?.(event);
    }}
    onCompositionEnd={event => {
      clearTimeout(compositionTimer.current);
      props.onCompositionEnd?.(event);
      // Browsers emit the final input after compositionend. Keep its native editor
      // alive through that event so the caller receives the committed draft.
      compositionTimer.current = setTimeout(() => {
        composing.current = false;
        setInputMode(latestMode.current);
      }, 0);
    }}
    data-debug-id={debugId} rows={mobile ? 1 : 2} className={composerInputClassName(mobile, appearance, mono)} />;
});

export type ComposerActionsProps = {
  debugPrefix: string; mobile: boolean; compactModel?: boolean; provider: string; model: string;
  onSettings: () => void; onUpload: () => void; uploadDisabled?: boolean;
  onPaneToggle?: () => void; paneExpanded?: boolean; sendDisabled: boolean;
  /** Opens the chain's Tasks surface; the button is hidden when omitted (no chain). */
  onOpenTasks?: () => void;
  pendingActions?: ReactNode; readOnly?: boolean;
  /** Extra buttons after upload/terminal/tasks in the toolbar's leading group. */
  extraActions?: ReactNode;
};
/** Bottom row of the composer card: upload, terminal, tasks | model pill, send. Same
 *  controls on every form factor; mobile only gets larger tap targets. */
export function MessageComposerActions({ debugPrefix: p, mobile, compactModel, provider, model, onSettings, onUpload, uploadDisabled, onPaneToggle, paneExpanded, sendDisabled, onOpenTasks, pendingActions, readOnly, extraActions }: ComposerActionsProps) {
  const btn = mobile ? 'h-10 w-10 rounded-full' : 'h-9 w-9 rounded-xl';
  const iconSize = mobile ? 20 : 18;
  const send = !readOnly && !pendingActions ? <button type="submit" data-debug-id={`${p}-composer-send-btn`} disabled={sendDisabled} aria-label="Send message" className={`grid ${btn} shrink-0 place-items-center bg-accent text-accent-fg disabled:opacity-40`}><Icon name="arrow-up" size={iconSize} /></button> : null;
  return <div data-debug-id={`${p}-composer-toolbar`} className="mt-2 flex min-w-0 items-center justify-between gap-1.5">
    {!pendingActions && !readOnly ? <div className="flex shrink-0 items-center gap-0.5 sm:gap-1.5">
      <button type="button" data-debug-id={`${p}-attach-btn`} disabled={uploadDisabled} aria-label="Upload attachment" onClick={onUpload} className={`grid ${btn} place-items-center text-muted hover:bg-neutral-soft disabled:opacity-40`}><Icon name="plus" size={mobile ? 22 : 19} /></button>
      {onPaneToggle ? <button type="button" data-debug-id={`${p}-request-pane-btn`} aria-label="Open terminal" aria-pressed={paneExpanded} onClick={onPaneToggle} className={`grid ${btn} place-items-center ${paneExpanded ? 'bg-accent/20 text-accent' : 'text-muted hover:bg-neutral-soft'}`}><Icon name="terminal" size={iconSize} /></button> : null}
      {onOpenTasks ? <button type="button" data-debug-id={`${p}-tasks-btn`} aria-label="Open tickets" onClick={onOpenTasks} className={`grid ${btn} place-items-center text-muted hover:bg-neutral-soft`}><Icon name="tasks" size={iconSize} /></button> : null}
      {extraActions}
    </div> : <span />}
    <div className="ml-auto flex min-w-0 items-center justify-end gap-1.5 sm:gap-2">
      <button type="button" data-debug-id={`${p}-runtime-menu-btn`} aria-haspopup="dialog" aria-label="Choose bridge, provider and model" title={model || undefined} onClick={onSettings} className={`inline-flex ${mobile ? 'h-10 rounded-full' : 'h-9 rounded-xl'} min-w-0 max-w-[180px] items-center gap-1.5 border border-subtle bg-surface-raised px-2.5 text-sm text-primary hover:bg-neutral-soft`}><ProviderIcon provider={provider} size={16} />{!compactModel ? <><span className="min-w-0 truncate font-semibold">{model || 'Choose model'}</span><Icon name="chevron-down" size={14} className="shrink-0" /></> : null}</button>
      {pendingActions || send}
    </div>
  </div>;
}

/** Runtime indicator for the composer card's top-right corner: the real StatusDot only.
 *  Rendered inside a button by the caller (which owns the start/stop menu). */
export function MessageComposerStatus({ debugPrefix: p, tone, label }: { debugPrefix: string; tone: StatusDotProps['tone']; label: string }) {
  return <span data-debug-id={`${p}-composer-status`} className="inline-flex items-center">
    <StatusDot size="sm" tone={tone} label={label} />
  </span>;
}
