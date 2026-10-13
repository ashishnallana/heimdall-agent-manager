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

export function buildInteractiveShellRequest({
  bridgeId,
  cwd,
  chainId,
  projectId,
}: {
  bridgeId: string;
  cwd?: string;
  chainId?: string;
  projectId?: string;
}): CreateShellArgs {
  const request: CreateShellArgs = {
    bridgeId,
    kind: 'shell',
  };
  const normalizedCwd = String(cwd || '').trim();
  if (normalizedCwd) request.cwd = normalizedCwd;
  if (chainId) request.chain_id = chainId;
  if (projectId) request.project_id = projectId;
  return request;
}
