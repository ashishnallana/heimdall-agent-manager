#+build linux
package main

import "core:math"

// Linux release binaries link the host's glibc dynamically and sqlite
// statically (flake.nix mkReleaseOdinPackage). sqlite calls fmod, which glibc
// 2.38 re-versioned (fmod@GLIBC_2.38), so the bridge would refuse to load on
// any older glibc although nothing else needs more than GLIBC_2.34. The release
// build defines HAM_PORTABLE_FMOD so this local definition satisfies sqlite's
// reference instead of the versioned libm symbol: the linker aliases fmod to
// it (-Wl,--defsym,fmod=ham_portable_fmod; core:c/libc already owns the Odin
// name "fmod").
when #config(HAM_PORTABLE_FMOD, false) {
	@(export, link_name = "ham_portable_fmod")
	ham_portable_fmod :: proc "c" (x, y: f64) -> f64 {
		return math.mod(x, y)
	}
}
