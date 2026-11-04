> Moved verbatim from the "Socket lifetime across threads" section of the former `AGENTS.md`.

# Socket lifetime across threads

This codebase has produced the same concurrency defect five times: **a socket closed on one
thread while another thread is blocked reading it.** If you are about to copy a stream-teardown
pattern from `src/bridge/local_proxy.odin`, `src/bridge/hub_runtime_client.odin` (the `tunnel_*`
procs) or `src/hub/transport/http/shell_session_handlers.odin`, read this first — the pattern you
are copying protects **memory**, and on its own it will not protect the **fd**.

**A registered stream has two resources with two different owners. Do not conflate them.**

1. **Memory — the independent-key probe.** A stream struct is reachable from a map, and two
   threads can both decide the stream is finished. Whoever removes the map key owns the free;
   the loser finds the key absent and must not dereference the pointer at all. Capture anything
   you still need (ids, handles) as stack locals at entry.

2. **The fd — the reader owns it.** The thread that blocks in `recv` on a socket is its **sole
   closer**, on **every** exit path. Every other thread may only `shutdown(..., .Receive)` /
   `SHUT_RD` to *wake* that reader; it must never `close`.

**Why `close` from the other thread is not an option.** Measured on Linux, in-tree:

- `close()` **cannot** unblock a `recv` that is already parked. The parked `recv` holds the
  `struct file`, so the socket is merely orphaned and the reader sleeps **forever** — one leaked
  thread per teardown, unbounded, each pinning a socket and its buffers. `/proc/<pid>/fd` looks
  clean throughout, which is why this keeps shipping unnoticed.
- If the reader is instead *between* `recv` calls when the close lands, its next `recv` re-resolves
  the fd **number**, which a new connection may already own. It then reads a stranger's bytes and
  forwards them under the dead stream's id. fd-number reuse on the very next dial is confirmed.
- `shutdown(.Receive)` on a **still-open** fd wakes a parked `recv` in tens of microseconds,
  returning `(0, nil)`. Issued *after* a close it does nothing — the fd is already invalid. So
  shutdown must always precede the close, and the close must come from the reader.

**Three rules that follow, each of which has been got wrong here:**

- **Never gate the close on the key race.** `if i_won_the_key_race { close(fd) }` leaks the fd on
  the losing path, because the probe governs memory only. The close belongs outside that branch.
- **Never `close` the same fd from a proc that runs for both directions or both owners.** Each fd
  gets exactly one owning `close`; four closes per fd is a defect this repo actually shipped, and
  each spurious close frees the number for an unrelated live connection.
- **A receive timeout is not end-of-stream.** `core:net` reports a graceful close as `(0, nil)` and
  a timeout as `Would_Block`/`Timeout` (`-1`/`EAGAIN` for raw `posix.recv`), so the common
  `if err != nil || n <= 0 do break` will tear down a live idle connection once per period. Handle
  the timeout wake as "keep going", and use it to re-check whether teardown has happened — via the
  independent key, never by dereferencing the struct.

**Joining is a valid alternative, but only where the closer can afford to block.** Making the
reader joinable and doing shutdown → join → close concentrates ownership in the closer and is what
`shell_session_handlers.odin` does. Do not force it onto a teardown that runs on a WebSocket
reader thread: stalling that thread stalls the whole hub connection behind one local socket. In the
bridge, reader-owns-close is used precisely because the closing thread is the WS reader.
