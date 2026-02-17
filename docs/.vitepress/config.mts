import { defineConfig } from "vitepress";

export default defineConfig({
  title: "Sparkles",
  description: "D library for building CLI applications",
  base: "/",

  // Ignore links to .d source files referenced from docs
  ignoreDeadLinks: [/\.d$/],

  themeConfig: {
    nav: [
      { text: "Docs", link: "/overview" },
      { text: "API", link: "/api/" },
    ],

    sidebar: [
      {
        text: "Overview",
        collapsed: false,
        items: [{ text: "core-cli Package", link: "/overview" }],
      },
      {
        text: "Guidelines",
        collapsed: true,
        items: [
          {
            text: "Functional & Declarative Programming",
            link: "/guidelines/functional-declarative-programming-guidelines",
          },
          {
            text: "Design by Introspection",
            collapsed: true,
            items: [
              {
                text: "Intro",
                link: "/guidelines/design-by-introspection-00-intro",
              },
              {
                text: "Guidelines",
                link: "/guidelines/design-by-introspection-01-guidelines",
              },
            ],
          },
          {
            text: "Interpolated Expression Sequences",
            link: "/guidelines/interpolated-expression-sequences",
          },
          { text: "DDoc", link: "/guidelines/ddoc" },
          {
            text: "Code Style",
            collapsed: true,
            items: [
              { text: "Overview", link: "/guidelines/code-style" },
              { text: "Appendix: Official DStyle", link: "/guidelines/dstyle" },
            ],
          },
        ],
      },
      {
        text: "Research",
        collapsed: true,
        items: [
          {
            text: "Sean Parent: Better Code",
            link: "/research/sean-parent/",
            collapsed: true,
            items: [
              {
                text: "C++ Seasoning",
                link: "/research/sean-parent/cpp-seasoning",
              },
              {
                text: "Local Reasoning",
                link: "/research/sean-parent/local-reasoning",
              },
              {
                text: "Regular Types",
                link: "/research/sean-parent/regular-types",
              },
              {
                text: "Value Semantics",
                link: "/research/sean-parent/value-semantics",
              },
              {
                text: "Algorithms",
                link: "/research/sean-parent/algorithms",
              },
              {
                text: "Concurrency",
                link: "/research/sean-parent/concurrency",
              },
              {
                text: "Chains",
                link: "/research/sean-parent/chains-alternative-to-sender-receivers",
              },
              {
                text: "Data Structures",
                link: "/research/sean-parent/data-structures",
              },
              {
                text: "Relationships",
                link: "/research/sean-parent/relationships",
              },
              {
                text: "Contracts",
                link: "/research/sean-parent/contracts",
              },
              {
                text: "Safety",
                link: "/research/sean-parent/safety",
              },
              {
                text: "Human Interface",
                link: "/research/sean-parent/human-interface",
              },
              {
                text: "Generic Programming",
                link: "/research/sean-parent/generic-programming",
              },
            ],
          },
          {
            text: "Algebraic Effects",
            link: "/research/algebraic-effects/",
            collapsed: true,
            items: [
              {
                text: "Cross-Cutting",
                collapsed: true,
                items: [
                  {
                    text: "Comparison",
                    link: "/research/algebraic-effects/comparison",
                  },
                  {
                    text: "Papers",
                    link: "/research/algebraic-effects/papers",
                  },
                  {
                    text: "Theory & Compilation",
                    link: "/research/algebraic-effects/theory-compilation",
                  },
                ],
              },
              {
                text: "Effect-Native Languages",
                collapsed: true,
                items: [
                  {
                    text: "Koka",
                    link: "/research/algebraic-effects/koka",
                  },
                  {
                    text: "Eff",
                    link: "/research/algebraic-effects/eff-lang",
                  },
                  {
                    text: "Frank",
                    link: "/research/algebraic-effects/frank",
                  },
                  {
                    text: "Unison",
                    link: "/research/algebraic-effects/unison",
                  },
                ],
              },
              {
                text: "Haskell",
                collapsed: true,
                items: [
                  {
                    text: "effectful",
                    link: "/research/algebraic-effects/haskell-effectful",
                  },
                  {
                    text: "polysemy",
                    link: "/research/algebraic-effects/haskell-polysemy",
                  },
                  {
                    text: "fused-effects",
                    link: "/research/algebraic-effects/haskell-fused-effects",
                  },
                  {
                    text: "cleff",
                    link: "/research/algebraic-effects/haskell-cleff",
                  },
                  {
                    text: "bluefin",
                    link: "/research/algebraic-effects/haskell-bluefin",
                  },
                  {
                    text: "freer-simple",
                    link: "/research/algebraic-effects/haskell-freer-simple",
                  },
                  {
                    text: "mtl",
                    link: "/research/algebraic-effects/haskell-mtl",
                  },
                ],
              },
              {
                text: "Scala",
                collapsed: true,
                items: [
                  {
                    text: "ZIO",
                    link: "/research/algebraic-effects/scala-zio",
                  },
                  {
                    text: "Cats Effect",
                    link: "/research/algebraic-effects/scala-cats-effect",
                  },
                  {
                    text: "Kyo",
                    link: "/research/algebraic-effects/scala-kyo",
                  },
                  {
                    text: "Scala 3 Capabilities",
                    link: "/research/algebraic-effects/scala-capabilities",
                  },
                  {
                    text: "Turbolift",
                    link: "/research/algebraic-effects/scala-turbolift",
                  },
                ],
              },
              {
                text: "OCaml",
                collapsed: true,
                items: [
                  {
                    text: "OCaml 5 Effects",
                    link: "/research/algebraic-effects/ocaml-effects",
                  },
                  {
                    text: "Eio",
                    link: "/research/algebraic-effects/ocaml-eio",
                  },
                ],
              },
              {
                text: "Rust",
                collapsed: true,
                items: [
                  {
                    text: "Implicit Effect System",
                    link: "/research/algebraic-effects/rust-effect-system",
                  },
                  {
                    text: "effing-mad",
                    link: "/research/algebraic-effects/rust-effing-mad",
                  },
                  {
                    text: "CPS Effects",
                    link: "/research/algebraic-effects/rust-cps-effects",
                  },
                ],
              },
              {
                text: "Industry Platforms",
                collapsed: true,
                items: [
                  {
                    text: "Effect (TypeScript)",
                    link: "/research/algebraic-effects/typescript-effect",
                  },
                  {
                    text: "Project Loom (Java)",
                    link: "/research/algebraic-effects/java-loom",
                  },
                  {
                    text: "WasmFX",
                    link: "/research/algebraic-effects/wasmfx",
                  },
                ],
              },
            ],
          },
          {
            text: "TUI Libraries",
            collapsed: true,
            items: [
              { text: "Catalog", link: "/research/tui-libraries/" },
              {
                text: "Ratatui (Rust)",
                link: "/research/tui-libraries/ratatui",
              },
              {
                text: "Ink (JavaScript)",
                link: "/research/tui-libraries/ink",
              },
              {
                text: "Textual (Python)",
                link: "/research/tui-libraries/textual",
              },
              {
                text: "Bubble Tea (Go)",
                link: "/research/tui-libraries/bubbletea",
              },
              {
                text: "Brick (Haskell)",
                link: "/research/tui-libraries/brick",
              },
              {
                text: "Notcurses (C)",
                link: "/research/tui-libraries/notcurses",
              },
              {
                text: "FTXUI (C++)",
                link: "/research/tui-libraries/ftxui",
              },
              {
                text: "Cursive (Rust)",
                link: "/research/tui-libraries/cursive",
              },
              {
                text: "Mosaic (Kotlin)",
                link: "/research/tui-libraries/mosaic",
              },
              {
                text: "Nottui (OCaml)",
                link: "/research/tui-libraries/nottui",
              },
              {
                text: "libvaxis (Zig)",
                link: "/research/tui-libraries/libvaxis",
              },
              {
                text: "tview (Go)",
                link: "/research/tui-libraries/tview",
              },
              {
                text: "ImTui (C++)",
                link: "/research/tui-libraries/imtui",
              },
              {
                text: "Comparison",
                link: "/research/tui-libraries/comparison",
              },
            ],
          },
        ],
      },
    ],

    socialLinks: [
      { icon: "github", link: "https://github.com/PetarKirov/sparkles" },
    ],
  },
});
