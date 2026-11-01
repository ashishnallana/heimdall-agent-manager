#+build windows
package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"

@(test)
test_background_probe_has_no_console_and_preserves_streams :: proc(t: ^testing.T) {
	script := `$ProgressPreference='SilentlyContinue'; Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ProbeConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'; [Console]::WriteLine([ProbeConsole]::GetConsoleWindow().ToInt64()); [Console]::WriteLine([Console]::ReadLine()); [Console]::WriteLine($env:HEIMDALL_HIDDEN_TEST); [Console]::WriteLine([Environment]::CurrentDirectory); [Console]::Error.WriteLine('hidden-stderr')`
	utf16 := make([]byte, len(script)*2, context.temp_allocator)
	for c, i in transmute([]byte)script do utf16[i*2] = c
	encoded := base64.encode(utf16, base64.ENC_TABLE, context.temp_allocator)
	temp := os.temp_dir(context.temp_allocator) or_else ""
	path := fmt.tprintf("%s/hidden probe %d", temp, os.get_pid())
	testing.expect(t, os.make_directory(path) == nil)
	defer os.remove(path)
	input_r, input_w, ie := os.pipe()
	output_r, output_w, oe := os.pipe()
	testing.expect(t, ie == nil && oe == nil)
	if ie != nil || oe != nil do return
	defer os.close(input_r)
	defer os.close(output_r)
	_, _ = os.write_string(input_w, "probe input\n")
	os.close(input_w)
	env := make([dynamic]string, context.temp_allocator)
	for entry in os.environ(context.temp_allocator) or_else nil do append(&env, entry)
	append(&env, "HEIMDALL_HIDDEN_TEST=probe-env")
	shell := fmt.tprintf("%s/System32/WindowsPowerShell/v1.0/powershell.exe", os.get_env("SystemRoot", context.temp_allocator))
	process, err := bridge_os_start_hidden({command = {shell, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded}, stdin = input_r, stdout = output_w, stderr = output_w, env = env[:], working_dir = path})
	os.close(output_w)
	testing.expect(t, err == nil)
	if err != nil do return
	state, wait_error := os.process_wait(process, 10*time.Second)
	if wait_error != nil { _ = os.process_kill(process); _, _ = os.process_wait(process, time.Second) }
	testing.expect(t, wait_error == nil && state.exit_code == 0)
	output, read_error := os.read_entire_file(output_r, context.temp_allocator)
	testing.expect(t, read_error == nil)
	text := strings.replace_all(string(output), "\r", "", context.temp_allocator) or_else ""
	testing.expect(t, strings.has_prefix(text, "0\nprobe input\nprobe-env\n"), fmt.tprintf("child must have no console and retain stdin/stdout/environment: %q", text))
	testing.expect(t, strings.contains(text, "hidden probe"), "working directory survives")
	testing.expect(t, strings.contains(text, "hidden-stderr"), "stderr is captured")
}

@(test)
test_background_probe_does_not_inherit_other_handles :: proc(t: ^testing.T) {
	temp := os.temp_dir(context.temp_allocator) or_else ""
	path := fmt.tprintf("%s/hidden-probe-log-%d.tmp", temp, os.get_pid())
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	defer os.remove(path)
	security := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	log := win.CreateFileW(wpath, win.GENERIC_WRITE, 0, &security, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, log != win.INVALID_HANDLE_VALUE)
	if log == win.INVALID_HANDLE_VALUE do return
	shell := fmt.tprintf("%s/System32/WindowsPowerShell/v1.0/powershell.exe", os.get_env("SystemRoot", context.temp_allocator))
	child, err := bridge_os_start_hidden({command = {shell, "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 10"}})
	win.CloseHandle(log)
	testing.expect(t, err == nil)
	if err != nil do return
	defer { _ = os.process_kill(child); _, _ = os.process_wait(child, time.Second) }
	testing.expect(t, bridge_os_pid_alive(child.pid))
	reopened := win.CreateFileW(wpath, win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, reopened != win.INVALID_HANDLE_VALUE, "only explicit standard handles may be inherited")
	if reopened != win.INVALID_HANDLE_VALUE do win.CloseHandle(reopened)
}

@(test)
test_background_probe_keeps_deadline_cleanup :: proc(t: ^testing.T) {
	shell := fmt.tprintf("%s/System32/WindowsPowerShell/v1.0/powershell.exe", os.get_env("SystemRoot", context.temp_allocator))
	started := time.now()
	output, errors, ok, timed_out := bridge_process_run_capture({shell, "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"}, 100*time.Millisecond)
	defer { delete(output); delete(errors) }
	testing.expect(t, !ok && timed_out)
	testing.expect(t, time.diff(started, time.now()) < 3*time.Second, "hidden subprocesses must still be killed and reaped on deadline")
}
