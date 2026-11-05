/**
 * SentenceToken — one switchable noun in the new-conversation headline.
 * ------------------------------------------------------------------
 * "Start a new [conversation] in [project] on [bridge]": each bracketed word is
 * a SentenceToken, a dotted-underlined `<button aria-haspopup="menu">` that opens
 * its menu right under it (spec §3.2, §3.3, motion §4 #1 #2 #3 #5 #6 #7 #17 #18).
 *
 * Built from `@ui`, not hand-rolled:
 *   - desktop: `Menu` with `variant="picker"`, a fixed `width`, a search `header`
 *     and `animated` enter/exit; rows are `Menu.RadioItem` (`menuitemradio` +
 *     `aria-checked`).
 *   - mobile (`useIsMobile()`, below 768px): `Drawer side="bottom" variant="sheet"`
 *     hosting the same `Menu.Panel` list, so keyboarding is identical.
 *
 * Callers pass `options` for a plain single-choice list (mode, project, bridge),
 * or `renderMenu` for a custom body (the provider + model split, the agent
 * list/edit views). Either way the token owns open state, focus and motion.
 *
 * `appearance="chip"` renders the same trigger + menu as a composer footer chip
 * (32px, bg-300 fill, border-strong hairline, a 14px chevron that is always
 * shown) for the provider + model and agent pickers (§3.3, §3.4). `side="top"`
 * opens the desktop menu above the trigger; `menuMode="dialog"` hosts ordinary
 * controls instead of menu items (the agent menu's edit view).
 *
 * Keyboard: Enter/Space open; ArrowUp/Down/Home/End move; Esc closes and returns
 * focus to the token; typing in the search field filters the options.
 *
 * Motion: background/underline/text colours transition at `fast` (#1); the
 * chevron grows 0 -> 18px and rotates 180deg when open (#2); the value replays
 * `tokSwap` only when `value` changes after mount (#3), never on unrelated
 * renders, and not at all under reduced motion.
 */
import React, { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { Drawer, Icon, Input, Menu, useIsMobile, type MenuMode } from '@ui';

export interface SentenceTokenOption<V extends string = string> {
  value: V;
  /** Row title. Also the token text when no `tokenLabel` is given. */
  label: string;
  /** What the token shows when this option is chosen (e.g. "without a project" for the "No project" row). */
  tokenLabel?: React.ReactNode;
  /** Secondary line under the title. */
  description?: React.ReactNode;
  /** Render `description` in mono (paths, IDs). */
  descriptionMono?: boolean;
  /** Leading glyph or icon well. */
  leading?: React.ReactNode;
  /** Trailing content (status pill). */
  trailing?: React.ReactNode;
  disabled?: boolean;
  /** Extra strings the search matches (path, id). */
  keywords?: string[];
  /** `data-debug-id` of the row. */
  debugId?: string;
}

export interface SentenceTokenSearch {
  /** Placeholder, which is also the field's accessible name unless `label` is set. */
  placeholder: string;
  label?: string;
  debugId: string;
  /** Shown when nothing matches, e.g. "No project matches that name." */
  emptyText: string;
}

export interface SentenceTokenMenuContext {
  close: () => void;
  /** Current search text (empty without `search`). */
  query: string;
  isMobile: boolean;
}

export interface SentenceTokenProps<V extends string = string> {
  /** The chosen value. A change replays the `tokSwap` animation. */
  value: V;
  /** Options for a plain single-choice menu. */
  options?: ReadonlyArray<SentenceTokenOption<V>>;
  /** Fired when an option row is picked. */
  onChange?: (value: V) => void;
  /** Token text. Defaults to the chosen option's `tokenLabel ?? label`. */
  children?: React.ReactNode;
  /** Content before the value inside the token (e.g. a status dot). */
  leading?: React.ReactNode;
  /** Accessible name of the menu and title of the mobile sheet, e.g. "Project". */
  label: string;
  /** `data-debug-id` of the token button; the menu gets `${debugId}-menu`. */
  debugId: string;
  /** Desktop menu width in px (spec: mode 300, project 380, bridge 360). */
  menuWidth?: number;
  /** Desktop menu alignment under the token. Default `start`. */
  align?: 'start' | 'end';
  /** Optional search field, focused on open, filtering `options`. */
  search?: SentenceTokenSearch;
  /** Rows above the options inside the menu (e.g. a `Menu.Label`). */
  menuHeader?: React.ReactNode;
  /** Rows after the options inside the menu (e.g. a separator and a "New project" row). */
  menuFooter?: React.ReactNode;
  /** Custom menu body instead of the `options` rows. */
  renderMenu?: (ctx: SentenceTokenMenuContext) => React.ReactNode;
  /** Controlled open state (omit for uncontrolled). */
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  disabled?: boolean;
  className?: string;
  /** `token` (default): the dotted headline noun. `chip`: a composer footer chip. */
  appearance?: 'token' | 'chip';
  /** Desktop menu side. Default `bottom`; `top` for triggers near the viewport bottom. */
  side?: 'bottom' | 'top';
  /** `dialog` when the menu body holds ordinary controls rather than menu items. Default `menu`. */
  menuMode?: MenuMode;
  /** Extra classes on the desktop popup / sheet panel (e.g. `p-0` for a split layout). */
  menuClassName?: string;
  /** Accessible name of the trigger when its visible text is not enough (chips). */
  triggerLabel?: string;
}

/** Case-insensitive match over the label, description text and keywords. */
export function filterSentenceTokenOptions<V extends string>(
  options: ReadonlyArray<SentenceTokenOption<V>>,
  query: string,
): Array<SentenceTokenOption<V>> {
  const q = query.trim().toLowerCase();
  if (!q) return [...options];
  return options.filter((option) => {
    const haystack = [option.label, typeof option.description === 'string' ? option.description : '', ...(option.keywords ?? [])];
    return haystack.some((text) => text.toLowerCase().includes(q));
  });
}

/** True when the user asked for reduced motion; animation classes are then left off entirely. */
export function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined' && !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
}

const cx = (...parts: Array<string | false | null | undefined>) => parts.filter(Boolean).join(' ');

export function SentenceToken<V extends string = string>({
  value,
  options,
  onChange,
  children,
  leading,
  label,
  debugId,
  menuWidth,
  align = 'start',
  search,
  menuHeader,
  menuFooter,
  renderMenu,
  open: openProp,
  onOpenChange,
  disabled = false,
  className,
  appearance = 'token',
  side = 'bottom',
  menuMode = 'menu',
  menuClassName,
  triggerLabel,
}: SentenceTokenProps<V>) {
  const chip = appearance === 'chip';
  const isMobile = useIsMobile();
  const isControlled = openProp !== undefined;
  const [openState, setOpenState] = useState(false);
  const open = isControlled ? !!openProp : openState;
  const [query, setQuery] = useState('');
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const searchId = useId();

  const setOpen = useCallback(
    (next: boolean) => {
      if (!isControlled) setOpenState(next);
      onOpenChange?.(next);
    },
    [isControlled, onOpenChange],
  );

  // Each open starts with an empty search.
  useEffect(() => {
    if (open) setQuery('');
  }, [open]);

  const close = useCallback(
    (restoreFocus = true) => {
      setOpen(false);
      if (restoreFocus) triggerRef.current?.focus();
    },
    [setOpen],
  );

  // tokSwap (#3): count real value changes after mount (React's "adjust state
  // while rendering" pattern) and key the value span on the count, so the
  // keyframe replays once per change, never on unrelated renders, and also when
  // a pick returns to the mount value.
  const [swap, setSwap] = useState({ value, count: 0 });
  if (swap.value !== value) setSwap({ value, count: swap.count + 1 });
  const animateSwap = swap.count > 0 && !prefersReducedMotion();

  const selected = options?.find((option) => option.value === value);
  const display = children ?? selected?.tokenLabel ?? selected?.label ?? value;

  const visibleOptions = useMemo(
    () => (options ? filterSentenceTokenOptions(options, search ? query : '') : []),
    [options, query, search],
  );

  const variant = isMobile ? 'sheet' : 'picker';

  const searchField = search ? (
    <div className="px-1 pb-1.5 pt-1">
      <label htmlFor={searchId} className="sr-only">
        {search.label ?? search.placeholder}
      </label>
      <Input
        id={searchId}
        type="search"
        width="full"
        value={query}
        onChange={setQuery}
        placeholder={search.placeholder}
        leading={<Icon name="search" />}
        autoComplete="off"
        data-debug-id={search.debugId}
      />
    </div>
  ) : null;

  const body = renderMenu ? (
    renderMenu({ close: () => close(true), query, isMobile })
  ) : (
    <>
      {menuHeader}
      {visibleOptions.map((option) => (
        <Menu.RadioItem
          key={option.value}
          checked={option.value === value}
          disabled={option.disabled}
          leading={option.leading}
          trailing={option.trailing}
          description={
            option.description === undefined ? undefined : option.descriptionMono ? (
              <span className="font-mono text-label font-normal">{option.description}</span>
            ) : (
              option.description
            )
          }
          data-debug-id={option.debugId}
          onClick={() => {
            if (option.value !== value) onChange?.(option.value);
          }}
        >
          {option.label}
        </Menu.RadioItem>
      ))}
      {search && visibleOptions.length === 0 ? (
        <p role="presentation" className="px-2.5 py-2 text-body-sm text-muted">
          {search.emptyText}
        </p>
      ) : null}
      {menuFooter}
    </>
  );

  const token = (
    <button
      ref={triggerRef}
      type="button"
      aria-haspopup={menuMode === 'dialog' ? 'dialog' : 'menu'}
      aria-expanded={open}
      aria-label={triggerLabel}
      disabled={disabled}
      data-debug-id={debugId}
      data-state={open ? 'open' : 'closed'}
      onClick={isMobile ? () => setOpen(!open) : undefined}
      className={chip ? cx(
        // Composer chip (DESIGN.md control height 32; 40px on mobile). It shrinks and
        // truncates its value so the composer toolbar stays on one row.
        'inline-flex min-w-0 max-w-full shrink items-center gap-1.5 rounded-[var(--radius-md)] border border-strong bg-neutral-soft px-2.5 text-body-sm font-medium text-primary',
        'transition-colors duration-fast ease-standard motion-reduce:transition-none hover:bg-strong',
        open && 'bg-strong',
        'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus',
        'disabled:cursor-not-allowed disabled:opacity-[.45]',
        isMobile ? 'h-10 max-w-[9rem]' : 'h-8',
        className,
      ) : cx(
        // Rest (§3.2): inherits the headline type; radius 10px and padding 0 8px 2px are the spec's exact values.
        'group/tok -mx-0.5 inline-flex items-center gap-1.5 rounded-[10px] bg-transparent px-2 pb-0.5 text-primary',
        'underline decoration-faint decoration-dotted decoration-2 underline-offset-8',
        // #1: colours only, fast/standard.
        'transition-[background-color,text-decoration-color,color] duration-fast ease-standard motion-reduce:transition-none',
        'hover:bg-neutral-soft hover:decoration-accent',
        open && 'bg-neutral-soft text-accent decoration-accent',
        // Focus: the standard 2px accent ring, 2px offset.
        'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus',
        'disabled:cursor-not-allowed disabled:opacity-[.45]',
        // 44px tap target on mobile; the -my-1 keeps it from stretching the 36px headline
        // lines. The max width is the slot plus the -mx-0.5 overhang, so a value only
        // truncates when it really is wider than the line.
        isMobile && 'min-h-11 -my-1 max-w-[calc(100%+4px)]',
        className,
      )}
    >
      {leading}
      <span
        key={`v:${swap.count}`}
        data-token-value=""
        className={cx(
          chip ? 'inline-flex min-w-0 items-center gap-1.5 truncate' : 'inline-block max-md:min-w-0 max-md:truncate',
          animateSwap && 'animate-tok-swap',
        )}
      >
        {display}
      </span>
      {chip ? (
        <span
          aria-hidden="true"
          data-token-chevron=""
          className={cx('inline-flex flex-none text-muted transition-transform duration-base ease-standard motion-reduce:transition-none', open && 'rotate-180')}
        >
          <Icon name="chevron-down" size={14} />
        </span>
      ) : <span
        aria-hidden="true"
        data-token-chevron=""
        className={cx(
          'inline-flex flex-none overflow-hidden text-muted',
          // #2: width/opacity at fast, rotation at base.
          'transition-[width,opacity,transform] duration-fast ease-standard [transition-duration:var(--duration-fast),var(--duration-fast),var(--duration-base)] motion-reduce:transition-none',
          isMobile ? 'w-4 opacity-100' : open ? 'w-[18px] opacity-100' : 'w-0 opacity-0 group-hover/tok:w-[18px] group-hover/tok:opacity-100',
          open && 'rotate-180',
        )}
      >
        <Icon name="chevron-down" size={isMobile ? 16 : 18} />
      </span>}
    </button>
  );

  if (isMobile) {
    return (
      <>
        {token}
        <Drawer
          open={open}
          onOpenChange={(next) => {
            if (!next) close(true);
          }}
          side="bottom"
          variant="sheet"
          title={label}
          hideHeader
          aria-label={label}
          autoFocus={false}
          returnFocusRef={triggerRef}
        >
          <Menu.Panel
            label={label}
            onClose={close}
            header={searchField}
            variant="sheet"
            mode={menuMode}
            autoFocus={open}
            data-debug-id={`${debugId}-menu`}
            className={cx('px-2 pb-4 pt-1 text-left font-sans text-body font-normal normal-case tracking-normal', menuClassName)}
          >
            {body}
          </Menu.Panel>
        </Drawer>
      </>
    );
  }

  return (
    <Menu
      trigger={token}
      open={open}
      onOpenChange={(next) => {
        if (next) setOpen(true);
        else setOpen(false);
      }}
      label={label}
      align={align}
      side={side}
      variant="picker"
      mode={menuMode}
      width={menuWidth}
      header={searchField}
      animated
      popupDebugId={`${debugId}-menu`}
      className={menuClassName}
    >
      {body}
    </Menu>
  );
}

export default SentenceToken;
