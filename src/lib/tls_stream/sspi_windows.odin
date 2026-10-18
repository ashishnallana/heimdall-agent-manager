#+build windows
package tls_stream

// The slice of SSPI/SChannel and the CryptoAPI chain engine this package uses.
// core:sys/windows ships neither (only crypt32's store enumeration), so they are
// declared here. Layouts follow sspi.h / schannel.h / wincrypt.h for x64.

import win "core:sys/windows"

foreign import secur32 "system:Secur32.lib"
foreign import crypt32 "system:Crypt32.lib"

SECURITY_STATUS :: i32

Sec_Handle :: struct {
	dwLower: uintptr,
	dwUpper: uintptr,
}

Sec_Buffer :: struct {
	cbBuffer:   u32,
	BufferType: u32,
	pvBuffer:   rawptr,
}

Sec_Buffer_Desc :: struct {
	ulVersion: u32,
	cBuffers:  u32,
	pBuffers:  [^]Sec_Buffer,
}

Sec_Pkg_Context_Stream_Sizes :: struct {
	cbHeader:         u32,
	cbTrailer:        u32,
	cbMaximumMessage: u32,
	cBuffers:         u32,
	cbBlockSize:      u32,
}

// SCH_CREDENTIALS (Windows 10 1809+; required for TLS 1.3).
Sch_Credentials :: struct {
	dwVersion:         u32,
	dwCredFormat:      u32,
	cCreds:            u32,
	paCred:            rawptr,
	hRootStore:        win.HCERTSTORE,
	cMappers:          u32,
	aphMappers:        rawptr,
	dwSessionLifespan: u32,
	dwFlags:           u32,
	cTlsParameters:    u32,
	pTlsParameters:    rawptr,
}

// SCHANNEL_CRED, the pre-1809 credential form (TLS 1.2 at most).
Schannel_Cred :: struct {
	dwVersion:               u32,
	cCreds:                  u32,
	paCred:                  rawptr,
	hRootStore:              win.HCERTSTORE,
	cMappers:                u32,
	aphMappers:              rawptr,
	cSupportedAlgs:          u32,
	palgSupportedAlgs:       rawptr,
	grbitEnabledProtocols:   u32,
	dwMinimumCipherStrength: u32,
	dwMaximumCipherStrength: u32,
	dwSessionLifespan:       u32,
	dwFlags:                 u32,
	dwCredFormat:            u32,
}

UNISP_NAME :: "Microsoft Unified Security Protocol Provider"

SCH_CREDENTIALS_VERSION :: 5
SCHANNEL_CRED_VERSION   :: 4
SECPKG_CRED_OUTBOUND    :: 0x2
SECURITY_NATIVE_DREP    :: 0x10
SCHANNEL_SHUTDOWN       :: 1

SCH_CRED_MANUAL_CRED_VALIDATION :: 0x00000008
SCH_CRED_NO_DEFAULT_CREDS       :: 0x00000010
SCH_CRED_AUTO_CRED_VALIDATION   :: 0x00000020
SCH_USE_STRONG_CRYPTO           :: 0x00400000

ISC_REQ_REPLAY_DETECT          :: 0x00000004
ISC_REQ_SEQUENCE_DETECT        :: 0x00000008
ISC_REQ_CONFIDENTIALITY        :: 0x00000010
ISC_REQ_ALLOCATE_MEMORY        :: 0x00000100
ISC_REQ_EXTENDED_ERROR         :: 0x00004000
ISC_REQ_STREAM                 :: 0x00008000
ISC_REQ_MANUAL_CRED_VALIDATION :: 0x00080000

SECBUFFER_VERSION       :: 0
SECBUFFER_EMPTY         :: 0
SECBUFFER_DATA          :: 1
SECBUFFER_TOKEN         :: 2
SECBUFFER_EXTRA         :: 5
SECBUFFER_STREAM_TRAILER :: 6
SECBUFFER_STREAM_HEADER :: 7

SECPKG_ATTR_STREAM_SIZES       :: 4
SECPKG_ATTR_REMOTE_CERT_CONTEXT :: 0x53

SEC_E_OK                    :: SECURITY_STATUS(0)
SEC_I_CONTINUE_NEEDED       :: SECURITY_STATUS(0x00090312)
SEC_I_CONTEXT_EXPIRED       :: SECURITY_STATUS(0x00090317)
SEC_I_INCOMPLETE_CREDENTIALS :: SECURITY_STATUS(0x00090320)
SEC_I_RENEGOTIATE           :: SECURITY_STATUS(0x00090321)
SEC_E_INCOMPLETE_MESSAGE    :: transmute(SECURITY_STATUS)u32(0x80090318)
SEC_E_WRONG_PRINCIPAL       :: transmute(SECURITY_STATUS)u32(0x80090322)
SEC_E_UNTRUSTED_ROOT        :: transmute(SECURITY_STATUS)u32(0x80090325)
SEC_E_CERT_EXPIRED          :: transmute(SECURITY_STATUS)u32(0x80090328)
SEC_E_ILLEGAL_MESSAGE       :: transmute(SECURITY_STATUS)u32(0x80090326)
SEC_E_ALGORITHM_MISMATCH    :: transmute(SECURITY_STATUS)u32(0x80090331)

@(default_calling_convention = "system")
foreign secur32 {
	AcquireCredentialsHandleW :: proc(
		pszPrincipal: win.wstring,
		pszPackage: win.wstring,
		fCredentialUse: u32,
		pvLogonId: rawptr,
		pAuthData: rawptr,
		pGetKeyFn: rawptr,
		pvGetKeyArgument: rawptr,
		phCredential: ^Sec_Handle,
		ptsExpiry: ^i64,
	) -> SECURITY_STATUS ---
	InitializeSecurityContextW :: proc(
		phCredential: ^Sec_Handle,
		phContext: ^Sec_Handle,
		pszTargetName: win.wstring,
		fContextReq: u32,
		Reserved1: u32,
		TargetDataRep: u32,
		pInput: ^Sec_Buffer_Desc,
		Reserved2: u32,
		phNewContext: ^Sec_Handle,
		pOutput: ^Sec_Buffer_Desc,
		pfContextAttr: ^u32,
		ptsExpiry: ^i64,
	) -> SECURITY_STATUS ---
	QueryContextAttributesW :: proc(phContext: ^Sec_Handle, ulAttribute: u32, pBuffer: rawptr) -> SECURITY_STATUS ---
	EncryptMessage :: proc(phContext: ^Sec_Handle, fQOP: u32, pMessage: ^Sec_Buffer_Desc, MessageSeqNo: u32) -> SECURITY_STATUS ---
	DecryptMessage :: proc(phContext: ^Sec_Handle, pMessage: ^Sec_Buffer_Desc, MessageSeqNo: u32, pfQOP: ^u32) -> SECURITY_STATUS ---
	ApplyControlToken :: proc(phContext: ^Sec_Handle, pInput: ^Sec_Buffer_Desc) -> SECURITY_STATUS ---
	DeleteSecurityContext :: proc(phContext: ^Sec_Handle) -> SECURITY_STATUS ---
	FreeCredentialsHandle :: proc(phCredential: ^Sec_Handle) -> SECURITY_STATUS ---
	FreeContextBuffer :: proc(pvContextBuffer: rawptr) -> SECURITY_STATUS ---
}

// ---- certificate chain verification (HAM_TLS_CA_FILE) ----

HCERTCHAINENGINE :: distinct rawptr

Cert_Chain_Engine_Config :: struct {
	cbSize:                    u32,
	hRestrictedRoot:           win.HCERTSTORE,
	hRestrictedTrust:          win.HCERTSTORE,
	hRestrictedOther:          win.HCERTSTORE,
	cAdditionalStore:          u32,
	rghAdditionalStore:        ^win.HCERTSTORE,
	dwFlags:                   u32,
	dwUrlRetrievalTimeout:     u32,
	MaximumCachedCertificates: u32,
	CycleDetectionModulus:     u32,
	hExclusiveRoot:            win.HCERTSTORE,
	hExclusiveTrustedPeople:   win.HCERTSTORE,
	dwExclusiveFlags:          u32,
}

Cert_Enhkey_Usage :: struct {
	cUsageIdentifier:     u32,
	rgpszUsageIdentifier: ^cstring,
}

Cert_Usage_Match :: struct {
	dwType: u32,
	Usage:  Cert_Enhkey_Usage,
}

Cert_Chain_Para :: struct {
	cbSize:         u32,
	RequestedUsage: Cert_Usage_Match,
}

Cert_Chain_Policy_Para :: struct {
	cbSize:            u32,
	dwFlags:           u32,
	pvExtraPolicyPara: rawptr,
}

Ssl_Extra_Cert_Chain_Policy_Para :: struct {
	cbSize:         u32,
	dwAuthType:     u32,
	fdwChecks:      u32,
	pwszServerName: win.wstring,
}

Cert_Chain_Policy_Status :: struct {
	cbSize:              u32,
	dwError:             u32,
	lChainIndex:         i32,
	lElementIndex:       i32,
	pvExtraPolicyStatus: rawptr,
}

CERT_STORE_PROV_MEMORY            :: uintptr(2)
CERT_CHAIN_POLICY_SSL             :: uintptr(4)
X509_ASN_ENCODING                 :: 0x00000001
PKCS_7_ASN_ENCODING               :: 0x00010000
CERT_STORE_ADD_ALWAYS             :: 4
AUTHTYPE_SERVER                   :: 2
CERT_CHAIN_EXCLUSIVE_ENABLE_CA_FLAG :: 0x00000001

@(default_calling_convention = "system")
foreign crypt32 {
	CertOpenStore :: proc(lpszStoreProvider: uintptr, dwEncodingType: u32, hCryptProv: rawptr, dwFlags: u32, pvPara: rawptr) -> win.HCERTSTORE ---
	CertAddEncodedCertificateToStore :: proc(hCertStore: win.HCERTSTORE, dwCertEncodingType: u32, pbCertEncoded: [^]byte, cbCertEncoded: u32, dwAddDisposition: u32, ppCertContext: ^^win.CERT_CONTEXT) -> win.BOOL ---
	CertCreateCertificateChainEngine :: proc(pConfig: ^Cert_Chain_Engine_Config, phChainEngine: ^HCERTCHAINENGINE) -> win.BOOL ---
	CertFreeCertificateChainEngine :: proc(hChainEngine: HCERTCHAINENGINE) ---
	CertGetCertificateChain :: proc(hChainEngine: HCERTCHAINENGINE, pCertContext: ^win.CERT_CONTEXT, pTime: rawptr, hAdditionalStore: win.HCERTSTORE, pChainPara: ^Cert_Chain_Para, dwFlags: u32, pvReserved: rawptr, ppChainContext: ^rawptr) -> win.BOOL ---
	CertVerifyCertificateChainPolicy :: proc(pszPolicyOID: uintptr, pChainContext: rawptr, pPolicyPara: ^Cert_Chain_Policy_Para, pPolicyStatus: ^Cert_Chain_Policy_Status) -> win.BOOL ---
	CertFreeCertificateChain :: proc(pChainContext: rawptr) ---
}
