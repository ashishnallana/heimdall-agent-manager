import { Icon } from '@ui';
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
/**
 * What needs the user, in the bridge count's old place on the left. Waiting
 * items the user has not seen yet spin an amber ring around the pill (static
 * under reduced motion); once the deck is opened the ring stands still until
 * the count goes up again. All clear is quiet.
 */
export const attentionModule: StatusBarModuleDef = {
  id: 'attention',
  slot: 'left',
  order: 20,
  render: ({ compact, data }) => {
    if (!data.attention) return null;
    const { total, unseen, onOpen } = data.attention;
    const waiting = (total ?? 0) > 0;
    const ringing = waiting && unseen;
    const label = total === null ? '…' : waiting ? `${formatCount(total)} need you` : 'All clear';
    const short = total === null ? '…' : waiting ? formatCount(total) : '';
    return (
      <button
        type="button"
        data-debug-id="shell-attention-pill"
        data-state={total === null ? 'loading' : waiting ? 'waiting' : 'clear'}
        data-ring={waiting ? (ringing ? 'spinning' : 'static') : 'none'}
        onClick={onOpen}
        aria-label={total === null ? 'Attention: loading' : waiting ? `${total} items need you${ringing ? ', new' : ''}. Open the attention deck` : 'Nothing needs you. Open the attention deck'}
        title={waiting ? 'Open what needs you (g a)' : 'Nothing needs you (g a)'}
        className={`relative mx-0.5 inline-flex overflow-hidden rounded-full p-[1.5px] font-semibold tabular-nums ${compact ? 'min-h-[28px] text-[13px]' : 'text-[11px]'}`}
      >
        {waiting ? (
          <span
            aria-hidden="true"
            data-debug-id="shell-attention-ring"
            className={`absolute left-1/2 top-1/2 aspect-square w-[300%] -translate-x-1/2 -translate-y-1/2 ${ringing ? 'motion-safe:animate-[spin_2.5s_linear_infinite]' : ''}`}
            style={{ background: ringing ? 'conic-gradient(var(--color-warning) 0deg, var(--color-warning) 70deg, transparent 160deg, transparent 300deg, var(--color-warning) 360deg)' : 'var(--color-warning)' }}
          />
        ) : null}
        <span className={`relative inline-flex items-center gap-1 rounded-full bg-canvas px-2 ${waiting ? 'text-warning' : 'text-muted hover:text-primary'}`}>
          <Icon name={waiting || total === null ? 'bell' : 'check'} size={compact ? 14 : 12} className={waiting ? '' : 'text-success'} />
          {compact ? (short ? <span>{short}</span> : null) : <span>{label}</span>}
        </span>
      </button>
    );
  },
};

/** Global modules, in no particular order (each declares its slot and order). */
export const STATUS_BAR_MODULES: readonly StatusBarModuleDef[] = [
  shortcutModeModule,
  vaultModule,
  instancesModule,
  shellsModule,
  previewsModule,
  attentionModule,
];
