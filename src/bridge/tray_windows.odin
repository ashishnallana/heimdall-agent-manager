package main

// Windows tray: Shell_NotifyIconW on a hidden window of this process. A click on
// the icon opens a popup menu built from the latest status (TrackPopupMenu with
// TPM_RETURNCMD, so the chosen entry comes back synchronously). Explorer that
// restarts broadcasts "TaskbarCreated"; the icon is re-added then.
//
// Console: the login entry starts this console binary under `conhost --headless`
// (bridgesvc.tray_launch_argv). The tray keeps that hidden console on purpose:
// every console helper it runs (powershell.exe for the Scheduled Task state each
// poll, `service restart`, `setup`) inherits it. FreeConsole would make each of
// them open a console window of its own.
//
// Icons: the logo + status dot .ico per level is embedded; the entry that fits
// the small-icon size is turned into an HICON once at start. A level whose icon
// cannot be made shows the stock icon instead, with the reason logged.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import bridgesvc "odin_test:lib/bridgesvc"

@(private = "file")
TRAY_CALLBACK :: win.WM_APP + 1
@(private = "file")
TRAY_STATUS_ID :: 1000

@(private = "file")
tray_hwnd: win.HWND
@(private = "file")
tray_nid: win.NOTIFYICONDATAW
@(private = "file")
tray_taskbar_created: win.UINT
@(private = "file")
tray_title := "Checking..."
@(private = "file")
tray_enabled: Bridge_Tray_Enabled
@(private = "file")
tray_clicked: Maybe(bridgesvc.Tray_Action)

@(private = "file")
TRAY_LOGO_ICO := [bridgesvc.Tray_Level][]byte {
	.Ok      = #load("assets/tray/tray-ok.ico"),
	.Warning = #load("assets/tray/tray-warning.ico"),
	.Error   = #load("assets/tray/tray-error.ico"),
}
@(private = "file")
tray_logo: [bridgesvc.Tray_Level]win.HICON

foreign import user32 "system:User32.lib"

// core:sys/windows declares CreateIconFromResourceEx in its Kernel32.lib block,
// which does not export it; bind it from User32.lib here.
@(default_calling_convention = "system", private = "file")
foreign user32 {
	CreateIconFromResourceEx :: proc(presbits: win.PBYTE, dwResSize: win.DWORD, fIcon: win.BOOL, dwVer: win.DWORD, cxDesired: win.INT, cyDesired: win.INT, Flags: win.UINT) -> win.HICON ---
}

// tray_load_logo makes the per-level logo icons at the small-icon size; a level
// that fails keeps nil (stock icon) and is logged.
@(private = "file")
tray_load_logo :: proc() {
	cx := int(win.GetSystemMetrics(win.SM_CXSMICON))
	if cx <= 0 do cx = 16
	for ico, level in TRAY_LOGO_ICO {
		img, _, ok := bridgesvc.tray_ico_pick(ico, cx)
		if ok do tray_logo[level] = CreateIconFromResourceEx(win.PBYTE(raw_data(img)), win.DWORD(len(img)), true, 0x00030000, win.INT(cx), win.INT(cx), win.LR_DEFAULTCOLOR)
		if tray_logo[level] != nil do continue
		why := "malformed embedded .ico" if !ok else fmt.tprintf("CreateIconFromResourceEx failed (error %d)", win.GetLastError())
		fmt.eprintfln("ham-bridge tray: %v logo icon unavailable (%s); using the stock icon", level, why)
	}
}

@(private = "file")
tray_icon :: proc(level: bridgesvc.Tray_Level) -> win.HICON {
	if tray_logo[level] != nil do return tray_logo[level]
	// MAKEINTRESOURCE ids of the stock icons.
	id: uintptr = 32512 // IDI_APPLICATION
	switch level {
	case .Ok:      id = 32516 // IDI_INFORMATION
	case .Warning: id = 32515 // IDI_WARNING
	case .Error:   id = 32513 // IDI_ERROR
	}
	return win.LoadIconW(nil, win.LPCWSTR(rawptr(id)))
}

@(private = "file")
tray_set_tip :: proc(tip: string) {
	w := win.utf8_to_utf16(tip, context.temp_allocator)
	n := min(len(w), len(tray_nid.szTip) - 1)
	copy(tray_nid.szTip[:n], w[:n])
	tray_nid.szTip[n] = 0
}

@(private = "file")
tray_show_menu :: proc(hwnd: win.HWND) {
	menu := win.CreatePopupMenu()
	if menu == nil do return
	defer win.DestroyMenu(menu)
	win.AppendMenuW(menu, win.MF_STRING | win.MF_GRAYED, TRAY_STATUS_ID, win.utf8_to_wstring(tray_title, context.temp_allocator))
	win.AppendMenuW(menu, win.MF_SEPARATOR, 0, nil)
	for a in bridgesvc.Tray_Action {
		if a == .Uninstall || a == .Quit do win.AppendMenuW(menu, win.MF_SEPARATOR, 0, nil)
		flags: win.UINT = win.MF_STRING
		if !tray_enabled[a] do flags |= win.MF_GRAYED
		win.AppendMenuW(menu, flags, win.UINT_PTR(int(a) + 1), win.utf8_to_wstring(bridgesvc.TRAY_ACTION_LABELS[a], context.temp_allocator))
	}
	pt: win.POINT
	win.GetCursorPos(&pt)
	// Without this the menu does not close when the user clicks elsewhere.
	win.SetForegroundWindow(hwnd)
	cmd := win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nil)
	win.PostMessageW(hwnd, win.WM_NULL, 0, 0)
	if cmd >= 1 && cmd <= len(bridgesvc.Tray_Action) do tray_clicked = bridgesvc.Tray_Action(cmd - 1)
}

@(private = "file")
tray_wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = tray_context
	switch {
	case msg == TRAY_CALLBACK:
		switch win.UINT(lparam) {
		case win.WM_LBUTTONUP, win.WM_RBUTTONUP, win.WM_CONTEXTMENU:
			tray_show_menu(hwnd)
		}
		return 0
	case tray_taskbar_created != 0 && msg == tray_taskbar_created:
		win.Shell_NotifyIconW(win.NIM_ADD, &tray_nid)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private = "file")
tray_context: runtime.Context

// Explorer starts Run entries early at login; the notification area may not
// accept icons yet. Retry this long (TaskbarCreated also re-adds) before degrading.
@(private = "file")
TRAY_NIM_ADD_WAIT :: 2 * time.Minute

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetConsoleProcessList :: proc(lpdwProcessList: [^]win.DWORD, dwProcessCount: win.DWORD) -> win.DWORD ---
}

// tray_hide_own_console hides a console window that only this process uses (the
// tray started without conhost --headless); a console shared with a terminal the
// user ran `ham-bridge tray` from is left alone.
@(private = "file")
tray_hide_own_console :: proc() {
	pids: [2]win.DWORD
	if GetConsoleProcessList(&pids[0], len(pids)) != 1 do return
	if hwnd := win.GetConsoleWindow(); hwnd != nil do win.ShowWindow(hwnd, win.SW_HIDE)
}

bridge_tray_native_init :: proc(title: string) -> (ok: bool, why: string) {
	tray_context = context
	tray_hide_own_console()
	tray_load_logo()
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name := win.utf8_to_wstring("HeimdallBridgeTray", context.allocator)
	wc := win.WNDCLASSEXW{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = tray_wndproc, hInstance = instance, lpszClassName = class_name}
	if win.RegisterClassExW(&wc) == 0 do return false, "RegisterClassExW failed"
	tray_hwnd = win.CreateWindowExW(0, class_name, win.utf8_to_wstring(title, context.temp_allocator), win.WS_OVERLAPPED, 0, 0, 0, 0, nil, nil, instance, nil)
	if tray_hwnd == nil do return false, "CreateWindowExW failed"
	tray_taskbar_created = win.RegisterWindowMessageW(win.utf8_to_wstring("TaskbarCreated", context.temp_allocator))
	tray_nid = win.NOTIFYICONDATAW{cbSize = size_of(win.NOTIFYICONDATAW), hWnd = tray_hwnd, uID = 1, uFlags = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP, uCallbackMessage = TRAY_CALLBACK, hIcon = tray_icon(.Warning)}
	tray_set_tip(title)
	deadline := time.time_add(time.now(), TRAY_NIM_ADD_WAIT)
	// NIM_MODIFY succeeding means a TaskbarCreated handler already added the icon.
	for !win.Shell_NotifyIconW(win.NIM_ADD, &tray_nid) && !win.Shell_NotifyIconW(win.NIM_MODIFY, &tray_nid) {
		if time.diff(time.now(), deadline) <= 0 do return false, "Shell_NotifyIconW failed (no taskbar)"
		// Pump so a TaskbarCreated broadcast is handled (it adds the icon itself).
		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
		time.sleep(time.Second)
	}
	return true, ""
}

bridge_tray_native_update :: proc(view: bridgesvc.Tray_View, enabled: Bridge_Tray_Enabled) {
	delete(tray_title)
	tray_title = strings.clone(view.title)
	tray_enabled = enabled
	tray_nid.hIcon = tray_icon(view.level)
	tray_set_tip(view.tooltip)
	win.Shell_NotifyIconW(win.NIM_MODIFY, &tray_nid)
}

bridge_tray_native_pump :: proc(wait: time.Duration) -> (action: bridgesvc.Tray_Action, clicked: bool) {
	deadline := time.time_add(time.now(), wait)
	msg: win.MSG
	for time.diff(time.now(), deadline) > 0 {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
		if a, ok := tray_clicked.?; ok {
			tray_clicked = nil
			return a, true
		}
		time.sleep(20 * time.Millisecond)
	}
	return {}, false
}

bridge_tray_native_confirm :: proc(text: string) -> bool {
	MB_ICONWARNING :: 0x30
	MB_SETFOREGROUND :: 0x10000
	r := win.MessageBoxW(tray_hwnd, win.utf8_to_wstring(text, context.temp_allocator), win.utf8_to_wstring("Heimdall Bridge", context.temp_allocator), win.MB_YESNO | MB_ICONWARNING | MB_SETFOREGROUND)
	return r == win.IDYES
}

bridge_tray_native_shutdown :: proc() {
	win.Shell_NotifyIconW(win.NIM_DELETE, &tray_nid)
	if tray_hwnd != nil do win.DestroyWindow(tray_hwnd)
	for &icon in tray_logo {
		if icon != nil do win.DestroyIcon(icon)
		icon = nil
	}
}
