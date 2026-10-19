#+build linux
// These tests force the Termux keystore path (keystore_android_test_force),
// which only exists in the Linux build; contracts.release_target_resolve itself
// is platform-neutral and covered here on Linux.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// REQ-T13-1: the compile-time release target wins; a linux-* build that finds
// itself under Termux reports termux-<arch> and must refuse self-update.
@(test)
test_release_target_resolve :: proc(t: ^testing.T) {
	target, blocked := contracts.release_target_resolve("", "linux-arm64", false)
	testing.expect_value(t, target, "linux-arm64")
	testing.expect(t, !blocked, "native linux build updates normally")

	target, blocked = contracts.release_target_resolve("termux-arm64", "linux-arm64", true)
	testing.expect_value(t, target, "termux-arm64")
	testing.expect(t, !blocked, "termux bundle on Termux updates normally")

	target, blocked = contracts.release_target_resolve("termux-arm64", "linux-arm64", false)
	testing.expect_value(t, target, "termux-arm64")
	testing.expect(t, !blocked, "termux build keeps its target even without Termux env (e.g. under runsv with a scrubbed env)")

	target, blocked = contracts.release_target_resolve("", "linux-arm64", true)
	testing.expect_value(t, target, "termux-arm64")
	testing.expect(t, blocked, "glibc linux build under Termux reports termux and is blocked")

	target, blocked = contracts.release_target_resolve("", "linux-amd64", true)
	testing.expect_value(t, target, "termux-amd64")
	testing.expect(t, blocked, "arch is carried over")

	testing.expect(t, contracts.termux_env_detected("0.118.0", ""), "TERMUX_VERSION detects Termux")
	testing.expect(t, contracts.termux_env_detected("", "/data/data/com.termux/files/usr"), "Termux PREFIX detects Termux")
	testing.expect(t, !contracts.termux_env_detected(" ", "/usr"), "plain Linux is not Termux")
}

// REQ-T13-1: a mis-resolved catalog can never install another target's bundle.
@(test)
test_release_asset_names_other_target :: proc(t: ^testing.T) {
	other :: contracts.release_asset_names_other_target
	testing.expect(t, other("https://github.com/o/r/releases/download/v0.3.30/heimdall-local-linux-arm64-v0.3.30.tar.gz", "termux-arm64"), "linux asset for termux bridge")
	testing.expect(t, other("https://mirror.example/heimdall-local-linux-arm64.tar.gz?x=1", "termux-arm64"), "unversioned mirror asset, query ignored")
	testing.expect(t, other("https://mirror.example/heimdall-local-termux-arm64.tar.gz", "linux-arm64"), "termux asset for linux bridge")
	testing.expect(t, other("https://mirror.example/heimdall-local-linux-arm64x.tar.gz", "linux-arm64"), "target must end at a separator")
	testing.expect(t, !other("https://github.com/o/r/releases/download/v0.3.30/heimdall-local-termux-arm64-v0.3.30.tar.gz", "termux-arm64"), "matching versioned asset")
	testing.expect(t, !other("https://mirror.example/heimdall-local-termux-arm64.tar.gz", "termux-arm64"), "matching unversioned asset")
	testing.expect(t, !other("/api/v1/updates/bundle/abc.tar.gz", "termux-arm64"), "non-convention URL defers to the hub catalog")
	testing.expect(t, !other("/tmp/stage/bundle.tar.gz", "linux-amd64"), "local fixture path defers to the hub catalog")
	testing.expect(t, !other("https://github.com/o/r/releases/download/v0.4.9/heimdall-local-windows-amd64-v0.4.9.zip", "windows-amd64"), "matching windows zip asset")
	testing.expect(t, other("https://github.com/o/r/releases/download/v0.4.9/heimdall-local-linux-amd64-v0.4.9.tar.gz", "windows-amd64"), "linux asset for windows bridge")
	testing.expect(t, other("https://github.com/o/r/releases/download/v0.4.9/heimdall-local-windows-amd64-v0.4.9.zip", "linux-amd64"), "windows zip for linux bridge")
}

@(test)
test_bridge_update_target_refusal :: proc(t: ^testing.T) {
	refusal := bridge_update_target_refusal_for("termux-arm64", true, "https://x/heimdall-local-termux-arm64.tar.gz")
	testing.expect(t, strings.contains(refusal, "self-update refused"), "blocked build refuses even a matching asset")
	testing.expect(t, strings.contains(refusal, "reinstall with install.sh"), "refusal tells the operator what to do")

	refusal = bridge_update_target_refusal_for("termux-arm64", false, "https://x/heimdall-local-linux-arm64-v0.3.30.tar.gz")
	testing.expect(t, strings.contains(refusal, "not built for this bridge's target termux-arm64"), "foreign bundle refused")

	testing.expect_value(t, bridge_update_target_refusal_for("termux-arm64", false, "https://x/heimdall-local-termux-arm64-v0.3.30.tar.gz"), "")
	testing.expect_value(t, bridge_update_target_refusal_for("linux-amd64", false, "/test/bundle.tar.gz"), "")
}

// The hello carries the resolved target: under Termux a linux build says termux.
@(test)
test_bridge_hello_target_follows_termux_runtime :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	keystore_android_test_force = true
	defer keystore_android_test_force = false
	target, blocked := bridge_release_target()
	when contracts.RELEASE_TARGET == "" {
		testing.expect_value(t, target, fmt.tprintf("termux-%s", bridge_arch_string()))
		testing.expect(t, blocked, "test build is not the termux bundle, so self-update is blocked")
	}
	testing.expect(t, strings.has_prefix(target, "termux-"), "termux runtime never reports linux-*")
	hello := bridge_hub_hello_json()
	defer delete(hello)
	testing.expect(t, strings.contains(hello, fmt.tprintf("\"target\":\"%s\"", target)), "hello reports the termux target")

	_, apply_detail := bridge_runtime_apply_update(nil, "", "", "https://x/heimdall-local-linux-arm64.tar.gz", "abc", true, 0)
	testing.expect(t, strings.contains(apply_detail, "self-update refused"), "apply refuses before staging anything")
}

// REQ-BUPD-1: bridge_hub_hello_json includes version, commit_sha, built_at, and target.
@(test)
test_bridge_hub_hello_version_fields :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	hello := bridge_hub_hello_json()
	defer delete(hello)

	testing.expect(t, strings.contains(hello, "\"type\":\"bridge_hello\""), "type is bridge_hello")
	testing.expect(t, strings.contains(hello, fmt.tprintf("\"protocol_version\":%d", contracts.BRIDGE_WS_FRAME_VERSION)), "protocol_version is the bridge-ws frame version")
	expected_version := fmt.tprintf("\"version\":\"%s\"", contracts.APP_VERSION)
	testing.expect(t, strings.contains(hello, expected_version), "version serialized from contracts")
	testing.expect(t, strings.contains(hello, "\"commit_sha\":\""), "commit_sha key present")
	testing.expect(t, strings.contains(hello, "\"built_at\":\""), "built_at key present")
	testing.expect(t, strings.contains(hello, "\"target\":\""), "target key present")

	target := bridge_target_string()
	expected_target := fmt.tprintf("\"target\":\"%s\"", target)
	testing.expect(t, strings.contains(hello, expected_target), "target matches host os and arch")
}
