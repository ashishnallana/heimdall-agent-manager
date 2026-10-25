-- Extension telemetry has no durable history or per-event metadata.
DROP TABLE IF EXISTS agent_extension_events;
UPDATE agent_instances SET provider_session_id='', provider_transcript_path='',
 extension_provider='', extension_version='', extension_capabilities='[]',
 extension_last_seen_at=''
WHERE provider_session_id!='' OR provider_transcript_path!='' OR extension_provider!=''
 OR extension_version!='' OR extension_capabilities!='[]' OR extension_last_seen_at!='';
