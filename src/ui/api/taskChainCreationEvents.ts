// The sidebar owns cursor pages outside RTK Query, like the shell list. Only
// successful creation resets it; task/status churn never causes a list request.
// The same creation can arrive from the mutation and its user-WS echo.
const seen = new Set<string>();
const listeners = new Set<() => void>();
let revision = 0;

export const taskChainCreationRevision = () => revision;
export function subscribeTaskChainCreation(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
export function announceTaskChainCreated(chainId: string): void {
  if (!chainId || seen.has(chainId)) return;
  seen.add(chainId);
  if (seen.size > 256) seen.delete(seen.values().next().value!);
  revision += 1;
  listeners.forEach(listener => listener());
}
