// Task System v2 — shared facet fixture conformance (plan §4b).
//
// The JSON files under tests/fixtures/facets/ are the single source of truth for
// the facet body shapes in the M2 wire contract (handoff / vcs / verify / output).
// The Odin side #loads the SAME files and makes the SAME assertions; keep the
// file names and required keys in lock-step with that test.
//
// RUN: node --test tests/facets_fixtures_conformance.test.mjs
// (plain node, no npm deps, no transform hook needed)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const FIXTURES_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'facets');

function loadFixture(name) {
  const text = readFileSync(path.join(FIXTURES_DIR, name), 'utf8');
  const parsed = JSON.parse(text);
  assert.ok(parsed && typeof parsed === 'object' && !Array.isArray(parsed), `${name}: top level must be a JSON object`);
  return { text, parsed };
}

const isString = (v) => typeof v === 'string';
const isNumber = (v) => typeof v === 'number' && Number.isFinite(v);
const isBool = (v) => typeof v === 'boolean';

test('handoff.json: summary string (next_steps string when present)', () => {
  const { parsed } = loadFixture('handoff.json');
  assert.ok(isString(parsed.summary) && parsed.summary.length > 0, 'summary must be a non-empty string');
  assert.ok(parsed.summary.length <= 4000, 'summary must be ≤ 4000 chars');
  if ('next_steps' in parsed) {
    assert.ok(isString(parsed.next_steps), 'next_steps must be a string');
    assert.ok(parsed.next_steps.length <= 4000, 'next_steps must be ≤ 4000 chars');
  }
  if ('truncated' in parsed) assert.ok(isBool(parsed.truncated), 'truncated must be a boolean');
});

test('vcs.json: head string, dirty boolean, files array of {path,status,add,del}', () => {
  const { parsed } = loadFixture('vcs.json');
  assert.ok(isString(parsed.head), 'head must be a string');
  assert.ok(isBool(parsed.dirty), 'dirty must be a boolean');
  assert.ok(Array.isArray(parsed.files), 'files must be an array');
  for (const [i, f] of parsed.files.entries()) {
    assert.ok(f && typeof f === 'object', `files[${i}] must be an object`);
    assert.ok(isString(f.path), `files[${i}].path must be a string`);
    assert.ok(isString(f.status), `files[${i}].status must be a string`);
    assert.ok(isNumber(f.add), `files[${i}].add must be a number`);
    assert.ok(isNumber(f.del), `files[${i}].del must be a number`);
  }
  if ('kind' in parsed) assert.equal(parsed.kind, 'git');
  for (const opt of ['directory_id', 'bridge_id', 'branch', 'base']) {
    if (opt in parsed) assert.ok(isString(parsed[opt]), `${opt} must be a string when present`);
  }
});

test('verify.json: exit_code/duration_ms numbers, log_ref/heads/summary strings, dirty bool|null', () => {
  const { parsed } = loadFixture('verify.json');
  assert.ok(isNumber(parsed.exit_code), 'exit_code must be a number');
  assert.ok(isNumber(parsed.duration_ms), 'duration_ms must be a number');
  assert.ok(isString(parsed.log_ref), 'log_ref must be a string');
  assert.ok(isString(parsed.head_at_start), 'head_at_start must be a string');
  assert.ok(isString(parsed.head_at_end), 'head_at_end must be a string');
  assert.ok(parsed.dirty === null || isBool(parsed.dirty), 'dirty must be boolean or null');
  assert.ok(isString(parsed.summary), 'summary must be a string');
  assert.ok(isString(parsed.status), 'status must be a string');
});

test('output.json: an object (the brief output contract, stored verbatim)', () => {
  const { parsed } = loadFixture('output.json');
  assert.equal(typeof parsed, 'object');
  assert.ok(Object.keys(parsed).length > 0, 'output contract should not be empty');
});

test('unknown_fields.json: a handoff whose unknown nested members survive a round trip', () => {
  const { parsed } = loadFixture('unknown_fields.json');
  // Still a valid handoff.
  assert.ok(isString(parsed.summary) && parsed.summary.length > 0);
  // Carries unknown members, including nested arrays/objects/null.
  assert.ok('x_vendor' in parsed, 'fixture must carry an unknown member');
  assert.deepEqual(parsed.x_vendor.a, [1, 2, { b: null }]);

  const roundTripped = JSON.parse(JSON.stringify(parsed));
  assert.deepEqual(roundTripped, parsed, 'parse→stringify→parse must preserve every member');
  assert.deepEqual(roundTripped.x_vendor, parsed.x_vendor);
  assert.deepEqual(Object.keys(roundTripped).sort(), Object.keys(parsed).sort());
  // The unknown members must not be dropped by anything that treats the body as
  // a known shape: picking only the known keys would lose them.
  const knownOnly = { summary: parsed.summary, next_steps: parsed.next_steps };
  assert.notDeepEqual(knownOnly, parsed);
});

test('every fixture file listed in the contract exists and parses', () => {
  for (const name of ['handoff.json', 'vcs.json', 'verify.json', 'output.json', 'unknown_fields.json']) {
    assert.doesNotThrow(() => loadFixture(name), `${name} must exist and parse`);
  }
});
