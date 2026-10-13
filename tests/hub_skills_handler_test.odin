// SEARCH-5 coverage for the skills lookup backing GET /api/v1/skills/<slug>.
// The handler itself gates on auth; this exercises the pure lookup over the
// compiled-in STATIC_SKILLS set: every known slug resolves to its content, and
// an unknown slug reports not-found.
package hub_skills_handler_test

import "core:fmt"
import "core:testing"
import "core:os"
import agent "odin_test:hub/service/agent"
import http "odin_test:hub/transport/http"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

@(test)
test_hub_skills_handler_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	check(len(agent.STATIC_SKILLS) > 0, "expected at least one compiled-in skill")
	for skill in agent.STATIC_SKILLS {
		content, found := http.skill_content_by_slug(skill.slug)
		check(found, fmt.tprintf("known slug must resolve: %s", skill.slug))
		check(content == skill.content, fmt.tprintf("content must match for %s", skill.slug))
		check(len(content) > 0, fmt.tprintf("skill content must be non-empty: %s", skill.slug))
	}
	_, missing := http.skill_content_by_slug("no-such-skill-slug")
	check(!missing, "unknown slug must report not-found")
	fmt.println("PASS: hub skills handler lookup")
}
