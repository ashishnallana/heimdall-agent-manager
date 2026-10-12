package domain

// Built-in template bodies, compiled in from src/templates/*.md. These are the
// single source of truth for built-in template content: the template API and the
// bootstrap AGENTS.md both resolve built-in IDs here, so stale rows seeded into
// the templates table by older migrations (032) never shadow an edited .md file.
TEMPLATE_MD_COORDINATOR :: #load("../../templates/coordinator.md", string)
TEMPLATE_MD_WORKER :: #load("../../templates/worker.md", string)
TEMPLATE_MD_REVIEWER :: #load("../../templates/reviewer.md", string)
TEMPLATE_MD_SOLOIST :: #load("../../templates/soloist.md", string)
TEMPLATE_MD_EMPTY :: #load("../../templates/empty.md", string)

// builtin_template returns the built-in template for id, or ok = false when id is
// not a compiled-in template (curator is reserved but has no compiled body).
builtin_template :: proc(id: string) -> (Template, bool) {
	switch id {
	case TEMPLATE_COORDINATOR_ID:
		return Template{
			template_id = TEMPLATE_COORDINATOR_ID,
			is_system = true,
			name = "coordinator",
			description = "AI-native coordinator template for planning, delegation, and orchestration",
			persona = "You are an expert technical coordinator and orchestrator. You plan, delegate to specialized worker agents, track progress, enforce review gates, and synthesize outcomes.",
			instructions = TEMPLATE_MD_COORDINATOR,
		}, true
	case TEMPLATE_WORKER_ID:
		return Template{
			template_id = TEMPLATE_WORKER_ID,
			is_system = true,
			name = "worker",
			description = "AI-native worker template for focused implementation and task execution",
			persona = "You are a meticulous senior software engineer. You implement assigned tasks with clean, well-tested code following repository conventions and report step-by-step progress.",
			instructions = TEMPLATE_MD_WORKER,
		}, true
	case TEMPLATE_REVIEWER_ID:
		return Template{
			template_id = TEMPLATE_REVIEWER_ID,
			is_system = true,
			name = "reviewer",
			description = "AI-native reviewer template for independent verification and quality gatekeeping",
			persona = "You are a rigorous code reviewer and quality gatekeeper. You independently inspect diffs, verify acceptance criteria and test evidence, and enforce architectural integrity.",
			instructions = TEMPLATE_MD_REVIEWER,
		}, true
	case TEMPLATE_SOLOIST_ID:
		return Template{
			template_id = TEMPLATE_SOLOIST_ID,
			is_system = true,
			name = "soloist",
			description = "AI-native single-agent template: plans, implements, and verifies its own task-tracked work",
			persona = "You are a senior software engineer who owns work end to end. You plan with the user, implement and verify the work yourself, and track every step in tasks.",
			instructions = TEMPLATE_MD_SOLOIST,
		}, true
	case TEMPLATE_EMPTY_ID:
		return Template{
			template_id = TEMPLATE_EMPTY_ID,
			is_system = true,
			name = "empty",
			description = "Default empty template",
			persona = "",
			instructions = TEMPLATE_MD_EMPTY,
		}, true
	}
	return {}, false
}

// is_builtin_template_id reports whether id is reserved for a built-in template
// (including curator, which has no compiled body). Built-ins are always available
// and can never be edited or deleted.
is_builtin_template_id :: proc(id: string) -> bool {
	switch id {
	case TEMPLATE_EMPTY_ID, TEMPLATE_COORDINATOR_ID, TEMPLATE_WORKER_ID, TEMPLATE_REVIEWER_ID, TEMPLATE_SOLOIST_ID, TEMPLATE_CURATOR_ID:
		return true
	}
	return false
}
