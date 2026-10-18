package crashlog

// Windows has no POSIX fatal signals; Windows Error Reporting already records
// crashes. install exists so callers need no platform guard.
install :: proc(name: string) {}
