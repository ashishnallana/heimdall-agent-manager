package contracts

Agent_Class :: distinct string
Agent_Instance_ID :: distinct string
Wrapper_Instance_ID :: distinct string

Client_Kind :: enum {
	Interactive,
}

Client_Access_Mode :: enum {
	Main,
	Copy,
	Read_Only,
}

Client_Capability :: enum {
	Stdin,
	Interrupt,
	Capture,
	Terminate,
}
