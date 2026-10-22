package main

// ham.ext.v1 ingest (REQ-EXT-CORE-2, REQ-EXT-ACT-1).
//
// A harness extension (via `ham-ctl extension …`) calls the bridge-local RPC
// `agent.extension.event` with one ham.ext.v1 event or {"events":[...]}. The
// bridge:
//   1. validates each event (src/contracts/extension.odin), rejecting bad ones
//      individually so one malformed hook cannot drop a batch;
//   2. maps activity-bearing events onto the existing rank/TTL activity path
//      with source "<provider>_extension" (rank 80 > pane_diff 40, so the
//      screen-scraper is overridden while events flow and resumes after TTL);
//   3. records hello capabilities for `agent.extension.status`;
//   4. queues the normalised event JSON in a per-instance outbox that a single
//      worker forwards to the hub in batches (≥ BRIDGE_EXT_FLUSH_MAX_EVENTS
//      queued, or BRIDGE_EXT_FLUSH_DELAY_MS after the first queued event);
//   5. feeds tool/subagent/activity events to the per-instance tool aggregator
//      (extension_tool_aggregator.odin), whose `tool_activity` messages the same
//      worker posts to BRIDGE_EXT_TOOL_ACTIVITY_PATH after the instance's batch.
//
// IDENTITY: the instance is ALWAYS the token-verified rec.agent_instance_id.
// Any instance id inside the payload is ignored — the hub envelope is stamped
// from rec, never from the event.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

BRIDGE_EXT_FLUSH_MAX_EVENTS :: 50
BRIDGE_EXT_FLUSH_DELAY_MS :: i64(250)
// BRIDGE_EXT_OUTBOX_MAX_EVENTS bounds one instance's queue while the hub is
// unreachable; the OLDEST events are dropped first.
BRIDGE_EXT_OUTBOX_MAX_EVENTS :: 1000
BRIDGE_EXT_WORKER_TICK_MS :: 50
BRIDGE_EXT_HUB_PATH :: "/api/v1/agent-actions/extension-events"
BRIDGE_EXT_TOOL_ACTIVITY_PATH :: "/api/v1/agent-actions/tool-activity"

Bridge_Ext_Instance_State :: struct {
	agent_instance_id: string,
	rec:               Bridge_Local_Agent_Token_Record, // owned clone; latest caller wins
	provider:          string,
	ext_version:       string,
	capabilities:      [dynamic]string,
	last_event_at_ms:  i64,
	events_accepted:   int,
	events_dropped:    int,
	queue:             [dynamic]string, // normalised ham.ext.v1 JSON, owned
	first_enqueued_ms: i64, // 0 when queue is empty
	tools:             Tool_Agg, // tool_activity aggregation (REQ-EXT-CONV-1)
}

Bridge_Ext_Ingest_Result :: struct {
	accepted: int,
	rejected: int,
	errors:   [dynamic]string, // pre-rendered {"index":N,"error":"…"} objects
	fatal:    contracts.Ext_Error, // whole-request failure (unparseable / single invalid event)
}

bridge_ext_mutex: sync.Mutex
bridge_ext_states: [dynamic]Bridge_Ext_Instance_State
bridge_ext_worker_started: bool

// Global outbox state outlives any request (and any test's tracking allocator),
// so every proc that allocates into it pins the heap allocator.
@(private = "file")
bridge_ext_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// ext_outbox_should_flush is the pure batching decision.
ext_outbox_should_flush :: proc(count: int, first_enqueued_ms, now_ms: i64) -> bool {
	if count <= 0 do return false
	if count >= BRIDGE_EXT_FLUSH_MAX_EVENTS do return true
	return first_enqueued_ms > 0 && now_ms - first_enqueued_ms >= BRIDGE_EXT_FLUSH_DELAY_MS
}

// bridge_ext_activity_source names the activity source for a provider. It must
// contain "extension" so bridge_runtime_activity_source_rank ranks it 80.
bridge_ext_activity_source :: proc(provider: string) -> string {
	p := strings.to_lower(strings.trim_space(provider), context.temp_allocator)
	if p == "" do return "agent_extension"
	return fmt.tprintf("%s_extension", p)
}

@(private = "file")
bridge_ext_state_locked :: proc(instance_id: string) -> ^Bridge_Ext_Instance_State {
	for &s in bridge_ext_states {
		if s.agent_instance_id == instance_id do return &s
	}
	append(&bridge_ext_states, Bridge_Ext_Instance_State{agent_instance_id = strings.clone(instance_id)})
	return &bridge_ext_states[len(bridge_ext_states) - 1]
}

@(private = "file")
bridge_ext_set_rec_locked :: proc(s: ^Bridge_Ext_Instance_State, rec: Bridge_Local_Agent_Token_Record) {
	if s.rec.instance_token == rec.instance_token && s.rec.agent_instance_id == rec.agent_instance_id do return
	delete(s.rec.token_hash); delete(s.rec.agent_instance_id); delete(s.rec.instance_token)
	s.rec = rec
	s.rec.token_hash = strings.clone(rec.token_hash)
	s.rec.agent_instance_id = strings.clone(rec.agent_instance_id)
	s.rec.instance_token = strings.clone(rec.instance_token)
}

@(private = "file")
bridge_ext_enqueue_locked :: proc(s: ^Bridge_Ext_Instance_State, event_json: string, now: i64) {
	if len(s.queue) >= BRIDGE_EXT_OUTBOX_MAX_EVENTS {
		delete(s.queue[0])
		ordered_remove(&s.queue, 0)
		s.events_dropped += 1
	}
	append(&s.queue, strings.clone(event_json))
	if s.first_enqueued_ms == 0 do s.first_enqueued_ms = now
}

// bridge_ext_ingest validates, applies and queues the events in params for the
// token-verified rec. It does no network I/O (the forwarder does), so tests
// drive it directly.
bridge_ext_ingest :: proc(rec: Bridge_Local_Agent_Token_Record, params: string, now: i64) -> (res: Bridge_Ext_Ingest_Result) {
	context.allocator = bridge_ext_allocator()
	instance_id := rec.agent_instance_id
	raws, split_err := contracts.ext_split_events(params)
	if split_err != .None {
		res.fatal = split_err
		return
	}
	defer contracts.ext_split_events_destroy(raws)

	for raw, i in raws {
		ev, perr := contracts.ext_parse_event(raw)
		if perr != .None {
			res.rejected += 1
			b := strings.builder_make()
			strings.write_string(&b, fmt.tprintf("{{\"index\":%d,\"error\":\"", i))
			bridge_local_write_json_string(&b, contracts.ext_error_message(perr))
			strings.write_string(&b, "\"}")
			append(&res.errors, strings.to_string(b))
			if len(raws) == 1 do res.fatal = perr
			continue
		}
		defer contracts.ext_event_destroy(&ev)

		if status, ok := contracts.ext_activity_for_event(ev); ok {
			bridge_runtime_note_agent_activity(instance_id, status, bridge_ext_activity_source(ev.provider))
		}

		sync.mutex_lock(&bridge_ext_mutex)
		s := bridge_ext_state_locked(instance_id)
		bridge_ext_set_rec_locked(s, rec)
		if ev.kind == .Hello {
			delete(s.provider); delete(s.ext_version)
			s.provider = strings.clone(ev.provider)
			s.ext_version = strings.clone(ev.ext_version)
			for c in s.capabilities do delete(c)
			clear(&s.capabilities)
			for c in ev.capabilities do append(&s.capabilities, strings.clone(c))
		} else if s.provider == "" {
			s.provider = strings.clone(ev.provider)
			s.ext_version = strings.clone(ev.ext_version)
		}
		s.last_event_at_ms = now
		s.events_accepted += 1
		bridge_ext_enqueue_locked(s, raw, now)
		tool_agg_observe(&s.tools, ev, raw, now)
		sync.mutex_unlock(&bridge_ext_mutex)
		res.accepted += 1
	}
	return
}

bridge_ext_ingest_result_destroy :: proc(res: ^Bridge_Ext_Ingest_Result) {
	context.allocator = bridge_ext_allocator()
	for e in res.errors do delete(e)
	delete(res.errors)
}

bridge_ext_ingest_result_json :: proc(res: Bridge_Ext_Ingest_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("{{\"accepted\":%d,\"rejected\":%d,\"errors\":[", res.accepted, res.rejected))
	for e, i in res.errors {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, e)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// bridge_ext_take_batch_locked removes up to BRIDGE_EXT_FLUSH_MAX_EVENTS from
// the head of s.queue when a flush is due (or force). The caller owns the result.
bridge_ext_take_batch_locked :: proc(s: ^Bridge_Ext_Instance_State, now: i64, force: bool) -> [dynamic]string {
	context.allocator = bridge_ext_allocator()
	if len(s.queue) == 0 do return nil
	if !force && !ext_outbox_should_flush(len(s.queue), s.first_enqueued_ms, now) do return nil
	n := min(len(s.queue), BRIDGE_EXT_FLUSH_MAX_EVENTS)
	batch := make([dynamic]string, 0, n)
	for i in 0..<n do append(&batch, s.queue[i])
	remove_range(&s.queue, 0, n)
	s.first_enqueued_ms = now if len(s.queue) > 0 else 0
	return batch
}

// bridge_ext_requeue_head_locked puts an unsent batch back in front, honouring
// the outbox cap (oldest dropped first). Takes ownership of batch's strings.
bridge_ext_requeue_head_locked :: proc(s: ^Bridge_Ext_Instance_State, batch: [dynamic]string, now: i64) {
	context.allocator = bridge_ext_allocator()
	merged := make([dynamic]string, 0, len(batch) + len(s.queue))
	for e in batch do append(&merged, e)
	for e in s.queue do append(&merged, e)
	delete(s.queue)
	delete(batch)
	for len(merged) > BRIDGE_EXT_OUTBOX_MAX_EVENTS {
		delete(merged[0])
		ordered_remove(&merged, 0)
		s.events_dropped += 1
	}
	s.queue = merged
	if len(s.queue) > 0 && s.first_enqueued_ms == 0 do s.first_enqueued_ms = now
}

bridge_ext_batch_params :: proc(batch: [dynamic]string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"events\":[")
	for e, i in batch {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, e)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_ext_forwarder_ensure_started :: proc() {
	if _, swapped := sync.atomic_compare_exchange_strong(&bridge_ext_worker_started, false, true); swapped {
		thread.run(bridge_ext_forwarder_worker)
	}
}

bridge_ext_forwarder_worker :: proc() {
	for {
		time.sleep(BRIDGE_EXT_WORKER_TICK_MS * time.Millisecond)
		bridge_ext_forwarder_tick(bridge_runtime_now_ms())
		// This thread lives forever: reclaim the tick's temp allocations.
		free_all(context.temp_allocator)
	}
}

// bridge_ext_forwarder_tick sends at most one due batch per instance. While the
// hub is down nothing is taken off the queue.
bridge_ext_forwarder_tick :: proc(now: i64) {
	context.allocator = bridge_ext_allocator()
	if !sync.atomic_load(&bridge_hub_runtime_up) do return
	Pending :: struct {
		instance_id: string,
		rec:         Bridge_Local_Agent_Token_Record,
		batch:       [dynamic]string,
		messages:    [dynamic]Tool_Agg_Message,
	}
	pending := make([dynamic]Pending, context.temp_allocator)
	sync.mutex_lock(&bridge_ext_mutex)
	for &s in bridge_ext_states {
		tool_agg_tick(&s.tools, now)
		batch := bridge_ext_take_batch_locked(&s, now, false)
		messages := tool_agg_take_ready(&s.tools)
		if len(batch) == 0 && len(messages) == 0 {
			delete(messages)
			continue
		}
		rec := s.rec
		rec.instance_token = strings.clone(s.rec.instance_token, context.temp_allocator)
		rec.agent_instance_id = strings.clone(s.rec.agent_instance_id, context.temp_allocator)
		append(&pending, Pending{instance_id = strings.clone(s.agent_instance_id, context.temp_allocator), rec = rec, batch = batch, messages = messages})
	}
	sync.mutex_unlock(&bridge_ext_mutex)

	for p in pending {
		bridge_ext_post_tool_activity(p.instance_id, p.rec, p.messages)
		if len(p.batch) == 0 do continue
		body := bridge_ext_batch_params(p.batch)
		relay := bridge_local_relay_agent_envelope(BRIDGE_EXT_HUB_PATH, "agent.extension.event", body, p.rec)
		delete(body)
		// Retry later on transport failure or a hub 5xx; a 4xx means the hub will
		// never accept this batch (bad token/data), so drop rather than wedge.
		retry := !relay.ok || relay.status >= 500 || relay.status == 0
		if retry {
			sync.mutex_lock(&bridge_ext_mutex)
			bridge_ext_requeue_head_locked(bridge_ext_state_locked(p.instance_id), p.batch, now)
			sync.mutex_unlock(&bridge_ext_mutex)
		} else {
			for e in p.batch do delete(e)
			delete(p.batch)
		}
	}
}

// bridge_ext_post_tool_activity posts each aggregated `tool_activity` message
// (consuming messages). A transport failure or hub 5xx puts the unsent rest
// back at the head of the instance's ready queue for the next tick; a 4xx
// drops that message, as for event batches.
bridge_ext_post_tool_activity :: proc(instance_id: string, rec: Bridge_Local_Agent_Token_Record, messages: [dynamic]Tool_Agg_Message) {
	context.allocator = bridge_ext_allocator()
	msgs := messages
	defer delete(msgs)
	for i := 0; i < len(msgs); i += 1 {
		params := tool_agg_params(msgs[i])
		relay := bridge_local_relay_agent_envelope(BRIDGE_EXT_TOOL_ACTIVITY_PATH, "agent.extension.tool_activity", params, rec)
		delete(params)
		if !relay.ok || relay.status >= 500 || relay.status == 0 {
			sync.mutex_lock(&bridge_ext_mutex)
			a := &bridge_ext_state_locked(instance_id).tools
			rest := make([dynamic]Tool_Agg_Message, 0, len(msgs) - i + len(a.ready))
			for m in msgs[i:] do append(&rest, m)
			for m in a.ready do append(&rest, m)
			delete(a.ready)
			for len(rest) > TOOL_AGG_READY_MAX {
				tool_agg_message_destroy(&rest[0])
				ordered_remove(&rest, 0)
				a.ready_dropped += 1
			}
			a.ready = rest
			sync.mutex_unlock(&bridge_ext_mutex)
			return
		}
		tool_agg_message_destroy(&msgs[i])
	}
}

// bridge_ext_status_json renders agent.extension.status for one instance.
bridge_ext_status_json :: proc(instance_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\"")
	bridge_local_write_json_string(&b, instance_id)
	sync.mutex_lock(&bridge_ext_mutex)
	provider, version: string
	last: i64
	accepted, dropped, queued: int
	caps := make([dynamic]string, context.temp_allocator)
	for s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		provider = strings.clone(s.provider, context.temp_allocator)
		version = strings.clone(s.ext_version, context.temp_allocator)
		last = s.last_event_at_ms
		accepted = s.events_accepted
		dropped = s.events_dropped
		queued = len(s.queue)
		for c in s.capabilities do append(&caps, strings.clone(c, context.temp_allocator))
		break
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	strings.write_string(&b, "\",\"provider\":\""); bridge_local_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"ext_version\":\""); bridge_local_write_json_string(&b, version)
	strings.write_string(&b, "\",\"capabilities\":[")
	for c, i in caps {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); bridge_local_write_json_string(&b, c); strings.write_byte(&b, '"')
	}
	strings.write_string(&b, fmt.tprintf("],\"last_event_at_ms\":%d,\"events_accepted\":%d,\"events_dropped\":%d,\"queued\":%d", last, accepted, dropped, queued))
	activity, source: string
	if inst, ok := bridge_runtime_instance_snapshot(instance_id); ok {
		activity = inst.activity_status
		source = inst.activity_source
	}
	strings.write_string(&b, ",\"activity_status\":\""); bridge_local_write_json_string(&b, activity)
	strings.write_string(&b, "\",\"activity_source\":\""); bridge_local_write_json_string(&b, source)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_ext_handle_rpc fulfils agent.extension.event / agent.extension.status.
bridge_ext_handle_rpc :: proc(request_id, method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if method == "agent.extension.status" {
		return bridge_local_response_data(request_id, bridge_ext_status_json(rec.agent_instance_id))
	}
	res := bridge_ext_ingest(rec, params, bridge_runtime_now_ms())
	defer bridge_ext_ingest_result_destroy(&res)
	if res.accepted > 0 do bridge_ext_forwarder_ensure_started()
	if res.fatal != .None {
		return bridge_local_response_error(request_id, "bad_request", contracts.ext_error_message(res.fatal))
	}
	return bridge_local_response_data(request_id, bridge_ext_ingest_result_json(res))
}
