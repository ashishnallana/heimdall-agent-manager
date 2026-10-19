import { forwardRef, useEffect, useImperativeHandle, useRef, useState, type TextareaHTMLAttributes, type ReactNode } from 'react';
import { Icon, Menu } from '@ui';
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
  debugPrefix: string; mobile: boolean; inline?: boolean; compactModel?: boolean; provider: string; model: string;
  onSettings: () => void; onUpload: () => void; uploadDisabled?: boolean;
  onPaneToggle?: () => void; paneExpanded?: boolean; sendDisabled: boolean;
  pendingActions?: ReactNode; readOnly?: boolean;
  /** Extra buttons after upload/terminal in the desktop toolbar's leading group. */
  extraActions?: ReactNode;
};
export function MessageComposerActions({ debugPrefix: p, mobile, inline, compactModel, provider, model, onSettings, onUpload, uploadDisabled, onPaneToggle, paneExpanded, sendDisabled, pendingActions, readOnly, extraActions }: ComposerActionsProps) {
  const [moreOpen, setMoreOpen] = useState(false);
  const more = <Menu side="top" align="end" label="Composer options" open={moreOpen} onOpenChange={setMoreOpen} trigger={<button type="button" data-debug-id={`${p}-composer-more-btn`} aria-label="Composer options" className={`grid ${mobile ? 'h-11 w-11 rounded-full' : 'h-9 w-9 rounded-xl'} shrink-0 place-items-center text-muted hover:bg-neutral-soft`}><Icon name="more-horizontal" size={mobile ? 22 : 19} /></button>}>
    <Menu.Item data-debug-id={`${p}-mobile-model-btn`} onClick={() => { setMoreOpen(false); onSettings(); }}><ProviderIcon provider={provider} size={16} /><span className="min-w-0"><span className="block truncate">{model || 'Choose model/tier'}</span><span className="block text-xs text-muted">{provider || 'Provider'} · Agent settings</span></span></Menu.Item>
    {onPaneToggle ? <Menu.Item data-debug-id={`${p}-mobile-pane-btn`} onClick={() => { setMoreOpen(false); onPaneToggle(); }}><Icon name="terminal" size={16} /><span>{paneExpanded ? 'Hide terminal pane' : 'Show terminal pane'}</span></Menu.Item> : null}
    <Menu.Item data-debug-id={`${p}-mobile-upload-btn`} disabled={uploadDisabled} onClick={() => { setMoreOpen(false); onUpload(); }}><Icon name="plus" size={16} /><span>Upload attachment</span></Menu.Item>
  </Menu>;
  const send = !readOnly && !pendingActions ? <button type="submit" data-debug-id={`${p}-composer-send-btn`} disabled={sendDisabled} aria-label="Send message" className={`grid ${mobile ? 'h-11 w-11 rounded-full' : 'h-9 w-9 rounded-xl'} shrink-0 place-items-center bg-accent text-accent-fg disabled:opacity-40`}><Icon name="arrow-up" size={mobile ? 22 : 18} /></button> : null;
  if (inline) return <>{send}{more}</>;
  return <div data-debug-id={`${p}-composer-toolbar`} className="mt-2 flex min-w-0 items-center justify-between gap-2">
    {!mobile && !pendingActions && !readOnly ? <div className="flex shrink-0 items-center gap-1.5">
      <button type="button" data-debug-id={`${p}-attach-btn`} disabled={uploadDisabled} aria-label="Upload attachment" onClick={onUpload} className="grid h-9 w-9 place-items-center rounded-xl text-muted hover:bg-neutral-soft disabled:opacity-40"><Icon name="plus" size={19} /></button>
      {onPaneToggle ? <button type="button" data-debug-id={`${p}-request-pane-btn`} aria-label="Toggle terminal pane" aria-pressed={paneExpanded} onClick={onPaneToggle} className={`grid h-9 w-9 place-items-center rounded-xl ${paneExpanded ? 'bg-accent/20 text-accent' : 'text-muted hover:bg-neutral-soft'}`}><Icon name="terminal" size={18} /></button> : null}
      {extraActions}
    </div> : <span />}
    <div className="ml-auto flex min-w-0 items-center justify-end gap-2">
      {mobile ? more : <button type="button" data-debug-id={`${p}-runtime-menu-btn`} aria-haspopup="dialog" aria-label="Choose bridge, provider and model" onClick={onSettings} className="inline-flex h-9 min-w-0 max-w-[180px] items-center gap-1.5 rounded-xl border border-subtle bg-surface-raised px-2.5 text-sm text-primary hover:bg-neutral-soft"><ProviderIcon provider={provider} size={16} />{!compactModel ? <><span className="truncate font-semibold">{model || 'Choose model'}</span><Icon name="chevron-down" size={14} /></> : null}</button>}
      {pendingActions || send}
    </div>
  </div>;
}
