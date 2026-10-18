package main

// Win32 calls the bridge needs that core:sys/windows does not declare.

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import advapi32 "system:Advapi32.lib"

COMPUTER_NAME_DNS_HOSTNAME :: 1
CRED_TYPE_GENERIC          :: 1
CRED_PERSIST_LOCAL_MACHINE :: 2
ERROR_NOT_FOUND            :: 1168
STILL_ACTIVE               :: 259

Credential_W :: struct {
	Flags:              u32,
	Type:               u32,
	TargetName:         win.wstring,
	Comment:            win.wstring,
	LastWritten:        win.FILETIME,
	CredentialBlobSize: u32,
	CredentialBlob:     [^]u8,
	Persist:            u32,
	AttributeCount:     u32,
	Attributes:         rawptr,
	TargetAlias:        win.wstring,
	UserName:           win.wstring,
}

@(default_calling_convention = "system")
foreign kernel32 {
	QueryFullProcessImageNameW :: proc(hProcess: win.HANDLE, dwFlags: u32, lpExeName: [^]u16, lpdwSize: ^u32) -> win.BOOL ---
	GetComputerNameExW :: proc(NameType: i32, lpBuffer: [^]u16, nSize: ^u32) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign advapi32 {
	GetUserNameW :: proc(lpBuffer: [^]u16, pcbBuffer: ^u32) -> win.BOOL ---
	CredWriteW :: proc(Credential: ^Credential_W, Flags: u32) -> win.BOOL ---
	CredReadW :: proc(TargetName: win.wstring, Type: u32, Flags: u32, Credential: ^^Credential_W) -> win.BOOL ---
	CredDeleteW :: proc(TargetName: win.wstring, Type: u32, Flags: u32) -> win.BOOL ---
	CredFree :: proc(Buffer: rawptr) ---
}

Process_Memory_Counters :: struct {
	cb:                         u32,
	PageFaultCount:             u32,
	PeakWorkingSetSize:         uint,
	WorkingSetSize:             uint,
	QuotaPeakPagedPoolUsage:    uint,
	QuotaPagedPoolUsage:        uint,
	QuotaPeakNonPagedPoolUsage: uint,
	QuotaNonPagedPoolUsage:     uint,
	PagefileUsage:              uint,
	PeakPagefileUsage:          uint,
}

@(default_calling_convention = "system")
foreign kernel32 {
	K32GetProcessMemoryInfo :: proc(Process: win.HANDLE, ppsmemCounters: ^Process_Memory_Counters, cb: u32) -> win.BOOL ---
}
