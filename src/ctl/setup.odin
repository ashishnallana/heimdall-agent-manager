package main

// heimdall-setup: idempotent per-harness readiness check + wiring guidance.
//
// Task: task_18c70887b39cdf84. Implements the detect -> auth -> writability ->
// wire-guidance -> report flow from new-machine-setup-guide.md. Phase 1 focuses on the
// safely-automatable, read-only DETECTION + POSTURE REPORT: it never installs binaries,
// never fabricates/exfiltrates credentials, and never overwrites read-only managed
// (nix/home-manager symlink) config. Human-only steps (install, auth, one-time consent)
// degrade to printed guidance.
//
// Usage:
//   ham-ctl setup                 # detect+report all known harnesses (text)
//   ham-ctl setup --json          # machine-readable report
//   ham-ctl setup --harness pi    # limit to one harness

import "core:fmt"
import "core:os"
import "core:strings"

Setup_Harness :: struct {
	name: string,
	bin: string,           // command to detect on PATH
	config_path: string,   // primary config/hook file (~ expanded)
	install_hint: string,
	auth_hint: string,
	wire_hint: string,
}

setup_known_harnesses :: proc() -> []Setup_Harness {
	home := os.get_env_alloc("HOME", context.allocator)
	j :: proc(home, rel: string) -> string { return strings.concatenate({home, "/", rel}) }
	out := make([dynamic]Setup_Harness)
	append(&out, Setup_Harness{
		name = "pi", bin = "pi", config_path = j(home, ".pi/agent/extensions"),
		install_hint = "install @earendil-works/pi-coding-agent (npm) or via nix",
		auth_hint = "set provider key env (e.g. ANTHROPIC_API_KEY) or run pi's OAuth",
		wire_hint = "activity via the harness-agnostic tmux pane-capture detector (source=pane_diff); no extension required",
	})
	append(&out, Setup_Harness{
		name = "antigravity", bin = "agy", config_path = j(home, ".gemini/hooks.json"),
		install_hint = "install antigravity-cli (agy); extension: agy plugin install <repo>/extensions/antigravity",
		auth_hint = "Google OAuth: token at ~/.gemini/antigravity-cli/antigravity-oauth-token",
		wire_hint = "agy plugin install <repo>/extensions/antigravity or load via --add-dir extensions/antigravity; hooks invoke '$HEIMDALL_CTL_BIN' extension hook antigravity",
	})
	append(&out, Setup_Harness{
		name = "claude", bin = "claude", config_path = j(home, ".claude/settings.json"),
		install_hint = "install Claude Code",
		auth_hint = "run 'claude' login (OAuth) or set ANTHROPIC_API_KEY",
		wire_hint = "wire PreToolUse/PostToolUse/Stop/Notification hooks to the wrapper command",
	})
	append(&out, Setup_Harness{
		name = "codex", bin = "codex", config_path = j(home, ".codex/config.toml"),
		install_hint = "install Codex CLI",
		auth_hint = "set OPENAI_API_KEY or run Codex login",
		wire_hint = "set notify = [\"<wrapper>\", \"--codex\"]; permission relay via MCP",
	})
	return out[:]
}

setup_path_exists :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	fi, err := os.stat(path, context.allocator)
	if err == nil { os.file_info_delete(fi, context.allocator) }
	return err == nil
}

// setup_bin_on_path resolves a bare command name against $PATH entries.
setup_bin_on_path :: proc(bin: string) -> (string, bool) {
	if strings.trim_space(bin) == "" do return "", false
	path_env := os.get_env_alloc("PATH", context.allocator)
	if path_env == "" do return "", false
	dirs := strings.split(path_env, ":")
	defer delete(dirs)
	for d in dirs {
		if d == "" do continue
		candidate := strings.concatenate({strings.trim_right(d, "/"), "/", bin})
		if setup_path_exists(candidate) do return candidate, true
	}
	return "", false
}

// setup_is_symlink reports whether a path is a symlink (managed/read-only config
// signal on nix/home-manager machines -> use an overlay, never overwrite).
setup_is_symlink :: proc(path: string) -> bool {
	if !setup_path_exists(path) do return false
	// A successful readlink means path is a symlink. On managed (nix/home-manager)
	// machines these typically resolve into /nix/store and are read-only.
	link, err := os.read_link(path, context.allocator)
	if err != nil do return false
	is_link := link != ""
	delete(link)
	return is_link
}

ctl_setup_command :: proc(args: []string) {
	as_json := has_flag(args, "--json")
	only := option_value(args, "--harness", "")
	harnesses := setup_known_harnesses()

	if as_json {
		b := strings.builder_make()
		strings.write_string(&b, "{\"harnesses\":[")
		first := true
		for h in harnesses {
			if only != "" && h.name != only do continue
			bin_path, present := setup_bin_on_path(h.bin)
			cfg_present := setup_path_exists(h.config_path)
			cfg_symlink := setup_is_symlink(h.config_path)
			if !first do strings.write_string(&b, ",")
			first = false
			strings.write_string(&b, "{\"name\":\""); json_write_string(&b, h.name)
			strings.write_string(&b, "\",\"installed\":"); strings.write_string(&b, "true" if present else "false")
			strings.write_string(&b, ",\"bin_path\":\""); json_write_string(&b, bin_path)
			strings.write_string(&b, "\",\"config_path\":\""); json_write_string(&b, h.config_path)
			strings.write_string(&b, "\",\"config_present\":"); strings.write_string(&b, "true" if cfg_present else "false")
			strings.write_string(&b, ",\"config_readonly_symlink\":"); strings.write_string(&b, "true" if cfg_symlink else "false")
			strings.write_string(&b, ",\"needs_overlay\":"); strings.write_string(&b, "true" if cfg_symlink else "false")
			strings.write_string(&b, "}")
		}
		strings.write_string(&b, "]}")
		fmt.println(strings.to_string(b))
		return
	}

	fmt.println("Ninjy harness setup report (detect-only; nothing installed or modified)")
	fmt.println("=========================================================================")
	for h in harnesses {
		if only != "" && h.name != only do continue
		bin_path, present := setup_bin_on_path(h.bin)
		cfg_present := setup_path_exists(h.config_path)
		cfg_symlink := setup_is_symlink(h.config_path)
		fmt.printf("\n[%s]\n", h.name)
		if present {
			fmt.printf("  installed:   yes (%s)\n", bin_path)
		} else {
			fmt.printf("  installed:   NO  -> %s\n", h.install_hint)
		}
		fmt.printf("  config:      %s%s\n", h.config_path, cfg_present ? "" : "  (absent)")
		if cfg_symlink {
			fmt.println("  managed:     read-only symlink -> wrapper must use a writable OVERLAY, not overwrite")
		}
		fmt.printf("  auth:        %s\n", h.auth_hint)
		fmt.printf("  wiring:      %s\n", h.wire_hint)
	}
	fmt.println("\nHuman-only steps: install binary, authenticate, one-time permission/trust consent.")
	fmt.println("Automatable by the wrapper: activity + permission hook wiring (overlay where config is read-only).")
}
