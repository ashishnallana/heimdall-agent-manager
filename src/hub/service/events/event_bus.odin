package events

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"
import ws "odin_test:lib/ws"
import jsonx "odin_test:lib/jsonx"

USER_WS_MAX_SLOTS :: 128

// WS close code sent when every slot is taken (RFC 6455 1013 "Try Again Later"). The
// handshake used to answer user_ws_ready and then never deliver an event to the 129th
// socket — a READY-DEAF subscriber that believed it was live. Refusing is the only honest
// answer, and 1013 tells the client the refusal is transient so it backs off and retries.
USER_WS_CLOSE_TRY_AGAIN_LATER :: 1013

// REQ-3 — THE DELIVERY STREAM, AND WHY event_seq IS NOT IT.
//
// event_seq is one counter for the whole hub: every owner's publish advances it, it only
// rides resource_changed, and it resets on restart. A client that treated it as its own
// stream would see a "gap" whenever ANOTHER user's resource changed. So it stays what it
// was (resource_changed event_id/version, and the observable several tests read) and is
// never a gap signal.
//
// The gap signal is per CONNECTION: every frame the bus fans out to a socket — whatever
// its type — carries "stream_epoch" and "stream_seq", spliced in by the bus, with
// stream_seq contiguous from 1 on that socket. user_ws_ready announces the epoch and the
// watermark (stream_seq 0). Only events actually addressed to this socket's owner advance
// it, so another owner's traffic cannot create a false gap. The epoch is unique per
// connection (hub boot time + connection serial), so a reconnect or a hub restart is an
// epoch change, never a seq the client could mistake for continuity. State is two integers
// per slot: bounded by USER_WS_MAX_SLOTS, nothing retained after detach.
//
// CONCURRENCY. Publishers run on request threads, the reaper and the bridge WS loop at
// once. The table is guarded by `mutex`, which is NEVER held across socket I/O. Each slot
// has its own write_mutex: seq assignment and the frame write happen together under it, so
// on one socket the wire order IS the seq order, and a slow socket stalls only writers to
// that socket (each write is bounded by ws.WRITE_DEADLINE). Lock order is
// write_mutexes[i] -> mutex; nothing waits on a write_mutex while holding mutex.
//
// LIFETIME. Each attach bumps the slot's generation and returns a handle carrying it. A
// publisher snapshots (slot, generation) under mutex, drops it, takes the slot's
// write_mutex and re-checks the generation before touching the socket — a slot released
// and reused in between is skipped, never written. Detach is generation-checked too, so a
// reader exiting late cannot release a stranger's slot. The fd belongs to the READER (the
// upgrade handler) per AGENTS.md "Socket lifetime across threads": a publisher that gives
// up on a peer only shutdown(.Receive)s it to wake that reader, which then closes. That is
// safe because the reader cannot close before detach, and detach waits for write_mutex.
User_Event_Bus :: struct {
	poll_mutex: sync.Mutex,
	poll_slots: [64]Poll_Slot,
	mutex: sync.Mutex,
	write_mutexes: [USER_WS_MAX_SLOTS]sync.Mutex,
	owner_user_ids: [USER_WS_MAX_SLOTS]string,
	sockets: [USER_WS_MAX_SLOTS]net.TCP_Socket,
	connected: [USER_WS_MAX_SLOTS]bool,
	// reserved marks a slot claimed by an attach that has not finished its handshake yet,
	// so a concurrent attach cannot take it in the window before connected is set.
	reserved: [USER_WS_MAX_SLOTS]bool,
	generations: [USER_WS_MAX_SLOTS]u64,
	stream_serials: [USER_WS_MAX_SLOTS]u64,
	stream_seqs: [USER_WS_MAX_SLOTS]u64,
	client_count: int,
	// boot_epoch is set once, lazily, on the first registration. connection_serial
	// numbers connections for this boot.
	boot_epoch: i64,
	connection_serial: u64,
	event_seq: int,
	// slot_exhaustions counts attaches refused because every slot was taken (each one
	// is a 1013 close, never a ready-deaf socket).
	slot_exhaustions: int,
	// resyncs_sent counts resync_required frames sent in place of an event the
	// connection could not be given.
	resyncs_sent: int,

	// REQ-SHELL-35 — the failure counters. A write that cannot go out must be
	// ASSERTABLE, not just loggable: an eprintfln is what an OPERATOR sees and is
	// exactly what a test cannot check. These count the ways a fan-out write can end
	// badly, so the AC1 invariant is checkable rather than narrated.
	//
	// oversized_events_dropped counts events refused by the frame writer with the
	// socket left healthy and SUBSCRIBED. It is the counter that must be able to go
	// up WITHOUT sockets_removed going up — that pairing is the whole of AC1. Since
	// REQ-3 the client is not left to find out on its own: a resync_required frame
	// takes the dropped event's stream_seq (counted in resyncs_sent).
	oversized_events_dropped: int,
	// sockets_removed counts slots released because the PEER was finished
	// (.Peer_Gone or .Desynchronised). It never moves for an unencodable frame.
	sockets_removed: int,
	// desynchronised_removals counts the SUBSET of sockets_removed that were dropped
	// because a frame went out only PARTIALLY, and it is separate for a reason:
	// .Peer_Gone is routine (a closed tab increments sockets_removed all day and means
	// nothing), while .Desynchronised means the hub put half a frame on the wire and is
	// a defect worth chasing. Counted together, the alarming case is invisible inside the
	// ordinary one — which is the silent-failure shape REQ-SHELL-16 settled against.
	desynchronised_removals: int,
}

User_WS_Attach_Result :: enum {
	Attached,
	Slots_Full,   // refuse with USER_WS_CLOSE_TRY_AGAIN_LATER
	Ready_Failed, // the peer could not be written; the slot is already released
}

// User_WS_Handle names one registration: the slot AND the generation it was granted.
User_WS_Handle :: struct {
	idx: int,
	generation: u64,
}

// user_ws_attach registers a socket and writes user_ws_ready to it, atomically with
// respect to publishers: the slot's write_mutex is held from before the slot becomes
// visible until ready is on the wire. So the client receives ready first, and every event
// published after registration reaches it with stream_seq >= 1 — there is no window where
// an event is published to the owner but not to this socket.
user_ws_attach :: proc(bus: ^User_Event_Bus, owner_user_id: string, socket: net.TCP_Socket) -> (handle: User_WS_Handle, result: User_WS_Attach_Result) {
	if bus == nil || owner_user_id == "" do return User_WS_Handle{idx = -1}, .Ready_Failed
	idx := _user_ws_reserve(bus, owner_user_id)
	if idx < 0 do return User_WS_Handle{idx = -1}, .Slots_Full
	sync.mutex_lock(&bus.write_mutexes[idx])
	defer sync.mutex_unlock(&bus.write_mutexes[idx])
	sync.mutex_lock(&bus.mutex)
	handle = _user_ws_activate_locked(bus, idx, owner_user_id, socket)
	epoch_buf: [48]byte
	epoch := _stream_epoch(epoch_buf[:], bus.boot_epoch, bus.stream_serials[idx])
	sync.mutex_unlock(&bus.mutex)
	ready_buf: [160]byte
	ready := user_ws_ready_json(ready_buf[:], epoch)
	write := ws.write_server_text(socket, ready, true)
	user_ws_note_write(write, len(ready))
	if write != .Ok {
		sync.mutex_lock(&bus.mutex)
		_user_ws_release_locked(bus, idx)
		sync.mutex_unlock(&bus.mutex)
		return User_WS_Handle{idx = -1}, .Ready_Failed
	}
	return handle, .Attached
}

// user_ws_detach releases a registration made by user_ws_attach. It waits for any write
// in flight on that slot, so once it returns no publisher will touch the socket again and
// the reader may close it. A stale handle (the slot was already released and possibly
// reused) is a no-op.
user_ws_detach :: proc(bus: ^User_Event_Bus, handle: User_WS_Handle) {
	if bus == nil || handle.idx < 0 || handle.idx >= USER_WS_MAX_SLOTS do return
	sync.mutex_lock(&bus.write_mutexes[handle.idx])
	defer sync.mutex_unlock(&bus.write_mutexes[handle.idx])
	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)
	if bus.generations[handle.idx] == handle.generation && (bus.connected[handle.idx] || bus.reserved[handle.idx]) {
		_user_ws_release_locked(bus, handle.idx)
	}
}

// user_ws_add registers a socket WITHOUT the ready handshake and returns its slot, or -1
// when the table is full. Kept for tests that drive the bus over a bare socket pair; the
// /user-ws upgrade uses user_ws_attach.
user_ws_add :: proc(bus: ^User_Event_Bus, owner_user_id: string, socket: net.TCP_Socket) -> int {
	idx := _user_ws_reserve(bus, owner_user_id)
	if idx < 0 do return -1
	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)
	_user_ws_activate_locked(bus, idx, owner_user_id, socket)
	return idx
}

// user_ws_remove releases a slot by index regardless of generation (user_ws_add's pair).
user_ws_remove :: proc(bus: ^User_Event_Bus, idx: int) {
	if bus == nil || idx < 0 || idx >= USER_WS_MAX_SLOTS do return
	sync.mutex_lock(&bus.write_mutexes[idx])
	defer sync.mutex_unlock(&bus.write_mutexes[idx])
	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)
	_user_ws_release_locked(bus, idx)
}

@(private = "file")
_user_ws_reserve :: proc(bus: ^User_Event_Bus, owner_user_id: string) -> int {
	if bus == nil || owner_user_id == "" do return -1
	sync.mutex_lock(&bus.mutex)
	defer sync.mutex_unlock(&bus.mutex)
	for i in 0..<USER_WS_MAX_SLOTS {
		if !bus.connected[i] && !bus.reserved[i] {
			bus.reserved[i] = true
			bus.generations[i] += 1
			return i
		}
	}
	bus.slot_exhaustions += 1
	return -1
}

@(private = "file")
_user_ws_activate_locked :: proc(bus: ^User_Event_Bus, idx: int, owner_user_id: string, socket: net.TCP_Socket) -> User_WS_Handle {
	if bus.boot_epoch == 0 do bus.boot_epoch = time.to_unix_nanoseconds(time.now())
	bus.connection_serial += 1
	bus.reserved[idx] = false
	bus.connected[idx] = true
	bus.owner_user_ids[idx] = owner_user_id
	bus.sockets[idx] = socket
	bus.stream_serials[idx] = bus.connection_serial
	bus.stream_seqs[idx] = 0
	if idx >= bus.client_count do bus.client_count = idx + 1
	return User_WS_Handle{idx = idx, generation = bus.generations[idx]}
}

@(private = "file")
_user_ws_release_locked :: proc(bus: ^User_Event_Bus, idx: int) {
	bus.connected[idx] = false
	bus.reserved[idx] = false
	bus.owner_user_ids[idx] = ""
	bus.sockets[idx] = net.TCP_Socket(0)
	bus.stream_seqs[idx] = 0
}

// _stream_epoch formats a connection's epoch into buf: "<boot ns>-<serial>".
@(private = "file")
_stream_epoch :: proc(buf: []byte, boot_epoch: i64, serial: u64) -> string {
	return fmt.bprintf(buf, "%d-%d", boot_epoch, serial)
}

// user_ws_ready_json is the handshake frame. protocol_version 2 adds stream_epoch and the
// delivery watermark; a version-1 client ignores both.
user_ws_ready_json :: proc(buf: []byte, epoch: string) -> string {
	return fmt.bprintf(buf, `{{"type":"user_ws_ready","protocol_version":2,"stream_epoch":"%s","stream_seq":0}}`, epoch)
}

// user_ws_close_frame_payload builds a close frame payload: a 2-byte big-endian code and
// a short UTF-8 reason. buf must hold 2 + len(reason) bytes.
user_ws_close_frame_payload :: proc(buf: []byte, code: u16, reason: string) -> string {
	buf[0] = byte(code >> 8)
	buf[1] = byte(code & 0xff)
	n := copy(buf[2:], reason)
	return string(buf[:2 + n])
}

// user_ws_refuse_full writes the 1013 close frame for a socket that could not be given a
// slot. Called by the upgrade handler instead of ready; the handler then returns and the
// reader-side close happens as usual.
user_ws_refuse_full :: proc(socket: net.TCP_Socket) -> bool {
	buf: [32]byte
	payload := user_ws_close_frame_payload(buf[:], USER_WS_CLOSE_TRY_AGAIN_LATER, "user ws slots full")
	return ws.write_server_opcode(socket, 0x8, payload, true) == .Ok
}

publish_resource_changed :: proc(bus: ^User_Event_Bus, owner_user_id, resource, resource_id, change, summary_json: string) {
	if bus == nil || owner_user_id == "" do return
	chain_id:=resource_id
	if resource!="task_chain" {chain_id=jsonx.extract_string(summary_json,"chain_id");defer delete(chain_id)}
	poll_hint(bus, owner_user_id,chain_id)
	seq := sync.atomic_add(&bus.event_seq, 1) + 1
	event := resource_changed_json(seq, resource, resource_id, change, summary_json)
	publish_owned(bus, owner_user_id, event)
}

// publish_owned fans an event string out to the user's connections and then frees
// it. Fan-out is synchronous (publish_raw_to_user writes every connected socket
// inline), so the string can be released as soon as it returns. Use this for any
// freshly-built event JSON whose ownership is being handed to the bus. On the
// per-request arena delete is a no-op (the arena reclaims it); on the persistent
// heap (the reaper and the bridge WS runtime loop) it actually frees, closing the
// per-fan-out event-string leak.
publish_owned :: proc(bus: ^User_Event_Bus, owner_user_id, event_json: string) {
	defer delete(event_json)
	publish_raw_to_user(bus, owner_user_id, event_json)
}

// publish_raw_to_user delivers one event to every connection of owner_user_id, each copy
// stamped with that connection's stream_epoch/stream_seq. event_json must be a JSON
// object; anything else cannot carry the stamp and is replaced by resync_required.
publish_raw_to_user :: proc(bus: ^User_Event_Bus, owner_user_id, event_json: string) {
	if bus == nil || owner_user_id == "" || event_json == "" do return
	targets: [USER_WS_MAX_SLOTS]User_WS_Handle
	n_targets := 0
	sync.mutex_lock(&bus.mutex)
	for i in 0..<bus.client_count {
		if bus.connected[i] && bus.owner_user_ids[i] == owner_user_id {
			targets[n_targets] = User_WS_Handle{idx = i, generation = bus.generations[i]}
			n_targets += 1
		}
	}
	sync.mutex_unlock(&bus.mutex)
	for target in targets[:n_targets] {
		_deliver_to_slot(bus, target, event_json)
	}
}

// Best-effort worker hint, with a budget for the ENTIRE fan-out. A busy socket
// is skipped before taking a sequence number; no job data enters this stream.
// The request broker's deadline remains authoritative if every hint is skipped.
publish_mcp_worker_hint :: proc(bus:^User_Event_Bus,owner:string) {
	if bus==nil do return
	started:=time.tick_now()
	targets:[USER_WS_MAX_SLOTS]User_WS_Handle
	count:=0
	sync.mutex_lock(&bus.mutex)
	for i in 0..<bus.client_count do if bus.connected[i] && bus.owner_user_ids[i]==owner {targets[count]={i,bus.generations[i]};count+=1}
	sync.mutex_unlock(&bus.mutex)
	for target in targets[:count] {
		if time.tick_since(started)>=100*time.Millisecond do return
		i:=target.idx
		if !sync.mutex_try_lock(&bus.write_mutexes[i]) do continue
		sync.mutex_lock(&bus.mutex)
		if !bus.connected[i] || bus.generations[i]!=target.generation {sync.mutex_unlock(&bus.mutex);sync.mutex_unlock(&bus.write_mutexes[i]);continue}
		socket:=bus.sockets[i]
		seq:=bus.stream_seqs[i]+1
		epoch_buf:[48]byte
		epoch:=_stream_epoch(epoch_buf[:],bus.boot_epoch,bus.stream_serials[i])
		sync.mutex_unlock(&bus.mutex)
		frame,_:=stamp_stream_event(epoch,seq,`{"type":"mcp_worker_available"}`)
		remaining:=100*time.Millisecond-time.tick_since(started)
		result:ws.Text_Write_Result
		if remaining>0 {_,result=ws.write_server_opcode_counted(socket,0x1,frame,true,min(remaining,10*time.Millisecond))} else {result=.Peer_Gone}
		delete(frame)
		sync.mutex_lock(&bus.mutex)
		if result==.Ok {bus.stream_seqs[i]=seq} else if result==.Desynchronised {
			_user_ws_release_locked(bus,i)
		}
		sync.mutex_unlock(&bus.mutex)
		// The reader owns close. Hold write_mutex until shutdown completes.
		if result==.Desynchronised do _ = net.shutdown(net.Any_Socket(socket),.Receive)
		sync.mutex_unlock(&bus.write_mutexes[i])
	}
}

@(private = "file")
_deliver_to_slot :: proc(bus: ^User_Event_Bus, target: User_WS_Handle, event_json: string) {
	i := target.idx
	sync.mutex_lock(&bus.write_mutexes[i])
	defer sync.mutex_unlock(&bus.write_mutexes[i])

	sync.mutex_lock(&bus.mutex)
	if !bus.connected[i] || bus.generations[i] != target.generation {
		sync.mutex_unlock(&bus.mutex)
		return
	}
	socket := bus.sockets[i]
	bus.stream_seqs[i] += 1
	seq := bus.stream_seqs[i]
	epoch_buf: [48]byte
	epoch := _stream_epoch(epoch_buf[:], bus.boot_epoch, bus.stream_serials[i])
	sync.mutex_unlock(&bus.mutex)

	result: ws.Text_Write_Result
	frame_len := 0
	frame, stampable := stamp_stream_event(epoch, seq, event_json)
	if stampable {
		frame_len = len(frame)
		result = ws.write_server_text(socket, frame, true)
		delete(frame)
		user_ws_note_write(result, frame_len)
		// Reported unconditionally: whether the slot goes is a SEPARATE question from
		// whether the outcome is worth a line, and _log_publish_write owns the latter.
		_log_publish_write(result, frame_len)
	} else {
		// Not a JSON object, or too large once stamped: either way it cannot go out
		// stamped, so it is handled exactly like an unencodable frame.
		result = .Too_Large
		if len(event_json) <= ws.WS_MAX_SERVER_PAYLOAD {
			fmt.eprintfln("ham-hub WARN user ws event is not a JSON object bytes=%d (client KEPT subscribed, sent resync_required)", len(event_json))
		} else {
			_log_publish_write(result, len(event_json))
		}
		user_ws_note_write(result, len(event_json))
	}
	if result == .Too_Large {
		sync.atomic_add(&bus.oversized_events_dropped, 1)
		// The dropped event's seq goes to a bounded resync_required frame instead, so the
		// stream stays contiguous AND the client learns now, not at the next event.
		resync_buf: [192]byte
		resync := resync_required_json(resync_buf[:], epoch, seq, "event_too_large")
		result = ws.write_server_text(socket, resync, true)
		user_ws_note_write(result, len(resync))
		if result == .Ok do sync.atomic_add(&bus.resyncs_sent, 1)
	}
	if result == .Desynchronised do sync.atomic_add(&bus.desynchronised_removals, 1)
	if _publish_write_removes_socket(result) {
		sync.atomic_add(&bus.sockets_removed, 1)
		sync.mutex_lock(&bus.mutex)
		_user_ws_release_locked(bus, i)
		sync.mutex_unlock(&bus.mutex)
		// Wake the reader so it closes promptly instead of sitting out its idle timeout;
		// still under write_mutex, so the fd cannot have been closed yet.
		_ = net.shutdown(net.Any_Socket(socket), .Receive)
	}
}

// stamp_stream_event returns event_json with stream_epoch/stream_seq inserted as its
// first members. ok=false when event_json is not a JSON object or the stamped frame could
// not be sent anyway (over ws.WS_MAX_SERVER_PAYLOAD) — the size check comes first, so an
// oversized event is never copied. Caller owns the result.
stamp_stream_event :: proc(epoch: string, seq: u64, event_json: string) -> (frame: string, ok: bool) {
	body := strings.trim_left_space(event_json)
	if len(body) < 2 || body[0] != '{' do return "", false
	rest := strings.trim_left_space(body[1:])
	prefix_buf: [96]byte
	prefix := fmt.bprintf(prefix_buf[:], `{{"stream_epoch":"%s","stream_seq":%d`, epoch, seq)
	sep := ","
	if strings.has_prefix(rest, "}") do sep = ""
	if len(prefix) + len(sep) + len(rest) > ws.WS_MAX_SERVER_PAYLOAD do return "", false
	return strings.concatenate({prefix, sep, rest}), true
}

// resync_required_json is the bounded stand-in for an event a connection could not be
// given. The client answers it with one scoped resync.
resync_required_json :: proc(buf: []byte, epoch: string, seq: u64, reason: string) -> string {
	return fmt.bprintf(buf, `{{"stream_epoch":"%s","stream_seq":%d,"type":"resync_required","reason":"%s"}}`, epoch, seq, reason)
}

// _publish_write_removes_socket answers the only question the fan-out loop asks: is
// this CONNECTION finished? REQ-SHELL-35.
//
// The bug this replaces was a single `if !write_ws_text_frame(...)`. A bool cannot
// distinguish "the hub could not encode this frame" from "the peer is gone", and the
// fan-out loop read every falsey return as the latter — so one oversized event did not
// drop one event, it called user_ws_remove and PERMANENTLY unsubscribed a live, healthy
// browser from EVERY FUTURE EVENT. That client then had no way to find out: REQ-SHELL-6
// §6 deleted the UI's pollers, so it does not error, does not reconnect and does not show
// a disconnected state — it silently stops repainting and is indistinguishable from an
// idle app. The hub believes it has no such subscriber while the browser believes it is
// subscribed, which is precisely the convergence violation this chain exists to prevent.
//
// .Too_Large therefore KEEPS the slot: not one byte of that frame was written, so it says
// nothing whatever about the socket. .Desynchronised DOES remove it — half a frame is
// already on the wire and that client will misparse every byte after it, so ending a
// corrupt stream is the recovery, not the failure. That case is worse than an oversized
// drop and the old code could not even see it: `_, err := net.send_tcp(...)` discarded the
// written count, so a partial write reported plain success-or-failure.
//
// This mirrors _viewer_write_ends_session in the shell session service, deliberately: a
// client must not have to learn two different rules for when the hub gives up on it.
_publish_write_removes_socket :: proc(result: ws.Text_Write_Result) -> bool {
	switch result {
	case .Ok, .Too_Large:
		return false
	case .Peer_Gone, .Desynchronised:
		return true
	}
	return true
}

// _log_publish_write reports the two outcomes that would otherwise leave no trace, which
// are NOT the same failure and do not have the same remedy. REQ-SHELL-16 settled the
// principle — a refusal must never be silent.
//
//   .Too_Large      the connection stays up and the client stays subscribed, so an event
//                   simply never arrives and nothing anywhere else would ever mention it.
//   .Desynchronised the client IS dropped, but dropping it is the recovery; the fact worth
//                   reporting is that the hub put half a frame on the wire.
//
// .Peer_Gone is deliberately silent: a browser closing a tab is ordinary, and logging it
// would bury the two lines above in noise.
//
// The counters live at the CALL SITE rather than in here, so that the outcomes of a fan-out
// write are incremented in one place and this proc does only what its name says.
_log_publish_write :: proc(result: ws.Text_Write_Result, size: int) {
	switch result {
	case .Too_Large:
		fmt.eprintfln(
			"ham-hub WARN user ws event too large to encode bytes=%d limit=%d (client KEPT subscribed, event DROPPED)",
			size,
			ws.WS_MAX_SERVER_PAYLOAD,
		)
	case .Desynchronised:
		// The one removal worth a line. A .Peer_Gone removal is ordinary and would drown
		// this out; a partial write means the stream is corrupt, so say so and say that
		// dropping the client is the RECOVERY rather than the symptom.
		fmt.eprintfln(
			"ham-hub WARN user ws event PARTIALLY written bytes=%d (stream desynchronised, client DROPPED to end it)",
			size,
		)
	case .Ok, .Peer_Gone:
		// Nothing to report: success, and a peer that has simply gone away.
	}
}

// HOW BIG CAN AN EVENT ACTUALLY GET, AND WHY THAT QUESTION HAS TO STAY ANSWERED HERE.
//
// REQ-SHELL-35 asked it, because the old 65535-byte cliff was fatal and the answer decides
// whether it was an everyday occurrence or a rare one. Every publisher into this bus was
// enumerated and read; the result, so nobody has to redo it:
//
// >>> CORRECTION. An earlier version of THIS COMMENT, and the commit message of 19a6acf0,
// claimed the agent->user chat event was bounded at a 140-rune preview and that the only
// unbounded field was display_name, with "the largest thing enumerated is ~5 KB". THAT WAS
// FALSE, in the direction that matters: it made an everyday trigger look exotic. It is
// corrected here rather than quietly deleted, because the wrong version was written into
// source as documentation intended to stop anyone re-deriving it. Caught by reviewer #26 on
// the REQ-SHELL-35 review. <<<
//
//   PRIMARY UNBOUNDED FIELD — THE AGENT CHAT BODY. This is the everyday path.
//     agent_action_handlers.odin:82  builds the event with chat_event_preview(m.body, 140)
//     agent_action_handlers.odin:99  if domain.contains_vault_token(trimmed) do return collapsed
//   That early return hands back the WHOLE collapsed body; the rune clip below it is never
//   reached. And bodies arrive armored by default — ctl_agentmode_chat_send_params
//   (src/ctl/agent_mode.odin:1307-1317) encrypts every non-armored body whenever a vault key
//   is configured, producing exactly that `vault:v2:` prefix. So the bound is ~4/3 of the
//   plaintext (base64) with NO cap: roughly 49 KB of plaintext crossed the old 65535 cliff,
//   and multi-KB agent messages are routine.
//
//   AND THE GUARD IS `strings.contains`, NOT `has_prefix` — which is the more alarming half.
//   A body that merely MENTIONS the literal `vault:v2:` anywhere takes the uncapped branch
//   with no encryption involved at all. Discussing the armor prefix in a message is enough.
//   (The same pattern appears at taskchain_service.odin:1322 and :1361 and at
//   taskchain_repo_sqlite.odin:220 — those are the notice/persistence paths, not this bus.)
//
//   SECONDARY: agent_instance_summary_json embeds display_name verbatim, client-supplied and
//   stored with NO LENGTH CAP, riding created and every status_changed for that instance.
//   Real, but second to the chat body and filed separately as REQ-SHELL-51.
//
//   BOUNDED, and bounded for a REASON rather than by luck:
//     - task / chain / shell_session / bridge events carry IDS and a status, never a
//       description or a body — a multi-KB chain description never enters an event;
//     - the activity-bubble summary is rune-clipped at the call site;
//     - messages_read carries an id array whose producer caps the list at 200 rows.
//
// So the size of an event is DATA-DRIVEN and bounded only by how each summary happens to
// be written today. That is why the fix is not "cap the summaries": a 65535 bound spread
// across ~30 call sites is a trap, and the one that matters is that crossing it must cost
// a repaint rather than the client's entire event feed. The verdict on the task title is
// therefore EVERYDAY-REACHABLE, not theoretical: the defect this file fixes was being hit
// by ordinary traffic.
//
// WHERE AC2 LANDS — DELIVERY, not a survivable drop. With the 64-bit arm every event up to
// ws.WS_MAX_SERVER_PAYLOAD (16 MiB) is really sent. The chat-body path above is the one that
// makes that arm load-bearing rather than theoretical. Above 16 MiB an event IS still dropped, with the
// socket kept, counted and logged, and that residual is deliberate: the frame is built in
// one contiguous allocation, so removing the bound would make a remote-supplied string an
// unbounded hub-side allocation. Chunking is not the answer either — the UI refetches
// authoritative state from the id in the event, and since REQ-3 the dropped event's
// stream_seq is given to a resync_required frame so the client resyncs instead of going stale.
resource_changed_json :: proc(seq: int, resource, resource_id, change, summary_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"resource_changed\",\"event_id\":\"evt_")
	strings.write_string(&b, fmt.tprintf("%d", seq))
	strings.write_string(&b, "\",\"resource\":\""); write_json_string(&b, resource)
	strings.write_string(&b, "\",\"resource_id\":\""); write_json_string(&b, resource_id)
	strings.write_string(&b, "\",\"change\":\""); write_json_string(&b, change)
	strings.write_string(&b, "\",\"version\":"); strings.write_string(&b, fmt.tprintf("%d", seq))
	if summary_json != "" { strings.write_string(&b, ",\"summary\":"); strings.write_string(&b, summary_json) }
	strings.write_string(&b, ",\"occurred_at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// write_ws_text_frame writes one text frame to a user (BROWSER) socket. REQ-SHELL-35
// removed the framing that used to live here; ws.write_server_text owns it now, and what
// stays is the CHOICE of arm plus the collapse to a bool.
//
// allow_64bit IS TRUE HERE, AND THAT IS A PROPERTY OF THIS REGISTRY, NOT A DEFAULT. Every
// socket on this bus arrives through user_ws_attach, whose only caller is the /user WebSocket
// upgrade (user_ws_add is the test-only variant) — so every peer is a browser, and a browser parses a 127 length correctly. The
// bridge command channel takes the OPPOSITE answer for the same reason reversed: our own
// readers treat a 127 length as fatal, so emitting one toward a bridge would turn a dropped
// frame into a killed connection. See the note on ws.write_server_text.
//
// This wrapper exists for callers that send a FIXED-SHAPE control frame, for which
// Too_Large would mean a bug in this repository rather than a large event, and which can do
// nothing different about the reason. (user_ws_attach writes user_ws_ready itself, under
// the slot's write_mutex, so ready is ordered before every event.) The fan-out path
// does NOT use it: publish_raw_to_user needs the typed result, because acting on the
// difference is the fix.
write_ws_text_frame :: proc(socket: net.TCP_Socket, text: string) -> bool {
	return ws.write_server_text(socket, text, true) == .Ok
}

write_json_string :: proc(b: ^strings.Builder, value: string) {
	contracts.write_json_string(b, value)
}

// user_ws_note_write feeds heimdall_ws_bytes_total{user,tx,""} and
// heimdall_ws_write_errors_total{user,reason} (plan 3.4). Nil-safe when the
// metric families were never initialised.
user_ws_note_write :: proc(result: ws.Text_Write_Result, payload_len: int) {
	m := &project_service.fleet_metrics
	if result == .Ok {
		metrics.counter_add(metrics.with(m.ws_bytes, project_service.WS_KIND_USER, "tx", ""), u64(payload_len))
		return
	}
	reason := "other"
	switch result {
	case .Too_Large:      reason = "too_large"
	case .Peer_Gone:      reason = "peer_gone"
	case .Desynchronised: reason = "desync"
	case .Ok:
	}
	metrics.counter_inc(metrics.with(m.ws_write_errors, project_service.WS_KIND_USER, reason))
}
