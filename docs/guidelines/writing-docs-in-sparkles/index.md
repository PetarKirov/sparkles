---
name: writing-docs
description: 'Write, edit, or add documentation pages to the VitePress docs site. Use when creating or modifying files under docs/, updating the sidebar, or adding research/guideline articles.'
---

# Writing Documentation

Guidelines for writing, organizing, and validating documentation in the Sparkles project.

## Quick Checklist

Every docs change must satisfy **all** of these before committing:

1. New page added to sidebar in `docs/.vitepress/config.mts` — see [VitePress][]
2. All links are **reference-style** — see [Markdown Style][]
3. `lychee` link check passes — see [Lychee][]
4. `prettier` formatting passes — see [Markdown Style][]
5. If the page contains runnable D code examples, `verify-md-examples` passes — see [Sparkles MD Tooling][]
6. Cross-references to/from related pages are added (index pages, sibling docs)
7. Link to relevant **upstream documentation** where possible (e.g., VitePress feature docs, lychee config reference, language specs)

---

## Directory Structure

### Top-Level Layout

```
docs/
├── .vitepress/
│   ├── config.mts          # Sidebar + nav config
│   └── theme/              # Theme overrides
├── guidelines/             # Style guides and idioms
│   ├── idioms/             # Complex patterns, each in its own directory
│   │   └── <idiom-name>/
│   │       ├── index.md    # Main article
│   │       └── *.d         # Companion source files
│   └── *.md                # Standalone guideline pages
├── research/               # Research surveys
│   └── <topic>/
│       ├── index.md        # Survey hub / catalog
│       └── <project>.md    # Per-project deep dives (kebab-case)
├── specs/                  # Specifications (if present)
│   └── <project>/
│       ├── index.md        # Spec overview
│       ├── SPEC.md         # Main spec
│       └── TESTING.md      # Testing strategy
├── index.md                # Site home
└── overview.md             # Package overview
```

### When to Use a Directory vs. a Single File

- **Single file** — short, self-contained guideline page (e.g., `ddoc.md`)
- **Directory with `index.md`** — article that needs companion files (D source, images, data) or has sub-pages. The `index.md` is the main entry point; auxiliary files sit alongside it.

### Naming

- Use **kebab-case** for file and directory names (`forced-named-arguments/`, `haskell-effectful.md`)
- Research deep-dives: `<language>-<project>.md` (e.g., `rust-vulkano.md`, `scala-zio.md`)
- Index pages are always `index.md`

---

## Workflow Summary

1. **Create the file** in the appropriate `docs/` subdirectory
2. **Write content** using the matching [article template][Markdown Style]
3. **Use reference-style links** throughout; place definitions at EOF
4. **Cross-link** from relevant index pages and sibling docs
5. **Add to sidebar** in `docs/.vitepress/config.mts` — see [VitePress][]
6. **Run pre-commit hooks** to validate formatting, links, and examples — see [Sparkles MD Tooling][]
7. **Commit** with a `docs(<scope>): ...` message — see [Conventions][]

---

## Topic Guides

- [Markdown Style][] — reference-style links, formatting rules, article structure templates
- [VitePress][] — sidebar configuration, code groups, collapsible sections, theme
- [Lychee][] — link checking configuration, exclusions, fixing broken links
- [Sparkles MD Tooling][] — `run_md_examples`, D code blocks, pre-commit hooks
- [Conventions][] — conventional commits, symlinks for library ergonomics

[Markdown Style]: markdown-style.md
[VitePress]: vitepress.md
[Lychee]: lychee.md
[Sparkles MD Tooling]: sparkles-md-tooling.md
[Conventions]: conventions.md
