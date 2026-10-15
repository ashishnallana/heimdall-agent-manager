import React from 'react';
import { useRegisterActions } from '../../services/shortcuts/useRegisterActions';

function announceShortcut(sequence: string): void {
  window.alert(`Shortcut triggered: ${sequence}`);
}

/** Mounted by Workspace so these entries and handlers exist only on workspace pages. */
export function WorkspaceShortcutPreviewActions() {
  useRegisterActions([
    {
      id: 'preview.workspace.split-right',
      title: 'Preview workspace action: Split right',
      category: 'Workspace',
      sequence: ['s', 'v'],
      run: () => announceShortcut('s v'),
    },
    {
      id: 'preview.workspace.split-bottom',
      title: 'Preview workspace action: Split bottom',
      category: 'Workspace',
      sequence: ['s', 'h'],
      run: () => announceShortcut('s h'),
    },
  ]);
  return null;
}
