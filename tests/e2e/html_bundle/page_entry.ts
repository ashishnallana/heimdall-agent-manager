// Browser half of the html-bundle preview check: the same compiler, iframe attributes
// and page-link mechanism (poll the frame's location.hash, parse it with
// parseHtmlBundleNavHash) as src/ui/components/HtmlBundlePreview.tsx. The mounted
// component itself is driven in three engines by engines.cjs.
import { HtmlBundleRenderer, parseHtmlBundleNavHash, readHtmlBundle } from '../../../src/ui/utils/htmlBundle.ts';

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

(window as any).__runBundleChecks = async (zipBase64: string) => {
  const bytes = Uint8Array.from(atob(zipBase64), (c) => c.charCodeAt(0));
  const bundle = await readHtmlBundle(bytes);
  const renderer = new HtmlBundleRenderer(bundle);
  const iframe = document.createElement('iframe');
  iframe.setAttribute('sandbox', 'allow-same-origin');
  iframe.setAttribute('referrerpolicy', 'no-referrer');
  iframe.setAttribute('allow', '');
  iframe.style.cssText = 'width:800px;height:400px';
  document.body.appendChild(iframe);
  let current = '';
  let loaded: { doc: Document; hash: string } | null = null;
  const nav: string[] = [];
  const show = (page: string, fragment = '') => new Promise<void>((resolve) => {
    current = page;
    loaded = null;
    nav.push(fragment ? `${page}#${fragment}` : page);
    iframe.onload = () => {
      const doc = iframe.contentDocument!;
      loaded = { doc, hash: doc.location.hash };
      if (fragment) doc.getElementById(fragment)?.scrollIntoView();
      resolve();
    };
    iframe.srcdoc = renderer.compilePage(page).html;
  });
  const poll = setInterval(() => {
    if (!loaded || iframe.contentDocument !== loaded.doc || loaded.doc.location.hash === loaded.hash) return;
    loaded.hash = loaded.doc.location.hash;
    const target = parseHtmlBundleNavHash(loaded.hash);
    if (target && renderer.hasPage(target.page) && target.page !== current) void show(target.page, target.fragment);
  }, 100);
  const r: Record<string, unknown> = {};
  await show(bundle.entry);
  await wait(400);
  const d = iframe.contentDocument!;
  const w = iframe.contentWindow as any;
  r.pages = bundle.pages;
  r.missingOnEntry = renderer.compilePage(bundle.entry).missing;
  r.nestedImageLoaded = (d.getElementById('logo') as HTMLImageElement).naturalWidth === 1;
  r.rootPathImageLoaded = (d.getElementById('rootimg') as HTMLImageElement).naturalWidth === 1;
  r.srcsetRewritten = (d.getElementById('logo') as HTMLImageElement).getAttribute('srcset')?.startsWith('blob:') === true;
  r.remoteImageRemoved = !(d.getElementById('remote') as HTMLImageElement).getAttribute('src');
  r.linkedCssApplied = getComputedStyle(d.body).color === 'rgb(0, 0, 255)';
  r.importedCssApplied = getComputedStyle(d.querySelector('h1')!).textTransform === 'uppercase';
  r.cssUrlImageIsBlob = getComputedStyle(d.getElementById('bg')!).backgroundImage.includes('blob:');
  await (d as any).fonts?.ready;
  r.fontLoaded = [...((d as any).fonts || [])].some((f: any) => f.family.includes('BundleFont') && f.status === 'loaded');
  r.scriptsDisabled = w.__pwned !== true && document.title === 'host';
  r.noScriptElements = d.querySelectorAll('script').length === 0;
  r.handlersStripped = !d.querySelector('[onclick],[onerror],[onload]');
  r.jsUrlStripped = !(d.getElementById('jslink') as HTMLAnchorElement).hasAttribute('href');
  r.formNeutralized = d.querySelectorAll('form').length === 0;
  r.externalLinkInert = !(d.getElementById('external') as HTMLAnchorElement).hasAttribute('href');
  // A "</style>" in bundled CSS must stay CSS text; clicking a leaked link would hit the network log.
  const injected = d.getElementById('inj') as HTMLAnchorElement | null;
  injected?.click();
  r.styleBreakoutContained = !injected;
  r.cspPresent = !!d.querySelector('meta[http-equiv="Content-Security-Policy"]');
  (d.getElementById('totop') as HTMLAnchorElement).click();
  await wait(150);
  r.fragmentScrolledInPlace = w.scrollY > 1000 && current === 'index.html' && iframe.contentDocument === d;
  r.parentUrlUnchanged = location.protocol === 'file:' && !location.hash;
  // REQ-BUNDLE-5: SMIL <set>/<animate> must not survive to retarget the SVG link.
  r.smilAnimationStripped = !d.querySelector('set, animate');
  d.getElementById('smil')!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  await wait(400);
  r.smilLinkStayedInFrame = iframe.contentDocument === d && d.URL.startsWith('about:srcdoc');
  (d.getElementById('next') as HTMLAnchorElement).click();
  await wait(400);
  const d2 = iframe.contentDocument!;
  r.navigatedToNestedPage = current === 'docs/two.html' && !!d2.getElementById('sec');
  r.nestedPageScrolledToFragment = (iframe.contentWindow as any).scrollY > 1000;
  r.nestedPageRelativeCss = getComputedStyle(d2.body).color === 'rgb(0, 0, 255)';
  (d2.getElementById('back') as HTMLAnchorElement).click();
  await wait(400);
  r.navigatedBackViaRootLink = current === 'index.html';
  clearInterval(poll);
  r.nav = nav;
  r.objectUrls = renderer.objectUrlCount;
  renderer.dispose();
  r.objectUrlsAfterDispose = renderer.objectUrlCount;
  r.title = document.title;
  return r;
};
