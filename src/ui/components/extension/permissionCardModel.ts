// Permission prompt input summary (REQ-EXT-PERM-1, UI): what a blocked tool
// call wants to do, in one line plus an optional diff, and the countdown
// helpers. Pure logic, no React and no fetch. The card's live state comes from
// the in-memory agent blockers API (blockersModel.ts, REQ-EXT-BLK-1..5).

function str(value: unknown): string {
  return typeof value === 'string' ? value : value == null ? '' : String(value);
}

// ---------------------------------------------------------------------------
// Input summary: what the agent wants to do, in one line plus an optional diff.

export interface PermissionDiff {
  filePath: string;
  original: string;
  modified: string;
  /** True for Write (whole-file content, original unknown). */
  wholeFile: boolean;
}

export interface PermissionInputSummary {
  /** 'command' | 'file' | 'url' | 'pattern' | 'other' — decides the icon/mono styling. */
  kind: 'command' | 'file' | 'url' | 'pattern' | 'other';
  text: string;
  /** Extra one-liner (e.g. the Bash description), '' when none. */
  detail: string;
  diff: PermissionDiff | null;
}

const MAX_SUMMARY = 400;

function clip(text: string, max = MAX_SUMMARY): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

export function summarizePermissionInput(toolName: string, input: Record<string, any>): PermissionInputSummary {
  const tool = String(toolName || '');
  const inp = input || {};
  const filePath = str(inp.file_path || inp.notebook_path);
  if (typeof inp.command === 'string' && inp.command) {
    return { kind: 'command', text: clip(inp.command), detail: str(inp.description), diff: null };
  }
  if (filePath) {
    let diff: PermissionDiff | null = null;
    if (typeof inp.old_string === 'string' || typeof inp.new_string === 'string') {
      diff = { filePath, original: str(inp.old_string), modified: str(inp.new_string), wholeFile: false };
    } else if (Array.isArray(inp.edits) && inp.edits.length) {
      diff = {
        filePath,
        original: inp.edits.map((e: any) => str(e?.old_string)).join('\n…\n'),
        modified: inp.edits.map((e: any) => str(e?.new_string)).join('\n…\n'),
        wholeFile: false,
      };
    } else if (typeof inp.content === 'string') {
      diff = { filePath, original: '', modified: inp.content, wholeFile: true };
    } else if (typeof inp.new_source === 'string') {
      diff = { filePath, original: '', modified: inp.new_source, wholeFile: true };
    }
    return { kind: 'file', text: filePath, detail: '', diff };
  }
  if (typeof inp.url === 'string' && inp.url) {
    return { kind: 'url', text: clip(inp.url), detail: str(inp.prompt) ? clip(str(inp.prompt), 160) : '', diff: null };
  }
  if (typeof inp.pattern === 'string' && inp.pattern) {
    return { kind: 'pattern', text: clip(inp.pattern), detail: str(inp.path), diff: null };
  }
  const keys = Object.keys(inp);
  if (keys.length === 0) return { kind: 'other', text: tool ? `${tool} (no input)` : 'No input', detail: '', diff: null };
  let text = '';
  try {
    text = JSON.stringify(inp);
  } catch {
    text = keys.join(', ');
  }
  return { kind: 'other', text: clip(text), detail: '', diff: null };
}

// ---------------------------------------------------------------------------
// Time helpers.

export function parseTimeMs(value: string): number {
  if (!value) return NaN;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : NaN;
}

export function formatCountdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')}`;
}
