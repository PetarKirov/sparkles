// The generated site's client layer: the file-explorer sidebar, hydrated from
// one shared tree asset (`DOC12`), and soft navigation between listing pages
// with the sidebar kept alive across it (`DOC13`).
//
// The tree is `assets/tree-<hash>.json`, fetched once and served from cache
// for every subsequent page — which is why it is JSON and not JSON baked into
// a script.
//
// Progressive enhancement: the aside is the only part of the page that needs
// this. Content, header, breadcrumbs and the directory indexes are rendered
// server-side, so a reader without JS (or on `file://`, where fetch cannot
// read a sibling file) loses the explorer and nothing else.
//
// Port of the D renderer this replaced (`page_shell.explorerNav`); the
// open-along-the-current-path, docs-nav-inlining and listing-subtree rules
// are the same, and `libs/docs`' tests pin the data it reads.
const SITE_ROUTE_PREFIX = '/src/';

const mount = document.getElementById('site-explorer');
if (mount) hydrate(mount);
installNavigation();

async function hydrate(el) {
  let data;
  try {
    const res = await fetch(el.dataset.tree, { cache: 'force-cache' });
    if (!res.ok) return;
    data = await res.json();
  } catch {
    return; // file://, offline, blocked — the page stands without us
  }
  el.appendChild(
    buildNav(data, el.dataset.root || '', el.dataset.current || ''),
  );
  el.classList.add('ready');
  const active = el.querySelector('.sb-link.active');
  if (active) active.scrollIntoView({ block: 'center' });
}

function buildNav(data, root, current) {
  const nodes = new Map();
  (function index(n) {
    nodes.set(n.path || '', n);
    (n.dirs || []).forEach(index);
  })(data.root);

  const currentDir = current.slice(0, current.lastIndexOf('/') + 1);
  // Absolute, not page-relative: a soft navigation rewrites the document URL,
  // and relative hrefs in the aside — which survives that navigation — would
  // then resolve against the new page's depth. Resolving once, here, keeps
  // every link right for the life of the tab, `file://` included.
  const href = outPath => new URL(root + outPath, document.baseURI).href;

  // The route of a listing directory this site holds, or null.
  const listingDirOf = link => {
    if (
      !link ||
      !link.startsWith(SITE_ROUTE_PREFIX) ||
      !link.endsWith('/index.html')
    )
      return null;
    const rel = link.slice(SITE_ROUTE_PREFIX.length, -'/index.html'.length);
    return nodes.has(rel) ? rel : null;
  };

  const link = (cls, out, label) => {
    const a = document.createElement('a');
    a.className = cls;
    a.href = href(out);
    a.textContent = label;
    if (out === current) {
      a.classList.add('active');
      a.setAttribute('aria-current', 'page');
    }
    return a;
  };

  const dirDetails = (dirRel, label) => {
    const d = document.createElement('details');
    d.className = 'sb-group';
    d.open = currentDir.startsWith(dirRel + '/');
    const s = document.createElement('summary');
    s.appendChild(link('sb-link sb-dir', dirRel + '/index.html', label));
    d.appendChild(s);
    const items = document.createElement('div');
    items.className = 'sb-items';
    const node = nodes.get(dirRel);
    if (node) walk(node, items);
    d.appendChild(items);
    return d;
  };

  // A nav group renders open when the reader is somewhere inside one of its
  // listing subtrees — the chain above them unfolds like the file tree does.
  const navHasCurrent = items =>
    (items || []).some(it => {
      if (it.items && it.items.length && navHasCurrent(it.items)) return true;
      const dirRel = listingDirOf(it.link);
      return (
        !!dirRel &&
        (currentDir.startsWith(dirRel + '/') ||
          current === dirRel + '/index.html')
      );
    });

  const renderNav = (items, into) => {
    for (const it of items || []) {
      if (it.items && it.items.length) {
        const d = document.createElement('details');
        d.className = 'sb-group';
        d.open = !it.collapsed || navHasCurrent(it.items);
        const s = document.createElement('summary');
        s.textContent = it.text;
        d.appendChild(s);
        const box = document.createElement('div');
        box.className = 'sb-items';
        renderNav(it.items, box);
        d.appendChild(box);
        into.appendChild(d);
        continue;
      }
      const dirRel = listingDirOf(it.link);
      if (dirRel) {
        into.appendChild(
          dirDetails(dirRel, dirRel.slice(dirRel.lastIndexOf('/') + 1) + '/'),
        );
        continue;
      }
      if (it.link) {
        const a = document.createElement('a');
        a.className = 'sb-link';
        a.href = /^https?:\/\//.test(it.link)
          ? it.link
          : (data.base || '') + it.link;
        a.textContent = it.text;
        if (it.target) a.target = it.target;
        if (it.rel) a.rel = it.rel;
        into.appendChild(a);
      } else {
        const s = document.createElement('span');
        s.className = 'sb-text';
        s.textContent = it.text;
        into.appendChild(s);
      }
    }
  };

  function walk(node, into) {
    // The docs node IS the docs nav: its groups inline, its raw directory
    // children suppressed — their listing subtrees sit inside the owning
    // groups already. Loose files directly under docs/ still render below.
    const navHere = node.path === 'docs' && data.nav && data.nav.length;
    if (navHere) renderNav(data.nav, into);
    else
      for (const d of node.dirs || [])
        into.appendChild(
          dirDetails(d.path, d.path.slice(d.path.lastIndexOf('/') + 1) + '/'),
        );
    for (const f of node.files || [])
      into.appendChild(
        link('sb-link', (node.path ? node.path + '/' : '') + f.href, f.label),
      );
  }

  const nav = document.createElement('nav');
  nav.setAttribute('aria-label', 'Files');
  walk(data.root, nav);
  return nav;
}

// ── soft navigation (`DOC13`) ───────────────────────────────────────────────
//
// A listing page is mostly chrome the next one repeats: the same header, the
// same aside, a different <main>. Fetching only what changes keeps the
// explorer's scroll position and open state across a click — the persistent
// layout a multi-page site otherwise cannot have — and, where the browser
// supports it, animates the swap through a View Transition.
//
// Everything here is enhancement over links that already work: no interception
// happens for a modified click, a different-origin target, a download, or a
// page this module could not fetch, and any failure falls through to a normal
// navigation.
//
// Prefetch is our own small cache rather than the Speculation Rules API: rules
// feed the browser's *navigation* cache, which a `fetch()`-driven swap cannot
// read, so declaring them here would double every request. A hard navigation
// (no JS) is the case rules would help, and it has no script to declare them.
const PREFETCH_MAX = 24;
const prefetched = new Map();

function installNavigation() {
  if (!window.history?.pushState) return;

  addEventListener('click', e => {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest?.('a[href]');
    if (!a || a.target || a.hasAttribute('download')) return;
    const url = softTarget(a);
    if (!url) return;
    e.preventDefault();
    navigate(url, true);
  });

  // Warm the cache on intent: a pointer resting on a link, or a touch that has
  // not yet lifted, is the cheapest signal of the next navigation there is.
  const warm = e => {
    const a = e.target.closest?.('a[href]');
    const url = a && softTarget(a);
    if (url) prefetch(url);
  };
  addEventListener('pointerover', warm, { passive: true });
  addEventListener('touchstart', warm, { passive: true });

  addEventListener('popstate', () => navigate(location.href, false));
}

/// The absolute URL a click should be handled in-page, or null when the link
/// is not one of this site's own pages.
function softTarget(a) {
  const href = a.getAttribute('href');
  if (!href || href.startsWith('#')) return null;
  let url;
  try {
    url = new URL(a.href);
  } catch {
    return null;
  }
  if (url.origin !== location.origin) return null;
  if (!url.pathname.endsWith('.html')) return null;
  if (url.href.split('#')[0] === location.href.split('#')[0]) return null;
  return url.href;
}

function prefetch(url) {
  if (prefetched.has(url)) return prefetched.get(url);
  if (prefetched.size >= PREFETCH_MAX)
    prefetched.delete(prefetched.keys().next().value);
  // Default cache mode: a page is not content-addressed (only the assets it
  // links are), so it has to revalidate like any other document.
  const p = fetch(url)
    .then(r => (r.ok ? r.text() : null))
    .catch(() => null);
  prefetched.set(url, p);
  return p;
}

async function navigate(url, push) {
  const html = await prefetch(url);
  if (html == null) {
    location.href = url; // let the browser do what we could not
    return;
  }
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const header = doc.querySelector('header');
  const content = doc.querySelector('.content');
  if (!header || !content) {
    location.href = url;
    return;
  }

  // The URL moves first: everything swapped in carries page-relative hrefs
  // written for *that* page, and they resolve against the document's URL.
  if (push) history.pushState(null, '', url);

  const apply = () => {
    document.title = doc.title;
    document
      .querySelector('header')
      .replaceWith(document.importNode(header, true));
    document
      .querySelector('.content')
      .replaceWith(document.importNode(content, true));
    markCurrent(url);
    dispatchEvent(new CustomEvent('hue:navigate', { detail: { url } }));
  };

  if (document.startViewTransition) document.startViewTransition(apply);
  else apply();
}

/// Move the explorer's `active` marker to the page just navigated to, and open
/// the collapsibles above it — the aside itself is never rebuilt.
function markCurrent(url) {
  const aside = document.getElementById('site-explorer');
  if (!aside) return;
  for (const a of aside.querySelectorAll('.sb-link.active')) {
    a.classList.remove('active');
    a.removeAttribute('aria-current');
  }
  const bare = url.split('#')[0];
  const a = [...aside.querySelectorAll('a.sb-link')].find(
    l => l.href.split('#')[0] === bare,
  );
  if (!a) return;
  a.classList.add('active');
  a.setAttribute('aria-current', 'page');
  for (let d = a.closest('details'); d; d = d.parentElement.closest('details'))
    d.open = true;
  a.scrollIntoView({ block: 'nearest' });
}
