package main

import "core:strings"
import "core:testing"

// Unit coverage for the pure ham-ctl search param-builder. It must map the CLI
// flags onto the query params (--scope=>types; typed --task-ids/--chain-ids/
// --project-ids/--conversation-ids + --not-in-* negations; --exclude; --limit;
// plus the load-more cursor), percent-encode each value, and OMIT any flag the
// caller didn't provide. --scope-ids is REMOVED (SEARCH-8).

@(test)
test_search_path_query_only :: proc(t: ^testing.T) {
	path := ctl_test_target(t, ctl_search_request([]string{}, "hello world", ""))
	testing.expect(t, path == "/api/v1/search?q=hello+world" || path == "/api/v1/search?q=hello%20world", path)
}

@(test)
test_search_path_omits_absent_flags :: proc(t: ^testing.T) {
	path := ctl_test_target(t, ctl_search_request([]string{}, "q", ""))
	testing.expect(t, !strings.contains(path, "types="), "types omitted when --scope absent")
	testing.expect(t, !strings.contains(path, "task_ids="), "task_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "chain_ids="), "chain_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "project_ids="), "project_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "conversation_ids="), "conversation_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "not_in_"), "negations omitted when absent")
	testing.expect(t, !strings.contains(path, "scope_ids"), "scope_ids must be gone (SEARCH-8)")
	testing.expect(t, !strings.contains(path, "exclude="), "exclude omitted when --exclude absent")
	testing.expect(t, !strings.contains(path, "limit="), "limit omitted when --limit absent")
	testing.expect(t, !strings.contains(path, "cursor="), "cursor omitted when empty")
}

@(test)
test_search_path_maps_all_flags :: proc(t: ^testing.T) {
	args := []string{
		"--scope", "task,comment",
		"--chain-ids", "chain_1,chain_2",
		"--task-ids", "task_9",
		"--project-ids", "proj_1",
		"--conversation-ids", "inst_5",
		"--exclude", "draft",
		"--limit", "25",
	}
	path := ctl_test_target(t, ctl_search_request(args, "zebra", ""))
	testing.expect(t, strings.contains(path, "q=zebra"), path)
	testing.expect(t, strings.contains(path, "&types=task%2Ccomment"), path)          // comma encoded
	testing.expect(t, strings.contains(path, "&task_ids=task_9"), path)
	testing.expect(t, strings.contains(path, "&chain_ids=chain_1%2Cchain_2"), path)
	testing.expect(t, strings.contains(path, "&project_ids=proj_1"), path)
	testing.expect(t, strings.contains(path, "&conversation_ids=inst_5"), path)
	testing.expect(t, strings.contains(path, "&exclude=draft"), path)
	testing.expect(t, strings.contains(path, "&limit=25"), path)
	testing.expect(t, !strings.contains(path, "scope_ids"), "scope_ids must be gone")
}

@(test)
test_search_path_negations :: proc(t: ^testing.T) {
	args := []string{
		"--not-in-task-ids", "task_1",
		"--not-in-chain-ids", "chain_1",
		"--not-in-project-ids", "proj_1",
		"--not-in-conversation-ids", "inst_1",
	}
	path := ctl_test_target(t, ctl_search_request(args, "q", ""))
	testing.expect(t, strings.contains(path, "&not_in_task_ids=task_1"), path)
	testing.expect(t, strings.contains(path, "&not_in_chain_ids=chain_1"), path)
	testing.expect(t, strings.contains(path, "&not_in_project_ids=proj_1"), path)
	testing.expect(t, strings.contains(path, "&not_in_conversation_ids=inst_1"), path)
}

@(test)
test_search_path_encodes_reserved_chars :: proc(t: ^testing.T) {
	path := ctl_test_target(t, ctl_search_request([]string{"--exclude", "a&b=c d"}, "x/y?z", ""))
	// Reserved characters must be percent-encoded so they don't break the query.
	testing.expect(t, strings.contains(path, "q=x%2Fy%3Fz"), path)
	testing.expect(t, strings.contains(path, "exclude=a%26b%3Dc+d") || strings.contains(path, "exclude=a%26b%3Dc%20d"), path)
	// Unreserved punctuation passes through unescaped.
	keep := ctl_test_target(t, ctl_search_request([]string{}, "a-b_c.d~e", ""))
	testing.expect(t, strings.contains(keep, "q=a-b_c.d~e"), keep)
}

@(test)
test_search_path_appends_cursor :: proc(t: ^testing.T) {
	path := ctl_test_target(t, ctl_search_request([]string{}, "q", "Y3Vyc29y"))
	testing.expect(t, strings.has_suffix(path, "&cursor=Y3Vyc29y"), path)
}

// ── Unit coverage for ctl_search_collect (SEARCH-12 use-after-free guard) ──

@(test)
test_search_collect_rows_survive_tree_destroy :: proc(t: ^testing.T) {
	body := `{"data":{"groups":[{"type":"task","hits":[` +
		`{"label":"Alpha","sublabel":"chain_1","route":"/t/1","preview":"do the thing","matched_field":"title"},` +
		`{"label":"Beta","route":"/t/2","preview":"another","matched_field":"body"}` +
		`]}]},"page":{"has_more":false}}`

	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}

	next, perr := ctl_search_collect(body, &rows)
	testing.expect(t, !perr, "well-formed envelope should parse")
	testing.expect_value(t, next, "")
	testing.expect_value(t, len(rows), 2)

	testing.expect_value(t, rows[0].type, "task")
	testing.expect_value(t, rows[0].label, "Alpha")
	testing.expect_value(t, rows[0].sublabel, "chain_1")
	testing.expect_value(t, rows[0].route, "/t/1")
	testing.expect_value(t, rows[0].preview, "do the thing")
	testing.expect_value(t, rows[0].matched_field, "title")

	testing.expect_value(t, rows[1].type, "task")
	testing.expect_value(t, rows[1].label, "Beta")
	testing.expect_value(t, rows[1].sublabel, "")
	testing.expect_value(t, rows[1].route, "/t/2")
}

@(test)
test_search_collect_clones_next_cursor :: proc(t: ^testing.T) {
	body := `{"data":{"groups":[]},"page":{"has_more":true,"next_cursor":"Y3Vyc29y"}}`

	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}

	next, perr := ctl_search_collect(body, &rows)
	testing.expect(t, !perr, "well-formed envelope should parse")
	testing.expect_value(t, next, "Y3Vyc29y")
	delete(next)
}

@(test)
test_search_collect_rejects_malformed_body :: proc(t: ^testing.T) {
	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}

	next, perr := ctl_search_collect(`{"unexpected":true}`, &rows)
	testing.expect(t, perr, "unexpected shape should report perr")
	testing.expect_value(t, next, "")
	testing.expect_value(t, len(rows), 0)
}

// ── REQ-CLI-4 coverage for the search unknown-flag rejector ──

@(test)
test_search_flags_accepts_every_real_flag :: proc(t: ^testing.T) {
	args := []string{
		"--scope", "task,comment", "--limit", "5", "--exclude", "smoke",
		"--task-ids", "task_1", "--chain-ids", "chain_1",
		"--project-ids", "proj_1", "--conversation-ids", "chat_1",
		"--not-in-task-ids", "task_2", "--not-in-chain-ids", "chain_2",
		"--not-in-project-ids", "proj_2", "--not-in-conversation-ids", "chat_2",
	}
	testing.expect(t, search_validate_flags(args, false) == "", "user mode accepts every real flag")
	testing.expect(t, search_validate_flags(args, true) == "", "agent mode accepts every real flag")
}

@(test)
test_search_flags_rejects_unknown :: proc(t: ^testing.T) {
	args := []string{"--scope", "task", "--zzz-invented", "foo"}
	testing.expect(t, search_validate_flags(args, false) == "--zzz-invented", "user mode rejects unknown flag")
	testing.expect(t, search_validate_flags(args, true) == "--zzz-invented", "agent mode rejects unknown flag")
}

@(test)
test_search_flags_allows_globals :: proc(t: ^testing.T) {
	args := []string{"--hub", "--hub-url", "http://localhost:8080", "--user-token", "tok", "--scope", "task"}
	testing.expect(t, search_validate_flags(args, false) == "", "globals stay valid in user mode")
	agent := []string{"--agent-mode", "--bridge-endpoint", "http://127.0.0.1:1", "--agent-token", "tok"}
	testing.expect(t, search_validate_flags(agent, true) == "", "globals stay valid in agent mode")
	testing.expect(t, search_validate_flags([]string{"--config", "/tmp/c.json", "--as", "alice"}, false) == "", "--config/--as stay valid")
	testing.expect(t, search_validate_flags([]string{"--help"}, false) == "", "--help stays valid")
	testing.expect(t, search_validate_flags([]string{"-h"}, false) == "", "-h stays valid")
}

@(test)
test_search_flags_mode_specific :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"--json"}, false) == "", "--json valid in user mode")
	testing.expect(t, search_validate_flags([]string{"--json"}, true) == "--json", "--json rejected in agent mode")
	testing.expect(t, search_validate_flags([]string{"--cursor", "c"}, true) == "", "--cursor valid in agent mode")
	testing.expect(t, search_validate_flags([]string{"--since", "c"}, true) == "", "--since alias valid in agent mode")
	testing.expect(t, search_validate_flags([]string{"--cursor", "c"}, false) == "--cursor", "--cursor rejected in user mode")
}

@(test)
test_search_flags_value_not_scanned :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"--exclude", "--weird"}, false) == "", "value is consumed, not scanned")
	testing.expect(t, search_validate_flags([]string{"--scope", "--zzz"}, false) == "", "scope value consumed")
}

@(test)
test_search_flags_rejects_equals_form :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"--scope=task"}, false) == "--scope=task", "--scope=task reported")
}

@(test)
test_search_flags_ignores_positionals :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"search", "rag"}, false) == "", "positionals ignored")
	testing.expect(t, search_validate_flags([]string{}, false) == "", "empty args accepted")
}

// ── REQ-CLI-3 coverage for `ham-ctl search --help` ──

help_flag_tokens :: proc(text: string) -> [dynamic]string {
	out := make([dynamic]string)
	in_flags := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "Flags:" {
			in_flags = true
			continue
		}
		if !in_flags do continue
		if line != "" && !strings.has_prefix(line, " ") do break
		words := strings.fields(line)
		defer delete(words)
		for raw in words {
			tok := strings.trim_right(raw, ",.;:)")
			if strings.has_prefix(tok, "--") do append(&out, tok)
		}
	}
	return out
}

@(test)
test_search_help_documents_only_accepted_flags :: proc(t: ^testing.T) {
	for agent_mode in ([?]bool{false, true}) {
		text := search_help_text(agent_mode)
		defer delete(text)
		tokens := help_flag_tokens(text)
		defer delete(tokens)
		testing.expect(t, len(tokens) > 0, "the Flags block documents at least one flag")
		for tok in tokens {
			args := []string{tok, "value"}
			testing.expectf(
				t,
				search_validate_flags(args, agent_mode) == "",
				"help documents %s but search rejects it (agent_mode=%v)",
				tok,
				agent_mode,
			)
		}
	}
}

@(test)
test_search_help_documents_every_accepted_flag :: proc(t: ^testing.T) {
	common := SEARCH_COMMON_VALUE_FLAGS
	agent_only := SEARCH_AGENT_ONLY_VALUE_FLAGS
	user_only := SEARCH_USER_ONLY_BOOL_FLAGS

	for agent_mode in ([?]bool{false, true}) {
		text := search_help_text(agent_mode)
		defer delete(text)
		for flag in common {
			testing.expectf(t, strings.contains(text, flag), "%s undocumented (agent_mode=%v)", flag, agent_mode)
		}
	}

	agent_text := search_help_text(true)
	defer delete(agent_text)
	user_text := search_help_text(false)
	defer delete(user_text)

	for flag in agent_only {
		testing.expectf(t, strings.contains(agent_text, flag), "agent-only %s undocumented in agent help", flag)
	}
	for flag in user_only {
		testing.expectf(t, strings.contains(user_text, flag), "user-only %s undocumented in user help", flag)
	}

	agent_tokens := help_flag_tokens(agent_text)
	defer delete(agent_tokens)
	for tok in agent_tokens {
		testing.expectf(t, tok != "--json", "--json is rejected in agent mode but the agent Flags block lists it")
	}
	user_tokens := help_flag_tokens(user_text)
	defer delete(user_tokens)
	for tok in user_tokens {
		testing.expectf(t, tok != "--cursor" && tok != "--since", "%s is rejected in user mode but the user Flags block lists it", tok)
	}
}

@(test)
test_search_help_lists_all_eleven_scopes :: proc(t: ^testing.T) {
	scopes := [?]string{
		"conversation", "message", "agent", "agent_instance", "task-chain",
		"task", "comment", "project", "artifact", "memory", "skill",
	}
	for agent_mode in ([?]bool{false, true}) {
		text := search_help_text(agent_mode)
		defer delete(text)
		for scope in scopes {
			testing.expectf(t, strings.contains(text, scope), "scope %s missing from help (agent_mode=%v)", scope, agent_mode)
		}
	}
}

@(test)
test_search_help_auth_line_is_mode_correct :: proc(t: ^testing.T) {
	agent_text := search_help_text(true)
	defer delete(agent_text)
	testing.expect(t, strings.contains(agent_text, "HEIMDALL_AGENT_TOKEN"), "agent help names the token the agent actually has")
	testing.expect(t, !strings.contains(agent_text, "--user-token"), "agent help must not ask an agent for a user token")
	testing.expect(t, !strings.contains(agent_text, "--hub-url"), "agent help must not ask an agent for a hub url")

	user_text := search_help_text(false)
	defer delete(user_text)
	testing.expect(t, strings.contains(user_text, "--user-token"), "user help still states the user-mode credential")
	testing.expect(t, strings.contains(user_text, "--hub-url"), "user help still states the user-mode hub url")
}
