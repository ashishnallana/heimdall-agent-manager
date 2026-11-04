import { Children, Fragment, forwardRef, isValidElement, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef, useState, type FocusEvent as ReactFocusEvent, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent as ReactMouseEvent, type CSSProperties, type HTMLAttributes, type RefObject, type TextareaHTMLAttributes, type ReactNode } from 'react';
import { flushSync } from 'react-dom';
import { Icon, StatusDot, type StatusDotProps } from '@ui';
import ProviderIcon from '../providers/ProviderIcon';
import { useSelector } from 'react-redux';
import { selectUseExternalKeyboard } from '../../store/inputPreferencesSlice';

/**
 * `appearance`: `pane` (default) is the conversation pane's compact field. `launch`
 * is the new-conversation composer's field: flush (no padding), 72px tall on
 * desktop, body 14/20; `mono` sets it in the code face (the shell command field).
 */
export type MessageComposerInputProps = TextareaHTMLAttributes<HTMLTextAreaElement> & {
  mobile: boolean; debugId: string; appearance?: 'pane' | 'launch'; mono?: boolean;
  /** Opt in to the morphing composer field (inside `MessageComposerMorphShell`): one line
   *  while collapsed, two lines (auto-growing, then scrolling) while expanded. Height is CSS
   *  owned so it can transition; JS only reports the content height on edits/resizes.
   *  Overrides `appearance`/`mono` sizing. */
  morph?: boolean;
};
const COMPOSER_INPUT_BASE = 'w-full resize-none bg-transparent text-primary outline-none placeholder:text-muted';
function composerInputClassName(mobile: boolean, appearance: 'pane' | 'launch', mono: boolean): string {
  const face = mono ? 'font-mono text-code leading-5' : '';
  if (mobile) return `block min-h-6 max-h-[72px] ${COMPOSER_INPUT_BASE} p-0 ${mono ? face : 'text-base leading-6'}`;
  if (appearance === 'launch') return `block min-h-[72px] ${COMPOSER_INPUT_BASE} p-0 ${mono ? face : 'text-sm leading-5'}`;
  return `min-h-[44px] ${COMPOSER_INPUT_BASE} px-1 py-1 ${mono ? face : 'text-sm'}`;
}

export const MessageComposerInput = forwardRef<HTMLTextAreaElement, MessageComposerInputProps>(function MessageComposerInput({ mobile, debugId, appearance = 'pane', mono = false, morph = false, ...props }, forwardedRef) {
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
    const resize = morph ? () => {
      // Measure the content at the field's one-line intrinsic size, then hand the number to
      // CSS (which clamps it between the expanded minimum and the scroll cap) so the open and
      // close height transitions stay pure CSS. Runs on edits and width changes only.
      const transition = input.style.transition;
      input.style.transition = 'none';
      input.style.height = 'auto';
      input.style.setProperty(MORPH_FIELD_CONTENT_VAR, `${input.scrollHeight}px`);
      input.style.height = '';
      input.style.transition = transition;
    } : () => { input.style.height = mobile ? 'auto' : ''; if (mobile) input.style.height = `${Math.min(72, Math.max(24, input.scrollHeight))}px`; input.style.overflowY = mobile && input.scrollHeight > 72 ? 'auto' : ''; };
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
  }, [mobile, morph, props.value, inputMode]);
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
    data-debug-id={debugId} {...(morph ? { 'data-composer-morph-field': '' } : null)} rows={mobile || morph ? 1 : 2} className={morph ? (mobile ? MORPH_FIELD_CLASS_MOBILE : MORPH_FIELD_CLASS_DESKTOP) : composerInputClassName(mobile, appearance, mono)} />;
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
  /** Opt in to the morphing layout (inside `MessageComposerMorphShell`, pass the hook's
   *  state): leading tools fade in at the lower left only while expanded and leave the tab
   *  order and accessibility tree while collapsed; the model chip and send button stay
   *  anchored at the lower right and grow. Omit for the classic toolbar row. */
  morph?: { expanded: boolean };
};
/** Bottom row of the composer card: upload, terminal, tasks | model pill, send. Same
 *  controls on every form factor; mobile only gets larger tap targets. */
export function MessageComposerActions(props: ComposerActionsProps) {
  return props.morph ? <MorphComposerActions {...props} morph={props.morph} /> : <ClassicComposerActions {...props} />;
}

function ClassicComposerActions({ debugPrefix: p, mobile, compactModel, provider, model, onSettings, onUpload, uploadDisabled, onPaneToggle, paneExpanded, sendDisabled, onOpenTasks, pendingActions, readOnly, extraActions }: ComposerActionsProps) {
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

/** Morph layout: same controls, debug IDs and labels as the classic toolbar. The toolbar
 *  wrapper is `display: contents` so both groups position against the shell. */
function MorphComposerActions({ debugPrefix: p, compactModel, provider, model, onSettings, onUpload, uploadDisabled, onPaneToggle, paneExpanded, sendDisabled, onOpenTasks, pendingActions, readOnly, extraActions, morph }: ComposerActionsProps & { morph: { expanded: boolean } }) {
  const tool = 'grid h-11 w-11 shrink-0 place-items-center rounded-[var(--radius-md)]';
  const hidden = !morph.expanded;
  const showTools = !pendingActions && !readOnly;
  // Width of the open tool row (44px buttons, 4px gaps), so the open trailing group can stop
  // short of it: on a phone-width card a long model name would otherwise cover the tools.
  const toolCount = showTools ? 1 + (onPaneToggle ? 1 : 0) + (onOpenTasks ? 1 : 0) + countControls(extraActions) : 0;
  const toolsWidth = toolCount > 0 ? toolCount * 44 + (toolCount - 1) * 4 : 0;
  return <div data-debug-id={`${p}-composer-toolbar`} data-composer-morph-toolbar="" className="contents"
    style={{ [MORPH_TOOLS_WIDTH_VAR]: `${toolsWidth}px` } as CSSProperties}>
    {showTools ? <div data-debug-id={`${p}-composer-morph-tools`} data-composer-morph-tools="" {...inertWhen(hidden)} className="flex items-center gap-1">
      <button type="button" data-debug-id={`${p}-attach-btn`} disabled={uploadDisabled} aria-label="Upload attachment" onClick={onUpload} className={`${tool} text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40`}><Icon name="plus" size={20} /></button>
      {onPaneToggle ? <button type="button" data-debug-id={`${p}-request-pane-btn`} aria-label="Open terminal" aria-pressed={paneExpanded} onClick={onPaneToggle} className={`${tool} ${paneExpanded ? 'bg-accent/20 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}><Icon name="terminal" size={20} /></button> : null}
      {onOpenTasks ? <button type="button" data-debug-id={`${p}-tasks-btn`} aria-label="Open tickets" onClick={onOpenTasks} className={`${tool} text-muted hover:bg-neutral-soft hover:text-primary`}><Icon name="tasks" size={20} /></button> : null}
      {extraActions}
    </div> : null}
    <div data-debug-id={`${p}-composer-morph-trailing`} data-composer-morph-trailing="" className="flex min-w-0 items-center justify-end gap-2">
      <button type="button" data-debug-id={`${p}-runtime-menu-btn`} data-composer-morph-chip="" aria-haspopup="dialog" aria-label="Choose bridge, provider and model" title={model || undefined} onClick={onSettings} className="inline-flex min-w-0 items-center gap-1.5 border border-strong bg-neutral-soft text-primary hover:bg-surface-raised">
        <ProviderIcon provider={provider} size={16} />
        {!compactModel ? <span className="min-w-0 truncate">{model || 'Choose model'}</span> : null}
        <span data-composer-morph-chevron="" aria-hidden="true"><Icon name="chevron-down" size={16} className="shrink-0" /></span>
      </button>
      {pendingActions || (!readOnly ? <button type="submit" data-debug-id={`${p}-composer-send-btn`} data-composer-morph-send="" disabled={sendDisabled} aria-label="Send message" className="grid shrink-0 place-items-center bg-accent text-accent-fg disabled:opacity-40"><Icon name="arrow-up" size={20} /></button> : null)}
    </div>
  </div>;
}

/** Rendered controls in a node, looking through fragments (`<>…</>` of extra buttons). */
function countControls(node: ReactNode): number {
  return Children.toArray(node).reduce<number>((total, child) =>
    total + (isValidElement<{ children?: ReactNode }>(child) && child.type === Fragment ? countControls(child.props.children) : 1), 0);
}

/** React 18 has no boolean `inert` prop; the attribute alone removes the subtree from the
 *  tab order and the accessibility tree. `aria-hidden` covers engines without `inert`, and
 *  the morph CSS also sets `visibility: hidden` once the fade-out ends. */
function inertWhen(hidden: boolean): HTMLAttributes<HTMLElement> {
  // The installed types declare `inert` as boolean (React 19); React 18 only writes it as a string.
  return hidden ? { inert: '', 'aria-hidden': true } as unknown as HTMLAttributes<HTMLElement> : {};
}

/** What keeps a morphing composer open besides focus. Every flag is explicit so state the
 *  DOM cannot see (portal menus, uploads, borrowed tray modes) still holds it open. */
export type ComposerExpansionInputs = {
  /** The current draft; any character (whitespace, a restored draft) holds it open. */
  draft: string;
  hasAttachments?: boolean;
  hasQuotes?: boolean;
  /** Another surface borrowed the composer (Answer / Request changes tray mode). */
  borrowed?: boolean;
  /** A popup the composer owns is open, including portaled menus, sheets and mentions. */
  menuOpen?: boolean;
  /** The file picker or an upload is in flight. */
  uploadActive?: boolean;
  /** Pending action buttons replace send; keep them visible at full size. */
  pendingActions?: boolean;
  /** Read-only composers keep their current, always-visible UI. */
  readOnly?: boolean;
};

export type ComposerExpansionReason = 'focus' | 'draft' | 'attachments' | 'quotes' | 'borrowed' | 'menu' | 'upload' | 'pending-actions' | 'read-only';

export type ComposerExpansion = {
  expanded: boolean;
  focusWithin: boolean;
  /** Why it is open, in a stable order; empty when collapsed. */
  reasons: ComposerExpansionReason[];
  /** Spread onto the shell root (`MessageComposerMorphShell` does this). */
  shellProps: {
    ref: (node: HTMLDivElement | null) => void;
    onFocus: (event: ReactFocusEvent<HTMLDivElement>) => void;
    onBlur: (event: ReactFocusEvent<HTMLDivElement>) => void;
    onKeyDown: (event: ReactKeyboardEvent<HTMLDivElement>) => void;
    onMouseDown: (event: ReactMouseEvent<HTMLDivElement>) => void;
  };
};

const INTERACTIVE_SELECTOR = 'button, a[href], input, textarea, select, label, summary, [role="button"], [role="menuitem"], [role="option"], [contenteditable="true"], [tabindex]:not([tabindex="-1"]), [data-composer-morph-ignore]';

/** Pure: which conditions currently hold a morphing composer open. */
export function composerExpansionReasons(inputs: ComposerExpansionInputs, focusWithin: boolean): ComposerExpansionReason[] {
  const reasons: ComposerExpansionReason[] = [];
  if (focusWithin) reasons.push('focus');
  if (inputs.draft.length > 0) reasons.push('draft');
  if (inputs.hasAttachments) reasons.push('attachments');
  if (inputs.hasQuotes) reasons.push('quotes');
  if (inputs.borrowed) reasons.push('borrowed');
  if (inputs.menuOpen) reasons.push('menu');
  if (inputs.uploadActive) reasons.push('upload');
  if (inputs.pendingActions) reasons.push('pending-actions');
  if (inputs.readOnly) reasons.push('read-only');
  return reasons;
}

/** Opt-in expansion state for `MessageComposerMorphShell`. Focus is tracked with
 *  `relatedTarget` containment (moving between the field and the composer's own controls
 *  never collapses it, nor does switching windows); the other open conditions are passed in. */
export function useComposerExpanded(inputs: ComposerExpansionInputs): ComposerExpansion {
  const root = useRef<HTMLDivElement | null>(null);
  const [focusWithin, setFocusWithin] = useState(false);
  const latest = useRef(inputs);
  latest.current = inputs;
  // WebKit (Safari, iOS) does not focus a pressed <button>: pressing + or the terminal
  // button blurs the field with `relatedTarget` null, and collapsing then makes the tools
  // inert before the click lands. `pressInside` is true from a primary press on an enabled
  // part of the composer until that press ends; `held` means the composer stays
  // engaged although focus went nowhere. A press or focus outside the composer ends it.
  const pressInside = useRef(false);
  const held = useRef(false);
  const ref = useCallback((node: HTMLDivElement | null) => { root.current = node; }, []);
  useEffect(() => {
    const doc = root.current?.ownerDocument ?? (typeof document === 'undefined' ? null : document);
    if (!doc) return;
    const inside = (target: EventTarget | null) => Boolean(root.current && target && root.current.contains(target as Node));
    const release = () => {
      if (!held.current) return;
      held.current = false;
      setFocusWithin(false);
    };
    const onPointerDown = (event: Event) => {
      const press = event as PointerEvent;
      const target = event.target as Element | null;
      // Only a primary press on an enabled control can end in a click; anything else
      // (right-click, a disabled send button) must not leave a hold armed.
      pressInside.current = inside(target) && (press.isPrimary ?? true) && (press.button ?? 0) === 0
        // An aria-disabled control that still handles clicks must not rely on this hold.
        && !target?.closest?.(':disabled, [aria-disabled="true"]');
      if (!inside(target)) release();
    };
    const onPressEnd = () => { pressInside.current = false; };
    // Mouse: WebKit blurs at mousedown, before pointerup, so the press ends there (a
    // drag-off release may never click). Touch and pen (iPadOS Pencil): the compatibility
    // mousedown and blur come after pointerup, just before click, so they end at click or cancel.
    const onPointerUp = (event: Event) => { if ((event as PointerEvent).pointerType === 'mouse') onPressEnd(); };
    const onFocusIn = (event: Event) => {
      if (inside(event.target)) held.current = false;
      else release();
    };
    // Capture phase throughout, so a handler's stopPropagation() cannot leave a hold armed;
    // the blur that sets the hold always comes before the press's pointerup/click.
    doc.addEventListener('pointerdown', onPointerDown, true);
    doc.addEventListener('pointerup', onPointerUp, true);
    doc.addEventListener('focusin', onFocusIn, true);
    doc.addEventListener('click', onPressEnd, true);
    doc.addEventListener('pointercancel', onPressEnd, true);
    return () => {
      doc.removeEventListener('pointerdown', onPointerDown, true);
      doc.removeEventListener('pointerup', onPointerUp, true);
      doc.removeEventListener('focusin', onFocusIn, true);
      doc.removeEventListener('click', onPressEnd, true);
      doc.removeEventListener('pointercancel', onPressEnd, true);
    };
  }, []);
  const onFocus = useCallback(() => { held.current = false; setFocusWithin(true); }, []);
  const onBlur = useCallback((event: ReactFocusEvent<HTMLDivElement>) => {
    const node = root.current;
    const next = event.relatedTarget as Node | null;
    if (node && next && node.contains(next)) return;
    // Focus went nowhere because the user pressed one of the composer's own controls.
    if (!next && pressInside.current) { held.current = true; return; }
    // The window lost focus but the field keeps it (app switch, devtools): stay open, as
    // `:focus-within` would. Focus returning fires onFocus again.
    if (!next && node && !node.ownerDocument.hasFocus() && node.contains(node.ownerDocument.activeElement)) return;
    setFocusWithin(false);
  }, []);
  const onKeyDown = useCallback((event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'Escape' || event.defaultPrevented) return;
    // IME: Escape cancels the composition, not the composer.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    if (latest.current.menuOpen) return;
    const target = event.target as HTMLTextAreaElement;
    if (target.tagName !== 'TEXTAREA' || !target.hasAttribute('data-composer-morph-field')) return;
    if (target.value.length > 0) return;
    event.preventDefault();
    pressInside.current = false;
    target.blur();
  }, []);
  const onMouseDown = useCallback((event: ReactMouseEvent<HTMLDivElement>) => {
    const node = root.current;
    if (!node || event.button !== 0 || event.defaultPrevented) return;
    const target = event.target as Element;
    const interactive = target.closest(INTERACTIVE_SELECTOR);
    if (interactive && node.contains(interactive)) return;
    const field = node.querySelector<HTMLTextAreaElement>('textarea[data-composer-morph-field]');
    if (!field || field.disabled) return;
    // Background press: keep (or move) focus in the field instead of dropping it to <body>.
    event.preventDefault();
    if (node.ownerDocument.activeElement !== field) field.focus();
  }, []);
  const reasons = composerExpansionReasons(inputs, focusWithin);
  return {
    expanded: reasons.length > 0,
    focusWithin,
    reasons,
    shellProps: { ref, onFocus, onBlur, onKeyDown, onMouseDown },
  };
}

export type MessageComposerMorphShellProps = {
  expansion: ComposerExpansion;
  debugPrefix: string;
  /** Debug ID for the shell root; defaults to `${debugPrefix}-composer-morph`. */
  debugId?: string;
  /** Always visible, above the context row: attachment/quote trays, borrowed-mode banners. */
  leading?: ReactNode;
  /** Collapsible context row (bridge, project, runtime status). */
  context?: ReactNode;
  /** The `MessageComposerInput morph` field and anything that sits directly below it. */
  children: ReactNode;
  /** `MessageComposerActions morph={...}`. */
  actions?: ReactNode;
  /** Surface classes; the shell owns geometry and motion. */
  className?: string;
};

/** Opt-in morphing composer card: a 56px pill (one-line field, model chip and send) that
 *  grows upward into the full card (context row, two-line field, tools) while it is open.
 *  All motion is CSS: grid rows for the context height, height/margin/padding transitions
 *  for the field and spacer, staggered fades, and near-instant changes under reduced motion. */
export function MessageComposerMorphShell({ expansion, debugPrefix: p, debugId, leading, context, children, actions, className }: MessageComposerMorphShellProps) {
  const { expanded, shellProps } = expansion;
  return <div {...shellProps} data-debug-id={debugId ?? `${p}-composer-morph`} data-composer-morph="" data-expanded={expanded ? 'true' : 'false'}
    className={className ?? 'rounded-[28px] border border-subtle bg-surface-raised px-5'}>
    <style>{MORPH_CSS}</style>
    {leading}
    {context ? <div data-composer-morph-head=""><div data-composer-morph-head-inner="">
      <div data-debug-id={`${p}-composer-morph-context`} data-composer-morph-context="" {...inertWhen(!expanded)}>{context}</div>
    </div></div> : null}
    {children}
    <div data-debug-id={`${p}-composer-morph-spacer`} data-composer-morph-spacer="" aria-hidden="true" />
    {actions}
  </div>;
}

/** How long the dock height must hold still before the settled value is committed to React. */
const DOCK_INSET_SETTLE_MS = 120;

export type ComposerDockInsetOptions = {
  /** Debug ID of the transcript's bottom spacer (`${debugPrefix}-bottom-inset` in `ChatMessageList`). */
  insetDebugId: string;
  /** Debug ID of the list's jump-to-latest button, which sits `inset + 12px` above the bottom. */
  jumpDebugId?: string;
  /** Re-subscribes when this changes (conversation, form factor). */
  resetKey?: string;
};

/** Height of a floating composer dock, for `ChatMessageList`'s `bottomInset`, kept in step
 *  with the dock while a morphing composer animates.
 *
 *  `ResizeObserver` callbacks run after layout and before paint, so the observer writes the
 *  new height straight onto the list's spacer (and jump button) in the same frame the dock
 *  changed, and keeps a reader who was at the bottom pinned there. Committing every frame to
 *  React state would re-render the whole transcript per animation frame and lands a frame
 *  late; instead the settled height is committed once the dock holds still. No animation
 *  loop: the observer only fires when the dock's size actually changes, and it never resizes
 *  the dock, so there is no feedback loop. Both elements must share the dock's parent. */
export function useComposerDockInset(dockRef: RefObject<HTMLElement | null>, { insetDebugId, jumpDebugId, resetKey }: ComposerDockInsetOptions): number {
  const [inset, setInset] = useState(0);
  useLayoutEffect(() => {
    const dock = dockRef.current;
    if (!dock || typeof ResizeObserver === 'undefined') { setInset(0); return; }
    let applied = Math.ceil(dock.getBoundingClientRect().height);
    setInset(applied);
    let settle: ReturnType<typeof setTimeout> | undefined;
    const observer = new ResizeObserver(entries => {
      const box = entries[entries.length - 1]?.borderBoxSize?.[0];
      const height = Math.ceil(box ? box.blockSize : dock.getBoundingClientRect().height);
      if (height === applied) return;
      applied = height;
      clearTimeout(settle);
      const scope = dock.parentElement;
      const spacer = scope?.querySelector<HTMLElement>(`[data-debug-id="${insetDebugId}"]`);
      const scroller = spacer?.parentElement;
      if (!scope || !spacer || !scroller) {
        // No spacer yet (first non-zero height): render it synchronously, before paint.
        flushSync(() => setInset(height));
        return;
      }
      // Read before writing: layout is clean when observers are delivered.
      // REQ-PIN-4: a send-pinned list (ChatMessageList pinOnSend) is never pulled down.
      const pinned = scroller.dataset.chatPinned !== 'true' && scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= 2;
      spacer.style.height = `${height}px`;
      const jump = jumpDebugId ? scope.querySelector<HTMLElement>(`[data-debug-id="${jumpDebugId}"]`) : null;
      if (jump) jump.style.bottom = `${height + 12}px`;
      if (pinned) scroller.scrollTop = scroller.scrollHeight;
      settle = setTimeout(() => setInset(height), DOCK_INSET_SETTLE_MS);
    });
    observer.observe(dock);
    return () => { observer.disconnect(); clearTimeout(settle); };
  }, [dockRef, insetDebugId, jumpDebugId, resetKey]);
  return inset;
}

const MORPH_FIELD_CONTENT_VAR = '--composer-morph-field-content';
const MORPH_TOOLS_WIDTH_VAR = '--composer-morph-tools-width';
const MORPH_FIELD_CLASS_BASE = 'block w-full resize-none bg-transparent text-primary outline-none placeholder:text-muted';
// 16px on phones keeps iOS from zooming into the field on focus.
const MORPH_FIELD_CLASS_MOBILE = `${MORPH_FIELD_CLASS_BASE} text-base leading-6`;
const MORPH_FIELD_CLASS_DESKTOP = `${MORPH_FIELD_CLASS_BASE} text-[15px] leading-6`;

/** Scoped to the morph data attributes; nothing global. Motion uses the tokens.css duration
 *  and easing tokens (incl. `--ease-emphasized`), with their values as fallbacks. */
export const MORPH_CSS = `
[data-composer-morph] { --cm-d: var(--duration-base, 200ms); --cm-e: var(--ease-standard, cubic-bezier(0.2, 0.8, 0.2, 1)); position: relative; cursor: text; transition: border-color var(--cm-d) var(--cm-e), box-shadow var(--cm-d) var(--cm-e) }
[data-composer-morph][data-expanded='true'] { --cm-d: var(--duration-slow, 300ms); --cm-e: var(--ease-emphasized, cubic-bezier(0.22, 1, 0.36, 1)); cursor: auto; border-color: var(--color-border-strong); box-shadow: var(--shadow-panel) }
[data-composer-morph-head] { display: grid; grid-template-rows: 0fr; transition: grid-template-rows var(--cm-d) var(--cm-e) }
[data-composer-morph-head-inner] { min-height: 0; overflow: hidden }
[data-composer-morph-context] { padding-top: 16px; opacity: 0; transform: translateY(-4px); transition: opacity var(--cm-d) var(--cm-e), transform var(--cm-d) var(--cm-e) }
[data-composer-morph-field] { height: 24px; margin: 16px 0 0; padding: 0 164px 0 0; overflow: hidden; transition: height var(--cm-d) var(--cm-e), margin var(--cm-d) var(--cm-e), padding var(--cm-d) var(--cm-e) }
[data-composer-morph-spacer] { height: 16px; transition: height var(--cm-d) var(--cm-e) }
[data-composer-morph-tools] { position: absolute; left: 10px; bottom: 16px; opacity: 0; transform: translateY(6px); visibility: hidden; transition: opacity var(--cm-d) var(--cm-e), transform var(--cm-d) var(--cm-e), visibility 0s var(--cm-d) }
[data-composer-morph-trailing] { position: absolute; right: 8px; bottom: 8px; max-width: calc(100% - 16px); transition: right var(--cm-d) var(--cm-e), bottom var(--cm-d) var(--cm-e) }
[data-composer-morph-chip] { height: 32px; max-width: 108px; padding: 0 10px; border-radius: 10px; font-size: 13px; line-height: 18px; font-weight: 500; transition: height var(--cm-d) var(--cm-e), max-width var(--cm-d) var(--cm-e), padding var(--cm-d) var(--cm-e), font-size var(--cm-d) var(--cm-e), background-color var(--duration-fast, 120ms) }
[data-composer-morph-chevron] { display: inline-flex; flex-shrink: 0; width: 0; opacity: 0; overflow: hidden; transition: width var(--cm-d) var(--cm-e), opacity var(--cm-d) var(--cm-e) }
[data-composer-morph-send] { width: 40px; height: 40px; border-radius: 12px; transition: width var(--cm-d) var(--cm-e), height var(--cm-d) var(--cm-e), opacity var(--duration-fast, 120ms) }
[data-composer-morph][data-expanded='true'] [data-composer-morph-head] { grid-template-rows: 1fr }
[data-composer-morph][data-expanded='true'] [data-composer-morph-context] { opacity: 1; transform: none; transition-delay: 60ms }
[data-composer-morph][data-expanded='true'] [data-composer-morph-field] { height: clamp(48px, var(${MORPH_FIELD_CONTENT_VAR}, 48px), 144px); margin-top: 12px; padding-right: 0; overflow-y: auto }
[data-composer-morph][data-expanded='true'] [data-composer-morph-spacer] { height: 76px }
[data-composer-morph][data-expanded='true'] [data-composer-morph-tools] { opacity: 1; transform: none; visibility: visible; transition: opacity var(--cm-d) var(--cm-e) 80ms, transform var(--cm-d) var(--cm-e) 80ms, visibility 0s }
[data-composer-morph][data-expanded='true'] [data-composer-morph-trailing] { right: 16px; bottom: 16px; max-width: calc(100% - 34px - var(${MORPH_TOOLS_WIDTH_VAR}, 0px)) }
[data-composer-morph][data-expanded='true'] [data-composer-morph-chip] { height: 40px; max-width: 220px; padding: 0 12px; font-size: 15px; font-weight: 600 }
[data-composer-morph][data-expanded='true'] [data-composer-morph-chevron] { width: 16px; opacity: 1 }
[data-composer-morph][data-expanded='true'] [data-composer-morph-send] { width: 44px; height: 44px }
@media (prefers-reduced-motion: reduce) {
  [data-composer-morph], [data-composer-morph] * { transition-duration: 1ms !important; transition-delay: 0ms !important }
}
`;

/** Runtime indicator for the composer card's top-right corner: the real StatusDot only.
 *  Rendered inside a button by the caller (which owns the start/stop menu). */
export function MessageComposerStatus({ debugPrefix: p, tone, label }: { debugPrefix: string; tone: StatusDotProps['tone']; label: string }) {
  return <span data-debug-id={`${p}-composer-status`} className="inline-flex items-center">
    <StatusDot size="sm" tone={tone} label={label} />
  </span>;
}
