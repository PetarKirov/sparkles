# VitePress

This project uses [VitePress][] to generate the documentation site. See the [VitePress Markdown Extensions guide][vp-markdown] for the full feature set.

## Sidebar Configuration

Every new page **must** be added to the [sidebar][vp-sidebar] in `docs/.vitepress/config.mts`.

### Structure

```typescript
sidebar: [
  {
    text: 'Section Name',
    collapsed: true, // collapsed by default for large sections
    items: [
      { text: 'Page Title', link: '/path/to/page' },
      {
        text: 'Subsection',
        collapsed: true,
        items: [{ text: 'Child Page', link: '/path/to/child' }],
      },
    ],
  },
];
```

### Rules

- Links omit the `.md` extension
- For `index.md` pages, link to the directory with a trailing slash: `'/guidelines/idioms/forced-named-arguments/'`
- Keep sidebar ordering consistent with the logical reading order
- Use `collapsed: true` for sections with many items
- Match the `text` value to the page's H1 title (or a short form of it)

---

## Frontmatter

VitePress supports [YAML frontmatter][vp-frontmatter] at the top of every Markdown file. Custom keys are silently ignored and accessible via `$frontmatter`. Built-in keys like `title` and `description` set the page's `<meta>` tags. See the [Frontmatter Config Reference][vp-frontmatter-config] for all available options.

---

## Code Groups

Use [`::: code-group`][vp-code-groups] to show related code side-by-side in tabs:

````markdown
::: code-group

```d [definition]
// definition code
```

```d [usage]
// usage code
```

:::
````

---

## Custom Containers

VitePress provides [custom containers][vp-containers] for callouts:

```markdown
::: info
Informational note.
:::

::: tip
Helpful tip.
:::

::: warning
Warning message.
:::

::: danger
Critical warning.
:::
```

[GitHub-flavored alerts][vp-github-alerts] (`> [!NOTE]`, `> [!TIP]`, etc.) are also supported and render identically.

---

## Collapsible Sections

Use `<details>` for secondary information:

```markdown
<details>
<summary>Alternative approach (click to expand)</summary>

Content here.

</details>
```

---

## Syntax Highlighting

Code blocks are highlighted by [Shiki][vp-syntax]. Additional features:

- [Line highlighting][vp-line-highlight]: ` ```d {2,4-6} ` or `// [!code highlight]`
- [Line numbers][vp-line-numbers]: ` ```d:line-numbers `
- [Code snippets from files][vp-code-import]: `<<< @/path/to/file.d`

---

## Markdown File Inclusion

Include another Markdown file's content with [file inclusion][vp-include]:

```markdown
<!--@include: ./parts/section.md-->
```

Supports line ranges (`{3,}`, `{,10}`, `{1,10}`) and VS Code region markers.

---

## Dead Link Exceptions

The VitePress config ignores links to `.d` source files (see [ignoreDeadLinks][vp-dead-links]):

```typescript
ignoreDeadLinks: [/\.d$/];
```

This allows referencing companion D source files from within articles without generating build errors.

---

## Theme

Theme customizations live in `docs/.vitepress/theme/` (see [Extending the Default Theme][vp-theme]):

- `index.mts` — entry point; imports base theme and custom CSS
- `custom.css` — sidebar styling, typography, color overrides
- `Layout.vue` — layout component overrides

When adding custom fonts, import from `vitepress/theme-without-fonts` to avoid bundling the default Inter font twice.

[VitePress]: https://vitepress.dev/
[vp-markdown]: https://vitepress.dev/guide/markdown
[vp-sidebar]: https://vitepress.dev/reference/default-theme-sidebar
[vp-frontmatter]: https://vitepress.dev/guide/frontmatter
[vp-frontmatter-config]: https://vitepress.dev/reference/frontmatter-config
[vp-code-groups]: https://vitepress.dev/guide/markdown#code-groups
[vp-containers]: https://vitepress.dev/guide/markdown#custom-containers
[vp-github-alerts]: https://vitepress.dev/guide/markdown#github-flavored-alerts
[vp-syntax]: https://vitepress.dev/guide/markdown#syntax-highlighting-in-code-blocks
[vp-line-highlight]: https://vitepress.dev/guide/markdown#line-highlighting-in-code-blocks
[vp-line-numbers]: https://vitepress.dev/guide/markdown#line-numbers
[vp-code-import]: https://vitepress.dev/guide/markdown#import-code-snippets
[vp-include]: https://vitepress.dev/guide/markdown#markdown-file-inclusion
[vp-dead-links]: https://vitepress.dev/reference/site-config#ignoredeadlinks
[vp-theme]: https://vitepress.dev/guide/extending-default-theme
