// The file-explorer sidebar, hydrated from the site's one shared tree asset
// (`DOC12`). The page ships an empty <aside> and this module; the tree itself
// is `assets/tree-<hash>.json`, fetched once and served from cache for every
// subsequent page — which is why it is JSON and not JSON baked into a script.
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
  const href = outPath => root + outPath;

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
