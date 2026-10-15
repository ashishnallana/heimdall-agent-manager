import React from 'react';
import { useRegisterActions } from '../../services/shortcuts/useRegisterActions';

function announceShortcut(sequence: string): void {
  window.alert(`Shortcut triggered: ${sequence}`);
}

/** Temporary development actions used to exercise the registry before real navigation lands. */
export function GlobalShortcutPreviewActions() {
  useRegisterActions([
    {
      id: 'preview.global.home',
      title: 'Preview global action: Home',
      category: 'Navigation',
      sequence: ['g', 'h'],
      run: () => announceShortcut('g h'),
    },
    {
      id: 'preview.global.conversations',
      title: 'Preview global action: Conversations',
      category: 'Navigation',
      sequence: ['g', 'c'],
      run: () => announceShortcut('g c'),
    },
  ]);
  return null;
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
