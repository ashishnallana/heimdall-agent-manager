import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@ui';
import { useDialogA11y } from '../ui/composites/useDialogA11y';
import {
  type CommandCategory,
  type EditorCommand,
  type EditorCommandContext,
  COMMAND_CATEGORIES,
  DEFAULT_EDITOR_COMMANDS,
  filterEditorCommands,
} from '../../commands/editorCommands';

export interface ProjectCommandPaletteModalProps {
  isOpen: boolean;
  onClose: () => void;
  context: EditorCommandContext;
  commands?: EditorCommand[];
  initialQuery?: string;
}

// These were five arbitrary hues (purple/amber/emerald/cyan/indigo) from the
// raw Tailwind palette. The theme carries a single accent plus semantic status
// tones, so a five-hue rainbow cannot be expressed in it without inventing
// colors that belong to no theme. The chips are already labelled with their
// category, so the label carries the distinction and the chip carries the
// theme. Semantic tones are reserved for status, not taxonomy.
const CATEGORY_CHIP = 'bg-info-soft text-accent border-info-soft';

const CATEGORY_COLORS: Record<CommandCategory, string> = {
  LSP: CATEGORY_CHIP,
  Search: CATEGORY_CHIP,
  File: CATEGORY_CHIP,
  View: CATEGORY_CHIP,
  Directory: CATEGORY_CHIP,
};

export function ProjectCommandPaletteModal({
  isOpen,
  onClose,
  context,
  commands = DEFAULT_EDITOR_COMMANDS,
  initialQuery = '',
}: ProjectCommandPaletteModalProps) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);

  const [query, setQuery] = useState(initialQuery);
  const [selectedCategory, setSelectedCategory] = useState<CommandCategory | 'ALL'>('ALL');
  const [selectedIndex, setSelectedIndex] = useState(0);

  useDialogA11y(isOpen, onClose, panelRef);

  // Sync / reset state on open
  useEffect(() => {
    if (isOpen) {
      setQuery(initialQuery);
      setSelectedCategory('ALL');
      setSelectedIndex(0);
      window.setTimeout(() => {
        inputRef.current?.focus();
        inputRef.current?.select();
      }, 0);
    }
  }, [isOpen, initialQuery]);

  const filteredCommands = useMemo(() => {
    return filterEditorCommands(commands, query, selectedCategory, context);
  }, [commands, query, selectedCategory, context]);

  // Keep selected index within bounds
  useEffect(() => {
    if (selectedIndex >= filteredCommands.length) {
      setSelectedIndex(Math.max(0, filteredCommands.length - 1));
    }
  }, [filteredCommands.length, selectedIndex]);

  // Scroll active item into view
  useEffect(() => {
    if (!listRef.current) return;
    const el = listRef.current.querySelector<HTMLElement>(`[data-command-index="${selectedIndex}"]`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [selectedIndex]);

  const executeCommand = (cmd: EditorCommand) => {
    onClose();
    try {
      void cmd.run(context);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error(`[CommandPalette] Error executing command ${cmd.id}:`, err);
    }
  };

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="project-command-palette-modal"
      role="presentation"
      className="fixed inset-x-0 top-0 app-viewport-height z-modal flex items-start justify-center bg-surface-overlay/80 px-2 pt-[max(env(safe-area-inset-top),0.5rem)] backdrop-blur-sm sm:px-4 sm:pt-[calc(var(--app-viewport-height)*0.12)]"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Editor Command Palette"
        className="flex max-h-[calc(var(--app-viewport-height)-1rem)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface-overlay shadow-overlay outline-none sm:max-h-[calc(var(--app-viewport-height)*0.7)]"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Search Input Bar */}
        <div className="flex items-center gap-3 border-b border-subtle px-4 py-3">
          <span aria-hidden="true" className="text-muted">
            <Icon name="terminal" size={16} />
          </span>
          <input
            ref={inputRef}
            data-debug-id="command-palette-input"
            type="text"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setSelectedIndex(0);
            }}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setSelectedIndex((prev) =>
                  filteredCommands.length > 0 ? (prev + 1) % filteredCommands.length : 0
                );
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setSelectedIndex((prev) =>
                  filteredCommands.length > 0
                    ? (prev - 1 + filteredCommands.length) % filteredCommands.length
                    : 0
                );
              } else if (e.key === 'Enter') {
                e.preventDefault();
                if (filteredCommands.length > 0) {
                  const selected = filteredCommands[selectedIndex] || filteredCommands[0];
                  if (selected) {
                    executeCommand(selected);
                  }
                }
              }
            }}
            placeholder="Type a command or '>' to filter..."
            className="min-w-0 flex-1 bg-transparent text-[15px] text-primary outline-none placeholder:text-faint"
            autoComplete="off"
            spellCheck={false}
          />
          <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted">
            esc
          </kbd>
        </div>

        {/* Category Filter Chips Bar */}
        <div
          data-debug-id="command-palette-category-bar"
          className="flex items-center gap-1.5 border-b border-subtle bg-surface-raised px-4 py-2 overflow-x-auto text-xs"
        >
          <button
            type="button"
            data-debug-id="command-category-all"
            onClick={() => {
              setSelectedCategory('ALL');
              setSelectedIndex(0);
              inputRef.current?.focus();
            }}
            className={`rounded-full px-2.5 py-0.5 font-medium transition-colors ${
              selectedCategory === 'ALL'
                ? 'bg-primary text-surface-overlay'
                : 'bg-neutral-soft text-muted hover:text-primary'
            }`}
          >
            All
          </button>
          {COMMAND_CATEGORIES.map((cat) => {
            const isSelected = selectedCategory === cat;
            return (
              <button
                key={cat}
                type="button"
                data-debug-id={`command-category-${cat.toLowerCase()}`}
                onClick={() => {
                  setSelectedCategory(cat);
                  setSelectedIndex(0);
                  inputRef.current?.focus();
                }}
                className={`rounded-full px-2.5 py-0.5 font-medium transition-colors ${
                  isSelected
                    ? 'bg-primary text-surface-overlay'
                    : 'bg-neutral-soft text-muted hover:text-primary'
                }`}
              >
                {cat}
              </button>
            );
          })}
        </div>

        {/* Results List */}
        <div
          ref={listRef}
          data-debug-id="command-palette-results"
          className="flex-1 overflow-y-auto p-2"
        >
          {filteredCommands.length === 0 ? (
            <div className="px-3 py-8 text-center text-sm text-muted">
              No matching commands found.
            </div>
          ) : (
            filteredCommands.map((cmd, idx) => {
              const isSelected = idx === selectedIndex;
              const catColor = CATEGORY_COLORS[cmd.category] || 'bg-neutral-soft text-muted';
              return (
                <div
                  key={cmd.id}
                  data-debug-id={`command-palette-item-${cmd.id}`}
                  data-selected={isSelected ? 'true' : 'false'}
                  data-command-index={idx}
                  onClick={() => executeCommand(cmd)}
                  onMouseEnter={() => setSelectedIndex(idx)}
                  className={`flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition-colors ${
                    isSelected
                      ? 'bg-neutral-soft text-primary font-semibold'
                      : 'text-muted hover:bg-neutral-soft hover:text-primary'
                  }`}
                >
                  {/* Category Chip */}
                  <span
                    data-debug-id={`command-category-badge-${cmd.id}`}
                    className={`rounded border px-1.5 py-0.5 text-[10px] font-mono uppercase tracking-wider shrink-0 ${catColor}`}
                  >
                    {cmd.category}
                  </span>

                  {/* Title & Description */}
                  <div className="flex min-w-0 flex-1 flex-col justify-center">
                    <span className="truncate text-primary text-[13.5px] leading-tight">
                      {cmd.title}
                    </span>
                    {cmd.description ? (
                      <span className="truncate text-caption text-faint text-[11px] leading-tight mt-0.5">
                        {cmd.description}
                      </span>
                    ) : null}
                  </div>

                  {/* Shortcut Badge */}
                  {cmd.shortcut ? (
                    <kbd
                      data-debug-id={`command-shortcut-${cmd.id}`}
                      className="ml-auto rounded border border-subtle bg-neutral-soft px-1.5 py-0.5 font-mono text-[11px] text-muted shrink-0"
                    >
                      {cmd.shortcut}
                    </kbd>
                  ) : null}
                </div>
              );
            })
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between border-t border-subtle bg-surface-raised px-4 py-2 text-[11px] text-muted">
          <span>
            {filteredCommands.length} command{filteredCommands.length === 1 ? '' : 's'}
          </span>
          <div className="flex items-center gap-2">
            <span>
              <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↑↓</kbd> navigate
            </span>
            <span>
              <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↵</kbd> run
            </span>
            <span>
              <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">esc</kbd> dismiss
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
