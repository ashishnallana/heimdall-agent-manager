package vault

CONTROL_FIELDS_CHAIN := [?]string{"chain_id","title","description","status","kind","work_revision","task_count","completed_task_count","user_validation_count","created_at","updated_at","configuration_revision","fleet"}
CONTROL_FIELDS_TASK := [?]string{"task_id","title","description","state","kind","attempt_no","requires_user_approval","reviews","updated_at"}
CONTROL_FIELDS_COMMENT := [?]string{"comment_id","chain_id","task_id","body","created_at","author_kind","author_user_id","author_agent_instance_id","delegated_client_id","delegated_grant_id","body_error","body_bytes"}
CONTROL_FIELDS_DETAIL := [?]string{"task_id","chain_id","title","description","state","kind","attempt_no","requires_user_approval","reviews","updated_at","goal","acceptance","inputs","review_roles","reviewers","assignee_agent_id","bridge_id","depends_on","publish_state","priority","revision","blocked_kind","blocked_ref","blocked_reason","blocked_since","blocked_since_ms","hold_reason","hold_since_ms","hold_by","checkpoint_requested","allowed_actions","latest_attempt_no","latest_attempt_holder_instance_id","latest_attempt_outcome","latest_attempt_started_at","latest_attempt_ended_at","latest_attempt_summary","latest_attempt_summary_error","requirements_revision","requirements_submitted_revision","requirements_submitted_head","requirements_checkpoint_required","requirements_acknowledgements","requirements_history","requirements_history_truncated"}
CONTROL_TEXT_BASIC := [?]string{"title","description"}
CONTROL_TEXT_COMMENT := [?]string{"body"}
CONTROL_TEXT_DETAIL := [?]string{"title","description","goal","blocked_reason","hold_reason","latest_attempt_summary","requirements_history"}
control_record_fields :: proc(kind:Control_Record_Kind)->([]string,[]string) {
	if kind==.Artifact do return CONTROL_FIELDS_ARTIFACT[:],CONTROL_TEXT_ARTIFACT[:]
	if kind==.Memory do return CONTROL_FIELDS_MEMORY[:],CONTROL_TEXT_MEMORY[:]
	if kind==.Project do return CONTROL_FIELDS_PROJECT[:],CONTROL_TEXT_PROJECT[:]
	if kind==.Issue do return CONTROL_FIELDS_ISSUE[:],CONTROL_TEXT_ISSUE[:]
	if kind==.Issue_Comment do return CONTROL_FIELDS_ISSUE_COMMENT[:],CONTROL_TEXT_ISSUE_COMMENT[:]
	if kind==.Agent do return CONTROL_FIELDS_AGENT[:],CONTROL_TEXT_AGENT[:]
	if kind==.Instance do return CONTROL_FIELDS_INSTANCE[:],CONTROL_TEXT_INSTANCE[:]
	if kind==.Bridge do return CONTROL_FIELDS_BRIDGE[:],CONTROL_TEXT_BRIDGE[:]
	if kind==.Provider do return CONTROL_FIELDS_PROVIDER[:],CONTROL_TEXT_PROVIDER[:]
	if kind==.Chain do return CONTROL_FIELDS_CHAIN[:],CONTROL_TEXT_BASIC[:]
	if kind==.Task do return CONTROL_FIELDS_TASK[:],CONTROL_TEXT_BASIC[:]
	if kind==.Comment do return CONTROL_FIELDS_COMMENT[:],CONTROL_TEXT_COMMENT[:]
	return CONTROL_FIELDS_DETAIL[:],CONTROL_TEXT_DETAIL[:]
}
