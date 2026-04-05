# VitePress

## Sidebar Configuration

Every new page **must** be added to the sidebar in `docs/.vitepress/config.mts`.

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

## Code Groups

Use `::: code-group` to show related code side-by-side in tabs:

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

## Collapsible Sections

Use `<details>` for secondary information:

```markdown
<details>
<summary>Alternative approach (click to expand)</summary>

Content here.

</details>
```

---

## Dead Link Exceptions

The VitePress config ignores links to `.d` source files:

```typescript
ignoreDeadLinks: [/\.d$/];
```

This allows referencing companion D source files from within articles without generating build errors.

---

## Theme

Theme customizations live in `docs/.vitepress/theme/`:

- `index.mts` — entry point; imports base theme and custom CSS
- `custom.css` — sidebar styling, typography, color overrides
- `Layout.vue` — layout component overrides

When adding custom fonts, import from `vitepress/theme-without-fonts` to avoid bundling the default Inter font twice.
