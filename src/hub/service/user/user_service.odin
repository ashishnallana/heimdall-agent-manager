package user

import "core:strings"
import "core:sync"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

User_Service :: struct {
 launch_preferences_mutex: sync.Mutex,
 bridges: ^iface.Bridge_Repository,
	users:    ^iface.User_Repository,
	// agents lets provisioning seed canonical durable agents ('coordinator', 'worker', 'reviewer', 'soloist')
	// for new users so first-time users always have agents to start. Optional (nil in tests that
	// only exercise user CRUD); seeding is skipped when nil.
	agents:   ^iface.Agent_Repository,
	// projects lets provisioning seed the dedicated 'Conversation' project for new users.
	// Optional (nil in tests); seeding is skipped when nil.
	projects: ^iface.Project_Repository,
	clock:    ^platform.Clock,
	ids:      ^platform.ID_Generator,
	// REQ-2: told about each canonical agent seeding saved (nil: no hint).
	on_agent_seeded:     proc(ctx: rawptr, owner_user_id, agent_id: string),
	on_agent_seeded_ctx: rawptr,
}

new_user_service_full :: proc(users: ^iface.User_Repository, agents: ^iface.Agent_Repository, projects: ^iface.Project_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> User_Service {
	return User_Service{users = users, agents = agents, projects = projects, clock = clock, ids = ids}
}

new_user_service_compat :: proc(users: ^iface.User_Repository, agents: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> User_Service {
	return User_Service{users = users, agents = agents, clock = clock, ids = ids}
}

new_user_service_basic :: proc(users: ^iface.User_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> User_Service {
	return User_Service{users = users, clock = clock, ids = ids}
}

new_user_service :: proc{new_user_service_full, new_user_service_compat, new_user_service_basic}

// COORDINATOR_AGENT_SLUG is the slug of the durable coordinator agent seeded for every user.
COORDINATOR_AGENT_SLUG :: "coordinator"
WORKER_AGENT_SLUG      :: "worker"
REVIEWER_AGENT_SLUG    :: "reviewer"
// SOLOIST_AGENT_SLUG is the single-agent-workflow identity: it coordinates its own task chain
// but does all the work itself, using tasks only to track it.
SOLOIST_AGENT_SLUG     :: "soloist"

CONVERSATION_PROJECT_SLUG :: "conversation"
CONVERSATION_PROJECT_NAME :: "Conversation"
CONVERSATION_PROJECT_DESCRIPTION :: `Dedicated environment for open-ended conversation, brainstorming, and ad-hoc reasoning.

- Purpose: Dedicated environment for open-ended conversation and brainstorming.
- Project Transition: If user queries or goals involve a specific software project, repository, or multi-step engineering task, proactively recommend creating or switching to a dedicated project and launching a coordinator agent to orchestrate the work.
- User Primacy: All recommendations require explicit user approval; user requests always trump best practices.`

Canonical_Agent_Spec :: struct {
	name:        string,
	slug:        string,
	template_id: string,
}

CANONICAL_AGENTS :: [4]Canonical_Agent_Spec{
	{name = COORDINATOR_AGENT_SLUG, slug = COORDINATOR_AGENT_SLUG, template_id = domain.TEMPLATE_COORDINATOR_ID},
	{name = WORKER_AGENT_SLUG,      slug = WORKER_AGENT_SLUG,      template_id = domain.TEMPLATE_WORKER_ID},
	{name = REVIEWER_AGENT_SLUG,    slug = REVIEWER_AGENT_SLUG,    template_id = domain.TEMPLATE_REVIEWER_ID},
	{name = SOLOIST_AGENT_SLUG,     slug = SOLOIST_AGENT_SLUG,     template_id = domain.TEMPLATE_SOLOIST_ID},
}

// ensure_canonical_resources seeds the 4 canonical durable agents (coordinator,
// worker, reviewer, soloist) and the dedicated Conversation project for owner if they do
// not exist yet. Idempotent and best-effort: provisioning a user must never fail
// because resource seeding did. No-op when the respective repositories are not wired.
ensure_canonical_resources :: proc(service: ^User_Service, owner: domain.User_ID) {
	if service == nil || service.clock == nil || service.ids == nil do return
	if string(owner) == "" do return

	now := platform.clock_now(service.clock)

	// 1. Seed canonical durable agents (coordinator, worker, reviewer, soloist)
	if service.agents != nil {
		existing, list_err := iface.agent_list_by_owner(service.agents, owner, 200, "")
		if list_err.code == .None {
			defer delete(existing)
			for spec in CANONICAL_AGENTS {
				found := false
				for a in existing {
					if a.slug == spec.slug {
						found = true
						break
					}
				}
				if !found {
					agent := domain.Agent{
						agent_id = platform.generate_id(service.ids, "agt_"),
						owner_user_id = owner,
						name = spec.name,
						slug = spec.slug,
						template_id = spec.template_id,
						state = .Active,
						created_at = now,
						updated_at = now,
					}
					if _, seeded, _ := iface.agent_save(service.agents, agent); seeded && service.on_agent_seeded != nil {
						service.on_agent_seeded(service.on_agent_seeded_ctx, string(owner), agent.agent_id)
					}
				}
			}
		}
	}

	// 2. Seed dedicated Conversation project
	if service.projects != nil {
		existing_projects, proj_err := iface.project_list_by_owner(service.projects, owner, 200, "")
		if proj_err.code == .None {
			defer delete(existing_projects)
			found_conversation := false
			for p in existing_projects {
				if p.slug == CONVERSATION_PROJECT_SLUG {
					found_conversation = true
					break
				}
			}
			if !found_conversation {
				project := domain.Project{
					project_id = domain.Project_ID(platform.generate_id(service.ids, "proj_")),
					owner_user_id = owner,
					name = CONVERSATION_PROJECT_NAME,
					slug = CONVERSATION_PROJECT_SLUG,
					description = CONVERSATION_PROJECT_DESCRIPTION,
					repo_url = "",
					vcs_kind = "",
					default_path = "",
					created_at = now,
					updated_at = now,
				}
				iface.project_save(service.projects, project)
			}
		}
	}
	// Persist seeded identities as pinned independently of their editable names.
	if service.users != nil && service.users.launch_preferences_get != nil {
		lock_tok := dbt.timed_lock(&service.launch_preferences_mutex, .Launch_Prefs)
		if prefs, err := launch_preferences_read(service, string(owner)); err.code == .None { _, _ = launch_preferences_write(service, string(owner), prefs) }
		dbt.timed_unlock(&service.launch_preferences_mutex, .Launch_Prefs, lock_tok)
	}

}

get_user :: proc(service: ^User_Service, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	if string(user_id) == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "user_id is required")
	}
	return iface.user_get_by_id(service.users, user_id)
}

Create_User_Input :: struct {
	name: string,
	email: string,
	display_name: string,
}

// create_user is the explicit user-creation path used by `ham-hub users create`.
// name AND email are mandatory. The user_id is operator-independent: a fresh
// `usr_...` id is generated so issuance never depends on caller-supplied input.
create_user :: proc(service: ^User_Service, input: Create_User_Input) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.clock == nil || service.ids == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	name := strings.trim_space(input.name)
	email := strings.trim_space(input.email)
	if name == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "name is required")
	}
	if email == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "email is required")
	}
	display := strings.trim_space(input.display_name)
	if display == "" do display = name
	now := platform.clock_now(service.clock)
	user_id := platform.generate_id(service.ids, "usr_")
	created := domain.User{
		user_id = domain.User_ID(user_id),
		name = name,
		display_name = display,
		email = email,
		status = .Active,
		created_at = now,
		updated_at = now,
	}
	saved, ok, save_err := iface.user_save(service.users, created)
	if !ok do return saved, ok, save_err
	ensure_canonical_resources(service, saved.user_id)
	return saved, ok, save_err
}

ensure_user_from_auth :: proc(service: ^User_Service, user_id, display_name, email: string, auto_provision: bool) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.clock == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	normalized := normalize_user_id(user_id)
	if normalized == "" {
		return domain.User{}, false, domain.domain_error(.Unauthenticated, "user identity is missing")
	}
	found, ok, err := iface.user_get_by_id(service.users, domain.User_ID(normalized))
	if ok {
		if found.status == .Disabled {
			return domain.User{}, false, domain.domain_error(.Forbidden, "user is disabled")
		}
		return found, true, domain.Domain_Error{}
	}
	if err.code != .Not_Found {
		return domain.User{}, false, err
	}
	if !auto_provision {
		return domain.User{}, false, domain.domain_error(.Not_Found, "user not found")
	}
	name := normalized
	display := strings.trim_space(display_name)
	if display == "" do display = name
	now := platform.clock_now(service.clock)
	created := domain.User{
		user_id = domain.User_ID(normalized),
		name = name,
		display_name = display,
		email = strings.trim_space(email),
		status = .Active,
		created_at = now,
		updated_at = now,
	}
	saved, saved_ok, save_err := iface.user_save(service.users, created)
	if !saved_ok do return saved, saved_ok, save_err
	ensure_canonical_resources(service, saved.user_id)
	return saved, saved_ok, save_err
}

normalize_user_id :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	builder := strings.builder_make()
	for ch in trimmed {
		switch ch {
		case 'A'..='Z': strings.write_rune(&builder, ch + 32)
		case 'a'..='z', '0'..='9', '_', '-', '.', '@': strings.write_rune(&builder, ch)
		case ' ', '\t': strings.write_rune(&builder, '-')
		case:
			// Drop unsupported characters rather than trusting caller-supplied IDs verbatim.
		}
	}
	return strings.to_string(builder)
}
