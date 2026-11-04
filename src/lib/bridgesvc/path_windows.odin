#+build windows
package bridgesvc

import "core:strings"
import win "core:sys/windows"

// path_final_windows resolves an EXISTING file or directory to its final path
// (junctions, symlinks and 8.3 short names expanded) with GetFinalPathNameByHandleW.
// A missing path, or any failure, returns ok=false so path_key keeps the lexical form.
path_final_windows :: proc(path: string) -> (final: string, ok: bool) {
	h := win.CreateFileW(
		win.utf8_to_wstring(path, context.temp_allocator), 0,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, nil,
	)
	if h == win.INVALID_HANDLE_VALUE do return "", false
	defer win.CloseHandle(h)
	n := win.GetFinalPathNameByHandleW(h, nil, 0, win.VOLUME_NAME_DOS)
	if n == 0 do return "", false
	buf := make([]u16, n + 1, context.temp_allocator)
	got := win.GetFinalPathNameByHandleW(h, cstring16(raw_data(buf)), u32(len(buf)), win.VOLUME_NAME_DOS)
	if got == 0 || int(got) >= len(buf) do return "", false
	s, err := win.utf16_to_utf8(buf[:got], context.temp_allocator)
	if err != nil do return "", false
	// \\?\C:\x -> C:\x ; \\?\UNC\server\share -> \\server\share
	if strings.has_prefix(s, `\\?\UNC\`) do return strings.concatenate({`\\`, s[len(`\\?\UNC\`):]}, context.temp_allocator), true
	return strings.trim_prefix(s, `\\?\`), true
}
