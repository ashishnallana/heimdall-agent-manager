import type { CreateShellArgs } from '../../api/endpoints/shells';

type ProjectBridgePathLike = {
  bridge_id?: string;
  bridgeId?: string;
  path?: string;
};

type ProjectWithBridgePaths = {
  bridge_paths?: ProjectBridgePathLike[];
  bridgePaths?: ProjectBridgePathLike[];
} | null | undefined;

export function resolveProjectBridgeShellCwd(
  project: ProjectWithBridgePaths,
  bridgeId: string | undefined,
): string | undefined {
  const targetBridgeId = String(bridgeId || '').trim();
  if (!targetBridgeId) return undefined;

  const paths = Array.isArray(project?.bridge_paths)
    ? project.bridge_paths
    : Array.isArray(project?.bridgePaths)
      ? project.bridgePaths
      : [];
  const match = paths.find(
    (entry) => String(entry?.bridge_id || entry?.bridgeId || '').trim() === targetBridgeId,
  );
  const path = String(match?.path || '').trim();
  return path || undefined;
}

/**
 * A new interactive shell (kind=shell). `cmd` and `cwd` are sent only when non-blank:
 * with no cmd the bridge starts the user's login shell, with no cwd it starts in HOME.
 */
export function buildInteractiveShellRequest({
  bridgeId,
  cwd,
  cmd,
  chainId,
  projectId,
}: {
  bridgeId: string;
  cwd?: string;
  cmd?: string;
  chainId?: string;
  projectId?: string;
}): CreateShellArgs {
  const request: CreateShellArgs = {
    bridgeId,
    kind: 'shell',
  };
  const normalizedCwd = String(cwd || '').trim();
  if (normalizedCwd) request.cwd = normalizedCwd;
  const normalizedCmd = String(cmd || '').trim();
  if (normalizedCmd) request.cmd = normalizedCmd;
  if (chainId) request.chain_id = chainId;
  if (projectId) request.project_id = projectId;
  return request;
}
