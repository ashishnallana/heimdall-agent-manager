// MD-1: markdown renderer regressions (apostrophes, code-span isolation, URLs,
// emphasis flanking, lists, headings, escapes). Executes the real renderer.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown } from '../src/ui/components/markdownRender.ts';

const md = (src: string) => renderMarkdown(src, false);
const ACCENT_QUOTE = 'text-accent font-medium';

test('typographic apostrophes are not treated as a quotation (reported bug)', () => {
  const html = md('I received your approval to begin. I’m checking the approved task and chain state now, then I’ll move it.');
  assert.doesNotMatch(html, new RegExp(ACCENT_QUOTE));
  assert.match(html, /I’m checking the approved task and chain state now, then I’ll move it\./);
});

test('real curly and straight quotations are still highlighted', () => {
  assert.match(md('Use the ‘Deploy’ button.'), /‘<span class="text-accent font-medium">Deploy<\/span>’/);
  assert.match(md("Click 'Save' now."), /‘<span class="text-accent font-medium">Save<\/span>’/);
  // Possessives and contractions around a quote stay plain.
  assert.doesNotMatch(md("the workers’ files and the drivers’ cars"), new RegExp(ACCENT_QUOTE));
  assert.doesNotMatch(md("don't stop, it's fine"), new RegExp(ACCENT_QUOTE));
});

test('inline code is literal: no emphasis, quotes, links or newline expansion inside it', () => {
  const html = md("Call `fn(**kwargs)` and `a_b_c_` and `'x'` and `https://x.com/_a_` here.");
  assert.match(html, /<code[^>]*>fn\(\*\*kwargs\)<\/code>/);
  assert.match(html, /<code[^>]*>a_b_c_<\/code>/);
  assert.match(html, /<code[^>]*>&#39;x&#39;<\/code>/);
  assert.match(html, /<code[^>]*>https:\/\/x\.com\/_a_<\/code>/);
  assert.doesNotMatch(html, /<em>|<strong>|<a /);
});

test('URLs are not mangled by emphasis markers', () => {
  const html = md('See https://example.com/a_b_/c*d*e for details.');
  assert.match(html, /<a href="https:\/\/example\.com\/a_b_\/c\*d\*e"/);
  assert.doesNotMatch(html, /<em>/);
  const link = md('[docs](https://example.com/__init__/x)');
  assert.match(link, /<a href="https:\/\/example\.com\/__init__\/x"[^>]*>docs<\/a>/);
});

test('autolinked URL does not swallow a closing paren or trailing punctuation', () => {
  const html = md('(see https://example.com/path) and https://example.com/end.');
  assert.match(html, /<a href="https:\/\/example\.com\/path"[^>]*>https:\/\/example\.com\/path<\/a>\)/);
  assert.match(html, /<a href="https:\/\/example\.com\/end"[^>]*>https:\/\/example\.com\/end<\/a>\./);
  assert.match(md('https://en.wikipedia.org/wiki/Foo_(bar)'), /href="https:\/\/en\.wikipedia\.org\/wiki\/Foo_\(bar\)"/);
});

test('emphasis needs non-space flanking; arithmetic stays literal', () => {
  assert.doesNotMatch(md('2 * 3 * 4 = 24'), /<em>/);
  assert.doesNotMatch(md('a ** b ** c'), /<strong>/);
  assert.match(md('this is *important* and **bold**'), /<em>important<\/em> and <strong>bold<\/strong>/);
  assert.match(md('_under_ and __strong__'), /<em>under<\/em> and <strong>strong<\/strong>/);
  assert.doesNotMatch(md('snake_case_name stays'), /<em>/);
});

test('backslash escapes render the literal character', () => {
  const html = md('\\*not italic\\* and \\_x\\_ and \\`tick\\`');
  assert.doesNotMatch(html, /<em>|<code/);
  assert.match(html, /\*not italic\* and _x_ and `tick`/);
});

test('literal \\n inside code is preserved when the message has real newlines', () => {
  const html = md('Use this:\n```c\nprintf("a\\n");\n```\nand `"\\n"` inline.');
  assert.match(html, /printf\(&quot;a\\n&quot;\);/);
  assert.match(html, /<code[^>]*>&quot;\\n&quot;<\/code>/);
  // A single-line message that only uses literal \n escapes is still expanded.
  assert.match(md('line one\\nline two'), /line one<br \/>line two/);
});

test('ordered lists keep their start number and survive blank lines between items', () => {
  assert.match(md('3. three\n4. four'), /<ol start="3"/);
  const loose = md('1. one\n\n2. two\n\n3. three');
  assert.equal((loose.match(/<ol/g) || []).length, 1);
  assert.equal((loose.match(/<li>/g) || []).length, 3);
  assert.match(md('1) paren style'), /<ol[^>]*><li>paren style<\/li><\/ol>/);
});

test('nested and continued list items stay inside the list', () => {
  const html = md('- parent\n  - child one\n  - child two\n- sibling\n  continued text');
  assert.equal((html.match(/<ul/g) || []).length, 2);
  assert.match(html, /<li>parent<ul[^>]*><li>child one<\/li><li>child two<\/li><\/ul><\/li>/);
  assert.match(html, /<li>sibling continued text<\/li>/);
  assert.doesNotMatch(html, /<p/);
});

test('headings keep a trailing # that is part of the text', () => {
  assert.match(md('# Fix C#'), />Fix C#<\/h1>/);
  assert.match(md('## Title ##'), />Title<\/h2>/);
});

test('fences accept info strings and tilde fences; blockquote accepts ">" without space', () => {
  assert.match(md('```ts title="a.ts"\nconst a = 1;\n```'), /data-lang="ts"/);
  assert.match(md('~~~\nraw *text*\n~~~'), /<code>raw \*text\*<\/code>/);
  assert.match(md('>quoted line\n>\n> next'), /<blockquote[^>]*>quoted line/);
});

test('HTML in source is escaped', () => {
  const html = md('<script>alert(1)</script> **x**');
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
});
