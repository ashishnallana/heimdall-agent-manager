package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// REQ-TV2-3d: every ham-ctl JSON output parses, and none carries a core:fmt
// error such as `%!(MISSING CLOSE BRACE)`. core:fmt reads `{` in a format string
// as a placeholder, so a printf-family format holding JSON braces is always
// broken. Two halves: a source scan that forbids such formats anywhere in the
// CLI, and a parse check of the shared builders the fixed sites now use, fed
// the hostile values (quotes, backslashes, newlines, `%s`, braces) that the old
// unescaped `%s` interpolation corrupted.

// expect_cli_json parses `out` as one JSON object and returns it.
@(private = "file")
expect_cli_json :: proc(t: ^testing.T, out: string, loc := #caller_location) -> json.Object {
	testing.expectf(t, !strings.contains(out, "%!("), "fmt error in output: %s", out, loc = loc)
	parsed, err := json.parse(transmute([]byte)out, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expectf(t, err == nil, "output is not JSON (%v): %s", err, out, loc = loc)
	obj, is_obj := parsed.(json.Object)
	testing.expectf(t, is_obj, "output is not a JSON object: %s", out, loc = loc)
	return obj
}

@(test)
test_cli_error_json_parses_with_hostile_values :: proc(t: ^testing.T) {
	hostile := []string{
		`/tmp/a "quoted" dir/brief.json`,
		`C:\Users\x\brief.json`,
		"line1\nline2\ttab",
		`%s %d {} {"ok":true}`,
		"",
	}
	for v in hostile {
		// The exact messages the formerly broken sites now build.
		for msg in ([]string{
			fmt.tprintf("--brief-file %s: cannot read", v),
			fmt.tprintf("--brief-file %s: must contain a JSON object", v),
			fmt.tprintf("%s %s: cannot read", "--output-file", v),
			fmt.tprintf("%s %s: not valid JSON", "--handoff-file", v),
			fmt.tprintf("--file %s: cannot read", v),
			fmt.tprintf("unknown issue action '%s'", v),
		}) {
			obj := expect_cli_json(t, ctl_error_json(msg))
			ok, has_ok := obj["ok"].(json.Boolean)
			testing.expect(t, has_ok && !bool(ok), "ok:false")
			m, has_m := obj["message"].(json.String)
			testing.expect(t, has_m, "message present")
			testing.expect_value(t, string(m), msg)
		}
		obj := expect_cli_json(t, ctl_error_json("artifact was not written", json_kv("path", v)))
		p, has_p := obj["path"].(json.String)
		testing.expect(t, has_p, "path present")
		testing.expect_value(t, string(p), v)
	}
}

@(test)
test_cli_workflow_output_params_parse :: proc(t: ^testing.T) {
	_, _, params, ok := ctl_v2_workflow_output_params([]string{"output", "wfr_1", `st"a}ge`}, []string{"ham-ctl", "workflow", "output", "wfr_1", `st"a}ge`, "--execution", "2"})
	testing.expect(t, ok, "params built")
	obj := expect_cli_json(t, params)
	s, _ := obj["stage_key"].(json.String)
	testing.expect_value(t, string(s), `st"a}ge`)
}

// CTL_PRINTF_CALLS: every core:fmt procedure that takes a format string.
@(private = "file")
CTL_PRINTF_CALLS :: []string{"printf(", "printfln("}

@(test)
test_cli_sources_have_no_brace_printf_formats :: proc(t: ^testing.T) {
	root := strings.trim_right(#directory, "/")
	offenders: [dynamic]string
	defer delete(offenders)
	scanned := 0
	scan_brace_formats(root, &offenders, &scanned)
	testing.expectf(t, scanned > 10, "scanned only %d files under %s", scanned, root)
	for o in offenders {
		testing.expectf(t, false, "%s: printf-family format holds a literal brace; core:fmt prints %%!(MISSING CLOSE BRACE). Build JSON with ctl_error_json/json_kv/json_object instead.", o)
	}
}

@(private = "file")
scan_brace_formats :: proc(dir: string, offenders: ^[dynamic]string, scanned: ^int) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for e in entries {
		if e.type == .Directory {
			scan_brace_formats(e.fullpath, offenders, scanned)
			continue
		}
		if !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") do continue
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil do continue
		scanned^ += 1
		for line, i in strings.split_lines(string(data), context.temp_allocator) {
			if strings.has_prefix(strings.trim_space(line), "//") do continue
			if printf_format_has_brace(line) {
				append(offenders, fmt.tprintf("%s:%d", filepath.base(e.fullpath), i + 1))
			}
		}
	}
}

// printf_format_has_brace reports whether a printf-family call on this line
// has a format literal (its first string literal) containing `{` or `}`.
@(private = "file")
printf_format_has_brace :: proc(line: string) -> bool {
	rest := line
	for {
		at := -1
		width := 0
		for call in CTL_PRINTF_CALLS {
			if i := strings.index(rest, call); i >= 0 && (at < 0 || i < at) {
				at = i
				width = len(call)
			}
		}
		if at < 0 do return false
		rest = rest[at + width:]
		lit, found := first_string_literal(rest)
		if found && strings.contains_any(lit, "{}") do return true
	}
}

// first_string_literal returns the body of the first "…" or `…` literal.
@(private = "file")
first_string_literal :: proc(s: string) -> (string, bool) {
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '`':
			end := strings.index_byte(s[i + 1:], '`')
			if end < 0 do return s[i + 1:], true
			return s[i + 1:i + 1 + end], true
		case '"':
			for j := i + 1; j < len(s); j += 1 {
				if s[j] == '\\' { j += 1; continue }
				if s[j] == '"' do return s[i + 1:j], true
			}
			return s[i + 1:], true
		case ')':
			return "", false
		}
	}
	return "", false
}

@(test)
test_printf_format_scanner_self_check :: proc(t: ^testing.T) {
	testing.expect(t, printf_format_has_brace("fmt.printfln(`{\"ok\":false,\"message\":\"%s\"}`, path)"), "raw literal")
	testing.expect(t, printf_format_has_brace(`fmt.printf("{\"ok\":false,\"path\":\"%s\"}\n", path)`), "escaped literal")
	testing.expect(t, printf_format_has_brace(`s := fmt.tprintf("%s,%s}", a, b)`), "tprintf closing brace")
	testing.expect(t, printf_format_has_brace(`fmt.eprintfln("x {}", v)`), "eprintfln")
	testing.expect(t, !printf_format_has_brace(`fmt.tprintf("/api/v1/x/%s", safe_path_part(id))`), "no brace")
	testing.expect(t, !printf_format_has_brace(`fmt.println(json_object(json_kv("a", "{")))`), "println is not a format call")
	// Conservative: with a variable format the first literal is an argument, and
	// a brace there is still flagged.
	testing.expect(t, printf_format_has_brace(`fmt.tprintf(f, "{")`), "conservative on variable formats")
}
