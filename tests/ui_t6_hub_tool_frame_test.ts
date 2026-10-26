import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { harness } from './helpers/toolStreamHarness.ts';
import { parseLiveSnapshot } from '../src/ui/store/toolActivitySlice.ts';

// Minimal heartbeat plan T6 acceptance, UI end: the exact viewer frame the Hub queued
// in http.test_negotiated_bridge_many_beats_and_diagnostics_keep_tool_stream_live
// (after 120 negotiated eight-member heartbeats interleaved with bridge_diagnostics
// snapshots) goes through the production UI stream consumer. Run that Odin test with
// HEIMDALL_T6_UI_FRAME_OUT=<file>, then this test with HEIMDALL_T6_UI_FRAME=<file>.
// It fails rather than skips without the Hub-produced frame. This is synthetic
// handler-level evidence, not a browser reproduction.
test('Hub-delivered live tool frame after many negotiated beats reaches the UI store', async () => {
  const file = process.env.HEIMDALL_T6_UI_FRAME;
  assert.ok(file, 'HEIMDALL_T6_UI_FRAME must name the frame written by the Hub test');
  const frame = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(frame.type, 'state');
  assert.equal(frame.instance_id, 'inst_diag_live');
  const parsed = parseLiveSnapshot(frame.snapshot);
  assert.ok(parsed, 'Hub frame passes the production snapshot parser');

  const h = harness(), view = h.stream.subscribe('diag-owner', [frame.instance_id]);
  await h.flush();
  const socket = h.sockets[0]; socket.open();
  try {
    socket.frame(frame);
    const member = h.member(frame.instance_id);
    assert.deepEqual(member.snapshot, parsed, 'current-session tool state accepted into the store');
    assert.ok(member.snapshot.active.some((call: any) => call.call_id === 'call_live'), 'live call visible');
  } finally { view.release(); }
});
