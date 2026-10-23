import React from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { externalKeyboardSet, selectUseExternalKeyboard } from '../../store/inputPreferencesSlice';
import { Badge, Icon } from '@ui';
import { useTheme } from '../../store/themeSlice';
import { ThemeDefinition } from '../../theme/registry';

export function AppearanceSettings() {
  const dispatch = useDispatch();
  const useExternalKeyboard = useSelector(selectUseExternalKeyboard);
  const { theme: activeTheme, themeId, setTheme, themes } = useTheme();

  return (
    <div data-debug-id="appearance-settings" className="space-y-6 text-left">
      <div>
        <h2 className="text-lg font-semibold text-primary">Appearance & Themes</h2>
        <p className="mt-1 text-sm text-muted">
          Select a theme to customize the dashboard color palette, syntax highlighting, and terminal colors.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3" data-debug-id="theme-grid">
        {themes.map((t: ThemeDefinition) => {
          const isSelected = t.id === themeId;
          const isLight = t.appearance === 'light';

          return (
            <button
              key={t.id}
              type="button"
              data-debug-id={`theme-card-${t.id}`}
              onClick={() => setTheme(t.id)}
              className={`relative flex flex-col justify-between rounded-xl border p-4 text-left transition-all outline-none ${
                isSelected
                  ? 'border-accent ring-2 ring-accent/40 bg-surface-raised'
                  : 'border-subtle bg-surface hover:border-strong hover:bg-surface-raised'
              }`}
            >
              <div className="flex w-full items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2">
                    <span className="font-semibold text-primary">{t.label}</span>
                    <Badge tone={isLight ? 'warning' : 'neutral'}>
                      {isLight ? 'Light' : 'Dark'}
                    </Badge>
                  </div>
                  <span className="mt-1 block text-xs text-faint">
                    {t.id}
                  </span>
                </div>

                {isSelected ? (
                  <div
                    data-debug-id={`theme-active-indicator-${t.id}`}
                    className="flex h-6 w-6 items-center justify-center rounded-full bg-accent text-accent-fg"
                    title="Active Theme"
                  >
                    <Icon name="check" className="h-3.5 w-3.5" />
                  </div>
                ) : null}
              </div>

              {/* Color swatches preview */}
              <div
                data-debug-id={`theme-swatches-${t.id}`}
                className="mt-4 flex items-center gap-1.5 rounded-lg border border-subtle p-2"
                style={{ backgroundColor: t.tokens.canvas }}
              >
                <div
                  className="h-4 w-4 rounded-full border border-subtle"
                  style={{ backgroundColor: t.tokens.surface }}
                  title="Surface"
                />
                <div
                  className="h-4 w-4 rounded-full"
                  style={{ backgroundColor: t.tokens.accent }}
                  title="Accent"
                />
                <div
                  className="h-4 w-4 rounded-full"
                  style={{ backgroundColor: t.tokens.success }}
                  title="Success"
                />
                <div
                  className="h-4 w-4 rounded-full"
                  style={{ backgroundColor: t.tokens.warning }}
                  title="Warning"
                />
                <div
                  className="h-4 w-4 rounded-full"
                  style={{ backgroundColor: t.tokens.danger }}
                  title="Danger"
                />
                <div
                  className="h-4 w-4 rounded-full"
                  style={{ backgroundColor: t.tokens.info }}
                  title="Info"
                />
                <div
                  className="ml-auto text-xs font-mono font-bold"
                  style={{ color: t.tokens.textPrimary }}
                >
                  Aa
                </div>
              </div>
            </button>
          );
        })}
      </div>

      <section aria-labelledby="appearance-input-heading" className="rounded-xl border border-subtle bg-surface p-4">
        <h3 id="appearance-input-heading" className="font-semibold text-primary">Input</h3>
        <label className="mt-2 flex min-h-11 cursor-pointer items-center gap-3 py-2">
          <input
            type="checkbox"
            data-debug-id="settings-external-keyboard-checkbox"
            checked={useExternalKeyboard}
            onChange={event => dispatch(externalKeyboardSet(event.target.checked))}
            aria-describedby="appearance-external-keyboard-help"
            className="h-5 w-5 shrink-0 accent-accent"
          />
          <span className="text-sm font-medium text-primary">Use external keyboard</span>
        </label>
        <p id="appearance-external-keyboard-help" className="text-sm text-muted">
          Hide the on-screen keyboard in message composers. Turn off to type on screen.
        </p>
      </section>

      <div className="rounded-xl border border-subtle bg-surface p-4 text-sm text-muted">
        <span className="font-medium text-primary">Current Theme:</span>{' '}
        <span className="font-semibold text-accent">{activeTheme.label}</span> ({activeTheme.appearance})
      </div>
    </div>
  );
}

export default AppearanceSettings;
