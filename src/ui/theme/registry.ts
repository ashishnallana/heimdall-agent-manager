/**
 * Declarative Theme Registry — Heimdall Dashboard
 * -----------------------------------------------
 * Defines the canonical theme interface, palette tokens, xterm terminal colors,
 * and registered themes (Default Dark, Catppuccin Mocha, Catppuccin Latte,
 * Tokyo Night, and Tokyo Night Day).
 */

export type ThemeAppearance = 'dark' | 'light';

export interface ThemeTokens {
  canvas: string;
  surface: string;
  surfaceRaised: string;
  surfaceOverlay: string;
  borderSubtle: string;
  borderStrong: string;
  textPrimary: string;
  textMuted: string;
  textFaint: string;
  accent: string;
  accentFg: string;
  success: string;
  warning: string;
  danger: string;
  info: string;
}

export interface ThemeTerminal {
  background: string;
  foreground: string;
  cursor: string;
  cursorAccent: string;
  selectionBackground: string;
  black: string;
  red: string;
  green: string;
  yellow: string;
  blue: string;
  magenta: string;
  cyan: string;
  white: string;
  brightBlack: string;
  brightRed: string;
  brightGreen: string;
  brightYellow: string;
  brightBlue: string;
  brightMagenta: string;
  brightCyan: string;
  brightWhite: string;
}

export interface ThemeDefinition {
  id: string;
  label: string;
  appearance: ThemeAppearance;
  shikiTheme: string;
  tokens: ThemeTokens;
  terminal: ThemeTerminal;
}

export const THEMES: readonly ThemeDefinition[] = [
  {
    id: 'default-dark',
    label: 'Default Dark',
    appearance: 'dark',
    shikiTheme: 'github-dark',
    tokens: {
      canvas: '#090909',
      surface: '#141414',
      surfaceRaised: '#1c1c1c',
      surfaceOverlay: '#0d0f14',
      borderSubtle: '#262626',
      borderStrong: '#3a3a3a',
      textPrimary: '#ffffff',
      textMuted: '#999999',
      textFaint: '#6b6b6b',
      accent: '#d2a965',
      accentFg: '#000000',
      success: '#22c55e',
      warning: '#f59e0b',
      danger: '#ef4444',
      info: '#0099ff',
    },
    terminal: {
      background: '#09090b',
      foreground: '#e4e4e7',
      cursor: '#d2a965',
      cursorAccent: '#09090b',
      selectionBackground: 'rgba(210, 169, 101, 0.3)',
      black: '#18181b',
      red: '#ef4444',
      green: '#22c55e',
      yellow: '#eab308',
      blue: '#3b82f6',
      magenta: '#a855f7',
      cyan: '#06b6d4',
      white: '#f4f4f5',
      brightBlack: '#71717a',
      brightRed: '#f87171',
      brightGreen: '#4ade80',
      brightYellow: '#fde047',
      brightBlue: '#60a5fa',
      brightMagenta: '#c084fc',
      brightCyan: '#22d3ee',
      brightWhite: '#ffffff',
    },
  },
  {
    id: 'catppuccin-mocha',
    label: 'Catppuccin Mocha',
    appearance: 'dark',
    shikiTheme: 'catppuccin-mocha',
    tokens: {
      canvas: '#181825',
      surface: '#1e1e2e',
      surfaceRaised: '#313244',
      surfaceOverlay: '#11111b',
      borderSubtle: '#45475a',
      borderStrong: '#585b70',
      textPrimary: '#cdd6f4',
      textMuted: '#a6adc8',
      textFaint: '#6c7086',
      accent: '#89b4fa',
      accentFg: '#1e1e2e',
      success: '#a6e3a1',
      warning: '#fab387',
      danger: '#f38ba8',
      info: '#74c7ec',
    },
    terminal: {
      background: '#1e1e2e',
      foreground: '#cdd6f4',
      cursor: '#f5e0dc',
      cursorAccent: '#11111b',
      selectionBackground: '#585b70',
      black: '#45475a',
      red: '#f38ba8',
      green: '#a6e3a1',
      yellow: '#f9e2af',
      blue: '#89b4fa',
      magenta: '#f5c2e7',
      cyan: '#94e2d5',
      white: '#bac2de',
      brightBlack: '#585b70',
      brightRed: '#f38ba8',
      brightGreen: '#a6e3a1',
      brightYellow: '#f9e2af',
      brightBlue: '#89b4fa',
      brightMagenta: '#f5c2e7',
      brightCyan: '#94e2d5',
      brightWhite: '#a6adc8',
    },
  },
  {
    id: 'catppuccin-latte',
    label: 'Catppuccin Latte',
    appearance: 'light',
    shikiTheme: 'catppuccin-latte',
    tokens: {
      canvas: '#e6e9ef',
      surface: '#eff1f5',
      surfaceRaised: '#ccd0da',
      surfaceOverlay: '#dce0e8',
      borderSubtle: '#bcc0cc',
      borderStrong: '#acb0be',
      textPrimary: '#4c4f69',
      textMuted: '#6c6f85',
      textFaint: '#9ca0b0',
      accent: '#1e66f5',
      accentFg: '#eff1f5',
      success: '#40a02b',
      warning: '#fe640b',
      danger: '#d20f39',
      info: '#209fb5',
    },
    terminal: {
      background: '#eff1f5',
      foreground: '#4c4f69',
      cursor: '#dc8a78',
      cursorAccent: '#eff1f5',
      selectionBackground: '#acb0be',
      black: '#bcc0cc',
      red: '#d20f39',
      green: '#40a02b',
      yellow: '#df8e1d',
      blue: '#1e66f5',
      magenta: '#ea76cb',
      cyan: '#179299',
      white: '#acb0be',
      brightBlack: '#acb0be',
      brightRed: '#d20f39',
      brightGreen: '#40a02b',
      brightYellow: '#df8e1d',
      brightBlue: '#1e66f5',
      brightMagenta: '#ea76cb',
      brightCyan: '#179299',
      brightWhite: '#bcc0cc',
    },
  },
  {
    id: 'tokyo-night',
    label: 'Tokyo Night',
    appearance: 'dark',
    shikiTheme: 'tokyo-night',
    tokens: {
      canvas: '#16161e',
      surface: '#1a1b26',
      surfaceRaised: '#292e42',
      surfaceOverlay: '#16161e',
      borderSubtle: '#414868',
      borderStrong: '#565f89',
      textPrimary: '#c0caf5',
      textMuted: '#a9b1d6',
      textFaint: '#565f89',
      accent: '#7aa2f7',
      accentFg: '#1a1b26',
      success: '#9ece6a',
      warning: '#ff9e64',
      danger: '#f7768e',
      info: '#7dcfff',
    },
    terminal: {
      background: '#1a1b26',
      foreground: '#c0caf5',
      cursor: '#c0caf5',
      cursorAccent: '#1a1b26',
      selectionBackground: '#33467c',
      black: '#15161e',
      red: '#f7768e',
      green: '#9ece6a',
      yellow: '#e0af68',
      blue: '#7aa2f7',
      magenta: '#bb9af7',
      cyan: '#7dcfff',
      white: '#a9b1d6',
      brightBlack: '#414868',
      brightRed: '#f7768e',
      brightGreen: '#9ece6a',
      brightYellow: '#e0af68',
      brightBlue: '#7aa2f7',
      brightMagenta: '#bb9af7',
      brightCyan: '#7dcfff',
      brightWhite: '#c0caf5',
    },
  },
  {
    id: 'tokyo-night-day',
    label: 'Tokyo Night Day',
    appearance: 'light',
    shikiTheme: 'catppuccin-latte',
    tokens: {
      canvas: '#d5d6db',
      surface: '#e1e2e7',
      surfaceRaised: '#c4c8da',
      surfaceOverlay: '#d5d6db',
      borderSubtle: '#8990b3',
      borderStrong: '#848cb5',
      textPrimary: '#3760bf',
      textMuted: '#6172b0',
      textFaint: '#848cb5',
      accent: '#2e7de9',
      accentFg: '#e1e2e7',
      success: '#587539',
      warning: '#b15c00',
      danger: '#f52a65',
      info: '#007197',
    },
    terminal: {
      background: '#e1e2e7',
      foreground: '#3760bf',
      cursor: '#3760bf',
      cursorAccent: '#e1e2e7',
      selectionBackground: '#b4d0fe',
      black: '#8990b3',
      red: '#f52a65',
      green: '#587539',
      yellow: '#8c6c3e',
      blue: '#2e7de9',
      magenta: '#9854f1',
      cyan: '#007197',
      white: '#6172b0',
      brightBlack: '#848cb5',
      brightRed: '#f52a65',
      brightGreen: '#587539',
      brightYellow: '#8c6c3e',
      brightBlue: '#2e7de9',
      brightMagenta: '#9854f1',
      brightCyan: '#007197',
      brightWhite: '#3760bf',
    },
  },
] as const;

export const DEFAULT_THEME_ID = 'default-dark';

export const THEME_MAP: Record<string, ThemeDefinition> = Object.fromEntries(
  THEMES.map((theme) => [theme.id, theme]),
);

export function getTheme(id?: string | null): ThemeDefinition {
  if (!id) return THEME_MAP[DEFAULT_THEME_ID];
  return THEME_MAP[id] || THEME_MAP[DEFAULT_THEME_ID];
}

export function isThemeId(id: string): boolean {
  return id in THEME_MAP;
}
