#+build windows
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"

@(test)
test_daemon_does_not_inherit_bridge_log_handles :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/bridge-daemon-log-%d.tmp", os.temp_dir(context.temp_allocator), os.get_pid())
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	defer os.remove(path)
	security := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	log := win.CreateFileW(wpath, win.GENERIC_WRITE, 0, &security, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, log != win.INVALID_HANDLE_VALUE)
	if log == win.INVALID_HANDLE_VALUE do return
	shell := strings.concatenate({os.get_env("SystemRoot", context.temp_allocator), "/System32/WindowsPowerShell/v1.0/powershell.exe"}, context.temp_allocator)
	child, err := bridge_os_start_daemon([]string{shell, "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 10"})
	win.CloseHandle(log)
	testing.expect(t, err == nil)
	if err != nil do return
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, time.Second)
	}
	testing.expect(t, bridge_os_pid_alive(child.pid), "test child must still be alive when the log is reopened")
	reopened := win.CreateFileW(wpath, win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, reopened != win.INVALID_HANDLE_VALUE, "a live daemon must not keep the Bridge's exclusive log handle open")
	if reopened != win.INVALID_HANDLE_VALUE do win.CloseHandle(reopened)
}
