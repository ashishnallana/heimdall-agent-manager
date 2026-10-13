// REQ-CLI-5 coverage: an unknown `--scope` token must be REJECTED, not quietly
// matched against nothing. Before this fix, `--scope bogusscope` returned ok
// with zero hits, so one typo made a populated Hub look empty — a false
// negative indistinguishable from a correct "no results" answer.
//
// The canonical vocabulary lives in package domain (moved there from package
// sqlite) so the service can validate against the SAME list the repository
// selects from. This test pins BOTH halves: every accepted token still resolves
// (a regression here silently breaks callers), and anything else errors.
package hub_search_scope_validation_test

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import search "odin_test:hub/service/search"

failures := 0

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	failures += 1
}

// The full accepted token set, enumerated from domain.normalize_search_type:
// 11 canonical names + 18 aliases. Every one must keep resolving.
ALIAS_CASES :: [?][2]string{
	{"conversation", "conversation"}, {"conversations", "conversation"},
	{"message", "message"}, {"messages", "message"}, {"msg", "message"},
	{"agent", "agent"}, {"agents", "agent"},
	{"agent_instance", "agent_instance"}, {"instance", "agent_instance"},
	{"instances", "agent_instance"}, {"agent_instances", "agent_instance"},
	{"task-chain", "task-chain"}, {"task_chain", "task-chain"}, {"task_chains", "task-chain"},
	{"chain", "task-chain"}, {"chains", "task-chain"}, {"taskchain", "task-chain"},
	{"task", "task"}, {"tasks", "task"},
	{"comment", "comment"}, {"comments", "comment"},
	{"project", "project"}, {"projects", "project"},
	{"artifact", "artifact"}, {"artifacts", "artifact"},
	{"memory", "memory"}, {"memories", "memory"},
	{"skill", "skill"}, {"skills", "skill"},
}

@(test)
test_hub_search_scope_validation_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	// 1. Canonical vocabulary is exactly the eleven names, `message` included.
	check(len(domain.SEARCH_TYPE_ORDER) == 11, fmt.tprintf("expected 11 canonical types, got %d", len(domain.SEARCH_TYPE_ORDER)))
	for want in ([?]string{"conversation", "message", "agent", "agent_instance", "task-chain", "task", "comment", "project", "artifact", "memory", "skill"}) {
		found := false
		for have in domain.SEARCH_TYPE_ORDER do if have == want do found = true
		check(found, fmt.tprintf("canonical type missing from SEARCH_TYPE_ORDER: %s", want))
	}

	// 2. Every canonical name and every alias still normalizes AND validates.
	for c in ALIAS_CASES {
		token, want := c[0], c[1]
		got := domain.normalize_search_type(token)
		check(got == want, fmt.tprintf("normalize(%s) = %s, want %s", token, got, want))
		check(domain.search_type_is_valid(token), fmt.tprintf("token rejected but must be accepted: %s", token))
		ok, err := search.validate_types_csv(token)
		check(ok, fmt.tprintf("validate_types_csv(%s) rejected: %s", token, err.message))
	}

	// 3. Comma-combined scopes, including aliases mixed with canonical names.
	for csv in ([?]string{"task,comment", "tasks,comments,msg", "chain,task-chain,memories", " task , comment ", "conversation,message,agent,agent_instance,task-chain,task,comment,project,artifact,memory,skill"}) {
		ok, err := search.validate_types_csv(csv)
		check(ok, fmt.tprintf("combined scope rejected: %q (%s)", csv, err.message))
	}

	// 4. Empty/absent scope still means "all scopes" — no behavior change.
	for csv in ([?]string{"", "   "}) {
		ok, _ := search.validate_types_csv(csv)
		check(ok, fmt.tprintf("empty scope must mean all scopes: %q", csv))
	}

	// 5. The `all` wildcard is still accepted, alone and alongside real names.
	for csv in ([?]string{"all", "task,all", "all,comment"}) {
		ok, _ := search.validate_types_csv(csv)
		check(ok, fmt.tprintf("`all` wildcard must be accepted: %q", csv))
	}
	// STATED SEMANTICS: `all` excuses ITSELF from validation, not its neighbours.
	// `all,bogusscope` used to succeed (any `all` token made every type match), so
	// this is a deliberate behavior change: a typo is reported wherever it appears
	// rather than being masked by a wildcard that happens to sit next to it. The
	// result set is unaffected either way, so no caller loses hits — it only stops
	// a typo from travelling silently.
	ok_all_bad, err_all_bad := search.validate_types_csv("all,bogusscope")
	check(!ok_all_bad, "`all` must not excuse an unknown token beside it")
	check(strings.contains(err_all_bad.message, "bogusscope"), "error must name the bad token even beside `all`")
	// `all` is the caller's wildcard, not a member of the vocabulary.
	check(!domain.search_type_is_valid("all"), "`all` is not itself a search type")

	// 6. THE FIX: an unknown token errors, naming the bad value AND the valid
	//    names — it must not fall through to a zero-hit success.
	for bad in ([?]string{"bogusscope", "tsk", "conversationss", "Task", "task-chains"}) {
		ok, err := search.validate_types_csv(bad)
		check(!ok, fmt.tprintf("unknown scope accepted (the REQ-CLI-5 bug): %q", bad))
		check(err.code == .Validation_Failed, fmt.tprintf("unknown scope %q: wrong error code %v", bad, err.code))
		check(strings.contains(err.message, bad), fmt.tprintf("error for %q must name the offending value: %s", bad, err.message))
		check(strings.contains(err.message, "message"), fmt.tprintf("error for %q must list the valid scopes: %s", bad, err.message))
	}
	// An unknown token mixed into an otherwise valid CSV is still rejected.
	ok_mixed, err_mixed := search.validate_types_csv("task,bogusscope,comment")
	check(!ok_mixed, "unknown token in a combined scope must still be rejected")
	check(strings.contains(err_mixed.message, "bogusscope"), "combined-scope error must name the bad token")

	if failures > 0 {
		fmt.eprintfln("hub_search_scope_validation_test: %d failure(s)", failures)
		os.exit(1)
	}
	fmt.println("hub_search_scope_validation_test: OK")
}
