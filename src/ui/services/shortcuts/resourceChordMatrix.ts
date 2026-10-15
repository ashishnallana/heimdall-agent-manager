import type { LauncherIntent } from '../../store/workspaceLayoutSlice';

export type ResourcePlacement = 'replace' | 'right' | 'bottom';
export type OpenResourceKind = 'conversation' | 'task-chain' | 'shell';

export type LocalResourceChord = {
  id: string;
  title: string;
  sequence: readonly string[];
  placement: ResourcePlacement;
  resource?: OpenResourceKind;
  launchIntent?: LauncherIntent;
};

const placements = [
  { placement: 'replace' as const, suffix: [] as string[], title: 'in focused pane' },
  { placement: 'right' as const, suffix: ['v'], title: 'in pane right' },
  { placement: 'bottom' as const, suffix: ['h'], title: 'in pane below' },
];

export const LOCAL_RESOURCE_CHORDS: readonly LocalResourceChord[] = [
  ...([
    { resource: 'conversation' as const, key: 'c', title: 'conversation' },
    { resource: 'task-chain' as const, key: 't', title: 'task-chain coordinator' },
    { resource: 'shell' as const, key: 's', title: 'running shell' },
  ]).flatMap((item) => placements.map((variant) => ({
    id: `workspace.open-${item.resource}-${variant.placement}`,
    title: `Open ${item.title} ${variant.title}`,
    sequence: ['s', 'o', item.key, ...variant.suffix],
    placement: variant.placement,
    resource: item.resource,
  }))),
  ...([
    { launchIntent: 'agent' as const, key: 'c', title: 'conversation' },
    { launchIntent: 'shell' as const, key: 's', title: 'shell' },
  ]).flatMap((item) => placements.map((variant) => ({
    id: `workspace.new-${item.launchIntent}-${variant.placement}`,
    title: `New ${item.title} ${variant.title}`,
    sequence: ['s', 'n', item.key, ...variant.suffix],
    placement: variant.placement,
    launchIntent: item.launchIntent,
  }))),
];
