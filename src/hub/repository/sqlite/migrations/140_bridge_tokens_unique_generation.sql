-- Backstop for single-use rotation: one access and one refresh row per generation
-- of a family. A racing mint of an already-taken generation fails its INSERT
-- instead of creating a second live credential. run_migrations skips (and logs) this
-- index on a database whose existing rows already violate it, rather than refusing
-- to start; such duplicates can only come from the pre-fix grace race.
CREATE UNIQUE INDEX IF NOT EXISTS bridge_tokens_family_kind_generation ON bridge_tokens(family_id, kind, generation);
