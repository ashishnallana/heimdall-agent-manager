#+build linux
package main

import "core:sync"
import "core:sys/linux"
import "core:log"
import "core:testing"

// A bridge started outside a login session (the GitHub runner, ssh without
// pam_keyinit, a container) has a session keyring that does not link @u, so it
// does not possess the keys it adds there: add_key succeeds, the read back fails
// with EACCES, and enrollment reported "the vault key was decrypted but could not
// be read back from the OS keystore". KEYCTL_JOIN_SESSION_KEYRING(NULL) gives this
// test thread such an anonymous session (thread credentials only; other tests keep
// theirs). The keystore must still round-trip and delete its key.
@(test)
test_keystore_keyring_round_trip_without_session_possession :: proc(t: ^testing.T) {
	if keystore_android_selected() do return
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	KEYCTL_JOIN_SESSION_KEYRING :: 1
	if ret := linux.syscall(linux.SYS_keyctl, uintptr(KEYCTL_JOIN_SESSION_KEYRING), uintptr(0)); ret < 0 {
		log.warnf("skipped: cannot join an anonymous session keyring (errno %d)", -ret)
		return
	}
	id, _ := keystore_test_bridge_ids()
	secret := []byte{0x68, 0x65, 0x69, 0x6d, 0x64, 0x61, 0x6c, 0x6c}
	_ = keystore_os_delete_secret(.Keyring, id)
	err := keystore_os_write_secret(.Keyring, id, secret)
	if err == KEYSTORE_ERR_EPERM || err == KEYSTORE_ERR_EACCES || err == KEYSTORE_ERR_ENOSYS {
		log.warnf("skipped: kernel keyring unavailable here (errno %d)", err)
		return
	}
	testing.expectf(t, err == 0, "add_key to @u (errno %d)", err)
	buf: [64]byte
	n, status := keystore_os_read_secret_status(.Keyring, id, buf[:])
	testing.expectf(t, status == .Found && n == len(secret) && string(buf[:n]) == string(secret), "the key reads back without session possession (status %v, n %d)", status, n)
	testing.expect(t, keystore_os_delete_secret(.Keyring, id), "the key is revoked and unlinked")
	_, after := keystore_os_read_secret_status(.Keyring, id, buf[:])
	testing.expect(t, after == .Not_Found, "nothing remains after delete")
}
