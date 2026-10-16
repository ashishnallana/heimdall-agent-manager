// Viewer-socket client for scripts/pty-stream-smoke.sh. Speaks BOTH wire generations so
// the same script measures a baseline (JSON text frames) and the binary protocol:
//   - binary frame  : u8 kind | u8 flags | [cursor] | payload   (REQ-PTY-NET-2)
//   - text frame    : JSON control, or the legacy {type:output,data_b64} output frame
// Input is sent as a binary INPUT frame when SMOKE_LEGACY is unset, else as the legacy
// JSON {type:input,data_b64} frame.
//
// Prints frame/byte counts per phase: attach repaint, an interactive echo, and a bulk
// `seq` burst (the coalescing case).
import WebSocket from 'ws';

const url = process.env.SMOKE_WS_URL;
const legacy = process.env.SMOKE_LEGACY === '1';
if (!url) { console.error('SMOKE_WS_URL required'); process.exit(2); }

const ws = new WebSocket(url, { perMessageDeflate: false });
ws.binaryType = 'arraybuffer';

const stats = { frames: 0, wireBytes: 0, payloadBytes: 0, snapshotFrames: 0, textControl: 0, phases: {} };
let phase = 'attach';
let text = '';
const phaseStats = () => (stats.phases[phase] ??= { frames: 0, wireBytes: 0, payloadBytes: 0, snapshotFrames: 0 });

function noteOutput(wire, payload, snapshot) {
  stats.frames += 1; stats.wireBytes += wire; stats.payloadBytes += payload; if (snapshot) stats.snapshotFrames += 1;
  const p = phaseStats(); p.frames += 1; p.wireBytes += wire; p.payloadBytes += payload; if (snapshot) p.snapshotFrames += 1;
}

ws.on('message', (data, isBinary) => {
  if (isBinary || data instanceof ArrayBuffer) {
    const bytes = new Uint8Array(data);
    const kind = bytes[0], flags = bytes[1];
    let off = 2; if (flags & 0x04) off += 4;
    const payload = bytes.subarray(off);
    noteOutput(bytes.length, payload.length, (flags & 0x01) !== 0);
    text += Buffer.from(payload).toString('utf8');
    return;
  }
  const s = data.toString();
  let msg; try { msg = JSON.parse(s); } catch { return; }
  if (msg.type === 'output' || msg.type === 'screen') {
    const payload = Buffer.from(msg.data_b64 ?? '', 'base64');
    noteOutput(s.length, payload.length, msg.type === 'screen' || msg.is_snapshot === true);
    text += payload.toString('utf8');
    return;
  }
  stats.textControl += 1;
  if (msg.type === 'stream_ready') ready = true;
});

let ready = false;
let reconnecting = false;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const sendInput = (str) => {
  if (legacy) { ws.send(JSON.stringify({ type: 'input', data_b64: Buffer.from(str).toString('base64'), is_encrypted: false })); return; }
  const payload = Buffer.from(str, 'utf8');
  const frame = Buffer.alloc(2 + payload.length); frame[0] = 0x02; frame[1] = 0x00; payload.copy(frame, 2);
  ws.send(frame);
};
const waitFor = async (needle, ms) => { const t0 = Date.now(); while (!text.includes(needle) && Date.now() - t0 < ms) await sleep(20); return text.includes(needle); };
const bytesSentBefore = () => ws._socket?.bytesWritten ?? 0;

ws.on('open', async () => {
  const t0 = Date.now();
  ws.send(JSON.stringify({ type: 'resize', rows: 24, cols: 100 }));
  for (let i = 0; i < 150 && !ready; i++) await sleep(20);
  await sleep(1500); // let attach repaint(s) land
  const attachMs = Date.now() - t0;
  console.log(`[client] attach: ready=${ready} after ${attachMs} ms, repaint frames=${phaseStats().snapshotFrames} total frames=${phaseStats().frames} wire=${phaseStats().wireBytes}B payload=${phaseStats().payloadBytes}B`);

  phase = 'echo';
  const marker = 'SMOKE_ECHO_OK';
  const w0 = bytesSentBefore(); const e0 = Date.now();
  for (const ch of `echo ${marker}\n`) sendInput(ch); // one keystroke per frame, like typing
  const echoed = await waitFor(marker, 5000);
  await sleep(300);
  console.log(`[client] echo: ok=${echoed} rtt<=${Date.now() - e0} ms, output frames=${phaseStats().frames} wire=${phaseStats().wireBytes}B payload=${phaseStats().payloadBytes}B, input bytes sent (ws level)=${bytesSentBefore() - w0}`);

  phase = 'colour';
  // REQ-PTY-COLOR-1: set the background live, then force a repaint via a second viewer
  // is out of scope for one socket; instead ask the hub for the capture path indirectly:
  // the shell prints the OSC, we read it back from a fresh connection below.
  sendInput('printf "\\033]11;rgb:1e/1e/2e\\007"; echo SMOKE_COLOR_SET\n');
  await waitFor('SMOKE_COLOR_SET', 5000);
  await sleep(200);

  phase = 'bulk';
  const b0 = Date.now();
  sendInput('seq 1 20000; echo SMOKE_BULK_DONE\n');
  const done = await waitFor('SMOKE_BULK_DONE', 20000);
  await sleep(300);
  const p = phaseStats();
  console.log(`[client] bulk: ok=${done} ${Date.now() - b0} ms, output frames=${p.frames} wire=${p.wireBytes}B payload=${p.payloadBytes}B avg payload/frame=${(p.payloadBytes / Math.max(p.frames, 1)).toFixed(0)}B overhead=${((p.wireBytes / Math.max(p.payloadBytes, 1) - 1) * 100).toFixed(1)}%`);
  console.log(`[client] total: frames=${stats.frames} wire=${stats.wireBytes}B payload=${stats.payloadBytes}B control_text_frames=${stats.textControl}`);
  console.log(`[client] RESULT ${JSON.stringify({ legacy, attachMs, phases: stats.phases, total: { frames: stats.frames, wire: stats.wireBytes, payload: stats.payloadBytes } })}`);
  ws.close();
  // Reconnect: the repaint for the new viewer must carry the OSC 11 preamble.
  if (!legacy) {
    reconnecting = true;
    const ws2 = new WebSocket(url, { perMessageDeflate: false });
    ws2.binaryType = 'arraybuffer';
    let repaint = '';
    ws2.on('message', (data, isBinary) => {
      if (!isBinary && !(data instanceof ArrayBuffer)) return;
      const bytes = new Uint8Array(data);
      let off = 2; if (bytes[1] & 0x04) off += 4;
      if (bytes[1] & 0x01) repaint += Buffer.from(bytes.subarray(off)).toString('utf8');
    });
    ws2.on('open', async () => {
      ws2.send(JSON.stringify({ type: 'resize', rows: 24, cols: 100 }));
      await sleep(2500);
      const has = repaint.includes('\x1b]11;rgb:1e/1e/2e\x07');
      const first = repaint.indexOf('\x1b]11;');
      console.log(`[client] reconnect repaint carries OSC 11 preamble=${has} at offset ${first} (bytes=${repaint.length}) head=${JSON.stringify(repaint.slice(0, 60))}`);
      ws2.close();
    });
    ws2.on('close', () => process.exit(0));
    return;
  }
});
ws.on('error', (e) => { console.error('[client] ws error', e.message); process.exit(1); });
ws.on('close', () => { if (!reconnecting) process.exit(0); });
