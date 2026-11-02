package app

import "core:fmt"
import "core:mem/virtual"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import events "odin_test:hub/service/events"
import http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"
import card_service "odin_test:hub/service/card"
import bridge_log_service "odin_test:hub/service/bridge_log"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import shell_session_svc "odin_test:hub/service/shell_session"
import vault_directory_service "odin_test:hub/service/vault_directory"

// REAPER_STALE_MS mirrors the request-driven sweep threshold used on bridge
// heartbeats (http.BRIDGE_INSTANCE_STALE_MS = 90s): an instance still in an
// active runtime state whose last_seen_at is older than this is flipped to
// "unreachable". Kept generously above the ~2s heartbeat cadence so a briefly
// slow bridge is never falsely reaped.
REAPER_STALE_MS :: 90_000

// DEFAULT_REAPER_INTERVAL_SECONDS is used when the configured interval is <= 0.
DEFAULT_REAPER_INTERVAL_SECONDS :: 20

// REAPER_BRIDGE_GONE_MS is how long a bridge must go UNHEARD-FROM before the hub
// declares it gone for good and lands a terminal status on its live shell sessions
// (REQ-SHELL-14, core invariant (b) for the never-came-back case).
//
// IT IS DELIBERATELY FAR ABOVE THE LIVENESS THRESHOLDS, and not a reuse of them.
// REAPER_STALE_MS (90s) and http.BRIDGE_INSTANCE_STALE_MS answer "is it responding
// right now". This answers "is it never coming back", a categorically stronger claim
// about a remote machine, so it must not borrow their number: at 45s heartbeats, 90s
// is two missed beats, which is a blip.
//
// THE TRIGGER IS ABSENCE OVER TIME, NEVER "DISCONNECTED". Three call sites in this
// codebase deliberately CONVERT rather than kill on a WS drop, because a drop is
// usually transient with the child processes alive; reacting to disconnect here would
// reintroduce exactly the destroyed-in-flight-work failure those sites exist to
// prevent — a 20-minute build killed by a network hiccup.
//
// WHY ONE HOUR, in both directions, because the next reader will be tempted to tighten
// it and that is the dangerous way to be wrong:
//   TOO SHORT destroys real work. A long outage on a live bridge would mark running
//     sessions failed while their processes are fine.
//   TOO LONG only leaves a row stale for longer.
// Those costs are NOT symmetric, and the asymmetry is what picks the number: because
// REQ-SHELL-10's inventory diff REVIVES a session the hub wrongly called terminal once
// the bridge returns with the process alive, being early is bounded and self-healing,
// while being late costs only staleness. An hour is comfortably longer than any
// plausible partition or bridge restart, and short enough that a genuinely dead
// bridge's rows do not advertise themselves as live for a working day.
// That revive is a CONDITION on this constant, not a bonus: if it ever stops firing for
// hub-synthesized rows, this threshold becomes destructive rather than conservative.
// It is asserted by test for exactly that reason.
REAPER_BRIDGE_GONE_MS :: 60 * 60 * 1000

// REAPER_SERVER_MAX_AGE_MS is how old a `server` may get before it is killed regardless
// of chain state (REQ-SHELL-9 trigger B). The user's words: "kill all servers once task
// chain completes OR are older than 1 day".
//
// AGE IS MEASURED FROM started_at, NOT created_at. created_at is when the hub wrote the
// row; started_at is when the process began. The requirement is about a process that has
// been running too long, so the process's own clock answers it — see
// shell_session_reap_aged_servers, which also documents why an unparseable or empty
// started_at is skipped rather than treated as infinitely old.
//
// WHY 24 HOURS IS NOT A THRESHOLD TO TUNE. Unlike REAPER_BRIDGE_GONE_MS above, this
// number was not chosen by weighing failure costs — it was GIVEN. Anyone tempted to
// lower it should understand that it is not a heuristic about when a server is probably
// abandoned; it is the product decision about how long a server is allowed to live.
// Changing it changes the promise, not the accuracy of a guess.
//
// IT IS ONLY A BACKSTOP. The chain-completion trigger is the one that normally ends a
// server's life, and it is immediate. This catches the cases that trigger cannot see: a
// chain that never closes, and a server started outside any chain's lifetime.
REAPER_SERVER_MAX_AGE_MS :: 24 * 60 * 60 * 1000

// REAPER_LIVE_BRIDGE_IDS_MAX bounds the candidate listing, a runaway backstop rather
// than pagination — mirroring SHELL_SESSION_INVENTORY_MAX_ROWS. The query already
// narrows to bridges HOLDING LIVE SESSIONS, which is small; this only stops a
// pathological table from allocating without limit on a 20-second loop.
REAPER_LIVE_BRIDGE_IDS_MAX :: 1024

// reaper_loop is the periodic background safety net for stale agent instances.
//
// Why it exists: the hub's staleness reap was REQUEST-DRIVEN only — it ran on
// inbound bridge heartbeats. If a whole bridge dies and never reconnects, no
// heartbeat arrives, so its instances stay runtime_status='running' forever
// (the clean-disconnect cascade in bridge_ws_disconnect covers an observed WS
// close, but not a hub restart with a persisted DB, a silently half-open
// connection, or a lost close). This loop re-evaluates staleness on a fixed
// cadence independent of bridge traffic and flips stranded instances to
// 'unreachable', publishing resource_changed so the UI self-heals live.
//
// Thread-safety: this runs in its own process-scoped thread (launched from
// app.run before the blocking http.serve). It uses the EXACT same access
// pattern the HTTP request threads already use concurrently — the server spawns
// one thread per client, all sharing graph.agents + graph.event_bus with no
// mutex, and request handlers already call agent_service.reap_stale_instances +
// events.publish_resource_changed. So this adds no new shared-state contract.
reaper_loop :: proc(graph: ^App_Graph) {
	if graph == nil do return
	interval := graph.config.reaper_interval_seconds
	if interval <= 0 do interval = DEFAULT_REAPER_INTERVAL_SECONDS
	reaper_with_scratch(graph, proc(graph: ^App_Graph) {
		mcp_cleanup_once(graph)
		// Attention cards: reconcile once at startup, then on the sweep cadence below.
		attention_reconcile_maybe(graph, true)
		// REQ-EA-3: once at startup, before the first interval, so an enrollment that
		// was pending when the hub stopped is rolled back as soon as the hub is back.
		reaper_sweep_pending_enrollments(graph)
		// REQ-2: startup recovery for reconfigurations left mid-flight by a restart.
		agent_service.reconcile_active_reconfigurations(&graph.agents)
	})
	for {
		time.sleep(time.Duration(interval) * time.Second)
		reaper_with_scratch(graph, proc(graph: ^App_Graph) {
			reaper_sweep_once(graph)
			attention_reconcile_maybe(graph, false)
		})
	}
}

// reaper_with_scratch runs one reaper pass on a scratch arena, as both allocators.
// This thread lives for the whole process on the persistent heap, and the passes
// call the same services request handlers do — which return owned rows and rely on
// an arena to reclaim whatever the caller does not free (taskv2's terminal hook,
// card reconciliation, repository rows) — and its temp allocator is never reset.
// Anything a pass hands to another thread or keeps is cloned onto an explicit
// allocator by its owner (runtime registry, event bus, attention debouncer, kill
// replay workers), exactly as for a request.
reaper_with_scratch :: proc(graph: ^App_Graph, pass: proc(graph: ^App_Graph)) {
	scratch: virtual.Arena
	scratch_ok := virtual.arena_init_growing(&scratch) == nil
	defer if scratch_ok do virtual.arena_destroy(&scratch)
	allocator, temp_allocator := context.allocator, context.temp_allocator
	if scratch_ok do allocator, temp_allocator = virtual.arena_allocator(&scratch), virtual.arena_allocator(&scratch)
	context.allocator, context.temp_allocator = allocator, temp_allocator
	pass(graph)
}

// ATTENTION_RECONCILE_INTERVAL_SECONDS: how often the attention-card
// reconciliation (card_service.reconcile_attention) re-checks every source.
// Write-through keeps cards current; this only repairs a missed notification,
// so it can be infrequent.
ATTENTION_RECONCILE_INTERVAL_SECONDS :: 10 * 60

attention_last_reconcile: time.Tick

// attention_reconcile_maybe rides the reaper thread (no extra timer thread). It
// runs when forced or when the interval has elapsed since the last run.
attention_reconcile_maybe :: proc(graph: ^App_Graph, force: bool) {
	if graph == nil do return
	now := time.tick_now()
	if !force && attention_last_reconcile != {} && time.tick_diff(attention_last_reconcile, now) < time.Duration(ATTENTION_RECONCILE_INTERVAL_SECONDS) * time.Second do return
	attention_last_reconcile = now
	stats := card_service.reconcile_attention(&graph.cards)
	if stats.failed > 0 do fmt.eprintfln("ham-hub WARN attention reconcile: owners=%d projected=%d failed=%d last_failure=%s code=%v", stats.owners, stats.projected, stats.failed, stats.last_failure, stats.last_failure_code)
}

// reaper_sweep_once performs a single stale-instance sweep + event fan-out. Split
// out from the loop so it stays trivially callable/testable and so app.run can
// launch reaper_loop as a thread entry point.
reaper_sweep_once :: proc(graph: ^App_Graph) {
	if graph == nil do return
	mcp_cleanup_once(graph)
	// Outcome for heimdall_reaper_runs_total: the passes below swallow their
	// own failures by design, so the only error signal that surfaces is the
	// retention sweep's domain error. Recorded on every exit path.
	sweep_ok := true
	defer reaper_metrics_record(sweep_ok)
	_ = project_service.bridge_runtime_registry_sweep(&graph.bridge_runtime_registry)
	if plan_err := reconcile_bridge_plans(graph); plan_err.code != .None {
		sweep_ok = false
		fmt.eprintfln("hub: bridge plan reconciliation failed: %s", plan_err.message)
	}

	// REQ-SHELL-8 item 6: terminal shell_sessions rows past their retention window.
	// It rides THIS sweep rather than bringing its own timer — the loop already runs
	// on a cadence, and a second thread walking the same table would be the polling
	// the shells redesign exists to remove. Deliberately one call, for REQ-SHELL-9's
	// server reaping to extend rather than duplicate.
	//
	// A failure here is logged by neither side on purpose: retention is a best-effort
	// tidy-up, the next tick retries it unchanged, and letting it abort the sweep
	// would take the stale-instance reap down with it — the safety net this loop
	// actually exists for.
	if _, retention_err := shell_session_svc.shell_session_sweep_terminal_rows(&graph.shell_session_service); retention_err.code != .None {
		sweep_ok = false
	}

	// REQ-SHELL-14: sessions on a bridge that is never coming back. Rides THIS sweep
	// for the same reason the retention pass above does — the loop already runs, and a
	// second thread walking the same table would be the polling the shells redesign
	// exists to remove. Like retention, a failure is swallowed rather than allowed to
	// abort the stale-instance reap below, which is the safety net this loop is for.
	reaper_sweep_gone_bridges(graph)

	// REQ-EA-3: pending enrollments past their deadline are rolled back, so a bridge
	// whose vault key never arrived is never left enrolled.
	reaper_sweep_pending_enrollments(graph)

	// Passwordless vault: owner resets whose 72 h delay has passed.
	reaper_sweep_vault_resets(graph)

	// Browser sessions (absolute/idle expiry), pending OIDC logins and v2
	// device-proof nonces past their window.
	if _, purge_err := auth_service.purge_expired_auth_rows(&graph.auth); purge_err.code != .None {
		sweep_ok = false
		fmt.eprintfln("[reaper] auth expiry purge failed: %s", purge_err.message)
	}

	// bridge_log relay (plan §4.3): the 7-day time prune of bridge_log_events
	// rides this sweep but runs only every 15 min (by the received_at index);
	// the per-bridge 500-row cap lives in the writer thread, not here.
	_, _ = bridge_log_service.maybe_prune(&graph.bridge_logs, time.now()._nsec / 1_000_000)

	// REQ-SHELL-9 trigger B: servers older than a day. Rides THIS sweep for the reason
	// the task requires and the two passes above already demonstrate — the loop exists,
	// and a second timer walking the same table would be the polling the shells redesign
	// removes. The no-polling rule is about STATUS PROPAGATION, which must be pushed; an
	// age reap is not a status, and nothing here asks a bridge how it is doing.
	reaper_sweep_aged_servers(graph)

	// Provider tests are intentionally transient. Reap them independently of the
	// browser polling their status, and also when their bridge is no longer live.
	// cleanup_provider_test_instance sends stop only while the bridge is connected,
	// then always removes the operational agent_instances row.
	provider_runs := provider_service.provider_test_active_runs(&graph.providers)
	defer provider_service.provider_test_runs_destroy(provider_runs)
	now := platform.clock_now(&graph.clock)
	for run in provider_runs {
		expired := run.expires_at != "" && run.expires_at <= now
		disconnected := !project_service.bridge_runtime_registry_has_live(&graph.bridge_runtime_registry, run.bridge_id)
		if !expired && !disconnected do continue
		auth := contracts.Auth_Context{kind = .Internal_User, user_id = run.owner_user_id}
		_ = agent_service.cleanup_provider_test_instance(&graph.agents, auth, run.agent_instance_id)
		state := "expired" if expired else "cancelled"
		reason := "provider test expired" if expired else "bridge disconnected during provider test"
		updated, _ := provider_service.provider_test_set_state(&graph.providers, run.run_id, run.owner_user_id, state, reason)
		provider_service.provider_test_run_destroy(&updated)
	}

	// REQ-2: reconfiguration progress and confirmation timeouts advance here (and
	// on bridge transitions), so they complete with no client polling the GET.
	agent_service.reconcile_active_reconfigurations(&graph.agents)

	reaped := agent_service.reap_stale_instances(&graph.agents, REAPER_STALE_MS)
	agent_service.notify_instances_terminal(&graph.agents, reaped)
	defer domain.agent_instances_destroy(reaped)
	for inst in reaped {
		project_service.bridge_runtime_instance_retire(&graph.bridge_runtime_registry, inst.bridge_id, project_service.bridge_runtime_registry_generation(&graph.bridge_runtime_registry, inst.bridge_id), inst.agent_instance_id, string(inst.runtime_status))
		// REQ-SHELL-2 §9: the staleness sweep is the third and last liveness signal,
		// and it gets the same rule as the other two — a foreground run whose agent
		// is gone becomes a background run, so it stays tracked and reapable instead
		// of blocking for a caller that no longer exists.
		shell_session_svc.shell_session_background_runs_for_agent(&graph.shell_session_service, string(inst.owner_user_id), inst.agent_instance_id)
		http.publish_instance_changed(&graph.event_bus, inst, "status_changed")
	}
}

// reaper_sweep_pending_enrollments rolls back every pending enrollment past its
// deadline (REQ-EA-3), closes any enroll-only socket still open for it, and tells the
// owner's UI. Returns how many were rolled back. Everything it allocates is freed:
// this runs on the reaper thread, which has no per-request arena.
reaper_sweep_pending_enrollments :: proc(graph: ^App_Graph) -> int {
	if graph == nil do return 0
	rolled := bridge_service.sweep_expired_enrollments(&graph.bridges)
	defer bridge_service.rolled_back_enrollments_destroy(rolled)
	for r in rolled {
		key := http.bridge_enroll_registry_key(r.bridge_id)
		// Before the close: a process that already saved its key undoes it on this.
		http.bridge_enroll_send_result(&graph.bridge_runtime_registry, key, false)
		_ = bridge_service.close_bridge_connection(&graph.bridges, key)
		delete(key)
		fmt.eprintfln("hub: bridge %s enrollment rolled back (vault key not delivered in time; row deleted: %v)", r.bridge_id, r.row_deleted)
		events.publish_resource_changed(&graph.event_bus, r.owner_user_id, "bridge", r.bridge_id, "bridge_enrollment_changed", "{}")
		// The identity approved with it never got the vault key: retire its entry.
		reaper_retire_bridge_entry(graph, r.owner_user_id, r.bridge_id)
	}
	return len(rolled)
}

// reaper_sweep_gone_bridges lands a terminal status on the live shell sessions of every
// bridge the hub has not heard from for longer than REAPER_BRIDGE_GONE_MS.
//
// Split out and exported for the same reason reaper_sweep_once is: it must be callable
// from a test directly, with injected timestamps rather than by waiting an hour.
//
// SHAPE, and why it is this way round. It asks the SESSION table which bridges hold live
// rows, then asks each of those bridges how long it has been absent — not the reverse.
// The candidate set is therefore bounded by what can actually need reaping rather than
// by every bridge ever enrolled, and a bridge with nothing running costs one query row
// and no bridge read at all. On a 20-second loop that difference is the whole design.
//
// THE AGE TEST LIVES HERE, IN ODIN, NOT IN SQL. That mirrors reap_stale_instances, which
// likewise takes a candidate set from the repository and judges age itself, and it keeps
// the threshold next to the comment that justifies it instead of splitting the rule
// between a constant and a WHERE clause.
//
// MEMORY: this runs on the process-scoped reaper thread, which has NO per-request arena,
// so every HEAP allocation here is freed explicitly — the bridge id list and each id in
// it, and each cloned last_seen_at. Nothing is left for a later pass to tidy, because
// there is no later pass; a leak here would accumulate every 20 seconds forever.
// The word HEAP is load-bearing: the one value on this path that is NOT a heap block is
// the clock_now timestamp, and freeing it is a crash rather than a tidy-up. See below.
reaper_sweep_gone_bridges :: proc(graph: ^App_Graph) -> int {
	if graph == nil do return 0
	// BORROWED, NEVER DELETED. platform.clock_now bottoms out in fmt.tprintf
	// (platform/clock.odin:format_rfc3339_utc), so what it returns lives in the TEMP
	// allocator's arena and was never a heap block. Handing it to delete() frees a
	// non-heap pointer through the heap allocator — an invalid free, not a tidy-up.
	// shell_session_apply_inventory carries the same comment because it made exactly
	// this mistake once, and there bridge RECONNECT was the trigger; here it would be
	// every 20 seconds, forever.
	//
	// So this is the one clock_now on this path that must NOT be freed, and it is the
	// exception to the free-everything rule the rest of this sweep follows: the rule is
	// about HEAP allocations, and this is not one. Nothing below needs `now` to outlive
	// the call — reaper_reap_gone_bridges only parses it to an i64.
	//
	// The temp arena itself is never reset on this thread. That is a real, separate
	// concern (it predates this code: shell_session_delete_terminal_before_sqlite has
	// done the same since REQ-SHELL-8), filed as its own issue — but a 20-byte string
	// left in an arena is a leak, while delete() on it is a crash.
	now_str := platform.clock_now(&graph.clock)
	return reaper_reap_gone_bridges(&graph.bridges, &graph.shell_session_service, now_str)
}

// reaper_reap_gone_bridges is the sweep itself, taking the two services it actually
// needs instead of the whole App_Graph.
//
// IT IS SPLIT FROM THE GRAPH WRAPPER SO THE BLIP CASE IS TESTABLE. The regression this
// task must not cause — a bridge that merely blinked having its live sessions marked
// failed — can only be asserted by driving the sweep with a bridge that was seen
// recently and checking the rows are UNCHANGED. Threading a whole App_Graph into a test
// to prove that would mean standing up every repository in the hub, so the observable
// behaviour would go unasserted in practice. These two services and a timestamp are the
// entire input, and `now` being a parameter is what lets a test place a bridge an hour
// in the past without waiting an hour.
reaper_reap_gone_bridges :: proc(
	bridges:  ^bridge_service.Bridge_Service,
	sessions: ^shell_session_svc.Shell_Session_Service,
	now_str:  string,
) -> int {
	if bridges == nil || sessions == nil || sessions.repo == nil do return 0
	if now_str == "" do return 0
	now_ms, now_ok := platform.rfc3339_to_unix_ms(now_str)
	if !now_ok do return 0

	ids, err := iface.shell_session_list_live_bridge_ids(sessions.repo, REAPER_LIVE_BRIDGE_IDS_MAX)
	defer {
		for id in ids do delete(id)
		delete(ids)
	}
	if err.code != .None do return 0

	reaped := 0
	for id in ids {
		last_seen, eligible := bridge_service.bridge_absence_marker(bridges, id)
		defer delete(last_seen)
		if !eligible do continue
		if !reaper_bridge_absence_is_terminal(now_ms, last_seen) do continue
		reaped += shell_session_svc.shell_session_reap_gone_bridge(sessions, id, now_str)
	}
	return reaped
}

// reaper_bridge_absence_is_terminal is the age test itself: has this bridge been
// unheard-from for longer than REAPER_BRIDGE_GONE_MS?
//
// It is a separate, pure proc taking milliseconds and a timestamp rather than an inline
// comparison so the THRESHOLD DECISION is testable without a repository, a clock or a
// bridge — a test can assert directly that 59 minutes is a blip and 61 is gone, which is
// the acceptance criterion this task is judged on.
//
// AN UNPARSEABLE last_seen_at RETURNS FALSE, i.e. NOT gone. That direction is chosen
// deliberately: the failure mode of guessing "gone" from a timestamp we could not read
// is marking live sessions failed, which is the destructive direction the whole design
// avoids. Skipping mirrors reap_stale_instances, which likewise skips an instance whose
// last_seen_at will not parse rather than misclassifying it.
//
// A FUTURE-DATED last_seen_at is also NOT gone, which falls out of the signed
// comparison: clock skew between hub and bridge should never manufacture absence.
reaper_bridge_absence_is_terminal :: proc(now_ms: i64, last_seen_at: string) -> bool {
	seen_ms, ok := platform.rfc3339_to_unix_ms(last_seen_at)
	if !ok do return false
	return now_ms - seen_ms >= REAPER_BRIDGE_GONE_MS
}

// reaper_sweep_aged_servers kills every live server older than REAPER_SERVER_MAX_AGE_MS
// (REQ-SHELL-9 trigger B), through the REQ-SHELL-3 durable kill intent so a server on a
// disconnected bridge still dies when its bridge returns.
//
// Split from the service proc it calls for the same reason reaper_sweep_gone_bridges is:
// the graph wrapper reads the clock, and the proc that decides anything takes `now` as a
// parameter, so AC2 is tested by placing a server 25 hours in the past instead of by
// sleeping for 25 hours.
//
// THIS THREE-LINE WRAPPER IS UNCOVERED BY TESTS, and that is now a known cost rather than
// an assumption: the same seam in reaper_sweep_gone_bridges is where a `defer
// delete(now_str)` on a temp-arena string shipped (fixed in 1ba0d4ba). Which is exactly
// why clock_now is BORROWED here and not freed — it is an fmt.tprintf temp allocation
// (platform/clock.odin format_rfc3339_utc), so delete() on it is an invalid free, not a
// tidy-up. Nothing below needs it to outlive this call; it is parsed to an i64 and
// discarded.
reaper_sweep_aged_servers :: proc(graph: ^App_Graph) -> int {
	if graph == nil do return 0
	now_str := platform.clock_now(&graph.clock)
	if now_str == "" do return 0
	now_ms, ok := platform.rfc3339_to_unix_ms(now_str)
	if !ok do return 0
	return shell_session_svc.shell_session_reap_aged_servers(&graph.shell_session_service, now_ms, REAPER_SERVER_MAX_AGE_MS)
}

// reaper_retire_bridge_entry retires a rolled-back enrollment's vault directory
// entry (in a local arena: reaper thread). A failure is logged; the entry then stays
// approved for a bridge that has no credential, which is inert.
@(private = "file")
reaper_retire_bridge_entry :: proc(graph: ^App_Graph, owner_user_id, bridge_id: string) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	retired, err := vault_directory_service.retire_bridge_entry(&graph.vault_directory, owner_user_id, bridge_id)
	if err.code != .None {
		fmt.eprintfln("hub: bridge %s vault directory entry could not be retired: %s", bridge_id, err.message)
		return
	}
	if retired != "" do events.publish_resource_changed(&graph.event_bus, owner_user_id, http.VAULT_DEVICES_RESOURCE, retired, "retired", "{}")
}

// reaper_sweep_vault_resets executes every owner vault reset whose delay has passed
// (vault_directory.schedule_reset). Per account, FAIL CLOSED: every bridge the
// account owns loses its credentials first (pending enrollments are rolled back,
// enrolled bridges revoked); if any of that fails the directory is kept and the next
// sweep retries. Only then is the directory deleted, and a second, best-effort pass
// catches a bridge that enrolled in between. Also drops expired request nonces.
// Runs on the reaper thread: everything is allocated in a local arena.
reaper_sweep_vault_resets :: proc(graph: ^App_Graph) -> int {
	if graph == nil do return 0
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return 0
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator

	if now_ms, ok := platform.rfc3339_to_unix_ms(platform.clock_now(&graph.clock)); ok {
		vault_directory_service.nonce_cache_sweep(&graph.vault_directory.nonces, now_ms)
	}
	users, err := vault_directory_service.due_resets(&graph.vault_directory)
	if err.code != .None do return 0
	executed := 0
	for user_id in users {
		if !reaper_revoke_all_bridges(graph, user_id) {
			fmt.eprintfln("hub: vault reset for %s postponed: a bridge credential could not be revoked; retrying next sweep", user_id)
			continue
		}
		done, xerr := vault_directory_service.execute_reset(&graph.vault_directory, user_id)
		if xerr.code != .None {
			fmt.eprintfln("hub: vault reset for %s failed: %s", user_id, xerr.message)
			continue
		}
		if !done do continue // cancelled in between
		_ = reaper_revoke_all_bridges(graph, user_id)
		executed += 1
		http.vault_announce_directory(&graph.event_bus, &graph.push, graph.config.public_app_origin, user_id, "reset_executed", "")
	}
	return executed
}

// reaper_revoke_all_bridges revokes the credentials of every bridge
// user_id owns. False if any of them could not be revoked (or the list failed).
@(private = "package")
reaper_revoke_all_bridges :: proc(graph: ^App_Graph, user_id: string) -> bool {
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = user_id}
	bridges, err := bridge_service.list_bridges(&graph.bridges, auth)
	if err.code != .None do return false
	all_ok := true
	// Enrolled bridges (list_bridges omits pending rows): revoke every credential.
	for b in bridges {
		// Already-revoked sunset rows retain rollback authority until explicitly
		// revoked. Invalidate it here before a concurrent rollback can restore them.
		if _, ok, _ := bridge_service.revoke_bridge(&graph.bridges, auth, b.bridge_id); !ok do all_ok = false
	}
	// Pending new-bridge enrollments: roll back (revokes the enroll family, deletes the
	// row). .Keep_Revoked also covers sunsets admitted after the enrolled-row
	// snapshot: resetting the vault must never revive their old credentials.
	for b in bridge_service.list_pending_bridges(&graph.bridges, auth) {
		if _, _, cerr := bridge_service.cancel_pending_enrollment(&graph.bridges, b.bridge_id, .Keep_Revoked); cerr.code != .None do all_ok = false
	}
	return all_ok
}
