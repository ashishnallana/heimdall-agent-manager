package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_provider_catalog_serializer_emits_recipe_and_literal_models :: proc(t: ^testing.T) {
	entry := domain.Provider_Catalog_Entry{
		provider = "codex",
		display_name = "Codex",
		icon_url = "/api/v1/providers/codex/icon",
		binary = "codex",
		base_args_json = "[]",
		yolo_args_json = "[\"--approval-policy=never\"]",
		model_flag = "-m",
		prompt_args_json = "[]",
		prompt_delivery = "flag-injection",
		starter_prompt = "Run \"start-success\"",
		bootstrap_file = "AGENTS.md",
		skill_dir = ".codex/skills",
		startup_detection_json = "{\"enabled\":true}",
		activity_detection_json = "{\"enabled\":true}",
		state = "active",
		models = make([dynamic]domain.Provider_Model),
	}
	defer delete(entry.models)
	append(&entry.models, domain.Provider_Model{provider = "codex", model_id = "gpt-5", label = "GPT-5", state = "active"})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_provider_catalog_entry_json(&b, entry)
	body := strings.to_string(b)
	parsed: json.Value
	defer json.destroy_value(parsed)
	parse_err := json.unmarshal(transmute([]byte)body, &parsed)
	testing.expect(t, parse_err == nil, "provider response is valid JSON")
	testing.expect(t, strings.contains(body, "\"binary\":\"codex\""), "recipe binary is present")
	testing.expect(t, strings.contains(body, "\"model_flag\":\"-m\""), "model flag is present")
	testing.expect(t, strings.contains(body, "\"model_id\":\"gpt-5\""), "literal model id is present")
	testing.expect(t, !strings.contains(body, "tier"), "catalog contract contains no tier fields")
}
