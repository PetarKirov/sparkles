# Writing Research Docs

How to write a research catalog under `docs/research/<topic>/` that matches the
existing corpus. The reference implementations are
[`docs/research/async-io/`](../research/async-io/index.md) and
[`docs/research/monorepo-tooling/`](../research/monorepo-tooling/index.md) — between
them they show every shape a tree takes: a breadth-first `.md` per subject, a subject
deepened into its own directory with companion files (async-io's
[`io-uring/`](../research/async-io/io-uring/index.md) and its `examples/` of runnable
programs), and a topic that is per-subject-subdirectory throughout (monorepo-tooling,
for its co-located samples). When in doubt, open one and imitate it — a new tree
should be stylistically indistinguishable.

> [!NOTE]
> This guide is about the **shape and conventions** of research docs, not their
> content. It complements [DDoc](./ddoc.md) (for in-source docs) and the
> [Code Style](./code-style.md) guide (for code). For where each kind of doc
> lives, see [AGENTS § Where docs live](./AGENTS.md#where-docs-live).

> [!IMPORTANT]
> Research here is **grounded twice over**: every claim is tied to a primary source (a
> cited file path or URL, usually with a verbatim quote), and wherever a behaviour can
> be _demonstrated_ it is backed by a **runnable example that CI compiles and runs**.
> Prose drifts; a CI-tested example cannot — if the API or behaviour a deep-dive
> describes stops working, the build goes red. Lean on runnable, CI-verified examples
> heavily (see [Runnable samples and examples](#co-located-runnable-samples-and-examples)).

---

## When to use `docs/research/`

`docs/research/` holds **background surveys that inform a design** — breadth-first
maps of how other languages/libraries/tools solve a problem Sparkles is about to
tackle. A research tree is the evidence base; the design decision it feeds usually
lands later in `docs/specs/` or in a library's
[`docs/libs/<name>/`](../libs/versions/index.md) tree.

Use it when you are surveying prior art (e.g. "how do other ecosystems do
workspaces", "TUI rendering models", "async I/O runtimes"). Do **not** use it for
how-to/reference/tutorial material for a Sparkles library (that is Diátaxis material
under `docs/libs/<name>/`) or for cross-cutting agent/style guides (those live here
in `docs/guidelines/`).

---

## Catalog anatomy

A research catalog is **one directory per topic** under `docs/research/<topic>/`,
tied together by an **`index.md` umbrella** and registered in the VitePress sidebar.
Every topic gets its own directory — research never lives as loose files directly in
`docs/research/`.

Within a topic, each **subject** (a surveyed system, sub-area, or theme) starts as a
single breadth-first file and **graduates to its own subdirectory as the research
deepens**:

```
docs/research/<topic>/
├── index.md            # umbrella (always present)
├── concepts.md         # shared vocabulary (optional)
├── <subject>.md        # starting form: one breadth-first file per subject
├── <subject>/          # graduated form: the subject now carries companion files
│   ├── index.md        #   the deep-dive
│   ├── sample/ …       #   a runnable workspace, and/or
│   ├── examples/ …     #   standalone runnable programs, and/or
│   └── <sub-topic>.md  #   its own cluster of sub-deep-dives
└── comparison.md       # cross-subject synthesis (the capstone)
```

- **`<topic>/<subject>.md`** — the default starting point while the survey is still
  breadth-first. Most of `async-io/` stays here (`glommio.md`, `tokio.md`, …).
- **`<topic>/<subject>/index.md` + companion files** — once a subject needs to carry
  more than prose: a runnable [`sample/`](#co-located-runnable-samples-and-examples)
  workspace (every subject in `monorepo-tooling/`), an `examples/` directory of standalone
  programs (async-io's [`io-uring/`](../research/async-io/io-uring/index.md), whose
  `examples/` holds ~40 runnable `.d` programs the deep-dive links to), or its own
  sub-deep-dives (`io-uring/{features,timeline,opcodes-reference}.md`;
  `coroutines/stackless/` + `stackful/`). The prose conventions are unchanged; the
  file just moves from `<subject>.md` to `<subject>/index.md`, deepening
  relative-link depth by one.

The rule of thumb is **start flat, deepen on demand**: reach for a subject directory
the moment the subject acquires companion files or its own sub-tree — not before. A
topic freely mixes the two forms (async-io has flat `glommio.md` beside the deepened
`io-uring/`); `monorepo-tooling/` went all-subdirectory from the start only because
every subject was getting a `sample/`.

Express a subject's **category** as a column in the master catalog and a grouping in
the sidebar (see [VitePress integration](#vitepress-integration)), not as an extra
directory level — keep the topic→subject nesting shallow.

---

## The `index.md` umbrella

Model on [`async-io/index.md`](../research/async-io/index.md) and
[`coroutines/index.md`](../research/coroutines/index.md). It contains, in order:

1. A framing paragraph, then an explicit **"this survey answers N questions"** list
   linking to the docs that answer each.
2. A **`**Last reviewed:** <Month Day, Year>`** line (absolute date — convert any
   relative date). Every umbrella and synthesis doc carries one.
3. A **Master Catalog** table — one row per subject, with the columns that matter for
   the topic (always include a **Link** column pointing at the deep-dive). Mark
   forward-dated or uncertain entries explicitly.
4. **Taxonomy** tables that re-cut the same set by one axis each (e.g. _by I/O model_,
   _by dependency-isolation model_), every row linking back to deep-dives.
5. A **Milestones** timeline of when key capabilities landed across the field.
6. **Quick navigation / suggested reading paths** (including a path for "I'm
   designing the Sparkles feature this informs").
7. A **Sources** section + the [reference-link block](#house-style).

---

## The per-subject deep-dive

Model every deep-dive on [`async-io/glommio.md`](../research/async-io/glommio.md).
Fixed skeleton:

1. `# <Subject> (<Language/Ecosystem>)` title + a one-sentence positioning line.
2. A **metadata table** near the top (Language, License, Repository, Documentation,
   Category, plus topic-specific rows like _Workspace model_, _First/Latest release_).
3. `## Overview` — `### What it solves` and `### Design philosophy`, with **at least
   one verbatim quote from the source tree or official docs**, cited to a real file
   path or URL.
4. `## How it works` — the real mechanics, identifiers in backticks, short fenced
   config/code excerpts (label the fence: `toml`, `json`, `yaml`, `bash`, `sdl`, …).
5. A **fixed analysis spine** — the same set of subsections in every deep-dive of the
   tree, so the catalog is comparable. (In `monorepo-tooling/` that spine is five
   dimensions: workspace declaration & topology, dependency handling & isolation, task
   orchestration & scheduling, caching & remote execution, CLI/UX ergonomics. Pick the
   spine that fits your topic and apply it uniformly.) Where a dimension doesn't apply
   to a subject, say so and explain why — the _absence_ of a feature is itself a finding.
6. `## Strengths` / `## Weaknesses` (bulleted).
7. `## Key design decisions and trade-offs` — a three-column
   `Decision | Rationale | Trade-off` table.
8. `## Sources` — bulleted primary sources, then the reference-link block.

Be primary-source-driven: read the real source tree or official docs and cite real
paths/URLs, not general impressions. Match the density and declarative, citation-heavy
tone of the exemplars — never hand-wavy.

---

## Concepts, synthesis & proposal docs

Beyond the deep-dives, a mature tree usually has:

- **`concepts.md`** — the shared vocabulary the deep-dives reference, each term defined
  once and grounded in real examples (cf. `async-io/primitives.md` + `techniques.md`).
- **`comparison.md`** — the capstone synthesis: an at-a-glance master table, a
  per-dimension comparison, the **consensus standard**, the **architectural
  trade-offs**, and — when the survey targets a specific Sparkles gap — an explicit
  **delta table** mapping each modern capability to where Sparkles stands today. This
  bridges into any proposal.
- **A baseline / proposal pair** (optional, when the survey drives a concrete feature)
  — e.g. `monorepo-tooling/`'s [`dub-baseline.md`](../research/monorepo-tooling/dub-baseline.md)
  (the system under improvement) and
  [`dub-proposal.md`](../research/monorepo-tooling/dub-proposal.md) (a milestoned plan,
  each milestone cross-linking the prior art it borrows from).

---

## House style

Enforced partly by the pre-commit hooks and the VitePress build, partly by convention:

- **Reference-style links**, collected under an HTML comment `<!-- References -->` at
  the very bottom of the file (copy the pattern from any existing deep-dive). Mind the
  depth: from a `<subject>.md` a sibling is `./<other>.md`; from a deepened
  `<subject>/index.md` a sibling subject is `../<other>/`, the umbrella is `../`, and
  another tree is `../../<tree>/<file>.md`. Every link must resolve.
- **Backtick every identifier** — filenames, flags, config keys, type/command names
  (`dub.sdl`, `--filter`, `[workspace]`, `pnpm-workspace.yaml`). The whole corpus does
  this religiously; it also sidesteps Prettier's underscore-in-emphasis mangling.
- **Link every term to its definition.** A reader should be able to click any
  identifier, operation, or proper noun and land on the authoritative source — a
  section in the same doc, another page under `docs/`, or the canonical external
  reference (official API docs, a spec, or the upstream source). The
  [`expected` cheat sheet](./idioms/expected/index.md#cheat-sheet-d-expected-vs-rust-result)
  is the exemplar: every operation links to the section that explains it, and every
  D/Rust API name links to its official docs. In a research tree this is why the master
  catalog and comparison tables link each subject to its deep-dive, and why each
  deep-dive's `Sources` block carries the external references behind its claims.
- Use **GitHub alerts** (`> [!NOTE]`, `> [!IMPORTANT]`, `> [!WARNING]`) for scope
  notes and caveats.
- A **`**Last reviewed:**`** date on every umbrella/synthesis doc; absolute dates
  everywhere; mark forward-dated/uncertain timeline entries.
- Column-aligned tables; dense, declarative, source-grounded prose.

---

## VitePress integration

The site build is the gate for link and markup correctness — **`npm run docs:build`
must be green** before you commit a tree, and it is the fastest way to catch the
gotchas below.

1. **Register the tree** in `docs/.vitepress/config.mts`
   under the `Research` sidebar section: a top-level entry linking the umbrella, with
   subjects **grouped by category** into nested collapsed `items` (see how `ui-layout`
   and `monorepo-tooling` are grouped). A `<slug>/` link resolves to its `index.md`.
2. **Markdown is compiled as a Vue template**, so a few constructs bite:

   ```text
   • Bare <word> in prose parses as an HTML tag → backtick it or rephrase.
     Single-line inline code like `<member>` is fine (escaped); a code span that
     BREAKS ACROSS A LINE while containing <...> is NOT — keep such spans on one line.
   • {{ ... }} is a Vue interpolation, even inside inline code. To show it literally,
     put it in a fenced code block, or wrap the span in <span v-pre>...</span>.
   • Unknown code-fence languages (ninja, just, meson, …) fall back to plain text with
     a harmless warning. languageAlias them ONLY to a real bundled grammar (e.g.
     starlark → python); aliasing to a non-grammar (text/make) turns the warning into
     a hard build error.
   ```

3. **`ignoreDeadLinks`** — links to source artifacts that aren't built pages (`.d`
   files, a `sample/` directory) must be added to the `ignoreDeadLinks` patterns in
   `config.mts`, the same way the existing `/\.d$/` rule works.

---

## Co-located runnable samples and examples

A subject that has graduated to its own directory can co-locate runnable code — the
strongest grounding the corpus has. The engine is the repository's **`ci` helper**
(`apps/ci`), which makes example code self-testing in two ways, both run in CI:

- **Markdown-embedded examples.** A fenced `d` block written as a single-file `dub`
  program, immediately followed by an `[Output]` block. `ci --verify` **extracts the
  snippet from the `.md`, compiles and runs it, and diffs its stdout/stderr against the
  `[Output]` block** — so the numbers and text quoted in the prose are provably what
  the code actually prints. For dynamic output, a `<!-- md-example-expected -->` comment
  carries a wildcard pattern while the `[Output]` block keeps reader-friendly literals.
  Full convention: [AGENTS § Runnable README examples](./AGENTS.md#runnable-readme-examples).
- **Standalone `examples/` programs.** A directory of single-file `dub` programs
  (`#!/usr/bin/env dub` + an embedded `dub.sdl`), each demonstrating one claim from the
  deep-dive. `ci --example-files` (`-x`) **compiles and runs** them, and the directory
  is registered in the helper's defaults (alongside `libs/core-cli/examples/*.d`) so it
  runs on every pass — no example is "documented but dead". async-io's
  [`io-uring/`](../research/async-io/io-uring/index.md) ships ~40 (`nop.d`, `tcp-echo.d`,
  `multishot-accept.d`, …).

The discipline is the same either way: **if the API or behaviour a deep-dive describes
stops working, the example fails to compile/run (or its output stops matching) and CI
goes red.** To keep that signal honest:

- **Cross-link example ↔ prose** — each standalone example's header comment points at
  the deep-dive section it backs, and the deep-dive links to the example. Links to the
  `.d` files pass the link checker via the `ignoreDeadLinks` `/\.d$/` rule.
- **Keep examples portable-green** — gate on `platforms` in the `dub.sdl` header, and
  where the host may lack a capability, print a `SKIP:` line and exit `0` instead of
  failing (the `io_uring` examples skip on too-old kernels). A red CI from a missing
  host capability would defeat the purpose.
- **A shebang example file must be executable** (`git add --chmod=+x …`) or the
  `check-shebang-scripts-are-executable` hook blocks the commit.

### `sample/` workspace fixtures

A `sample/` is the non-executed cousin: a minimal, idiomatic workspace co-located with
a deep-dive to make its config concrete (every `monorepo-tooling/` subject; see
[`cargo/sample/`](../research/monorepo-tooling/cargo/)). It _would_ run with the
toolchain installed, but CI does not execute it — its job is to be correct and
illustrative. Rules:

- **Minimal and real:** a root manifest + two members with a genuine local
  cross-reference + one task.
- **Source only:** never commit build artifacts or dependency stores
  (`node_modules/`, `target/`, `dist/`, `.dub/`, …); add them to `.gitignore`.
- **No `.md` under `sample/`** — keep all prose in the deep-dive, so the link checker
  and VitePress don't try to build fixture files. (If a sample must contain `.md`, add
  a `srcExclude` glob in `config.mts`.)
- **Match each ecosystem's native formatting** so the hooks pass: per-file
  `.editorconfig` indent (4-space Rust/D, tabs for Go/Makefile, 2-space JSON/YAML/JS),
  a final newline, no trailing whitespace.
- **JSON formatter tension:** Prettier and the `pretty-format-json` hook disagree on
  array style. Keep sample JSON in `pretty-format-json`'s canonical form (sorted keys,
  expanded arrays) and add those files to `.prettierignore` (negating `package.json`
  back in) so the two stop fighting.

---

## Citations & link-checking

- **Cite primary sources** — real repository file paths and official-doc URLs — and
  quote verbatim where it carries weight. Each deep-dive's `Sources` section is its
  provenance.
- **Pin flaky external links to `web.archive.org`.** Some hosts rate-limit or reject
  the link checker; replace such a URL with a _verified_ Wayback snapshot
  (`https://web.archive.org/web/<timestamp>/<url>` — confirm the snapshot is HTTP 200,
  e.g. via the CDX index). For hosts that should be ignored everywhere, add a pattern
  to the shared `lychee.exclude` file at the repo root.
- The `lychee` link checker is slow and flaky on large external sets; it is reasonable
  to `SKIP=lychee` at commit time and let CI run it (see below).

---

## Hooks & committing

The pre-commit hooks ([AGENTS § Pre-commit hooks](./AGENTS.md#pre-commit-hooks-prek))
shape every commit:

- **prettier** re-flows markdown and re-aligns tables; re-check literal-data tables
  afterward (it has corrupted underscores). It owns markdown/JSON/YAML formatting.
- **editorconfig-checker** checks indentation. Markdown indent is exempt, but a fenced
  block with required tabs (e.g. a Makefile recipe) needs a per-file `indent_style =
unset` override in `.editorconfig`.
- **fix-markdown-reference-links** de-duplicates reference URLs; **pretty-format-json**
  and the `check-*` validators police the sample configs.
- **lychee** (external links) and **verify-md-examples** (OOM-prone; a no-op when a
  doc has no `[Output]` examples) are the two it's reasonable to bypass for a large
  docs drop: `SKIP=lychee,verify-md-examples git commit …`.

Commit the catalog as a coherent unit (the deep-dives and synthesis docs cross-link
densely, so they only build green together), with the VitePress/`.editorconfig`/
`.gitignore` prep in a separate preparation commit ahead of it. Follow the repo's
[commit-message](./AGENTS.md#commit-messages) and
[git-hygiene](./AGENTS.md#git-hygiene-atomic-commits) conventions — scope research-doc
commits `docs` or `research`.

---

## Authoring checklist

- [ ] Tree registered in the VitePress sidebar, grouped by category.
- [ ] `npm run docs:build` is green (no dead links, no Vue/mustache compile errors).
- [ ] Every deep-dive follows the skeleton and the tree's fixed analysis spine.
- [ ] At least one verbatim, cited primary-source quote per deep-dive.
- [ ] Umbrella + synthesis docs carry a `**Last reviewed:**` date.
- [ ] Reference-style links, all resolving; identifiers backticked.
- [ ] Every term links to its definition — a same-doc section, another `docs/` page, or
      the canonical external reference (the [`expected` cheat sheet](./idioms/expected/index.md#cheat-sheet-d-expected-vs-rust-result) is the model).
- [ ] Demonstrable claims are backed by a runnable example the `ci` helper compiles and
      runs — a markdown `[Output]` example (`ci --verify`) or a standalone `examples/*.d`
      (`ci --example-files`); examples stay green cross-platform (`SKIP:` / `platforms`).
- [ ] Samples are source-only illustrative fixtures; artifacts git-ignored; hooks pass.
- [ ] Flaky external links pinned to `web.archive.org` or excluded in `lychee.exclude`.
