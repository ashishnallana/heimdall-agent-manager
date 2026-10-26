#+build windows
package tls_stream

// SChannel client over a plain TCP socket. Certificates are verified by Windows
// against the system trust store with hostname checking (SNI + name match) --
// the same guarantees the Unix relay gets from socat verify=1/commonname=. When
// HAM_TLS_CA_FILE is set, that PEM bundle REPLACES the system store as the trust
// anchor set, as cafile= does for socat; the chain is then checked manually.
//
// Threading: one reader (has_data/read) and any number of writers serialised by
// the caller may share a Stream. send_mu keeps record writes from interleaving
// with the handshake messages a reader may have to send (TLS 1.3 post-handshake
// traffic surfaces as SEC_I_RENEGOTIATE from DecryptMessage).

import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"

RECV_CHUNK :: 16 * 1024
WSAETIMEDOUT :: 10060

Stream :: struct {
	socket:    net.TCP_Socket,
	cred:      Sec_Handle,
	ctx:       Sec_Handle,
	have_cred: bool,
	have_ctx:  bool,
	target:    win.wstring,
	flags:     u32,
	sizes:     Sec_Pkg_Context_Stream_Sizes,
	eof:       bool,
	failed:    bool,
	cipher:    [dynamic]byte, // received, not yet decrypted
	plain:     [dynamic]byte, // decrypted, not yet read
	plain_pos: int,
	send_mu:   sync.Mutex,
}

dial :: proc(host: string, port: u16, timeout: time.Duration = 0) -> (s: Stream, ok: bool) {
	clean_host := host_trim_brackets(host)

	endpoint: net.Endpoint
	if addr := net.parse_address(clean_host); addr != nil {
		endpoint = net.Endpoint{address = addr, port = int(port)}
	} else {
		ep4, ep6, resolve_err := net.resolve(fmt.tprintf("%s:%d", clean_host, port))
		if resolve_err != nil {
			set_last_dial_error(fmt.tprintf("could not resolve %s: %v", clean_host, resolve_err))
			return {}, false
		}
		endpoint = ep4 if ep4.address != nil else ep6
		if endpoint.address == nil {
			set_last_dial_error(fmt.tprintf("could not resolve %s", clean_host))
			return {}, false
		}
	}
	socket, dial_err := net.dial_tcp_from_endpoint(endpoint)
	if dial_err != nil {
		set_last_dial_error(fmt.tprintf("could not connect to %s:%d: %v", clean_host, port, dial_err))
		return {}, false
	}
	s.socket = socket
	success := false
	defer if !success do close(&s)

	// The handshake obeys the caller's budget; afterwards reads block until data,
	// and callers bound them with has_data() and their own deadlines.
	set_socket_timeout(socket, win.SO_RCVTIMEO, timeout)
	defer set_socket_timeout(socket, win.SO_RCVTIMEO, 0)

	ca := ca_file()
	manual := ca != ""
	if !acquire_credentials(&s, manual) {
		set_last_dial_error("SChannel refused the client credentials")
		return {}, false
	}
	// Lives as long as the Stream (post-handshake ISC calls need it); freed in close.
	s.target = win.utf8_to_wstring(clean_host, context.allocator)
	s.flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_EXTENDED_ERROR
	if manual do s.flags |= ISC_REQ_MANUAL_CRED_VALIDATION

	if status := handshake(&s); status != SEC_E_OK {
		set_last_dial_error(fmt.tprintf("TLS handshake with %s:%d failed: %s", clean_host, port, status_text(status)))
		return {}, false
	}
	if QueryContextAttributesW(&s.ctx, SECPKG_ATTR_STREAM_SIZES, &s.sizes) != SEC_E_OK {
		set_last_dial_error("TLS stream sizes unavailable")
		return {}, false
	}
	if manual {
		if reason, verified := verify_against_ca_file(&s, ca, clean_host); !verified {
			set_last_dial_error(fmt.tprintf("TLS certificate of %s:%d rejected: %s", clean_host, port, reason))
			return {}, false
		}
	}
	success = true
	return s, true
}

acquire_credentials :: proc(s: ^Stream, manual: bool) -> bool {
	flags := u32(SCH_CRED_NO_DEFAULT_CREDS | SCH_USE_STRONG_CRYPTO)
	flags |= SCH_CRED_MANUAL_CRED_VALIDATION if manual else SCH_CRED_AUTO_CRED_VALIDATION
	package_name := win.utf8_to_wstring(UNISP_NAME, context.temp_allocator)
	expiry: i64

	creds := Sch_Credentials{dwVersion = SCH_CREDENTIALS_VERSION, dwFlags = flags}
	if AcquireCredentialsHandleW(nil, package_name, SECPKG_CRED_OUTBOUND, nil, &creds, nil, nil, &s.cred, &expiry) == SEC_E_OK {
		s.have_cred = true
		return true
	}
	// Windows before 10 1809 only knows SCHANNEL_CRED (no TLS 1.3).
	legacy := Schannel_Cred{dwVersion = SCHANNEL_CRED_VERSION, dwFlags = flags}
	if AcquireCredentialsHandleW(nil, package_name, SECPKG_CRED_OUTBOUND, nil, &legacy, nil, nil, &s.cred, &expiry) == SEC_E_OK {
		s.have_cred = true
		return true
	}
	return false
}

handshake :: proc(s: ^Stream) -> SECURITY_STATUS {
	attrs: u32
	out_buf := Sec_Buffer{BufferType = SECBUFFER_TOKEN}
	out_desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 1, pBuffers = &out_buf}
	status := InitializeSecurityContextW(&s.cred, nil, s.target, s.flags, 0, SECURITY_NATIVE_DREP, nil, 0, &s.ctx, &out_desc, &attrs, nil)
	if status < 0 do return status
	s.have_ctx = true

	for {
		if !flush_token(s, &out_buf) do return SEC_E_ILLEGAL_MESSAGE
		if status == SEC_E_OK do return SEC_E_OK
		if status != SEC_I_CONTINUE_NEEDED && status != SEC_E_INCOMPLETE_MESSAGE && status != SEC_I_INCOMPLETE_CREDENTIALS {
			return status
		}
		if status == SEC_E_INCOMPLETE_MESSAGE || len(s.cipher) == 0 {
			if !recv_more(s) do return SEC_E_ILLEGAL_MESSAGE
		}
		in_bufs := [2]Sec_Buffer{
			{cbBuffer = u32(len(s.cipher)), BufferType = SECBUFFER_TOKEN, pvBuffer = raw_data(s.cipher)},
			{BufferType = SECBUFFER_EMPTY},
		}
		in_desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 2, pBuffers = &in_bufs[0]}
		out_buf = Sec_Buffer{BufferType = SECBUFFER_TOKEN}
		status = InitializeSecurityContextW(&s.cred, &s.ctx, s.target, s.flags, 0, SECURITY_NATIVE_DREP, &in_desc, 0, nil, &out_desc, &attrs, nil)
		if status == SEC_E_INCOMPLETE_MESSAGE do continue
		keep_extra(s, &in_bufs[1])
		// ISC_REQ_EXTENDED_ERROR: a failing call may still carry an alert to send.
		if status < 0 {
			_ = flush_token(s, &out_buf)
			return status
		}
	}
}

// keep_extra drops the consumed prefix of s.cipher, keeping any SECBUFFER_EXTRA
// tail (the start of the next record).
keep_extra :: proc(s: ^Stream, extra: ^Sec_Buffer) {
	if extra.BufferType == SECBUFFER_EXTRA && extra.cbBuffer > 0 {
		n := int(extra.cbBuffer)
		copy(s.cipher[:n], s.cipher[len(s.cipher)-n:])
		resize(&s.cipher, n)
	} else {
		clear(&s.cipher)
	}
}

flush_token :: proc(s: ^Stream, buf: ^Sec_Buffer) -> bool {
	if buf.pvBuffer == nil do return true
	defer {
		FreeContextBuffer(buf.pvBuffer)
		buf.pvBuffer = nil
		buf.cbBuffer = 0
	}
	if buf.cbBuffer == 0 do return true
	return send_raw(s, ([^]byte)(buf.pvBuffer)[:buf.cbBuffer], 0) == .Ok
}

// recv_more appends whatever the socket has (blocking until something arrives).
recv_more :: proc(s: ^Stream) -> bool {
	old := len(s.cipher)
	resize(&s.cipher, old + RECV_CHUNK)
	n := win.recv(win.SOCKET(s.socket), &s.cipher[old], RECV_CHUNK, 0)
	if n <= 0 {
		resize(&s.cipher, old)
		if n == 0 do s.eof = true
		return false
	}
	resize(&s.cipher, old + int(n))
	return true
}

send_raw :: proc(s: ^Stream, bytes: []byte, timeout: time.Duration) -> Write_Result {
	set_socket_timeout(s.socket, win.SO_SNDTIMEO, timeout)
	sent := 0
	for sent < len(bytes) {
		n := win.send(win.SOCKET(s.socket), &bytes[sent], i32(len(bytes) - sent), 0)
		if n <= 0 {
			if win.WSAGetLastError() == WSAETIMEDOUT do return .Timed_Out
			return .Failed
		}
		sent += int(n)
	}
	return .Ok
}

set_socket_timeout :: proc(socket: net.TCP_Socket, option: i32, timeout: time.Duration) {
	ms := u32(max(time.duration_milliseconds(timeout), 0)) // 0 = no timeout
	_ = win.setsockopt(win.SOCKET(socket), win.SOL_SOCKET, option, &ms, size_of(ms))
}

// decrypt_step decrypts one record from s.cipher if a whole one is buffered.
// progressed reports that plaintext was produced or the stream state changed.
decrypt_step :: proc(s: ^Stream) -> (progressed: bool, ok: bool) {
	if len(s.cipher) == 0 do return false, true
	bufs := [4]Sec_Buffer{
		{cbBuffer = u32(len(s.cipher)), BufferType = SECBUFFER_DATA, pvBuffer = raw_data(s.cipher)},
		{BufferType = SECBUFFER_EMPTY},
		{BufferType = SECBUFFER_EMPTY},
		{BufferType = SECBUFFER_EMPTY},
	}
	desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 4, pBuffers = &bufs[0]}
	status := DecryptMessage(&s.ctx, &desc, 0, nil)
	if status == SEC_E_INCOMPLETE_MESSAGE do return false, true
	if status == SEC_I_CONTEXT_EXPIRED {
		// close_notify from the peer: a clean end of stream.
		s.eof = true
		clear(&s.cipher)
		return true, true
	}
	if status != SEC_E_OK && status != SEC_I_RENEGOTIATE do return false, false

	extra: ^Sec_Buffer
	for &b in bufs {
		if b.BufferType == SECBUFFER_DATA && b.cbBuffer > 0 {
			append(&s.plain, ..([^]byte)(b.pvBuffer)[:b.cbBuffer])
		} else if b.BufferType == SECBUFFER_EXTRA {
			extra = &b
		}
	}
	// Decryption is in place inside s.cipher; plaintext is copied out above, so
	// the record can now be dropped.
	if extra != nil {
		keep_extra(s, extra)
	} else {
		clear(&s.cipher)
	}

	if status == SEC_I_RENEGOTIATE {
		// TLS 1.3 post-handshake message (session ticket, key update): hand the
		// remaining bytes back to the handshake machinery.
		if !continue_post_handshake(s) do return false, false
	}
	return true, true
}

continue_post_handshake :: proc(s: ^Stream) -> bool {
	sync.mutex_lock(&s.send_mu)
	defer sync.mutex_unlock(&s.send_mu)
	attrs: u32
	in_bufs := [2]Sec_Buffer{
		{cbBuffer = u32(len(s.cipher)), BufferType = SECBUFFER_TOKEN, pvBuffer = raw_data(s.cipher)},
		{BufferType = SECBUFFER_EMPTY},
	}
	in_desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 2, pBuffers = &in_bufs[0]}
	out_buf := Sec_Buffer{BufferType = SECBUFFER_TOKEN}
	out_desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 1, pBuffers = &out_buf}
	status := InitializeSecurityContextW(&s.cred, &s.ctx, s.target, s.flags, 0, SECURITY_NATIVE_DREP, &in_desc, 0, nil, &out_desc, &attrs, nil)
	if status == SEC_E_INCOMPLETE_MESSAGE {
		_ = flush_token(s, &out_buf)
		return true
	}
	keep_extra(s, &in_bufs[1])
	if !flush_token(s, &out_buf) do return false
	return status == SEC_E_OK || status == SEC_I_CONTINUE_NEEDED
}

plain_available :: proc(s: ^Stream) -> bool {
	return s.plain_pos < len(s.plain)
}

// drain_decrypt runs decrypt_step until it stops producing.
drain_decrypt :: proc(s: ^Stream) -> bool {
	for !s.eof {
		progressed, ok := decrypt_step(s)
		if !ok {
			s.failed = true
			return false
		}
		if !progressed do break
	}
	return true
}

has_data :: proc(s: ^Stream) -> (ready: bool, ok: bool) {
	if plain_available(s) || s.eof do return true, true
	if s.failed do return false, false
	if !drain_decrypt(s) do return false, false
	if plain_available(s) || s.eof do return true, true

	pfd := win.WSA_POLLFD{fd = win.SOCKET(s.socket), events = win.POLLRDNORM}
	r := win.WSAPoll(&pfd, 1, 0)
	if r < 0 {
		s.failed = true
		return false, false
	}
	if r == 0 do return false, true
	if !recv_more(s) {
		if s.eof do return true, true
		s.failed = true
		return false, false
	}
	if !drain_decrypt(s) do return false, false
	return plain_available(s) || s.eof, true
}

read :: proc(s: ^Stream, out: []byte) -> (n: int, ok: bool) {
	for {
		if plain_available(s) {
			n = copy(out, s.plain[s.plain_pos:])
			s.plain_pos += n
			if s.plain_pos >= len(s.plain) {
				clear(&s.plain)
				s.plain_pos = 0
			}
			return n, true
		}
		if s.eof do return 0, true
		if s.failed do return 0, false
		progressed, step_ok := decrypt_step(s)
		if !step_ok {
			s.failed = true
			return 0, false
		}
		if progressed do continue
		if !recv_more(s) {
			if s.eof do return 0, true
			s.failed = true
			return 0, false
		}
	}
}

write_all :: proc(s: ^Stream, bytes: []byte, timeout: time.Duration = 0) -> Write_Result {
	sync.mutex_lock(&s.send_mu)
	defer sync.mutex_unlock(&s.send_mu)
	if s.failed || !s.have_ctx do return .Failed
	max_chunk := int(s.sizes.cbMaximumMessage)
	header := int(s.sizes.cbHeader)
	trailer := int(s.sizes.cbTrailer)
	record := make([]byte, header + min(max_chunk, max(len(bytes), 1)) + trailer)
	defer delete(record)
	started := time.tick_now()
	for offset := 0; offset < len(bytes); {
		n := min(max_chunk, len(bytes) - offset)
		copy(record[header:header+n], bytes[offset:offset+n])
		bufs := [4]Sec_Buffer{
			{cbBuffer = u32(header), BufferType = SECBUFFER_STREAM_HEADER, pvBuffer = &record[0]},
			{cbBuffer = u32(n), BufferType = SECBUFFER_DATA, pvBuffer = &record[header]},
			{cbBuffer = u32(trailer), BufferType = SECBUFFER_STREAM_TRAILER, pvBuffer = &record[header+n]},
			{BufferType = SECBUFFER_EMPTY},
		}
		desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 4, pBuffers = &bufs[0]}
		if EncryptMessage(&s.ctx, 0, &desc, 0) != SEC_E_OK do return .Failed
		total := int(bufs[0].cbBuffer + bufs[1].cbBuffer + bufs[2].cbBuffer)
		remaining: time.Duration
		if timeout > 0 {
			remaining = timeout - time.tick_since(started)
			if remaining <= 0 do return .Timed_Out
		}
		if res := send_raw(s, record[:total], remaining); res != .Ok do return res
		offset += n
	}
	return .Ok
}

// abort wakes a reader blocked in recv without invalidating the socket it owns.
// Winsock shutdown alone does not interrupt a recv that is already parked;
// CancelIoEx does, and the shutdown makes later calls fail at once.
abort :: proc(s: ^Stream) {
	_ = win.shutdown(win.SOCKET(s.socket), win.SD_BOTH)
	win.CancelIoEx(win.HANDLE(uintptr(s.socket)), nil)
}

close :: proc(s: ^Stream) {
	if s.have_ctx {
		send_close_notify(s)
		DeleteSecurityContext(&s.ctx)
		s.have_ctx = false
	}
	if s.have_cred {
		FreeCredentialsHandle(&s.cred)
		s.have_cred = false
	}
	if s.socket != 0 {
		net.close(s.socket)
		s.socket = 0
	}
	if s.target != nil {
		free(rawptr(s.target))
		s.target = nil
	}
	delete(s.cipher)
	delete(s.plain)
	s.cipher = nil
	s.plain = nil
	s.plain_pos = 0
}

send_close_notify :: proc(s: ^Stream) {
	if s.failed || s.eof do return
	sync.mutex_lock(&s.send_mu)
	defer sync.mutex_unlock(&s.send_mu)
	shutdown_type := u32(SCHANNEL_SHUTDOWN)
	ctl := Sec_Buffer{cbBuffer = size_of(shutdown_type), BufferType = SECBUFFER_TOKEN, pvBuffer = &shutdown_type}
	ctl_desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 1, pBuffers = &ctl}
	if ApplyControlToken(&s.ctx, &ctl_desc) != SEC_E_OK do return
	attrs: u32
	out_buf := Sec_Buffer{BufferType = SECBUFFER_TOKEN}
	out_desc := Sec_Buffer_Desc{ulVersion = SECBUFFER_VERSION, cBuffers = 1, pBuffers = &out_buf}
	_ = InitializeSecurityContextW(&s.cred, &s.ctx, s.target, s.flags, 0, SECURITY_NATIVE_DREP, nil, 0, nil, &out_desc, &attrs, nil)
	_ = flush_token(s, &out_buf)
}

// verify_against_ca_file checks the server chain against the PEM bundle at
// ca_path as the ONLY trust anchors, plus the hostname -- the equivalent of
// socat cafile= with verify=1 and commonname=.
verify_against_ca_file :: proc(s: ^Stream, ca_path, host: string) -> (reason: string, ok: bool) {
	server_cert: ^win.CERT_CONTEXT
	if QueryContextAttributesW(&s.ctx, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &server_cert) != SEC_E_OK || server_cert == nil {
		return "server sent no certificate", false
	}
	defer win.CertFreeCertificateContext(server_cert)

	roots := CertOpenStore(CERT_STORE_PROV_MEMORY, 0, nil, 0, nil)
	if roots == nil do return "could not create a certificate store", false
	defer win.CertCloseStore(roots, 0)
	loaded, load_ok := load_pem_bundle(roots, ca_path)
	if !load_ok || loaded == 0 do return fmt.tprintf("no certificates loaded from HAM_TLS_CA_FILE=%s", ca_path), false

	config := Cert_Chain_Engine_Config{
		cbSize           = size_of(Cert_Chain_Engine_Config),
		hExclusiveRoot   = roots,
		dwExclusiveFlags = CERT_CHAIN_EXCLUSIVE_ENABLE_CA_FLAG,
	}
	engine: HCERTCHAINENGINE
	if !CertCreateCertificateChainEngine(&config, &engine) do return "could not create a chain engine", false
	defer CertFreeCertificateChainEngine(engine)

	para := Cert_Chain_Para{cbSize = size_of(Cert_Chain_Para)}
	chain: rawptr
	// The server's own intermediates travel in the certificate's store.
	if !CertGetCertificateChain(engine, server_cert, nil, server_cert.hCertStore, &para, 0, nil, &chain) || chain == nil {
		return "could not build a certificate chain", false
	}
	defer CertFreeCertificateChain(chain)

	server_name := win.utf8_to_wstring(host, context.temp_allocator)
	extra := Ssl_Extra_Cert_Chain_Policy_Para{
		cbSize         = size_of(Ssl_Extra_Cert_Chain_Policy_Para),
		dwAuthType     = AUTHTYPE_SERVER,
		pwszServerName = server_name,
	}
	policy := Cert_Chain_Policy_Para{cbSize = size_of(Cert_Chain_Policy_Para), pvExtraPolicyPara = &extra}
	status := Cert_Chain_Policy_Status{cbSize = size_of(Cert_Chain_Policy_Status)}
	if !CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &policy, &status) {
		return "chain policy check could not run", false
	}
	if status.dwError != 0 do return chain_error_text(status.dwError), false
	return "", true
}

chain_error_text :: proc(code: u32) -> string {
	name := ""
	switch code {
	case 0x800B0109: name = "chain does not end at a HAM_TLS_CA_FILE certificate"
	case 0x800B010F: name = "certificate does not match the host name"
	case 0x800B0101: name = "certificate expired or not yet valid"
	case 0x800B010A: name = "incomplete certificate chain"
	}
	if name == "" do return fmt.tprintf("chain policy error 0x%08x", code)
	return fmt.tprintf("%s (0x%08x)", name, code)
}

load_pem_bundle :: proc(store: win.HCERTSTORE, path: string) -> (count: int, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return 0, false
	BEGIN :: "-----BEGIN CERTIFICATE-----"
	END :: "-----END CERTIFICATE-----"
	rest := string(data)
	for {
		start := strings.index(rest, BEGIN)
		if start < 0 do break
		rest = rest[start+len(BEGIN):]
		stop := strings.index(rest, END)
		if stop < 0 do break
		body, _ := strings.remove_all(rest[:stop], "\r", context.temp_allocator)
		body, _ = strings.remove_all(body, "\n", context.temp_allocator)
		body, _ = strings.remove_all(body, " ", context.temp_allocator)
		rest = rest[stop+len(END):]
		der, decode_err := base64.decode(body, allocator = context.temp_allocator)
		if decode_err != nil || len(der) == 0 do continue
		if CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, raw_data(der), u32(len(der)), CERT_STORE_ADD_ALWAYS, nil) {
			count += 1
		}
	}
	return count, true
}

status_text :: proc(status: SECURITY_STATUS) -> string {
	name := ""
	switch status {
	case SEC_E_UNTRUSTED_ROOT:     name = "certificate chain not trusted"
	case SEC_E_WRONG_PRINCIPAL:    name = "certificate does not match the host name"
	case SEC_E_CERT_EXPIRED:       name = "certificate expired"
	case SEC_E_ILLEGAL_MESSAGE:    name = "connection closed or malformed TLS message"
	case SEC_E_ALGORITHM_MISMATCH: name = "no common TLS version or cipher"
	}
	if name == "" do return fmt.tprintf("SECURITY_STATUS 0x%08x", transmute(u32)status)
	return fmt.tprintf("%s (0x%08x)", name, transmute(u32)status)
}
