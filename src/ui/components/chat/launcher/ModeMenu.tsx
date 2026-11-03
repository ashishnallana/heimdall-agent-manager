/**
 * ModeMenu — the `[conversation | shell]` token of the launcher headline
 * (spec §3.1 mode token, §3.3 mode menu: 300px, two rows with icon wells).
 *
 * Presentational: the page owns the value (persisted to `heimdall:new-pane-mode`)
 * and passes the setter as `onChange`.
 */
import React from 'react';
import { IconWell } from '@ui';
import { SentenceToken, type SentenceTokenOption } from './SentenceToken';

/** Same values the page already persists (`heimdall:new-pane-mode`). */
export type LauncherMode = 'agent' | 'shell';

export const MODE_MENU_WIDTH = 300;

export const MODE_OPTIONS: ReadonlyArray<SentenceTokenOption<LauncherMode>> = [
  {
    value: 'agent',
    label: 'Conversation',
    tokenLabel: 'conversation',
    description: 'Chat with an agent that works in the project',
    leading: <IconWell icon="chat" />,
    debugId: 'new-convo-mode-option-agent',
  },
  {
    value: 'shell',
    label: 'Shell',
    tokenLabel: 'shell',
    description: 'A terminal in the project folder',
    leading: <IconWell icon="terminal" />,
    debugId: 'new-convo-mode-option-shell',
  },
];

export interface ModeMenuProps {
  value: LauncherMode;
  onChange: (mode: LauncherMode) => void;
  disabled?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}

export function ModeMenu({ value, onChange, disabled, open, onOpenChange }: ModeMenuProps) {
  return (
    <SentenceToken<LauncherMode>
      value={value}
      options={MODE_OPTIONS}
      onChange={onChange}
      label="Mode"
      debugId="new-convo-mode-token"
      menuWidth={MODE_MENU_WIDTH}
      disabled={disabled}
      open={open}
      onOpenChange={onOpenChange}
    />
  );
}

export default ModeMenu;
