// Browser half of engines.cjs: mounts the production HtmlBundlePreview (unmodified, with
// the real @ui Select) and lets the runner swap the blob, lock and unmount it.
import { flushSync } from 'react-dom';
import { createRoot, type Root } from 'react-dom/client';
import HtmlBundlePreview from '../../../src/ui/components/HtmlBundlePreview';

// Active interval count, to check the page-link poll is cleared on lock and unmount.
const active = new Set<number>();
const setInterval0 = window.setInterval.bind(window);
const clearInterval0 = window.clearInterval.bind(window);
window.setInterval = ((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
  const id = setInterval0(handler, timeout, ...args);
  active.add(id);
  return id;
}) as typeof window.setInterval;
window.clearInterval = ((id?: number) => {
  if (id !== undefined) active.delete(id);
  clearInterval0(id);
}) as typeof window.clearInterval;

let root: Root | null = null;
let blob: Blob | null = null;
const toBlob = (b64: string) => new Blob([Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))], { type: 'application/zip' });
const render = (locked: boolean) => flushSync(() => root!.render(<HtmlBundlePreview blob={blob} locked={locked} />));

Object.assign(window as any, {
  __intervals: () => active.size,
  __mount: (b64: string) => {
    document.documentElement.style.setProperty('--app-viewport-height', '700px');
    root = createRoot(document.getElementById('root')!);
    blob = toBlob(b64);
    render(false);
  },
  // Version change: a new blob for the same mounted viewer.
  __setBlob: (b64: string) => { blob = toBlob(b64); render(false); },
  __lock: (locked: boolean) => render(locked),
  __unmount: () => { flushSync(() => root!.unmount()); root = null; },
});
