/** Collect the complete project inventory before checking import paths or names.
 * Reject incomplete or looping pagination rather than exposing unsafe candidates. */
export async function loadAllProjectPages(
  fetchPage: (cursor: string) => Promise<any>,
): Promise<any[]> {
  const projects: any[] = [];
  const seen = new Set<string>();
  let cursor = '';
  for (;;) {
    const body = await fetchPage(cursor);
    const items = body?.data;
    const page = body?.page;
    if (!Array.isArray(items) || typeof page?.has_more !== 'boolean') {
      throw new Error('Could not check all existing projects.');
    }
    projects.push(...items);
    if (!page.has_more) return projects;
    const next = page.next_cursor;
    if (typeof next !== 'string' || !next || next === cursor || seen.has(next)) {
      throw new Error('Could not check all existing projects: invalid pagination.');
    }
    seen.add(next);
    cursor = next;
  }
}
