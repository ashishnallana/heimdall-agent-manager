
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
