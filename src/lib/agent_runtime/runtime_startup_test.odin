package agent_runtime

import "core:strings"
import "core:testing"

@(test)
startup_prompt_preserves_bootstrap_and_runtime :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for command in ([]string{"{ctl_bin} agent start-success", "{ctl_bin} start-success", "{ctl_bin} --token {token} start-success"}) {
		profile := Agent_Profile{starter_prompt = strings.concatenate({"First, run: ", command, ". Then read AGENTS.md for context."}), extension_expected = true}
		out := render_starter_prompt_for_agent(profile, "http://hub", "tok", "inst")
		testing.expect(t, strings.has_prefix(out, "Then read AGENTS.md for context."), "keep the entire bootstrap instruction")
		testing.expect(t, !strings.contains(out, "start-success"), "remove the known startup instruction")
		testing.expect(t, strings.contains(out, "Your agent token is `tok`") && strings.contains(out, "instance id is `inst`"), "retain runtime identity")
	}
}

// A Hub older than its bridge renders the pre-bin/ shim path; the known sentence is
// still stripped when the extension reports readiness itself.
@(test)
startup_prompt_strips_legacy_rendered_instruction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: ./.heimdall/bin/ham-ctl agent start-success. Then read AGENTS.md for context.", extension_expected = true}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, !strings.contains(out, "First, run:"), "legacy sentence removed")
	testing.expect(t, strings.contains(out, "Then read AGENTS.md for context."), "keep bootstrap")
}

@(test)
startup_prompt_unknown_extension_keeps_instruction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context."}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, strings.contains(out, "First, run: ./bin/ham-ctl agent start-success."), "absent/unknown extension keeps command")
	testing.expect(t, strings.contains(out, "Then read AGENTS.md for context."), "keep bootstrap")
}

@(test)
startup_prompt_custom_prose_is_preserved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Read AGENTS.md. The start-success command is documented there. Preserve this custom guidance."
	out := render_starter_prompt_for_agent(Agent_Profile{starter_prompt = text, extension_expected = true}, "", "tok", "inst")
	testing.expect(t, strings.has_prefix(out, text), "do not strip lines or arbitrary command mentions")
}
