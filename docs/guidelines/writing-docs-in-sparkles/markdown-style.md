# Markdown Style

## Link Style: Reference-Style Links Only

**Never use inline links.** Always use [reference-style links][md-ref-links] with definitions at the bottom of the file.

### ✅ Correct

```markdown
See the [effectful][] library for a ReaderT IO approach.

The [Koka][] language uses row-polymorphic effects.

[effectful]: haskell-effectful.md
[Koka]: koka.md
```

### ❌ Wrong

```markdown
See the [effectful](haskell-effectful.md) library.
```

### Rules

- Place all reference definitions at the **end of the file**, grouped logically
- Use relative paths for internal links (`./sibling.md`, `../parent/page.md`)
- Use the document's natural title as the reference label when possible
- The `fix-markdown-reference-links` pre-commit hook will auto-convert inline links, but write reference-style from the start to avoid noisy diffs

---

## Formatting Rules

- [Prettier][] enforces markdown formatting — do not fight it
- [EditorConfig][]: Markdown uses `indent_size = unset` (code blocks may have intentional spacing)
- Line endings: LF only (`end_of_line = lf`)
- Files must end with a newline
- Use GFM-style tables for comparisons and metadata

---

## Article Structure Templates

### Guideline / Idiom Article

```markdown
# Title

## Problem

Describe the limitation or issue.

## Solution

Describe the pattern/idiom with code examples.

## Guidelines

Rules for when and how to apply the pattern.

## ABI Impact / Technical Analysis

(If applicable) Detailed performance or low-level implications.

## Alternative Techniques Considered

| Technique | Result | Why It Fails |
| --------- | ------ | ------------ |
| ...       | ...    | ...          |
```

### Research Survey Index (`index.md`)

```markdown
# Topic Name

A one-line summary of the research scope.

**Last reviewed:** Month Day, Year.

---

## Scope

What this survey covers and doesn't cover.

## State of the Art

| Axis | Current Frontier |
| ---- | ---------------- |
| ...  | ...              |

## Surveyed Projects

1. [Project A][] — one-line summary
2. [Project B][] — one-line summary

## Comparative Snapshot

| Feature | Project A | Project B |
| ------- | --------- | --------- |
| ...     | ...       | ...       |

## Synthesis / Takeaways

Aggregated findings and actionable design patterns.

[Project A]: project-a.md
[Project B]: project-b.md
```

### Research Deep-Dive Page

```markdown
# Language: Project Name

## Overview

High-level summary: what it solves, design philosophy.

| Field         | Value |
| ------------- | ----- |
| Language      | ...   |
| License       | ...   |
| Repository    | ...   |
| Documentation | ...   |

## Core Mechanism

Technical details with code snippets.

## Strengths

- ...

## Limitations

- ...

## D Takeaways

What lessons apply to this project's D codebase.

## Sources

- [Source 1][]
- [Source 1][]

[Source 1]: https://...
```

[md-ref-links]: https://www.markdownguide.org/basic-syntax/#reference-style-links
[Prettier]: https://prettier.io/docs/en/
[EditorConfig]: https://editorconfig.org/
