import React, { useMemo } from 'react';
import { Kbd, Modal } from '@ui';
import { useShortcuts } from '../../services/shortcuts/ShortcutContext';
import {
  isActionEnabled,
  type ActionCategory,
  type AppAction,
} from '../../services/shortcuts/shortcutLogic';

const CATEGORY_ORDER: ActionCategory[] = ['General', 'Navigation', 'Workspace'];

function debugIdForAction(actionId: string): string {
  return `shortcut-cheatsheet-action-${actionId.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`;
}

export function ShortcutCheatsheetModal() {
  const { actions, cheatsheetOpen, runAction, setCheatsheetOpen } = useShortcuts();
  const groupedActions = useMemo(() => {
    const groups = new Map<ActionCategory, AppAction[]>();
    for (const category of CATEGORY_ORDER) groups.set(category, []);
    for (const action of actions) groups.get(action.category)?.push(action);
    return CATEGORY_ORDER.map((category) => ({ category, actions: groups.get(category) ?? [] }))
      .filter((group) => group.actions.length > 0);
  }, [actions]);

  return (
    <Modal
      open={cheatsheetOpen}
      onOpenChange={setCheatsheetOpen}
      title="Keyboard shortcuts"
      size="lg"
      data-debug-id="shortcut-cheatsheet-modal"
      data-shortcut-cheatsheet="true"
    >
      <Modal.Body className="space-y-5">
        {groupedActions.map((group) => (
          <section key={group.category} aria-labelledby={`shortcut-category-${group.category.toLowerCase()}`}>
            <h3
              id={`shortcut-category-${group.category.toLowerCase()}`}
              className="mb-2 text-label font-semibold text-muted"
            >
              {group.category}
            </h3>
            <div className="overflow-hidden rounded-[var(--radius-md)] border border-subtle">
              {group.actions.map((action) => {
                const enabled = isActionEnabled(action);
                return (
                  <button
                    key={action.id}
                    type="button"
                    data-debug-id={debugIdForAction(action.id)}
                    disabled={!enabled}
                    onClick={() => {
                      if (runAction(action.id)) setCheatsheetOpen(false);
                    }}
                    className="flex min-h-11 w-full items-center justify-between gap-4 border-b border-subtle px-3 py-2 text-left text-sm text-primary transition-colors last:border-b-0 hover:bg-surface-raised focus-visible:bg-surface-raised focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    <span>{action.title}</span>
                    <span className="flex shrink-0 items-center gap-1" aria-label={action.sequence.join(' then ')}>
                      {action.sequence.map((key, index) => <Kbd key={`${key}-${index}`}>{key}</Kbd>)}
                    </span>
                  </button>
                );
              })}
            </div>
          </section>
        ))}
        <p className="border-t border-subtle pt-4 text-caption text-muted">
          Shortcuts pause while you type in a composer, terminal, or code editor. Press Escape to leave that surface before using pane shortcuts.
        </p>
      </Modal.Body>
    </Modal>
  );
}

export default ShortcutCheatsheetModal;
