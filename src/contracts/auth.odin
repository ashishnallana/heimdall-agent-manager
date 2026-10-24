package contracts

Auth_Kind :: enum {
	None,
	Trusted_Proxy,
	User_Token,
	Bridge_Token,
	Enrollment_Token,
	Instance_Token,
}

Auth_Context :: struct {
	kind: Auth_Kind,
	user_id: string,
	name: string,
	display_name: string,
	email: string,
	bridge_id: string,
	agent_instance_id: string,
	token_scopes: []string,
	user_token_id: string, // opaque identity for long-lived stream revocation checks
}

HTTP_Header :: struct {
	name: string,
	value: string,
}
