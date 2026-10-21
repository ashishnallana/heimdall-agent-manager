package domain

User_ID :: distinct string
Bridge_ID :: distinct string
Agent_ID :: distinct string
Agent_Instance_ID :: distinct string
Project_ID :: distinct string
Task_Chain_ID :: distinct string
Task_ID :: distinct string
Artifact_ID :: distinct string

id_is_empty :: proc(id: string) -> bool {
	return id == ""
}
Action_ID :: distinct string
Push_Subscription_ID :: distinct string
Card_ID :: distinct string
Issue_ID :: distinct string
Issue_Comment_ID :: distinct string
