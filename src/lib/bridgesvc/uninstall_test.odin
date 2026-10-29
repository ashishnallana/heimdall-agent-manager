package bridgesvc

import "core:fmt"
import "core:slice"
import "core:testing"

// Simulated uninstall: `fail_step` fails `fail_times` times with `fail_with`.
@(private = "file")
Fake_Uninstall :: struct {
	ran:        [dynamic]Uninstall_Step,
	fail_step:  Uninstall_Step,
	fail_with:  Uninstall_Failure,
	fail_times: int,
	failures:   int,
	remediated: [dynamic]Uninstall_Failure,
	events:     [dynamic]Event,
}

@(private = "file")
fake_uninstall_ops :: proc(f: ^Fake_Uninstall) -> Uninstall_Ops {
	return {
		data = f,
		run = proc(data: rawptr, step: Uninstall_Step) -> (bool, Uninstall_Failure, string) {
			f := (^Fake_Uninstall)(data)
			append(&f.ran, step)
			if step == f.fail_step && f.failures < f.fail_times {
				f.failures += 1
				return false, f.fail_with, fmt.tprintf("injected %v", f.fail_with)
			}
			return true, .None, ""
		},
		remediate = proc(data: rawptr, step: Uninstall_Step, failure: Uninstall_Failure) -> (bool, string) {
			f := (^Fake_Uninstall)(data)
			append(&f.remediated, failure)
			return true, "stopped the service"
		},
		emit = proc(data: rawptr, ev: Event) {
			f := (^Fake_Uninstall)(data)
			append(&f.events, ev)
		},
	}
}

@(private = "file")
fake_destroy :: proc(f: ^Fake_Uninstall) {
	delete(f.ran)
	delete(f.remediated)
	delete(f.events)
}

@(test)
test_uninstall_keep_data_skips_only_data :: proc(t: ^testing.T) {
	f := Fake_Uninstall{fail_step = .Data}
	defer fake_destroy(&f)
	res := run_uninstall(fake_uninstall_ops(&f), .Keep_Data)
	testing.expect_value(t, res.failed, bit_set[Uninstall_Step]{})
	testing.expect(t, !slice.contains(f.ran[:], Uninstall_Step.Data), "keep-data must not remove logs/data")
	// Neither data nor the hub row goes: uninstall keeps the bridge on the hub.
	testing.expect_value(t, len(f.ran), len(Uninstall_Step) - 2)
	testing.expect(t, !slice.contains(f.ran[:], Uninstall_Step.Revoke), "uninstall must not revoke by default")
	testing.expect_value(t, f.ran[0], Uninstall_Step.Stop)
	si, _ := slice.linear_search(f.ran[:], Uninstall_Step.Secrets)
	bi, _ := slice.linear_search(f.ran[:], Uninstall_Step.Binaries)
	testing.expect(t, si < bi, "secrets are wiped before the binaries go")
	last := f.events[len(f.events) - 1]
	testing.expect_value(t, last.state, "done")
}

@(test)
test_uninstall_purge_runs_every_step :: proc(t: ^testing.T) {
	f := Fake_Uninstall{fail_times = 0}
	defer fake_destroy(&f)
	res := run_uninstall(fake_uninstall_ops(&f), .Purge)
	testing.expect_value(t, res.failed, bit_set[Uninstall_Step]{})
	testing.expect_value(t, len(f.ran), len(Uninstall_Step) - 1)
	testing.expect(t, !slice.contains(f.ran[:], Uninstall_Step.Revoke), "purge keeps the bridge on the hub too")
	revoke_skip := false
	for ev in f.events do if ev.step == "revoke" && ev.state == "skipped" do revoke_skip = true
	testing.expect(t, revoke_skip, "the kept hub row is reported as a skipped revoke")

	// --revoke opts back in: Revoke runs first (the token is still on disk).
	g := Fake_Uninstall{fail_times = 0}
	defer fake_destroy(&g)
	res = run_uninstall(fake_uninstall_ops(&g), .Purge, revoke = true)
	testing.expect_value(t, len(g.ran), len(Uninstall_Step))
	testing.expect_value(t, g.ran[0], Uninstall_Step.Revoke)
}

@(test)
test_uninstall_remediates_busy_and_continues_after_failure :: proc(t: ^testing.T) {
	// Busy twice: remediated twice, third run succeeds.
	f := Fake_Uninstall{fail_step = .Binaries, fail_with = .Busy, fail_times = 2}
	defer fake_destroy(&f)
	res := run_uninstall(fake_uninstall_ops(&f), .Purge)
	testing.expect_value(t, res.failed, bit_set[Uninstall_Step]{})
	testing.expect_value(t, len(f.remediated), 2)

	// Fatal: no remediation, reported, and later steps still run.
	g := Fake_Uninstall{fail_step = .Secrets, fail_with = .Fatal, fail_times = 99}
	defer fake_destroy(&g)
	res = run_uninstall(fake_uninstall_ops(&g), .Purge)
	testing.expect_value(t, res.failed, bit_set[Uninstall_Step]{.Secrets})
	testing.expect(t, slice.contains(g.ran[:], Uninstall_Step.State), "a failed step does not stop the uninstall")
	testing.expect_value(t, len(g.remediated), 0)
	testing.expect_value(t, g.events[len(g.events) - 1].state, "failed")
}

@(test)
test_uninstall_unreachable_hub_is_a_warning :: proc(t: ^testing.T) {
	f := Fake_Uninstall{fail_step = .Revoke, fail_with = .Hub_Unreachable, fail_times = 99}
	defer fake_destroy(&f)
	res := run_uninstall(fake_uninstall_ops(&f), .Keep_Data, revoke = true)
	testing.expect_value(t, res.failed, bit_set[Uninstall_Step]{})
	testing.expect_value(t, res.warnings, bit_set[Uninstall_Step]{.Revoke})
	testing.expect_value(t, len(f.remediated), MAX_REMEDIATIONS)
	testing.expect(t, slice.contains(f.ran[:], Uninstall_Step.Secrets), "local secrets are wiped even when the hub is down")
}

@(test)
test_uninstall_paths_and_unregister_per_os :: proc(t: ^testing.T) {
	for target in Target_OS {
		host := Host{os = target, home = "/home/u", appdata = "C:/Users/u/AppData/Roaming", local_appdata = "C:/Users/u/AppData/Local", prefix = "/data/usr", uid = 501}
		l := layout_for(host, "heimdall-bridge-hub-example-com")
		p := uninstall_paths(l)
		testing.expect(t, slice.contains(p.binaries, l.bin_dir), "bin/ removed")
		testing.expect(t, slice.contains(p.state, l.state_dir), "state dir removed")
		testing.expect(t, slice.contains(p.data, l.data_dir), "data dir removed on purge")
		argvs := unregister_argv(host, l)
		testing.expect(t, len(argvs) > 0, "every backend unregisters")
		files := unregister_files(l)
		switch target {
		case .Linux:
			testing.expect_value(t, argvs[0][2], "disable")
			testing.expect_value(t, files[0], l.service_file)
		case .Darwin:
			testing.expect_value(t, argvs[0][1], "bootout")
			testing.expect_value(t, files[0], l.service_file)
		case .Windows:
			testing.expect_value(t, argvs[0][1], "/Delete")
			testing.expect_value(t, argvs[0][3], "\\heimdall-bridge-hub-example-com")
			testing.expect_value(t, len(files), 0)
		case .Termux:
			testing.expect_value(t, files[0], pdir(l.service_file))
		}
	}
}

@(test)
test_update_runs_the_new_binarys_setup :: proc(t: ^testing.T) {
	host := Host{os = .Windows}
	exists :: proc(path: string) -> bool {return path == "D:/bundle/bin/ham-bridge.exe"}
	exe := update_bundle_exe(host, "D:/bundle", exists)
	testing.expect_value(t, exe, "D:/bundle/bin/ham-bridge.exe")
	testing.expect_value(t, update_bundle_exe(Host{os = .Linux}, "D:/bundle", exists), "")
	argv := update_setup_argv(exe, "https://hub.example.com", "work", true)
	want := []string{exe, "setup", "--hub", "https://hub.example.com", "--profile", "work", "--headless", "--json-progress"}
	testing.expect(t, slice.equal(argv, want), fmt.tprintf("argv %v", argv))
	argv = update_setup_argv(exe, "https://hub.example.com", "", false)
	testing.expect_value(t, len(argv), 5)
}

@(test)
test_pbase :: proc(t: ^testing.T) {
	testing.expect_value(t, pbase("/home/u/.local/bin/ham-bridge"), "ham-bridge")
	testing.expect_value(t, pbase(`C:\T\ham-bridge-uninstall-3.exe`), "ham-bridge-uninstall-3.exe")
	testing.expect_value(t, pbase("ham-bridge"), "ham-bridge")
	testing.expect_value(t, pbase("/opt/bin/"), "bin")
}
