#+build !windows
package main

import "core:os"

bridge_os_start_hidden :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	return os.process_start(desc)
}
