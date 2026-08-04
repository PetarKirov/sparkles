# Mergiraf (Rust)

A syntax-aware git merge driver that parses all three revisions with tree-sitter and merges
their ASTs via matching + PCS-triple reconciliation, falling back to line-based diff3 only
where structure cannot decide.

| Field             | Value                                                   |
| ----------------- | ------------------------------------------------------- |
| Language          | Rust (edition 2024)                                     |
| License           | GPL-3.0-only                                            |
| Repository        | [codeberg.org/mergiraf/mergiraf][repo]                  |
| Documentation     | [mergiraf.org][docs] (mdBook, sources in `doc/src/`)    |
| Category          | merge-tool (structural three-way merge driver)          |
| First release     | `v0.1.0`, 2024-11-01                                    |
| Latest release    | `v0.18.0`, 2026-07-14                                   |
| Surveyed revision | `3e61fe78e78de5b383382b3912ead3398e780913` (2026-07-26) |

## Overview

### What it solves

Git's built-in diff3 merge treats files as flat line sequences, so two textually-overlapping
but semantically-independent edits (two imports added at the same spot, a reformat on one side
plus a content change on the other, a function moved and edited) produce spurious conflicts.
Mergiraf replaces the merge with a structured one: it parses base/left/right with tree-sitter
(~45 language profiles in `src/supported_langs.rs`, from Java and Rust to `go.sum`, YAML and
Markdown), matches the three trees, merges them as sets of parent–child–successor triples, and
prints a merged file — emitting classic conflict markers only for genuinely contested regions.
It installs as a git merge driver (so `merge`, `rebase`, `cherry-pick`, `revert` all benefit)
or runs after the fact on a conflicted file via `mergiraf solve`.

The architecture follows Spork ("Spork: Structured Merge for Java with Formatting
Preservation", [arXiv:2202.05329][spork-paper]), generalized from Java-via-Spoon to any
tree-sitter grammar, with an added fast mode, delete/modify conflict detection, and a
faithfulness guarantee (no re-normalization of untouched syntax) — the differences are
enumerated in `doc/src/related-work.md`.

### Design philosophy

Two commitments recur through the docs and code. First, conservatism over cleverness —
from `doc/src/introduction.md`:

> "Syntax-aware merging heuristics can sometimes be a bit too optimistic in considering a
> conflict resolved. Mergiraf does its best to err on the side of caution and retain conflict
> markers in the file when encountering suspicious cases."

Second, language support must be data, not code — from the `LangProfile` doc comment in
`src/lang_profile.rs`:

> "Language-dependent settings to influence how merging is done. All those settings are
> declarative (except for the tree-sitter parser, which is imported from the corresponding
> crate)."

A third, operational one: be fast enough that git can spawn one process per merged file
(`doc/src/related-work.md` cites JVM startup as the reason Spork can't be a practical merge
driver). Structured merging runs under a watchdog timeout (default 5000 ms in fast mode,
10000 ms for a full merge, `src/main.rs`) after which Mergiraf yields to git's own result.

## How it works

### 1. Diff computation & data model

There is no pairwise "diff" artifact; the core data model is a **three-way tree matching**
computed in-process:

- **Parsing** (`src/ast.rs`): each revision is parsed by tree-sitter into an arena-allocated
  `AstNode` tree (`typed-arena`). Every node carries a precomputed `hash` that is _invariant
  under isomorphism_ — leaves hash their token text, internal nodes hash `(kind, child
hashes)`; byte ranges and ids are deliberately excluded (`internal_finalize`). Leaves that
  span multiple lines (block comments, string literals) are split into per-line
  `@virtual_line@` child nodes with _left-trimmed_ sources, so they merge line-by-line
  instead of atomically.
- **Matching** (`src/tree_matcher.rs`): the GumTree-classic algorithm — a top-down pass
  matching sufficiently deep, unique isomorphic subtrees (via the hashes), then a bottom-up
  pass matching ancestors by the proportion of matched descendants, plus a tree-edit-distance
  "last chance" refinement. Base↔left and base↔right are matched in parallel threads with a
  _primary_ (more aggressive) matcher; left↔right uses an _auxiliary_ conservative matcher
  seeded by composing the two base matchings (`src/merge_3dm.rs::generate_matchings`).
- **Class mapping** (`src/class_mapping.rs`): the union of the three matchings is closed into
  equivalence classes; each class elects a _leader_ (base ≻ left ≻ right) that stands for the
  node in the rest of the pipeline.
- **PCS triples** (`src/pcs.rs`, `src/changeset.rs`): each tree becomes a set of
  `(parent, child, successor)` triples over leaders, with `⊣`/`⊢` sentinels per child list,
  tagged by revision. The union is cleaned by deleting base-revision triples inconsistent
  with left/right ones; remaining inconsistencies surface during tree reconstruction
  (`src/tree_builder.rs`) as conflicts or local diff3 fallbacks.

The only classical text diff is the line-based diff3 itself, delegated to the `diffy-imara`
crate with `Algorithm::Histogram` (`src/line_based.rs`).

### 2. Rendering & layout

Mergiraf renders a merged _file_, not a visual diff — there are no panes, gutters or
highlighting. Rendering (`src/merged_tree/print.rs`, `src/merged_text.rs`) still solves two
non-trivial layout problems:

- **Whitespace reconstruction**: whitespace lives between tokens and is absent from the AST,
  so the printer re-derives it by _imitation_: for each pair of adjacent output nodes it looks
  up the inter-node whitespace in every revision where both nodes exist
  (`add_preceding_whitespace`/`whitespace_at_rev`), preferring the revision that changed the
  whitespace (i.e. the reformatter), and re-indents relocated subtrees by replacing the
  ancestor indentation prefix (`AstNode::reindented_source`).
- **Conflict rendering**: because structural conflicts can be narrower than a line (one
  argument of a call), the merged stream is post-processed into either the **default mode** —
  markers expanded to full-line boundaries, matching git's conventions — or `--compact` mode,
  which allows markers mid-line at the cost of formatting fidelity
  (`MergedText::render_full_lines` vs `render_compact`). Marker size and `diff3` style are
  honored from settings/gitattributes.

The one visual surface is `mergiraf review`, which shells out to
`git diff --no-index <line-based merge> <mergiraf merge>` (`src/attempts.rs::review_merge`)
so the user's configured pager/diff UI displays what Mergiraf did beyond plain git.

### 3. Intra-line & noise handling

Formatting noise is neutralized _structurally_ rather than by diff postprocessing:

- Inter-token whitespace never enters the AST, and node hashes ignore it, so a
  formatting-only change yields trees isomorphic to the base — matched exactly, merged with
  zero conflict. The reformatter's whitespace is then preferred at print time (see the
  explicit heuristic comment in `print.rs`: "If whitespace only changed in the right
  revision, then the right revision is likely doing some reformatting, so keep its
  whitespace"). `doc/src/conflicts.md` § "Conflicting formatting and content changes"
  documents the resulting behavior: one side reformats, the other edits content, both
  survive.
- **Commutative parents** (`src/lang_profile.rs`): per-language declarations that a node's
  child order is irrelevant — Java imports, class members, JSON/YAML object keys, Rust
  `use` lists — identified either by node kind (`ParentType::ByKind`) or by a tree-sitter
  query for context-dependent cases (`ParentType::ByQuery`, e.g. a Python list only when
  assigned to `__all__`). Each declares its separator and delimiters (so a synthesized
  `CommutativeChildSeparator` can be inserted between merged-in children) and optional
  `ChildrenGroup` restrictions limiting which child kinds may commute with each other.
  Insertions on both sides into such a parent merge order-insensitively instead of
  conflicting.
- **Signatures** (`src/signature.rs`): declarative key paths (e.g. a Java method's name +
  parameter types) that uniquely identify children of a commutative parent; a post-pass
  (`src/merged_tree/postprocess.rs`) groups children with duplicate signatures into a
  conflict — catching the "both sides added the same method" hazard that naive structured
  merge silently duplicates.
- **Moved-code handling** exists for _merge_ purposes: delete/modify checking computes a
  covering of edited descendants that survive in the deleting revision — if the edits all
  land inside moved subtrees the merge is accepted, otherwise a conflict is reinstated
  (`doc/src/architecture.md` § delete/modify).
- There is no word/char-level diff refinement anywhere — the finest text granularity is the
  per-line splitting of multi-line leaves.

### 4. Navigation, folding & scale

Not an interactive viewer, so hunk navigation, folding and file trees do not apply. The
scale guards are batch-oriented:

- A watchdog thread runs the structured cascade and is abandoned on timeout
  (`src/merge.rs::cascading_merge`, `oneshot::recv_timeout`), returning git's own line-based
  result — bounding worst-case latency per file during a large rebase.
- **Fast mode** (default when invoked as a driver): line-based merge runs first; if clean,
  done. If conflicted, fictional base/left/right revisions are _reconstructed from the
  conflicted output_ (`src/parsed_merge.rs`), and every syntax element lying wholly in
  non-conflict regions is pre-matched across all three trees, so GumTree only works on the
  conflict neighborhoods (`doc/src/architecture.md` § "Fast mode"). `--full-merge` forces
  the ground-up structured merge.
- Base↔left and base↔right matchings run on parallel scoped threads.

### 5. VCS & review integration

The deepest-integrated subject in this survey:

- **Merge-driver protocol**: registered in git config as
  `driver = mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L` plus a
  `* merge=mergiraf` gitattribute (`doc/src/usage.md`); `%P` supplies the real path for
  language detection, `%S/%X/%Y` the conflict-marker labels, `%L` the marker size. `mergiraf
languages --gitattributes` prints a ready-to-paste attributes file. The `mergiraf=0`
  environment variable is a per-invocation kill switch. Jujutsu is supported via
  `jj resolve --tool mergiraf`.
- **Gitattributes as config**: per-path `mergiraf.language` (with `linguist-language`
  fallback), `conflict-marker-size`, and parse-error tolerance are read from git attributes
  (`src/git.rs` `attr` module) and merged with CLI flags (`src/solve.rs::create_settings`).
- **`mergiraf solve`** — the post-hoc flow — is a cascade (`src/solve.rs::do_solve`) that
  keeps the best of up to four candidates: (1) resolve directly from the conflicted file's
  reconstructed revisions; (2) recover the true revisions from the index via
  `git checkout-index --stage=all` (`src/git.rs::extract_all_revisions_from_git`); (3) if the
  conflict labels are 40-hex OIDs (as in `git rebase`), fetch blob contents from those
  commits (`ParsedMerge::extract_conflict_oids` + `read_content_from_commits`); (4) the
  original conflicted file itself as the floor. Candidates are ranked by `conflict_mass`
  (total conflict byte weight), with syntactically-suspect merges (`has_additional_issues`)
  deprioritized.
- **The review flow**: when the driver fully solves conflicts that line-based merge could
  not, it stores base/left/right, the line-based merge, and its own output in a bounded
  XDG cache (`AttemptsCache`, 128 entries, `src/attempts.rs`) and prints
  `Solved N conflicts. Review with: mergiraf review <file>_<uid>`; `review` then diffs
  line-based vs structured output. `mergiraf report` packages the same attempt into a
  reproducible bug-report archive (`src/bug_reporter.rs`).
- No PR/forge integration of any kind — this is a local-merge tool; comments, revisions and
  stacks are out of scope.

### 6. Architecture & reuse

A single ~15.7 kLOC Rust binary plus a library crate (`src/lib.rs` exposes
`line_merge_and_structured_resolution`, `resolve_merge_cascading`, `LangProfile`, etc. — the
`mgf_dev` helper binary consumes it for grammar development). Grammars are static-linked
crates, not dlopened. Notably reusable ideas, mostly independent of the merge use case:

- The **declarative language profile** (`LangProfile`: atomic nodes, commutative parents
  with separators/delimiters/groups, signatures as field paths, injection queries, flattened
  nodes) — a compact vocabulary for "what edits to this tree are order-independent /
  identity-bearing", validated against the live grammar by `check_kinds` tests.
- The **isomorphism-invariant node hash** enabling O(1) subtree equality, and the
  **multi-line-leaf → virtual line nodes** trick giving line granularity inside opaque
  tokens.
- The **whitespace-imitation printer**, which reconstructs plausible formatting for a tree
  assembled from three differently-formatted sources.
- `ParsedMerge` — a parser that turns a conflict-markered file back into structured chunks
  and can reconstruct each side (`reconstruct_revision`), including OID recovery from
  marker labels.
- The `AttemptsCache` review pattern (persist competing merge candidates, invite a diff).

Language injections (`injections` query per profile, e.g. Markdown code fences) parse
embedded languages with their own profiles, so commutativity/signature knowledge applies
inside host documents.

> [!NOTE]
> Markdown is a supported profile (`src/supported_langs.rs`): `pipe_table_cell`,
> `pipe_table_delimiter_cell`, `inline`, and fence contents are atomic nodes; only
> `link_reference_definition`s commute. Table _rows_ are ordered structure, so Mergiraf
> merges tables structurally per cell/row but declares no table-specific smartness beyond
> atomicity.

## Strengths

- Whole categories of textual conflicts (adjacent insertions, reorderable members,
  reformat-vs-edit, move-and-edit) vanish, with the merged output preserving each side's
  formatting — no re-printing normalization.
- Deliberately conservative: delete/modify and duplicate-signature post-passes _add_
  conflicts that naive 3DM merge (and Spork) silently mis-resolve; the cascade never
  returns something worse than git's own merge, and the timeout bounds latency.
- Language support is a declarative table entry plus a grammar crate — ~45 languages from
  one algorithm, with tree-sitter queries handling context-dependent commutativity.
- Excellent operational ergonomics: standard merge-driver protocol, gitattributes-driven
  per-path config, an escape hatch (`mergiraf=0`), a post-hoc `solve` mode that works even
  from nothing but a conflicted file, and a built-in review + bug-report loop.
- Fast mode reuses git's own line-based result to shrink the structured problem to the
  conflicted neighborhoods.

## Weaknesses

- Any parse error in any revision (unless `allow_parse_errors`) aborts structured merging —
  fine as a merge driver fallback, but it means the structural machinery is all-or-nothing
  per file.
- Whitespace reconstruction is heuristic and admittedly "bound to produce imperfect
  formatting in certain cases" (`doc/src/conflicts.md`); the tool recommends an enforced
  formatter as the real fix.
- Merge quality is only as good as the profile: a language without commutative-parent /
  signature declarations gets little beyond formatting tolerance; declarations are
  hand-curated and can drift from grammar updates (mitigated by `check_kinds` tests).
- Single-file scope: no cross-file move detection (IntelliMerge territory), no rename
  integration, no forge/PR layer.
- The left↔right matcher must be deliberately weakened to avoid false matches, so identical
  twin changes on both sides are under-exploited by design (`doc/src/architecture.md`).

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                      | Trade-off                                                                                            |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Tree-sitter grammars + declarative `LangProfile` per language      | One algorithm scales to ~45 languages; profiles are data, reviewable and testable              | Grammar quirks leak in (atomic-node lists, `allow_parse_errors` for lenient grammars); curation cost |
| PCS-triple changeset merge (3DM/Spork lineage)                     | Uniform set-union semantics for tree merging; move handling falls out of the representation    | Inconsistency taxonomy is subtle; several cases punt to local diff3 inside the reconstructed node    |
| Whitespace excluded from AST, reconstructed by imitation at print  | Formatting-only edits become structurally invisible; reformat + edit merges cleanly            | Printer heuristics can emit imperfect indentation; no guarantee of formatter-idempotent output       |
| Line-based merge first, structured merge only on residual conflict | Matches git behavior/latency in the common case; conflict regions localize the expensive match | Some resolutions (moving edited elements) are unreachable in fast mode; two code paths to maintain   |
| Timeout watchdog with fallback to git's result                     | A merge driver must never hang a 300-file rebase                                               | Big files silently lose structured merging; result depends on machine speed                          |
| Elect class _leaders_ (base ≻ left ≻ right) for node identity      | Collapses three trees into one id space; simplifies PCS and printing                           | Leader choice is a hidden bias; left↔right-only matches get second-class treatment                   |
| Extra conflicts re-inserted (delete/modify, duplicate signatures)  | "Err on the side of caution" — never silently drop or duplicate a change                       | More conflicts than a maximally optimistic merger; covering computation adds complexity              |
| Review = `git diff --no-index` of line-based vs structured output  | Zero UI to build; user's own diff tooling; auditable cache of attempts                         | No in-context review, no per-resolution accept/reject, cache is time-bounded (128 entries)           |

## Sources

- Local checkout at `/home/petar/code/repos/rust/mergiraf` @ `3e61fe78e78de5b383382b3912ead3398e780913` (2026-07-26): `src/merge_3dm.rs`, `src/tree_matcher.rs`, `src/class_mapping.rs`, `src/pcs.rs`, `src/tree_builder.rs`, `src/lang_profile.rs`, `src/supported_langs.rs`, `src/signature.rs`, `src/ast.rs`, `src/merged_tree/print.rs`, `src/merged_text.rs`, `src/line_based.rs`, `src/parsed_merge.rs`, `src/solve.rs`, `src/merge.rs`, `src/git.rs`, `src/attempts.rs`, `src/main.rs`
- In-tree book: `doc/src/architecture.md`, `doc/src/usage.md`, `doc/src/conflicts.md`, `doc/src/related-work.md`, `doc/src/introduction.md`, `doc/src/adding-a-language.md`
- [Mergiraf documentation site][docs]
- [Spork paper (arXiv:2202.05329)][spork-paper] — the algorithmic lineage

<!-- References -->

[repo]: https://codeberg.org/mergiraf/mergiraf
[docs]: https://mergiraf.org/
[spork-paper]: https://arxiv.org/abs/2202.05329
