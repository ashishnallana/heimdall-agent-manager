package httpc

// Trust anchors for TLS peer verification. Precedence (README.md "Behaviour"):
//
//   1. HAM_TLS_CA_FILE (or Request._test_ca_file): that PEM bundle and nothing
//      else.
//   2. SSL_CERT_FILE / SSL_CERT_DIR (OpenSSL's variables, honoured explicitly
//      so the behaviour does not depend on the TLS backend).
//   3. The system store:
//      - Linux: the first CA bundle file in LINUX_CA_FILES that exists, else
//        LINUX_CA_DIRS when it holds OpenSSL hash links, else the Mozilla
//        bundle embedded at build time (-define:HAM_CA_BUNDLE=<pem>; release
//        builds only). The pinned libcurl compiles in no CA location, because a
//        statically linked OpenSSL only knows its own build prefix.
//      - macOS: Apple SecTrust (system keychains and trust settings), built into
//        the pinned libcurl (--with-apple-sectrust) and used whenever no CA
//        file/path is set.
//      - Windows: Schannel and the Windows certificate store.
//
// The Linux probe runs once, in init(): the CA layout does not change under a
// running process, and a request must not stat a list of paths every time.

import "base:runtime"
import "core:os"
import "core:strings"

// Distribution CA bundles, most common first: Debian/Ubuntu/Alpine/Arch/Gentoo,
// Fedora/RHEL/CentOS (two names), openSUSE/SLES, then the BSD-style name
// several distributions also provide.
@(rodata) LINUX_CA_FILES := [?]string{
	"/etc/ssl/certs/ca-certificates.crt",
	"/etc/pki/tls/certs/ca-bundle.crt",
	"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
	"/etc/ssl/ca-bundle.pem",
	"/etc/ssl/cert.pem",
}
// Hashed certificate directories (c_rehash / update-ca-certificates).
@(rodata) LINUX_CA_DIRS := [?]string{"/etc/ssl/certs"}

CA_BUNDLE_PATH :: #config(HAM_CA_BUNDLE, "")
when CA_BUNDLE_PATH != "" {
	// Mozilla's root store (nixpkgs cacert at the flake's pin), the last resort
	// on a Linux host that has no CA bundle installed.
	@(private) EMBEDDED_CA_BUNDLE :: #load(CA_BUNDLE_PATH, string)
} else {
	@(private) EMBEDDED_CA_BUNDLE :: ""
}

// Ca_Source is where the default (step 3) trust anchors come from.
Ca_Source :: enum u8 {
	Backend,       // libcurl's own default: SecTrust, Schannel, or nothing
	System_File,
	System_Dir,
	Embedded,
}

@(private) g_ca_source: Ca_Source
@(private) g_ca_path: string

// ca_init resolves the default trust anchors (step 3). Called once by init.
@(private)
ca_init :: proc() {
	when ODIN_OS == .Linux {
		g_ca_source, g_ca_path = probe_ca_locations(LINUX_CA_FILES[:], LINUX_CA_DIRS[:], len(EMBEDDED_CA_BUNDLE) > 0, runtime.heap_allocator())
	}
}

// default_ca describes the trust anchors used when neither HAM_TLS_CA_FILE nor
// SSL_CERT_FILE/SSL_CERT_DIR is set, for diagnostics (--probe-hub): the source
// and, for a system file or directory, its path.
default_ca :: proc() -> (source: Ca_Source, path: string) {
	_, _ = init()
	return g_ca_source, g_ca_path
}

// probe_ca_locations picks the first readable bundle file, else the first
// directory holding at least one OpenSSL hash link (an empty /etc/ssl/certs, as
// on a host without the ca-certificates package, does not count), else the
// embedded bundle when there is one. The path is cloned with `allocator`.
@(private)
probe_ca_locations :: proc(files, dirs: []string, have_embedded: bool, allocator := context.allocator) -> (Ca_Source, string) {
	for f in files {
		// stat follows symlinks (/etc/ssl/cert.pem usually is one); the open
		// proves the file is readable by this process.
		info, serr := os.stat(f, context.temp_allocator)
		if serr != nil || info.type != .Regular || info.size == 0 do continue
		if fd, err := os.open(f); err == nil {
			os.close(fd)
			return .System_File, strings.clone(f, allocator)
		}
	}
	for d in dirs {
		if dir_has_hash_links(d) do return .System_Dir, strings.clone(d, allocator)
	}
	if have_embedded do return .Embedded, ""
	return .Backend, ""
}

// dir_has_hash_links: does `dir` contain an entry named like "5ad8a5d6.0"?
@(private)
dir_has_hash_links :: proc(dir: string) -> bool {
	fd, err := os.open(dir)
	if err != nil do return false
	defer os.close(fd)
	it := os.read_directory_iterator_create(fd)
	defer os.read_directory_iterator_destroy(&it)
	for e in os.read_directory_iterator(&it) {
		if is_hash_link_name(e.name) do return true
	}
	return false
}

@(private)
is_hash_link_name :: proc(name: string) -> bool {
	if len(name) < 10 || name[8] != '.' do return false
	for i in 0..<8 {
		if !is_hex(name[i]) do return false
	}
	for i in 9..<len(name) {
		if name[i] < '0' || name[i] > '9' do return false
	}
	return true
}

// Trust is what perform() configures on the handle: CAINFO / CAPATH /
// CAINFO_BLOB. All empty = libcurl's default (Ca_Source.Backend).
@(private)
Trust :: struct {
	cainfo:    string,
	capath:    string,
	blob:      string,
	// HAM_TLS_CA_FILE: cainfo is the only anchor; clear any CAPATH.
	exclusive: bool,
}

// trust_anchors applies the precedence at the top of this file.
@(private)
trust_anchors :: proc(test_ca_file := "", test_ca_blob := "") -> (t: Trust) {
	if test_ca_blob != "" do return {blob = test_ca_blob, exclusive = true}
	if test_ca_file != "" do return {cainfo = test_ca_file, exclusive = true}
	if v := strings.trim_space(os.get_env("HAM_TLS_CA_FILE", context.temp_allocator)); v != "" {
		return {cainfo = v, exclusive = true}
	}
	t.cainfo = strings.trim_space(os.get_env("SSL_CERT_FILE", context.temp_allocator))
	t.capath = strings.trim_space(os.get_env("SSL_CERT_DIR", context.temp_allocator))
	if t.cainfo != "" || t.capath != "" do return
	switch g_ca_source {
	case .Backend:
	case .System_File: t.cainfo = g_ca_path
	case .System_Dir: t.capath = g_ca_path
	case .Embedded: t.blob = EMBEDDED_CA_BUNDLE
	}
	return
}

// trust_summary names the trust anchors a request uses (the precedence above),
// for diagnostics such as `ham-bridge --probe-hub`. Allocated with `allocator`.
trust_summary :: proc(allocator := context.temp_allocator) -> string {
	_, _ = init()
	t := trust_anchors()
	switch {
	case t.exclusive && t.blob == "":
		return strings.concatenate({"HAM_TLS_CA_FILE ", t.cainfo}, allocator)
	case t.blob != "":
		return strings.clone("embedded Mozilla CA bundle (no system CA bundle found)", allocator)
	case g_ca_source == .System_File && t.cainfo == g_ca_path, g_ca_source == .System_Dir && t.capath == g_ca_path:
		return strings.concatenate({"system ", g_ca_path}, allocator)
	case t.cainfo != "" || t.capath != "":
		return strings.concatenate({"SSL_CERT_FILE=", t.cainfo, " SSL_CERT_DIR=", t.capath}, allocator)
	}
	when ODIN_OS == .Windows {
		return strings.clone("Windows certificate store (Schannel)", allocator)
	} else when ODIN_OS == .Darwin {
		return strings.clone("Apple SecTrust (system keychains)", allocator)
	} else {
		return strings.clone("none found (set SSL_CERT_FILE or HAM_TLS_CA_FILE)", allocator)
	}
}
