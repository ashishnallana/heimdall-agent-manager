import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Select, Spinner } from '@ui';
import { HtmlBundleError, HtmlBundleRenderer, readHtmlBundle, type HtmlBundle } from '../utils/htmlBundle';

// REQ-BUNDLE-3/4/5: renders a decrypted html-bundle artifact in an isolated iframe.
//
// Isolation: `sandbox="allow-same-origin"` WITHOUT allow-scripts, allow-forms,
// allow-popups or allow-top-navigation, plus the CSP meta every compiled page carries
// (no network, no scripts). Without script the frame cannot reach the app's DOM, storage
// or credentials; allow-same-origin only lets THIS component attach a click listener to
// the frame's document so page links can be followed host-side and the page selector
// kept in sync. Never add allow-scripts here: with allow-same-origin it would void the
// sandbox entirely.

type Status =
  | { kind: 'loading' }
  | { kind: 'error'; code: string; message: string }
  | { kind: 'ready'; bundle: HtmlBundle; renderer: HtmlBundleRenderer };

type Location = { page: string; fragment: string };

const ERROR_TITLES: Record<string, string> = {
  malformed: 'This HTML bundle is malformed',
  unsafe: 'This HTML bundle was rejected',
  too_large: 'This HTML bundle is too large to preview',
  missing_entry: 'The bundle entry page is missing',
};

export default function HtmlBundlePreview({ blob, locked, lockReason = 'locked' }: { blob: Blob | null; locked: boolean; lockReason?: '' | 'locked' | 'other_vault' }) {
  const [status, setStatus] = useState<Status>({ kind: 'loading' });
  const [location, setLocation] = useState<Location>({ page: '', fragment: '' });
  // Bumped to remount the iframe when it escaped about:srcdoc (see handleLoad).
  const [frameKey, setFrameKey] = useState(0);
  const [navigationBlocked, setNavigationBlocked] = useState(false);
  const iframeRef = useRef<HTMLIFrameElement | null>(null);

  useEffect(() => {
    if (!blob || locked) {
      setStatus({ kind: 'loading' });
      return;
    }
    let cancelled = false;
    let renderer: HtmlBundleRenderer | null = null;
    setStatus({ kind: 'loading' });
    setNavigationBlocked(false);
    blob.arrayBuffer()
      .then((buffer) => readHtmlBundle(new Uint8Array(buffer)))
      .then((bundle) => {
        if (cancelled) return;
        renderer = new HtmlBundleRenderer(bundle);
        setLocation({ page: bundle.entry, fragment: '' });
        setStatus({ kind: 'ready', bundle, renderer });
      })
      .catch((err) => {
        if (cancelled) return;
        const code = err instanceof HtmlBundleError ? err.code : 'malformed';
        setStatus({ kind: 'error', code, message: String(err?.message || err) });
      });
    // Close, version change and vault lock all replace or drop `blob`: every blob: URL
    // and the parsed archive are released here. Nothing is persisted.
    return () => {
      cancelled = true;
      renderer?.dispose();
    };
  }, [blob, locked]);

  const compiled = useMemo(() => {
    if (status.kind !== 'ready' || !location.page) return null;
    try {
      return { ...status.renderer.compilePage(location.page), error: '' };
    } catch (err) {
      return { html: '', missing: [] as string[], error: String((err as Error)?.message || err) };
    }
  }, [status, location.page]);

  const scrollToFragment = useCallback((fragment: string) => {
    const doc = iframeRef.current?.contentDocument;
    if (!doc) return;
    if (!fragment) {
      doc.defaultView?.scrollTo(0, 0);
      return;
    }
    const target = doc.getElementById(fragment) || doc.getElementsByName(fragment)[0];
    target?.scrollIntoView();
  }, []);

  const handleLoad = useCallback(() => {
    const doc = iframeRef.current?.contentDocument;
    // Backstop for sanitizer gaps: every compiled page is same-origin about:srcdoc, so an
    // unreachable document (cross-origin) or any other URL means the frame navigated
    // away. Remount it on the current page instead of leaving foreign content shown.
    if (!doc || !doc.URL.startsWith('about:srcdoc')) {
      setNavigationBlocked(true);
      setFrameKey((key) => key + 1);
      return;
    }
    if (status.kind !== 'ready') return;
    doc.addEventListener('click', (event) => {
      const anchor = (event.target as Element | null)?.closest?.('a[data-hb-page], area[data-hb-page]');
      if (!anchor) return;
      event.preventDefault();
      const page = anchor.getAttribute('data-hb-page') || '';
      const fragment = anchor.getAttribute('data-hb-fragment') || '';
      if (!status.renderer.hasPage(page)) return;
      if (page === location.page) scrollToFragment(fragment);
      else setLocation({ page, fragment });
    });
    scrollToFragment(location.fragment);
  }, [status, location, scrollToFragment]);

  if (locked) {
    return (
      <div data-debug-id="artifact-viewer-html-bundle-locked" className="rounded-xl border border-subtle bg-surface-raised px-4 py-6 text-center text-sm text-muted">
        {lockReason === 'other_vault'
          ? 'This HTML bundle was encrypted by a previous vault and cannot be opened with the current one.'
          : 'This HTML bundle is encrypted. Unlock the vault to preview it.'}
      </div>
    );
  }
  if (status.kind === 'loading') {
    return (
      <div data-debug-id="artifact-viewer-html-bundle-loading" className="grid min-h-[calc(var(--app-viewport-height)*0.4)] place-items-center rounded-2xl border border-subtle bg-surface-raised">
        <Spinner size="lg" label="Preparing HTML preview…" className="text-accent" />
      </div>
    );
  }
  if (status.kind === 'error') {
    return (
      <div data-debug-id="artifact-viewer-html-bundle-error" data-error-code={status.code} className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">
        <div className="font-medium">{ERROR_TITLES[status.code] || ERROR_TITLES.malformed}</div>
        <div className="mt-1 break-words">{status.message}</div>
        <div className="mt-1 text-xs">Use Download to inspect the ZIP.</div>
      </div>
    );
  }

  return (
    <div data-debug-id="artifact-viewer-html-bundle" className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2">
        <label className="text-xs uppercase tracking-wide text-faint">Page</label>
        <Select
          data-debug-id="artifact-viewer-html-bundle-page-select"
          value={location.page}
          onChange={(next) => setLocation({ page: String(next), fragment: '' })}
        >
          {status.bundle.pages.map((page) => (
            <option key={page} value={page}>{page === status.bundle.entry ? `${page} (entry)` : page}</option>
          ))}
        </Select>
      </div>
      {compiled?.error ? (
        <div data-debug-id="artifact-viewer-html-bundle-page-error" className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">{compiled.error}</div>
      ) : null}
      {navigationBlocked ? (
        <div data-debug-id="artifact-viewer-html-bundle-navigation-blocked" className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-2 text-xs text-warning">
          The page tried to navigate outside the bundle; the preview was reset.
        </div>
      ) : null}
      {compiled && compiled.missing.length > 0 ? (
        <div data-debug-id="artifact-viewer-html-bundle-resource-warning" className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-2 text-xs text-warning">
          {compiled.missing.length} resource{compiled.missing.length === 1 ? '' : 's'} could not be loaded (missing, remote or unsupported): {compiled.missing.slice(0, 5).join(', ')}{compiled.missing.length > 5 ? ', …' : ''}
        </div>
      ) : null}
      <iframe
        key={frameKey}
        ref={iframeRef}
        data-debug-id="artifact-viewer-html-bundle-frame"
        title={location.page}
        sandbox="allow-same-origin"
        referrerPolicy="no-referrer"
        allow=""
        srcDoc={compiled?.html || ''}
        onLoad={handleLoad}
        className="h-[calc(var(--app-viewport-height)*0.65)] w-full rounded-2xl border border-subtle bg-white"
      />
    </div>
  );
}
