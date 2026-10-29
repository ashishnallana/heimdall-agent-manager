import { useState } from 'react';
import { useSelector } from 'react-redux';
import ArtifactViewer from './ArtifactViewer';
import MarkdownBody, { type MarkdownTextSelection } from './MarkdownBody';

type MarkdownProps = {
  source: string;
  className?: string;
  compact?: boolean;
  copyAll?: boolean;
  onTextSelectionChange?: (selection: MarkdownTextSelection | null) => void;
  'data-debug-id'?: string;
};

export { renderMarkdown } from './MarkdownBody';

function canUseAmbientApiAuth(): boolean {
  if (typeof window === 'undefined') return false;
  return window.location.protocol === 'http:' || window.location.protocol === 'https:';
}

function artifactViewerSession(session: any) {
  if (canUseAmbientApiAuth()) return { daemonUrl: '', clientToken: 'v1' };
  return { daemonUrl: String(session?.daemonUrl || ''), clientToken: String(session?.clientToken || '') };
}

export default function Markdown({ source, className, compact, copyAll = true, onTextSelectionChange, 'data-debug-id': dataDebugId }: MarkdownProps) {
  const session = useSelector((state: any) => state.chat?.session || {});
  const viewerSession = artifactViewerSession(session);
  const [activeArtifactId, setActiveArtifactId] = useState('');

  return (
    <>
      <MarkdownBody
        source={source}
        className={className}
        compact={compact}
        copyAll={copyAll}
        data-debug-id={dataDebugId}
        onArtifactClick={setActiveArtifactId}
        onTextSelectionChange={onTextSelectionChange}
      />
      {activeArtifactId && viewerSession.clientToken ? (
        <ArtifactViewer artifactId={activeArtifactId} daemonUrl={viewerSession.daemonUrl} clientToken={viewerSession.clientToken} onClose={() => setActiveArtifactId('')} />
      ) : null}
    </>
  );
}
