package bridgesvc

// `ham-bridge uninstall` engine (F20, REQ-ENR-6).
//
// Uninstall is the reverse of setup, but it never rolls back: every step is
// idempotent removal, so a step that still fails after remediation is reported and
// the engine goes on with the next one (a half-uninstalled bridge is worse than one
// with a single leftover file the report names). Order matters:
//
//   revoke      the hub revokes the bridge, using the bridge's OWN token, read
//               before anything is deleted. Best effort: an unreachable hub is a
//               warning (the owner revokes it in Settings -> Devices).
//   stop        the service, so nothing rewrites tokens or holds bin/ open.
//   unregister  the unit / plist / Scheduled Task / runit dir.
//   secrets     access + refresh token files and rotation leftovers, identity key +
//               epoch floor, vault keyring in Keychain / Credential Manager / keyring.
//   extensions  <data dir>/extensions{,.bak,.new} (the extensions generation).
//   caches      bootstrap/provider caches, staging, run/ (sockets, pid files).
//   binaries    bin/ and bin.bak/.
//   state       the profile's state dir (config.toml, ports, hub-url, markers).
//   data        logs and agent data: only with --purge.
//
// Like run_setup, the side effects live in Uninstall_Ops so tests inject failures.

Uninstall_Step :: enum {
	Revoke,
	Stop,
	Unregister,
	Secrets,
	Extensions,
	Caches,
	Binaries,
	State,
	Data,
}

UNINSTALL_STEP_NAMES := [Uninstall_Step]string {
	.Revoke     = "revoke",
	.Stop       = "stop",
	.Unregister = "unregister",
	.Secrets    = "secrets",
	.Extensions = "extensions",
	.Caches     = "caches",
	.Binaries   = "binaries",
	.State      = "state",
	.Data       = "data",
}

Uninstall_Mode :: enum {
	Keep_Data, // default: logs and agent data stay; every secret and binary goes
	Purge, // everything of the profile goes
}

// Uninstall_Failure classes what the engine can remediate.
Uninstall_Failure :: enum {
	None,
	Still_Running, // the bridge process survived the stop: stop again, then kill it
	Busy, // a file is held open (Windows) by the bridge or a child: stop + retry
	Hub_Unreachable, // revoke could not reach the hub: retry, then warn
	Fatal,
}

UNINSTALL_FAILURE_NAMES := [Uninstall_Failure]string {
	.None            = "",
	.Still_Running   = "still_running",
	.Busy            = "busy",
	.Hub_Unreachable = "hub_unreachable",
	.Fatal           = "fatal",
}

Uninstall_Ops :: struct {
	data:      rawptr,
	run:       proc(data: rawptr, step: Uninstall_Step) -> (ok: bool, failure: Uninstall_Failure, message: string),
	remediate: proc(data: rawptr, step: Uninstall_Step, failure: Uninstall_Failure) -> (ok: bool, message: string),
	emit:      proc(data: rawptr, ev: Event),
}

Uninstall_Result :: struct {
	failed:   bit_set[Uninstall_Step], // steps that left something behind
	warnings: bit_set[Uninstall_Step], // steps that could not finish but leave nothing usable (revoke)
}

uninstall_steps :: proc(mode: Uninstall_Mode) -> bit_set[Uninstall_Step] {
	all := ~bit_set[Uninstall_Step]{}
	return all if mode == .Purge else all - {.Data}
}

uninstall_pct :: proc(step: Uninstall_Step, done: bool) -> int {
	i := int(step) + (1 if done else 0)
	return i * 100 / len(Uninstall_Step)
}

// run_uninstall runs every step of mode. A revoke that cannot reach the hub is a
// warning; any other step that still fails after MAX_REMEDIATIONS retries is a failure.
run_uninstall :: proc(ops: Uninstall_Ops, mode: Uninstall_Mode) -> Uninstall_Result {
	res: Uninstall_Result
	steps := uninstall_steps(mode)
	for step in Uninstall_Step {
		name := UNINSTALL_STEP_NAMES[step]
		if step not_in steps {
			ops.emit(ops.data, Event{step = name, state = "skipped", pct = uninstall_pct(step, true), message = "kept (--keep-data)", attempt = 1})
			continue
		}
		ops.emit(ops.data, Event{step = name, state = "start", pct = uninstall_pct(step, false), attempt = 1})
		attempt := 1
		for {
			ok, failure, msg := ops.run(ops.data, step)
			if ok {
				ops.emit(ops.data, Event{step = name, state = "skipped" if msg == "skipped" else "ok", pct = uninstall_pct(step, true), message = msg, attempt = attempt})
				break
			}
			if failure != .Fatal && failure != .None && attempt <= MAX_REMEDIATIONS {
				fixed, how := ops.remediate(ops.data, step, failure)
				ops.emit(ops.data, Event{step = name, state = "retry", pct = uninstall_pct(step, false), message = how, attempt = attempt, failure = UNINSTALL_FAILURE_NAMES[failure]})
				attempt += 1
				if fixed do continue
			}
			warn := step == .Revoke
			ops.emit(ops.data, Event{step = name, state = "warning" if warn else "failed", pct = uninstall_pct(step, false), message = msg, attempt = attempt, failure = UNINSTALL_FAILURE_NAMES[failure]})
			if warn do res.warnings += {step}
			else do res.failed += {step}
			break
		}
	}
	done_msg := "bridge uninstalled; no credentials or secrets remain"
	if res.failed != {} do done_msg = "bridge uninstalled with leftovers (see failed steps)"
	else if res.warnings != {} do done_msg = "bridge uninstalled locally; the hub could not be told (revoke it in Settings -> Devices)"
	ops.emit(ops.data, Event{step = "uninstall", state = "done" if res.failed == {} else "failed", pct = 100, message = done_msg})
	return res
}

// uninstall_remediation_plan: what fixes a failure at a step before it is retried.
uninstall_remediation_plan :: proc(step: Uninstall_Step, failure: Uninstall_Failure) -> Remedies {
	#partial switch failure {
	case .Still_Running, .Busy:
		return {.Stop_Service}
	}
	return {}
}

// Uninstall_Paths is every path of a profile, grouped by the step that removes it.
Uninstall_Paths :: struct {
	extensions: []string,
	caches:     []string,
	binaries:   []string,
	state:      []string,
	data:       []string,
}

// uninstall_paths lists the files and directories each step removes (temp-allocated).
// Secrets are not listed here: they are named by the token file and the keystore
// scope, which only the bridge knows how to resolve.
uninstall_paths :: proc(l: Layout) -> Uninstall_Paths {
	p: Uninstall_Paths
	ext := pjoin(l.data_dir, "extensions")
	p.extensions = clone_list({ext, concat(ext, ".bak"), concat(ext, ".new")})
	p.caches = clone_list({
		pjoin(l.data_dir, ".staging"),
		pjoin(l.data_dir, "run"),
		pjoin(l.data_dir, "cache"),
		pjoin(l.data_dir, "bootstrap-cache"),
		pjoin(l.data_dir, "updates"),
		pjoin(l.data_dir, "run.cmd"),
		pjoin(l.data_dir, "task.xml"),
	})
	p.binaries = clone_list({l.bin_dir, concat(l.bin_dir, ".bak")})
	p.state = clone_list({l.state_dir})
	p.data = clone_list({l.data_dir})
	return p
}

@(private = "file")
concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(private = "file")
clone_list :: proc(items: []string) -> []string {
	out := make([]string, len(items), context.temp_allocator)
	copy(out, items)
	return out
}

// unregister_argv: the supervisor commands that forget a service, in order, after
// its file is removed (temp-allocated). launchd: bootout (already done by stop, but
// harmless); systemd: disable + daemon-reload + reset-failed; Windows: delete the task.
unregister_argv :: proc(host: Host, l: Layout) -> [][]string {
	out := make([dynamic][]string, context.temp_allocator)
	cmd :: proc(out: ^[dynamic][]string, parts: ..string) {
		a := make([]string, len(parts), context.temp_allocator)
		copy(a, parts)
		append(out, a)
	}
	unit := concat(l.service_name, ".service")
	switch l.backend {
	case .None:
	case .Systemd:
		cmd(&out, "systemctl", "--user", "disable", unit)
		cmd(&out, "systemctl", "--user", "daemon-reload")
		cmd(&out, "systemctl", "--user", "reset-failed", unit)
	case .Launchd:
		target := service_argv(host, l, .Stop)
		cmd(&out, ..target)
	case .Schtasks:
		cmd(&out, "schtasks", "/Delete", "/TN", concat("\\", l.service_name), "/F")
	case .Runit:
		cmd(&out, "sv", "down", pdir(l.service_file))
	}
	return out[:]
}

// unregister_files: what to delete so the supervisor cannot start the bridge again.
unregister_files :: proc(l: Layout) -> []string {
	switch l.backend {
	case .Systemd, .Launchd: return clone_list({l.service_file})
	case .Runit:             return clone_list({pdir(l.service_file)}) // the whole service dir
	case .Schtasks, .None:
	}
	return nil
}

// ---- update ----------------------------------------------------------------
//
// `ham-bridge update --bundle DIR` is `setup` run by the NEW binary against the
// profile it updates: setup's transaction already is the update supervisor the
// apply-bridge-update.{sh,ps1} scripts implemented (stage, bin -> bin.bak, re-render
// the service (F9), extensions on every OS, restart, health = running AND connected
// to the hub, and on any failure bin.bak restored and the old bridge restarted).
// Running the staged binary means the version being installed decides how it is
// installed.

// update_bundle_exe finds the bundle's ham-bridge: DIR/ham-bridge or DIR/bin/ham-bridge.
update_bundle_exe :: proc(host: Host, dir: string, exists: proc(path: string) -> bool) -> string {
	name := exe_name(host, "ham-bridge")
	for c in ([]string{pjoin(dir, name), pjoin(dir, "bin", name)}) {
		if exists(c) do return c
	}
	return ""
}

// update_setup_argv: the setup the new binary runs for this profile (temp-allocated).
update_setup_argv :: proc(new_exe, hub, profile: string, json_progress: bool) -> []string {
	a := make([dynamic]string, context.temp_allocator)
	append(&a, new_exe, "setup", "--hub", hub)
	if profile != "" do append(&a, "--profile", profile)
	// An update never enrolls: an enrolled profile skips the step, an unenrolled one
	// must not block on a browser approval nobody is watching.
	append(&a, "--headless")
	if json_progress do append(&a, "--json-progress")
	return a[:]
}
