/**
 * LaunchComposer — the new-conversation page's shared composer (spec §3.4).
 * ------------------------------------------------------------------
 * One container for both modes, so the border stays put while the body swaps:
 *
 *   - `LaunchComposer`: the container. `bg-400` (`bg-subtle`) fill, `border-strong`
 *     border, `radius-xl`, padding 16/16/12. On focus-within the border turns
 *     accent with a 1px accent glow (motion #12, fast/standard). When `mode`
 *     changes after mount, the new body plays `composerSwap` (motion #11); never on
 *     first render and never under reduced motion.
 *   - `ConversationComposerBody`: textarea "Message the agent" and the footer bar:
 *     attach `IconButton` + agent chip on the left; `Kbd` "Ctrl Enter" (desktop),
 *     the provider chip and the accent send button (`arrow-up`) on the right.
 *   - `ShellComposerBody`: a `$` prompt in accent, a mono command field, and the
 *     footer bar: the `zsh` shell chip, "Opens in the {project|home} folder on
 *     {bridge}" and the primary "Open shell" button.
 *
 * Presentational: the page owns the state, the launch calls and the menus (it
 * passes the `AgentMenu` / `RuntimeMenu` chips in as nodes). Further shell
 * controls (a working directory, attaching to a running shell) can be added as
 * extra rows in `ShellComposerBody` without touching the container.
 */
import React, { forwardRef, useState, type ClipboardEvent, type FormEvent, type KeyboardEvent, type ReactNode } from 'react';
import { Badge, Button, Icon, IconButton, Kbd, Text } from '@ui';
import { MessageComposerInput } from '../MessageComposer';
import type { LauncherMode } from './ModeMenu';
import { prefersReducedMotion } from './SentenceToken';

const cx = (...parts: Array<string | false | null | undefined>) => parts.filter(Boolean).join(' ');

export const CONVERSATION_PLACEHOLDER = 'Message the agent';
export const SHELL_PLACEHOLDER = 'Run a command, or leave empty for an interactive shell';
export const SEND_SHORTCUT_HINT = 'Ctrl Enter';

/** The shell footer hint (spec §3.4): the project folder when the shell starts in one, else the home folder. */
export function shellFolderHint(inProjectFolder: boolean, bridgeName: string): string {
  const folder = inProjectFolder ? 'the project folder' : 'the home folder';
  return bridgeName ? `Opens in ${folder} on ${bridgeName}` : `Opens in ${folder}`;
}

export interface LaunchComposerProps {
  mode: LauncherMode;
  /** Dims the composer (45%) and blocks pointer input; sets `aria-disabled`. */
  disabled?: boolean;
  onSubmit?: (event: FormEvent<HTMLFormElement>) => void;
  children: ReactNode;
  debugId?: string;
}

/** The container. The forwarded ref is the element the launch transition moves. */
export const LaunchComposer = forwardRef<HTMLFormElement, LaunchComposerProps>(function LaunchComposer(
  { mode, disabled = false, onSubmit, children, debugId = 'new-convo-composer-shell' },
  ref,
) {
  // composerSwap (#11) only after a real mode change, derived while rendering
  // (an effect would render the new body once without the class first).
  const [swap, setSwap] = useState({ mode, count: 0 });
  if (swap.mode !== mode) setSwap({ mode, count: swap.count + 1 });
  const animate = swap.count > 0 && !prefersReducedMotion();
  return (
    <form
      ref={ref}
      onSubmit={onSubmit ?? ((event) => event.preventDefault())}
      data-debug-id={debugId}
      data-mode={mode}
      aria-disabled={disabled || undefined}
      className={cx(
        'relative rounded-[var(--radius-xl)] border border-strong bg-subtle px-4 pb-3 pt-4',
        'transition-[border-color,box-shadow] duration-fast ease-standard motion-reduce:transition-none',
        'focus-within:border-accent focus-within:shadow-[0_0_0_1px_var(--color-accent)]',
        disabled && 'pointer-events-none opacity-[.45]',
      )}
    >
      <div
        key={mode}
        data-composer-body={mode}
        className={cx('flex flex-col gap-3', animate && 'animate-composer-swap')}
      >
        {children}
      </div>
    </form>
  );
});

export interface ConversationComposerBodyProps {
  mobile: boolean;
  inputRef?: React.Ref<HTMLTextAreaElement>;
  draft: string;
  onDraftChange: (value: string) => void;
  /** Ctrl/Cmd+Enter. */
  onSubmitShortcut: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  onPaste?: (event: ClipboardEvent<HTMLTextAreaElement>) => void;
  inputDisabled?: boolean;
  /** Attachment rows, shown between the field and the footer. */
  attachments?: ReactNode;
  onAttach: () => void;
  attachDisabled?: boolean;
  /** The agent chip (`AgentMenu`). */
  agentChip: ReactNode;
  /** The provider + model chip (`RuntimeMenu`). */
  runtimeChip: ReactNode;
  sendDisabled: boolean;
}

export function ConversationComposerBody({
  mobile,
  inputRef,
  draft,
  onDraftChange,
  onSubmitShortcut,
  onPaste,
  inputDisabled,
  attachments,
  onAttach,
  attachDisabled,
  agentChip,
  runtimeChip,
  sendDisabled,
}: ConversationComposerBodyProps) {
  return (
    <>
      <MessageComposerInput
        ref={inputRef}
        mobile={mobile}
        appearance="launch"
        debugId="new-convo-composer-input"
        aria-label={CONVERSATION_PLACEHOLDER}
        placeholder={CONVERSATION_PLACEHOLDER}
        value={draft}
        disabled={inputDisabled}
        onChange={(event) => onDraftChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
            event.preventDefault();
            onSubmitShortcut(event);
          }
        }}
        onPaste={onPaste}
      />
      {attachments}
      {/* One row that never wraps (§3.7, like the classic composer toolbar): the attach
          and send buttons keep their size and the two chips shrink and truncate. */}
      <div data-debug-id="new-convo-composer-toolbar" className="flex min-w-0 flex-nowrap items-center gap-1.5 md:gap-2">
        <IconButton
          icon="plus"
          label="Attach files"
          size={mobile ? 'md' : 'sm'}
          className="shrink-0"
          data-debug-id="new-convo-attach-btn"
          disabled={attachDisabled}
          onClick={onAttach}
        />
        {agentChip}
        {/* One right-aligned group holding the provider chip and the send button. */}
        <div data-debug-id="new-convo-composer-send-group" className="ml-auto flex min-w-0 items-center gap-1.5 md:gap-2">
          {mobile ? null : <Kbd data-debug-id="new-convo-send-shortcut" className="shrink-0">{SEND_SHORTCUT_HINT}</Kbd>}
          {runtimeChip}
          <IconButton
            type="submit"
            icon="arrow-up"
            label="Start conversation"
            variant="primary"
            size={mobile ? 'md' : 'sm'}
            className="shrink-0"
            data-debug-id="new-convo-composer-send-btn"
            disabled={sendDisabled}
          />
        </div>
      </div>
    </>
  );
}

export interface ShellComposerBodyProps {
  mobile: boolean;
  inputRef?: React.Ref<HTMLTextAreaElement>;
  command: string;
  onCommandChange: (value: string) => void;
  inputDisabled?: boolean;
  /** True when the shell starts in the project's folder on the bridge. */
  inProjectFolder: boolean;
  bridgeName: string;
  onOpen: () => void;
  openDisabled: boolean;
  busy?: boolean;
  openRef?: React.Ref<HTMLButtonElement>;
}

export function ShellComposerBody({
  mobile,
  inputRef,
  command,
  onCommandChange,
  inputDisabled,
  inProjectFolder,
  bridgeName,
  onOpen,
  openDisabled,
  busy = false,
  openRef,
}: ShellComposerBodyProps) {
  return (
    <>
      <div className="flex min-w-0 items-start gap-2">
        <Text as="span" role="code" tone="accent" aria-hidden="true" data-debug-id="new-shell-prompt">$</Text>
        <MessageComposerInput
          ref={inputRef}
          mobile={mobile}
          appearance="launch"
          mono
          debugId="new-shell-command"
          aria-label="Command to run"
          placeholder={SHELL_PLACEHOLDER}
          value={command}
          disabled={inputDisabled}
          onChange={(event) => onCommandChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              if (!openDisabled) onOpen();
            }
          }}
        />
      </div>
      <div data-debug-id="new-shell-toolbar" className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge data-debug-id="new-shell-kind" className="font-mono">zsh</Badge>
        <Text as="span" role="body-sm" tone="muted" className="m-0 min-w-0" data-debug-id="new-shell-hint">
          {shellFolderHint(inProjectFolder, bridgeName)}
        </Text>
        <span className="flex-1" aria-hidden="true" />
        <Button
          ref={openRef}
          variant="primary"
          size="sm"
          leading={<Icon name="terminal" size="md" />}
          loading={busy}
          disabled={openDisabled}
          onClick={onOpen}
          data-debug-id="new-shell-open"
          className="active:scale-[.96] motion-reduce:active:scale-100 max-md:min-h-11"
        >
          {busy ? 'Opening…' : 'Open shell'}
        </Button>
      </div>
    </>
  );
}

export default LaunchComposer;
