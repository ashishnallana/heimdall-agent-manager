import { forwardRef, useEffect, useImperativeHandle, useRef, type TextareaHTMLAttributes, type ReactNode } from 'react';
import { Icon, Spinner, StatusDot, type StatusDotProps } from '@ui';
import ProviderIcon from '../providers/ProviderIcon';

export const MessageComposerInput = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement> & { mobile: boolean; debugId: string }>(function MessageComposerInput({ mobile, debugId, ...props }, forwardedRef) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useImperativeHandle(forwardedRef, () => ref.current!, []);
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
  }, [mobile, props.value]);
  return <textarea {...props} ref={ref} data-debug-id={debugId} rows={mobile ? 1 : 2} className={mobile ? 'block min-h-6 max-h-[72px] w-full resize-none bg-transparent p-0 text-base leading-6 text-primary outline-none placeholder:text-muted' : 'min-h-[44px] w-full resize-none bg-transparent px-1 py-1 text-sm text-primary outline-none placeholder:text-muted'} />;
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
      {onOpenTasks ? <button type="button" data-debug-id={`${p}-tasks-btn`} aria-label="Open tasks" onClick={onOpenTasks} className={`grid ${btn} place-items-center text-muted hover:bg-neutral-soft`}><Icon name="tasks" size={iconSize} /></button> : null}
      {extraActions}
    </div> : <span />}
    <div className="ml-auto flex min-w-0 items-center justify-end gap-1.5 sm:gap-2">
      <button type="button" data-debug-id={`${p}-runtime-menu-btn`} aria-haspopup="dialog" aria-label="Choose bridge, provider and model" title={model || undefined} onClick={onSettings} className={`inline-flex ${mobile ? 'h-10 rounded-full' : 'h-9 rounded-xl'} min-w-0 max-w-[180px] items-center gap-1.5 border border-subtle bg-surface-raised px-2.5 text-sm text-primary hover:bg-neutral-soft`}><ProviderIcon provider={provider} size={16} />{!compactModel ? <><span className="min-w-0 truncate font-semibold">{model || 'Choose model'}</span><Icon name="chevron-down" size={14} className="shrink-0" /></> : null}</button>
      {pendingActions || send}
    </div>
  </div>;
}

/** Runtime indicator for the composer card's top-right corner: the real StatusDot, plus a
 *  Spinner while the agent is starting, stopping or working. Rendered inside a button by the
 *  caller (which owns the start/stop menu). */
export function MessageComposerStatus({ debugPrefix: p, tone, label, busy }: { debugPrefix: string; tone: StatusDotProps['tone']; label: string; busy: boolean }) {
  return <span data-debug-id={`${p}-composer-status`} className="inline-flex items-center gap-1.5">
    {busy ? <Spinner size="sm" label={label} className="text-muted" /> : null}
    <StatusDot size="sm" tone={tone} label={label} />
  </span>;
}
