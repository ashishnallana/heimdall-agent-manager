-- Migration 078: Drop the stale built-in template rows seeded by 032.
--
-- Built-in template content is compiled in from src/templates/*.md
-- (domain.builtin_template) and resolved before any templates-table lookup,
-- so these rows were unused copies that drifted from the .md files.
-- list_templates appends any built-in missing from the table, so the API still
-- returns every built-in. tmpl_curator is left alone: it has no compiled body.
DELETE FROM templates
WHERE is_system = 1
  AND template_id IN ('tmpl_coordinator', 'tmpl_worker', 'tmpl_reviewer', 'tmpl_empty', 'tmpl_soloist');
