package agent

import "core:strings"
import "core:testing"

@(test)
test_static_skills_ham_ctl_reference_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "ham-ctl-reference" {
			found = true
			testing.expect(t, strings.contains(skill.content, "task-chain create --title"), "ham-ctl-reference must document task-chain create")
			testing.expect(t, strings.contains(skill.content, "--coordinator"), "ham-ctl-reference must document coordinator flag")
			testing.expect(t, strings.contains(skill.content, "task-chain subscribe"), "ham-ctl-reference must document task-chain subscribe")
			testing.expect(t, strings.contains(skill.content, "task-chain unsubscribe"), "ham-ctl-reference must document task-chain unsubscribe")
			testing.expect(t, strings.contains(skill.content, "task subscribe"), "ham-ctl-reference must document task subscribe")
			testing.expect(t, strings.contains(skill.content, "task unsubscribe"), "ham-ctl-reference must document task unsubscribe")
			testing.expect(t, strings.contains(skill.content, "Pub/Sub subscription mechanism"), "ham-ctl-reference must document Pub/Sub subscription mechanism")
			testing.expect(t, strings.contains(skill.content, "notify_task_nudge"), "ham-ctl-reference must document notify_task_nudge notice delivery")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain ham-ctl-reference")
}

@(test)
test_static_skills_heimdall_preview_setup_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "heimdall-preview-setup" {
			found = true
			testing.expect(t, strings.contains(skill.content, "shell serve"), "heimdall-preview-setup must document shell serve")
			testing.expect(t, strings.contains(skill.content, "--port"), "heimdall-preview-setup must document --port")
			testing.expect(t, strings.contains(skill.content, "127.0.0.1"), "heimdall-preview-setup must document the preferred loopback bind")
			testing.expect(t, strings.contains(skill.content, "base: './'"), "heimdall-preview-setup must document a relative Vite base")
			testing.expect(t, strings.contains(skill.content, "preview_url"), "heimdall-preview-setup must document preview_url")
			testing.expect(t, strings.contains(skill.content, "/proxy/"), "heimdall-preview-setup must document cross-bridge proxy calls")
			testing.expect(t, strings.contains(skill.content, "/p/"), "heimdall-preview-setup must document preview-origin paths")
			testing.expect(t, strings.contains(skill.content, "description: How to share a web app or API you are running on localhost"), "heimdall-preview-setup description must mention localhost")
			testing.expect(t, strings.contains(skill.content, "description:") && strings.contains(skill.content, "presenting the hub-returned `preview_url` verbatim"), "heimdall-preview-setup description must mention preview_url")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain heimdall-preview-setup")
}
