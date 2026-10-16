# PTY streaming: binary wire format and network optimizations (as implemented)

Status: **implemented** on `feat/pty-stream-opt` (hub↔bridge protocol 2). Supersedes
[pane-streaming-network-and-compression-plan.md](pane-streaming-network-and-compression-plan.md),
which is kept as the pre-change audit; its compression phase was dropped by decision
(see §7).

## 1. What changed, in one table

| # | Change | Where | Effect |
|---|---|---|---|
| P1 | Coalescing in the bridge drain | `src/bridge/pty_host_stream_worker.odin` | adjacent same-session records merged up to the per-frame cap, encrypted once per merged frame; byte-budgeted drain (256 KiB/turn), 1 ms loop cadence while backlog remains; no flush timer |
| P2 | Binary WS frames on both hops | `src/contracts/pty_wire.odin`, hub `bridge_handlers.odin`/`pane_viewer_writer.odin`/`shell_stream_screen_snapshot.odin`, UI `ptyWire.ts` | JSON+base64 output envelope removed (−25 % bulk, −~100 B/frame); one streaming `TextDecoder` per connection |
| P3 | Ack-less, binary, coalesced input | hub `bridge_runtime.odin` (`send_runtime_binary`), bridge `bridge_hub_handle_binary_frame`, UI `ptyInputCoalescer.ts` | per keystroke: 3 frames end-to-end instead of 5, no `command_result`; `onData` chunks folded per macrotask |
| P4 | Single repaint on attach | hub `shell_snapshot_cache.odin`, `shell_stream_serve_screen_snapshot` | viewer #1 no longer gets the catch-up **and** a `shell_get_pane` capture; late joiners served from the hub cache without a bridge round-trip |
| P5 | Visibility gating + queue compaction | UI `paneVisibilityGate.ts`; bridge overflow path | hidden tab >10 s closes the viewer socket (bridge stream detaches when last viewer); per-session overflow keeps the newest 64 KiB behind a clear-screen instead of a resync storm |
| P7 | Client write path | UI `PaneWriteBatcher`, replay gate in both panes | one `term.write` per animation frame; xterm auto-replies during a repaint are not sent back as input |

## 2. Wire format (`BRIDGE_WS_FRAME_VERSION = 2`)

Authoritative definitions: `src/contracts/pty_wire.odin` (Odin) and
`src/ui/components/shells/ptyWire.ts` (browser). The `bridge_hello.protocol_version`
**is** this constant; a mismatching bridge is refused at hello with
`unsupported bridge protocol_version`.

### 2.1 bridge-ws (bridge ↔ hub), WebSocket opcode `0x2`

```
u8 kind | u8 flags | u16be session_id_len | session_id | payload
```

| kind | value | direction | payload |
|---|---|---|---|
| OUTPUT | 1 | bridge → hub | raw pty bytes, or `nonce(12) \| tag(16) \| AES-256-GCM ct` when `ENCRYPTED` |
| INPUT  | 2 | hub → bridge | same layout (browser-encrypted when the vault is unlocked) |

flags: `0x01 SNAPSHOT` (catch-up / absolute repaint), `0x02 ENCRYPTED`.

Sizing: binary frames **never** pass through the `kind:"chunk"` text re-splitter.
The bridge sizes output frames from the transport (`bridge_pty_stream_emit_caps`):
12 KiB under socat (edge-proxy safe — see `BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES`),
4 KiB under the legacy s_client (6000 B cap). `bridge_hub_send_binary` refuses, with a
log line, anything larger. Input frames are ≤ 8 KiB + header.

### 2.2 viewer-ws (hub ↔ browser), WebSocket opcode `0x2`

```
u8 kind | u8 flags | [u16be cursor_row | u16be cursor_col]* | payload
```

| kind | value | direction |
|---|---|---|
| OUTPUT | 1 | hub → browser (bridge output, relayed byte-for-byte) |
| INPUT  | 2 | browser → hub |
| SCREEN | 3 | hub → browser (hub pane capture; `SNAPSHOT` always set) |

flags: `0x01 SNAPSHOT`, `0x02 ENCRYPTED`, `0x04 CURSOR` (*cursor block present; set on
SCREEN frames so an encrypted capture the hub cannot read can still be positioned by
the browser after decrypting).

### 2.3 What stays JSON text

Control only: `ready`, `stream_ready`, `stream_closed`, `status`, `error`
(incl. `vault_locked`), `resize`, `heartbeat` on the viewer socket; `shell_stream_attach`
/`shell_stream_detach`/`shell_pty_resize` (acked, command_id) and the REST-fallback
`shell_pty_input` on the bridge-ws. The `shell_pty_input` envelope lost its duplicated
`agent_instance_id`; the bridge keys on `shell_id` for both panes.

### 2.4 Browser decoding rules

`ws.binaryType = 'arraybuffer'`; one `TextDecoder('utf-8', {stream:true})` per connection
(`PtyTextDecoder`), reset when a snapshot/screen **sequence begins** (a frame with
`SNAPSHOT` following a frame without); OUTPUT+SNAPSHOT text is normalised to an absolute
repaint (`normalizeSnapshotText`); an encrypted SCREEN is positioned with the cursor block
(`repaintCapturedScreenText`). Output is handed to the pane as **text**; writes are
batched per animation frame, a repaint always leading its own write.

## 3. Attach repaint policy (REQ-PTY-NET-4, keeps REQ-SHELL-61)

On a viewer's first `resize` the hub consults the per-session cache:

1. the socket was painted by the catch-up broadcast → nothing more;
2. a cached repaint is < 2 s old or at the requested geometry → replayed to that socket
   only, no bridge round-trip;
3. otherwise, if this viewer caused the 0→1 attach, wait ≤ 2 s (20 ms polls) for the
   in-flight catch-up; then, as a last resort, one `shell_get_pane` capture, cached.

A catch-up under 16 bytes does not count as a screen. The cache is evicted when the
session's last viewer leaves, on `stream_closed`, and at teardown; ≤ 1 MiB per session.

## 4. Bridge queue

- Plaintext records (`data`) and control JSON (`json`) share one queue; `(salt, seq)` is
  reserved at enqueue so a merged frame reuses the first record's nonce and skipped
  values are never reused.
- Merge boundaries: session, snapshot flag, encrypted flag, salt, any control frame.
- Overflow: per-session incremental → compact to the newest 64 KiB behind `\x1b[2J\x1b[H`;
  3 compactions within 10 s, snapshot overflow or global overflow → `pane_resync_required`
  for that stream (old behaviour).

## 4b. Terminal colours across repaints (REQ-PTY-COLOR-1)

`tools/pty_host/src/vt.rs` tracks OSC 10/11/12 (default fg/bg/cursor) and OSC 4 (palette),
their resets (110/111/112/104) and RIS; `capture()` emits them as a BEL-terminated OSC
preamble in `Capture.preamble` AND at the head of `lines[0]` (wire shape unchanged), before
the alt-screen prefix. The bridge catch-up payload and the hub SCREEN repaint both split it
off (`contracts.pty_screen_split_preamble`) and re-emit it FIRST — ahead of the alt prefix
and the erase+home — so trimming/sanitising never touches it (`shell_output_sanitize` only
serves `shell log`). The browser writes `PTY_COLOR_RESET`
(`OSC 110/111/112/104`) at the start of every repaint, then the capture; a capture with a
preamble re-applies the bridge machine's colours, one without returns to the UI theme.
Queries (`OSC 11;?`) are never answered by the emulator.

## 5. Metrics

- `heimdall_shell_output_frames_total{bridge_id}` (new) and
  `heimdall_shell_output_bytes_total{bridge_id}` (now **payload** bytes) on arrival;
- `heimdall_bridge_ws_frames_total{dir,kind}` counts binary frames as
  `shell_pty_output` / `shell_pty_input`;
- fan-out / `ws_bytes` count the binary viewer frame.

The win is `output_bytes / output_frames` (bytes per frame) and frames/s for a given
workload; `scripts/pty-stream-smoke.sh` measures both ends on an isolated stack.

## 6. Verification

`odin test` per package (bridge per file/filter when the full suite trips a
process-group kill), `npm run typecheck`, `npm test`, `npm run build`,
`scripts/test-pane-transport.sh` (real hub fan-out → Node client → xterm),
`scripts/pty-stream-smoke.sh` (hub + bridge + pty-host end to end).

## 7. Dropped by decision

`permessage-deflate` on hub→browser (plan item 6 / the old plan's "Phase 2:
compress-before-encrypt"). The zero-code alternative is nginx `permessage-deflate` in
front of the hub for the plaintext (vault-disabled) case; encrypted payloads do not
compress anywhere downstream of the bridge by construction.
