package project

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
