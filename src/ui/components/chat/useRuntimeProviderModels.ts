/**
 * Provider + model selection logic shared by the "Agent settings" picker
 * (`RuntimeConfigurationOptions`, used by `AgentChatPane`) and the new-conversation
 * launcher's provider chip menu (`launcher/RuntimeMenu`).
 *
 * Given the selected bridge's provider capabilities and the current
 * `RuntimeSelection`, it lists the providers to offer (every capability profile
 * plus the current choice, even when that bridge no longer has it), and turns a
 * provider or model pick into the next selection.
 *
 * Per-provider model memory: a provider keeps the model last chosen in it for the
 * life of the component, so switching away and back restores that model (when the
 * bridge still offers it). Nothing here is persisted; callers persist the final
 * selection as they always have.
 */
import { useState } from 'react';
import type { BridgeCapability } from '../../api/endpoints/bridgeSupport';

export type RuntimeSelection = { bridgeId: string; provider: string; providerProfile?: string; model: string };

export interface RuntimeProviderModels {
  /** Profile id (or provider id) of the current choice. */
  selectedId: string;
  /** Profile/provider ids to list, capabilities first, then the current choice if missing. */
  providers: string[];
  capFor: (id: string) => BridgeCapability | undefined;
  /** The provider driver behind a profile id (`claude` for a `claude-work` profile). */
  driverFor: (id: string) => string;
  /** Display name of a provider/profile. */
  labelFor: (id: string) => string;
  modelsFor: (id: string) => string[];
  /** The model shown for a provider row: the selection's for the selected row, else its remembered one. */
  rowModel: (id: string) => string;
  /** Select a provider (restoring its remembered model, else its first). No-op when already selected. */
  chooseProvider: (id: string) => void;
  /** Select a model of a provider (selecting that provider too). */
  chooseModel: (id: string, model: string) => void;
}

export function useRuntimeProviderModels(
  caps: BridgeCapability[],
  selection: RuntimeSelection,
  onChange: (next: RuntimeSelection) => void,
): RuntimeProviderModels {
  const selectedId = selection.providerProfile || selection.provider;
  const providers = Array.from(new Set([...caps.map(c => c.profile_id || c.provider), selectedId].filter(Boolean)));
  const capFor = (id: string) => caps.find(c => (c.profile_id || c.provider) === id);
  const driverFor = (id: string) => capFor(id)?.provider || (id === selectedId ? selection.provider : '');
  const labelFor = (id: string) => capFor(id)?.label || id;
  const modelsFor = (id: string) => capFor(id)?.models || [];

  // Per-provider model picks for rows that are not the active selection, so a
  // provider row keeps the model last chosen in it when it is re-selected.
  const [rowModels, setRowModels] = useState<Record<string, string>>({});
  const rowModel = (id: string) => id === selectedId ? selection.model : rowModels[id] || '';
  const rememberCurrent = () => { if (selection.provider) setRowModels(prev => ({ ...prev, [selectedId]: selection.model })); };
  const profileFields = (id: string) => (id !== driverFor(id) || selection.providerProfile ? { providerProfile: id } : {});

  const chooseProvider = (id: string) => {
    if (id === selectedId) return;
    rememberCurrent();
    const remembered = rowModels[id];
    onChange({ ...selection, provider: driverFor(id), ...profileFields(id), model: remembered && modelsFor(id).includes(remembered) ? remembered : modelsFor(id)[0] || '' });
  };
  const chooseModel = (id: string, model: string) => {
    if (id !== selectedId) rememberCurrent();
    onChange({ ...selection, provider: driverFor(id), ...profileFields(id), model });
  };

  return {
    selectedId,
    providers,
    capFor,
    driverFor,
    labelFor,
    modelsFor,
    rowModel,
    chooseProvider,
    chooseModel,
  };
}
