package agent_runtime

import "core:strings"
import "core:time"
import cfg_lib "odin_test:lib/config"
import tmux "odin_test:lib/tmux"

Agent_Profile :: struct {
	command: []string,
	base_args: []string,
	yolo_flags: []string,
	// ask_flags replace yolo_flags for permission_mode "ask" (catalog ask_args),
	// pinning a prompting mode instead of the provider's user-configured default.
	ask_flags: []string,
	prompt_flags: []string,
	starter_prompt: string,
	// Launch-scoped evidence that the provider loads the Heimdall extension.
	extension_expected: bool,
	prompt_delivery: string,
	prompt_tmux_delay_ms: int,
	prompt_tmux_enter: bool,
	model_flag: string,
	// Provider profile launch args (REQ-PROF, user-authored on the bridge): literal
	// arguments placed after the model flag and before the prompt.
	extra_args: []string,
	startup_detection: cfg_lib.Startup_Detection_Config,
	activity_detection: cfg_lib.Activity_Detection_Config,
}


// Per-agent permission modes (REQ-EXT-PERM-2), carried in the launch payload as
// "permission_mode". Only an explicit "ask" swaps the catalog yolo flags for its
// ask flags; empty or unknown values (older hubs, provider tests) keep the
// historical yolo launch.
PERMISSION_MODE_YOLO :: "yolo"
PERMISSION_MODE_ASK :: "ask"

permission_mode_uses_yolo_flags :: proc(permission_mode: string) -> bool {
	return strings.trim_space(permission_mode) != PERMISSION_MODE_ASK
}

build_agent_command :: proc(profile: Agent_Profile, model, daemon_url, agent_token, agent_instance_id: string, permission_mode := PERMISSION_MODE_YOLO) -> []string {
	if strings.trim_space(model) == "" do return nil
	argv := make([dynamic]string)
	append(&argv, ..profile.command)
	append(&argv, ..profile.base_args)
	if permission_mode_uses_yolo_flags(permission_mode) {
		append(&argv, ..profile.yolo_flags)
	} else {
		append(&argv, ..profile.ask_flags)
	}
	if strings.trim_space(profile.model_flag) == "" { delete(argv); return nil }
	append(&argv, profile.model_flag)
	append(&argv, model)
	append(&argv, ..profile.extra_args)
	if prompt_delivery(profile) == "flag-injection" {
		prompt := render_starter_prompt_for_agent(profile, daemon_url, agent_token, agent_instance_id)
		if strings.trim_space(prompt) != "" {
			append(&argv, ..profile.prompt_flags)
			append(&argv, prompt)
		}
	}
	return argv[:]
}

prompt_delivery :: proc(profile: Agent_Profile) -> string {
	delivery := profile.prompt_delivery
	if delivery == "tmux" || delivery == "none" || delivery == "flag-injection" do return delivery
	return "flag-injection"
}

render_starter_prompt_for_agent :: proc(profile: Agent_Profile, daemon_url, agent_token, agent_instance_id: string) -> string {
	out := profile.starter_prompt
	if strings.trim_space(out) == "" do return ""
	out, _ = strings.replace_all(out, "{ctl_bin} --token {token} start-success", "{ctl_bin} agent start-success")
	out, _ = strings.replace_all(out, "{ctl_bin} start-success", "{ctl_bin} agent start-success")
	if profile.extension_expected {
		// Strip only the known instruction sentence, never a line containing other
		// bootstrap instructions or arbitrary occurrences of a command in prose.
		out, _ = strings.replace_all(out, "First, run: {ctl_bin} agent start-success. ", "")
		out, _ = strings.replace_all(out, "First, run: " + CTL_SHIM_INVOCATION + " agent start-success. ", "")
		// A Hub older than this bridge still renders the pre-bin/ shim path.
		out, _ = strings.replace_all(out, "First, run: ./.heimdall/bin/ham-ctl agent start-success. ", "")
	}
	out, _ = strings.replace_all(out, "{token}", agent_token)
	out, _ = strings.replace_all(out, "{agent_token}", agent_token)
	out, _ = strings.replace_all(out, "{instance}", agent_instance_id)
	out, _ = strings.replace_all(out, "{agent_instance_id}", agent_instance_id)
	out, _ = strings.replace_all(out, "{daemon_url}", daemon_url)
	out, _ = strings.replace_all(out, "{ctl_bin}", CTL_SHIM_INVOCATION)
	out, _ = strings.replace_all(out, strings.concatenate({CTL_SHIM_INVOCATION + " --token ", agent_token, " start-success"}), CTL_SHIM_INVOCATION + " agent start-success")
	out, _ = strings.replace_all(out, "ham-ctl --token ", CTL_SHIM_INVOCATION + " --token ")
	out, _ = strings.replace_all(out, "ham-ctl start-success", CTL_SHIM_INVOCATION + " agent start-success")
	out = strings.concatenate({out, "\n\nHeimdall runtime: use `" + CTL_SHIM_INVOCATION + "` for CLI actions. Your agent token is `", agent_token, "` and your agent instance id is `", agent_instance_id, "`; they are also available in HEIMDALL_AGENT_TOKEN and HEIMDALL_AGENT_INSTANCE_ID."})
	return out
}
