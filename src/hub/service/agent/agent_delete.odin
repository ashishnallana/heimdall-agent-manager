package agent

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// AGENT_IN_USE_REASON is the `details.reason` of the 409 a delete answers with when
// something still refers to the agent; the UI keys its copy on it.
AGENT_IN_USE_REASON :: "agent_in_use"

// get_agent_usage reports what still refers to the caller's agent, so the UI can
// offer Delete only when the answer is "nothing".
get_agent_usage :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (domain.Agent_Usage, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent_Usage{}, false, err
	usage, usage_err := iface.agent_usage(service.agents, agent.agent_id)
	if usage_err.code != .None do return domain.Agent_Usage{}, false, usage_err
	return usage, true, {}
}

// delete_agent permanently removes an agent nothing refers to. An agent with any
// instance, conversation, chain, task, memory, action or workflow reference is
// refused with 409 (archive is the way to retire it). The repository re-checks
// the same references inside the DELETE statement, so a launch racing this call
// cannot leave an orphaned instance behind.
delete_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent{}, false, err
	usage, usage_err := iface.agent_usage(service.agents, agent.agent_id)
	if usage_err.code != .None do return domain.Agent{}, false, usage_err
	if domain.agent_usage_total(usage) > 0 do return domain.Agent{}, false, agent_in_use_error(usage)
	deleted, delete_err := iface.agent_delete_unused(service.agents, agent.agent_id, agent.owner_user_id)
	if delete_err.code != .None do return domain.Agent{}, false, delete_err
	if !deleted {
		// Something started referring to it after the check above.
		again, _ := iface.agent_usage(service.agents, agent.agent_id)
		return domain.Agent{}, false, agent_in_use_error(again)
	}
	return agent, true, {}
}

agent_in_use_error :: proc(usage: domain.Agent_Usage) -> domain.Domain_Error {
	details := fmt.tprintf(`{{"reason":"%s","usage":%s}}`, AGENT_IN_USE_REASON, agent_usage_json(usage))
	summary := agent_usage_summary(usage)
	message := "This agent is still in use, so it can't be deleted. Archive it instead."
	if summary != "" do message = fmt.tprintf("This agent is still in use (%s), so it can't be deleted. Archive it instead.", summary)
	return domain.domain_error(.Conflict, message, details)
}

// agent_usage_json renders the counts as the `usage` object of the usage endpoint
// and of the 409 details.
agent_usage_json :: proc(u: domain.Agent_Usage) -> string {
	return fmt.tprintf(
		`{{"instances":%d,"conversations":%d,"messages":%d,"artifacts":%d,"chains":%d,"tasks":%d,"memories":%d,"actions":%d,"workflows":%d}}`,
		u.instances, u.conversations, u.messages, u.artifacts, u.chains, u.tasks, u.memories, u.actions, u.workflows,
	)
}

// agent_usage_summary is "2 instances, 1 chain": the non-zero counts, in order.
agent_usage_summary :: proc(u: domain.Agent_Usage) -> string {
	b := strings.builder_make(context.temp_allocator)
	add :: proc(b: ^strings.Builder, n: int, one, many: string) {
		if n <= 0 do return
		if strings.builder_len(b^) > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "%d %s", n, one if n == 1 else many)
	}
	add(&b, u.instances, "instance", "instances")
	add(&b, u.conversations, "conversation", "conversations")
	add(&b, u.messages, "message", "messages")
	add(&b, u.artifacts, "artifact", "artifacts")
	add(&b, u.chains, "chain", "chains")
	add(&b, u.tasks, "task", "tasks")
	add(&b, u.memories, "memory", "memories")
	add(&b, u.actions, "action", "actions")
	add(&b, u.workflows, "workflow", "workflows")
	return strings.to_string(b)
}
