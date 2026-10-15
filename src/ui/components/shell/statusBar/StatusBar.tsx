import { useRef, type ReactNode } from 'react';
import { Icon, type IconName } from '@ui';
import { useBottomChromeVar } from '../responsive';
import type { ShortcutMode } from '../../../services/shortcuts/shortcutLogic';
import type { ShellCounts } from './statusBarModel';

/**
 * Global bottom status bar (REQ-BAR-1), in the spirit of a tmux status line: three
 * slots (left / center / right), each an ordered list of modules.
 *
 * A module is a self-contained definition: where it sits (`slot`, `order`) and how it
 * renders given the bar's context. Every render receives `compact` (true on mobile),
 * so a module decides for itself what to drop when space is tight. To add one, write
 * a `StatusBarModuleDef` and append it to `STATUS_BAR_MODULES` (global), or pass it
 * through `StatusBar`'s `modules` prop (e.g. a route's contextual center module).
 */
export type StatusBarSlot = 'left' | 'center' | 'right';

/** Data the shell gathers once and hands to every module. Extend as modules need. */
export type StatusBarData = {
  runningInstances: number;
  connectedBridges: number;
  shells: ShellCounts;
  shortcutMode: ShortcutMode;
  /** Shell-owned vault toggle (its handlers and modal state live in AppShell). */
  renderVaultToggle: (compact: boolean) => ReactNode;
};

export type StatusBarContext = {
  /** True on mobile: render icon + value only and keep touch targets usable. */
  compact: boolean;
  data: StatusBarData;
};

export type StatusBarModuleDef = {
  id: string;
  slot: StatusBarSlot;
  /** Ascending within a slot; ties keep registration order. */
  order: number;
  /** Return null to hide the module in the current context. */
  render: (ctx: StatusBarContext) => ReactNode;
};

/** Compact view-only count module: icon + value, with a text label when not compact. */
export function StatusCount({
  icon,
  value,
  label,
  compact,
  tone = 'muted',
}: {
  icon: IconName;
  value: string;
  label: string;
  compact: boolean;
  tone?: 'muted' | 'active';
}) {
  return (
    <span
      role="status"
      aria-label={`${value} ${label}`}
      title={`${value} ${label}`}
      className={`inline-flex items-center gap-1 px-1.5 tabular-nums ${compact ? 'text-[13px]' : 'text-[11px]'} ${
        tone === 'active' ? 'text-primary' : 'text-muted'
      }`}
    >
      <Icon name={icon} size={compact ? 14 : 12} />
      <span className="font-semibold">{value}</span>
      {!compact ? <span className="text-faint">{label}</span> : null}
    </span>
  );
}

/** Orders a slot's modules and drops those that render nothing in this context. */
export function renderSlot(modules: readonly StatusBarModuleDef[], slot: StatusBarSlot, ctx: StatusBarContext) {
  return modules
    .map((module, index) => ({ module, index }))
    .filter(({ module }) => module.slot === slot)
    .sort((a, b) => a.module.order - b.module.order || a.index - b.index)
    .map(({ module }) => ({ id: module.id, node: module.render(ctx) }))
    .filter((entry) => entry.node !== null && entry.node !== undefined && entry.node !== false);
}

function Slot({ slot, modules, ctx, className }: { slot: StatusBarSlot; modules: readonly StatusBarModuleDef[]; ctx: StatusBarContext; className: string }) {
  return (
    <div data-debug-id={`shell-status-bar-${slot}`} className={`flex min-w-0 items-center gap-0.5 ${className}`}>
      {renderSlot(modules, slot, ctx).map(({ id, node }) => (
        <div key={id} data-debug-id={`shell-status-module-${id}`} className="flex shrink-0 items-center">
          {node}
        </div>
      ))}
    </div>
  );
}

export function StatusBar({ modules, compact, data }: { modules: readonly StatusBarModuleDef[]; compact: boolean; data: StatusBarData }) {
  const ref = useRef<HTMLElement | null>(null);
  // Publishes the bar's height as --ui-bottom-chrome so fixed mobile action bars
  // (BulkActionBar, detail-page sticky footers) sit above it instead of under it.
  useBottomChromeVar(ref);
  const ctx: StatusBarContext = { compact, data };
  return (
    <footer
      ref={ref}
      data-debug-id="shell-status-bar"
      data-compact={compact ? 'true' : 'false'}
      aria-label="Status bar"
      className={`ui-safe-bottom grid shrink-0 grid-cols-[1fr_auto_1fr] items-center gap-2 bg-canvas px-2 text-muted ${compact ? 'min-h-9' : 'min-h-7'}`}
    >
      <Slot slot="left" modules={modules} ctx={ctx} className="justify-start" />
      <Slot slot="center" modules={modules} ctx={ctx} className="justify-center" />
      <Slot slot="right" modules={modules} ctx={ctx} className="justify-end" />
    </footer>
  );
}

export default StatusBar;
