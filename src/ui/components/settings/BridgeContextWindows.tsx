import { useEffect, useState } from 'react';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { Badge, Button, Input, Text } from '@ui';
import {
  CONTEXT_WINDOW_PRESETS,
  type ContextWindowEntry,
  type ContextWindowState,
  contextWindowClearPath,
  contextWindowSourceHelp,
  contextWindowSourceLabel,
  contextWindowsPath,
  formatContextWindow,
  normalizeContextWindowState,
  parseCustomContextWindow,
} from './contextWindowSettings';

const SOURCE_TONE = { override: 'info', reported: 'info', config: 'neutral', default: 'warning' } as const;

function entryKey(e: { provider: string; model: string }): string {
  return `${e.provider}\u0000${e.model}`;
}

function errorText(err: any, fallback: string): string {
  const code = err?.details?.bridge_error;
  const message = String(err?.message || fallback);
  return code && !message.includes(code) ? `${message} (${code})` : message;
}

// Per-bridge context windows (optionally filtered to one provider): what each provider/model resolves to and where the
// value comes from. The bridge is the source of truth; every reply carries its
// full state and replaces ours.
export default function BridgeContextWindows({ bridgeId, online, provider }: { bridgeId: string; online: boolean; provider?: string }) {
  const [state, setState] = useState<ContextWindowState | null>(null);
  const [loadError, setLoadError] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [custom, setCustom] = useState('');
  const [customError, setCustomError] = useState('');
  const [saveError, setSaveError] = useState('');
  const [saving, setSaving] = useState(false);
  const path = contextWindowsPath(bridgeId);

  useEffect(() => {
    let active = true;
    setState(null);
    setLoadError('');
    setEditing(null);
    if (online) {
      void cookieJsonFetch(path).then((data: any) => {
        if (!active) return;
        const next = normalizeContextWindowState(data);
        if (next) setState(next);
        else setLoadError('Bridge returned no context-window settings; it may need an update.');
      }).catch((err: any) => { if (active) setLoadError(errorText(err, 'Could not load context windows')); });
    }
    return () => { active = false; };
  }, [path, online]);

  function openEditor(e: ContextWindowEntry) {
    const key = entryKey(e);
    setEditing(editing === key ? null : key);
    setCustom('');
    setCustomError('');
    setSaveError('');
  }

  async function apply(run: () => Promise<any>) {
    setSaving(true);
    setSaveError('');
    try {
      const next = normalizeContextWindowState(await run());
      if (!next) throw new Error('Bridge did not confirm the change');
      setState(next);
      setEditing(null);
      setCustom('');
    } catch (err: any) {
      setSaveError(errorText(err, 'Could not save the context window'));
    } finally {
      setSaving(false);
    }
  }

  function setWindow(e: ContextWindowEntry, value: number) {
    void apply(() => cookieMutation(path, 'PUT', { provider: e.provider, model: e.model, context_window: value }));
  }

  function setCustomWindow(e: ContextWindowEntry) {
    const parsed = parseCustomContextWindow(custom);
    if ('error' in parsed) { setCustomError(parsed.error); return; }
    setCustomError('');
    setWindow(e, parsed.value);
  }

  function clearOverride(e: ContextWindowEntry) {
    void apply(() => cookieMutation(contextWindowClearPath(bridgeId, e.provider, e.model), 'DELETE'));
  }

  const windows = state ? (provider ? state.windows.filter((w) => w.provider === provider) : state.windows) : [];
  const missing = windows.filter((w) => w.source === 'default').length;

  return <div className="flex flex-col gap-2" data-debug-id={`settings-bridge-context-windows-${bridgeId}${provider ? `-${provider}` : ''}`}>
    <Text as="span" role="caption" tone="muted">
      Context windows{!online ? ' (connect to view or change)' : state === null && !loadError ? ' (loading…)' : ''}
    </Text>
    {state ? <Text as="p" role="caption" tone="muted">
      The context meter turns amber at {state.warn_pct}% of the window (display only; nothing is sent to the agent), and at {state.rollover_pct}% the agent rolls over: it restarts with a fresh context.
      {missing > 0 ? ` ${missing} model${missing === 1 ? ' is' : 's are'} not in the shipped config and use${missing === 1 ? 's' : ''} the ${formatContextWindow(state.default_window)} default.` : ''}
    </Text> : null}
    {loadError ? <p role="alert" className="text-caption text-danger">{loadError}</p> : null}
    {state && windows.length === 0 ? <Text as="p" role="caption" tone="muted">{provider ? `No ${provider} models known on this bridge yet.` : 'No provider models known on this bridge yet.'}</Text> : null}
    {state && windows.length > 0 ? <ul className="flex flex-col gap-1" aria-label="Context windows by provider and model">
      {windows.map((w) => {
        const key = entryKey(w);
        const open = editing === key;
        const isDefault = w.source === 'default';
        return <li key={key}
          data-debug-id={`settings-bridge-context-window-${w.provider}-${w.model}`}
          data-source={w.source}
          className={`flex flex-col gap-2 rounded-md border px-2 py-1.5 ${isDefault ? 'border-warning-soft bg-warning-soft/30' : 'border-subtle'}`}>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex min-w-0 flex-col">
              <Text as="span" role="label" truncate>{w.provider} / {w.model}</Text>
              {w.resolved_model ? <Text as="span" role="caption" tone="muted" truncate>resolves to {w.resolved_model}</Text> : null}
            </div>
            <div className="flex items-center gap-2">
              <Text as="span" role="label" data-role="context-window-value">{formatContextWindow(w.context_window)}</Text>
              <span title={contextWindowSourceHelp(w.source, state.default_window)}>
                <Badge tone={SOURCE_TONE[w.source]} data-role="context-window-source">{contextWindowSourceLabel(w.source)}</Badge>
              </span>
              <Button size="sm" variant="ghost" disabled={!online || saving}
                aria-expanded={open}
                aria-label={`Change context window for ${w.provider} ${w.model}`}
                onClick={() => openEditor(w)}>{open ? 'Cancel' : 'Change'}</Button>
            </div>
          </div>
          {w.window_mismatch ? <Text as="p" role="caption" tone="warning" data-role="context-window-mismatch">
            Provider reports {formatContextWindow(w.reported_window ?? w.context_window)}, which differs from the configured window by more than 10%. Check the config or set an override.
          </Text> : null}
          {open ? <div className="flex flex-col gap-2" data-role="context-window-editor">
            <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Preset context windows">
              {CONTEXT_WINDOW_PRESETS.map((p) => <Button key={p.value} size="sm"
                variant={w.source === 'override' && w.context_window === p.value ? 'primary' : 'secondary'}
                disabled={saving} data-preset={p.value}
                onClick={() => setWindow(w, p.value)}>{p.label}</Button>)}
              {w.source === 'override' ? <Button size="sm" variant="ghost" disabled={saving}
                data-role="context-window-clear"
                onClick={() => clearOverride(w)}>Clear override</Button> : null}
            </div>
            <form className="flex flex-wrap items-center gap-2" onSubmit={(ev) => { ev.preventDefault(); setCustomWindow(w); }}>
              <Input size="sm" value={custom} placeholder="Custom, e.g. 150K"
                aria-label={`Custom context window for ${w.provider} ${w.model}`}
                invalid={customError !== ''}
                onChange={(v) => { setCustom(v); if (customError) setCustomError(''); }} />
              <Button size="sm" type="submit" disabled={saving}>Set</Button>
            </form>
            {customError ? <p role="alert" className="text-caption text-danger" data-role="context-window-custom-error">{customError}</p> : null}
            <Text as="p" role="caption" tone="muted">Minimum {formatContextWindow(state.min_window)} tokens.</Text>
          </div> : null}
        </li>;
      })}
    </ul> : null}
    {saveError ? <p role="alert" className="text-caption text-danger" data-role="context-window-save-error">{saveError}</p> : null}
  </div>;
}
