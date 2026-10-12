import { useState } from 'react';
import { Combobox, Icon } from '@ui';
import ProviderIcon from '../providers/ProviderIcon';
import { normalizeBridgeCapabilities } from '../../api/endpoints/bridgeSupport';
import { COMPOSER_BRIDGE_STATUS_LABEL, composerBridgeOptions } from '../../utils/composerBridgeOptions';
export type RuntimeSelection = { bridgeId: string; provider: string; model: string };
export default function RuntimeConfigurationOptions({ bridges, selection, onChange, disabled, debugPrefix, requireReconfiguration = false }: { bridges: any[]; selection: RuntimeSelection; onChange: (next: RuntimeSelection) => void; disabled?: boolean; debugPrefix: string; requireReconfiguration?: boolean }) {
  // Archived bridges are not offered at all; offline ones are listed but disabled.
  const bridgeOptions = composerBridgeOptions(bridges, requireReconfiguration);
  const bridge = bridgeOptions.find(o => o.id === selection.bridgeId)?.bridge;
  const caps = normalizeBridgeCapabilities(bridge);
  const providers = Array.from(new Set([...caps.map(c => c.provider), selection.provider].filter(Boolean)));
  const modelsFor = (p: string) => caps.find(c => c.provider === p)?.models || [];
  // Per-provider model picks for rows that are not the active selection, so a
  // provider row keeps the model last chosen in it when it is re-selected.
  const [rowModels, setRowModels] = useState<Record<string, string>>({});
  const rowModel = (p: string) => p === selection.provider ? selection.model : rowModels[p] || '';
  const rememberCurrent = () => { if (selection.provider) setRowModels(prev => ({ ...prev, [selection.provider]: selection.model })); };
  const chooseProvider = (p: string) => {
    if (p === selection.provider) return;
    rememberCurrent();
    const remembered = rowModels[p];
    onChange({ ...selection, provider: p, model: remembered && modelsFor(p).includes(remembered) ? remembered : modelsFor(p)[0] || '' });
  };
  const chooseModel = (p: string, m: string) => {
    if (p !== selection.provider) rememberCurrent();
    onChange({ ...selection, provider: p, model: m });
  };
  return <div className="space-y-4">
    <section><h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Bridge</h3><div className="grid gap-2 sm:grid-cols-2">{bridgeOptions.map(({ id, bridge: b, disabledReason }) => {
      const selected = id === selection.bridgeId;
      return <button type="button" key={id} data-debug-id={`${debugPrefix}-destination-bridge-option-${id}`} aria-pressed={selected} disabled={disabled || disabledReason !== null} onClick={() => onChange({ ...selection, bridgeId: id })} className={`flex min-h-14 items-center justify-between gap-3 rounded-xl border px-3 py-3 text-left disabled:opacity-50 ${selected ? 'border-accent bg-accent/10' : 'border-subtle hover:bg-neutral-soft'}`}><span className="min-w-0"><span className="block break-words text-sm font-medium text-primary">{b.label || b.machine_hostname || id}</span><span className="block text-xs text-muted">{COMPOSER_BRIDGE_STATUS_LABEL[disabledReason ?? 'ok']}</span></span>{selected ? <Icon name="check" size={18} className="shrink-0 text-accent" /> : null}</button>;
    })}</div>{!bridge && selection.bridgeId ? <p className="mt-2 text-xs text-danger">Selected bridge is unavailable. Choose a connected bridge.</p> : null}</section>
    <section data-debug-id={`${debugPrefix}-provider-model-picker`}>
      <div className="mb-2 grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)] gap-3 text-xs font-semibold uppercase tracking-wide text-muted"><h3>Provider</h3><h3>Model</h3></div>
      <div className="space-y-2">{providers.map(p => {
        const available = caps.some(c => c.provider === p);
        const selected = p === selection.provider;
        const current = rowModel(p);
        const options = Array.from(new Set([...modelsFor(p), current].filter(Boolean))).map(m => ({ value: m, title: m, tag: modelsFor(p).includes(m) ? undefined : 'Unavailable' }));
        return <div key={p} data-debug-id={`${debugPrefix}-provider-row-${p}`} className={`grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)] items-center gap-3 rounded-xl border p-2 ${selected ? 'border-accent bg-accent/10' : 'border-subtle'}`}>
          <button type="button" data-debug-id={`${debugPrefix}-provider-option-${p}`} aria-pressed={selected} disabled={disabled || !available} onClick={() => chooseProvider(p)} className="flex min-h-11 min-w-0 items-center gap-2 rounded-lg px-1 text-left hover:bg-neutral-soft disabled:opacity-50">
            <ProviderIcon provider={p} size={18} />
            <span className="min-w-0 flex-1"><span className="block truncate text-sm font-medium text-primary">{p}</span>{!available ? <span className="block text-xs text-muted">Unavailable on selected bridge</span> : null}</span>
            {selected ? <Icon name="check" size={18} className="shrink-0 text-accent" /> : null}
          </button>
          <Combobox debugId={`${debugPrefix}-model-select-${p}`} options={options} value={current} onChange={m => chooseModel(p, m)} placeholder="Choose model" searchPlaceholder="Search models…" emptyLabel="No models" disabled={disabled || !available} width="full" />
        </div>;
      })}</div>
      {selection.model && !modelsFor(selection.provider).includes(selection.model) ? <p className="mt-2 text-xs text-danger">Selected model is unavailable for {selection.provider}. Choose another model.</p> : null}
    </section>
  </div>;
}
