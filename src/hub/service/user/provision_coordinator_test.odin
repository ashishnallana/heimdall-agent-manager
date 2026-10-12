package user

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// In-memory user, agent, and project stores so provisioning can be exercised without sqlite.
User_Store :: struct {
	users: [dynamic]domain.User,
}

fake_user_get_by_id :: proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	store := cast(^User_Store)ctx
	for u in store.users do if u.user_id == id do return u, true, {}
	return domain.User{}, false, domain.domain_error(.Not_Found, "user not found")
}

fake_user_save :: proc(ctx: rawptr, u: domain.User) -> (domain.User, bool, domain.Domain_Error) {
	store := cast(^User_Store)ctx
	append(&store.users, u)
	return u, true, {}
}

Prov_Agent_Store :: struct {
	agents: [dynamic]domain.Agent,
}

fake_prov_agent_save :: proc(ctx: rawptr, a: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Prov_Agent_Store)ctx
	append(&store.agents, a)
	return a, true, {}
}

fake_prov_agent_list_by_owner :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent, domain.Domain_Error) {
	store := cast(^Prov_Agent_Store)ctx
	out := make([dynamic]domain.Agent)
	for a in store.agents do if a.owner_user_id == owner do append(&out, a)
	return out[:], {}
}

Prov_Project_Store :: struct {
	projects: [dynamic]domain.Project,
}

fake_prov_project_save :: proc(ctx: rawptr, p: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	store := cast(^Prov_Project_Store)ctx
	append(&store.projects, p)
	return p, true, {}
}

fake_prov_project_list_by_owner :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Project, domain.Domain_Error) {
	store := cast(^Prov_Project_Store)ctx
	out := make([dynamic]domain.Project)
	for p in store.projects do if p.owner_user_id == owner do append(&out, p)
	return out[:], {}
}

count_agents_by_slug :: proc(store: ^Prov_Agent_Store, owner: domain.User_ID, slug: string) -> int {
	count := 0
	for a in store.agents do if a.owner_user_id == owner && a.slug == slug do count += 1
	return count
}

find_agent_by_slug :: proc(store: ^Prov_Agent_Store, owner: domain.User_ID, slug: string) -> (domain.Agent, bool) {
	for a in store.agents do if a.owner_user_id == owner && a.slug == slug do return a, true
	return domain.Agent{}, false
}

count_projects_by_slug :: proc(store: ^Prov_Project_Store, owner: domain.User_ID, slug: string) -> int {
	count := 0
	for p in store.projects do if p.owner_user_id == owner && p.slug == slug do count += 1
	return count
}

find_project_by_slug :: proc(store: ^Prov_Project_Store, owner: domain.User_ID, slug: string) -> (domain.Project, bool) {
	for p in store.projects do if p.owner_user_id == owner && p.slug == slug do return p, true
	return domain.Project{}, false
}

count_coordinators :: proc(store: ^Prov_Agent_Store, owner: domain.User_ID) -> int {
	return count_agents_by_slug(store, owner, COORDINATOR_AGENT_SLUG)
}

@(test)
test_provision_seeds_canonical_agents_and_conversation_project :: proc(t: ^testing.T) {
	ustore: User_Store
	urepo := iface.User_Repository{ctx = &ustore, get_by_id = fake_user_get_by_id, save = fake_user_save}
	astore: Prov_Agent_Store
	arepo := iface.Agent_Repository{ctx = &astore, save = fake_prov_agent_save, list_by_owner = fake_prov_agent_list_by_owner}
	pstore: Prov_Project_Store
	prepo := iface.Project_Repository{ctx = &pstore, save = fake_prov_project_save, list_by_owner = fake_prov_project_list_by_owner}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_user_service(&urepo, &arepo, &prepo, &clock, &ids)
	defer delete(ustore.users)
	defer delete(astore.agents)
	defer delete(pstore.projects)

	created, ok, err := ensure_user_from_auth(&service, "alice", "Alice", "", true)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	// Exactly 4 canonical agents seeded
	testing.expect_value(t, len(astore.agents), 4)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, COORDINATOR_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, WORKER_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, REVIEWER_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, SOLOIST_AGENT_SLUG), 1)

	// Canonical agent templates
	coord, coord_ok := find_agent_by_slug(&astore, created.user_id, COORDINATOR_AGENT_SLUG)
	testing.expect_value(t, coord_ok, true)
	testing.expect_value(t, coord.template_id, domain.TEMPLATE_COORDINATOR_ID)
	testing.expect_value(t, coord.name, COORDINATOR_AGENT_SLUG)

	worker, worker_ok := find_agent_by_slug(&astore, created.user_id, WORKER_AGENT_SLUG)
	testing.expect_value(t, worker_ok, true)
	testing.expect_value(t, worker.template_id, domain.TEMPLATE_WORKER_ID)
	testing.expect_value(t, worker.name, WORKER_AGENT_SLUG)

	reviewer, reviewer_ok := find_agent_by_slug(&astore, created.user_id, REVIEWER_AGENT_SLUG)
	testing.expect_value(t, reviewer_ok, true)
	testing.expect_value(t, reviewer.template_id, domain.TEMPLATE_REVIEWER_ID)
	testing.expect_value(t, reviewer.name, REVIEWER_AGENT_SLUG)

	soloist, soloist_ok := find_agent_by_slug(&astore, created.user_id, SOLOIST_AGENT_SLUG)
	testing.expect_value(t, soloist_ok, true)
	testing.expect_value(t, soloist.template_id, domain.TEMPLATE_SOLOIST_ID)
	testing.expect_value(t, soloist.name, SOLOIST_AGENT_SLUG)

	// Dedicated Conversation project seeded
	testing.expect_value(t, len(pstore.projects), 1)
	testing.expect_value(t, count_projects_by_slug(&pstore, created.user_id, CONVERSATION_PROJECT_SLUG), 1)
	proj, proj_ok := find_project_by_slug(&pstore, created.user_id, CONVERSATION_PROJECT_SLUG)
	testing.expect_value(t, proj_ok, true)
	testing.expect_value(t, proj.name, CONVERSATION_PROJECT_NAME)
	testing.expect_value(t, proj.slug, CONVERSATION_PROJECT_SLUG)
	testing.expect(t, strings.contains(proj.description, "Dedicated environment for open-ended conversation"), "description has dedicated environment")
	testing.expect(t, strings.contains(proj.description, "Purpose:"), "description has Purpose")
	testing.expect(t, strings.contains(proj.description, "Project Transition:"), "description has Project Transition")
	testing.expect(t, strings.contains(proj.description, "User Primacy:"), "description has User Primacy")
}

@(test)
test_ensure_canonical_resources_idempotent :: proc(t: ^testing.T) {
	astore: Prov_Agent_Store
	arepo := iface.Agent_Repository{ctx = &astore, save = fake_prov_agent_save, list_by_owner = fake_prov_agent_list_by_owner}
	pstore: Prov_Project_Store
	prepo := iface.Project_Repository{ctx = &pstore, save = fake_prov_project_save, list_by_owner = fake_prov_project_list_by_owner}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_user_service(nil, &arepo, &prepo, &clock, &ids)
	defer delete(astore.agents)
	defer delete(pstore.projects)

	ensure_canonical_resources(&service, "user_x")
	ensure_canonical_resources(&service, "user_x")

	testing.expect_value(t, len(astore.agents), 4)
	testing.expect_value(t, count_agents_by_slug(&astore, "user_x", COORDINATOR_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, "user_x", WORKER_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, "user_x", REVIEWER_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, "user_x", SOLOIST_AGENT_SLUG), 1)
	testing.expect_value(t, len(pstore.projects), 1)
	testing.expect_value(t, count_projects_by_slug(&pstore, "user_x", CONVERSATION_PROJECT_SLUG), 1)
}

@(test)
test_create_user_explicit_seeds_canonical_resources :: proc(t: ^testing.T) {
	ustore: User_Store
	urepo := iface.User_Repository{ctx = &ustore, get_by_id = fake_user_get_by_id, save = fake_user_save}
	astore: Prov_Agent_Store
	arepo := iface.Agent_Repository{ctx = &astore, save = fake_prov_agent_save, list_by_owner = fake_prov_agent_list_by_owner}
	pstore: Prov_Project_Store
	prepo := iface.Project_Repository{ctx = &pstore, save = fake_prov_project_save, list_by_owner = fake_prov_project_list_by_owner}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_user_service(&urepo, &arepo, &prepo, &clock, &ids)
	defer delete(ustore.users)
	defer delete(astore.agents)
	defer delete(pstore.projects)

	created, ok, err := create_user(&service, Create_User_Input{
		name = "bob",
		email = "bob@example.com",
		display_name = "Bob",
	})
	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	testing.expect_value(t, len(astore.agents), 4)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, COORDINATOR_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, WORKER_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, REVIEWER_AGENT_SLUG), 1)
	testing.expect_value(t, count_agents_by_slug(&astore, created.user_id, SOLOIST_AGENT_SLUG), 1)
	testing.expect_value(t, len(pstore.projects), 1)
	testing.expect_value(t, count_projects_by_slug(&pstore, created.user_id, CONVERSATION_PROJECT_SLUG), 1)
}
