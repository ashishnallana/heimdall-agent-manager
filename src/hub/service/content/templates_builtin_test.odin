package content

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Fake content repository returning no owner templates so list_templates appends
// the built-in templates.
fake_content_list_templates_empty :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Template, domain.Domain_Error) {
	return {}, {}
}

fake_content_get_template_none :: proc(ctx: rawptr, id: string) -> (domain.Template, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Not_Found, "template not found")
}

// Fake content repository returning the built-ins already to test deduplication.
fake_content_list_templates_with_builtins :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Template, domain.Domain_Error) {
	out := make([]domain.Template, 5)
	out[0] = domain.Template{template_id = domain.TEMPLATE_COORDINATOR_ID, is_system = true, name = "coordinator"}
	out[1] = domain.Template{template_id = domain.TEMPLATE_WORKER_ID, is_system = true, name = "worker"}
	out[2] = domain.Template{template_id = domain.TEMPLATE_REVIEWER_ID, is_system = true, name = "reviewer"}
	out[3] = domain.Template{template_id = domain.TEMPLATE_EMPTY_ID, is_system = true, name = "empty"}
	out[4] = domain.Template{template_id = domain.TEMPLATE_SOLOIST_ID, is_system = true, name = "soloist"}
	return out, {}
}

@(test)
test_list_templates_includes_all_builtins_without_duplication :: proc(t: ^testing.T) {
	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	templates, err := list_templates(&service, contracts.Auth_Context{user_id = "user_1"})
	defer delete(templates)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	has_coordinator := false
	has_worker := false
	has_reviewer := false
	has_empty := false
	has_soloist := false
	has_stale_reviewer := false

	for tmpl in templates {
		if tmpl.template_id == domain.TEMPLATE_COORDINATOR_ID {
			has_coordinator = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "coordinator")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Coordinator"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_WORKER_ID {
			has_worker = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "worker")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Worker"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_REVIEWER_ID {
			has_reviewer = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "reviewer")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Reviewer"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_EMPTY_ID {
			has_empty = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "empty")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: General Agent"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_SOLOIST_ID {
			has_soloist = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "soloist")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Soloist"), true)
		}
		if tmpl.template_id == "tmpl_system_reviewer" do has_stale_reviewer = true
	}

	testing.expect_value(t, has_coordinator, true)
	testing.expect_value(t, has_worker, true)
	testing.expect_value(t, has_reviewer, true)
	testing.expect_value(t, has_empty, true)
	testing.expect_value(t, has_soloist, true)
	testing.expect_value(t, has_stale_reviewer, false)
	testing.expect_value(t, len(templates), 5)

	// Now verify deduplication when repository already contains the templates
	repo_dedup := iface.Content_Repository{list_templates = fake_content_list_templates_with_builtins, get_template = fake_content_get_template_none}
	service_dedup := new_content_service(&repo_dedup, nil, nil, nil, nil, nil, nil)

	templates_dedup, err_dedup := list_templates(&service_dedup, contracts.Auth_Context{user_id = "user_1"})
	defer delete(templates_dedup)
	testing.expect_value(t, err_dedup.code, domain.Error_Code.None)
	testing.expect_value(t, len(templates_dedup), 5)
}

@(test)
test_template_available_all_builtins :: proc(t: ^testing.T) {
	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_COORDINATOR_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_WORKER_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_REVIEWER_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_EMPTY_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_SOLOIST_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", "tmpl_system_reviewer"), false)
	testing.expect_value(t, template_available(&service, "user_1", "tmpl_non_existent"), false)
}
