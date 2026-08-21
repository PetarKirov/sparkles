import { defineConfig, type DefaultTheme } from 'vitepress';
import { withMermaid } from 'vitepress-plugin-mermaid';
import { groupIconMdPlugin } from 'vitepress-plugin-group-icons';

// The sidebar tree and the srcExclude list are plain data, not code, and they
// have consumers besides VitePress: `ci --check-docs-sidebar` verifies every
// published page is linked (and that every link resolves to a page). Those two
// JSON files are the single source of truth; this config imports them. To add
// a page, edit sidebar.json — see docs/guidelines/AGENTS.md § "The docs
// sidebar is data".
import sidebar from './sidebar.json' with { type: 'json' };
import docsConfig from './docs-config.json' with { type: 'json' };
import fs from 'fs';
import path from 'path';

// Source-code listings (docs/specs/docs/discovery.md, DSC4): `hue site`
// pre-renders repository sources into docs/public/src and emits manifest.json
// — the single contract this config reads. A prose link rewrites to its
// listing route IFF the manifest maps it; with no manifest (listings not
// built) nothing rewrites and the build stays green. Existence on disk is
// guaranteed by construction: the manifest lists only pages the run wrote.
type SiteManifest = {
  files: Record<string, string>;
  dirs: Record<string, string>;
};
const manifestPath = path.resolve(
  process.cwd(),
  'docs/public/src/manifest.json',
);
const manifest: SiteManifest | null = fs.existsSync(manifestPath)
  ? (JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as SiteManifest)
  : null;

// Listing directories under docs/ join the sidebar group that owns that part
// of the docs tree (DSC7): e.g. the source examples in
// docs/research/async-io/io-uring/examples appear as "examples/" under the
// group whose pages live at /research/async-io/io-uring/. Only immediate
// children are added — deeper trees are reachable through the listing's own
// explorer sidebar. Runtime augmentation, not an edit to sidebar.json: the
// data file stays the source of truth for *pages*, and ci --check-docs-sidebar
// keeps checking it (listing routes are generated pages, not docs pages).
function augmentSidebar(
  items: DefaultTheme.SidebarItem[],
): DefaultTheme.SidebarItem[] {
  if (!manifest) {
    return items;
  }
  type Group = { node: DefaultTheme.SidebarItem; dirs: Set<string> };
  const groups: Group[] = [];
  function collect(node: DefaultTheme.SidebarItem) {
    if (!node.items) {
      return;
    }
    // A directory belongs to the group that lists pages in it DIRECTLY —
    // a child that is itself a group owns its own directories.
    const dirs = new Set<string>();
    const own = (n: DefaultTheme.SidebarItem) => {
      if (n.link?.startsWith('/')) {
        dirs.add(
          n.link.endsWith('/')
            ? n.link
            : n.link.slice(0, n.link.lastIndexOf('/') + 1),
        );
      }
    };
    own(node);
    for (const child of node.items) {
      if (!child.items) {
        own(child);
      }
    }
    groups.push({ node, dirs });
    node.items.forEach(collect);
  }
  items.forEach(collect);

  const additions = new Map<Group, { text: string; link: string }[]>();
  for (const [dir, route] of Object.entries(manifest.dirs)) {
    if (!dir.startsWith('docs/')) {
      continue;
    }
    const listingRoute = '/' + dir.slice('docs/'.length) + '/';
    let best: Group | null = null;
    let bestLen = 0;
    for (const g of groups) {
      for (const d of g.dirs) {
        if (listingRoute.startsWith(d) && d.length > bestLen) {
          best = g;
          bestLen = d.length;
        }
      }
    }
    if (!best || bestLen <= 1) {
      continue; // unowned, or owned only by the site root — too noisy
    }
    const rel = listingRoute.slice(bestLen);
    if (rel.split('/').filter(Boolean).length !== 1) {
      continue; // not an immediate child of the group's directory
    }
    if (!additions.has(best)) {
      additions.set(best, []);
    }
    additions.get(best)!.push({ text: rel + ' (source)', link: route });
  }
  for (const [group, entries] of additions) {
    entries.sort((a, b) => a.text.localeCompare(b.text));
    group.node.items!.push(...entries);
  }
  return items;
}

function listingRouteFor(href: string, relativePath: string): string | null {
  if (!manifest || /^(https?:|mailto:|#|\/)/.test(href)) {
    return null;
  }
  const [urlPath] = href.split('#');
  if (!urlPath) {
    return null;
  }
  const abs = path.resolve(
    process.cwd(),
    'docs',
    path.dirname(relativePath),
    urlPath,
  );
  const rel = path.relative(process.cwd(), abs).replace(/\\/g, '/');
  if (rel.startsWith('..')) {
    return null;
  }
  return manifest.files[rel] ?? manifest.dirs[rel] ?? null;
}

export default withMermaid(
  defineConfig({
    title: 'Sparkles',
    description: 'D library for building CLI applications',
    base: '/',

    // Ignore links to .d/.c/.nix/.sdl source files and to sample/ workspace directories
    // (source artifacts under research/monorepo-tooling/<tool>/sample/ and the
    // os-apis demo packages' ImportC shims, not pages), and links into repo
    // source trees the harness docs reference (the text-conformance tool + the
    // base/text source) — these resolve on GitHub but the VitePress site doesn't
    // serve repo source.
    ignoreDeadLinks: [
      /\.c$/,
      /\.d$/,
      /\.nix$/,
      /\.sdl$/,
      /\/sample\//,
      /\/sample$/,
      /\/example\//,
      /\/text-conformance\//,
      /\/libs\/base\/src\//,
      /\/libs\/wired\/bench\//,
      /\/research\/application-packaging\/grounding\//,
      // The twoslash showcase is a static gallery generated into docs/public/ at
      // build time (docs/scripts/build-twoslash-showcase.sh), not a markdown page.
      /\/apps\/hue\/twoslash\//,
      // Source listings are static pages generated into docs/public/src at
      // build time (hue site); the manifest guarantees each emitted route.
      /^\/src\//,
    ],

    // Which pages the site does not build (internal QA evidence: the research
    // grounding ledgers and a couple of planning files). The list lives in
    // docs-config.json so the D tooling reads the same one — see the note
    // above the imports.
    srcExclude: docsConfig.srcExclude,

    markdown: {
      config(md) {
        md.use(groupIconMdPlugin);
        // Pushed last so it wins over VitePress's own link handling: rewrite a
        // repository-file link to its pre-rendered listing (see the manifest
        // note at the top of this file).
        md.core.ruler.push('rewrite-source-links', state => {
          const relativePath = state.env?.relativePath;
          if (!relativePath || !manifest) return;
          function walk(tokens: any[]) {
            for (const token of tokens) {
              if (token.type === 'link_open') {
                const hrefAttr = token.attrs?.find(
                  (attr: string[]) => attr[0] === 'href',
                );
                if (hrefAttr) {
                  const route = listingRouteFor(hrefAttr[1], relativePath);
                  if (route) {
                    hrefAttr[1] = route;
                    token.attrSet('class', 'src-listing-link');
                    token.attrSet('target', '_blank');
                    token.attrSet('rel', 'noreferrer');
                  }
                }
              }
              if (token.children) {
                walk(token.children);
              }
            }
          }
          walk(state.tokens);
        });
      },
      languageAlias: {
        sdl: 'd',
        eff: 'ocaml',
        frank: 'ocaml',
        koka: 'typescript',
        wat: 'wasm',
        unison: 'haskell',
        odin: 'go',
        xaml: 'xml',
        wast: 'wasm',
        // Monorepo-tooling fences whose grammars ARE bundled under another name.
        // (Unbundled ones — ninja, meson, just — are left to Shiki's graceful
        // plain-text fallback; aliasing them to a non-grammar errors the build.)
        starlark: 'python',
        bzl: 'python',
      },
    },

    themeConfig: {
      // Built-in local search (MiniSearch) — fully client-side, no third-party APIs.
      search: {
        provider: 'local',
      },

      nav: [
        { text: 'Docs', link: '/overview' },
        { text: 'API', link: '/api/' },
      ],

      sidebar: augmentSidebar(sidebar as DefaultTheme.SidebarItem[]),

      socialLinks: [
        { icon: 'github', link: 'https://github.com/PetarKirov/sparkles' },
      ],
    },
  }),
);
