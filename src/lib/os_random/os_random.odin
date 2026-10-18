// Package os_random fills buffers from the OS CSPRNG and FAILS CLOSED.
//
// It exists rather than core:crypto's rand_bytes because that routine treats an
// entropy-source failure as catastrophic and PANICS, while the credential paths
// that use this (bridge enrollment PKCE, hub device codes and tokens, ham-ctl
// ids) must be able to refuse instead: a false return means NO usable
// randomness was produced and the caller must not use any part of dst.
package os_random

// DEFAULT_SOURCE names the OS CSPRNG. On Unix it is the device read; on Windows
// any other value is opened as a file (tests use it to prove the fail-closed
// path) and this default selects BCryptGenRandom.
DEFAULT_SOURCE :: "/dev/urandom"
