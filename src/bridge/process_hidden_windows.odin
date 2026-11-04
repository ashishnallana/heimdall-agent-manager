#+build windows
package main

import "core:os"
import "core:strings"
import win "core:sys/windows"

foreign import hidden_kernel "system:kernel32.lib"
foreign hidden_kernel {
	InitializeProcThreadAttributeList :: proc "system" (list: rawptr, count, flags: u32, size: ^uintptr) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc "system" (list: rawptr, flags: u32, attribute: uintptr, value: rawptr, size: uintptr, previous: rawptr, returned: ^uintptr) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc "system" (list: rawptr) ---
}

Bridge_Hidden_Startup :: struct { base: win.STARTUPINFOW, attributes: rawptr }

// Background probes must never create a console, and may inherit only their
// explicitly supplied standard streams, never the Bridge's log/socket handles.
bridge_os_start_hidden :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	if len(desc.command) == 0 do return {}, os.General_Error.Invalid_Command
	line := strings.builder_make(context.temp_allocator)
	for arg, i in desc.command {
		if i > 0 do strings.write_byte(&line, ' ')
		strings.write_byte(&line, '"')
		slashes := 0
		for c in transmute([]byte)arg {
			if c == '\\' { slashes += 1; continue }
			count := slashes*2+1 if c == '"' else slashes
			for _ in 0..<count do strings.write_byte(&line, '\\')
			slashes = 0
			strings.write_byte(&line, c)
		}
		for _ in 0..<slashes*2 do strings.write_byte(&line, '\\')
		strings.write_byte(&line, '"')
	}
	command := win.utf8_to_wstring(strings.to_string(line), context.temp_allocator)
	working: win.wstring
	if desc.working_dir != "" do working = win.utf8_to_wstring(desc.working_dir, context.temp_allocator)
	environment: rawptr
	if desc.env != nil {
		block := strings.builder_make(context.temp_allocator)
		for entry in desc.env { strings.write_string(&block, entry); strings.write_byte(&block, 0) }
		strings.write_byte(&block, 0)
		environment = rawptr(win.utf8_to_wstring(strings.to_string(block), context.temp_allocator))
	}
	null := win.CreateFileW(win.L("NUL"), win.GENERIC_READ|win.GENERIC_WRITE, win.FILE_SHARE_READ|win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if null == win.INVALID_HANDLE_VALUE do return {}, os.Platform_Error(win.GetLastError())
	defer win.CloseHandle(null)
	handles: [3]win.HANDLE
	defer for handle in handles do if handle != nil do win.CloseHandle(handle)
	streams := [3]^os.File{desc.stdin, desc.stdout, desc.stderr}
	for file, i in streams {
		source := null if file == nil else win.HANDLE(os.fd(file))
		if !win.DuplicateHandle(win.GetCurrentProcess(), source, win.GetCurrentProcess(), &handles[i], 0, true, win.DUPLICATE_SAME_ACCESS) do return {}, os.Platform_Error(win.GetLastError())
	}
	size: uintptr
	_ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
	storage := make([]byte, int(size), context.temp_allocator)
	attributes := rawptr(raw_data(storage))
	if !InitializeProcThreadAttributeList(attributes, 1, 0, &size) do return {}, os.Platform_Error(win.GetLastError())
	defer DeleteProcThreadAttributeList(attributes)
	if !UpdateProcThreadAttribute(attributes, 0, 0x20002, rawptr(&handles[0]), size_of(handles), nil, nil) do return {}, os.Platform_Error(win.GetLastError())
	startup := Bridge_Hidden_Startup{base = {cb = size_of(Bridge_Hidden_Startup), dwFlags = win.STARTF_USESTDHANDLES|win.STARTF_USESHOWWINDOW, wShowWindow = u16(win.SW_HIDE), hStdInput = handles[0], hStdOutput = handles[1], hStdError = handles[2]}, attributes = attributes}
	process: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, command, nil, nil, true, win.CREATE_NO_WINDOW|win.CREATE_UNICODE_ENVIRONMENT|win.EXTENDED_STARTUPINFO_PRESENT, environment, working, &startup.base, &process) do return {}, os.Platform_Error(win.GetLastError())
	win.CloseHandle(process.hThread)
	return os.Process{pid = int(process.dwProcessId), handle = uintptr(process.hProcess)}, nil
}
