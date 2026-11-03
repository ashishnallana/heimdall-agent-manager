/**
 * Menu — a popover list of actions (or a single choice) from a trigger.
 * ------------------------------------------------------------------
 * Purpose: the one dropdown menu of actions (EL-057), fixing the "menu without
 * menu keyboarding" defect — it implements the ARIA menu-button pattern (roving
 * focus, arrow keys, Home/End, Esc, focus restore) once, for every kebab/overflow
 * dropdown.
 *
 * NOT for: choosing a form value (use `Select`/`Combobox`), or a dialog
 * (`Modal`). Menu items DO things. `Menu.RadioItem` is for a menu that switches
 * a live setting at once (the conversation launcher's sentence tokens), not for
 * a form field that is submitted later.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Menu.
 *
 * API: pass the `trigger` element (it is cloned to get `aria-haspopup="menu"` +
 * `aria-expanded` + the toggle handler) and `Menu.Item` / `Menu.RadioItem`
 * children. Uncontrolled by default; pass `open`/`onOpenChange` to control it.
 * Give the menu an accessible name via `label` (or the trigger's own text).
 *
 * Opt-in extensions (all default off, so existing menus render unchanged):
 *   - `variant="picker"`: the DESIGN.md `menu` surface (bg-200, radius-lg, 4px
 *     padding, 10px gap, roomy 40px rows, selected row fill) for value menus.
 *   - `width`: a fixed popup width in px (the launcher menus are 300–560px).
 *   - `header`: content above the item list, e.g. a search field. It sits
 *     outside `role="menu"`; ArrowDown/ArrowUp from it move into the list.
 *   - `animated`: `menuIn` on open from the anchor corner, the reverse at the
 *     fast duration on close, then unmount (motion spec #5/#6).
 *   - `Menu.Panel`: the same keyboarded list without a trigger or popup
 *     positioning, for hosts such as a `Drawer` bottom sheet.
 *
 * Accessibility (built in): trigger gets `aria-haspopup`/`aria-expanded`; the
 * list is `role="menu"`; items are `menuitem` or `menuitemradio` (+`aria-checked`)
 * with roving `tabindex`. On open focus goes to the header's first input, else the
 * checked item, else the first item. Down/Up move, Home/End jump, Enter/Space (or
 * click) activate + close, Esc closes and restores focus to the trigger, Tab
 * closes, outside-click closes.
 *
 * Tokens only: `z-dropdown`, surface/border/text roles, radius vars, shadows,
 * spacing, motion utilities.
 *
 * Escape hatch: `className` merges onto the popup.
 */
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import type { OpenChangeHandler, RootClassNameProps } from '../types';
import { Icon } from '../primitives/Icon';

/** `default` keeps the original compact menu; `picker` is the DESIGN.md menu surface; `sheet` is a bottom-sheet list (48px rows). */
export type MenuVariant = 'default' | 'picker' | 'sheet';

interface MenuCtx {
  close: (restoreFocus?: boolean) => void;
  variant: MenuVariant;
}
const MenuContext = createContext<MenuCtx | null>(null);

const MENUITEM_SELECTOR =
  '[role="menuitem"]:not([aria-disabled="true"]),' +
  '[role="menuitemradio"]:not([aria-disabled="true"]),' +
  '[role="menuitemcheckbox"]:not([aria-disabled="true"])';

const cx = (...parts: Array<string | false | null | undefined>) =>
  parts.filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();

/** Closing animations are unmounted on `animationend`; this is the fallback when none fires (no CSS, hidden tab). */
export const MENU_EXIT_FALLBACK_MS = 250;

// ---------------------------------------------------------------------------
// Menu.Panel — the keyboarded list, usable without a trigger.
// ---------------------------------------------------------------------------

export interface MenuPanelProps extends RootClassNameProps {
  /** Accessible name of the `role="menu"` list. */
  label?: string;
  /** Called with `restoreFocus` when an item activates, Esc is pressed or Tab leaves. */
  onClose: (restoreFocus?: boolean) => void;
  /** Content above the list (outside `role="menu"`), e.g. a search field. */
  header?: React.ReactNode;
  /** Item styling. Default `default`. */
  variant?: MenuVariant;
  /** Focus the header input / checked item / first item when mounted. Default true. */
  autoFocus?: boolean;
  /** Extra classes on the `role="menu"` list (the outer panel takes `className`). */
  listClassName?: string;
  style?: React.CSSProperties;
  children?: React.ReactNode;
}

/** The roving-focus `role="menu"` list behind `Menu`. Hosts own placement and dismissal. */
export const MenuPanel = React.forwardRef<HTMLDivElement, MenuPanelProps & Omit<React.HTMLAttributes<HTMLDivElement>, 'className' | 'children' | 'style'>>(
  function MenuPanel(
    { label, onClose, header, variant = 'default', autoFocus = true, className, listClassName, style, children, ...rest },
    forwardedRef,
  ) {
    const outerRef = useRef<HTMLDivElement | null>(null);
    const listRef = useRef<HTMLDivElement | null>(null);

    const items = useCallback(
      () => Array.from(listRef.current?.querySelectorAll<HTMLElement>(MENUITEM_SELECTOR) ?? []),
      [],
    );

    // Initial focus, once per mount (a remount = a new open).
    useEffect(() => {
      if (!autoFocus) return;
      const input = header ? outerRef.current?.querySelector<HTMLElement>('input:not([disabled]),textarea:not([disabled])') : null;
      if (input) {
        input.focus();
        return;
      }
      const list = items();
      const checked = list.find((el) => el.getAttribute('aria-checked') === 'true');
      (checked ?? list[0])?.focus();
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    function onKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
      rest.onKeyDown?.(event);
      if (event.defaultPrevented) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        onClose(true);
        return;
      }
      if (event.key === 'Tab') {
        onClose(false);
        return;
      }
      const list = items();
      const target = event.target as HTMLElement;
      const fromField = !listRef.current?.contains(target) && /^(INPUT|TEXTAREA)$/.test(target.tagName);
      if (fromField) {
        // Typing (including Home/End) stays in the field; arrows step into the list.
        if (event.key === 'ArrowDown' && list.length) {
          event.preventDefault();
          list[0].focus();
        } else if (event.key === 'ArrowUp' && list.length) {
          event.preventDefault();
          list[list.length - 1].focus();
        }
        return;
      }
      if (list.length === 0) return;
      const idx = list.indexOf(document.activeElement as HTMLElement);
      switch (event.key) {
        case 'ArrowDown':
          event.preventDefault();
          list[(idx + 1) % list.length]?.focus();
          break;
        case 'ArrowUp':
          event.preventDefault();
          list[(idx - 1 + list.length) % list.length]?.focus();
          break;
        case 'Home':
          event.preventDefault();
          list[0]?.focus();
          break;
        case 'End':
          event.preventDefault();
          list[list.length - 1]?.focus();
          break;
        default:
      }
    }

    const setOuter = (node: HTMLDivElement | null) => {
      outerRef.current = node;
      if (typeof forwardedRef === 'function') forwardedRef(node);
      else if (forwardedRef) forwardedRef.current = node;
    };

    const ctx = { close: onClose, variant };
    const list = (
      <MenuContext.Provider value={ctx}>{children}</MenuContext.Provider>
    );

    // Without a header the popup IS the menu (the original DOM shape).
    if (!header) {
      return (
        <div
          {...rest}
          ref={(node) => {
            setOuter(node);
            listRef.current = node;
          }}
          role="menu"
          aria-label={label}
          onKeyDown={onKeyDown}
          style={style}
          className={cx(className, listClassName)}
        >
          {list}
        </div>
      );
    }
    return (
      <div {...rest} ref={setOuter} onKeyDown={onKeyDown} style={style} className={className}>
        {header}
        <div ref={listRef} role="menu" aria-label={label} className={listClassName}>
          {list}
        </div>
      </div>
    );
  },
);

// ---------------------------------------------------------------------------
// Menu — trigger + anchored popup.
// ---------------------------------------------------------------------------

export interface MenuProps extends RootClassNameProps {
  /** The trigger element (cloned to add aria-haspopup/expanded + toggle). */
  trigger: React.ReactElement;
  /** Menu.Item / Menu.RadioItem children. */
  children?: React.ReactNode;
  /** Accessible name for the menu (when the trigger has no text of its own). */
  label?: string;
  /** Controlled open state (omit for uncontrolled). */
  open?: boolean;
  /** Fired when the open state should change. */
  onOpenChange?: OpenChangeHandler;
  /** Popup alignment relative to the trigger. Default `start` (left-aligned). */
  align?: 'start' | 'end';
  /**
   * Which side of the trigger the popup opens on. `bottom` (default) opens below;
   * `top` opens above — for triggers pinned near the viewport bottom (a composer
   * bar, a bottom toolbar) where a downward menu would clip off-screen.
   */
  side?: 'bottom' | 'top';
  /** Surface + item styling. Default `default` (unchanged compact menu). */
  variant?: Exclude<MenuVariant, 'sheet'>;
  /** Fixed popup width in px. */
  width?: number;
  /** Content above the items, outside `role="menu"` (e.g. a search field focused on open). */
  header?: React.ReactNode;
  /** Play `menuIn` on open and its reverse on close before unmounting. Default false. */
  animated?: boolean;
  /** `data-debug-id` for the popup. */
  popupDebugId?: string;
}

const MenuRoot: React.FC<MenuProps> = ({
  trigger,
  children,
  label,
  open: openProp,
  onOpenChange,
  align = 'start',
  side = 'bottom',
  variant = 'default',
  width,
  header,
  animated = false,
  popupDebugId,
  className,
}) => {
  const isControlled = openProp !== undefined;
  const [openState, setOpenState] = useState(false);
  const open = isControlled ? openProp : openState;

  // `closing` keeps the popup mounted for its exit animation. It is derived while
  // rendering (not in an effect) so the popup never unmounts for one commit and
  // remounts, which would restart the exit and re-run its initial focus.
  const [closing, setClosing] = useState(false);
  const [prevOpen, setPrevOpen] = useState(open);
  if (prevOpen !== open) {
    setPrevOpen(open);
    setClosing(!open && animated);
  }
  useEffect(() => {
    if (!closing) return;
    const timer = setTimeout(() => setClosing(false), MENU_EXIT_FALLBACK_MS);
    return () => clearTimeout(timer);
  }, [closing]);

  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLElement | null>(null);

  const setOpen = useCallback(
    (next: boolean) => {
      if (!isControlled) setOpenState(next);
      onOpenChange?.(next);
    },
    [isControlled, onOpenChange],
  );

  const close = useCallback(
    (restoreFocus = true) => {
      setOpen(false);
      if (restoreFocus) triggerRef.current?.focus();
    },
    [setOpen],
  );

  // Read the latest setOpen without re-running the open effect — a controlled
  // caller with an inline onOpenChange would otherwise re-run it every render and
  // steal focus back to the first item (same class as the Modal focus bug).
  const setOpenRef = useRef(setOpen);
  useEffect(() => {
    setOpenRef.current = setOpen;
  });

  // Close on outside pointer-down. Keyed on [open] ONLY so it runs once per open.
  // (Initial focus is MenuPanel's mount effect.)
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpenRef.current(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [open]);

  // Clone the trigger to wire aria + toggle + ref.
  const triggerEl = React.cloneElement(trigger, {
    'aria-haspopup': 'menu',
    'aria-expanded': open,
    onClick: (e: React.MouseEvent) => {
      (trigger.props as { onClick?: (e: React.MouseEvent) => void }).onClick?.(e);
      setOpen(!open);
    },
    ref: (node: HTMLElement | null) => {
      triggerRef.current = node;
      const r = (trigger as unknown as { ref?: React.Ref<HTMLElement> }).ref;
      if (typeof r === 'function') r(node);
      else if (r && typeof r === 'object') (r as React.MutableRefObject<HTMLElement | null>).current = node;
    },
  } as Record<string, unknown>);

  const picker = variant === 'picker';
  const origin =
    side === 'top'
      ? align === 'end' ? 'origin-bottom-right' : 'origin-bottom-left'
      : align === 'end' ? 'origin-top-right' : 'origin-top-left';
  const menuClassName = cx(
    picker
      ? // DESIGN.md `menu`: bg-200, radius-lg, 4px padding; a float, so it takes a shadow.
        'absolute z-dropdown rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-1 text-primary shadow-panel outline-none ' +
          'text-left font-sans text-body font-normal normal-case tracking-normal'
      : 'absolute z-dropdown min-w-[12rem] rounded-[var(--radius-md)] border border-subtle bg-surface text-primary py-1 shadow-overlay outline-none',
    side === 'top' ? (picker ? 'bottom-full mb-2.5' : 'bottom-full mb-1') : picker ? 'top-full mt-2.5' : 'top-full mt-1',
    align === 'end' ? 'right-0' : 'left-0',
    animated && origin,
    animated && (open ? 'animate-menu-in' : 'animate-menu-out pointer-events-none'),
    className,
  );

  const mounted = open || closing;

  return (
    <div ref={rootRef} className="relative inline-block">
      {triggerEl}
      {mounted ? (
        <MenuPanel
          key="menu-panel"
          label={label}
          onClose={close}
          header={header}
          variant={variant}
          autoFocus={open}
          data-debug-id={popupDebugId}
          data-state={open ? 'open' : 'closing'}
          aria-hidden={open ? undefined : true}
          onAnimationEnd={() => {
            if (!open) setClosing(false);
          }}
          style={width ? { width } : undefined}
          className={menuClassName}
        >
          {children}
        </MenuPanel>
      ) : null}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

function itemClassName(variant: MenuVariant, danger: boolean, className?: string) {
  if (variant === 'default') {
    return cx(
      'flex w-full items-center gap-2 px-3 py-1.5 text-left text-[length:var(--text-body-sm-size)]',
      'outline-none focus-visible:bg-neutral-soft hover:bg-neutral-soft',
      'disabled:opacity-50 disabled:cursor-not-allowed',
      danger ? 'text-danger' : 'text-primary',
      className,
    );
  }
  // picker / sheet: the reference `.opt` row (40px desktop, 48px in a sheet).
  return cx(
    'flex w-full items-center gap-3 rounded-[var(--radius-md)] px-2.5 py-2 text-left text-body',
    variant === 'sheet' ? 'min-h-12' : 'min-h-10',
    'outline-none transition-colors duration-fast ease-standard motion-reduce:transition-none',
    'hover:bg-neutral-soft focus-visible:bg-neutral-soft aria-checked:bg-neutral-soft',
    'disabled:cursor-not-allowed disabled:opacity-[.45] disabled:hover:bg-transparent',
    danger ? 'text-danger' : 'text-primary',
    className,
  );
}

interface RowContentProps {
  leading?: React.ReactNode;
  description?: React.ReactNode;
  trailing?: React.ReactNode;
  children?: React.ReactNode;
}

/** Shared row body: optional leading glyph/well, title + description, trailing slot. */
function RowContent({ leading, description, trailing, children }: RowContentProps) {
  if (leading === undefined && description === undefined && trailing === undefined) return <>{children}</>;
  return (
    <>
      {leading !== undefined ? <span className="inline-flex flex-none items-center text-muted">{leading}</span> : null}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="font-medium">{children}</span>
        {description !== undefined ? <span className="truncate text-body-sm text-muted">{description}</span> : null}
      </span>
      {trailing}
    </>
  );
}

export interface MenuItemProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className'>,
    RootClassNameProps {
  /** Marks a destructive action (danger styling). */
  danger?: boolean;
  /** Leading icon or icon well. */
  leading?: React.ReactNode;
  /** Secondary line under the label. */
  description?: React.ReactNode;
  /** Trailing content (badge, pill). */
  trailing?: React.ReactNode;
  /** Keep the menu open after activation (e.g. a provider column that swaps the models). Default false. */
  keepOpen?: boolean;
}

/** A single actionable row in a Menu. */
export const MenuItem: React.FC<MenuItemProps> = ({
  danger = false,
  disabled,
  onClick,
  className,
  children,
  leading,
  description,
  trailing,
  keepOpen = false,
  ...rest
}) => {
  const ctx = useContext(MenuContext);
  return (
    <button
      {...rest}
      type="button"
      role="menuitem"
      tabIndex={-1}
      aria-disabled={disabled || undefined}
      disabled={disabled}
      onClick={(e) => {
        onClick?.(e);
        if (!keepOpen) ctx?.close();
      }}
      className={itemClassName(ctx?.variant ?? 'default', danger, className)}
    >
      <RowContent leading={leading} description={description} trailing={trailing}>
        {children}
      </RowContent>
    </button>
  );
};

export interface MenuRadioItemProps extends Omit<MenuItemProps, 'danger'> {
  /** Whether this is the current choice (`aria-checked`). */
  checked: boolean;
}

/** A `menuitemradio` row: one choice among the menu's options, with an accent check when selected. */
export const MenuRadioItem: React.FC<MenuRadioItemProps> = ({
  checked,
  disabled,
  onClick,
  className,
  children,
  leading,
  description,
  trailing,
  keepOpen = false,
  ...rest
}) => {
  const ctx = useContext(MenuContext);
  return (
    <button
      {...rest}
      type="button"
      role="menuitemradio"
      aria-checked={checked}
      tabIndex={-1}
      aria-disabled={disabled || undefined}
      disabled={disabled}
      onClick={(e) => {
        onClick?.(e);
        if (!keepOpen) ctx?.close();
      }}
      className={itemClassName(ctx?.variant ?? 'default', false, className)}
    >
      <RowContent
        leading={leading}
        description={description}
        trailing={
          <>
            {trailing}
            {checked ? (
              // `pop` replays because the check mounts only when the row becomes selected (motion spec #7).
              <span className="inline-flex flex-none text-accent animate-pop">
                <Icon name="check" title="Selected" />
              </span>
            ) : null}
          </>
        }
      >
        {children}
      </RowContent>
    </button>
  );
};

/** A non-interactive section heading inside a Menu (groups related items). */
export const MenuLabel: React.FC<{ children?: React.ReactNode; className?: string }> = ({
  children,
  className,
}) => {
  const ctx = useContext(MenuContext);
  const roomy = ctx && ctx.variant !== 'default';
  return (
    <div
      role="presentation"
      className={cx(
        roomy
          ? 'flex justify-between px-2.5 pb-1 pt-2 text-overline uppercase text-faint'
          : 'px-3 pb-1 pt-2 text-[length:var(--text-caption-size)] font-semibold uppercase tracking-wide text-faint',
        className,
      )}
    >
      {children}
    </div>
  );
};

/** A thin divider between groups of Menu items. */
export const MenuSeparator: React.FC = () => (
  <div role="separator" className="my-1 border-t border-subtle" />
);

interface MenuComponent extends React.FC<MenuProps> {
  Item: typeof MenuItem;
  RadioItem: typeof MenuRadioItem;
  Label: typeof MenuLabel;
  Separator: typeof MenuSeparator;
  Panel: typeof MenuPanel;
}
export const Menu = MenuRoot as MenuComponent;
Menu.Item = MenuItem;
Menu.RadioItem = MenuRadioItem;
Menu.Label = MenuLabel;
Menu.Separator = MenuSeparator;
Menu.Panel = MenuPanel;

export default Menu;
