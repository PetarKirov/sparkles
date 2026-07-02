# Grounding ledger — `lezer.md`

Claim-by-claim verification of `docs/research/parsing/lezer.md` against **local** pinned sources.
`$REPOS = /home/petar/code/repos`.

- `$REPOS/js/lezer-lr` `ed59b8b` (2026-04-15) — `README.md`, `package.json`, `LICENSE`, `src/{parse,stack,token,constants}.ts`, `CHANGELOG.md`
- `$REPOS/js/lezer-common` `d87b56c` (2026-04-15) — `src/tree.ts`

Status key: ✓ verified verbatim/exact · ≈ accurate paraphrase / abridged-but-faithful ·
⚠ discrepancy · ◯ opinion/interpretation · 🌐 web/secondary (not locally groundable).

| #   | Claim                                                                                                                                                    | Type       | Source (local + locator)                                                                                   | Status   |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------- | -------- |
| 1   | "incremental GLR parser intended for use in an editor … keep a representation of the program current during changes and in the face of syntax errors."   | QUOTE      | `lezer-lr/README.md`                                                                                       | ✓        |
| 2   | "prioritizes speed and compactness … over having a highly usable parse tree—trees nodes are just blobs with a start, end, tag, and set of child nodes …" | QUOTE      | `lezer-lr/README.md`                                                                                       | ✓        |
| 3   | "This project was hugely inspired by tree-sitter."                                                                                                       | QUOTE      | `lezer-lr/README.md`                                                                                       | ✓        |
| 4   | License MIT; © 2018 Marijn Haverbeke                                                                                                                     | fact       | `lezer-lr/LICENSE:1` "Copyright (C) 2018 by Marijn Haverbeke … and others"                                 | ✓        |
| 5   | `@lezer/lr` version `1.4.8`                                                                                                                              | fact       | `lezer-lr/package.json` `"version": "1.4.8"`                                                               | ✓        |
| 6   | On-disk table format `File.Version = 14`, checked at `LRParser` construction                                                                             | fact       | `lezer-lr/src/constants.ts:102-103` `enum File { Version = 14 }`                                           | ✓        |
| 7   | `@lezer/generator` compiles grammar → LR table ahead of time; `@lezer/lr` drives it with a generalized LR loop                                           | fact       | `lezer-lr/README.md`; `src/parse.ts`                                                                       | ✓        |
| 8   | GLR forking: on a table conflict the parser forks; live parse "versions" = array of `Stack`s advanced in `advance()`                                     | fact       | `src/parse.ts` (`Parse.advance`); `src/stack.ts`                                                           | ≈        |
| 9   | `Stack` = one GLR parse version (state stack + shared output buffer + score)                                                                             | fact       | `src/stack.ts` (`Stack` class)                                                                             | ✓        |
| 10  | Big-reduction threshold `Recover.MinBigReduction = 2000` (reuse/score logic)                                                                             | QUOTE-code | `src/stack.ts:469` (`MinBigReduction = 2000`), used `:119`                                                 | ✓        |
| 11  | Compact tree: `Tree` + `TreeBuffer` pack small nodes into a flat buffer (contrast tree-sitter inline `Subtree`)                                          | fact       | `lezer-common/src/tree.ts` (`Tree`, `TreeBuffer`)                                                          | ≈        |
| 12  | Incremental reuse via `TreeFragment` (`applyChanges`/`addTree`); reuse decided by the automaton via `goto`                                               | fact       | `lezer-common/src/parse.ts:25,69,78` (`class TreeFragment`, `addTree`, `applyChanges`) — **not** `tree.ts` | ✓ (D-L1) |
| 13  | Fragment reuse "used to limit reuse of contextual nodes" (openStart/openEnd margins)                                                                     | QUOTE≈     | `lezer-common/src/tree.ts:105-107` (doc comment)                                                           | ✓        |
| 14  | Contextual/external tokenizers (token groups, context)                                                                                                   | fact       | `src/token.ts`; `src/parse.ts`                                                                             | ≈        |
| 15  | Error recovery (forced reduce / skip; error-tolerant tree)                                                                                               | fact       | `src/parse.ts` (`recover*`)                                                                                | ≈        |
| 16  | Created by Marijn Haverbeke (CodeMirror/ProseMirror/Acorn author) as CodeMirror 6's parsing layer                                                        | fact       | `LICENSE` © Marijn Haverbeke; CodeMirror link = 🌐                                                         | 🌐       |
| 17  | Canonical repo moved GitHub → `code.haverbeke.berlin/lezer/lr`; GitHub `lezer-parser/lr` is a mirror                                                     | fact       | `lezer-lr/README.md` (banner "This repository has moved …")                                                | ✓        |
| 18  | `1.4.x` line (`1.4.8`, 2026-01-25); CHANGELOG = steady small bug-fix releases                                                                            | fact       | `package.json` (1.4.8); `CHANGELOG.md` (date = 🌐/tag)                                                     | ≈        |
| 19  | Strengths / Weaknesses / trade-off tables                                                                                                                | synthesis  | derived from verified rows                                                                                 | ◯        |

## Discrepancies

**D-L1 (ledger locator, self-corrected).** Row 12 originally cited `TreeFragment` to
`lezer-common/src/tree.ts`; the class + `addTree`/`applyChanges` actually live in
`lezer-common/src/parse.ts:25,69,78` (`tree.ts` holds only `Tree`/`TreeBuffer` + the
`:107` "contextual nodes" doc comment cited in row 13). Locator fixed; the page
`lezer.md` already cites the correct `parse.ts` path (with an inline `[!IMPORTANT]` note),
so no page change was needed. No content claim was affected.

Otherwise none. All README quotes are verbatim; the version (`1.4.8`), the on-disk format
(`File.Version = 14`), `MinBigReduction = 2000`, and the LICENSE year/author are exact
against the pinned trees.

## Web-fallback / not-locally-groundable

- **CodeMirror 6 positioning / ecosystem** — the CodeMirror project relationship is external context
  (`codemirror.net`); the Haverbeke authorship is grounded in `LICENSE`, but "author of CodeMirror,
  ProseMirror, Acorn" is biographical/web.
- **Release date `2026-01-25`** for `1.4.8` — from npm/CHANGELOG metadata; `package.json` grounds the
  version string but not the publish date (treat the date as secondary).

## Opinion (◯) — legitimate survey voice

- "a second, independent incremental engine to contrast with tree-sitter" (positioning).
- Compactness-vs-usability framing of the blob tree; Strengths/Weaknesses/trade-off tables (row 19).

**Net:** 0 discrepancies. Every README quote and every code constant (`File.Version = 14`,
`MinBigReduction = 2000`) is verbatim-grounded in the pinned trees; only the CodeMirror biographical
context and the `1.4.8` publish date are web-attested.
