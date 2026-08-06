import { defineConfig, type DefaultTheme } from 'vitepress';
import { withMermaid } from 'vitepress-plugin-mermaid';
import { groupIconMdPlugin } from 'vitepress-plugin-group-icons';
import fs from 'fs';
import path from 'path';

// The sidebar tree and the srcExclude list are plain JSON data, not code, and
// they have consumers besides VitePress: `ci --check-docs-sidebar` verifies
// every published page is linked (and every link resolves), `ci --audit-fences`
// needs the same site-visibility rule, and `hue` renders the sidebar onto its
// generated pages. Those files are the single source of truth; this config
// imports them. To add a page, edit sidebar.json — see
// docs/guidelines/AGENTS.md § "The docs sidebar is data".
import sidebar from './sidebar.json' with { type: 'json' };
import docsConfig from './docs-config.json' with { type: 'json' };

function rewriteLink(href: string, relativePath: string): string | null {
  if (/^(https?:|mailto:|#)/.test(href)) {
    return null;
  }
  if (href.startsWith('/')) {
    return null;
  }

  const [urlPath, anchor] = href.split('#');
  const currentDir = path.dirname(relativePath);

  // Resolve relative path from the current markdown file's directory
  const resolvedPath = path.join(currentDir, urlPath);
  const absolutePath = path.resolve(process.cwd(), 'docs', resolvedPath);

  if (fs.existsSync(absolutePath)) {
    const docsDir = path.resolve(process.cwd(), 'docs');
    const repoDir = process.cwd();
    const isInsideDocs = absolutePath.startsWith(docsDir + path.sep);
    const isInsideRepo = absolutePath.startsWith(repoDir + path.sep);

    if (isInsideRepo) {
      const stats = fs.statSync(absolutePath);
      const filename = path.basename(absolutePath);
      const ext = path.extname(filename).toLowerCase();
      const allowedExtensions = [
        '.d',
        '.c',
        '.h',
        '.sdl',
        '.sh',
        '.json',
        '.toml',
        '.yaml',
        '.yml',
        '.build',
        '.txt',
        '.go',
        '.work',
      ];
      const isAllowedFile =
        allowedExtensions.includes(ext) ||
        filename === 'Makefile' ||
        filename === 'Cargo.toml';

      if (stats.isDirectory() || isAllowedFile) {
        if (isInsideDocs) {
          const relPath = path
            .relative(docsDir, absolutePath)
            .replace(/\\/g, '/');
          return `/${relPath}${stats.isDirectory() ? '/' : ''}${anchor ? '#' + anchor : ''}`.replace(
            /\/+/g,
            '/',
          );
        } else {
          const repoRelPath = path
            .relative(repoDir, absolutePath)
            .replace(/\\/g, '/');
          return `/${repoRelPath}${stats.isDirectory() ? '/' : ''}${anchor ? '#' + anchor : ''}`.replace(
            /\/+/g,
            '/',
          );
        }
      }
    }
  }

  return null;
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
    ],
    // Internal QA / agent-only docs — not published pages:
    // research grounding ledgers (claim-by-claim verification), packaging plan,
    // and the d-language-features agent protocol + its grounding tree.
    // Which pages the site does not build (internal QA evidence: the research
    // grounding ledgers and a couple of planning files). The list lives in
    // docs-config.json so the D tooling reads the same one — see the note above
    // the imports.
    srcExclude: docsConfig.srcExclude,

    markdown: {
      lineNumbers: true,
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
      config(md) {
        md.use(groupIconMdPlugin);
        md.core.ruler.push('rewrite-artifact-links', state => {
          const env = state.env;
          const relativePath = env.relativePath;
          if (!relativePath) return;

          function walk(tokens: any[]) {
            for (const token of tokens) {
              if (token.type === 'link_open') {
                const hrefAttr = token.attrs.find(
                  (attr: string[]) => attr[0] === 'href',
                );
                if (hrefAttr) {
                  const href = hrefAttr[1];
                  const newHref = rewriteLink(href, relativePath);
                  if (newHref) {
                    hrefAttr[1] = newHref;
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
    },

    themeConfig: {
      editLink: {
        pattern: 'https://github.com/PetarKirov/sparkles/edit/main/docs/:path',
        text: 'Edit this page on GitHub',
      },

      // Built-in local search (MiniSearch) — fully client-side, no third-party APIs.
      search: {
        provider: 'local',
      },

      nav: [
        { text: 'Docs', link: '/overview' },
        { text: 'API', link: '/api/' },
      ],

      sidebar: sidebar as DefaultTheme.Sidebar,

      socialLinks: [
        { icon: 'github', link: 'https://github.com/PetarKirov/sparkles' },
      ],
    },

    vite: {
      build: {
        chunkSizeWarningLimit: 2000,
        rollupOptions: {
          maxParallelFileOps: 4, // Limit parallel file operations to reduce peak memory usage
        },
      },
    },
  }),
);
