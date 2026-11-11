/**
 * Row patches for a verb fired from a list page's detail pane.
 *
 * The Agents, Projects, Memory and Shells list pages keep their own rows in
 * `useInfiniteList`. RTK tag invalidation never reaches those rows, and the list's
 * `refresh()` only feeds the "N new or updated" pill, so a verb fired from the
 * right-hand detail pane left its row stale until a reload. The pane now hands the
 * verb and the server's response to the list, which patches the row with these.
 */

type ArchivableRow = { state: string; updatedAt: string };

/** The row after an archive/unarchive succeeded; `saved` is the hub's response. */
export function archivedRowPatch<T extends ArchivableRow>(prev: T, verb: 'archive' | 'unarchive', saved: unknown): T {
  const updatedAt = saved && typeof saved === 'object' ? String((saved as { updated_at?: unknown }).updated_at || '') : '';
  return { ...prev, state: verb === 'archive' ? 'archived' : 'active', updatedAt: updatedAt || prev.updatedAt };
}

export type ShellRowPatch<S> = { id: string; next: S | ((prev: S) => S) } | null;

/**
 * What a shell verb does to its list row, mirroring the row verbs: kill repaints
 * the row as killed, restart takes the hub's returned session, interrupt changes
 * nothing the row shows.
 */
export function shellRowPatch<S extends { session_id: string; status: string }>(
  verb: string,
  session: S,
  saved: unknown,
): ShellRowPatch<S> {
  if (verb === 'kill') return { id: session.session_id, next: (prev: S) => ({ ...prev, status: 'killed' }) };
  if (verb === 'restart') {
    const next = saved && typeof saved === 'object' ? (saved as S) : null;
    return next?.session_id ? { id: next.session_id, next } : null;
  }
  return null;
}
