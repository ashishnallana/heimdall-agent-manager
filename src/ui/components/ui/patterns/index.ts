/**
 * Patterns barrel — product-specific compositions worth naming.
 * Re-exported through the top-level `@ui` barrel (`../index.ts`).
 */

export {
  RuntimeChip,
  runtimeStateFromStatus,
  runtimeStateLabel,
  runtimeStatusToTone,
  RUNTIME_STATE_TONE,
} from './RuntimeChip';
export type { RuntimeChipProps, RuntimeState } from './RuntimeChip';

export * from './ScopeField';

export { CommandPalette, DEFAULT_ACTIONS, mergePaletteActions } from './CommandPalette';
export type {
  CommandPaletteProps,
  PaletteAction,
  PaletteConversation,
  PaletteConversationGroup,
  PaletteResult,
} from './CommandPalette';
