package main

import "core:fmt"
import "core:os"
import "core:strings"
import json "core:encoding/json"
import httpc "odin_test:lib/httpc"

// ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--json]
//
// Calls the Hub GET /api/v1/search with the SEARCH-2/8 params:
//   --scope     -> types      (CSV of scopes/resource types: agent,task,comment,skill,…)
//   typed per-parent id filters (CSV each): --task-ids/--chain-ids/--project-ids/
//     --conversation-ids and negations --not-in-task-ids/-chain-ids/-project-ids/-conversation-ids
//   --exclude   -> exclude    (drop hits whose text contains this substring)
//   --limit     -> limit      (page size; server clamps to its max)
// Default output is grouped, human-readable, with a preview line per hit; it
// follows next_cursor to page in the full result set. --json prints the raw
// first-page envelope (which carries next_cursor/has_more for scripted paging).

SEARCH_MAX_PAGES :: 20

// Search_Row is the flattened hit used for grouped human output.
Search_Row :: struct {
	type:          string,
	label:         string,
	sublabel:      string,
	route:         string,
	preview:       string,
	matched_field: string,
}

// print_search_help documents `ham-ctl search` for whichever mode the caller is
// actually in. The --scope line lists all ELEVEN scope names (REQ-CLI-5): an
// unknown scope is a validation error, so the help has to state the vocabulary
// it is validated against — `message` is real and was missing here before.
//
// REQ-CLI-3: this help used to be unreachable in agent mode (main.odin gated the
// --help check behind NOT-agent-mode, so an agent got the ROOT overview and the
// agent-mode flag surface had no documentation at all). main.odin now honours
// --help for search in BOTH modes and passes agent_mode through to here.
print_search_help :: proc(agent_mode := false) {
	text := search_help_text(agent_mode)
	defer delete(text)
	fmt.println(text)
}

// search_help_text renders the help as a string so the drift test in
// src/ctl/search_help_text_test.odin can read the very text a user sees, rather
// than a parallel list that could disagree with it. The two modes accept
// DIFFERENT flags — agent mode pages with --cursor (--since alias) and rejects
// --json; user mode is the mirror image (see SEARCH_AGENT_ONLY_VALUE_FLAGS /
// SEARCH_USER_ONLY_BOOL_FLAGS) — so the difference is rendered explicitly here
// instead of being maintained as a second copy of the whole page.
//
// The test scans `--flag` tokens out of the indented block under "Flags:" and
// requires each to be accepted by search_validate_flags for that mode. Keep any
// prose that NAMES a flag the mode rejects (e.g. the --json note) in a
// column-0 section such as "Output:", which is outside that block.
search_help_text :: proc(agent_mode: bool) -> string {
	lines := make([dynamic]string)
	defer delete(lines)

	if agent_mode {
		append(&lines, "ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--cursor c]")
		append(&lines, "Purpose: global entity search across the Hub (agent.search RPC, relayed by your Bridge).")
	} else {
		append(&lines, "ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--json]")
		append(&lines, "Purpose: global entity search across the Hub (GET /api/v1/search).")
	}

	// Shared flag surface (SEARCH_COMMON_VALUE_FLAGS) — identical in both modes.
	append(&lines, "Flags:")
	append(&lines, "  --scope             CSV of scopes (default: all). Eleven names:")
	append(&lines, "                      conversation, message, agent, agent_instance, task-chain,")
	append(&lines, "                      task, comment, project, artifact, memory, skill")
	append(&lines, "  Typed parent-id filters (CSV; keep only rows under the named parent):")
	append(&lines, "    --task-ids, --chain-ids, --project-ids, --conversation-ids")
	append(&lines, "  Negations (CSV; drop rows under the named parent):")
	append(&lines, "    --not-in-task-ids, --not-in-chain-ids, --not-in-project-ids, --not-in-conversation-ids")
	append(&lines, "  --exclude           Drop hits whose text contains this substring")

	if agent_mode {
		append(&lines, "  --limit             Page size (server clamps to its max)")
		append(&lines, "  --cursor            Resume from the previous page's next_cursor (--since is an accepted alias)")
		append(&lines, "Output: always the raw JSON envelope. next_cursor/has_more sit at data.page,")
		append(&lines, "        one level ABOVE data.data.groups. --json is a user-mode flag and is")
		append(&lines, "        rejected here, because the envelope is already raw.")
		append(&lines, "Auth: your own agent token, which the managed ham-ctl already exports as")
		append(&lines, "      HEIMDALL_AGENT_TOKEN. No Hub URL and no user token are needed: the")
		append(&lines, "      Bridge holds the Hub credential and relays on your behalf.")
		append(&lines, "Examples:")
		append(&lines, "  ham-ctl search 'deploy runbook'")
		append(&lines, "  ham-ctl search zebra --scope task,comment --chain-ids chain_123 --limit 20")
		append(&lines, "  ham-ctl search zebra --project-ids proj_1 --not-in-chain-ids chain_9")
		append(&lines, "  ham-ctl search zebra --limit 20 --cursor <next_cursor from the previous page>")
	} else {
		append(&lines, "  --limit             Page size (server clamps to its max); human mode pages via the cursor")
		append(&lines, "  --json              Print the raw response envelope (carries next_cursor/has_more)")
		append(&lines, "Auth: needs --hub-url + --user-token (or HAM_HUB_URL / HAM_HUB_USER_TOKEN).")
		append(&lines, "Examples:")
		append(&lines, "  ham-ctl search 'deploy runbook' --hub-url http://127.0.0.1:49322 --user-token hut_...")
		append(&lines, "  ham-ctl search zebra --scope task,comment --chain-ids chain_123 --limit 20")
		append(&lines, "  ham-ctl search zebra --project-ids proj_1 --not-in-chain-ids chain_9")
	}

	return strings.join(lines[:], "\n")
}

// ---- unknown-flag rejection (REQ-CLI-4) ---------------------------------
// `search` previously parsed only the flags it recognised and ignored every
// other `--…` argument, so `--zzz-invented foo` produced ok:true and the exact
// baseline result set — a typo'd flag was indistinguishable from a working one,
// and the "foo" it was given silently became the query. These tables make the
// accepted surface explicit so anything else is a usage error.
//
// SEARCH_*_VALUE_FLAGS consume the NEXT argument; that value is skipped by the
// scanner so a value that itself looks like a flag (`--exclude --weird`) is not
// mistaken for one. Globals are allowlisted from main.odin's dispatch and the
// transport resolvers, so `search q --hub-url … --user-token …` keeps working.

SEARCH_COMMON_VALUE_FLAGS :: [?]string{
	"--scope", "--limit", "--exclude",
	"--task-ids", "--chain-ids", "--project-ids", "--conversation-ids",
	"--not-in-task-ids", "--not-in-chain-ids", "--not-in-project-ids", "--not-in-conversation-ids",
}

// Agent mode reaches the Hub over the agent.search RPC: it pages with --cursor
// (--since is a historical alias) and always prints the raw envelope, so --json
// is deliberately NOT accepted there. User mode is the mirror image.
SEARCH_AGENT_ONLY_VALUE_FLAGS :: [?]string{"--cursor", "--since"}
SEARCH_USER_ONLY_BOOL_FLAGS :: [?]string{"--json"}

// Global flags handled by main.odin / the transport resolvers, valid alongside
// any command. Enumerated from source, not from memory.
SEARCH_GLOBAL_VALUE_FLAGS :: [?]string{
	"--config", "--as", "--daemon-url", "--hub-url", "--user-token", "--token",
	"--bridge-endpoint", "--agent-token",
}
SEARCH_GLOBAL_BOOL_FLAGS :: [?]string{"--hub", "--agent-mode", "--help", "-h", "--version"}

search_flag_in :: proc(name: string, table: []string) -> bool {
	for known in table do if known == name do return true
	return false
}

// search_validate_flags reports the first unrecognised `--…` argument, or "" when
// every flag is known. Positional arguments (the query, and any flag value) never
// start with "--" and are skipped.
//
// A query that itself begins with "--" is therefore reported as an unknown flag.
// That is a deliberate, stated behavior and not a regression: command_tokens
// already discards every "--"-prefixed argument before the query is read, so such
// a query never reached the Hub — it silently searched for the following word
// instead. Erroring is strictly better than that. There is no "--" end-of-flags
// separator today; adding one is out of scope here.
search_validate_flags :: proc(args: []string, agent_mode: bool) -> string {
	// The tables above are compile-time array constants, which are not addressable
	// and so cannot be sliced directly; copy them into locals once per call.
	common_value := SEARCH_COMMON_VALUE_FLAGS
	global_value := SEARCH_GLOBAL_VALUE_FLAGS
	agent_value := SEARCH_AGENT_ONLY_VALUE_FLAGS
	global_bool := SEARCH_GLOBAL_BOOL_FLAGS
	user_bool := SEARCH_USER_ONLY_BOOL_FLAGS
	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1
		if !strings.has_prefix(arg, "-") do continue
		if arg == "-h" do continue
		if !strings.has_prefix(arg, "--") do return arg
		// `--flag=value` is not a form this CLI parses (option_value only reads the
		// NEXT argument), so it would silently take the default. Report it as such
		// rather than as an unknown flag, which would misdirect the fix.
		if strings.contains(arg, "=") do return arg
		if search_flag_in(arg, common_value[:]) || search_flag_in(arg, global_value[:]) {
			i += 1 // consume the value so it is never scanned as a flag
			continue
		}
		if agent_mode && search_flag_in(arg, agent_value[:]) {
			i += 1
			continue
		}
		if search_flag_in(arg, global_bool[:]) do continue
		if !agent_mode && search_flag_in(arg, user_bool[:]) do continue
		return arg
	}
	return ""
}

// search_reject_unknown_flag prints the usage error for `bad`. Agent mode prints
// the machine-readable envelope its callers parse; user mode prints plain text.
//
// The envelope is built with json_object/json_kv, NOT fmt.printf: fmt treats the
// braces in a JSON literal as format syntax and emits
// `%!(MISSING CLOSE BRACE)`, which would make this error unparseable for exactly
// the agent callers it exists to inform — a silent-failure bug inside the
// silent-failure fix. json_kv also escapes the offending flag text.
search_reject_unknown_flag :: proc(bad: string, agent_mode: bool) {
	hint := "unknown flag"
	if strings.contains(bad, "=") do hint = "flags take their value as the next argument (use `--scope task`, not `--scope=task`)"
	msg := strings.concatenate({"search: ", hint, ": ", bad, ". Run `ham-ctl search --help` for the accepted flags."})
	defer delete(msg)
	if agent_mode {
		fmt.println(json_object(json_kv_raw("ok", "false"), json_kv("message", msg)))
		return
	}
	fmt.printfln("search: %s: %s", hint, bad)
	fmt.println("Run `ham-ctl search --help` for the accepted flags.")
}

ctl_search_command :: proc(cmd: []string, args: []string) {
	if bad := search_validate_flags(args, false); bad != "" {
		search_reject_unknown_flag(bad, false)
		os.exit(1)
	}
	query := ""
	if len(cmd) >= 2 do query = cmd[1]
	if strings.trim_space(query) == "" {
		fmt.println(`{"ok":false,"message":"usage: ham-ctl search <query> [--scope csv] [--task-ids/--chain-ids/--project-ids/--conversation-ids csv] [--not-in-* csv] [--exclude text] [--limit n] [--json]"}`)
		os.exit(1)
	}
	base := hub_user_mode_url(args)
	if base == "" do base = "http://127.0.0.1:49328"
	hub := ctl_hub_make(strings.trim_right(base, "/"), hub_user_mode_token(args))

	// --json: single request, print the structured envelope verbatim.
	if has_flag(args, "--json") {
		body, _, ok := ctl_hub_fetch(hub, ctl_search_request(args, query, ""))
		if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); os.exit(1) }
		fmt.println(body)
		return
	}

	// Human output: page through with the cursor and aggregate. Each row owns its
	// strings (cloned in ctl_search_collect) so they survive the per-page JSON tree
	// being destroyed; free them all once printing is done.
	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}
	// cursor holds a cloned (owned) next_cursor between pages; "" is the unallocated
	// literal start/end sentinel, so only free it when it points at a clone.
	cursor := ""
	defer if cursor != "" do delete(cursor)
	for _ in 0..<SEARCH_MAX_PAGES {
		body, _, ok := ctl_hub_fetch(hub, ctl_search_request(args, query, cursor))
		if !ok { fmt.println("search request failed"); os.exit(1) }
		next, perr := ctl_search_collect(body, &rows)
		if perr {
			// Fall back to raw output if the body isn't the expected shape.
			fmt.println(body)
			return
		}
		if cursor != "" do delete(cursor)
		cursor = next
		if cursor == "" do break
	}
	ctl_print_search_rows(rows[:], query)
}

// ctl_search_request is the pure request builder (unit-tested): GET
// /api/v1/search with each flag mapped to its query param, omitting any flag
// the caller didn't provide. httpc percent-encodes the values.
ctl_search_request :: proc(args: []string, query, cursor: string) -> Ctl_Request {
	q := ctl_query_make()
	append(&q, httpc.Query_Param{"q", strings.trim_space(query)})
	ctl_query_add(&q, "types", option_value(args, "--scope", ""))
	ctl_query_add(&q, "task_ids", option_value(args, "--task-ids", ""))
	ctl_query_add(&q, "chain_ids", option_value(args, "--chain-ids", ""))
	ctl_query_add(&q, "project_ids", option_value(args, "--project-ids", ""))
	ctl_query_add(&q, "conversation_ids", option_value(args, "--conversation-ids", ""))
	ctl_query_add(&q, "not_in_task_ids", option_value(args, "--not-in-task-ids", ""))
	ctl_query_add(&q, "not_in_chain_ids", option_value(args, "--not-in-chain-ids", ""))
	ctl_query_add(&q, "not_in_project_ids", option_value(args, "--not-in-project-ids", ""))
	ctl_query_add(&q, "not_in_conversation_ids", option_value(args, "--not-in-conversation-ids", ""))
	ctl_query_add(&q, "exclude", option_value(args, "--exclude", ""))
	ctl_query_add(&q, "limit", option_value(args, "--limit", ""))
	ctl_query_add(&q, "cursor", cursor)
	return {method = .GET, path = ctl_api("search"), query = q[:]}
}

// ctl_search_collect parses one page envelope, appends its hits to rows, and
// returns the next cursor ("" when there is no more). perr is true when the
// body is not the expected {"data":{"groups":[…]},"page":{…}} shape.
ctl_search_collect :: proc(body: string, rows: ^[dynamic]Search_Row) -> (next_cursor: string, perr: bool) {
	value, err := json.parse(transmute([]byte)body)
	if err != .None do return "", true
	defer json.destroy_value(value)
	root, is_obj := value.(json.Object)
	if !is_obj do return "", true
	data, has_data := root["data"].(json.Object)
	if !has_data do return "", true
	groups, has_groups := data["groups"].(json.Array)
	if !has_groups do return "", true
	for group_value in groups {
		group, gok := group_value.(json.Object)
		if !gok do continue
		gtype := json_field_string(group, "type")
		hits, hok := group["hits"].(json.Array)
		if !hok do continue
		for hit_value in hits {
			hit, hitok := hit_value.(json.Object)
			if !hitok do continue
			// json_field_string returns a slice INTO the parsed tree, which the
			// deferred destroy_value frees when this proc returns. Clone every field
			// (gtype per row, so no two rows share a backing) so the rows can outlive
			// the page's JSON tree; ctl_search_command frees them via search_row_delete.
			append(rows, Search_Row{
				type          = strings.clone(gtype),
				label         = strings.clone(json_field_string(hit, "label")),
				sublabel      = strings.clone(json_field_string(hit, "sublabel")),
				route         = strings.clone(json_field_string(hit, "route")),
				preview       = strings.clone(json_field_string(hit, "preview")),
				matched_field = strings.clone(json_field_string(hit, "matched_field")),
			})
		}
	}
	// Only follow the cursor when the server says there is more.
	if page, has_page := root["page"].(json.Object); has_page {
		has_more, _ := page["has_more"].(json.Boolean)
		// Clone the cursor too: it points into the tree destroy_value frees below, so
		// the caller would otherwise read freed memory when building the next page.
		if has_more do return strings.clone(json_field_string(page, "next_cursor")), false
	}
	return "", false
}

// search_row_delete frees the strings a Search_Row owns (cloned in
// ctl_search_collect so the row can outlive the parsed JSON tree it came from).
search_row_delete :: proc(row: Search_Row) {
	delete(row.type)
	delete(row.label)
	delete(row.sublabel)
	delete(row.route)
	delete(row.preview)
	delete(row.matched_field)
}

json_field_string :: proc(obj: json.Object, key: string) -> string {
	if s, ok := obj[key].(json.String); ok do return string(s)
	return ""
}

// SEARCH_GROUP_ORDER mirrors the server's group ordering so the CLI is stable.
SEARCH_GROUP_ORDER :: [?]string{"conversation", "message", "agent", "agent_instance", "task-chain", "task", "comment", "project", "artifact", "memory", "skill"}

ctl_print_search_rows :: proc(rows: []Search_Row, query: string) {
	if len(rows) == 0 {
		fmt.printfln("No results for %q.", query)
		return
	}
	for group_type in SEARCH_GROUP_ORDER {
		ctl_print_search_group(rows, group_type)
	}
	// Print any unexpected type once, so nothing is silently dropped.
	seen := make(map[string]bool)
	defer delete(seen)
	for row in rows {
		if search_type_in_order(row.type) || seen[row.type] do continue
		seen[row.type] = true
		ctl_print_search_group(rows, row.type)
	}
	fmt.printfln("%d result%s.", len(rows), len(rows) == 1 ? "" : "s")
}

ctl_print_search_group :: proc(rows: []Search_Row, group_type: string) {
	count := 0
	for row in rows do if row.type == group_type do count += 1
	if count == 0 do return
	fmt.printfln("%s (%d)", search_group_label(group_type), count)
	for row in rows {
		if row.type != group_type do continue
		if row.sublabel != "" {
			fmt.printfln("  • %s  —  %s", row.label, row.sublabel)
		} else {
			fmt.printfln("  • %s", row.label)
		}
		if row.route != "" do fmt.printfln("      %s", row.route)
		if row.preview != "" do fmt.printfln("      %s", row.preview)
	}
	fmt.println("")
}

search_type_in_order :: proc(t: string) -> bool {
	for candidate in SEARCH_GROUP_ORDER do if candidate == t do return true
	return false
}

search_group_label :: proc(t: string) -> string {
	switch t {
	case "conversation":   return "Conversations"
	case "message":        return "Messages"
	case "agent":          return "Agents"
	case "agent_instance": return "Agent instances"
	case "task-chain":     return "Task chains"
	case "task":           return "Tasks"
	case "comment":        return "Comments"
	case "project":        return "Projects"
	case "artifact":       return "Artifacts"
	case "memory":         return "Memories"
	case "skill":          return "Skills"
	}
	return t
}
