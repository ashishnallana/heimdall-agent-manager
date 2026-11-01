-- Only unresolved dispatch intents participate in lease admission. Completed
-- receipt history must not make the scheduler scan every prior MCP operation.
CREATE INDEX IF NOT EXISTS idx_mcp_runtime_intents
ON mcp_mutation_receipts(result_id)
WHERE tool IN ('instances.create','instances.start','instances.stop','instances.reconfigure')
AND (CASE WHEN json_valid(result_json) THEN json_extract(result_json,'$.result.phase') END='prepared'
OR CASE WHEN json_valid(result_json) THEN json_extract(result_json,'$.result.status') END='repair_required');
