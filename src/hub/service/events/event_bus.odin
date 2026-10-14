package events

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"
import ws "odin_test:lib/ws"

User_Event_Bus :: struct {
	owner_user_ids: [128]string,
	sockets: [128]net.TCP_Socket,
	connected: [128]bool,
	client_count: int,
	event_seq: int,

	// REQ-SHELL-35 — the failure counters. A write that cannot go out must be
	// ASSERTABLE, not just loggable: an eprintfln is what an OPERATOR sees and is
	// exactly what a test cannot check. These count the ways a fan-out write can end
	// badly, so the AC1 invariant is checkable rather than narrated.
	//
	// oversized_events_dropped counts events refused by the frame writer with the
	// socket left healthy and SUBSCRIBED. It is the counter that must be able to go
	// up WITHOUT sockets_removed going up — that pairing is the whole of AC1.
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

user_ws_add :: proc(bus: ^User_Event_Bus, owner_user_id: string, socket: net.TCP_Socket) -> int {
	if bus == nil || owner_user_id == "" do return -1
	for i in 0..<len(bus.connected) {
		if !bus.connected[i] {
			bus.connected[i] = true
			bus.owner_user_ids[i] = owner_user_id
			bus.sockets[i] = socket
			if i >= bus.client_count do bus.client_count = i + 1
			return i
		}
	}
	return -1
}

user_ws_remove :: proc(bus: ^User_Event_Bus, idx: int) {
	if bus == nil || idx < 0 || idx >= len(bus.connected) do return
	bus.connected[idx] = false
	bus.owner_user_ids[idx] = ""
	bus.sockets[idx] = net.TCP_Socket(0)
}

publish_resource_changed :: proc(bus: ^User_Event_Bus, owner_user_id, resource, resource_id, change, summary_json: string) {
	if bus == nil || owner_user_id == "" do return
	bus.event_seq += 1
	event := resource_changed_json(bus.event_seq, resource, resource_id, change, summary_json)
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

publish_raw_to_user :: proc(bus: ^User_Event_Bus, owner_user_id, event_json: string) {
	if bus == nil || owner_user_id == "" || event_json == "" do return
	for i in 0..<bus.client_count {
		if bus.connected[i] && bus.owner_user_ids[i] == owner_user_id {
			result := ws.write_server_text(bus.sockets[i], event_json, true)
			switch result {
			case .Too_Large:      bus.oversized_events_dropped += 1
			case .Desynchronised: bus.desynchronised_removals += 1
			case .Ok, .Peer_Gone: // nothing to count
			}
			user_ws_note_write(result, len(event_json))
			// Reported unconditionally: whether the slot goes is a SEPARATE question from
			// whether the outcome is worth a line, and _log_publish_write owns the latter.
			_log_publish_write(result, len(event_json))
			if _publish_write_removes_socket(result) {
				bus.sockets_removed += 1
				user_ws_remove(bus, i)
			}
		}
	}
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
//     agent_action_handlers.odin:99  if strings.contains(trimmed, "vault:v1:") do return collapsed
//   That early return hands back the WHOLE collapsed body; the rune clip below it is never
//   reached. And bodies arrive armored by default — ctl_agentmode_chat_send_params
//   (src/ctl/agent_mode.odin:1307-1317) encrypts every non-armored body whenever a vault key
//   is configured, producing exactly that `vault:v1:` prefix. So the bound is ~4/3 of the
//   plaintext (base64) with NO cap: roughly 49 KB of plaintext crossed the old 65535 cliff,
//   and multi-KB agent messages are routine.
//
//   AND THE GUARD IS `strings.contains`, NOT `has_prefix` — which is the more alarming half.
//   A body that merely MENTIONS the literal `vault:v1:` anywhere takes the uncapped branch
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
// unbounded hub-side allocation. Chunking is not the answer either — this bus has no
// sequencing, and the UI refetches authoritative state from the id in the event.
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
// socket on this bus arrives through user_ws_add, whose only caller is the /user WebSocket
// upgrade — so every peer is a browser, and a browser parses a 127 length correctly. The
// bridge command channel takes the OPPOSITE answer for the same reason reversed: our own
// readers treat a 127 length as fatal, so emitting one toward a bridge would turn a dropped
// frame into a killed connection. See the note on ws.write_server_text.
//
// This wrapper exists for the one caller that sends a FIXED-SHAPE control frame — the
// user_ws_ready handshake — for which Too_Large would mean a bug in this repository rather
// than a large event, and which can do nothing different about the reason. The fan-out path
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
