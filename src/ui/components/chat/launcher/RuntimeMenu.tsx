/**
 * RuntimeMenu — the composer's provider + model chip and its two-column menu.
 * ------------------------------------------------------------------
 * Spec §3.3 "Provider + model menu", §3.4 (chip "{mark} {Provider} {model}"),
 * §3.7 (mobile: stacked columns in a bottom sheet, no model name on the chip),
 * motion §4 #8 (the model column replays `fadeSlide` when the provider changes).
 *
 * - Left column: the selected bridge's providers (its capabilities plus the
 *   current choice). "Signed in on {bridge}" when the bridge has it, otherwise
 *   "Not installed on {bridge}" and disabled.
 * - Right column: "{Provider} model" and that provider's models.
 * - Picking a provider keeps the menu open and swaps the right column; picking a
 *   model closes it.
 * - Per-provider model memory for the session and the pick-to-selection rules
 *   come from `useRuntimeProviderModels`, shared with `RuntimeConfigurationOptions`
 *   (the Agent settings picker in `AgentChatPane`). Nothing is persisted here; the
 *   caller keeps persisting the final `runtime` as before.
 *
 * Built on `SentenceToken` (chip appearance) → `@ui` `Menu` (desktop) / `Drawer`
 * sheet (mobile), with `Menu.RadioItem` rows in two `role="group"` columns.
 * Props-only (capabilities are passed in) so the page owns the bridge query.
 */
import React from 'react';
import { Menu } from '@ui';
import ProviderIcon from '../../providers/ProviderIcon';
import type { BridgeCapability } from '../../../api/endpoints/bridgeSupport';
import { useRuntimeProviderModels, type RuntimeSelection } from '../useRuntimeProviderModels';
import { SentenceToken, prefersReducedMotion } from './SentenceToken';

export const RUNTIME_MENU_WIDTH = 560;

export interface RuntimeMenuProps {
  /** The selected bridge's provider capabilities (`useBridgeProviderStatus(selectedBridge).capabilities`). */
  capabilities: BridgeCapability[];
  /** Display name of the selected bridge, for the provider subtitles. */
  bridgeLabel: string;
  selection: RuntimeSelection;
  onChange: (next: RuntimeSelection) => void;
  disabled?: boolean;
  /** Prefix for `data-debug-id`s. Default `new-convo`. */
  debugPrefix?: string;
  /** Desktop menu side/alignment under the chip. Default `bottom` / `end`. */
  side?: 'bottom' | 'top';
  align?: 'start' | 'end';
  /** Controlled open state (e.g. to poll provider status only while open). */
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /** Extra content under the model list (e.g. `ModelCatalogRefresh`). */
  modelFooter?: React.ReactNode;
}

const cx = (...parts: Array<string | false | null | undefined>) => parts.filter(Boolean).join(' ');

/** The provider glyph in a small well: 18px on the chip, 28px in menu rows. */
function ProviderMark({ provider, large = false }: { provider: string; large?: boolean }) {
  return (
    <span
      aria-hidden="true"
      className={cx(
        'inline-flex flex-none items-center justify-center rounded-[var(--radius-sm)] bg-strong text-primary',
        large ? 'h-7 w-7' : 'h-[18px] w-[18px]',
      )}
    >
      <ProviderIcon provider={provider} size={large ? 18 : 14} />
    </span>
  );
}

export function RuntimeMenu({
  capabilities,
  bridgeLabel,
  selection,
  onChange,
  disabled = false,
  debugPrefix = 'new-convo',
  side = 'bottom',
  align = 'end',
  open,
  onOpenChange,
  modelFooter,
}: RuntimeMenuProps) {
  const runtime = useRuntimeProviderModels(capabilities, selection, onChange);
  const { selectedId, providers, capFor, driverFor, labelFor, modelsFor, chooseProvider, chooseModel } = runtime;
  const bridge = bridgeLabel || 'this bridge';
  const providerLabel = selectedId ? labelFor(selectedId) : '';
  const available = Boolean(selectedId && capFor(selectedId));
  const models = modelsFor(selectedId);
  // The current model stays listed (disabled) when the bridge no longer offers it.
  const modelRows = Array.from(new Set([...models, selection.model].filter(Boolean)));

  return (
    <SentenceToken
      appearance="chip"
      value={`${selectedId}\u0000${selection.model}`}
      label="Provider and model"
      debugId={`${debugPrefix}-runtime-picker`}
      menuWidth={RUNTIME_MENU_WIDTH}
      side={side}
      align={align}
      open={open}
      onOpenChange={onOpenChange}
      disabled={disabled}
      menuClassName="!p-0"
      leading={selectedId ? <ProviderMark provider={driverFor(selectedId)} /> : undefined}
      renderMenu={({ isMobile }) => (
        <div data-debug-id={`${debugPrefix}-runtime-menu-columns`} className={cx('flex', isMobile ? 'flex-col' : 'flex-row')}>
          <div role="group" aria-label="Provider" className="min-w-0 flex-1 p-1">
            <Menu.Label>Provider</Menu.Label>
            {providers.length === 0 ? (
              <p className="px-2.5 py-2 text-body-sm text-muted">No providers on {bridge}.</p>
            ) : null}
            {providers.map((id) => {
              const installed = Boolean(capFor(id));
              return (
                <Menu.RadioItem
                  key={id}
                  keepOpen
                  checked={id === selectedId}
                  disabled={disabled || !installed}
                  leading={<ProviderMark provider={driverFor(id)} large />}
                  description={installed ? `Signed in on ${bridge}` : `Not installed on ${bridge}`}
                  data-debug-id={`${debugPrefix}-provider-option-${id}`}
                  onClick={() => chooseProvider(id)}
                >
                  {labelFor(id)}
                </Menu.RadioItem>
              );
            })}
          </div>
          <div
            // Keyed on the provider so `fadeSlide` replays on every switch (motion #8).
            key={selectedId || 'none'}
            role="group"
            aria-label={providerLabel ? `${providerLabel} model` : 'Model'}
            data-debug-id={`${debugPrefix}-model-column`}
            className={cx(
              'min-w-0 flex-1 bg-surface p-1',
              isMobile ? 'border-t border-subtle' : 'rounded-r-[var(--radius-lg)] border-l border-subtle',
              !prefersReducedMotion() && 'animate-fade-slide',
            )}
          >
            <Menu.Label>{providerLabel ? `${providerLabel} model` : 'Model'}</Menu.Label>
            {modelRows.map((model) => {
              const offered = models.includes(model);
              return (
                <Menu.RadioItem
                  key={model}
                  checked={model === selection.model}
                  disabled={disabled || !available || !offered}
                  description={offered ? undefined : `Not available on ${bridge}`}
                  data-debug-id={`${debugPrefix}-model-option-${model}`}
                  onClick={() => chooseModel(selectedId, model)}
                >
                  {model}
                </Menu.RadioItem>
              );
            })}
            {modelRows.length === 0 ? (
              <p className="px-2.5 py-2 text-body-sm text-muted">
                {selectedId ? `No models for ${providerLabel} on ${bridge}.` : 'Choose a provider first.'}
              </p>
            ) : null}
            {modelFooter ? <div className="px-2.5 pb-1.5 pt-1">{modelFooter}</div> : null}
          </div>
        </div>
      )}
    >
      {selectedId ? (
        <>
          {/* Icon-only at phone widths (below 440px), so the agent chip keeps room on the
              one-row composer toolbar; the name stays for screen readers. */}
          <span data-runtime-chip-provider="" className="truncate max-[439px]:sr-only">{providerLabel}</span>
          {selection.model ? <span data-runtime-chip-model="" className="hidden truncate font-normal text-muted md:inline">{selection.model}</span> : null}
        </>
      ) : (
        <span className="text-muted">Choose a provider</span>
      )}
    </SentenceToken>
  );
}

export default RuntimeMenu;
