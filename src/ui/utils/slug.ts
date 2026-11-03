/**
 * Slugs: lowercase ASCII words joined by '-'.
 *
 * `slugify` is the one slug rule in the UI (agents and projects share it).
 * `deriveProjectSlug` picks a project's slug from its PLAINTEXT name: the name is
 * vault-encrypted before it is sent, and a slug derived from the ciphertext would
 * leak `vault:v2:…` into search and generated paths (T17). A name with no ASCII
 * letters or digits (e.g. non-Latin) falls back to the project folder's name, then
 * to 'project'.
 */

/** Lowercase; every run outside [a-z0-9] becomes '-'; leading/trailing dashes trimmed. */
export function slugify(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

/** The last segment of a POSIX or Windows path ('' when there is none). */
export function lastPathSegment(path: string | undefined | null): string {
  const parts = String(path || '').split(/[\\/]+/).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : '';
}

export const FALLBACK_PROJECT_SLUG = 'project';

/** slugify(name), else slugify(last default_path segment), else 'project'. */
export function deriveProjectSlug(name: string | undefined | null, defaultPath?: string | null): string {
  return slugify(String(name || '')) || slugify(lastPathSegment(defaultPath)) || FALLBACK_PROJECT_SLUG;
}
