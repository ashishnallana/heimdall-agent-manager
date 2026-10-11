package contracts

import "core:strings"

// RELEASE_TARGET names the release bundle this binary ships in
// (heimdall-local-<target>.tar.gz). Only builds whose target differs from the
// compiler's os/arch set it: flake.nix mkTermuxOdinPackage passes
// -define:HAM_RELEASE_TARGET=termux-arm64, because the Termux bundle is built
// with -target:linux_arm64 but must never be replaced by the glibc linux-arm64
// bundle (Android's seccomp kills glibc's set_robust_list with SIGSYS).
// Empty means "<os>-<arch> of the compile target".
RELEASE_TARGET :: #config(HAM_RELEASE_TARGET, "")

RELEASE_TARGET_TERMUX_PREFIX :: "termux-"

// termux_env_detected reports a Termux runtime: TERMUX_VERSION is set
// (termux-exec exports it to every Termux process) or $PREFIX lives in the
// Termux app's data directory. Pure so callers can test both signals.
termux_env_detected :: proc(termux_version, prefix: string) -> bool {
	if strings.trim_space(termux_version) != "" do return true
	return strings.has_prefix(prefix, "/data/data/com.termux/") || prefix == "/data/data/com.termux"
}

// release_target_resolve picks the update target a binary must report and
// fetch. compiled is RELEASE_TARGET, native the compiler's "<os>-<arch>".
//
// A binary built for linux-<arch> that finds itself under Termux reports
// termux-<arch> (so no hub ever offers it the glibc bundle again) and returns
// update_blocked: it cannot know the termux bundle is compatible with the way
// it was installed, so self-update is refused and the operator reinstalls with
// install.sh. The result is temp-allocated when it differs from the inputs.
release_target_resolve :: proc(compiled, native: string, on_termux: bool) -> (target: string, update_blocked: bool) {
	built := strings.trim_space(compiled)
	if built == "" do built = native
	if !on_termux || strings.has_prefix(built, RELEASE_TARGET_TERMUX_PREFIX) {
		return built, false
	}
	arch := native
	if dash := strings.last_index_byte(native, '-'); dash >= 0 do arch = native[dash + 1:]
	return strings.concatenate({RELEASE_TARGET_TERMUX_PREFIX, arch}, context.temp_allocator), true
}

// release_asset_names_other_target is true when url's file name follows the
// release convention heimdall-local-<target>[-<tag>].tar.gz for a target other
// than target. URLs outside the convention (hub-hosted paths, test fixtures)
// return false: the hub's catalog lookup is authoritative for those, and this
// check only exists to stop a mis-resolved catalog from bricking a bridge.
release_asset_names_other_target :: proc(url, target: string) -> bool {
	name := url
	if q := strings.index_any(name, "?#"); q >= 0 do name = name[:q]
	if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
	PREFIX :: "heimdall-local-"
	if !strings.has_prefix(name, PREFIX) || !strings.has_suffix(name, ".tar.gz") do return false
	rest := name[len(PREFIX):]
	if !strings.has_prefix(rest, target) do return true
	tail := rest[len(target):]
	return !(strings.has_prefix(tail, "-") || strings.has_prefix(tail, "."))
}
