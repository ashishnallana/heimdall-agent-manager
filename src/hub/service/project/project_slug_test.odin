package project

import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// T17: a create request without a slug must never store a vault-armored
// (encrypted) name as the slug.

ARMORED_NAME :: "vault:v2:323b26cae1bb31bf:e1:06Z/+/8LOSte8WAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@(private = "file")
Slug_Test_Repo :: struct {
	saved: domain.Project,
	saves: int,
}

@(private = "file")
slug_test_save :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	repo := cast(^Slug_Test_Repo)ctx
	repo.saved = project
	repo.saves += 1
	return project, true, domain.Domain_Error{}
}

@(private = "file")
slug_test_id :: proc(ctx: rawptr, prefix: string) -> string {
	return "proj_slug_test"
}

@(private = "file")
slug_test_create :: proc(t: ^testing.T, input: Create_Project_Input) -> domain.Project {
	repo := new(Slug_Test_Repo)
	defer free(repo)
	projects := iface.Project_Repository{ctx = rawptr(repo), save = slug_test_save}
	clock := platform.real_clock()
	ids := platform.ID_Generator{generate = slug_test_id}
	service := Project_Service{projects = &projects, clock = &clock, ids = &ids}
	project, ok, err := create(&service, contracts.Auth_Context{user_id = "usr_slug"}, input)
	testing.expectf(t, ok, "create ok (err=%v)", err)
	testing.expect_value(t, repo.saves, 1)
	return project
}

@(test)
test_default_project_slug_plaintext_name_kept :: proc(t: ^testing.T) {
	testing.expect_value(t, default_project_slug("My App", "/home/u/my-app", context.temp_allocator), "My App")
}

@(test)
test_default_project_slug_armored_name_uses_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, default_project_slug(ARMORED_NAME, "/home/u/My Cool_App/", context.temp_allocator), "my-cool-app")
	testing.expect_value(t, default_project_slug(ARMORED_NAME, "C:\\Users\\u\\Heimdall.Hub", context.temp_allocator), "heimdall-hub")
	testing.expect_value(t, default_project_slug(ARMORED_NAME, "/home/u/--x--", context.temp_allocator), "x")
}

@(test)
test_default_project_slug_armored_name_without_usable_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, default_project_slug(ARMORED_NAME, "/", context.temp_allocator), "project")
	testing.expect_value(t, default_project_slug(ARMORED_NAME, "/home/u/プロジェクト", context.temp_allocator), "project")
}

@(test)
test_create_armored_name_without_slug_never_stores_ciphertext :: proc(t: ^testing.T) {
	project := slug_test_create(t, Create_Project_Input{name = ARMORED_NAME, default_path = "/home/u/heimdall-agent-manager"})
	testing.expect_value(t, project.slug, "heimdall-agent-manager")
	testing.expect(t, !domain.is_vault_armored(project.slug), "slug is not ciphertext")
	testing.expect_value(t, project.name, ARMORED_NAME)
	delete(project.slug)
}

@(test)
test_create_keeps_given_slug_and_plaintext_fallback :: proc(t: ^testing.T) {
	given := slug_test_create(t, Create_Project_Input{name = ARMORED_NAME, slug = "chosen", default_path = "/srv/app"})
	testing.expect_value(t, given.slug, "chosen")
	plain := slug_test_create(t, Create_Project_Input{name = "Plain name", default_path = "/srv/app"})
	testing.expect_value(t, plain.slug, "Plain name")
}

// Review round 1: derived slugs collide (UNIQUE(owner_user_id, slug), archived rows
// kept), so create must pick a free slug for the owner.

@(private = "file")
Unique_Test_Repo :: struct {
	rows: [dynamic]domain.Project,
	next_id: int,
	conflicts: int,
}

@(private = "file")
unique_test_save :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	repo := cast(^Unique_Test_Repo)ctx
	for row in repo.rows {
		if row.owner_user_id == project.owner_user_id && row.slug == project.slug {
			repo.conflicts += 1
			return domain.Project{}, false, domain.domain_error(.Conflict, "project could not be saved")
		}
	}
	append(&repo.rows, project)
	return project, true, domain.Domain_Error{}
}

@(private = "file")
unique_test_update :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	repo := cast(^Unique_Test_Repo)ctx
	for &row in repo.rows do if row.project_id == project.project_id do row = project
	return project, true, domain.Domain_Error{}
}

@(private = "file")
unique_test_get :: proc(ctx: rawptr, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	repo := cast(^Unique_Test_Repo)ctx
	for row in repo.rows do if row.project_id == project_id do return row, true, domain.Domain_Error{}
	return domain.Project{}, false, domain.domain_error(.Not_Found, "project not found")
}

@(private = "file")
unique_test_list :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Project, domain.Domain_Error) {
	repo := cast(^Unique_Test_Repo)ctx
	out := make([dynamic]domain.Project)
	for row in repo.rows do if row.owner_user_id == owner do append(&out, row)
	return out[:], domain.Domain_Error{}
}

@(private = "file")
unique_test_id :: proc(ctx: rawptr, prefix: string) -> string {
	repo := cast(^Unique_Test_Repo)ctx
	repo.next_id += 1
	return fmt.tprintf("proj_unique_%d", repo.next_id)
}

@(private = "file")
Unique_Fixture :: struct {
	repo: ^Unique_Test_Repo,
	projects: iface.Project_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	service: Project_Service,
	owned: [dynamic]string,
}

@(private = "file")
unique_fixture_init :: proc(f: ^Unique_Fixture, with_list := true) {
	f.repo = new(Unique_Test_Repo)
	f.projects = iface.Project_Repository{ctx = rawptr(f.repo), save = unique_test_save, update = unique_test_update, get = unique_test_get}
	if with_list do f.projects.list_by_owner = unique_test_list
	f.clock = platform.real_clock()
	f.ids = platform.ID_Generator{ctx = rawptr(f.repo), generate = unique_test_id}
	f.service = Project_Service{projects = &f.projects, clock = &f.clock, ids = &f.ids}
}

@(private = "file")
unique_fixture_destroy :: proc(f: ^Unique_Fixture) {
	for s in f.owned do delete(s)
	delete(f.owned)
	delete(f.repo.rows)
	free(f.repo)
}

@(private = "file")
unique_create :: proc(t: ^testing.T, f: ^Unique_Fixture, input: Create_Project_Input, owner := "usr_slug") -> domain.Project {
	project, ok, err := create(&f.service, contracts.Auth_Context{user_id = owner}, input)
	testing.expectf(t, ok, "create ok (err=%v)", err)
	// Every slug create returns that is not the caller's own input string is heap-owned.
	if ok && project.slug != input.slug && project.slug != input.name do append(&f.owned, project.slug)
	return project
}

@(test)
test_create_same_folder_name_gets_distinct_slugs :: proc(t: ^testing.T) {
	f: Unique_Fixture; unique_fixture_init(&f); defer unique_fixture_destroy(&f)
	a := unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/a/app"})
	b := unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/b/app"})
	c := unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/c/App/"})
	testing.expect_value(t, a.slug, "app")
	testing.expect_value(t, b.slug, "app-2")
	testing.expect_value(t, c.slug, "app-3")
	testing.expect_value(t, len(f.repo.rows), 3)
	testing.expect_value(t, f.repo.conflicts, 0)
}

@(test)
test_create_non_latin_names_both_succeed :: proc(t: ^testing.T) {
	f: Unique_Fixture; unique_fixture_init(&f); defer unique_fixture_destroy(&f)
	a := unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/home/u/プロジェクト"})
	b := unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/home/u/项目"})
	testing.expect_value(t, a.slug, "project")
	testing.expect_value(t, b.slug, "project-2")
}

@(test)
test_create_after_archiving_same_slug_succeeds :: proc(t: ^testing.T) {
	f: Unique_Fixture; unique_fixture_init(&f); defer unique_fixture_destroy(&f)
	auth := contracts.Auth_Context{user_id = "usr_slug"}
	first := unique_create(t, &f, Create_Project_Input{name = "x", slug = "my-app", default_path = "/srv/my-app"})
	_, archived, _ := archive_project(&f.service, auth, first.project_id)
	testing.expect(t, archived, "archive ok")
	again := unique_create(t, &f, Create_Project_Input{name = "x", slug = "my-app", default_path = "/srv/my-app"})
	testing.expect_value(t, again.slug, "my-app-2")
	testing.expect(t, again.project_id != first.project_id, "a new project")
}

@(test)
test_unarchive_restores_active_and_keeps_slug :: proc(t: ^testing.T) {
	f: Unique_Fixture; unique_fixture_init(&f); defer unique_fixture_destroy(&f)
	auth := contracts.Auth_Context{user_id = "usr_slug"}
	first := unique_create(t, &f, Create_Project_Input{name = "x", slug = "my-app", default_path = "/srv/my-app"})
	archived, archived_ok, _ := archive_project(&f.service, auth, first.project_id)
	testing.expect(t, archived_ok, "archive ok")
	testing.expect_value(t, archived.state, domain.Project_State.Archived)
	restored, restored_ok, _ := unarchive_project(&f.service, auth, first.project_id)
	testing.expect(t, restored_ok, "unarchive ok")
	testing.expect_value(t, restored.state, domain.Project_State.Active)
	testing.expect_value(t, restored.slug, "my-app")
	_, other_ok, _ := unarchive_project(&f.service, contracts.Auth_Context{user_id = "usr_other"}, first.project_id)
	testing.expect(t, !other_ok, "another owner cannot unarchive it")
}

@(test)
test_create_given_slug_clash_suffixed_and_owners_isolated :: proc(t: ^testing.T) {
	f: Unique_Fixture; unique_fixture_init(&f); defer unique_fixture_destroy(&f)
	unique_create(t, &f, Create_Project_Input{name = "my app", slug = "my-app", default_path = "/srv/one"})
	clash := unique_create(t, &f, Create_Project_Input{name = "My App", slug = "my-app", default_path = "/srv/two"})
	testing.expect_value(t, clash.slug, "my-app-2")
	other := unique_create(t, &f, Create_Project_Input{name = "My App", slug = "my-app", default_path = "/srv/two"}, "usr_other")
	testing.expect_value(t, other.slug, "my-app")
}

@(test)
test_create_conflict_without_listing_retries_next_suffix :: proc(t: ^testing.T) {
	// No list_by_owner (or a race): the save Conflict itself moves to the next suffix.
	f: Unique_Fixture; unique_fixture_init(&f, with_list = false); defer unique_fixture_destroy(&f)
	unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/a/app"})
	b := unique_create(t, &f, Create_Project_Input{name = ARMORED_NAME, default_path = "/b/app"})
	testing.expect_value(t, b.slug, "app-2")
	testing.expect_value(t, f.repo.conflicts, 1)
}
