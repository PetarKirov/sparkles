# Build Systems Research Plan

A working plan for the source-grounded build-systems catalog under
`docs/research/build-systems/`. The catalog surveys build-system _engines_ —
schedulers, rebuilders, dependency discovery, stores, sandboxes, and remote
execution — across academic literature, industry systems, and the Nix
ecosystem, and synthesizes fourteen cross-cutting themes. It feeds the
Sparkles task-DAG work in `sparkles:build-primitives`
(`libs/build-primitives/src/sparkles/build_primitives/task/`) and any future
`dub` build-engine design.

**Plan updated:** November 2, 2026

> [!IMPORTANT]
> This is an execution plan, not a findings page. Claims intended for readers
> belong in the catalog's deep-dives and synthesis pages, where they must
> carry primary-source citations. Remove this plan from the published
> catalog, or move it to the final design issue, once the research tree is
> complete and its remaining work is tracked elsewhere. It is excluded from
> the site build via `docs/.vitepress/docs-config.json` (`srcExclude`).

## 1. Decision: a new top-level catalog, not a monorepo-tooling extension

`docs/research/monorepo-tooling/` already deep-dives 13 of this catalog's
industry subjects (Bazel, Buck2, Please, Pants, moon, GN, Ninja, Make, Meson,
Earthly, sbt, redo, tup). It is not extended, for three reasons:

1. **Different question.** monorepo-tooling asks how 45 tools declare
   workspaces, isolate dependencies, orchestrate package tasks, cache, and
   expose filter ergonomics — to inform a `dub` _workspace_ proposal. This
   catalog asks how a build _engine_ schedules tasks, decides dirtiness,
   discovers dependencies, stores outputs, sandboxes actions, and distributes
   work — to inform a task-DAG/build-engine design. Merging them would force
   one tree to carry two analysis spines, which
   [Writing Research Docs](../../guidelines/research-docs.md) forbids in
   spirit: one tree, one fixed spine, comparable deep-dives.
2. **Different center of gravity.** The academic spine (à la carte, PIE,
   Rattle), the Nix dynamic-derivations cluster, and the fourteen themes
   (sandbox overheads, CAS eviction, formal verification, SLSA, …) have no
   home in a workspace-shaped tree; they would be appendices there and are
   the main text here.
3. **Overlap is handled by cross-linking, not duplication.** Where a subject
   exists in both trees, the build-systems page covers engine internals and
   links the monorepo-tooling page for workspace/orchestration treatment,
   and vice versa. New subjects with no monorepo angle (BuildXL, build2,
   Shake, Rattle, BitBake, BuildKit) live only here.

The alternative — deepening monorepo-tooling with engine sections per tool —
remains available later by moving pages; starting separate keeps both trees
green and independently reviewable.

## 2. Sources on disk (verified November 2, 2026)

Cloning was delegated to `opencode2` (`opencode-go/deepseek-v4.1-flash`) and
is complete. Authoritative inventories:

- `$REPOS/build-systems-research/MANIFEST.md` — 33 clones (26 cloned,
  5 reused-and-updated, `nix` reused, `nixpkgs` reused-dirty/untouched,
  `boba-fuchsia` skipped after investigation), each with upstream URL,
  40-char HEAD SHA, default branch, and size. Canonical clones live at
  `$REPOS/<language-or-ecosystem>/<repo>/`; `$REPOS/build-systems-research/src/<slug>`
  is a relative symlink view. Research prompts cite the symlink path;
  citations pin the manifest SHA.
- `$REPOS/papers/build-systems/MANIFEST.md` — 7 PDFs on disk (à la carte
  ICFP 2018 + JFP 2020, Konat et al. ASE 2018, Spall et al. OOPSLA 2020,
  Dolstra thesis 2006, NixOS JFP 2010, and an author **preprint** of
  McIntosh et al. EMSE 2015 supplied 2026-11-02 — the published version is
  paywalled; cite the preprint as such, since pagination may differ) with
  SHA256s.

Known gaps carried as findings, not blockers: no standalone Fuchsia **Boba**
repo exists (Bazel integration is in-tree at `build/bazel/` in the multi-GB
`fuchsia.git` — cloning it is a separate disk-budget decision); `$REPOS/nix/nix`
is a personal fork clone whose upstream tip is read via
`git show 1ed54a0fd62da96d4f5e9c806555861e46f65341:<path>`.

## 3. Catalog shape and analysis spine

Flat-first layout per the research-docs guide; category is a sidebar/index
grouping, not a directory level. A subject graduates to `<subject>/index.md`
only when it gains companion files (a `sample/`, sub-deep-dives).

```text
docs/research/build-systems/
├── index.md          # umbrella: questions, master catalog, taxonomies, milestones
├── concepts.md       # à-la-carte vocabulary: scheduler × rebuilder, traces, …
├── <subject>.md      # one page per paper / system / Nix project
├── <theme>.md        # one synthesis page per broader theme (§5, wave 5)
└── comparison.md     # capstone: consensus, trade-offs, Sparkles delta
```

Every system/paper deep-dive uses the guide's skeleton (metadata table,
verbatim primary-source quote, `How it works`, Strengths/Weaknesses,
Decision|Rationale|Trade-off table, Sources) with this tree's fixed spine,
derived from _Build Systems à la Carte_:

1. **Task model & scheduling** — static vs dynamic dependencies; topological,
   restarting, or suspending scheduler; parallelism and speculation.
2. **Rebuilding & correctness** — dirty check (mtime, hash, verifying/
   constructive traces); minimality; early cutoff; correctness argument.
3. **Dependency discovery** — declared, inferred, traced (syscall/FUSE/
   compiler depfiles), or hybrid; strict-deps enforcement and pruning.
4. **Store & caching** — in-place vs content-addressed store; local/remote
   cache; CAS dedup and eviction; action-cache keys.
5. **Hermeticity & provenance** — sandbox mechanism and overhead;
   reproducibility; attestation (SLSA/in-toto) hooks.
6. **Distribution** — remote execution (REAPI or proprietary), daemon/
   memory-resident operation, cross-language/codegen boundaries.
7. **Sparkles relevance** — what `build_primitives.task` or a future `dub`
   engine should borrow, avoid, or measure. (One short subsection; design
   decisions themselves belong in `docs/specs/`.)

Where a dimension does not apply (e.g. distribution for `redo`), the page
says so explicitly — absence is a finding.

## 4. Subject inventory

Status: `todo` → `drafted` (delegated draft exists) → `reviewed` (citations
verified, `yarn docs:build` green).

### Academic (wave 1)

| Page                      | Subject                                                                          | Primary source                                                                                            | Status   |
| ------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | -------- |
| `a-la-carte.md`           | Build Systems à la Carte: Theory and Practice (Mokhov et al.)                    | JFP 2020 PDF + ICFP 2018 PDF                                                                              | todo     |
| `pie.md`                  | Scalable Incremental Building with Dynamic Task Dependencies (Konat et al., PIE) | ASE 2018 PDF                                                                                              | todo     |
| `build-maintenance.md`    | Build Technology & Build Maintenance (McIntosh et al.)                           | Author preprint PDF (published EMSE version paywalled, DOI `10.1007/s10664-014-9324-x`); cite as preprint | reviewed |
| `perfect-dependencies.md` | Build Scripts with Perfect Dependencies (Spall et al., Rattle)                   | OOPSLA 2020 PDF + `haskell/rattle`                                                                        | todo     |
| `nix-thesis.md`           | The Purely Functional Software Deployment Model (Dolstra) + NixOS paper          | Thesis 2006 PDF + JFP 2010 PDF                                                                            | todo     |

### Industry (waves 2–3)

New here: `buildxl.md`, `build2.md`, `shake.md`, `rattle.md` (system page,
distinct from the paper page), `bitbake.md`, `buildkit.md`, `boba.md`
(short page recording the in-tree finding; no clone).

Engine-focused companion pages that cross-link their monorepo-tooling
deep-dive instead of repeating it: `bazel.md`, `buck2.md`, `please.md`,
`pants.md`, `moon.md`, `gn.md`, `ninja.md`, `gnumake.md`, `meson.md`,
`earthly.md`, `sbt.md`, `redo.md`, `tup.md`. Companion pages may be shorter:
spine dimensions 1–6 from the clone, plus a delta note on what the
monorepo page already covers.

### Nix ecosystem (wave 4)

`nixception.md`, `nix-ninja.md`, `sandstone.md`, `drowse.md`, `dgd.md`,
`nixgg.md`, `nix-cargo-unit.md`, `makenix.md`, and
`nix-dynamic-derivations.md` — the last synthesizes the four F. Zakaria
posts cloned in `fzakaria.com` (`_posts/2025-03-10-…`, `2025-03-11-…`,
`2026-09-21-…`, `2026-10-17-…`) against the `NixOS/nix` sources they
describe, and cross-links `docs/research/content-addressing/` and
`docs/research/monorepo-tooling/nix-flakes/`.

## 5. Broader themes (wave 5, synthesis pages)

Each theme page synthesizes across the deep-dives above plus its own primary
sources; none is written before its feeding deep-dives are `reviewed`.

| Page                          | Theme                                                                                                 |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| `sandboxing-overheads.md`     | Hermetic syscall interception & sandboxing overheads (`ptrace`, eBPF, Landlock, FUSE vs declared I/O) |
| `dynamic-deps-distributed.md` | Dynamic task dependencies in distributed/remote execution                                             |
| `dependency-pruning.md`       | Automated redundant/strict dependency pruning                                                         |
| `graph-autogeneration.md`     | Build-graph auto-generation via dynamic tracing                                                       |
| `semantic-caching.md`         | AST- & semantic-level cache invalidation, interface hashing                                           |
| `daemon-compilers.md`         | Continuous incremental building & memory-resident compilers                                           |
| `link-time-pruning.md`        | Fine-grained link-time pruning (mold/`lld`, symbol-level)                                             |
| `compile-time-execution.md`   | Deterministic macros/CTFE/`build.rs` under hermetic sandboxing                                        |
| `cas-eviction.md`             | CAS deduplication & eviction at scale                                                                 |
| `cross-language-dags.md`      | Multi-language cross-module DAG unification (FFI, codegen, protobuf)                                  |
| `speculative-execution.md`    | Critical-path speculative execution from historical traces                                            |
| `formal-verification.md`      | Mechanized build-correctness/minimality proofs (Coq/Lean)                                             |
| `reproducibility.md`          | Non-determinism detection & bit-for-bit reproducibility                                               |
| `provenance.md`               | SLSA attestation & in-toto provenance in the build DAG                                                |

## 6. Orchestration (rate-limit-aware delegation)

Bulk reading and first drafts are delegated to `opencode2` with
`opencode-go/deepseek-v4.1-flash`; Muse (this session) owns the plan,
prompts, citation verification, sidebar/docs-build gates, and final edits.
Rules that keep usage bounded and output verifiable:

- **One `opencode2 run` per page** (small Nix projects may pair two per run).
  Sequential only — never parallel runs. A run writes exactly one `.md` file
  under `docs/research/build-systems/` and nothing else.
- **Self-contained prompts.** Each prompt names: the output file, the clone
  path under `$REPOS/build-systems-research/src/<slug>` and its manifest
  SHA, the §3 spine, the deep-dive skeleton, and the citation rules
  (SHA-pinned `github.com/…/blob/<40-char SHA>/<path>` URLs, ≥1 verbatim
  quote with file path, reference-style links under `<!-- References -->`,
  backticked identifiers, no invented release dates — mark `~` or omit).
- **Waves with review gates.** After each wave: `dub run :ci -- --check-docs-sidebar`,
  `yarn docs:build`, and `dub run :ci -- --check-blob-paths` (offline
  `git cat-file` against the clones) must pass before the next wave starts.
  Unverifiable claims are cut or marked, never smoothed over.
- **Wave order:** 0 scaffold (`index.md` skeleton + `concepts.md`) →
  1 academic (5) → 2 new industry (7) → 3 engine companions (13) →
  4 Nix ecosystem (9) → 5 themes (14) → 6 `comparison.md` + umbrella
  completion. ≈50 delegated runs total; stop/park between waves freely —
  every wave leaves the tree green.
- **PDF access.** Papers are PDFs only; a delegated run first checks for a
  text extractor (`pdftotext`, `mutool`, `python3`+`pypdf`) and otherwise
  reads the publisher/arXiv HTML of the same paper, citing the PDF in
  Sources. It must state which route it used.
- **Sidebar last per wave.** Pages join `docs/.vitepress/sidebar.json`
  (grouped: Foundations / Engines / Generators & Executors / Nix & Dynamic
  Derivations / Themes / Synthesis) only once they exist, so the docs build
  never sees a dead link.

## 7. Validation checklist (per wave)

- [ ] `yarn docs:build` green; new pages registered in the sidebar.
- [ ] `dub run :ci -- --check-docs-sidebar` and `--check-vcs-urls` pass.
- [ ] `dub run :ci -- --check-blob-paths` — every pinned citation resolves
      against its `$REPOS` clone (unchecked repos reported as such).
- [ ] Each new deep-dive follows the §3 spine and carries ≥1 verbatim,
      cited primary-source quote.
- [ ] Umbrella/synthesis pages carry an absolute `**Last reviewed:**` date.
- [ ] Prettier/editorconfig hooks pass; literal-data tables re-checked
      after prettier.
