package bridgesvc

// Service-file rendering (systemd unit, launchd plist, runit run file, Scheduled
// Task XML) — the same arguments and environment scripts/install.sh render_service
// and install.ps1 New-TaskXml produce, so `ham-bridge setup` re-rendering over an
// installer-made service is a no-op apart from fixes. setup re-renders on every run.

import "core:fmt"
import "core:slice"
import "core:strings"

Render_Input :: struct {
	hub:           string,
	profile:       string,
	path_env:      string, // PATH to append after bin_dir
	termux_version: string,
	// Windows: the account (DOMAIN\\user) the logon task belongs to. Without it
	// the LogonTrigger means "at log on of ANY user", which only an
	// administrator may register (schtasks /Create: Access is denied).
	windows_user:  string,
	bridge_port:   int,
	endpoint_port: int,
}

exe_name :: proc(host: Host, base: string) -> string {
	return strings.concatenate({base, ".exe"}, context.temp_allocator) if host.os == .Windows else base
}

// service_args: the bridge command line every backend runs (temp-allocated).
service_args :: proc(host: Host, l: Layout, in_: Render_Input) -> []string {
	a := make([dynamic]string, context.temp_allocator)
	append(&a, pjoin(l.bin_dir, exe_name(host, "ham-bridge")), "--hub", in_.hub,
		"--config", pjoin(l.state_dir, CONFIG_FILE), "--bridge-token-file", pjoin(l.state_dir, TOKEN_FILE),
		"--data-dir", l.data_dir, "--bind-host", "127.0.0.1", "--port", fmt.tprintf("%d", in_.bridge_port),
		"--local-endpoint-port", fmt.tprintf("%d", in_.endpoint_port), "--local-run-dir", pjoin(l.data_dir, "run"))
	return a[:]
}

// service_env: KEY=VALUE pairs, in install.sh order.
service_env :: proc(host: Host, l: Layout, in_: Render_Input) -> []string {
	sep := ";" if host.os == .Windows else ":"
	service_env_name: string
	#partial switch l.backend {
	case .Runit:    service_env_name = l.service_name
	case .Launchd, .Schtasks: service_env_name = l.service_name
	case:           service_env_name = strings.concatenate({l.service_name, ".service"}, context.temp_allocator)
	}
	e := make([dynamic]string, context.temp_allocator)
	path := l.bin_dir if in_.path_env == "" else strings.concatenate({l.bin_dir, sep, in_.path_env}, context.temp_allocator)
	append(&e, strings.concatenate({"PATH=", path}, context.temp_allocator),
		strings.concatenate({"HEIMDALL_HAM_PTY_HOST_BIN=", pjoin(l.bin_dir, exe_name(host, "ham-pty-host"))}, context.temp_allocator),
		"HEIMDALL_BRIDGE_PTY_HOST=true",
		strings.concatenate({"HEIMDALL_HAM_CTL_BIN=", pjoin(l.bin_dir, exe_name(host, strings.concatenate({"ham-ctl-", l.service_name}, context.temp_allocator)))}, context.temp_allocator),
		fmt.tprintf("HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:%d", in_.endpoint_port),
		strings.concatenate({"HEIMDALL_BRIDGE_SERVICE_NAME=", service_env_name}, context.temp_allocator))
	return e[:]
}

xml_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '&':  strings.write_string(&b, "&amp;")
		case '<':  strings.write_string(&b, "&lt;")
		case '>':  strings.write_string(&b, "&gt;")
		case '"':  strings.write_string(&b, "&quot;")
		case '\'': strings.write_string(&b, "&apos;")
		case:      strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

sh_quote :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", out, "'"}, context.temp_allocator)
}

// systemd_exec_quote quotes one ExecStart word (and escapes % specifiers / $).
systemd_exec_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"', '\\': strings.write_byte(&b, '\\'); strings.write_rune(&b, r)
		case '%':       strings.write_string(&b, "%%")
		case '$':       strings.write_string(&b, "$$")
		case:           strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// render_service_file returns the service definition text for l.backend
// (temp-allocated); "" for Backend.None.
render_service_file :: proc(host: Host, l: Layout, in_: Render_Input) -> string {
	args := service_args(host, l, in_)
	env := service_env(host, l, in_)
	b := strings.builder_make(context.temp_allocator)
	switch l.backend {
	case .None:
		return ""
	case .Systemd:
		fmt.sbprintf(&b, "[Unit]\nDescription=Ninjy Bridge %s", in_.hub)
		if in_.profile != "" do fmt.sbprintf(&b, " (profile %s)", in_.profile)
		strings.write_string(&b, "\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=")
		for a, i in args {
			if i > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, systemd_exec_quote(a))
		}
		strings.write_byte(&b, '\n')
		for e in env do fmt.sbprintf(&b, "Environment=%s\n", systemd_exec_quote(e))
		strings.write_string(&b, "Restart=on-failure\nRestartSec=5\nKillMode=process\n\n[Install]\nWantedBy=default.target\n")
	case .Launchd:
		sorted := slice.clone(env, context.temp_allocator)
		sort_strings(sorted)
		strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
		strings.write_string(&b, "<plist version=\"1.0\">\n<dict>\n\t<key>AbandonProcessGroup</key>\n\t<true/>\n\t<key>EnvironmentVariables</key>\n\t<dict>\n")
		for e in sorted {
			eq := strings.index_byte(e, '=')
			fmt.sbprintf(&b, "\t\t<key>%s</key>\n\t\t<string>%s</string>\n", e[:eq], xml_escape(e[eq + 1:]))
		}
		strings.write_string(&b, "\t</dict>\n\t<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>\n")
		fmt.sbprintf(&b, "\t<key>Label</key>\n\t<string>%s</string>\n\t<key>ProgramArguments</key>\n\t<array>\n", xml_escape(l.service_name))
		for a in args do fmt.sbprintf(&b, "\t\t<string>%s</string>\n", xml_escape(a))
		strings.write_string(&b, "\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n")
		fmt.sbprintf(&b, "\t<key>StandardErrorPath</key>\n\t<string>%s</string>\n", xml_escape(pjoin(l.data_dir, "logs", "bridge.err.log")))
		fmt.sbprintf(&b, "\t<key>StandardOutPath</key>\n\t<string>%s</string>\n", xml_escape(pjoin(l.data_dir, "logs", "bridge.out.log")))
		strings.write_string(&b, "\t<key>ThrottleInterval</key>\n\t<integer>5</integer>\n</dict>\n</plist>\n")
	case .Runit:
		fmt.sbprintf(&b, "#!%s/bin/sh\nexec 2>&1\n", host.prefix)
		fmt.sbprintf(&b, "export PREFIX=%s\n", sh_quote(host.prefix))
		fmt.sbprintf(&b, "export TERMUX_VERSION=%s\n", sh_quote(in_.termux_version if in_.termux_version != "" else "installed"))
		fmt.sbprintf(&b, "export TMPDIR=%s\n", sh_quote(pjoin(host.prefix, "tmp")))
		for e in env {
			eq := strings.index_byte(e, '=')
			fmt.sbprintf(&b, "export %s=%s\n", e[:eq], sh_quote(e[eq + 1:]))
		}
		strings.write_string(&b, "exec")
		for a in args do fmt.sbprintf(&b, " %s", sh_quote(a))
		strings.write_byte(&b, '\n')
	case .Schtasks:
		// Per-user logon task running run.cmd (render_windows_run_cmd), which
		// carries the environment the other backends set inline, like install.ps1.
		strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n")
		fmt.sbprintf(&b, "  <RegistrationInfo><Description>Ninjy Bridge %s</Description></RegistrationInfo>\n", xml_escape(in_.hub))
		user_id := in_.windows_user == "" ? "" : fmt.tprintf("<UserId>%s</UserId>", xml_escape(in_.windows_user))
		fmt.sbprintf(&b, "  <Triggers><LogonTrigger><Enabled>true</Enabled>%s</LogonTrigger></Triggers>\n", user_id)
		fmt.sbprintf(&b, "  <Principals><Principal id=\"Author\">%s<LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>\n", user_id)
		strings.write_string(&b, "  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure></Settings>\n")
		strings.write_string(&b, "  <Actions Context=\"Author\"><Exec>\n    <Command>cmd.exe</Command>\n")
		fmt.sbprintf(&b, "    <Arguments>/d /c \"%s\"</Arguments>\n", xml_escape(windows_run_cmd_path(l)))
		strings.write_string(&b, "  </Exec></Actions>\n</Task>\n")
	}
	return strings.to_string(b)
}

// default_config_toml is written only when config.toml is missing (existing
// configs are migrated, never replaced).
default_config_toml :: proc(hub, data_dir: string) -> string {
	esc :: proc(s: string) -> string {
		a, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
		b, _ := strings.replace_all(a, "\"", "\\\"", context.temp_allocator)
		return b
	}
	return fmt.tprintf("[daemon]\ndaemon_url = \"%s\"\ndata_dir = \"%s\"\n\n[wrapper]\ndaemon_url = \"%s\"\n", esc(hub), esc(data_dir), esc(hub))
}

windows_run_cmd_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "run.cmd")}

// render_windows_run_cmd: the batch file the Scheduled Task runs (CRLF).
render_windows_run_cmd :: proc(host: Host, l: Layout, in_: Render_Input) -> string {
	cmdq :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "%", "%%", context.temp_allocator)
		return out
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "@echo off\r\nrem Ninjy bridge for %s (generated by ham-bridge setup)\r\nsetlocal DisableDelayedExpansion\r\n", cmdq(in_.hub))
	for e in service_env(host, l, in_) do fmt.sbprintf(&b, "set \"%s\"\r\n", cmdq(e))
	args := service_args(host, l, in_)
	fmt.sbprintf(&b, "\"%s\"", cmdq(args[0]))
	for a in args[1:] do fmt.sbprintf(&b, " \"%s\"", cmdq(a))
	fmt.sbprintf(&b, " 1>>\"%s\" 2>>\"%s\"\r\nexit /b %%ERRORLEVEL%%\r\n", cmdq(pjoin(l.data_dir, "logs", "bridge.out.log")), cmdq(pjoin(l.data_dir, "logs", "bridge.err.log")))
	return strings.to_string(b)
}
