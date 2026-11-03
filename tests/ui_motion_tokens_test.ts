import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import postcss from 'postcss';
import tailwindcss from 'tailwindcss';
import tailwindConfig from '../tailwind.config.js';

// Motion foundation for the conversation launcher redesign: the emphasized
// easing token, the seven reference keyframes (plus the scrim `fade`), their `animate-*` utilities, and the
// reduced-motion guard that collapses them.

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel: string) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');

const UTILITIES: Record<string, string> = {
  'tok-swap': 'tokSwap var(--duration-slow) var(--ease-emphasized)',
  'menu-in': 'menuIn var(--duration-base) var(--ease-emphasized)',
  pop: 'pop var(--duration-base) var(--ease-emphasized)',
  'fade-slide': 'fadeSlide var(--duration-base) var(--ease-standard)',
  'composer-swap': 'composerSwap var(--duration-slow) var(--ease-emphasized)',
  breathe: 'breathe 1.6s ease-in-out infinite',
  'sheet-in': 'sheetIn var(--duration-slow) var(--ease-emphasized)',
  // Added by the SentenceToken task: exits (the entrance reversed at the close
  // timing, motion spec #6/#18) and the bottom-sheet scrim fade (#17/#18).
  'menu-out': 'menuIn var(--duration-fast) var(--ease-standard) reverse forwards',
  'sheet-out': 'sheetIn var(--duration-base) var(--ease-standard) reverse forwards',
  'fade-in': 'fade var(--duration-base) var(--ease-emphasized)',
  'fade-out': 'fade var(--duration-base) var(--ease-standard) reverse forwards',
};

async function compileUtilities(classes: string[]): Promise<string> {
  const result = await postcss([
    tailwindcss({ ...tailwindConfig, content: [{ raw: `<div class="${classes.join(' ')}"></div>`, extension: 'html' }] }),
  ]).process('@tailwind utilities;', { from: undefined });
  return result.css.replace(/\s+/g, ' ');
}

test('tokens.css defines --ease-emphasized and Tailwind exposes it', async () => {
  assert.match(read('src/ui/tokens.css'), /--ease-emphasized:\s*cubic-bezier\(0\.22, 1, 0\.36, 1\);/);
  const css = await compileUtilities(['ease-emphasized']);
  assert.match(css, /\.ease-emphasized \{ transition-timing-function: var\(--ease-emphasized\) \}/);
});

test('the launcher keyframes match the redesign reference values', () => {
  const keyframes = (tailwindConfig as { theme: { extend: { keyframes: Record<string, unknown> } } }).theme.extend
    .keyframes;
  assert.deepEqual(keyframes, {
    tokSwap: {
      from: { opacity: '0', transform: 'translateY(8px)', filter: 'blur(2px)' },
      to: { opacity: '1', transform: 'none', filter: 'none' },
    },
    menuIn: {
      from: { opacity: '0', transform: 'translateY(-4px) scale(.97)' },
      to: { opacity: '1', transform: 'none' },
    },
    pop: { from: { transform: 'scale(.6)', opacity: '0' }, to: { transform: 'none', opacity: '1' } },
    fadeSlide: { from: { opacity: '0', transform: 'translateX(6px)' }, to: { opacity: '1', transform: 'none' } },
    composerSwap: { from: { opacity: '0', transform: 'translateY(6px)' }, to: { opacity: '1', transform: 'none' } },
    breathe: {
      '0%, 100%': { opacity: '.35', transform: 'scale(.85)' },
      '50%': { opacity: '1', transform: 'none' },
    },
    sheetIn: { from: { transform: 'translateY(100%)' }, to: { transform: 'none' } },
    fade: { from: { opacity: '0' }, to: { opacity: '1' } },
  });
});

test('each animate-* utility compiles with its keyframes, token duration and easing', async () => {
  const css = await compileUtilities(Object.keys(UTILITIES).map((name) => `animate-${name}`));
  for (const [name, value] of Object.entries(UTILITIES)) {
    const keyframe = value.split(' ')[0];
    assert.ok(css.includes(`@keyframes ${keyframe} {`), `missing @keyframes ${keyframe}`);
    assert.ok(css.includes(`.animate-${name} { animation: ${value} }`), `animate-${name} should be "${value}"`);
  }
});

test('reduced motion collapses the launcher animations to 1ms and stops breathe', () => {
  const styles = read('src/ui/styles.css').replace(/\s+/g, ' ');
  const guards = [...styles.matchAll(/@media \(prefers-reduced-motion: reduce\) \{(.*?\}) \}/g)].map((m) => m[1]);
  const guard = guards.find((body) => body.includes('.animate-breathe'));
  assert.ok(guard, 'reduced-motion guard for the launcher utilities is missing');
  const collapse = guard.match(/^(.*?) \{ animation-duration: 1ms !important; \}/);
  assert.ok(collapse, 'entrance utilities should collapse to 1ms');
  const collapsed = collapse[1].split(',').map((s) => s.trim());
  assert.deepEqual(
    collapsed.sort(),
    Object.keys(UTILITIES)
      .filter((name) => name !== 'breathe')
      .map((name) => `.animate-${name}`)
      .sort(),
  );
  assert.match(guard, /\.animate-breathe \{ animation: none !important; \}/);
});
