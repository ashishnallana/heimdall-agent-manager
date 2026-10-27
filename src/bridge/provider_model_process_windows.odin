#+build windows
package main

import "core:os"
import "core:fmt"
import "core:time"

bridge_model_process_start :: proc(desc: os.Process_Desc) -> (os.Process, bool) {
	process, err := os.process_start(desc)
	return process, err == nil
}

bridge_model_process_kill :: proc(process: os.Process) {
	if process.pid <= 0 do return
	// taskkill is a Windows system utility and /T includes CLI helper children.
	// No command shell is involved; bound the cleanup utility as well.
	path := bridge_runtime_find_on_path("taskkill.exe")
	defer delete(path)
	if path != "" {
		killer, err := os.process_start({command = []string{path, "/PID", fmt.tprintf("%d", process.pid), "/T", "/F"}})
		if err == nil {
			if _, wait_err := os.process_wait(killer, time.Second); wait_err != nil {
				_ = os.process_kill(killer)
				_, _ = os.process_wait(killer, 500 * time.Millisecond)
			}
		}
	}
	_ = os.process_kill(process)
}
