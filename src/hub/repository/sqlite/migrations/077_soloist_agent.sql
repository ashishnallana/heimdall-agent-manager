-- Migration 077: Seed the canonical 'soloist' agent and make it the permanent
-- single-agent-workflow favorite in place of 'worker'.
--
-- The soloist coordinates its own task chain but does all the work itself,
-- using tasks only to track it. It runs on the built-in 'tmpl_soloist'
-- template (compiled in from src/templates/soloist.md, no table row needed).
-- 'worker' stays seeded (task chains still delegate to it); it just stops
-- being a pinned launch favorite.
--
-- Idempotent:
--   - NOT EXISTS check keyed on (owner_user_id, slug); deterministic ID.
--   - Preference rewrites drop worker ids and only add the soloist id when absent.

INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, instructions, state, created_at, updated_at)
SELECT 'agt_soloist_' || u.user_id,
       u.user_id,
       'soloist',
       'soloist',
       'tmpl_soloist',
       '',
       'active',
       u.created_at,
       u.updated_at
FROM users u
WHERE NOT EXISTS (
    SELECT 1 FROM agents a
    WHERE a.owner_user_id = u.user_id
      AND a.slug = 'soloist'
);

-- Swap the worker id for the soloist id in the persisted pinned and favorite
-- lists (the UI orders favorites by slug, so appending is enough), and move
-- a worker launch selection onto the soloist.
UPDATE user_conversation_launch_preferences
SET payload_json = json_set(payload_json,
  '$.pinned_agent_ids', json((
    SELECT json_group_array(id) FROM (
      SELECT value AS id FROM json_each(user_conversation_launch_preferences.payload_json, '$.pinned_agent_ids')
      WHERE value NOT IN (SELECT agent_id FROM agents WHERE owner_user_id = user_conversation_launch_preferences.owner_user_id AND slug = 'worker')
      UNION ALL
      SELECT agent_id FROM agents
      WHERE owner_user_id = user_conversation_launch_preferences.owner_user_id AND slug = 'soloist'
        AND agent_id NOT IN (SELECT value FROM json_each(user_conversation_launch_preferences.payload_json, '$.pinned_agent_ids'))
    )
  )),
  '$.favorite_agent_ids', json((
    SELECT json_group_array(id) FROM (
      SELECT value AS id FROM json_each(user_conversation_launch_preferences.payload_json, '$.favorite_agent_ids')
      WHERE value NOT IN (SELECT agent_id FROM agents WHERE owner_user_id = user_conversation_launch_preferences.owner_user_id AND slug = 'worker')
      UNION ALL
      SELECT agent_id FROM agents
      WHERE owner_user_id = user_conversation_launch_preferences.owner_user_id AND slug = 'soloist'
        AND agent_id NOT IN (SELECT value FROM json_each(user_conversation_launch_preferences.payload_json, '$.favorite_agent_ids'))
    )
  )),
  '$.agent_id', COALESCE((
    SELECT s.agent_id FROM agents w JOIN agents s ON s.owner_user_id = w.owner_user_id AND s.slug = 'soloist'
    WHERE w.owner_user_id = user_conversation_launch_preferences.owner_user_id AND w.slug = 'worker'
      AND w.agent_id = json_extract(user_conversation_launch_preferences.payload_json, '$.agent_id')
  ), json_extract(payload_json, '$.agent_id'), '')
);
