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

/** Global modules, in no particular order (each declares its slot and order). */
export const STATUS_BAR_MODULES: readonly StatusBarModuleDef[] = [
  shortcutModeModule,
  vaultModule,
  bridgesModule,
  instancesModule,
  shellsModule,
  previewsModule,
];
