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
			testing.expect(t, !strings.contains(skill.content, "Pub/Sub subscription mechanism"), "ham-ctl-reference must not document removed Pub/Sub subscriptions")
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

@(test)
test_static_skills_artifact_authoring_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "artifact-authoring" {
			found = true
			testing.expect(t, strings.has_prefix(skill.content, "---\nname: artifact-authoring\ndescription: "), "artifact-authoring must start with name/description frontmatter")
			testing.expect(t, strings.contains(skill.content, "--kind html-bundle --directory"), "artifact-authoring must document html-bundle directory upload")
			testing.expect(t, strings.contains(skill.content, "--entry"), "artifact-authoring must document --entry")
			testing.expect(t, strings.contains(skill.content, "--kind image --content-type image/png"), "artifact-authoring must document image kind and content type")
			testing.expect(t, strings.contains(skill.content, "artifact://"), "artifact-authoring must document artifact:// delivery links")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain artifact-authoring")
}
