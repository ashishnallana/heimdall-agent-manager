package main

// REQ-SHELL-20: validation of a session's requested working directory, for every
// kind that spawns through the pty-host daemon.
//
// WHY THIS EXISTS AT ALL — it is compensating for a SILENT FALLBACK IN A VENDORED
// THIRD-PARTY CRATE, not re-checking something we already check. Do not "simplify"
// it away as redundant validation.
//
// The bridge hands `cwd` to pty-host (tools/pty_host/src/host.rs:122-124,
// `cmd.cwd(cwd)`), which hands it to portable-pty's CommandBuilder. That crate
// then does this, in portable-pty 0.9.0, CommandBuilder::as_command():
//
//     src/cmdbuilder.rs:501-507
//         let dir: &OsStr = self.cwd.as_ref()
//             .map(|dir| dir.as_os_str())
//             .filter(|dir| std::path::Path::new(dir).is_dir())  // DROPS a bad cwd
//             .unwrap_or(home.as_ref());                         // ...and uses $HOME
//     src/cmdbuilder.rs:526            cmd.current_dir(dir);
//
// A cwd that fails `is_dir()` is DISCARDED and replaced by the home directory, with
// nothing reported. The command then really does run in $HOME and exits 0, so the
// caller is told the run succeeded and the session row records a directory the
// process never entered.
//
// THE ASYMMETRY THIS EXPLAINS, and the reason the bug read as flakiness rather than
// as a missing check — two adjacent error cases take two different code paths:
//
//     --cwd /tmp        is_dir TRUE,  chdir ok      -> survives the filter, used. Correct.
//     --cwd /nope       stat ENOENT                 -> is_dir FALSE -> filtered -> $HOME. SILENT.
//     --cwd /etc/passwd is_dir FALSE (a file)       -> is_dir FALSE -> filtered -> $HOME. SILENT.
//     --cwd /root       is_dir TRUE,  chdir EACCES  -> SURVIVES the filter (stat only
//                                                      needs +x on the PARENT, not on
//                                                      /root itself), so the real chdir
//                                                      runs and fails inside the child
//                                                      -> spawn_command errors -> loud.
//
// `is_dir()` is a stat() predicate, so an existing-but-unenterable directory passes it
// and dies loudly at the real chdir, while a missing or non-directory path is deleted
// before chdir is ever attempted. That is why an ABSENT directory failed SILENTLY while
// a present-but-unusable one failed loudly.
//
// WHAT THIS CHECKS, AND WHAT IT DELIBERATELY DOES NOT. It rejects exactly the two cases
// the filter swallows: missing, and present-but-not-a-directory. It does NOT probe for
// access. EACCES is neither of those, it already fails loudly at spawn, and a probe
// would be a TOCTOU guess about the child's uid — a check that can be wrong between
// test and use is worse than the loud failure you already get.
//
// WHY BRIDGE-SIDE. The path only means anything on the machine that will spawn the
// process, so a hub-side existence check is impossible for any remote bridge and would
// validate against the wrong host's filesystem even where it happened to work.
//
// EXPANSION AND THE CHECK ARE THE SAME STEP, on purpose: checking the raw value would
// pass a literal `~/foo` that the spawn then fails to resolve. Callers store the cwd AS
// THE CALLER WROTE IT and resolve at each spawn — bridge-side and hub-side rows then
// describe a session the same way, and a future convergence check comparing them cannot
// see a spurious disagreement. Residual, already true of every cwd we store and not
// this procedure's to fix: `~` resolves against THE BRIDGE's HOME, so the stored string
// is only unambiguous on that host.
//
// A BARE `~` IS A CASE OF ITS OWN, and getting it wrong is how the first cut of this
// guard NARROWED a working input (review B1). The shared bridge_expand_home
// (src/bridge/provider_store.odin:166-173) expands only on a `~/` PREFIX, so a lone `~`
// fell through unexpanded, was stat()ed literally, and was refused with "does not
// exist: ~" — a refusal that is FALSE about the world, since the directory `~` names
// exists on every host we run on. It is also the one input where the pre-fix fallback to
// $HOME was RIGHT, and right for the right reason: $HOME is exactly what `~` denotes. So
// `~` and `~/…` are BOTH expanded here.
//
// EXPANDED HERE, NOT BY WIDENING bridge_expand_home: that helper is shared with the
// provider store and the data dir, and changing shared expansion semantics is out of
// this contract's scope. Doing it locally also makes the HOME-UNSET branch explicit
// rather than a silent fall-through — with no HOME there is no answer, so both `~` and
// `~/x` are refused saying THAT, instead of claiming a path does not exist. A `~user`
// form is deliberately NOT expanded: nothing in this product has ever resolved one, so
// it is checked literally and refused naming what was checked.

import "core:os"
import cfg_lib "odin_test:lib/config"
import "core:strings"

// Bridge_Shell_Cwd_Verdict is the outcome of resolving a requested cwd.
// Ok covers both "no cwd was requested" and "the requested one is usable".
Bridge_Shell_Cwd_Verdict :: enum {
	Ok,
	Missing,
	Not_Directory,
	// `~`/`~/…` was requested and HOME is unset, so there is nothing to expand against.
	// Its own verdict rather than folding into .Missing: the path is not known to be
	// absent, it is unresolvable, and the two want different messages.
	Home_Unset,
}

// bridge_shell_cwd_resolve trims and ~-expands `cwd` and reports whether the result is
// a directory that exists.
//
// The returned string is ALWAYS heap-allocated and always owned by the caller, on every
// verdict — including the rejections, whose error messages must name the path that was
// actually checked (the expanded one) rather than the value as typed. An empty or
// whitespace-only `cwd` means "no cwd requested" and yields ("", .Ok), which callers
// pass through as has_cwd=false to keep today's inherit-the-bridge's-cwd default.
bridge_shell_cwd_resolve :: proc(cwd: string, allocator := context.allocator) -> (resolved: string, verdict: Bridge_Shell_Cwd_Verdict) {
	return bridge_shell_cwd_resolve_with_home(cwd, cfg_lib.home_dir(context.temp_allocator), allocator)
}

// bridge_shell_cwd_resolve_with_home is the whole of the logic, with HOME PASSED IN.
//
// The seam exists for the tests, and for a specific reason rather than as a reflex: the
// HOME-unset branch can only be exercised by removing HOME, and doing that to the
// PROCESS would race every other test in this package that reads it (see
// data_dir_expand_test.odin) under the parallel test runner. Passing it makes the branch
// deterministic and leaves the process environment alone. An empty `home` means HOME is
// unset — the caller above supplies whatever the environment actually holds, which is
// the one thing a test still asserts through the wrapper.
bridge_shell_cwd_resolve_with_home :: proc(cwd, home: string, allocator := context.allocator) -> (resolved: string, verdict: Bridge_Shell_Cwd_Verdict) {
	trimmed := strings.trim_space(cwd)
	if trimmed == "" do return strings.clone("", allocator), .Ok

	if trimmed == "~" || strings.has_prefix(trimmed, "~/") {
		if strings.trim_space(home) == "" {
			// NOT .Missing. "does not exist: ~" would be a false claim about the world;
			// the truth is that the bridge cannot resolve `~` at all.
			return strings.clone(trimmed, allocator), .Home_Unset
		}
		// trimmed[1:] keeps the separator, so `~/x` becomes HOME + "/x" and a bare `~`
		// becomes HOME itself.
		resolved = trimmed == "~" ? strings.clone(home, allocator) : strings.concatenate({home, trimmed[1:]}, allocator)
	} else {
		resolved = strings.clone(trimmed, allocator)
	}

	// Missing before non-directory: os.is_dir is false for a missing path too, so the
	// order is what makes the caller's two messages distinguishable.
	if !os.exists(resolved) do return resolved, .Missing
	if !os.is_dir(resolved) do return resolved, .Not_Directory
	return resolved, .Ok
}

// bridge_shell_cwd_reject_message renders the refusal a rejected cwd reaches the caller
// with. The PATH IS NAMED: "a bad --cwd" the caller has to guess at is most of what made
// the silent fallback expensive to diagnose in the first place. Wording deliberately
// mirrors the wording of the retired bridge-local exec surface this replaced, which
// validated the same two cases — so callers that moved to `shell run` read the same
// refusal they always did. That surface is now gone (REQ-SHELL-7); this is the only
// place the contract is stated.
// Returns an allocated string; .Ok has no message and yields "".
bridge_shell_cwd_reject_message :: proc(verdict: Bridge_Shell_Cwd_Verdict, resolved: string, allocator := context.allocator) -> string {
	switch verdict {
	case .Missing:       return strings.concatenate({"shell --cwd does not exist: ", resolved}, allocator)
	case .Not_Directory: return strings.concatenate({"shell --cwd is not a directory: ", resolved}, allocator)
	// Says the thing that IS true. Claiming the path does not exist here is the mistake
	// this verdict exists to avoid.
	case .Home_Unset:    return strings.concatenate({"shell --cwd cannot be expanded because HOME is not set: ", resolved}, allocator)
	case .Ok:            return strings.clone("", allocator)
	}
	return strings.clone("", allocator)
}
