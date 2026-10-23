import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { harness } from './helpers/toolStreamHarness.ts';
import { parseLiveSnapshot, validInstanceId } from '../src/ui/store/toolActivitySlice.ts';

// S3 supplies real captured backend frames. This consumer deliberately fails if
// evidence is missing/malformed/incomplete; S2's synthetic module/DOM tests do
// not claim a live-stack run. See docs/ephemeral-tool-activity.md.
test('captured isolated summary stream frames pass through the actual UI stream consumer', async () => {
  const dir = process.env.LIVE_TOOLS_EVIDENCE;
  assert.ok(dir, 'LIVE_TOOLS_EVIDENCE must name the actual isolated S3 capture');
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.kind, 'tool-stream-ui-evidence');
  assert.equal(manifest.schema_version, 1);
  assert.equal(manifest.status, 'pass');
  assert.equal(manifest.capture_source, 'isolated-backend-websocket');
  assert.equal(manifest.endpoint, '/api/v1/tool-activity/stream');
  assert.match(manifest.backend_head, /^[a-f0-9]{40}$/);
  assert.match(manifest.ui_head, /^[a-f0-9]{40}$/);
  const frames = manifest.ui_frames;
  assert.ok(Array.isArray(frames) && frames.length >= 5 && frames.length <= 4096);
  const ids = [...new Set<string>(frames.map((frame: any) => frame.instance_id))];
  assert.ok(ids.length >= 1 && ids.length <= 256 && ids.every(validInstanceId));
  const states = frames.filter((frame: any) => frame.type === 'state');
  assert.ok(states.some((frame: any) => frame.baseline && frame.snapshot.active.length > 0), 'active baseline captured');
  assert.ok(states.some((frame: any) => !frame.baseline && frame.snapshot.completed_since_last.length >= 2), 'transient completion batch captured');
  assert.ok(states.some((frame: any) => frame.refresh === true), 'actual fresh-state refresh captured');
  assert.ok(states.some((frame: any) => frame.snapshot.active.length === 0 && frame.snapshot.completed_since_last.length === 0), 'empty snapshot captured');
  assert.ok(frames.some((frame: any) => frame.type === 'unavailable'), 'unavailable captured');

  const h = harness(), view = h.stream.subscribe('captured-owner', ids);
  await h.flush();
  const socket = h.sockets[0]; socket.open();
  try {
    for (const frame of frames) {
      assert.ok(['state', 'unavailable'].includes(frame.type), 'ui_frames contains only dedicated display frames');
      if (frame.type === 'state') {
        const parsed = parseLiveSnapshot(frame.snapshot);
        assert.ok(parsed, 'captured state passes production parser');
        assert.equal(frame.instance_id, parsed.instance_id);
        assert.equal(typeof frame.baseline, 'boolean'); assert.equal(typeof frame.refresh, 'boolean');
        socket.frame(frame);
        assert.deepEqual(h.member(frame.instance_id).snapshot, parsed, 'captured current state accepted');
      } else {
        assert.equal(typeof frame.reason, 'string');
        socket.frame(frame);
        assert.equal(h.member(frame.instance_id).snapshot, null);
        assert.equal(h.member(frame.instance_id).availability, 'unavailable');
      }
    }
  } finally { view.release(); }
});
