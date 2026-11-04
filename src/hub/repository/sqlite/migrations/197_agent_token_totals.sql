-- Per-instance token usage (chain "Estimate agent tokens via extensions", T3r).
-- Only the latest bridge snapshot and running lifetime totals are kept; there is
-- deliberately no per-event or per-run history table (migration 125's intent).
--
-- token_usage_json: the latest canonicalized agent_instance_status.token_usage
--   object (tool_calls, est_tokens_total, context_tokens?, context_window,
--   window_source, context_pct?, output_tokens_total?, compactions, run_count?,
--   updated_at_ms); NULL until the bridge reported one.
-- token_total_*: sums of each finished run's final usage, added once per run
--   at the hub-requested stop/restart; token_totals_last_run is the de-dup key
--   (the newest run_count already added). All NULL until the first run counted.
ALTER TABLE agent_instances ADD COLUMN token_usage_json TEXT;
ALTER TABLE agent_instances ADD COLUMN token_usage_updated_at TEXT;
ALTER TABLE agent_instances ADD COLUMN token_total_context_tokens INTEGER;
ALTER TABLE agent_instances ADD COLUMN token_total_est_tool_tokens INTEGER;
ALTER TABLE agent_instances ADD COLUMN token_total_output_tokens INTEGER;
ALTER TABLE agent_instances ADD COLUMN token_runs_counted INTEGER;
ALTER TABLE agent_instances ADD COLUMN token_totals_last_run INTEGER;
