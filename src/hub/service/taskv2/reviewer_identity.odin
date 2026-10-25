package taskv2

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// reviewer_must_be_agent_id_error: brief.reviewers names durable agent
// templates (agt_…), never instances or unknown ids.
reviewer_must_be_agent_id_error :: proc(id: string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"reviewer_must_be_agent_id","reviewer":"`)
	contracts.write_json_string(&b, id)
	strings.write_string(&b, `"}`)
	why := "an instance id" if strings.has_prefix(id, "inst_") else "not a known agent template"
	return domain.domain_error(.Validation_Failed, strings.concatenate({"reviewer_must_be_agent_id: ", id, " is ", why, "; brief.reviewers takes durable agent ids (agt_…)"}, context.temp_allocator), strings.to_string(b))
}
