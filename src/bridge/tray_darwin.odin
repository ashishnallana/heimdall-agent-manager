package main

// macOS tray: an NSStatusItem in the menu bar of an Accessory (no Dock icon)
// NSApplication. The status bar classes are not wrapped by core:sys/darwin/Foundation,
// so they are messaged through the Objective-C runtime directly. Each menu
// entry's tag is its Tray_Action; the action selector is registered on NSObject,
// so the NSApplication (nil target -> responder chain) receives it.

import "base:intrinsics"
import "core:strings"
import "core:time"
import NS "core:sys/darwin/Foundation"
import bridgesvc "odin_test:lib/bridgesvc"

@(objc_class = "NSStatusBar")
Tray_NS_Status_Bar :: struct {using _: NS.Object}
@(objc_class = "NSStatusItem")
Tray_NS_Status_Item :: struct {using _: NS.Object}
@(objc_class = "NSStatusBarButton")
Tray_NS_Button :: struct {using _: NS.Object}
@(objc_class = "NSAlert")
Tray_NS_Alert :: struct {using _: NS.Object}

@(private = "file")
tray_app: ^NS.Application
@(private = "file")
tray_item: ^Tray_NS_Status_Item
@(private = "file")
tray_status_item: ^NS.MenuItem
@(private = "file")
tray_items: [bridgesvc.Tray_Action]^NS.MenuItem
@(private = "file")
tray_clicked: Maybe(bridgesvc.Tray_Action)
@(private = "file")
tray_have_ui: bool

// tray_ns_string: an autoreleased NSString copy of s.
@(private = "file")
tray_ns_string :: proc(s: string) -> ^NS.String {
	c := strings.clone_to_cstring(s, context.temp_allocator)
	return intrinsics.objc_send(^NS.String, NS.String, "stringWithUTF8String:", c)
}

@(private = "file")
tray_on_action :: proc "c" (unused: rawptr, name: NS.SEL, sender: ^NS.Object) {
	tag := NS.MenuItem_tag((^NS.MenuItem)(sender))
	if tag >= 0 && int(tag) < len(bridgesvc.Tray_Action) do tray_clicked = bridgesvc.Tray_Action(tag)
}

@(private = "file")
tray_button :: proc() -> ^Tray_NS_Button {
	return intrinsics.objc_send(^Tray_NS_Button, tray_item, "button")
}

bridge_tray_native_init :: proc(title: string) -> (ok: bool, why: string) {
	tray_app = NS.Application_sharedApplication()
	if tray_app == nil do return false, "no NSApplication (not a GUI session)"
	NS.Application_setActivationPolicy(tray_app, .Accessory)
	NS.Application_finishLaunching(tray_app)
	bar := intrinsics.objc_send(^Tray_NS_Status_Bar, Tray_NS_Status_Bar, "systemStatusBar")
	if bar == nil do return false, "no system status bar"
	NSVariableStatusItemLength :: f64(-1)
	tray_item = intrinsics.objc_send(^Tray_NS_Status_Item, bar, "statusItemWithLength:", NSVariableStatusItemLength)
	if tray_item == nil do return false, "statusItemWithLength failed"
	intrinsics.objc_send(nil, tray_item, "retain")
	tray_have_ui = true

	sel := NS.MenuItem_registerActionCallback("heimdallTrayAction", tray_on_action)
	menu := NS.Menu_init(NS.Menu_alloc())
	NS.Menu_setAutoenablesItems(menu, false)
	tray_status_item = NS.MenuItem_initWithTitle(NS.MenuItem_alloc(), tray_ns_string("Checking..."), nil, tray_ns_string(""))
	NS.MenuItem_setEnabled(tray_status_item, false)
	NS.Menu_addItem(menu, tray_status_item)
	NS.Menu_addItem(menu, NS.MenuItem_separatorItem())
	for a in bridgesvc.Tray_Action {
		if a == .Uninstall || a == .Quit do NS.Menu_addItem(menu, NS.MenuItem_separatorItem())
		item := NS.MenuItem_initWithTitle(NS.MenuItem_alloc(), tray_ns_string(bridgesvc.TRAY_ACTION_LABELS[a]), sel, tray_ns_string(""))
		NS.MenuItem_setTag(item, NS.Integer(a))
		NS.Menu_addItem(menu, item)
		tray_items[a] = item
	}
	intrinsics.objc_send(nil, tray_item, "setMenu:", menu)
	intrinsics.objc_send(nil, tray_button(), "setTitle:", tray_ns_string("Heimdall"))
	return true, ""
}

bridge_tray_native_update :: proc(view: bridgesvc.Tray_View, enabled: Bridge_Tray_Enabled) {
	symbol: string
	switch view.level {
	case .Ok:      symbol = "checkmark.circle"
	case .Warning: symbol = "exclamationmark.triangle"
	case .Error:   symbol = "xmark.octagon"
	}
	button := tray_button()
	// SF Symbols (macOS 11+); older systems keep the text title.
	image := intrinsics.objc_send(^NS.Image, NS.Image, "imageWithSystemSymbolName:accessibilityDescription:", tray_ns_string(symbol), tray_ns_string(view.title))
	if image != nil {
		intrinsics.objc_send(nil, image, "setTemplate:", NS.BOOL(true))
		intrinsics.objc_send(nil, button, "setImage:", image)
		intrinsics.objc_send(nil, button, "setTitle:", tray_ns_string(""))
	} else {
		intrinsics.objc_send(nil, button, "setTitle:", tray_ns_string(strings.concatenate({"Heimdall: ", view.title}, context.temp_allocator)))
	}
	intrinsics.objc_send(nil, button, "setToolTip:", tray_ns_string(view.tooltip))
	NS.MenuItem_setTitle(tray_status_item, tray_ns_string(view.title))
	for a in bridgesvc.Tray_Action do NS.MenuItem_setEnabled(tray_items[a], enabled[a])
}

bridge_tray_native_pump :: proc(wait: time.Duration) -> (action: bridgesvc.Tray_Action, clicked: bool) {
	deadline := time.time_add(time.now(), wait)
	for time.diff(time.now(), deadline) > 0 {
		for {
			ev := NS.Application_nextEventMatchingMask(tray_app, NS.EventMaskAny, NS.Date_dateWithTimeIntervalSinceNow(0.02), NS.DefaultRunLoopMode, true)
			if ev == nil do break
			NS.Application_sendEvent(tray_app, ev)
		}
		if a, ok := tray_clicked.?; ok {
			tray_clicked = nil
			return a, true
		}
	}
	return {}, false
}

bridge_tray_native_confirm :: proc(text: string) -> bool {
	NSAlertFirstButtonReturn :: NS.Integer(1000)
	NS.Application_activateIgnoringOtherApps(tray_app, true)
	alert := intrinsics.objc_send(^Tray_NS_Alert, intrinsics.objc_send(^Tray_NS_Alert, Tray_NS_Alert, "alloc"), "init")
	if alert == nil do return false
	head, _, rest := strings.partition(text, "\n\n")
	intrinsics.objc_send(nil, alert, "setMessageText:", tray_ns_string(head))
	intrinsics.objc_send(nil, alert, "setInformativeText:", tray_ns_string(rest))
	intrinsics.objc_send(nil, alert, "addButtonWithTitle:", tray_ns_string("Uninstall"))
	intrinsics.objc_send(nil, alert, "addButtonWithTitle:", tray_ns_string("Cancel"))
	r := intrinsics.objc_send(NS.Integer, alert, "runModal")
	intrinsics.objc_send(nil, alert, "release")
	return r == NSAlertFirstButtonReturn
}

bridge_tray_native_shutdown :: proc() {
	if !tray_have_ui do return
	bar := intrinsics.objc_send(^Tray_NS_Status_Bar, Tray_NS_Status_Bar, "systemStatusBar")
	intrinsics.objc_send(nil, bar, "removeStatusItem:", tray_item)
}
