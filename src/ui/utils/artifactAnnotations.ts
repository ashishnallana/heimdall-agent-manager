export const ARTIFACT_ANNOTATIONS_STORAGE_KEY = 'heimdall.artifact.annotations.v1';

export type TextAnnotationContext = {
  type: 'text';
  lineStart?: number;
  lineEnd?: number;
  selectedText?: string;
  charStart?: number;
  charEnd?: number;
};

export type ImageAnnotationContext = {
  type: 'image';
  x: number;
  y: number;
  w: number;
  h: number;
  xPercent: number;
  yPercent: number;
  wPercent: number;
  hPercent: number;
  imageNaturalWidth?: number;
  imageNaturalHeight?: number;
};

export type ArtifactAnnotationContext = TextAnnotationContext | ImageAnnotationContext;

export type ArtifactAnnotationRecord = {
  annotationId: string;
  artifactId: string;
  artifactUri: string;
  artifactName: string;
  artifactMime: string;
  artifactKind: string;
  versionNo: number;
  createdAt: number;
  updatedAt: number;
  comment: string;
  context: ArtifactAnnotationContext;
};

export type CreateArtifactAnnotationInput = Omit<ArtifactAnnotationRecord, 'annotationId' | 'createdAt' | 'updatedAt'> & {
  annotationId?: string;
  createdAt?: number;
  updatedAt?: number;
};

export function buildArtifactUri(artifactId: string) {
  return artifactId ? `artifact://${artifactId}` : 'artifact://unknown';
}

export function createAnnotationId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `annotation_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

function formatNumber(value: number) {
  if (!Number.isFinite(value)) return '0';
  if (Math.abs(value - Math.round(value)) < 0.001) return String(Math.round(value));
  return value.toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1');
}

function formatPercent(value: number) {
  if (!Number.isFinite(value)) return '0.0%';
  return `${value.toFixed(1)}%`;
}

function quoteSelection(value: string) {
  const trimmed = value.replace(/\s+/g, ' ').trim();
  if (!trimmed) return '';
  return `“${trimmed}”`;
}

export function formatAnnotationMarkdown(annotation: ArtifactAnnotationRecord) {
  const artifactName = annotation.artifactName || annotation.artifactId || 'Artifact';
  const artifactUri = annotation.artifactUri || buildArtifactUri(annotation.artifactId);
  const contextLines = [
    `- artifact: ${artifactUri}`,
    `- file: ${artifactName}`,
    `- version: v${annotation.versionNo}`,
    `- type: ${annotation.artifactMime || annotation.artifactKind || 'artifact'}`,
  ];

  if (annotation.context.type === 'image') {
    contextLines.push(`- region: x=${formatNumber(annotation.context.x)} y=${formatNumber(annotation.context.y)} w=${formatNumber(annotation.context.w)} h=${formatNumber(annotation.context.h)}`);
    contextLines.push(`- region_percent: x=${formatPercent(annotation.context.xPercent)} y=${formatPercent(annotation.context.yPercent)} w=${formatPercent(annotation.context.wPercent)} h=${formatPercent(annotation.context.hPercent)}`);
  } else {
    if (annotation.context.lineStart && annotation.context.lineEnd && annotation.context.lineStart !== annotation.context.lineEnd) {
      contextLines.push(`- location: lines ${annotation.context.lineStart}-${annotation.context.lineEnd}`);
    } else if (annotation.context.lineStart) {
      contextLines.push(`- location: line ${annotation.context.lineStart}`);
    }
    if (annotation.context.selectedText) {
      contextLines.push(`- selection: ${quoteSelection(annotation.context.selectedText)}`);
    }
  }

  return [
    `Artifact annotation on [${artifactName}](${artifactUri})`,
    '',
    'Context:',
    ...contextLines,
    '',
    'Comment:',
    annotation.comment.trim() || '(empty comment)',
  ].join('\n');
}

export async function copyTextToClipboard(text: string) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall through to the textarea fallback; Electron/Chromium can expose the
      // Clipboard API while rejecting writes for permission/focus reasons.
    }
  }

  const textarea = document.createElement('textarea');
  try {
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    if (!document.execCommand('copy')) {
      throw new Error('Copy command was not accepted');
    }
  } finally {
    textarea.remove();
  }
}
