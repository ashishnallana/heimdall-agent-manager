import { useEffect, useRef, type ReactNode } from 'react';

import { Drawer, Icon, Text, type IconName } from '@ui';
import { TOUCH_TARGET_CLASS } from '@ui/hooks/useViewport';
// UI-13: responsive/mobile primitives shared across the shell.
// Breakpoints (approx, per arch doc §6D): <768px mobile, 768–1024px tablet,
// >1024px desktop. The desktop "two panes side-by-side" collapses to mobile
// screens/sheets: sidebar = off-canvas drawer; main = full-width; a bottom tab
// bar with a command-palette center button replaces sidebar chrome; the right
// inspector becomes a bottom sheet; chain list/detail become a drill-down.

// UI-13: the breakpoint primitives now live in `@ui/hooks/useViewport` — `@ui`'s own
// responsive components (DataList, BulkActionBar) need them, and an `@ui` component
// importing from this app-level module would invert the layering and close an import
// cycle. Re-exported here so every existing call site keeps importing them from
// `shell/responsive` unchanged, with one implementation behind both paths.
export {
  MOBILE_MAX,
  TABLET_MAX,
  TAILWIND_SM_MIN,
  useViewport,
  useIsMobile,
  useIsBelowTailwindSm,
  TOUCH_TARGET_CLASS,
} from '@ui/hooks/useViewport';
export type { Viewport } from '@ui/hooks/useViewport';

export type MobileTab = {
  id: string;
  label: string;
  icon: IconName;
  route: string;
  badge?: number;
};

// UI-13: the mobile bottom tab bar. Home / Chains / (palette center) / Chats / Settings.
// `onOpenPalette` opens the command palette from the center button. The four
// outer tabs navigate; debug-ids are layout-independent (same as desktop nav).
export type MobileTabBarProps = {
  activePath: string;
  onNavigate: (route: string) => void;
  onOpenPalette: () => void;
  onOpenSettings?: () => void;
  isSettingsOpen?: boolean;
  chatBadge?: number;
  chainsBadge?: number;
  // The center palette button's debug-id is owned by the shell so the palette
  // entry point has one stable, layout-independent id (also satisfies UI-12).
  paletteDebugId?: string;
  className?: string;
};

// Bottom tabs: Home (the Action Cards home page) and Chats replace the former
// Chat/Agents entries; the command-palette stays the center button.
const TABS: { id: string; label: string; icon: IconName; route: string }[] = [
  // Home routes to the Home page (/home).
  { id: 'home', label: 'Home', icon: 'home', route: '/home' },
  // Slot 2 sits immediately left of the palette button: Task Chains, not Projects.
  { id: 'chains', label: 'Chains', icon: 'tasks', route: '/chains' },
  // Conversations sit right of the palette button.
  { id: 'chats', label: 'Chats', icon: 'chat', route: '/conversations' },
  { id: 'settings', label: 'Settings', icon: 'gear', route: '/settings/bridges' },
];

/**
 * `--ui-bottom-chrome` — how much persistent chrome the app keeps pinned to the
 * bottom edge. Published on the document root from the tab bar's REAL measured
 * height (padding and safe-area inset included), so anything that docks at the
 * bottom — `@ui`'s `BulkActionBar`, today — can sit above it instead of under it.
 *
 * It lives here rather than in `AppShell` because the bar itself is the thing whose
 * height it reports, and it is a CSS variable rather than a prop because `@ui`
 * components must not import the shell and no page should have to remember to pass
 * a shell measurement down. Cleared on unmount: when the tab bar is gone (desktop,
 * or a chrome-suppressed route) the variable is absent and consumers fall back to 0.
 */
export function useBottomChromeVar(ref: { current: HTMLElement | null }) {
  useEffect(() => {
    const node = ref.current;
    if (!node || typeof window === 'undefined') return undefined;
    const root = document.documentElement;
    const publish = () => {
      // offsetHeight, not the transform-aware bounding box: the bar is translated
      // out of view while scrolling (`scrollChromeSuppressed`) but still occupies
      // the same space the moment it comes back, and a bar that re-docked under the
      // tab bar on every scroll would be worse than one that never moved.
      root.style.setProperty('--ui-bottom-chrome', `${node.offsetHeight}px`);
    };
    publish();
    const observer = new ResizeObserver(publish);
    observer.observe(node);
    return () => {
      observer.disconnect();
      root.style.removeProperty('--ui-bottom-chrome');
    };
  }, [ref]);
}

export function MobileTabBar({
  activePath,
  onNavigate,
  onOpenPalette,
  onOpenSettings,
  isSettingsOpen = false,
  chatBadge = 0,
  chainsBadge = 0,
  paletteDebugId = 'shell-mobile-palette-button',
  className = '',
}: MobileTabBarProps) {
  const isActive = (route: string) => {
    if (route === '/home') {
      return activePath === '/home' || activePath.startsWith('/home/') || activePath === '/cards' || activePath.startsWith('/cards/');
    }
    return activePath === route || activePath.startsWith(`${route}/`);
  };
  const navRef = useRef<HTMLElement | null>(null);
  useBottomChromeVar(navRef);
  return (
    <nav
      ref={navRef}
      data-debug-id="shell-mobile-tab-bar"
      aria-label="Mobile bottom navigation"
      // Solid background, not a translucent blur (spec › GLOBAL FIXES): content
      // scrolling under a blurred bar reads as a rendering fault, and the bar is
      // what everything else on the bottom edge measures itself against. The safe
      // area is padding on the bar itself, so the tabs sit above the home indicator
      // rather than under it.
      // REQ-VIEWPORT-SWEEP-1: `app-viewport-bottom`, NOT `bottom-0`. `bottom-0` resolved
      // against the layout viewport, which a soft keyboard does not shrink, so with the
      // keyboard up this bar sat at 758..814 against a visible region ending at 409 — the
      // app's primary navigation did not exist while typing. `ui-safe-bottom` still handles
      // the home indicator; the two are alternatives the browser resolves independently.
      className={`ui-safe-bottom fixed inset-x-0 app-viewport-bottom z-40 grid grid-cols-5 items-stretch border-t border-subtle bg-surface transition-transform duration-300 ease-in-out md:hidden ${className}`}
    >
      {TABS.slice(0, 2).map((tab) => (
        <MobileTabButton key={tab.id} tab={tab} active={isActive(tab.route)} badge={tab.id === 'chains' ? chainsBadge : 0} onClick={() => onNavigate(tab.route)} />
      ))}
      {/* Center = command palette (dedicated center button per arch doc §6D). */}
      <div className="flex items-end justify-center pb-1">
        <button
          type="button"
          data-debug-id={paletteDebugId}
          onClick={onOpenPalette}
          aria-label="Command palette"
          className={`grid h-12 w-12 -translate-y-2 place-items-center rounded-full border border-subtle bg-accent text-accent-fg shadow-lg hover:opacity-90 ${TOUCH_TARGET_CLASS}`}
        >
          <Icon name="search" size={20} />
        </button>
      </div>
      {TABS.slice(2).map((tab) => (
        <MobileTabButton
          key={tab.id}
          tab={tab}
          active={tab.id === 'settings' ? (isSettingsOpen || isActive(tab.route)) : isActive(tab.route)}
          badge={tab.id === 'chats' ? chatBadge : 0}
          onClick={() => {
            if (tab.id === 'settings' && onOpenSettings) {
              onOpenSettings();
            } else {
              onNavigate(tab.route);
            }
          }}
        />
      ))}
    </nav>
  );
}

function MobileTabButton({ tab, active, badge = 0, onClick }: { tab: { id: string; label: string; icon: IconName; route: string }; active: boolean; badge?: number; onClick: () => void }) {
  return (
    <button
      type="button"
      data-debug-id={`shell-mobile-tab-${tab.id}`}
      onClick={onClick}
      aria-current={active ? 'page' : undefined}
      className={`relative flex flex-col items-center justify-center gap-0.5 py-1.5 text-[10px] ${active ? 'text-primary' : 'text-faint'} ${TOUCH_TARGET_CLASS}`}
    >
      <span aria-hidden="true" className="leading-none"><Icon name={tab.icon} size={20} /></span>
      <span>{tab.label}</span>
      {badge > 0 ? <span data-debug-id={`shell-mobile-tab-${tab.id}-badge`} className="absolute right-3 top-0.5 min-w-4 rounded-full bg-accent px-1 text-center text-[9px] font-bold leading-4 text-accent-fg">{badge > 99 ? '99+' : badge}</span> : null}
    </button>
  );
}

// UI-13: mobile-only top bar that replaces desktop sidebar chrome. Carries the
// drawer (off-canvas sidebar) toggle, the current title, and an optional
// inspector toggle (conversation right inspector -> bottom sheet).
export type MobileTopBarProps = {
  title: string;
  onOpenDrawer: () => void;
  inspectorToggle?: { label?: string; badge?: number; open?: boolean; onToggle: () => void };
};

export function MobileTopBar({ title, onOpenDrawer, inspectorToggle }: MobileTopBarProps) {
  return (
    <header
      data-debug-id="shell-mobile-top-bar"
      className="ui-safe-top sticky top-0 z-30 flex min-h-12 items-center gap-2 border-b border-subtle bg-surface/95 px-2 backdrop-blur md:hidden"
    >
      <button
        type="button"
        data-debug-id="shell-mobile-drawer-open"
        onClick={onOpenDrawer}
        aria-label="Open navigation"
        className={`grid h-10 w-10 shrink-0 place-items-center rounded-xl text-primary hover:bg-neutral-soft ${TOUCH_TARGET_CLASS}`}
      >
        <Icon name="menu" size={18} />
      </button>
      <h1 data-debug-id="shell-mobile-title" className="min-w-0 flex-1 truncate text-sm font-semibold text-primary">{title}</h1>
      {inspectorToggle ? (
        <button
          type="button"
          data-debug-id="shell-mobile-inspector-toggle"
          onClick={inspectorToggle.onToggle}
          aria-pressed={inspectorToggle.open ? 'true' : 'false'}
          aria-label={inspectorToggle.label || 'Toggle inspector'}
          className={`relative inline-flex shrink-0 items-center gap-1 rounded-xl border px-3 text-xs font-semibold ${inspectorToggle.open ? 'border-accent/40 bg-accent/15 text-accent' : 'border-subtle bg-neutral-soft text-muted hover:bg-surface-raised'} ${TOUCH_TARGET_CLASS}`}
        >
          <span>{inspectorToggle.label || 'Inspector'}</span>
          {typeof inspectorToggle.badge === 'number' && inspectorToggle.badge > 0 ? (
            <span data-debug-id="shell-mobile-inspector-badge" className="min-w-4 rounded-full bg-accent px-1 text-center text-[9px] font-bold leading-4 text-accent-fg">{inspectorToggle.badge > 99 ? '99+' : inspectorToggle.badge}</span>
          ) : null}
        </button>
      ) : null}
    </header>
  );
}

// UI-13: chain drill-down header. Desktop shows task list + detail side-by-side;
// mobile drills down: list (full-screen) -> tap task -> detail (full-screen) with
// a back affordance. This header provides that back navigation on mobile only.
export type MobileBackHeaderProps = {
  title: string;
  onBack: () => void;
  action?: ReactNode;
};

export function MobileBackHeader({ title, onBack, action }: MobileBackHeaderProps) {
  return (
    <header data-debug-id="shell-mobile-back-header" className="ui-safe-top sticky top-0 z-30 flex min-h-12 items-center gap-2 border-b border-subtle bg-surface/95 px-2 backdrop-blur md:hidden">
      <button
        type="button"
        data-debug-id="shell-mobile-back-btn"
        onClick={onBack}
        aria-label="Back"
        className={`grid h-10 w-10 shrink-0 place-items-center rounded-xl text-primary hover:bg-neutral-soft ${TOUCH_TARGET_CLASS}`}
      >
        <Icon name="chevron-left" size={18} />
      </button>
      <h2 data-debug-id="shell-mobile-back-title" className="min-w-0 flex-1 truncate text-sm font-semibold text-primary">{title}</h2>
      {action ? <div className="shrink-0">{action}</div> : null}
    </header>
  );
}

// UI-13: mobile bottom-sheet shell for the conversation right inspector. The
// desktop right-aside inspector collapses to a slide-up sheet on mobile; tabs
// render as a segmented control. Content/labels/debug-ids are supplied by the
// caller (ContextInspector) so they stay layout-independent (arch doc §6D).
export type MobileInspectorSheetProps = {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  subtitle?: ReactNode;
  headerActions?: ReactNode;
  children: ReactNode;
};

export function MobileInspectorSheet({ open, onClose, title, subtitle, headerActions, children }: MobileInspectorSheetProps) {
  // A bottom slide-up sheet built on @ui Drawer (portal, focus trap, Esc, scroll
  // lock, backdrop close — the a11y contract the bespoke sheet lacked). Drawer's
  // header renders the title + close; the "Inspector" eyebrow, subtitle and any
  // headerActions sit in a compact sub-header above the body.
  return (
    <Drawer
      side="bottom"
      open={open}
      onOpenChange={(next) => { if (!next) onClose(); }}
      title={title || 'Inspector'}
      aria-label="Inspector"
      data-debug-id="workspace-inspector"
      data-mobile-sheet="true"
      className="ui-safe-bottom md:hidden"
    >
      {(subtitle || headerActions) ? (
        <div className="flex items-start justify-between gap-3 px-5 pb-1">
          <div className="min-w-0">
            <Text as="div" role="overline" tone="muted">Inspector</Text>
            {subtitle ? <div className="truncate text-[11.5px] text-muted">{subtitle}</div> : null}
          </div>
          {headerActions ? <div className="flex shrink-0 items-center gap-2">{headerActions}</div> : null}
        </div>
      ) : null}
      <Drawer.Body>{children}</Drawer.Body>
    </Drawer>
  );
}
