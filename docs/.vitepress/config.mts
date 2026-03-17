import { defineConfig } from 'vitepress';

export default defineConfig({
  title: 'Sparkles',
  description: 'D library for building CLI applications',
  base: '/',

  // Ignore links to .d source files and to sample/ workspace directories
  // (source artifacts under research/monorepo-tooling/<tool>/sample/, not pages)
  ignoreDeadLinks: [/\.d$/, /\/sample\//, /\/sample$/, /\/example\//],

  markdown: {
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
    nav: [
      { text: 'Docs', link: '/overview' },
      { text: 'API', link: '/api/' },
    ],

    sidebar: [
      {
        text: 'Overview',
        collapsed: false,
        items: [{ text: 'core-cli Package', link: '/overview' }],
      },
      {
        text: 'Guidelines',
        collapsed: true,
        items: [
          {
            text: 'Agent Guidelines',
            link: '/guidelines/AGENTS',
          },
          {
            text: 'Functional & Declarative Programming',
            link: '/guidelines/functional-declarative-programming-guidelines',
          },
          {
            text: 'Design by Introspection',
            collapsed: true,
            items: [
              {
                text: 'Intro',
                link: '/guidelines/design-by-introspection-00-intro',
              },
              {
                text: 'Guidelines',
                link: '/guidelines/design-by-introspection-01-guidelines',
              },
            ],
          },
          {
            text: 'Interpolated Expression Sequences',
            link: '/guidelines/interpolated-expression-sequences',
          },
          { text: 'DDoc', link: '/guidelines/ddoc' },
          { text: 'Writing Research Docs', link: '/guidelines/research-docs' },
          {
            text: 'Integrating C Libraries (ImportC)',
            link: '/guidelines/importc-c-libraries',
          },
          {
            text: 'Move Semantics & __rvalue',
            link: '/guidelines/move-semantics/',
          },
          {
            text: 'Modern D Language Features',
            link: '/guidelines/d-language-features/',
          },
          {
            text: 'Code Style',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/guidelines/code-style' },
              { text: 'Appendix: Official DStyle', link: '/guidelines/dstyle' },
            ],
          },
          {
            text: 'Idioms',
            collapsed: true,
            items: [
              {
                text: 'Forcing Named Arguments',
                link: '/guidelines/idioms/forced-named-arguments/',
              },
              {
                text: 'Expected Error Handling',
                link: '/guidelines/idioms/expected/',
              },
            ],
          },
        ],
      },
      {
        text: 'Libraries',
        collapsed: false,
        items: [
          {
            text: 'versions',
            link: '/libs/versions/',
            collapsed: false,
            items: [
              {
                text: 'Tutorial',
                collapsed: false,
                items: [
                  {
                    text: 'Getting started',
                    link: '/libs/versions/tutorial/getting-started',
                  },
                ],
              },
              {
                text: 'How-to guides',
                collapsed: true,
                items: [
                  {
                    text: 'Compare and sort versions',
                    link: '/libs/versions/how-to/compare-and-sort',
                  },
                  {
                    text: 'Constrain with ranges',
                    link: '/libs/versions/how-to/constrain-with-ranges',
                  },
                  {
                    text: 'VERS and pURL interop',
                    link: '/libs/versions/how-to/vers-and-purl-interop',
                  },
                  {
                    text: 'Handle unknown schemes',
                    link: '/libs/versions/how-to/handle-unknown-schemes',
                  },
                  {
                    text: 'Add a new scheme',
                    link: '/libs/versions/how-to/add-a-new-scheme',
                  },
                ],
              },
              {
                text: 'Reference',
                collapsed: true,
                items: [
                  {
                    text: 'Concepts and API',
                    link: '/libs/versions/reference/concepts',
                  },
                  {
                    text: 'Scheme catalogue',
                    link: '/libs/versions/reference/schemes',
                  },
                  {
                    text: 'API index',
                    link: '/libs/versions/reference/api',
                  },
                ],
              },
              {
                text: 'Explanation',
                collapsed: true,
                items: [
                  {
                    text: 'The design',
                    link: '/libs/versions/explanation/design',
                  },
                  {
                    text: 'Prior art',
                    link: '/libs/versions/explanation/prior-art',
                  },
                  {
                    text: 'No cross-scheme order',
                    link: '/libs/versions/explanation/cross-scheme-policy',
                  },
                  {
                    text: 'Prerelease in ranges',
                    link: '/libs/versions/explanation/prerelease-in-range',
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        text: 'Specs',
        collapsed: true,
        items: [
          {
            text: 'Versions',
            collapsed: false,
            items: [
              { text: 'Specification', link: '/specs/versions/SPEC' },
              { text: 'Delivery Plan', link: '/specs/versions/PLAN' },
            ],
          },
        ],
      },
      {
        text: 'Research',
        collapsed: true,
        items: [
          {
            text: 'Sean Parent: Better Code',
            link: '/research/sean-parent/',
            collapsed: true,
            items: [
              {
                text: 'C++ Seasoning',
                link: '/research/sean-parent/cpp-seasoning',
              },
              {
                text: 'Local Reasoning',
                link: '/research/sean-parent/local-reasoning',
              },
              {
                text: 'Regular Types',
                link: '/research/sean-parent/regular-types',
              },
              {
                text: 'Value Semantics',
                link: '/research/sean-parent/value-semantics',
              },
              {
                text: 'Algorithms',
                link: '/research/sean-parent/algorithms',
              },
              {
                text: 'Concurrency',
                link: '/research/sean-parent/concurrency',
              },
              {
                text: 'Chains',
                link: '/research/sean-parent/chains-alternative-to-sender-receivers',
              },
              {
                text: 'Data Structures',
                link: '/research/sean-parent/data-structures',
              },
              {
                text: 'Relationships',
                link: '/research/sean-parent/relationships',
              },
              {
                text: 'Contracts',
                link: '/research/sean-parent/contracts',
              },
              {
                text: 'Safety',
                link: '/research/sean-parent/safety',
              },
              {
                text: 'Human Interface',
                link: '/research/sean-parent/human-interface',
              },
              {
                text: 'Generic Programming',
                link: '/research/sean-parent/generic-programming',
              },
            ],
          },
          {
            text: 'Algebraic Effects',
            link: '/research/algebraic-effects/',
            collapsed: true,
            items: [
              {
                text: 'Cross-Cutting',
                collapsed: true,
                items: [
                  {
                    text: 'Comparison',
                    link: '/research/algebraic-effects/comparison',
                  },
                  {
                    text: 'Evolution',
                    link: '/research/algebraic-effects/evolution',
                  },
                  {
                    text: 'Parallelism',
                    link: '/research/algebraic-effects/parallelism',
                  },
                  {
                    text: 'Papers',
                    link: '/research/algebraic-effects/papers',
                  },
                  {
                    text: 'Theory & Compilation',
                    link: '/research/algebraic-effects/theory-compilation',
                  },
                ],
              },
              {
                text: 'Effect-Native Languages',
                collapsed: true,
                items: [
                  {
                    text: 'Koka',
                    link: '/research/algebraic-effects/koka',
                  },
                  {
                    text: 'Eff',
                    link: '/research/algebraic-effects/eff-lang',
                  },
                  {
                    text: 'Frank',
                    link: '/research/algebraic-effects/frank',
                  },
                  {
                    text: 'Unison',
                    link: '/research/algebraic-effects/unison',
                  },
                ],
              },
              {
                text: 'Haskell',
                collapsed: true,
                items: [
                  {
                    text: 'effectful',
                    link: '/research/algebraic-effects/haskell-effectful',
                  },
                  {
                    text: 'polysemy',
                    link: '/research/algebraic-effects/haskell-polysemy',
                  },
                  {
                    text: 'fused-effects',
                    link: '/research/algebraic-effects/haskell-fused-effects',
                  },
                  {
                    text: 'cleff',
                    link: '/research/algebraic-effects/haskell-cleff',
                  },
                  {
                    text: 'bluefin',
                    link: '/research/algebraic-effects/haskell-bluefin',
                  },
                  {
                    text: 'freer-simple',
                    link: '/research/algebraic-effects/haskell-freer-simple',
                  },
                  {
                    text: 'mtl',
                    link: '/research/algebraic-effects/haskell-mtl',
                  },
                  {
                    text: 'eff',
                    link: '/research/algebraic-effects/haskell-eff',
                  },
                  {
                    text: 'theseus',
                    link: '/research/algebraic-effects/haskell-theseus',
                  },
                  {
                    text: 'heftia',
                    link: '/research/algebraic-effects/haskell-heftia',
                  },
                ],
              },
              {
                text: 'Scala',
                collapsed: true,
                items: [
                  {
                    text: 'ZIO',
                    link: '/research/algebraic-effects/scala-zio',
                  },
                  {
                    text: 'Cats Effect',
                    link: '/research/algebraic-effects/scala-cats-effect',
                  },
                  {
                    text: 'Kyo',
                    link: '/research/algebraic-effects/scala-kyo',
                  },
                  {
                    text: 'Ox',
                    link: '/research/algebraic-effects/scala-ox',
                  },
                  {
                    text: 'Scala 3 Capabilities',
                    link: '/research/algebraic-effects/scala-capabilities',
                  },
                  {
                    text: 'Turbolift',
                    link: '/research/algebraic-effects/scala-turbolift',
                  },
                ],
              },
              {
                text: 'OCaml',
                collapsed: true,
                items: [
                  {
                    text: 'OCaml 5 Effects',
                    link: '/research/algebraic-effects/ocaml-effects',
                  },
                  {
                    text: 'Eio',
                    link: '/research/algebraic-effects/ocaml-eio',
                  },
                ],
              },
              {
                text: 'Rust',
                collapsed: true,
                items: [
                  {
                    text: 'Implicit Effect System',
                    link: '/research/algebraic-effects/rust-effect-system',
                  },
                  {
                    text: 'effing-mad',
                    link: '/research/algebraic-effects/rust-effing-mad',
                  },
                  {
                    text: 'CPS Effects',
                    link: '/research/algebraic-effects/rust-cps-effects',
                  },
                ],
              },
              {
                text: 'Swift',
                collapsed: true,
                items: [
                  {
                    text: 'Swift Effects',
                    link: '/research/algebraic-effects/swift-effects',
                  },
                ],
              },
              {
                text: 'Industry Platforms',
                collapsed: true,
                items: [
                  {
                    text: 'Effect (TypeScript)',
                    link: '/research/algebraic-effects/typescript-effect',
                  },
                  {
                    text: 'Project Loom (Java)',
                    link: '/research/algebraic-effects/java-loom',
                  },
                  {
                    text: 'WasmFX',
                    link: '/research/algebraic-effects/wasmfx',
                  },
                ],
              },
              {
                text: 'Other Implementations',
                link: '/research/algebraic-effects/other-implementations',
              },
            ],
          },
          {
            text: 'Async I/O & Event Loops',
            link: '/research/async-io/',
            collapsed: true,
            items: [
              {
                text: 'Concepts',
                collapsed: true,
                items: [
                  {
                    text: 'Primitives',
                    link: '/research/async-io/primitives',
                  },
                  {
                    text: 'Implementation Techniques',
                    link: '/research/async-io/techniques',
                  },
                ],
              },
              {
                text: 'io_uring Reference',
                link: '/research/async-io/io-uring/',
                collapsed: true,
                items: [
                  {
                    text: 'Features by Area',
                    link: '/research/async-io/io-uring/features',
                  },
                  {
                    text: 'Timeline (v5.1–v7.1)',
                    link: '/research/async-io/io-uring/timeline',
                  },
                  {
                    text: 'Opcode & Flag Reference',
                    link: '/research/async-io/io-uring/opcodes-reference',
                  },
                ],
              },
              {
                text: 'Library Deep-Dives',
                collapsed: true,
                items: [
                  { text: 'Tokio (Rust)', link: '/research/async-io/tokio' },
                  {
                    text: 'Glommio (Rust)',
                    link: '/research/async-io/glommio',
                  },
                  { text: 'monoio (Rust)', link: '/research/async-io/monoio' },
                  {
                    text: 'Boost.Asio (C++)',
                    link: '/research/async-io/boost-asio',
                  },
                  { text: 'Seastar (C++)', link: '/research/async-io/seastar' },
                  { text: 'libuv (C)', link: '/research/async-io/libuv' },
                  { text: 'Zig std.Io', link: '/research/async-io/zig-io' },
                  { text: '.NET Runtime', link: '/research/async-io/dotnet' },
                  { text: 'Java', link: '/research/async-io/java' },
                  {
                    text: 'Go Netpoller',
                    link: '/research/async-io/go-netpoller',
                  },
                  {
                    text: 'Python (asyncio / Trio)',
                    link: '/research/async-io/python-async',
                  },
                  { text: 'Haskell', link: '/research/async-io/haskell' },
                  { text: 'Lean 4', link: '/research/async-io/lean' },
                  {
                    text: 'OCaml Eio Backend',
                    link: '/research/async-io/eio-backend',
                  },
                ],
              },
              {
                text: 'Synthesis',
                collapsed: true,
                items: [
                  {
                    text: 'Effects & Event Loops',
                    link: '/research/async-io/effects-and-event-loops',
                  },
                  {
                    text: 'D Landscape',
                    link: '/research/async-io/d-landscape',
                  },
                  {
                    text: 'Comparison & Recommendations',
                    link: '/research/async-io/comparison',
                  },
                ],
              },
            ],
          },
          {
            text: 'Coroutines (LDC)',
            link: '/research/coroutines/',
            collapsed: true,
            items: [
              {
                text: 'Stackless vs Stackful',
                link: '/research/coroutines/concepts',
              },
              {
                text: 'WebAssembly & WasmFX',
                link: '/research/coroutines/wasm-and-wasmfx',
              },
              {
                text: 'Stackless',
                link: '/research/coroutines/stackless/',
                collapsed: true,
                items: [
                  {
                    text: 'LLVM Model & Intrinsics',
                    link: '/research/coroutines/stackless/llvm-coroutines',
                  },
                  {
                    text: 'LLVM Pass Internals',
                    link: '/research/coroutines/stackless/llvm-coro-internals',
                  },
                  {
                    text: 'C++20 Coroutines',
                    link: '/research/coroutines/stackless/cpp-coroutines',
                  },
                  {
                    text: 'Cross-Language Comparison',
                    link: '/research/coroutines/stackless/comparison',
                  },
                  {
                    text: 'D Language Design',
                    link: '/research/coroutines/stackless/d-language-design',
                  },
                  {
                    text: 'LDC Code Generation',
                    link: '/research/coroutines/stackless/ldc-codegen',
                  },
                  {
                    text: 'Attributes & Memory',
                    link: '/research/coroutines/stackless/attributes-and-memory',
                  },
                  {
                    text: 'Implementation Roadmap',
                    link: '/research/coroutines/stackless/roadmap',
                  },
                ],
              },
              {
                text: 'Stackful',
                link: '/research/coroutines/stackful/',
                collapsed: true,
                items: [
                  {
                    text: 'D Fiber',
                    link: '/research/coroutines/stackful/d-fiber',
                  },
                  {
                    text: 'Context Switching',
                    link: '/research/coroutines/stackful/context-switching',
                  },
                  {
                    text: 'Green Threads & Scheduling',
                    link: '/research/coroutines/stackful/green-threads',
                  },
                  {
                    text: 'Stack Management',
                    link: '/research/coroutines/stackful/stack-management',
                  },
                  {
                    text: 'WasmFX as a Target',
                    link: '/research/coroutines/stackful/wasmfx-as-target',
                  },
                  {
                    text: 'Fiber → WasmFX Plan',
                    link: '/research/coroutines/stackful/fiber-to-wasmfx-plan',
                  },
                ],
              },
            ],
          },
          {
            text: 'Monorepo & Workspace Tooling',
            link: '/research/monorepo-tooling/',
            collapsed: true,
            items: [
              { text: 'Concepts', link: '/research/monorepo-tooling/concepts' },
              {
                text: 'JS/TS Package Managers',
                collapsed: true,
                items: [
                  { text: 'npm', link: '/research/monorepo-tooling/npm/' },
                  {
                    text: 'Yarn Berry',
                    link: '/research/monorepo-tooling/yarn-berry/',
                  },
                  { text: 'pnpm', link: '/research/monorepo-tooling/pnpm/' },
                  { text: 'Bun', link: '/research/monorepo-tooling/bun/' },
                ],
              },
              {
                text: 'Python Package Managers',
                collapsed: true,
                items: [
                  { text: 'uv', link: '/research/monorepo-tooling/uv/' },
                  {
                    text: 'Poetry',
                    link: '/research/monorepo-tooling/poetry/',
                  },
                  { text: 'Hatch', link: '/research/monorepo-tooling/hatch/' },
                ],
              },
              {
                text: 'Language Package Managers / Build Systems',
                collapsed: true,
                items: [
                  {
                    text: 'Cargo (Rust)',
                    link: '/research/monorepo-tooling/cargo/',
                  },
                  {
                    text: 'Go (go.work)',
                    link: '/research/monorepo-tooling/go-work/',
                  },
                  {
                    text: 'Gradle (JVM)',
                    link: '/research/monorepo-tooling/gradle/',
                  },
                  {
                    text: 'Maven (JVM)',
                    link: '/research/monorepo-tooling/maven/',
                  },
                  {
                    text: 'sbt (Scala)',
                    link: '/research/monorepo-tooling/sbt/',
                  },
                  {
                    text: 'Mill (Scala/JVM)',
                    link: '/research/monorepo-tooling/mill/',
                  },
                  {
                    text: 'Composer (PHP)',
                    link: '/research/monorepo-tooling/composer/',
                  },
                ],
              },
              {
                text: 'JS/TS Task Orchestrators',
                collapsed: true,
                items: [
                  { text: 'Nx', link: '/research/monorepo-tooling/nx/' },
                  {
                    text: 'Turborepo',
                    link: '/research/monorepo-tooling/turborepo/',
                  },
                  { text: 'Lerna', link: '/research/monorepo-tooling/lerna/' },
                  { text: 'Rush', link: '/research/monorepo-tooling/rush/' },
                  { text: 'Lage', link: '/research/monorepo-tooling/lage/' },
                  {
                    text: 'Wireit',
                    link: '/research/monorepo-tooling/wireit/',
                  },
                ],
              },
              {
                text: 'Polyglot Build Orchestrators',
                collapsed: true,
                items: [
                  { text: 'Bazel', link: '/research/monorepo-tooling/bazel/' },
                  { text: 'Buck2', link: '/research/monorepo-tooling/buck2/' },
                  { text: 'Pants', link: '/research/monorepo-tooling/pants/' },
                  {
                    text: 'Please',
                    link: '/research/monorepo-tooling/please/',
                  },
                  { text: 'moon', link: '/research/monorepo-tooling/moon/' },
                  {
                    text: 'GN + Ninja',
                    link: '/research/monorepo-tooling/gn/',
                  },
                ],
              },
              {
                text: 'Container / CI-Oriented',
                collapsed: true,
                items: [
                  {
                    text: 'Dagger',
                    link: '/research/monorepo-tooling/dagger/',
                  },
                  {
                    text: 'Earthly',
                    link: '/research/monorepo-tooling/earthly/',
                  },
                  {
                    text: 'Garden',
                    link: '/research/monorepo-tooling/garden/',
                  },
                ],
              },
              {
                text: 'Generic Task Runners',
                collapsed: true,
                items: [
                  {
                    text: 'Task (go-task)',
                    link: '/research/monorepo-tooling/task/',
                  },
                  { text: 'Just', link: '/research/monorepo-tooling/just/' },
                  { text: 'mise', link: '/research/monorepo-tooling/mise/' },
                  { text: 'Make', link: '/research/monorepo-tooling/make/' },
                ],
              },
              {
                text: 'Native Build Systems',
                collapsed: true,
                items: [
                  { text: 'Meson', link: '/research/monorepo-tooling/meson/' },
                  { text: 'CMake', link: '/research/monorepo-tooling/cmake/' },
                  { text: 'SCons', link: '/research/monorepo-tooling/scons/' },
                  { text: 'Waf', link: '/research/monorepo-tooling/waf/' },
                  { text: 'Ninja', link: '/research/monorepo-tooling/ninja/' },
                ],
              },
              {
                text: 'Remote Execution Backends',
                collapsed: true,
                items: [
                  {
                    text: 'BuildBuddy',
                    link: '/research/monorepo-tooling/buildbuddy/',
                  },
                  {
                    text: 'Buildbarn',
                    link: '/research/monorepo-tooling/buildbarn/',
                  },
                  {
                    text: 'NativeLink',
                    link: '/research/monorepo-tooling/nativelink/',
                  },
                ],
              },
              {
                text: 'Minimalist / Research',
                collapsed: true,
                items: [
                  { text: 'redo', link: '/research/monorepo-tooling/redo/' },
                  { text: 'tup', link: '/research/monorepo-tooling/tup/' },
                ],
              },
              {
                text: 'Polyglot Glue',
                collapsed: true,
                items: [
                  {
                    text: 'Nix (flakes)',
                    link: '/research/monorepo-tooling/nix-flakes/',
                  },
                ],
              },
              {
                text: 'Synthesis',
                collapsed: true,
                items: [
                  {
                    text: 'dub Baseline',
                    link: '/research/monorepo-tooling/dub-baseline',
                  },
                  {
                    text: 'Comparison & Recommendations',
                    link: '/research/monorepo-tooling/comparison',
                  },
                  {
                    text: 'dub Workspace Proposal',
                    link: '/research/monorepo-tooling/dub-proposal',
                  },
                ],
              },
            ],
          },
          {
            text: 'TUI Libraries',
            collapsed: true,
            items: [
              { text: 'Catalog', link: '/research/tui-libraries/' },
              {
                text: 'Ratatui (Rust)',
                link: '/research/tui-libraries/ratatui',
              },
              {
                text: 'Ink (JavaScript)',
                link: '/research/tui-libraries/ink',
              },
              {
                text: 'Textual (Python)',
                link: '/research/tui-libraries/textual',
              },
              {
                text: 'Bubble Tea (Go)',
                link: '/research/tui-libraries/bubbletea',
              },
              {
                text: 'Brick (Haskell)',
                link: '/research/tui-libraries/brick',
              },
              {
                text: 'Notcurses (C)',
                link: '/research/tui-libraries/notcurses',
              },
              {
                text: 'FTXUI (C++)',
                link: '/research/tui-libraries/ftxui',
              },
              {
                text: 'Cursive (Rust)',
                link: '/research/tui-libraries/cursive',
              },
              {
                text: 'Mosaic (Kotlin)',
                link: '/research/tui-libraries/mosaic',
              },
              {
                text: 'Nottui (OCaml)',
                link: '/research/tui-libraries/nottui',
              },
              {
                text: 'libvaxis (Zig)',
                link: '/research/tui-libraries/libvaxis',
              },
              {
                text: 'tview (Go)',
                link: '/research/tui-libraries/tview',
              },
              {
                text: 'ImTui (C++)',
                link: '/research/tui-libraries/imtui',
              },
              {
                text: 'Snacks.nvim (Lua)',
                link: '/research/tui-libraries/snacks-nvim',
              },
              {
                text: 'broot (Rust)',
                link: '/research/tui-libraries/broot',
              },
              {
                text: 'Comparison',
                link: '/research/tui-libraries/comparison',
              },
              {
                text: 'Tree-View Case Study',
                link: '/research/tui-libraries/tree-view-case-study',
              },
            ],
          },
          {
            text: 'UI Layout',
            collapsed: true,
            items: [
              { text: 'Catalog', link: '/research/ui-layout/' },
              {
                text: 'Constraint Systems',
                collapsed: false,
                items: [
                  {
                    text: 'Android ConstraintLayout',
                    link: '/research/ui-layout/android-constraintlayout',
                  },
                  {
                    text: 'Auto Layout (Apple)',
                    link: '/research/ui-layout/auto-layout',
                  },
                ],
              },
              {
                text: 'CSS Layout Specs',
                collapsed: false,
                items: [
                  {
                    text: 'CSS Flexbox',
                    link: '/research/ui-layout/css-flexbox',
                  },
                  {
                    text: 'CSS Grid',
                    link: '/research/ui-layout/css-grid',
                  },
                  {
                    text: 'CSS Normal Flow',
                    link: '/research/ui-layout/css-normal-flow',
                  },
                ],
              },
              {
                text: 'Declarative App Frameworks',
                collapsed: false,
                items: [
                  {
                    text: 'Flutter (Dart)',
                    link: '/research/ui-layout/flutter',
                  },
                  {
                    text: 'Jetpack Compose (Kotlin)',
                    link: '/research/ui-layout/jetpack-compose',
                  },
                  {
                    text: 'SwiftUI (Swift)',
                    link: '/research/ui-layout/swiftui',
                  },
                ],
              },
              {
                text: 'Desktop GUI Toolkits',
                collapsed: false,
                items: [
                  {
                    text: 'GTK 4 (C)',
                    link: '/research/ui-layout/gtk',
                  },
                  {
                    text: 'Qt Layouts (C++)',
                    link: '/research/ui-layout/qt-layouts',
                  },
                  {
                    text: 'Swing / MiG Layout (Java)',
                    link: '/research/ui-layout/swing-mig',
                  },
                  {
                    text: 'Tk Geometry Managers',
                    link: '/research/ui-layout/tk',
                  },
                  {
                    text: 'WPF / XAML (.NET)',
                    link: '/research/ui-layout/wpf-xaml',
                  },
                ],
              },
              {
                text: 'Foundational Algorithms',
                collapsed: false,
                items: [
                  {
                    text: 'Cassowary (algorithm)',
                    link: '/research/ui-layout/cassowary',
                  },
                  {
                    text: 'TeX / Knuth-Plass',
                    link: '/research/ui-layout/tex-knuth-plass',
                  },
                ],
              },
              {
                text: 'Immediate-Mode Layout',
                collapsed: false,
                items: [
                  {
                    text: 'Dear ImGui (C++)',
                    link: '/research/ui-layout/dear-imgui',
                  },
                  {
                    text: 'egui (Rust)',
                    link: '/research/ui-layout/egui',
                  },
                ],
              },
              {
                text: 'Renderer-Agnostic Libraries',
                collapsed: false,
                items: [
                  {
                    text: 'Clay (C)',
                    link: '/research/ui-layout/clay',
                  },
                  {
                    text: 'Kiwi (C++ / Python)',
                    link: '/research/ui-layout/kiwi',
                  },
                  {
                    text: 'Stretch (Rust)',
                    link: '/research/ui-layout/stretch',
                  },
                  {
                    text: 'Taffy (Rust)',
                    link: '/research/ui-layout/taffy',
                  },
                  {
                    text: 'Yoga (C++)',
                    link: '/research/ui-layout/yoga',
                  },
                ],
              },
              {
                text: 'Tiling / Structural Layout',
                collapsed: false,
                items: [
                  {
                    text: 'i3 / sway',
                    link: '/research/ui-layout/i3-sway',
                  },
                  {
                    text: 'xmonad (Haskell)',
                    link: '/research/ui-layout/xmonad',
                  },
                ],
              },
            ],
          },
          {
            text: 'Window System Integration',
            link: '/research/window-system-integration/',
            collapsed: true,
            items: [
              {
                text: 'Concepts',
                link: '/research/window-system-integration/concepts',
              },
              {
                text: 'Library Deep-Dives',
                collapsed: true,
                items: [
                  {
                    text: 'Tier 1 — Windowing Libraries',
                    collapsed: true,
                    items: [
                      {
                        text: 'winit (Rust)',
                        link: '/research/window-system-integration/winit',
                      },
                      {
                        text: 'SDL3 (C)',
                        link: '/research/window-system-integration/sdl3',
                      },
                      {
                        text: 'GLFW (C)',
                        link: '/research/window-system-integration/glfw',
                      },
                      {
                        text: 'sokol_app.h (C)',
                        link: '/research/window-system-integration/sokol',
                      },
                    ],
                  },
                  {
                    text: 'Tier 2 — Framework Platform Layers',
                    collapsed: true,
                    items: [
                      {
                        text: 'Qt 6 / QPA (C++)',
                        link: '/research/window-system-integration/qt6',
                      },
                      {
                        text: 'GTK4 / GDK (C)',
                        link: '/research/window-system-integration/gtk4',
                      },
                      {
                        text: 'Flutter Engine (C++)',
                        link: '/research/window-system-integration/flutter-engine',
                      },
                      {
                        text: 'Chromium Ozone (C++)',
                        link: '/research/window-system-integration/chromium-ozone',
                      },
                    ],
                  },
                  {
                    text: 'Tier 3 — Additional Perspectives',
                    collapsed: true,
                    items: [
                      {
                        text: 'Avalonia (.NET)',
                        link: '/research/window-system-integration/avalonia',
                      },
                      {
                        text: '.NET MAUI',
                        link: '/research/window-system-integration/dotnet-maui',
                      },
                      {
                        text: 'Uno Platform (.NET)',
                        link: '/research/window-system-integration/uno-platform',
                      },
                      {
                        text: 'Slint (Rust)',
                        link: '/research/window-system-integration/slint',
                      },
                      {
                        text: 'wxWidgets (C++)',
                        link: '/research/window-system-integration/wxwidgets',
                      },
                      {
                        text: 'JUCE (C++)',
                        link: '/research/window-system-integration/juce',
                      },
                      {
                        text: 'Smithay + libdecor',
                        link: '/research/window-system-integration/smithay-libdecor',
                      },
                    ],
                  },
                ],
              },
              {
                text: 'OS Windowing APIs',
                link: '/research/window-system-integration/os-apis/',
                collapsed: true,
                items: [
                  {
                    text: 'Overview',
                    link: '/research/window-system-integration/os-apis/',
                  },
                  {
                    text: 'Wayland',
                    link: '/research/window-system-integration/os-apis/wayland/',
                  },
                  {
                    text: 'X11 / Xlib',
                    link: '/research/window-system-integration/os-apis/x11/',
                  },
                  {
                    text: 'Windows (Win32)',
                    link: '/research/window-system-integration/os-apis/win32/',
                  },
                  {
                    text: 'macOS (AppKit)',
                    link: '/research/window-system-integration/os-apis/appkit/',
                  },
                  {
                    text: 'iOS / iPadOS (UIKit)',
                    link: '/research/window-system-integration/os-apis/uikit/',
                  },
                  {
                    text: 'Android (NDK)',
                    link: '/research/window-system-integration/os-apis/android/',
                  },
                  {
                    text: 'Cross-Platform Summary',
                    link: '/research/window-system-integration/os-apis/summary',
                  },
                ],
              },
              {
                text: 'Synthesis',
                collapsed: true,
                items: [
                  {
                    text: 'Comparison',
                    link: '/research/window-system-integration/comparison',
                  },
                  {
                    text: 'Recommendations',
                    link: '/research/window-system-integration/recommendations',
                  },
                  {
                    text: 'Platform Gotchas',
                    link: '/research/window-system-integration/platform-gotchas',
                  },
                ],
              },
            ],
          },
          {
            text: 'Vulkan Bindings',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/research/vulkan/' },
              {
                text: 'Rust (vulkano)',
                link: '/research/vulkan/rust-vulkano',
              },
              {
                text: 'Haskell (vulkan)',
                link: '/research/vulkan/haskell-vulkan',
              },
              {
                text: 'C++ (Vulkan-Hpp)',
                link: '/research/vulkan/cpp-vulkan-hpp',
              },
              {
                text: 'OCaml (Olivine)',
                link: '/research/vulkan/ocaml-olivine',
              },
            ],
          },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/PetarKirov/sparkles' },
    ],
  },
});
