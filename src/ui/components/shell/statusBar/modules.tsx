import { StatusCount, type StatusBarModuleDef } from './StatusBar';
import { formatCount } from './statusBarModel';

const plural = (count: number, one: string, many: string) => (count === 1 ? one : many);

/** Vim-style shortcut mode, derived from focus and the one-shot editable override. */
export const shortcutModeModule: StatusBarModuleDef = {
  id: 'shortcut-mode',
  slot: 'left',
  order: 10,
  render: ({ compact, data }) => {
    const normal = data.shortcutMode === 'normal';
    const fullLabel = normal ? 'Normal' : 'Insert';
    return (
      <span
        data-debug-id="shell-shortcut-mode"
        data-mode={data.shortcutMode}
        role="status"
        aria-label={`Shortcut mode: ${fullLabel}`}
        title={`${fullLabel} shortcut mode`}
        className={`inline-flex items-center px-1.5 font-bold tracking-wide ${compact ? 'text-[13px]' : 'text-[11px]'} ${
          normal ? 'text-info' : 'text-accent'
        }`}
      >
        {normal ? 'NOR' : 'INS'}
      </span>
    );
  },
};

/** Vault lock state; interactive (lock / unlock / reconcile), owned by the shell. */
export const vaultModule: StatusBarModuleDef = {
  id: 'vault',
  slot: 'right',
  order: 40,
  render: ({ compact, data }) => data.renderVaultToggle(compact),
};

export const bridgesModule: StatusBarModuleDef = {
  id: 'bridges',
  slot: 'left',
  order: 20,
  render: ({ compact, data }) => (
    <StatusCount icon="device" value={formatCount(data.connectedBridges)} label={plural(data.connectedBridges, 'bridge', 'bridges')} compact={compact} />
  ),
};

export const instancesModule: StatusBarModuleDef = {
  id: 'instances',
  slot: 'right',
  order: 10,
  render: ({ compact, data }) => (
    <StatusCount
      icon="bot"
      value={formatCount(data.runningInstances)}
      label={plural(data.runningInstances, 'instance', 'instances')}
      compact={compact}
      tone={data.runningInstances > 0 ? 'active' : 'muted'}
    />
  ),
};

export const shellsModule: StatusBarModuleDef = {
  id: 'shells',
  slot: 'right',
  order: 20,
  render: ({ compact, data }) => (
    <StatusCount icon="terminal" value={formatCount(data.shells.shells, data.shells.capped)} label={plural(data.shells.shells, 'shell', 'shells')} compact={compact} />
  ),
};

export const previewsModule: StatusBarModuleDef = {
  id: 'previews',
  slot: 'right',
  order: 30,
  render: ({ compact, data }) => (
    <StatusCount icon="eye" value={formatCount(data.shells.previews, data.shells.capped)} label={plural(data.shells.previews, 'preview', 'previews')} compact={compact} />
  ),
};

/**
 * Attention deck pill: one number for everything that needs the user (task reviews
 * and agent questions), no per-kind breakdown -- the deck's tabs carry that. Amber
 * while something is waiting, quiet "All clear" otherwise. Opens the deck.
 */
export const attentionModule: StatusBarModuleDef = {
  id: 'attention',
  slot: 'right',
  order: 5,
  render: ({ compact, data }) => {
    if (!data.attention) return null;
    const { total, onOpen } = data.attention;
    const waiting = (total ?? 0) > 0;
    const label = total === null ? '…' : waiting ? `${formatCount(total)} need you` : 'All clear';
    const short = total === null ? '…' : waiting ? formatCount(total) : '✓';
    return (
      <button
        type="button"
        data-debug-id="shell-attention-pill"
        data-state={total === null ? 'loading' : waiting ? 'waiting' : 'clear'}
        onClick={onOpen}
        aria-label={total === null ? 'Attention: loading' : waiting ? `${total} items need you. Open the attention deck` : 'Nothing needs you. Open the attention deck'}
        title={waiting ? 'Open what needs you (g a)' : 'Nothing needs you (g a)'}
        className={`mx-0.5 inline-flex items-center gap-1 rounded-full border px-2 font-semibold tabular-nums ${compact ? 'min-h-[28px] text-[13px]' : 'text-[11px]'} ${
          waiting ? 'border-warning-soft bg-warning-soft text-warning hover:brightness-110' : 'border-transparent text-muted hover:text-primary'
        }`}
      >
        <span aria-hidden="true" className={`inline-block h-1.5 w-1.5 rounded-full ${waiting ? 'bg-warning motion-safe:animate-pulse' : 'bg-success'}`} />
        <span>{compact ? short : label}</span>
      </button>
    );
  },
};

/** Global modules, in no particular order (each declares its slot and order). */
export const STATUS_BAR_MODULES: readonly StatusBarModuleDef[] = [
  shortcutModeModule,
  vaultModule,
  bridgesModule,
  instancesModule,
  shellsModule,
  previewsModule,
  attentionModule,
];
