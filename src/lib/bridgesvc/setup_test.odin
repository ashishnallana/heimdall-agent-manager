package bridgesvc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Fake install: `live` is what is installed and running; each step stages a change
// in `pending`, undo discards it, and only a full success commits it. A rollback
// must therefore always leave live == "v1".
@(private = "file")
Fake :: struct {
	live:        string,
	pending:     [Step]bool,
	fail_step:   Step,
	fail_with:   Failure,
	fail_times:  int, // how many runs of fail_step fail before it succeeds
	failures:    int,
	remediated:  [dynamic]Failure,
	undone:      [dynamic]Step,
	events:      [dynamic]Event,
	finished_ok: bool,
	inject:      bool,
}

@(private = "file")
fake_ops :: proc(f: ^Fake) -> Setup_Ops {
	return Setup_Ops {
		data = f,
		run = proc(data: rawptr, step: Step) -> Step_Result {
			f := (^Fake)(data)
			f.pending[step] = true
			if f.inject && step == f.fail_step && f.failures < f.fail_times {
				f.failures += 1
				return {failure = f.fail_with, message = fmt.tprintf("injected %v", f.fail_with)}
			}
			return {ok = true}
		},
		remediate = proc(data: rawptr, step: Step, failure: Failure) -> (bool, string) {
			f := (^Fake)(data)
			append(&f.remediated, failure)
			return true, FAILURE_NAMES[failure]
		},
		undo = proc(data: rawptr, step: Step) {
			f := (^Fake)(data)
			f.pending[step] = false
			append(&f.undone, step)
		},
		emit = proc(data: rawptr, ev: Event) {
			f := (^Fake)(data)
			append(&f.events, ev)
		},
		finish = proc(data: rawptr, ok: bool) {
			f := (^Fake)(data)
			f.finished_ok = ok
			if ok do f.live = "v2"
		},
	}
}

@(private = "file")
fake_make :: proc() -> Fake {
	return Fake{live = "v1", remediated = make([dynamic]Failure, context.temp_allocator), undone = make([dynamic]Step, context.temp_allocator), events = make([dynamic]Event, context.temp_allocator)}
}

@(test)
test_setup_success_emits_every_step :: proc(t: ^testing.T) {
	f := fake_make()
	ok, _ := run_setup(fake_ops(&f))
	testing.expect(t, ok)
	testing.expect_value(t, f.live, "v2")
	testing.expect_value(t, len(f.events), 2 * len(Step) + 1)
	last := f.events[len(f.events) - 1]
	testing.expect_value(t, last.state, "done")
	testing.expect_value(t, last.pct, 100)
	testing.expect(t, strings.contains(event_json(f.events[0], context.temp_allocator), `"step":"lock"`))
}

@(test)
test_setup_fatal_failure_at_each_step_rolls_back :: proc(t: ^testing.T) {
	for step in Step {
		f := fake_make()
		f.inject, f.fail_step, f.fail_with, f.fail_times = true, step, .Fatal, 99
		ok, failed := run_setup(fake_ops(&f))
		testing.expectf(t, !ok, "step %v: setup succeeded", step)
		testing.expect_value(t, failed, step)
		testing.expectf(t, f.live == "v1", "step %v: previous install not kept", step)
		testing.expect(t, !f.finished_ok)
		for s in Step do testing.expectf(t, !f.pending[s], "step %v: %v left applied", step, s)
		// Undone in reverse order, starting with the failed step.
		testing.expect_value(t, len(f.undone), int(step) + 1)
		testing.expect_value(t, f.undone[0], step)
		testing.expect_value(t, f.undone[len(f.undone) - 1], Step.Lock)
		testing.expect_value(t, len(f.remediated), 0)
	}
}

@(test)
test_setup_remediates_known_failures_and_reports_attempts :: proc(t: ^testing.T) {
	cases := [?]struct {
		step:    Step,
		failure: Failure,
	}{{.Lock, .Stale_Lock}, {.Ports, .Port_In_Use}, {.Service, .Stale_Service}, {.Binaries, .Partial_Install}, {.Start, .Port_In_Use}}
	for c in cases {
		f := fake_make()
		f.inject, f.fail_step, f.fail_with, f.fail_times = true, c.step, c.failure, 1
		ok, _ := run_setup(fake_ops(&f))
		testing.expectf(t, ok, "%v/%v not remediated", c.step, c.failure)
		testing.expect_value(t, len(f.remediated), 1)
		testing.expect_value(t, f.remediated[0], c.failure)
		retries := 0
		for ev in f.events {
			if ev.state == "retry" {
				retries += 1
				testing.expect_value(t, ev.step, STEP_NAMES[c.step])
				testing.expect_value(t, ev.failure, FAILURE_NAMES[c.failure])
				testing.expect_value(t, ev.attempt, 1)
			}
			if ev.step == STEP_NAMES[c.step] && ev.state == "ok" do testing.expect_value(t, ev.attempt, 2)
		}
		testing.expect_value(t, retries, 1)
	}
}

@(test)
test_setup_gives_up_after_max_remediations :: proc(t: ^testing.T) {
	f := fake_make()
	f.inject, f.fail_step, f.fail_with, f.fail_times = true, .Verify, .Stale_Service, 99
	ok, failed := run_setup(fake_ops(&f))
	testing.expect(t, !ok)
	testing.expect_value(t, failed, Step.Verify)
	testing.expect_value(t, len(f.remediated), MAX_REMEDIATIONS)
	testing.expect_value(t, f.live, "v1")
	saw_failed := false
	for ev in f.events do if ev.state == "failed" do saw_failed = true
	testing.expect(t, saw_failed)
}

@(private = "file")
lock_alive_none :: proc(pid: int) -> bool {return false}
@(private = "file")
lock_alive_all :: proc(pid: int) -> bool {return true}

@(test)
test_install_lock_stale_owner :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/bridgesvc-lock-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	path := pjoin(dir, LOCK_FILE)
	now := time.now()
	testing.expect(t, lock_acquire(path, 100, now, lock_alive_all).ok)
	// Live owner: refuse.
	held := lock_acquire(path, 200, now, lock_alive_all)
	testing.expect(t, !held.ok)
	testing.expect_value(t, held.failure, Failure.Fatal)
	// Dead owner: stale, broken by remediation, then acquired.
	stale := lock_acquire(path, 200, now, lock_alive_none)
	testing.expect_value(t, stale.failure, Failure.Stale_Lock)
	// Too old even with a (reused) live pid.
	old := lock_acquire(path, 200, time.time_add(now, 2 * LOCK_MAX_AGE), lock_alive_all)
	testing.expect_value(t, old.failure, Failure.Stale_Lock)
	testing.expect(t, lock_break(path))
	testing.expect(t, lock_acquire(path, 200, now, lock_alive_all).ok)
	// Only the owner releases.
	lock_release(path, 100)
	testing.expect(t, os.exists(path))
	lock_release(path, 200)
	testing.expect(t, !os.exists(path))
	// Garbage lock content is stale once it is past the write grace.
	_ = os.write_entire_file_from_string(path, "garbage")
	testing.expect_value(t, lock_acquire(path, 300, time.time_add(now, 2 * LOCK_WRITE_GRACE), lock_alive_all).failure, Failure.Stale_Lock)
}

@(test)
test_install_lock_being_written_is_held :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/bridgesvc-lock-race-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	path := pjoin(dir, LOCK_FILE)
	// An owner between create and write: empty file, fresh mtime. It must not be
	// classified stale (whose remediation would delete the live owner's lock).
	_ = os.write_entire_file_from_string(path, "")
	r := lock_acquire(path, 400, time.now(), lock_alive_none)
	testing.expect_value(t, r.failure, Failure.Fatal)
	testing.expect(t, os.exists(path))
	// A successful acquire leaves only the lock, with complete content, behind.
	_ = os.remove(path)
	testing.expect(t, lock_acquire(path, 400, time.now(), lock_alive_all).ok)
	owner, _, ok := lock_read(path)
	testing.expect(t, ok && owner == 400)
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect_value(t, len(entries), 1)
}

@(test)
test_remediation_plan :: proc(t: ^testing.T) {
	testing.expect_value(t, remediation_plan(.Lock, .Stale_Lock), Remedies{.Break_Lock})
	testing.expect_value(t, remediation_plan(.Stage, .Partial_Install), Remedies{.Discard_Staging})
	testing.expect_value(t, remediation_plan(.Binaries, .Partial_Install), Remedies{.Discard_Staging, .Restage})
	testing.expect_value(t, remediation_plan(.Binaries, .Stale_Service), Remedies{.Stop_Service})
	// Start re-runs itself after remediation; Verify only polls, so its plans must
	// end by starting the service again.
	testing.expect_value(t, remediation_plan(.Start, .Stale_Service), Remedies{.Stop_Service, .Register})
	testing.expect_value(t, remediation_plan(.Verify, .Stale_Service), Remedies{.Stop_Service, .Register, .Start_Service})
	testing.expect_value(t, remediation_plan(.Verify, .Port_In_Use), Remedies{.Stop_Service, .Reallocate_Ports, .Register, .Start_Service})
	testing.expect_value(t, remediation_plan(.Verify, .Fatal), Remedies{})
}

// Sim models the supervisor the way the real Host sees it: Verify succeeds only
// if the service is running, and it can run only on a port nobody else holds.
// Remediation executes remediation_plan against it, so a plan that forgets to
// start the service again cannot pass.
@(private = "file")
Sim :: struct {
	running:    bool,
	port:       int,
	held_port:  int, // port held by another process
	crash_once: bool, // the first start dies right away (stale unit)
	starts:     int,
}

@(private = "file")
sim_start :: proc(m: ^Sim) {
	m.starts += 1
	m.running = m.port != m.held_port && !(m.crash_once && m.starts == 1)
}

@(private = "file")
sim_ops :: proc(m: ^Sim) -> Setup_Ops {
	return Setup_Ops {
		data = m,
		run = proc(data: rawptr, step: Step) -> Step_Result {
			m := (^Sim)(data)
			#partial switch step {
			case .Start:
				sim_start(m)
				return {ok = true}
			case .Verify:
				if m.running do return {ok = true}
				if m.port == m.held_port do return {failure = .Port_In_Use, message = "port held"}
				return {failure = .Stale_Service, message = "not running"}
			}
			return {ok = true}
		},
		remediate = proc(data: rawptr, step: Step, failure: Failure) -> (bool, string) {
			m := (^Sim)(data)
			for r in remediation_plan(step, failure) {
				#partial switch r {
				case .Stop_Service:     m.running = false
				case .Reallocate_Ports: m.port += 2
				case .Start_Service:    sim_start(m)
				}
			}
			return true, "plan"
		},
		undo = proc(data: rawptr, step: Step) {},
		emit = proc(data: rawptr, ev: Event) {},
	}
}

@(test)
test_verify_remediation_leaves_service_started :: proc(t: ^testing.T) {
	stale := Sim{port = 49323, held_port = -1, crash_once = true}
	ok, failed := run_setup(sim_ops(&stale))
	testing.expectf(t, ok, "stale_service at verify not remediated (failed at %v)", failed)
	testing.expect(t, stale.running)
	testing.expect_value(t, stale.starts, 2)

	busy := Sim{port = 49323, held_port = 49323}
	ok, failed = run_setup(sim_ops(&busy))
	testing.expectf(t, ok, "port_in_use at verify not remediated (failed at %v)", failed)
	testing.expect(t, busy.running)
	testing.expect(t, busy.port != busy.held_port)
}

@(test)
test_render_service_files :: proc(t: ^testing.T) {
	in_ := Render_Input{hub = "https://hub.example.com", profile = "work", path_env = "/usr/bin", bridge_port = 49325, endpoint_port = 49326}
	name := "heimdall-bridge-hub-example-com_work"
	linux := Host{os = .Linux, home = "/home/u"}
	unit := render_service_file(linux, layout_for(linux, name), in_)
	testing.expect(t, strings.contains(unit, `ExecStart="/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-bridge" "--hub" "https://hub.example.com"`))
	testing.expect(t, strings.contains(unit, `"--port" "49325" "--local-endpoint-port" "49326"`))
	testing.expect(t, strings.contains(unit, `Environment="HEIMDALL_BRIDGE_SERVICE_NAME=heimdall-bridge-hub-example-com_work.service"`))
	testing.expect(t, strings.contains(unit, "(profile work)"))
	mac := Host{os = .Darwin, home = "/Users/u"}
	plist := render_service_file(mac, layout_for(mac, name), in_)
	testing.expect(t, strings.contains(plist, "<key>Label</key>\n\t<string>heimdall-bridge-hub-example-com_work</string>"))
	testing.expect(t, strings.index(plist, "HEIMDALL_BRIDGE_ENDPOINT") < strings.index(plist, "PATH</key>"))
	win := Host{os = .Windows, appdata = "C:/R", local_appdata = "C:/L"}
	wl := layout_for(win, name)
	xml := render_service_file(win, wl, in_)
	testing.expect(t, strings.contains(xml, "<LogonTrigger>"))
	testing.expect(t, strings.contains(xml, "C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/run.cmd"))
	cmd := render_windows_run_cmd(win, wl, in_)
	testing.expect(t, strings.contains(cmd, "ham-bridge.exe"))
	testing.expect(t, strings.contains(cmd, "\r\n"))
	termux := Host{os = .Termux, home = "/h", prefix = "/p"}
	run := render_service_file(termux, layout_for(termux, name), in_)
	testing.expect(t, strings.has_prefix(run, "#!/p/bin/sh\n"))
	testing.expect(t, strings.contains(run, "export TMPDIR='/p/tmp'"))
	// Escaping: XML and systemd specifiers.
	odd := Render_Input{hub = "https://h.example.com", bridge_port = 1, endpoint_port = 2, path_env = "/a&b%c"}
	testing.expect(t, strings.contains(render_service_file(mac, layout_for(mac, name), odd), "/a&amp;b%c"))
	testing.expect(t, strings.contains(render_service_file(linux, layout_for(linux, name), odd), "/a&b%%c"))
}
