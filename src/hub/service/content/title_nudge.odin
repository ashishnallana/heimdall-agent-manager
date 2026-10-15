package content

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// Activity-gated, CHAIN-scoped title-nudge engine (REQ-4,5,6; TN-1..TN-5;
// REQ-TN-A..D).
//
// A freshly-launched run gets a DEFAULT chain title "<agent-name> #<n>" (T1).
// Once any conversation in the chain has seen real activity (a message in any
// direction — including agent<->agent, so agents created by other agents are
// covered), we ask the chain's COORDINATOR to set a human-meaningful chain title.
// The nudge does NOT wait for a human to get involved. We do NOT build a new
// notifier: the nudge is delivered over the SAME bridge runtime command path used
// by notify_agent_message, so it reuses existing wake/delivery/coalescing.
//
// Conversation titles are deprecated (REQ-TN-A): the gate reads and stamps only
// the chain's title_source / last_activity_at / last_title_nudge_at, and a
// conversation with no chain is never nudged. Workers and reviewers are never
// nudged (REQ-TN-B) — only the coordinator owns the chain title.
//
// Re-nudge is heavily gated so we never spam:
//   - the chain title_source must still be "default" (agent- or user-set titles stop us);
//   - there must be NEW activity since the last nudge (last_activity_at moved);
//   - at least `cooldown` seconds must have elapsed since last_title_nudge_at.
//
// A nudge is only stamped once it has been handed to a LIVE coordinator
// (REQ-TN-D). The first message of a conversation lands while the agent is still
// launching; a nudge sent then was dropped on the bridge yet still stamped, which
// burned the first nudge and armed the cooldown. Skipping without stamping lets the
// next activity retry once the coordinator is up.

// DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS is the fallback cooldown (1 hour) between
// re-nudges for the same chain. Config-tunable via Hub_Config.
DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS :: 3600

// TITLE_NUDGE_MESSAGE is the notice the coordinator sees. It names only the chain
// verb: conversation titles are deprecated (REQ-TN-C).
TITLE_NUDGE_MESSAGE :: "Please set a short, human-meaningful title for this task chain: ham-ctl task-chain set-title \"<title>\""

// Title_Nudge_Decision is the pure output of evaluating one chain.
Title_Nudge_Decision :: struct {
	should_nudge: bool,
	reason:       string, // "" when should_nudge, else why it was skipped
}

// evaluate_title_nudge is pure + clock-injectable so it is trivially testable.
// Every input describes the CHAIN, except has_activity (see below).
//   - title_source:    the chain's "default" | "agent" | "user"
//   - has_activity:    the conversation that triggered evaluation has at least one
//                      real message, in ANY direction (user_to_agent, agent_to_user,
//                      agent_to_agent). A human message is NOT required (TN-1/TN-2).
//   - last_activity_ms: the chain's most recent meaningful activity (unix ms; 0 = none)
//   - last_nudge_ms:   time of the chain's previous nudge (unix ms; 0 = never nudged)
//   - now_ms:          current time (unix ms)
//   - cooldown_seconds: minimum gap between re-nudges
evaluate_title_nudge :: proc(title_source: string, has_activity: bool, last_activity_ms, last_nudge_ms, now_ms: i64, cooldown_seconds: int) -> Title_Nudge_Decision {
	// Guardrail: user-set title wins forever; any non-default title stops nudges.
	if title_source != "default" do return Title_Nudge_Decision{should_nudge = false, reason = "non_default_title"}
	// Gate on agent ACTIVITY alone: the conversation must have had at least one
	// real message (any direction). Never nudge a completely empty conversation.
	if !has_activity do return Title_Nudge_Decision{should_nudge = false, reason = "no_activity"}
	// First nudge fires as soon as any activity exists.
	if last_nudge_ms <= 0 do return Title_Nudge_Decision{should_nudge = true, reason = ""}
	// Re-nudge only when there is NEW activity since the last nudge.
	if last_activity_ms <= last_nudge_ms do return Title_Nudge_Decision{should_nudge = false, reason = "no_new_activity"}
	// ...and only after the cooldown has elapsed.
	cooldown := cooldown_seconds
	if cooldown <= 0 do cooldown = DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS
	if now_ms - last_nudge_ms < i64(cooldown) * 1000 do return Title_Nudge_Decision{should_nudge = false, reason = "cooldown"}
	return Title_Nudge_Decision{should_nudge = true, reason = ""}
}

// title_nudge_coordinator_instance picks the chain coordinator to nudge (REQ-TN-B):
// the earliest-designated coordinator member (members are ordered by created_at
// ASC, as taskchain.coordinator_primary_instance relies on), falling back to the
// chain's derived coordinator mirror column. Returns "" when the chain has none.
title_nudge_coordinator_instance :: proc(members: []domain.Task_Chain_Member, mirror_instance_id: string) -> string {
	for m in members {
		if m.role == "coordinator" && m.agent_instance_id != "" do return m.agent_instance_id
	}
	return mirror_instance_id
}

// title_nudge_target_is_live reports whether the coordinator can receive a nudge
// right now (REQ-TN-D): it must be bound to a bridge and have a running process.
// "launching"/"starting" are deliberately excluded — that is exactly the window in
// which a nudge used to be dropped. Mirrors taskchain.instance_is_live.
title_nudge_target_is_live :: proc(inst: domain.Agent_Instance) -> bool {
	if inst.bridge_id == "" do return false
	return inst.runtime_status == "running" || inst.runtime_status == "idle" || inst.runtime_status == "busy"
}

// conversation_has_any_activity reports whether the conversation has had at least
// one real message in ANY direction (user_to_agent, agent_to_user, or
// agent_to_agent) that is not a system lifecycle message. A human message is NOT
// required (TN-2): agents that only ever talk to other agents — e.g. an agent
// created by another agent — still count as active. A conversation with zero
// non-system messages returns false so it is never nudged on startup boilerplate alone.
conversation_has_any_activity :: proc(s: ^Content_Service, c: domain.Chat_Conversation) -> bool {
	if s == nil || s.content == nil do return false
	// Fetch up to 10 recent messages across all directions and check for at least one non-system message.
	rows, err := iface.content_list_messages(s.content, c.conversation_id, c.owner_user_id, 10, "")
	if err.code != .None do return false
	for m in rows {
		if m.message_type != "system" do return true
	}
	return false
}

// record_activity_and_maybe_nudge stamps last_activity_at on the conversation (and
// its chain), then evaluates the chain's title-nudge gate and, if it fires and the
// coordinator is live, delivers a single nudge to the coordinator and stamps the
// chain's last_title_nudge_at. Best-effort: any repo/bridge failure is swallowed so
// it never blocks the caller's primary message flow. `now` is the caller's clock
// timestamp (already stamped onto the message/conversation).
record_activity_and_maybe_nudge :: proc(s: ^Content_Service, conversation_id: string, now: string) {
	if s == nil || s.content == nil do return
	c, ok, _ := iface.content_get_conversation(s.content, conversation_id)
	if !ok do return

	// 1) Track activity: bump last_activity_at on the conversation and its chain.
	c.last_activity_at = now
	c.updated_at = now
	iface.content_save_conversation(s.content, c)
	// Conversation titles are deprecated: a conversation outside any chain has no
	// title to nudge for (REQ-TN-A).
	if c.chain_id == "" || s.taskchains == nil do return
	chain, chain_ok, _ := iface.taskchain_get_chain(s.taskchains, domain.Task_Chain_ID(c.chain_id))
	if !chain_ok do return
	chain.last_activity_at = now
	chain.updated_at = now
	if saved, saved_ok, _ := iface.taskchain_save_chain(s.taskchains, chain); saved_ok do chain = saved

	// 2) Evaluate the CHAIN's nudge gate. Eligibility is agent ACTIVITY alone — any
	// real message in the conversation (no human required).
	has_activity := conversation_has_any_activity(s, c)
	now_ms, _ := platform_rfc3339_to_unix_ms(now)
	last_activity_ms, _ := platform_rfc3339_to_unix_ms(chain.last_activity_at)
	last_nudge_ms, _ := platform_rfc3339_to_unix_ms(chain.last_title_nudge_at)
	decision := evaluate_title_nudge(chain.title_source, has_activity, last_activity_ms, last_nudge_ms, now_ms, s.title_nudge_cooldown_seconds)
	if !decision.should_nudge do return

	// 3) Resolve the coordinator; skip WITHOUT stamping unless it is live (REQ-TN-B/D).
	if s.agents == nil do return
	members, members_err := iface.taskchain_list_members_by_chain(s.taskchains, chain.chain_id, chain.owner_user_id)
	if members_err.code != .None do return
	target_id := title_nudge_coordinator_instance(members, chain.coordinator_agent_instance_id)
	if target_id == "" do return
	inst, inst_ok, _ := iface.agent_get_instance(s.agents, target_id)
	if !inst_ok || !title_nudge_target_is_live(inst) do return

	// 4) Deliver ONE nudge; stamp the chain only when the bridge accepted it.
	if !deliver_title_nudge(s, inst, string(chain.chain_id)) do return
	chain.last_title_nudge_at = now
	chain.updated_at = now
	iface.taskchain_save_chain(s.taskchains, chain)
}

// deliver_title_nudge sends a single title-nudge runtime command to the chain
// coordinator's bridge, reusing the existing gated-notification path (same
// bridge_command_send_runtime used by notify_agent_message). The coordinator is
// expected to respond with `ham-ctl task-chain set-title`. conversation_id is the
// coordinator's own conversation: the bridge only needs agent_instance_id, but the
// field stays populated for wire compatibility. Returns whether the bridge
// command sink accepted the command.
deliver_title_nudge :: proc(s: ^Content_Service, inst: domain.Agent_Instance, chain_id: string) -> bool {
	if s == nil || s.bridge_command_sink.send_runtime_command == nil do return false
	if inst.bridge_id == "" || inst.agent_instance_id == "" do return false
	conversation_id := ""
	if c, ok, _ := get_conversation_by_instance(s, contracts.Auth_Context{kind = .User_Token, user_id = string(inst.owner_user_id)}, inst.agent_instance_id); ok do conversation_id = c.conversation_id
	command_id := platform.generate_id(s.ids, "cmd_")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"type\":\"notify_title_nudge\",\"command_id\":\"")
	content_json_write(&b, command_id)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	content_json_write(&b, inst.bridge_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	content_json_write(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"conversation_id\":\"")
	content_json_write(&b, conversation_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	content_json_write(&b, chain_id)
	strings.write_string(&b, "\",\"message\":\"")
	content_json_write(&b, TITLE_NUDGE_MESSAGE)
	strings.write_string(&b, "\"}")
	sent, _ := project_service.bridge_command_send_runtime(s.bridge_command_sink, project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = command_id, body_json = strings.to_string(b)})
	return sent
}

// platform_rfc3339_to_unix_ms parses the hub's canonical "YYYY-MM-DDTHH:MM:SSZ"
// UTC timestamp into unix milliseconds. Returns ok=false for empty/malformed input
// so callers treat it as "unknown/never".
//
// DELEGATES to platform.rfc3339_to_unix_ms (REQ-SHELL-9 boy-scout). This body was a
// character-for-character copy of the agent service's, and its own comment explained
// why — "kept local to the content package to avoid a cross-service dependency". That
// constraint was real and it is now gone: the parser lives in platform, which this
// package already imports, so there is no cross-SERVICE dependency to avoid.
//
// ONE BEHAVIOUR CHANGE, deliberate: the local copy accepted a 19-character timestamp
// and the agent service's required 20, so a value missing its trailing Z parsed here
// and not there. The shared proc takes the stricter reading. Every timestamp this
// package reads is produced by platform.clock_now and is exactly 20 characters, so the
// laxer check only ever admitted input the hub does not generate.
platform_rfc3339_to_unix_ms :: proc(s: string) -> (i64, bool) {
	return platform.rfc3339_to_unix_ms(s)
}
