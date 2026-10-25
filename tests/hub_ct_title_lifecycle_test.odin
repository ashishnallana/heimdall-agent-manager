package hub_ct_title_lifecycle_test

// Phase 8 verification of the per-run title lifecycle (REQ-1..6 + T3).
//
// Covers, end to end against the REAL service/engine functions:
//   - per-agent GLOBAL title counter increments correctly and INDEPENDENTLY per
//     agent, and survives "restart" (the fake repo persists the counter);
//   - default_title_for_agent mints "<agent-name> #<n>" (never a raw agt_ id;
//     empty name -> "Agent"); slug fallback;
//   - evaluate_title_nudge gate (pure): no exchange gates; first exchange fires
//     exactly ONE nudge; re-nudge requires NEW activity AND cooldown elapsed; no
//     double-ping when nothing changed; any non-default (agent OR user) title
//     stops nudges forever;
//   - record_activity_and_maybe_nudge wiring: first user<->agent exchange delivers
//     exactly one bridge nudge command and stamps last_title_nudge_at (so a second
//     call without new activity does NOT re-nudge); an agent-set title stops it;
//   - set_own_conversation_title / set_own_chain_title mark title_source="agent"
//     (the T2 guardrail hook) and enforce instance-token auth;
//   - normalize_title_source clamps unknown values to "default".

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import taskchain_service "odin_test:hub/service/taskchain"
import content_sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

// ---------------------------------------------------------------------------
// Shared in-memory fixture (fake repositories + injected clock/ids). now_ms is
// advanced explicitly by tests so the cooldown gate is deterministic.
// ---------------------------------------------------------------------------
F :: struct {
	// content
	convos:    [8]domain.Chat_Conversation,
	convo_n:   int,
	msgs:      [64]domain.Chat_Message,
	msg_n:     int,
	// taskchain
	chains:    [8]domain.Task_Chain,
	chain_n:   int,
	members:   [16]domain.Task_Chain_Member,
	member_n:  int,
	// agents
	agents:    [8]domain.Agent,
	agent_n:   int,
	insts:     [8]domain.Agent_Instance,
	inst_n:    int,
	counters:  map[string]int, // per-agent persisted title counter (survives "restart")
	// runtime command sink capture
	cmds:      [32]string,
	cmd_n:     int,
	// clock/id
	now:       string,
	seq:       int,
}
f: F

fnow :: proc(ctx: rawptr) -> string { _ = ctx; return f.now }
fid :: proc(ctx: rawptr, prefix: string) -> string { f.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", f.seq)}) }

// --- content repo fakes ----------------------------------------------------
fc_save_convo :: proc(ctx: rawptr, c: domain.Chat_Conversation) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	nc := c
	nc.title_source = content_sqlite.normalize_title_source(c.title_source)
	for i in 0..<f.convo_n { if f.convos[i].conversation_id == nc.conversation_id { f.convos[i] = nc; return nc, true, {} } }
	f.convos[f.convo_n] = nc; f.convo_n += 1; return nc, true, {}
}
fc_get_convo :: proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	for i in 0..<f.convo_n { if f.convos[i].conversation_id == id do return f.convos[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "conversation")
}
fc_list_convos :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Conversation, domain.Domain_Error) {
	out := make([dynamic]domain.Chat_Conversation)
	for i in 0..<f.convo_n { if f.convos[i].owner_user_id == owner do append(&out, f.convos[i]) }
	return out[:], {}
}
fc_save_msg :: proc(ctx: rawptr, m: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	f.msgs[f.msg_n] = m; f.msg_n += 1; return m, true, {}
}
fc_list_user_visible :: proc(ctx: rawptr, conversation_id: string, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error) {
	out := make([dynamic]domain.Chat_Message)
	for i in 0..<f.msg_n { if f.msgs[i].conversation_id == conversation_id && f.msgs[i].direction != "agent_to_agent" do append(&out, f.msgs[i]) }
	return out[:], {}
}
// fc_list_messages returns messages of EVERY direction (incl. agent_to_agent),
// matching the real content_list_messages. The activity gate uses this so
// agent<->agent-only conversations count as active (TN-2/TN-3). Honors `limit`.
fc_list_messages :: proc(ctx: rawptr, conversation_id: string, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error) {
	out := make([dynamic]domain.Chat_Message)
	for i in 0..<f.msg_n {
		if f.msgs[i].conversation_id == conversation_id {
			append(&out, f.msgs[i])
			if limit > 0 && len(out) >= limit do break
		}
	}
	return out[:], {}
}

// --- taskchain repo fakes --------------------------------------------------
ft_get_chain :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	for i in 0..<f.chain_n { if f.chains[i].chain_id == id do return f.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "chain")
}
ft_save_chain :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	nc := c
	nc.title_source = content_sqlite.normalize_title_source(c.title_source)
	for i in 0..<f.chain_n { if f.chains[i].chain_id == nc.chain_id { f.chains[i] = nc; return nc, true, {} } }
	f.chains[f.chain_n] = nc; f.chain_n += 1; return nc, true, {}
}
ft_list_chains :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain)
	for i in 0..<f.chain_n { if f.chains[i].owner_user_id == owner do append(&out, f.chains[i]) }
	return out[:], {}
}
ft_save_member :: proc(ctx: rawptr, m: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	for i in 0..<f.member_n { if f.members[i].chain_id == m.chain_id && f.members[i].agent_instance_id == m.agent_instance_id { f.members[i] = m; return m, true, {} } }
	f.members[f.member_n] = m; f.member_n += 1; return m, true, {}
}
ft_list_members :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<f.member_n { if f.members[i].chain_id == chain_id do append(&out, f.members[i]) }
	return out[:], {}
}

// --- agent repo fakes ------------------------------------------------------
fa_get :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	for i in 0..<f.agent_n { if f.agents[i].agent_id == agent_id do return f.agents[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "agent")
}
fa_get_inst :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for i in 0..<f.inst_n { if f.insts[i].agent_instance_id == id do return f.insts[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "inst")
}
fa_by_bridge :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<f.inst_n { if f.insts[i].bridge_id == bridge_id do append(&out, f.insts[i]) }
	return out[:], {}
}
// Per-agent GLOBAL monotonic counter. UPSERT semantics (counter+1); persisted in
// f.counters so it survives service re-creation ("restart").
fa_next_counter :: proc(ctx: rawptr, agent_id: string, owner: domain.User_ID, now: string) -> (int, bool, domain.Domain_Error) {
	n := f.counters[agent_id] + 1
	f.counters[agent_id] = n
	return n, true, {}
}

fsink :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	f.cmds[f.cmd_n] = strings.clone(cmd.body_json); f.cmd_n += 1; return true, {}
}

cmds_with :: proc(needle: string) -> int {
	n := 0
	for i in 0..<f.cmd_n { if strings.contains(f.cmds[i], needle) do n += 1 }
	return n
}

// Global homes so repo/clock/id addresses stay valid for the service lifetime.
content_repo: iface.Content_Repository
tc_repo: iface.Taskchain_Repository
ag_repo: iface.Agent_Repository
clk: platform.Clock
idg: platform.ID_Generator

wire_repos :: proc() {
	content_repo = iface.Content_Repository{ctx = nil, save_conversation = fc_save_convo, get_conversation = fc_get_convo, list_conversations = fc_list_convos, save_message = fc_save_msg, list_user_visible_messages = fc_list_user_visible, list_messages = fc_list_messages}
	tc_repo = iface.Taskchain_Repository{ctx = nil, get_chain = ft_get_chain, save_chain = ft_save_chain, list_chains_by_owner = ft_list_chains, save_member = ft_save_member, list_members_by_chain = ft_list_members}
	ag_repo = iface.Agent_Repository{ctx = nil, get = fa_get, get_instance = fa_get_inst, list_instances_by_bridge = fa_by_bridge, next_title_counter = fa_next_counter}
	clk = platform.Clock{ctx = nil, now = fnow}
	idg = platform.ID_Generator{ctx = nil, generate = fid}
}

@(test)
test_hub_ct_title_lifecycle :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	f.counters = make(map[string]int)
	f.now = "2026-07-22T10:00:00Z"
	wire_repos()

	test_counter_and_default_title()
	test_evaluate_gate_pure()
	test_record_activity_wiring()
	test_nudge_without_user_message()
	test_agent_to_agent_triggers_nudge()
	test_set_title_marks_source()
	test_normalize_title_source()
	test_conversation_title_from_input()

	fmt.println("PASS: hub CT title lifecycle (counter, default title, activity-gating, guardrails, set-title source)")
}

// --- PS-7: conversation title is never derived from initial message body -----
test_conversation_title_from_input :: proc() {
	default_title := "Reviewer #7"
	check(content_service.conversation_title_from_input("", default_title) == default_title,
		"no explicit title -> falls back to the per-run default, NEVER the initial message body")
	title_no_explicit := content_service.conversation_title_from_input("", default_title)
	check(!strings.contains(title_no_explicit, "investigate"),
		"initial body text must not leak into the title")
	check(content_service.conversation_title_from_input("  My   Chat  ", default_title) == "My Chat",
		"explicit title is honored (whitespace-normalized)")
	check(content_service.conversation_title_from_input("", "") == "",
		"empty explicit + empty fallback yields empty (caller supplies default)")
}

// --- REQ-1/REQ-2: per-agent global counter + "<name> #n" default title ------
test_counter_and_default_title :: proc() {
	f = F{counters = make(map[string]int), now = "2026-07-22T10:00:00Z"}
	svc := agent_service.new_agent_service(&ag_repo, nil, &clk, &idg)

	agt_x := domain.Agent{agent_id = "agt_x", owner_user_id = "alice", name = "Reviewer"}
	agt_y := domain.Agent{agent_id = "agt_y", owner_user_id = "alice", name = "Coder"}

	// agt_x increments 1,2,3 across "runs".
	check(agent_service.default_title_for_agent(&svc, "alice", agt_x) == "Reviewer #1", "first run title is '<name> #1'")
	check(agent_service.default_title_for_agent(&svc, "alice", agt_x) == "Reviewer #2", "second run increments to #2")
	check(agent_service.default_title_for_agent(&svc, "alice", agt_x) == "Reviewer #3", "third run increments to #3")
	// agt_y is INDEPENDENT (starts at 1).
	check(agent_service.default_title_for_agent(&svc, "alice", agt_y) == "Coder #1", "per-agent counter is independent: agt_y starts at #1")

	// "Restart": a brand-new service over the SAME persisted counter store keeps counting.
	svc2 := agent_service.new_agent_service(&ag_repo, nil, &clk, &idg)
	check(agent_service.default_title_for_agent(&svc2, "alice", agt_x) == "Reviewer #4", "counter survives restart: agt_x continues at #4")

	// Never emit a raw agt_ id: empty name -> "Agent"; slug fallback when name empty.
	agt_blank := domain.Agent{agent_id = "agt_blank", owner_user_id = "alice"}
	check(agent_service.default_title_for_agent(&svc2, "alice", agt_blank) == "Agent #1", "empty name falls back to 'Agent' (never a raw agt_ id)")
	agt_slug := domain.Agent{agent_id = "agt_slug", owner_user_id = "alice", slug = "helper-bot"}
	check(agent_service.default_title_for_agent(&svc2, "alice", agt_slug) == "helper-bot #1", "empty name falls back to slug")
}

// --- REQ-4/5/6: pure gate semantics ----------------------------------------
test_evaluate_gate_pure :: proc() {
	HOUR :: i64(3600) * 1000
	base := i64(1_000_000)

	// No activity yet (empty conversation) -> gated.
	d := content_service.evaluate_title_nudge("default", false, base, 0, base, 3600)
	check(!d.should_nudge && d.reason == "no_activity", "no activity gates the nudge (empty conversation)")

	// First activity (any direction), never nudged -> fires. No human required.
	d = content_service.evaluate_title_nudge("default", true, base, 0, base, 3600)
	check(d.should_nudge, "first activity fires the first nudge (no user message required)")

	// Already nudged, NO new activity (activity <= last nudge) -> no re-nudge.
	d = content_service.evaluate_title_nudge("default", true, base, base, base + 2*HOUR, 3600)
	check(!d.should_nudge && d.reason == "no_new_activity", "re-nudge requires NEW activity since last nudge")

	// New activity but cooldown NOT elapsed -> gated by cooldown.
	d = content_service.evaluate_title_nudge("default", true, base + 10*1000, base, base + 30*1000, 3600)
	check(!d.should_nudge && d.reason == "cooldown", "re-nudge blocked until cooldown elapses")

	// New activity AND cooldown elapsed -> re-nudge fires.
	d = content_service.evaluate_title_nudge("default", true, base + 10*1000, base, base + 2*HOUR, 3600)
	check(d.should_nudge, "re-nudge fires with new activity + cooldown elapsed")

	// Guardrails: any non-default title stops nudges forever (agent AND user).
	d = content_service.evaluate_title_nudge("agent", true, base + 10*1000, base, base + 5*HOUR, 3600)
	check(!d.should_nudge && d.reason == "non_default_title", "agent-set title stops nudges")
	d = content_service.evaluate_title_nudge("user", true, base + 10*1000, base, base + 5*HOUR, 3600)
	check(!d.should_nudge && d.reason == "non_default_title", "user-set title stops nudges (wins forever)")

	// cooldown<=0 falls back to the 1h default (still gated at 30s).
	d = content_service.evaluate_title_nudge("default", true, base + 10*1000, base, base + 30*1000, 0)
	check(!d.should_nudge && d.reason == "cooldown", "non-positive cooldown falls back to the 1h default")
}

// --- REQ-4/5/6 wiring: exactly ONE nudge on first exchange, no double-ping --
test_record_activity_wiring :: proc() {
	f = F{counters = make(map[string]int), now = "2026-07-22T10:00:00Z"}
	cs := content_service.new_content_service_with_runtime(&content_repo, &ag_repo, nil, nil, &tc_repo, project_service.Bridge_Command_Sink{ctx = nil, send_runtime_command = fsink}, &clk, &idg)
	cs.title_nudge_cooldown_seconds = 3600

	// Conversation bound to inst_c on brg_c, chain chain_c, title still default.
	// REQ-TN-B/D: the nudge goes to the chain COORDINATOR and only while it is
	// live, so the fixture names inst_c as coordinator with a running process.
	f.chains[0] = domain.Task_Chain{chain_id = "chain_c", owner_user_id = "alice", title = "Coder #1", title_source = "default", coordinator_agent_instance_id = "inst_c"}
	f.chain_n = 1
	f.insts[0] = domain.Agent_Instance{agent_instance_id = "inst_c", owner_user_id = "alice", chain_id = "chain_c", bridge_id = "brg_c", runtime_status = "running"}
	f.inst_n = 1
	f.convos[0] = domain.Chat_Conversation{conversation_id = "chat_c", owner_user_id = "alice", agent_id = "agt_c", agent_instance_id = "inst_c", chain_id = "chain_c", title = "Coder #1", title_source = "default"}
	f.convo_n = 1

	// Empty conversation (zero messages): no nudge.
	f.msg_n = 0
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_c", "2026-07-22T10:00:00Z")
	check(cmds_with("notify_title_nudge") == 0, "no nudge for a completely empty conversation")

	// A SINGLE user->agent message is enough activity -> exactly ONE nudge (TN-1/2:
	// no two-way exchange, no agent reply required).
	f.msgs[0] = domain.Chat_Message{message_id = "m1", conversation_id = "chat_c", owner_user_id = "alice", direction = "user_to_agent", body = "hi"}
	f.msg_n = 1
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_c", "2026-07-22T10:01:00Z")
	check(cmds_with("notify_title_nudge") == 1, "first activity (one message, no exchange) fires EXACTLY one title nudge")
	check(cmds_with("inst_c") == 1 && cmds_with("chat_c") == 1 && cmds_with("chain_c") == 1, "nudge targets the owning instance + carries conversation/chain ids")

	// last_title_nudge_at stamped on the chain (chain-only nudges, REQ-TN-A);
	// the conversation only tracks activity.
	cc, _, _ := fc_get_convo(nil, "chat_c")
	ch, _, _ := ft_get_chain(nil, "chain_c")
	check(cc.last_activity_at == "2026-07-22T10:01:00Z", "last_activity_at stamped on conversation")
	check(ch.last_title_nudge_at == "2026-07-22T10:01:00Z", "last_title_nudge_at stamped on chain")

	// Immediate re-call: activity moves but cooldown NOT elapsed -> no second ping.
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_c", "2026-07-22T10:02:00Z")
	check(cmds_with("notify_title_nudge") == 0, "no double-ping: re-nudge blocked by cooldown right after the first")

	// After the cooldown (>1h later) WITH new activity -> re-nudge fires once.
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_c", "2026-07-22T11:30:00Z")
	check(cmds_with("notify_title_nudge") == 1, "re-nudge fires after cooldown + new activity")

	// Agent sets the CHAIN title (source=agent): all further nudges stop forever.
	// The gate reads the chain's title_source (chain-only nudges, REQ-TN-A).
	ch2, _, _ := ft_get_chain(nil, "chain_c")
	ch2.title = "Fix login bug"; ch2.title_source = "agent"
	ft_save_chain(nil, ch2)
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_c", "2026-07-22T13:00:00Z")
	check(cmds_with("notify_title_nudge") == 0, "a non-default (agent-set) title stops all further nudges")
}

// --- TN-5 (i): a nudge fires with NO user message present -------------------
// An agent that only ever emits agent_to_user output (never received a human
// message) must still be nudged once.
test_nudge_without_user_message :: proc() {
	f = F{counters = make(map[string]int), now = "2026-07-22T10:00:00Z"}
	cs := content_service.new_content_service_with_runtime(&content_repo, &ag_repo, nil, nil, &tc_repo, project_service.Bridge_Command_Sink{ctx = nil, send_runtime_command = fsink}, &clk, &idg)
	cs.title_nudge_cooldown_seconds = 3600

	f.chains[0] = domain.Task_Chain{chain_id = "chain_u", owner_user_id = "alice", title = "Coder #1", title_source = "default", coordinator_agent_instance_id = "inst_u"}
	f.chain_n = 1
	f.insts[0] = domain.Agent_Instance{agent_instance_id = "inst_u", owner_user_id = "alice", chain_id = "chain_u", bridge_id = "brg_u", runtime_status = "running"}
	f.inst_n = 1
	f.convos[0] = domain.Chat_Conversation{conversation_id = "chat_u", owner_user_id = "alice", agent_id = "agt_u", agent_instance_id = "inst_u", chain_id = "chain_u", title = "Coder #1", title_source = "default"}
	f.convo_n = 1

	// ONLY an agent_to_user message — no user_to_agent at all.
	f.msgs[0] = domain.Chat_Message{message_id = "u1", conversation_id = "chat_u", owner_user_id = "alice", direction = "agent_to_user", body = "starting work"}
	f.msg_n = 1
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_u", "2026-07-22T10:00:05Z")
	check(cmds_with("notify_title_nudge") == 1, "nudge fires with NO user message present (agent output alone)")
	check(cmds_with("inst_u") == 1, "nudge targets the owning instance")
}

// --- TN-5 (ii): agent_to_agent activity triggers a nudge --------------------
// An agent created by another agent sees only agent_to_agent traffic; it must
// still be nudged (TN-3 wires the agent<->agent path).
test_agent_to_agent_triggers_nudge :: proc() {
	f = F{counters = make(map[string]int), now = "2026-07-22T10:00:00Z"}
	cs := content_service.new_content_service_with_runtime(&content_repo, &ag_repo, nil, nil, &tc_repo, project_service.Bridge_Command_Sink{ctx = nil, send_runtime_command = fsink}, &clk, &idg)
	cs.title_nudge_cooldown_seconds = 3600

	f.chains[0] = domain.Task_Chain{chain_id = "chain_a", owner_user_id = "alice", title = "Coder #1", title_source = "default", coordinator_agent_instance_id = "inst_a"}
	f.chain_n = 1
	f.insts[0] = domain.Agent_Instance{agent_instance_id = "inst_a", owner_user_id = "alice", chain_id = "chain_a", bridge_id = "brg_a", runtime_status = "running"}
	f.inst_n = 1
	f.convos[0] = domain.Chat_Conversation{conversation_id = "chat_a", owner_user_id = "alice", agent_id = "agt_a", agent_instance_id = "inst_a", chain_id = "chain_a", title = "Coder #1", title_source = "default"}
	f.convo_n = 1

	// ONLY an agent_to_agent message (agent created by another agent).
	f.msgs[0] = domain.Chat_Message{message_id = "a1", conversation_id = "chat_a", owner_user_id = "alice", direction = "agent_to_agent", body = "peer ping"}
	f.msg_n = 1
	f.cmd_n = 0
	content_service.record_activity_and_maybe_nudge(&cs, "chat_a", "2026-07-22T10:00:05Z")
	check(cmds_with("notify_title_nudge") == 1, "agent_to_agent activity alone triggers a nudge")
	check(cmds_with("inst_a") == 1, "nudge targets the owning instance")
}

// --- REQ-3 / T3: set-title marks title_source='agent' + auth ----------------
test_set_title_marks_source :: proc() {
	f = F{counters = make(map[string]int), now = "2026-07-22T10:00:00Z"}
	cs := content_service.new_content_service(&content_repo, &ag_repo, nil, nil, &tc_repo, &clk, &idg)
	ts := taskchain_service.new_taskchain_service(&tc_repo, &ag_repo, &clk, &idg)

	// Chain where inst_o is the coordinator (so it can rename its own chain).
	f.chains[0] = domain.Task_Chain{chain_id = "chain_o", owner_user_id = "alice", publish_state = .Published, status = .Active, title = "Reviewer #1", title_source = "default"}
	f.chain_n = 1
	f.members[0] = domain.Task_Chain_Member{chain_id = "chain_o", agent_instance_id = "inst_o", owner_user_id = "alice", role = "coordinator"}
	f.member_n = 1
	f.insts[0] = domain.Agent_Instance{agent_instance_id = "inst_o", owner_user_id = "alice", chain_id = "chain_o", bridge_id = "brg_o"}
	f.inst_n = 1
	f.convos[0] = domain.Chat_Conversation{conversation_id = "chat_o", owner_user_id = "alice", agent_id = "agt_o", agent_instance_id = "inst_o", chain_id = "chain_o", title = "Reviewer #1", title_source = "default"}
	f.convo_n = 1

	inst_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_o"}

	// Conversation set-title marks title_source='agent'.
	conv, ok, err := content_service.set_own_conversation_title(&cs, inst_auth, "inst_o", "Investigate flaky test")
	check(ok, fmt.tprintf("set_own_conversation_title ok: %s", err.message))
	check(conv.title == "Investigate flaky test" && conv.title_source == "agent", "agent set-title stamps conversation title + title_source='agent'")

	// Chain set-title marks title_source='agent'.
	chn, ok2, err2 := taskchain_service.set_own_chain_title(&ts, inst_auth, "chain_o", "Flaky test investigation")
	check(ok2, fmt.tprintf("set_own_chain_title ok: %s", err2.message))
	check(chn.title == "Flaky test investigation" && chn.title_source == "agent", "agent set-title stamps chain title + title_source='agent'")

	// Auth: a non-instance (user) token cannot use the agent set-title verbs.
	user_auth := contracts.Auth_Context{kind = .Session, user_id = "alice"}
	_, bad_ok, _ := content_service.set_own_conversation_title(&cs, user_auth, "inst_o", "nope")
	check(!bad_ok, "conversation set-title requires an instance token")
	_, bad_ok2, _ := taskchain_service.set_own_chain_title(&ts, user_auth, "chain_o", "nope")
	check(!bad_ok2, "chain set-title requires an instance token")

	// A mismatched instance token cannot rename another instance's conversation.
	other_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_other"}
	_, bad_ok3, _ := content_service.set_own_conversation_title(&cs, other_auth, "inst_o", "nope")
	check(!bad_ok3, "conversation set-title forbids a mismatched instance token")
}

// --- normalize_title_source clamps unknown -> default -----------------------
test_normalize_title_source :: proc() {
	check(content_sqlite.normalize_title_source("agent") == "agent", "agent preserved")
	check(content_sqlite.normalize_title_source("user") == "user", "user preserved")
	check(content_sqlite.normalize_title_source("default") == "default", "default preserved")
	check(content_sqlite.normalize_title_source("") == "default", "empty clamps to default")
	check(content_sqlite.normalize_title_source("garbage") == "default", "unknown clamps to default")
}
