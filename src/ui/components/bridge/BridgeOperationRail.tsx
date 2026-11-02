import { Icon } from '@ui';

export interface BridgeOperationStep { id: string; label: string; hint?: string; state: 'done' | 'current' | 'todo' }

/** Shared wizard/Settings operation rail; steps describe UI, never backend work. */
export default function BridgeOperationRail({ items, label, debugId, className = '' }: {
  items: BridgeOperationStep[]; label: string; debugId: string; className?: string;
}) {
  const current = items.findIndex((item) => item.state === 'current');
  return <nav aria-label={label + ' steps'} data-debug-id={debugId} className={className}>
    <p className="mb-3 px-2 text-xs font-medium text-muted">{label}{current >= 0 ? ` · ${current + 1} of ${items.length}` : ''}</p>
    <ol className="flex flex-col gap-1">
      {items.map((item, index) => <li key={item.id} data-debug-id={debugId + '-' + item.id} data-state={item.state}
        aria-current={item.state === 'current' ? 'step' : undefined}
        className={'flex items-start gap-3 rounded-lg px-2 py-2 ' + (item.state === 'current' ? 'bg-surface-raised' : '')}>
        <span aria-hidden="true" className={'mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full text-xs font-medium ' +
          (item.state === 'done' ? 'bg-success-soft text-success' : item.state === 'current' ? 'bg-accent text-accent-fg' : 'border border-subtle text-muted')}>
          {item.state === 'done' ? <Icon name="check" size="sm" /> : index + 1}
        </span>
        <span className="min-w-0"><span className={'block text-sm font-medium ' + (item.state === 'todo' ? 'text-muted' : 'text-primary')}>{item.label}</span>
          {item.hint ? <span className="block text-xs text-muted">{item.hint}</span> : null}</span>
      </li>)}
    </ol>
  </nav>;
}
