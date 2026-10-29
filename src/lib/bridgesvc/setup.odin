package bridgesvc

// Transactional `ham-bridge setup` engine (F6, F9, ENR-12).
//
// setup is an ordered list of steps. Each step runs; on a KNOWN failure (stale
// lock, port in use, stale service, partial install) the engine asks the caller
// to remediate and retries, reporting every attempt as a progress event; on an
// unknown failure, or when retries are exhausted, every step that already ran is
// undone in reverse order so the previous install is left as it was (and running).
//
// The engine is pure: the side effects live in Setup_Ops so tests inject a failure
// at every step. The progress protocol (--json-progress) is documented in
// docs/bridge-setup-progress.md.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Step :: enum {
	Lock, // install lock with stale-owner detection
	Stage, // staging dir; snapshot of the current install for rollback
	Binaries, // copy bundle binaries into bin/, keeping bin.bak
	Config, // write or migrate config.toml, hub-url, profile
	Ports, // allocate / keep the profile's loopback ports
	Service, // render (always re-render) the service file and register it
	Enroll, // enroll unless already enrolled to this hub
	Extensions, // copy the bundled provider extensions, install/repair them per provider
	Start, // (re)start the service
	Verify, // service running and the bridge reports connected
}

STEP_NAMES := [Step]string {
	.Lock     = "lock",
	.Stage    = "stage",
	.Binaries = "binaries",
	.Config   = "config",
	.Ports    = "ports",
	.Service  = "service",
	.Enroll   = "enroll",
	.Extensions = "extensions",
	.Start    = "start",
	.Verify   = "verify",
}

// Failure classes the engine knows how to remediate (ENR-12).
Failure :: enum {
	None,
	Stale_Lock, // remediation: remove the dead owner's lock
	Port_In_Use, // remediation: re-allocate ports, re-render
	Stale_Service, // remediation: stop/unregister the old service, re-register
	Partial_Install, // remediation: discard the half-copied staging, recopy
	Fatal, // no remediation: roll back
}

FAILURE_NAMES := [Failure]string {
	.None            = "",
	.Stale_Lock      = "stale_lock",
	.Port_In_Use     = "port_in_use",
	.Stale_Service   = "stale_service",
	.Partial_Install = "partial_install",
	.Fatal           = "fatal",
}

// Remedy is one remediation action; the caller executes a plan in enum order.
Remedy :: enum {
	Break_Lock, // remove the dead owner's install lock
	Discard_Staging, // drop the half-copied staging dir; put bin.bak back if bin/ is gone
	Restage, // copy the bundle into staging again
	Stop_Service,
	Reallocate_Ports, // move to free loopback ports
	Register, // re-render and re-register the service file
	Start_Service, // start it again: a Verify retry only polls, it starts nothing
}
Remedies :: bit_set[Remedy]

// remediation_plan says how to fix a known failure at a step so that re-running
// that step can succeed. Fatal/None have no plan.
remediation_plan :: proc(step: Step, failure: Failure) -> Remedies {
	plan: Remedies
	#partial switch failure {
	case .Stale_Lock:
		plan = {.Break_Lock}
	case .Partial_Install:
		plan = {.Discard_Staging}
		if step == .Binaries do plan += {.Restage}
	case .Stale_Service:
		plan = {.Stop_Service}
		if step == .Start || step == .Verify do plan += {.Register}
		if step == .Verify do plan += {.Start_Service}
	case .Port_In_Use:
		plan = {.Stop_Service, .Reallocate_Ports, .Register}
		if step == .Verify do plan += {.Start_Service}
	}
	return plan
}

Step_Result :: struct {
	ok:      bool,
	failure: Failure,
	message: string,
	log:     string, // path of a log with details, optional
}

// Event is one --json-progress line.
Event :: struct {
	step:    string `json:"step"`,
	state:   string `json:"state"`, // start|progress|ok|skipped|retry|failed|rollback|done
	pct:     int    `json:"pct"`,
	message: string `json:"message"`,
	log:     string `json:"log"`,
	attempt: int    `json:"attempt"`,
	failure: string `json:"failure,omitempty"`,
}

Setup_Ops :: struct {
	data:      rawptr,
	run:       proc(data: rawptr, step: Step) -> Step_Result,
	remediate: proc(data: rawptr, step: Step, failure: Failure) -> (ok: bool, message: string),
	undo:      proc(data: rawptr, step: Step),
	emit:      proc(data: rawptr, ev: Event),
	finish:    proc(data: rawptr, ok: bool), // release the lock, drop staging
}

MAX_REMEDIATIONS :: 2

event_json :: proc(ev: Event, allocator := context.allocator) -> string {
	data, _ := json.marshal(ev, allocator = allocator)
	return string(data)
}

step_pct :: proc(step: Step, done: bool) -> int {
	n := len(Step)
	i := int(step) + (1 if done else 0)
	return i * 100 / n
}

// run_setup executes every step; failed_step is meaningful only when !ok.
run_setup :: proc(ops: Setup_Ops) -> (ok: bool, failed_step: Step) {
	completed := make([dynamic]Step, context.temp_allocator)
	for step in Step {
		name := STEP_NAMES[step]
		ops.emit(ops.data, Event{step = name, state = "start", pct = step_pct(step, false), attempt = 1})
		attempt := 1
		for {
			r := ops.run(ops.data, step)
			if r.ok {
				state := "skipped" if r.message == "skipped" else "ok"
				ops.emit(ops.data, Event{step = name, state = state, pct = step_pct(step, true), message = r.message, log = r.log, attempt = attempt})
				break
			}
			remediable := r.failure != .Fatal && r.failure != .None
			if remediable && attempt <= MAX_REMEDIATIONS {
				fixed, how := ops.remediate(ops.data, step, r.failure)
				ops.emit(ops.data, Event{step = name, state = "retry", pct = step_pct(step, false), message = fmt.tprintf("%s; remediation: %s", r.message, how), log = r.log, attempt = attempt, failure = FAILURE_NAMES[r.failure]})
				attempt += 1
				if fixed do continue
			}
			ops.emit(ops.data, Event{step = name, state = "failed", pct = step_pct(step, false), message = r.message, log = r.log, attempt = attempt, failure = FAILURE_NAMES[r.failure]})
			// The failed step may have half-applied: undo it too, then everything before it.
			append(&completed, step)
			for i := len(completed) - 1; i >= 0; i -= 1 {
				s := completed[i]
				ops.undo(ops.data, s)
				ops.emit(ops.data, Event{step = STEP_NAMES[s], state = "rollback", pct = step_pct(step, false), message = "restored previous state"})
			}
			if ops.finish != nil do ops.finish(ops.data, false)
			return false, step
		}
		append(&completed, step)
	}
	if ops.finish != nil do ops.finish(ops.data, true)
	ops.emit(ops.data, Event{step = "setup", state = "done", pct = 100, message = "bridge installed, enrolled and running"})
	return true, .Verify
}

// ---- install lock ----------------------------------------------------------

LOCK_FILE :: ".install.lock"
// A lock older than this is stale even if its pid was reused by another process.
LOCK_MAX_AGE :: 30 * time.Minute

Pid_Alive_Proc :: #type proc(pid: int) -> bool

// A lock file this young that cannot be parsed is being written by its owner
// (only reachable where hard links are unsupported); it is held, not stale.
LOCK_WRITE_GRACE :: 10 * time.Second

// lock_acquire atomically creates path holding "<pid> <unix seconds>": the content
// is written to a private temp file first and hard-linked into place, so another
// setup never sees a half-written lock. When it is held, it reports Stale_Lock if
// the owner is dead or the lock too old (the caller remediates with lock_break),
// otherwise Fatal.
lock_acquire :: proc(path: string, pid: int, now: time.Time, alive: Pid_Alive_Proc) -> Step_Result {
	content := fmt.tprintf("%d %d\n", pid, time.to_unix_seconds(now))
	tmp := fmt.tprintf("%s.%d.tmp", path, pid)
	if os.write_entire_file_from_string(tmp, content, {.Read_User, .Write_User}) == nil {
		lerr := os.link(tmp, path)
		_ = os.remove(tmp)
		if lerr == nil do return {ok = true}
		if os.exists(path) do return lock_held(path, now, alive)
		// No hard links on this filesystem: fall back to an exclusive create.
	}
	f, err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if err == nil {
		_, _ = os.write_string(f, content)
		os.close(f)
		return {ok = true}
	}
	return lock_held(path, now, alive)
}

@(private = "file")
lock_held :: proc(path: string, now: time.Time, alive: Pid_Alive_Proc) -> Step_Result {
	owner, started, parsed := lock_read(path)
	if !parsed {
		if mtime, merr := os.modification_time_by_path(path); merr == nil && time.diff(mtime, now) < LOCK_WRITE_GRACE {
			return {failure = .Fatal, message = fmt.tprintf("another setup is creating the install lock %s", path)}
		}
		return {failure = .Stale_Lock, message = fmt.tprintf("install lock %s is unreadable", path)}
	}
	if !alive(owner) || time.diff(time.unix(started, 0), now) > LOCK_MAX_AGE {
		return {failure = .Stale_Lock, message = fmt.tprintf("install lock %s is held by dead or stale owner pid %d", path, owner)}
	}
	return {failure = .Fatal, message = fmt.tprintf("another setup (pid %d) is running for this profile", owner)}
}

lock_read :: proc(path: string) -> (pid: int, started: i64, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return 0, 0, false
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) != 2 do return 0, 0, false
	p, pok := strconv.parse_int(fields[0], 10)
	s, sok := strconv.parse_i64(fields[1], 10)
	return p, s, pok && sok
}

lock_break :: proc(path: string) -> bool {return os.remove(path) == nil || !os.exists(path)}

lock_release :: proc(path: string, pid: int) {
	owner, _, ok := lock_read(path)
	if ok && owner == pid do _ = os.remove(path)
}
