package tmux

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

ensure_not_copy_mode :: proc(pane_id: string) {
	if pane_id == "" do return
	check_cmd := []string{"tmux", "display-message", "-p", "-t", pane_id, "#{pane_in_mode}"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = check_cmd}, context.allocator)
	if err != nil || !state.success do return
	if strings.trim_space(string(stdout)) != "1" do return

	cancel_cmd := []string{"tmux", "send-keys", "-t", pane_id, "-X", "cancel"}
	_, _, _, _ = os.process_exec(os.Process_Desc{command = cancel_cmd}, context.allocator)
}

send_text :: proc(pane_id, text: string, enter := false) -> bool {
	if pane_id == "" do return false
	ensure_not_copy_mode(pane_id)
	send_text_cmd := []string{"tmux", "send-keys", "-t", pane_id, "-l", text}
	state, _, _, err := os.process_exec(os.Process_Desc{command = send_text_cmd}, context.allocator)
	if err != nil || !state.success do return false
	if !enter do return true
	time.sleep(300 * time.Millisecond)
	enter_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Enter"}
	state, _, _, err = os.process_exec(os.Process_Desc{command = enter_cmd}, context.allocator)
	return err == nil && state.success
}

// send_named_keys presses one or more tmux NAMED keys (NOT literal text). The
// spec is a whitespace-separated list of tmux key names, e.g. "Down", "Tab",
// "Tab Tab", "Up", "Enter", or a single digit like "1". Each token is passed to
// `tmux send-keys` WITHOUT the -l literal flag so tmux interprets it as a key
// press (Down => arrow-down) instead of typing the characters d-o-w-n. This is
// what startup-prompt navigation (auto_enter_pre_keys) needs: bare send_text
// would type the word "Down" into the prompt instead of moving the highlight.
// When enter=true, a trailing Enter is pressed after a short settle so the
// navigated selection is confirmed. Empty/whitespace-only tokens are skipped.
send_named_keys :: proc(pane_id, keys_spec: string, enter := false) -> bool {
	if pane_id == "" do return false
	ensure_not_copy_mode(pane_id)
	tokens := strings.fields(keys_spec)
	defer delete(tokens)
	for token in tokens {
		if strings.trim_space(token) == "" do continue
		key_cmd := []string{"tmux", "send-keys", "-t", pane_id, token}
		state, _, _, err := os.process_exec(os.Process_Desc{command = key_cmd}, context.allocator)
		if err != nil || !state.success do return false
		// Small gap so a multi-key nav (e.g. "Tab Tab") is registered as discrete
		// key presses by the target TUI rather than coalesced/dropped.
		time.sleep(80 * time.Millisecond)
	}
	if !enter do return true
	time.sleep(300 * time.Millisecond)
	enter_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Enter"}
	state, _, _, err := os.process_exec(os.Process_Desc{command = enter_cmd}, context.allocator)
	return err == nil && state.success
}

version :: proc() -> (string, bool) {
	cmd := []string{"tmux", "-V"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return "", false
	return strings.clone(strings.trim_space(string(stdout))), true
}

shell_quote :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "'")
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "'\\''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	strings.write_string(&builder, "'")
	return strings.to_string(builder)
}
