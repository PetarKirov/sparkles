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
    ],

    socialLinks: [
      { icon: "github", link: "https://github.com/PetarKirov/sparkles" },
    ],
  },
});
