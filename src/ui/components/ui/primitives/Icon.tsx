/**
 * Icon — the one named monochrome glyph.
 * ------------------------------------------------------------------
 * Purpose: the single, sanctioned icon mechanism (spec:
 * `docs/ui-audit/04-component-catalogue.md` › Icon). Every glyph is referenced by
 * a stable `name`; there are no emoji and no text glyphs in the UI. Icons are
 * monochrome (`currentColor`) on a `0 0 24 24` viewBox, so they inherit text
 * color and pair with the `Text` type roles.
 *
 * NOT for: an icon-only action (wrap this in `IconButton`, which adds the button
 * semantics + hit target), or decorative emoji/illustration.
 *
 * Layer: primitive. This is the canonical home under `@ui`; the old
 * `components/Icon.tsx` is now a thin re-export shim so in-flight call sites keep
 * working while imports migrate to `@ui`.
 *
 * We deliberately hand-roll inline SVGs instead of pulling `lucide-react` — the
 * version pinned in this repo (1.21.0) ships a broken package (its `module` entry
 * points at a missing .mjs, so Vite fails to resolve it). Keeping icons local
 * means zero external dependency and no build breakage.
 *
 * Size: prefer the token scale `sm|md|lg|xl` (14/16/20/24 — the `--icon-*`
 * tokens). A raw `number` is still accepted for backward-compat with existing
 * call sites; those are a migration long-tail to snap to the nearest token.
 *
 * Accessibility (built in): decorative by default (`aria-hidden`). Pass `title`
 * to give the glyph an accessible name — it then renders `role="img"` + a
 * `<title>`. `focusable="false"` keeps it out of the tab order in every browser.
 */
import React, { type CSSProperties, type ReactElement } from 'react';

export type IconName =
  | 'plus'
  | 'bell'
  | 'gear'
  | 'chat'
  | 'home'
  | 'grid'
  | 'tasks'
  | 'chevron-left'
  | 'chevron-right'
  | 'chevron-down'
  | 'chevron-up'
  | 'arrow-up'
  | 'arrow-down'
  | 'arrow-right'
  | 'arrow-left'
  | 'close'
  | 'stop'
  | 'play'
  | 'search'
  | 'device'
  | 'menu'
  | 'refresh'
  | 'pencil'
  | 'folder'
  | 'folder-open'
  | 'file'
  | 'copy'
  | 'download'
  | 'clock'
  | 'calendar'
  | 'trash'
  | 'zap'
  | 'check'
  | 'alert'
  | 'info'
  | 'more'
  | 'more-horizontal'
  | 'more-vertical'
  | 'panel-right'
  | 'panel-left'
  | 'terminal'
  | 'lock'
  | 'lock-open'
  | 'spark'
  | 'sparkle'
  | 'command'
  | 'rocket'
  | 'eye'
  | 'eye-off'
  | 'maximize'
  | 'minimize'
  | 'bot'
  | 'save'
  | 'git-branch'
  | 'layers'
  | 'pin'
  | 'star'
  | 'star-filled'
  | 'filter';

/** Token size scale → px (the `--icon-*` sizes: 14 / 16 / 20 / 24). */
export type IconSize = 'sm' | 'md' | 'lg' | 'xl';

const SIZE_PX: Record<IconSize, number> = { sm: 14, md: 16, lg: 20, xl: 24 };

const PATHS: Record<IconName, ReactElement> = {
  star: <path d="m12 3 2.78 5.63L21 9.54l-4.5 4.39 1.06 6.2L12 17.2l-5.56 2.93 1.06-6.2L3 9.54l6.22-.91L12 3Z" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />,
  'star-filled': <path d="m12 3 2.78 5.63L21 9.54l-4.5 4.39 1.06 6.2L12 17.2l-5.56 2.93 1.06-6.2L3 9.54l6.22-.91L12 3Z" fill="currentColor" stroke="currentColor" strokeWidth={1.4} strokeLinecap="round" strokeLinejoin="round" />,
  plus: <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" />,
  pencil: <path d="M12 20h9M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />,
  gear: (
    // Eight-toothed cog outline with a centre hole (the old circle + spokes read as a sun).
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinejoin="round">
      <path d="M9.84 5.03 10.38 2.54h3.24l.54 2.49 1.25.51 2.13-1.38 2.3 2.3-1.38 2.13.51 1.25 2.49.54v3.24l-2.49.54-.51 1.25 1.38 2.13-2.3 2.3-2.13-1.38-1.25.51-.54 2.49h-3.24l-.54-2.49-1.25-.51-2.13 1.38-2.3-2.3 1.38-2.13-.51-1.25-2.49-.54v-3.24l2.49-.54.51-1.25-1.38-2.13 2.3-2.3 2.13 1.38z" />
      <circle cx={12} cy={12} r={3} />
    </g>
  ),
  chat: <path d="M4 5.5h16v11H9l-4 3.5v-3.5H4z" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinejoin="round" />,
  home: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 11.5 12 4l8 7.5" />
      <path d="M6 10.5V20h12v-9.5" />
      <path d="M10 20v-5h4v5" />
    </g>
  ),
  grid: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={4} y={4} width={6.5} height={6.5} rx={1.2} />
      <rect x={13.5} y={4} width={6.5} height={6.5} rx={1.2} />
      <rect x={4} y={13.5} width={6.5} height={6.5} rx={1.2} />
      <rect x={13.5} y={13.5} width={6.5} height={6.5} rx={1.2} />
    </g>
  ),
  tasks: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 6.5l1.6 1.6L8.5 5" />
      <path d="M4 15.5l1.6 1.6L8.5 14" />
      <path d="M11.5 7h8.5M11.5 16h8.5" />
    </g>
  ),
  'chevron-left': <path d="M14.5 6l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'chevron-right': <path d="M9.5 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'chevron-down': <path d="M6 9.5l6 6 6-6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'chevron-up': <path d="M6 14.5l6-6 6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'arrow-up': <path d="M12 19V5M6 11l6-6 6 6" fill="none" stroke="currentColor" strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round" />,
  'arrow-down': <path d="M12 5v14M6 13l6 6 6-6" fill="none" stroke="currentColor" strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round" />,
  'arrow-right': <path d="M5 12h14M13 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'arrow-left': <path d="M19 12H5M11 6l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  close: <path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" />,
  stop: <rect x={6.5} y={6.5} width={11} height={11} rx={2} fill="currentColor" />,
  play: <path d="M8 5.5v13l11-6.5z" fill="currentColor" />,
  search: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinecap="round">
      <circle cx={10.5} cy={10.5} r={6} />
      <path d="M15 15l4.5 4.5" />
    </g>
  ),
  device: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={4} y={5} width={16} height={11} rx={1.6} />
      <path d="M9 20h6M12 16v4" strokeLinecap="round" />
    </g>
  ),
  menu: <path d="M4 7h16M4 12h16M4 17h16" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" />,
  refresh: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 11a8 8 0 0 0-14.5-4.5L3 9" />
      <path d="M3 4v5h5" />
      <path d="M4 13a8 8 0 0 0 14.5 4.5L21 15" />
      <path d="M21 20v-5h-5" />
    </g>
  ),
  folder: <path d="M3 7a1 1 0 0 1 1-1h5l2 2h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinejoin="round" />,
  'folder-open': (
    <g fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinejoin="round">
      <path d="M3 7a1 1 0 0 1 1-1h5l2 2h8a1 1 0 0 1 1 1v2" />
      <path d="M3 11h18l-2 9H4l-2-8a1 1 0 0 1 1-1z" />
    </g>
  ),
  file: (
    <g fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round">
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
      <path d="M14 3v5h5" />
    </g>
  ),
  // Copy-to-clipboard. Same line weight and 24-box as the rest of the set — the
  // redesign puts a copy affordance on several cards, and an ad-hoc glyph at one
  // call site is how a set stops being a set.
  copy: (
    <g fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round">
      <rect x="9" y="9" width="11" height="11" rx="2" />
      <path d="M5 15V6a2 2 0 0 1 2-2h8" />
    </g>
  ),
  download: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3v12M7 10l5 5 5-5" />
      <path d="M4 19h16" />
    </g>
  ),
  bell: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
      <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
    </g>
  ),
  clock: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <circle cx={12} cy={12} r={9} />
      <path d="M12 7v5l3 3" />
    </g>
  ),
  calendar: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <rect x={3} y={4} width={18} height={18} rx={2} />
      <path d="M16 2v4M8 2v4M3 10h18" />
    </g>
  ),
  trash: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      <path d="M10 11v6M14 11v6" />
    </g>
  ),
  zap: <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />,
  check: <path d="M20 6L9 17l-5-5" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round" />,
  alert: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinecap="round" strokeLinejoin="round">
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
      <path d="M12 9v4M12 17h.01" />
    </g>
  ),
  info: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <circle cx={12} cy={12} r={9} />
      <path d="M12 11v5M12 8h.01" />
    </g>
  ),
  more: (
    <g fill="currentColor">
      <circle cx={5} cy={12} r={1.8} />
      <circle cx={12} cy={12} r={1.8} />
      <circle cx={19} cy={12} r={1.8} />
    </g>
  ),
  'more-horizontal': (
    <g fill="currentColor">
      <circle cx={5} cy={12} r={1.8} />
      <circle cx={12} cy={12} r={1.8} />
      <circle cx={19} cy={12} r={1.8} />
    </g>
  ),
  'more-vertical': (
    <g fill="currentColor">
      <circle cx={12} cy={5} r={1.8} />
      <circle cx={12} cy={12} r={1.8} />
      <circle cx={12} cy={19} r={1.8} />
    </g>
  ),
  'panel-right': (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={3.5} y={4.5} width={17} height={15} rx={2.2} />
      <path d="M14.5 4.5v15" strokeLinecap="round" />
    </g>
  ),
  'panel-left': (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={3.5} y={4.5} width={17} height={15} rx={2.2} />
      <path d="M9.5 4.5v15" strokeLinecap="round" />
    </g>
  ),
  terminal: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <rect x={3} y={4.5} width={18} height={15} rx={2} />
      <path d="M7 9.5l3 2.5-3 2.5M12.5 15h4" />
    </g>
  ),
  lock: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9}>
      <rect x={5} y={10.5} width={14} height={9} rx={2} />
      <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" strokeLinecap="round" />
    </g>
  ),
  'lock-open': (
    <g fill="none" stroke="currentColor" strokeWidth={1.9}>
      <rect x={5} y={10.5} width={14} height={9} rx={2} />
      <path d="M16 10.5V8a4 4 0 0 0-7.5-2" strokeLinecap="round" />
    </g>
  ),
  spark: <path d="M12 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2z" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinejoin="round" />,
  // Celebration / success flourish (replaces the celebration emoji strategy).
  sparkle: (
    <g fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinejoin="round">
      <path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3z" />
      <path d="M18.5 15l.6 1.9 1.9.6-1.9.6-.6 1.9-.6-1.9-1.9-.6 1.9-.6z" />
    </g>
  ),
  // ⌘ command key (replaces the raw ⌘ glyph in the command palette).
  command: (
    <path
      d="M18 3a3 3 0 0 0-3 3v12a3 3 0 0 0 3 3 3 3 0 0 0 3-3 3 3 0 0 0-3-3H6a3 3 0 0 0-3 3 3 3 0 0 0 3 3 3 3 0 0 0 3-3V6a3 3 0 0 0-3-3 3 3 0 0 0-3 3 3 3 0 0 0 3 3h12a3 3 0 0 0 3-3 3 3 0 0 0-3-3z"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  ),
  // Agents get their own glyph: they used to share 'tasks' with Task Chains, which
  // made the two sidebar/palette entries indistinguishable.
  bot: (
    <g fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round">
      <rect x={4} y={8} width={16} height={11} rx={3} />
      <path d="M12 5V8M8.5 4.5h7" />
      <circle cx={9.5} cy={13} r={1.1} fill="currentColor" stroke="none" />
      <circle cx={14.5} cy={13} r={1.1} fill="currentColor" stroke="none" />
    </g>
  ),
  rocket: (
    <g fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 15c-1 1-1.5 4-1.5 4s3-.5 4-1.5M14 4c3 0 6 3 6 6-2 5-7 8-9 9l-6-6c1-2 4-7 9-9z" />
      <circle cx={14.5} cy={9.5} r={1.5} />
    </g>
  ),
  eye: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
      <circle cx={12} cy={12} r={3} />
    </g>
  ),
  'eye-off': (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24" />
      <line x1={1} y1={1} x2={23} y2={23} />
    </g>
  ),
  maximize: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3" />
    </g>
  ),
  minimize: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M8 3v3a2 2 0 0 1-2 2H3m18 0h-3a2 2 0 0 1-2-2V3m0 18v-3a2 2 0 0 1 2-2h3M3 16h3a2 2 0 0 1 2 2v3" />
    </g>
  ),
  save: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z" />
      <polyline points="17 21 17 13 7 13 7 21" />
      <polyline points="7 3 7 8 15 8" />
    </g>
  ),
  layers: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <polygon points="12 2 2 7 12 12 22 7 12 2" />
      <polyline points="2 17 12 22 22 17" />
      <polyline points="2 12 12 17 22 12" />
    </g>
  ),
  // Source-control glyph (two branch nodes joined to a trunk) for the VCS tab.
  'git-branch': (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <line x1="6" y1="3" x2="6" y2="15" />
      <circle cx="18" cy="6" r="3" />
      <circle cx="6" cy="18" r="3" />
      <path d="M18 9a9 9 0 0 1-9 9" />
    </g>
  ),
  pin: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <line x1="12" y1="17" x2="12" y2="22" />
      <path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z" />
    </g>
  ),
  filter: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3" />
    </g>
  ),
};

export interface IconProps {
  /** Stable glyph name. Never an emoji or text glyph. */
  name: IconName;
  /** Token size `sm|md|lg|xl` (14/16/20/24). A raw number is accepted for legacy call sites. Default `md`. */
  size?: IconSize | number;
  className?: string;
  style?: CSSProperties;
  /** Accessible name. When set, renders `role="img"` + `<title>`; otherwise the icon is `aria-hidden`. */
  title?: string;
}

export function Icon({ name, size = 'md', className = '', style, title }: IconProps) {
  const px = typeof size === 'number' ? size : SIZE_PX[size];
  return (
    <svg
      viewBox="0 0 24 24"
      width={px}
      height={px}
      className={className}
      style={{ display: 'inline-block', verticalAlign: '-0.13em', flex: 'none', ...style }}
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
    >
      {title ? <title>{title}</title> : null}
      {PATHS[name]}
    </svg>
  );
}

export default Icon;
