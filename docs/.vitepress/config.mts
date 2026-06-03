import { defineConfig } from 'vitepress';

export default defineConfig({
  title: 'Sparkles',
  description: 'D library for building CLI applications',
  base: '/',

  // Ignore links to .d source files referenced from docs
  ignoreDeadLinks: [/\.d$/],

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
          {
            text: 'Move Semantics & __rvalue',
            link: '/guidelines/move-semantics/',
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
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/PetarKirov/sparkles' },
    ],
  },
});
