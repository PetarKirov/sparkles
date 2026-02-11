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
        items: [{ text: "core-cli Package", link: "/overview" }],
      },
      {
        text: "Guidelines",
        items: [
          {
            text: "Functional & Declarative Programming",
            link: "/guidelines/functional-declarative-programming-guidelines",
          },
          {
            text: "Design by Introspection",
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
            items: [
              { text: "Overview", link: "/guidelines/code-style" },
              { text: "Appendix: Official DStyle", link: "/guidelines/dstyle" },
            ],
          },
        ],
      },
      {
        text: "Research",
        items: [
          {
            text: "Sean Parent: Better Code",
            link: "/research/sean-parent/",
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
        ],
      },
    ],

    socialLinks: [
      { icon: "github", link: "https://github.com/PetarKirov/sparkles" },
    ],
  },
});
