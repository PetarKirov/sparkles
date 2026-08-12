# Agent Guidelines — Modern D Language Features

Instructions for agents editing or verifying
[`index.md`](./index.md) (the changelog-sourced survey of D features for Sparkles
code). Keep this file accurate — it is the protocol for claim-by-claim grounding of
that guide against the local `dlang.org` changelog tree.

The general research grounding protocol lives in
[Writing Research Docs § Grounding ledgers](../research-docs.md#grounding-ledgers-grounding).
This file specializes it for a **single guidelines page** whose primary is almost
entirely `changelog/*.dd`.

---

## Scope

| In scope                                                  | Out of scope                                                                   |
| --------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Version stamps (`[2.xxx]`), preview→default hops, DIP ids | Phobos-only history the guide deliberately omits                               |
| Changelog-stated syntax and semantics                     | Sparkles house policy (`-preview=in`, `@safe` defaults) — mark `◯`             |
| Milestone dates and “landmark” bullets                    | CI-runnable example programmes (this guide has none; do not invent that layer) |
| “Still legal legacy” vs modern form                       | LDC-only behaviour unless the changelog states it                              |

`index.md` is claim-dense (~tens of feature bullets, hundreds of version citations
across ~50 releases). Treat it as a **version-attribution survey**, not free-form prose.

---

## Primary source (local-first)

Prefer the local clone over web HTML.

| Item          | Value                                                                               |
| ------------- | ----------------------------------------------------------------------------------- |
| Repo          | `$REPOS/dlang/dlang.org` (typically `/home/petar/code/repos/dlang/dlang.org`)       |
| Path          | `changelog/`                                                                        |
| Files         | `2.060.dd` … `2.112.0.dd` (and patch `.1` files only when a claim is about a patch) |
| Public mirror | https://dlang.org/changelog/ (reader-facing links in `index.md` only)               |

**Filename quirks:** early releases are `2.060.dd` / `2.061.dd`; from ~2.065 many are
`2.065.0.dd`. Match the guide’s reference-link targets (e.g. `[2.066]` →
`2.066.0.html`).

**Changelog structure:** each `*.dd` has a TOC of `$(RELATIVE_LINK2 slug, …)` then body
sections `$(LNAME2 slug, …)`. Prefer **release file + slug** as the locator; add
`file:line` for exact quote rows.

```text
# Preferred locator
changelog/2.111.0.dd § dmd.auto-ref-local

# Optional line pin (at the recorded SHA)
changelog/2.111.0.dd:39
```

Do **not** re-fetch dlang.org HTML for verification when the local `.dd` is present.
Use web only if a file is missing from the pin. Record the full reviewed SHA and an
“as of” date in `grounding/_sources.md`.

### Secondaries (named fallback only)

- D language specification — when DIP text has drifted (the guide already notes DIP1000)
- DIPs under `dlang/DIPs` when the changelog only links the DIP
- Official [deprecated features table](https://dlang.org/deprecate.html) for
  still-legal vs removed forms

---

## Layout

```text
docs/guidelines/d-language-features/
├── index.md              # published guide (VitePress sidebar)
├── AGENTS.md             # this file
└── grounding/            # internal QA — never link from index.md
    ├── index.md          # status legend, per-ledger index, discrepancy register
    ├── _sources.md       # pin map (SHA, paths, secondaries)
    └── features.md       # claim ledger (or section-sliced files — see below)
```

> [!IMPORTANT]
> This directory’s agent protocol and ledgers are **not published**. VitePress
> `srcExclude` and lychee `exclude_path` already cover:
>
> - `**/guidelines/d-language-features/AGENTS.md` (this file)
> - `**/guidelines/d-language-features/grounding/**`
>
> (Research-wide `**/research/**/grounding/**` does **not** cover this path —
> keep the guideline-specific globs if you move or rename the tree.)
>
> Banner every ledger file: _Not published. Do not link to it from the guide._
> Never link `index.md` into `grounding/` or this `AGENTS.md`.

Published provenance stays in `index.md`’s `Sources` and the `[2.xxx]` reference
links. Local `$REPOS` paths and line locators stay in the ledger only.

---

## Status marks and claim types

| Mark | Meaning                                                                                              |
| ---- | ---------------------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)                                         |
| `≈`  | Accurate paraphrase / abridged-but-faithful (not a fake quote)                                       |
| `⚠`  | Discrepancy — wrong, misattributed, or fabricated; correction recorded **and** applied to `index.md` |
| `◯`  | Not changelog-groundable — editorial, Sparkles policy, or primary unobtainable (fallback named)      |
| `🌐` | Web-only fallback (use sparingly; prefer local `.dd`)                                                |

**Types:** `quote` · `fact` · `figure` · `behavior` · `exposition` · `opinion`.

Typical mapping for this guide:

| Type                     | Examples                                     | Ground against                                                   |
| ------------------------ | -------------------------------------------- | ---------------------------------------------------------------- |
| `fact` (version)         | “`@nogc` since [2.066]”                      | Feature in that release’s compiler-changes TOC/body              |
| `fact` (span)            | “Named arguments [2.103]→[2.108]”            | Intro in 2.103 **and** completion/docs language in 2.108         |
| `fact` (preview→default) | “Bitfields preview [2.101], default [2.112]” | Both ends in their release files                                 |
| `quote` / syntax         | `` `int f() pure => expr;` ``, `i"…"`        | Changelog sample or description (or DIP if `.dd` defers)         |
| `behavior`               | “`in` is `scope const` under `-preview=in`”  | Wording for that release; reworks need a second row (e.g. 2.094) |
| `fact` (DIP id)          | “DIP1043”, “DIP1009”                         | Changelog names or links the DIP                                 |
| `opinion` / policy       | Repo baseline `-preview=in` + `dip1000`      | `◯` — cite AGENTS / `dub.sdl`, not the changelog                 |
| `exposition`             | Narrative arcs (“the `@safe`/`scope` arc”)   | Ground atomic facts inside; leave framing `◯`                    |

---

## Ledger format

Minimum table columns:

```text
# | Section | Claim (short) | Type | Version(s) claimed | Source (changelog locator) | Status
```

### Slicing strategy

| Approach                   | When                          |
| -------------------------- | ----------------------------- |
| **One file** `features.md` | First pass or small edit      |
| **Section files**          | Parallel work or a full audit |

Recommended section files (match `index.md` headings):

| Ledger                 | Covers                                                |
| ---------------------- | ----------------------------------------------------- |
| `quick-ref.md`         | Master “features to reach for” table — **start here** |
| `declarations.md`      | Declarations & modules                                |
| `functions.md`         | Functions, parameters & contracts                     |
| `memory-safety.md`     | `@safe` / `scope` arc (multi-version; highest risk)   |
| `shared.md`            | `shared` & atomics                                    |
| `interop.md`           | C / C++ / Objective-C                                 |
| `compiler-switches.md` | Preview defaults table + switch list                  |
| `legacy.md`            | “Write X instead of Y” table                          |
| `milestones.md`        | Milestones table (date + landmark)                    |

`grounding/index.md` holds the status legend, a per-ledger index, and the **master
discrepancy register** (`R1`, `R2`, … with **Claim | Correction | Source | Fixed?**).

**Fixed? means `index.md` states the corrected fact** — a ledger-only note is not
enough. Land substantive corrections in the same commit series as the prose fix when
practical.

---

## Per-claim procedure

For a claim such as _“`ref`/`auto ref` variables — [2.111]”_:

1. Open `$REPOS/dlang/dlang.org/changelog/2.111.0.dd` at the pinned SHA.
2. Confirm the TOC entry (e.g. `dmd.auto-ref-local`).
3. Read the body: does version, semantics, and example shape match the guide?
4. Record a ledger row with locator + status (`✓` / `≈` / `⚠` / …).
5. Leave the published `[2.111]` link as the public changelog URL — do not point readers
   at `grounding/` or `$REPOS`.

### Multi-hop claims

Preview→default and “introduced → completed” spans need **both** ends:

- Row (or one row with two locators): intro release + default/completion release.
- Status is `✓` only if **every** listed locator holds.

### Attribute-inference ranges

Spans like `[2.063]–[2.068]` may need several greps; one row with multiple locators is
fine.

---

## Discrepancy patterns to hunt

| Pattern                      | Risk                                     | Fix                                                               |
| ---------------------------- | ---------------------------------------- | ----------------------------------------------------------------- |
| Wrong intro version          | Feature one release early/late           | Fix every `[2.xxx]` restatement                                   |
| Preview vs default collapsed | Bitfields, shortened methods, named args | Split “preview since / default since” if the table oversimplifies |
| Patch vs minor               | Link target mismatches `*.dd` name       | Align reference URL with real changelog file                      |
| Wrong DIP id                 | Mislabelled DIP                          | Correct id + any DIP link                                         |
| Semantics drift              | `in` after 2.094 rework                  | Prefer **current** semantics; cite both hops if teaching history  |
| “Still legal legacy” wrong   | Postblit / contracts still silent?       | Cross-check deprecate table + recent deprecation entries          |
| Milestone date wrong         | Month/year for a release                 | `$(VERSION …)` header in that `.dd`                               |

---

## Work order (full audit)

1. **Pin** — write `_sources.md` (full SHA of `dlang.org`, “as of” date, secondaries).
2. **Quick reference table** — one row per “Feature / Since” (highest signal).
3. **Milestones** — date + landmark vs `$(VERSION …)` and major bullets.
4. **Preview→default table** in “Compiler switches…”.
5. **Sections** — memory safety first, then functions/contracts, declarations, interop,
   remainder.
6. **Legacy table** — modern form’s version + that old form still compiles (or now
   warns).
7. **Policy rows** — mark `◯` (repo AGENTS / package `dub.sdl`).
8. **Apply `⚠`** — edit `index.md`; flip register `Fixed?`.
9. **Close out** — update `**Last reviewed:**` on `index.md`; if the pin has a newer
   prerelease (e.g. 2.113), either extend the guide’s upper bound deliberately or
   document the 2.112 ceiling in `_sources.md`.

Exclusions for this tree and `AGENTS.md` are already in `docs/.vitepress/config.mts`,
`lychee.toml`, and `nix/checks/pre-commit.nix` — re-check them only if you move paths.

For a small edit (one feature, one version bump), ground only the touched claims and
add/update their ledger rows — do not re-audit the whole guide unless asked.

---

## Ledgers vs examples

- **Ledgers** verify claims about the D language and its changelogs.
- This guide’s fenced snippets are **illustrative**, not CI-verified research
  examples. Do not treat a snippet as changelog-backed unless it appears in that
  release’s changelog sample (or a named secondary).

Cross-links to Code Style, IES, ImportC, etc. are navigation, not language claims.

---

## Checklist

Before merging material edits to `index.md`:

- [ ] Touched version stamps / DIP ids / preview boundaries have ledger rows with local
      locators (or explicit `◯` / `🌐`).
- [ ] Multi-hop claims list **both** ends.
- [ ] Discrepancy rows applied to `index.md` (`Fixed?` ✓).
- [ ] No published link into `grounding/` or this `AGENTS.md`.
- [ ] `_sources.md` records full pin SHA and paper/secondary paths used.
- [ ] `**Last reviewed:**` updated when the grounding pass finishes.
- [ ] Identifiers backticked; reference-style `[2.xxx]` links resolve.

---

## Related

- [Modern D Language Features](./index.md) — the published guide
- [Writing Research Docs — Grounding ledgers](../research-docs.md#grounding-ledgers-grounding) — corpus-wide protocol
- [AGENTS § Preview flags](../AGENTS.md#preview-flags) — Sparkles baseline (`-preview=in`, `-preview=dip1000`)
- Research exemplars (claim-ledger shape):
  [`docs/research/parsing/grounding/`](../../research/parsing/grounding/index.md)
