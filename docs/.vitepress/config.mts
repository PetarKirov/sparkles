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

// Listing directories join the docs sidebar (DSC7): the merge itself lives
// in D (`sparkles.docs.site.augmentWithListingDirs`) — `hue site` writes the
// augmented tree beside the manifest, and this config just READS it, falling
// back to the raw sidebar.json when the listings are not built. One
// algorithm, one implementation; sidebar.json stays the checked source of
// truth for pages (ci --check-docs-sidebar is unaffected).
const augmentedSidebarPath = path.resolve(
  process.cwd(),
  'docs/public/src/sidebar.json',
);
const effectiveSidebar: DefaultTheme.SidebarItem[] = fs.existsSync(
  augmentedSidebarPath,
)
  ? (JSON.parse(
      fs.readFileSync(augmentedSidebarPath, 'utf8'),
    ) as DefaultTheme.SidebarItem[])
  : (sidebar as DefaultTheme.SidebarItem[]);

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
      // wired's vendored-SDL license inventory (linked from the SDL provenance
      // spec) — a repo file, not a site page.
      /\/libs\/wired\/THIRD_PARTY_NOTICES$/,
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
      //
      // The whole index ships as ONE JavaScript chunk, and Cloudflare Pages
      // refuses any file over 25 MiB. Indexing every page's full prose put that
      // chunk at 26.0 MiB (measured 2026-08-26), which fails the deploy outright.
      //
      // `docs/research/` is ~30 MiB of the ~34 MiB of markdown in the tree and
      // therefore ~88% of the index: excluding it entirely drops the chunk to
      // 3.20 MiB, and indexing it by heading alone drops it to 7.95 MiB. The
      // second is what we do, because it keeps every research page findable by
      // its title and section headings — which is how the surveys are actually
      // navigated — while leaving ~17 MiB of headroom for the corpus to grow.
      //
      // If full-text search over the research corpus becomes necessary, the
      // answer is a hosted index (Algolia DocSearch), not a bigger chunk.
      search: {
        provider: 'local',
        options: {
          _render(src, env, md) {
            // Preserve VitePress's own opt-out.
            if (env.frontmatter?.search === false) return '';

            if (env.relativePath?.startsWith('research/')) {
              const headings = src
                .split(/\r?\n/)
                .filter(line => /^#{1,6}\s/.test(line))
                .join('\n');
              return md.render(headings, env);
            }

            return md.render(src, env);
          },
        },
      },

      nav: [
        { text: 'Docs', link: '/overview' },
        { text: 'API', link: '/api/' },
      ],

      sidebar: effectiveSidebar,

      socialLinks: [
        { icon: 'github', link: 'https://github.com/PetarKirov/sparkles' },
      ],
    },
  }),
);
