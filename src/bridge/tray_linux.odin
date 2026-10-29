package main

// Linux tray: a StatusNotifierItem through libayatana-appindicator3 (or the older
// libappindicator3) on GTK 3, which KDE, Xfce, Cinnamon, MATE, Budgie, LXQt and
// GNOME with the AppIndicator extension render; ayatana falls back to an XEmbed
// icon when no StatusNotifierWatcher runs. The libraries are loaded at RUNTIME
// (dlopen), so ham-bridge never links GTK: a desktop without them (or a headless
// host) gets "no tray" from bridge_tray_native_init and the bridge is unaffected.
//
// Icons: the logo + status dot PNGs are embedded and written to a per-user icon
// directory, which app_indicator_set_icon_theme_path adds to the lookup (the SNI
// IconThemePath), so each level is an icon name in it. Any failure there keeps
// the stock theme icons, with the reason logged.

import "core:bytes"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

@(private = "file")
Gtk :: struct {
	init_check:          proc "c" (argc: ^i32, argv: rawptr) -> b32,
	main_iteration_do:   proc "c" (blocking: b32) -> b32,
	events_pending:      proc "c" () -> b32,
	menu_new:            proc "c" () -> rawptr,
	menu_item_new:       proc "c" (label: cstring) -> rawptr,
	menu_item_set_label: proc "c" (item: rawptr, label: cstring),
	separator_new:       proc "c" () -> rawptr,
	menu_shell_append:   proc "c" (menu: rawptr, item: rawptr),
	widget_show_all:     proc "c" (w: rawptr),
	widget_set_sensitive: proc "c" (w: rawptr, on: b32),
	widget_destroy:      proc "c" (w: rawptr),
	message_dialog_new:  proc "c" (parent: rawptr, flags: i32, type: i32, buttons: i32, format: cstring, #c_vararg args: ..any) -> rawptr,
	dialog_run:          proc "c" (d: rawptr) -> i32,
	window_set_keep_above: proc "c" (w: rawptr, on: b32),
	signal_connect_data: proc "c" (instance: rawptr, signal: cstring, handler: rawptr, data: rawptr, destroy: rawptr, flags: i32) -> u64,
	indicator_new:       proc "c" (id: cstring, icon: cstring, category: i32) -> rawptr,
	indicator_set_status: proc "c" (ind: rawptr, status: i32),
	indicator_set_icon_full: proc "c" (ind: rawptr, icon: cstring, desc: cstring),
	indicator_set_title: proc "c" (ind: rawptr, title: cstring),
	indicator_set_menu:  proc "c" (ind: rawptr, menu: rawptr),
	// Optional: nil keeps the stock icons.
	indicator_set_icon_theme_path: proc "c" (ind: rawptr, path: cstring),
}

// 44 px: hosts scale it down to the panel size, exactly 2x on a 22 px panel, so
// HiDPI panels get a sharp icon too.
@(private = "file")
TRAY_LOGO_PNG := [bridgesvc.Tray_Level][]byte {
	.Ok      = #load("assets/tray/tray-ok-44.png"),
	.Warning = #load("assets/tray/tray-warning-44.png"),
	.Error   = #load("assets/tray/tray-error-44.png"),
}
@(private = "file")
TRAY_LOGO_NAMES := [bridgesvc.Tray_Level]cstring {
	.Ok      = "heimdall-bridge-tray-ok",
	.Warning = "heimdall-bridge-tray-warning",
	.Error   = "heimdall-bridge-tray-error",
}
@(private = "file")
TRAY_STOCK_NAMES := [bridgesvc.Tray_Level]cstring {
	.Ok      = "network-transmit-receive",
	.Warning = "network-offline",
	.Error   = "dialog-error",
}
@(private = "file")
tray_icon_names := TRAY_STOCK_NAMES

@(private = "file")
tray_gtk: Gtk
@(private = "file")
tray_indicator: rawptr
@(private = "file")
tray_status_item: rawptr
@(private = "file")
tray_items: [bridgesvc.Tray_Action]rawptr
@(private = "file")
tray_clicked: Maybe(bridgesvc.Tray_Action)

@(private = "file")
tray_load :: proc() -> (ok: bool, why: string) {
	sym :: proc(libs: []dynlib.Library, name: string, out: ^rawptr) -> bool {
		for l in libs {
			if l == nil do continue
			if p, found := dynlib.symbol_address(l, name); found {
				out^ = p
				return true
			}
		}
		return false
	}
	gtk, gtk_ok := dynlib.load_library("libgtk-3.so.0")
	if !gtk_ok do return false, strings.concatenate({"cannot load libgtk-3.so.0: ", dynlib.last_error()}, context.temp_allocator)
	gobj, _ := dynlib.load_library("libgobject-2.0.so.0")
	ind: dynlib.Library
	for name in ([?]string{"libayatana-appindicator3.so.1", "libappindicator3.so.1"}) {
		if l, lok := dynlib.load_library(name); lok {
			ind = l
			break
		}
	}
	if ind == nil do return false, "libayatana-appindicator3 / libappindicator3 not found"
	libs := []dynlib.Library{gtk, gobj, ind}
	g := &tray_gtk
	names := [?]struct {
		name: string,
		ptr:  ^rawptr,
	} {
		{"gtk_init_check", (^rawptr)(&g.init_check)},
		{"gtk_main_iteration_do", (^rawptr)(&g.main_iteration_do)},
		{"gtk_events_pending", (^rawptr)(&g.events_pending)},
		{"gtk_menu_new", (^rawptr)(&g.menu_new)},
		{"gtk_menu_item_new_with_label", (^rawptr)(&g.menu_item_new)},
		{"gtk_menu_item_set_label", (^rawptr)(&g.menu_item_set_label)},
		{"gtk_separator_menu_item_new", (^rawptr)(&g.separator_new)},
		{"gtk_menu_shell_append", (^rawptr)(&g.menu_shell_append)},
		{"gtk_widget_show_all", (^rawptr)(&g.widget_show_all)},
		{"gtk_widget_set_sensitive", (^rawptr)(&g.widget_set_sensitive)},
		{"gtk_widget_destroy", (^rawptr)(&g.widget_destroy)},
		{"gtk_message_dialog_new", (^rawptr)(&g.message_dialog_new)},
		{"gtk_dialog_run", (^rawptr)(&g.dialog_run)},
		{"gtk_window_set_keep_above", (^rawptr)(&g.window_set_keep_above)},
		{"g_signal_connect_data", (^rawptr)(&g.signal_connect_data)},
		{"app_indicator_new", (^rawptr)(&g.indicator_new)},
		{"app_indicator_set_status", (^rawptr)(&g.indicator_set_status)},
		{"app_indicator_set_icon_full", (^rawptr)(&g.indicator_set_icon_full)},
		{"app_indicator_set_title", (^rawptr)(&g.indicator_set_title)},
		{"app_indicator_set_menu", (^rawptr)(&g.indicator_set_menu)},
	}
	for n in names {
		if !sym(libs, n.name, n.ptr) do return false, strings.concatenate({"missing symbol ", n.name}, context.temp_allocator)
	}
	_ = sym(libs, "app_indicator_set_icon_theme_path", (^rawptr)(&g.indicator_set_icon_theme_path))
	return true, ""
}

// tray_write_logo_icons writes the embedded level icons into a per-user cache
// directory (left alone when already identical) and returns it.
@(private = "file")
tray_write_logo_icons :: proc() -> (dir: string, why: string) {
	cache, cerr := os.user_cache_dir(context.temp_allocator)
	if cerr != nil || cache == "" do return "", fmt.tprintf("no user cache directory (%v)", cerr)
	dir, _ = filepath.join({cache, "heimdall-bridge", "tray-icons"}, context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil do return "", fmt.tprintf("cannot create %s: %v", dir, err)
	for png, level in TRAY_LOGO_PNG {
		file, _ := filepath.join({dir, strings.concatenate({string(TRAY_LOGO_NAMES[level]), ".png"}, context.temp_allocator)}, context.temp_allocator)
		if have, rerr := os.read_entire_file(file, context.temp_allocator); rerr == nil && bytes.equal(have, png) do continue
		if err := os.write_entire_file(file, png); err != nil do return "", fmt.tprintf("cannot write %s: %v", file, err)
	}
	return dir, ""
}

// tray_use_logo_icons points the indicator at the logo icons; on failure the
// stock names stay and the reason is logged.
@(private = "file")
tray_use_logo_icons :: proc() {
	why: string
	if tray_gtk.indicator_set_icon_theme_path == nil {
		why = "app_indicator_set_icon_theme_path not available"
	} else if dir, werr := tray_write_logo_icons(); dir == "" {
		why = werr
	} else {
		tray_gtk.indicator_set_icon_theme_path(tray_indicator, strings.clone_to_cstring(dir, context.temp_allocator))
		tray_icon_names = TRAY_LOGO_NAMES
		return
	}
	fmt.eprintfln("ham-bridge tray: logo icons unavailable (%s); using stock icons", why)
}

@(private = "file")
tray_on_activate :: proc "c" (item: rawptr, data: rawptr) {
	tray_clicked = bridgesvc.Tray_Action(uintptr(data))
}

bridge_tray_native_init :: proc(title: string) -> (ok: bool, why: string) {
	if lok, lwhy := tray_load(); !lok do return false, lwhy
	g := &tray_gtk
	if !g.init_check(nil, nil) do return false, "cannot open the display"
	APP_INDICATOR_CATEGORY_SYSTEM_SERVICES :: 2
	APP_INDICATOR_STATUS_ACTIVE :: 1
	tray_indicator = g.indicator_new("heimdall-bridge", "network-idle", APP_INDICATOR_CATEGORY_SYSTEM_SERVICES)
	if tray_indicator == nil do return false, "app_indicator_new failed"
	tray_use_logo_icons()
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	g.indicator_set_title(tray_indicator, ctitle)
	menu := g.menu_new()
	tray_status_item = g.menu_item_new("Checking...")
	g.widget_set_sensitive(tray_status_item, false)
	g.menu_shell_append(menu, tray_status_item)
	g.menu_shell_append(menu, g.separator_new())
	for a in bridgesvc.Tray_Action {
		if a == .Uninstall || a == .Quit do g.menu_shell_append(menu, g.separator_new())
		item := g.menu_item_new(strings.clone_to_cstring(bridgesvc.TRAY_ACTION_LABELS[a], context.temp_allocator))
		g.signal_connect_data(item, "activate", rawptr(tray_on_activate), rawptr(uintptr(a)), nil, 0)
		g.menu_shell_append(menu, item)
		tray_items[a] = item
	}
	g.widget_show_all(menu)
	g.indicator_set_menu(tray_indicator, menu)
	g.indicator_set_status(tray_indicator, APP_INDICATOR_STATUS_ACTIVE)
	return true, ""
}

bridge_tray_native_update :: proc(view: bridgesvc.Tray_View, enabled: Bridge_Tray_Enabled) {
	g := &tray_gtk
	g.indicator_set_icon_full(tray_indicator, tray_icon_names[view.level], strings.clone_to_cstring(view.tooltip, context.temp_allocator))
	g.indicator_set_title(tray_indicator, strings.clone_to_cstring(view.tooltip, context.temp_allocator))
	g.menu_item_set_label(tray_status_item, strings.clone_to_cstring(view.title, context.temp_allocator))
	for a in bridgesvc.Tray_Action do g.widget_set_sensitive(tray_items[a], b32(enabled[a]))
}

bridge_tray_native_pump :: proc(wait: time.Duration) -> (action: bridgesvc.Tray_Action, clicked: bool) {
	g := &tray_gtk
	deadline := time.time_add(time.now(), wait)
	for time.diff(time.now(), deadline) > 0 {
		for g.events_pending() do g.main_iteration_do(false)
		if a, ok := tray_clicked.?; ok {
			tray_clicked = nil
			return a, true
		}
		time.sleep(20 * time.Millisecond)
	}
	return {}, false
}

bridge_tray_native_confirm :: proc(text: string) -> bool {
	g := &tray_gtk
	GTK_DIALOG_MODAL :: 1
	GTK_MESSAGE_QUESTION :: 2
	GTK_BUTTONS_YES_NO :: 4
	GTK_RESPONSE_YES :: -8
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	d := g.message_dialog_new(nil, GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION, GTK_BUTTONS_YES_NO, "%s", ctext)
	if d == nil do return false
	g.window_set_keep_above(d, true)
	resp := g.dialog_run(d)
	g.widget_destroy(d)
	for g.events_pending() do g.main_iteration_do(false)
	return resp == GTK_RESPONSE_YES
}

bridge_tray_native_shutdown :: proc() {
	if tray_indicator != nil do tray_gtk.indicator_set_status(tray_indicator, 0) // PASSIVE: hide
}
