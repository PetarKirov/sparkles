# Grounding ledger — `zig-tokenizer.md`

Verification of `docs/research/parsing/zig-tokenizer.md` against the **local** source
`$REPOS/zig/zig/lib/std/zig/tokenizer.zig` (+ `LICENSE`, `Ast.zig`) in the pinned
`$REPOS/zig/zig` checkout. `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                                               | Type              | Source (local + locator)                                                                                             | Status       |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------- | ------------ |
| 1   | `Token = struct { tag: Tag, loc: Loc }`, `Loc = struct { start: usize, end: usize }` — tag + byte range only (zero-copy)                            | QUOTE-code        | `tokenizer.zig:3-10`                                                                                                 | ✓            |
| 2   | Keywords via `pub const keywords = std.StaticStringMap(Tag).initComptime(.{ … })` — compile-time, no heap                                           | QUOTE-code        | `tokenizer.zig:15` (`StaticStringMap`)                                                                               | ✓            |
| 3   | `pub fn next(self: *Tokenizer) Token` is a table-free hand-written state machine using the labeled-`switch` idiom `state: switch (State.start) {…}` | fact + QUOTE-code | `tokenizer.zig:391,399`; `const State = enum` at `:342`                                                              | ✓            |
| 4   | Character-class dispatch (`'a'...'z','A'...'Z','_'` → identifier; digits → number; `"`/`'` → string/char; operators)                                | fact              | `tokenizer.zig:401-485` (switch arms)                                                                                | ✓            |
| 5   | Invalid bytes → `.invalid` token; the lexer never fails/allocates (emits invalid + continues)                                                       | fact              | `tokenizer.zig` invalid-token doc-comment contract                                                                   | ✓            |
| 6   | No heap allocation anywhere; operates on `[:0]const u8` (sentinel-0 buffer, EOF branch)                                                             | fact              | `tokenizer.zig` (sentinel-0 handling)                                                                                | ✓            |
| 7   | License MIT (Expat) — "The MIT License (Expat) … Copyright (c) Zig contributors"                                                                    | fact              | `$REPOS/zig/zig/LICENSE`                                                                                             | ✓            |
| 8   | Feeds a hand-written recursive-descent `Parse.zig` → compact `Ast` (MultiArrayList, index nodes)                                                    | fact              | `Ast.zig` top doc + `MultiArrayList` (Parse.zig **not** opened — RD characterization from Ast import + known design) | ≈ (see D-Z1) |
| 9   | AST `TokenList` stores only `tag` + `start` offset (not the full range)                                                                             | fact              | `Ast.zig` (TokenList layout)                                                                                         | ✓            |
| 10  | Relevance-to-Sparkles: the survey's cleanest hand-written, allocation-free lexer model                                                              | interp            | synthesis                                                                                                            | ◯            |
| 11  | Strengths / Weaknesses / trade-off tables                                                                                                           | synth             | derived                                                                                                              | ◯            |

## Discrepancies

**D-Z1 (scope caveat, not an error).** The "hand-written recursive-descent parser" characterization of
`Parse.zig` is asserted from the `Ast.zig` import + well-known Zig design; `Parse.zig` itself was **not**
opened. One sentence of context; not load-bearing for the lexer page. Flagged by the author.

**Note (avoided fabrication).** `StaticStringMap` is described as a compile-time-built static string map
(no runtime init, no heap) but **not** as a "perfect-hash" map — the tokenizer file shows only the call
site, not the internal hashing strategy, so the perfect-hash claim was deliberately omitted rather than
guessed. (Correct: Zig's `StaticStringMap` is a length-bucketed lookup, not a perfect hash.)

## Web-fallback / not-locally-groundable

- None material — everything is in the pinned Zig checkout.

## Opinion (◯)

- The Ragel/re2c/simdjson contrast and the Sparkles-relevance note; Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. Every code quote (`Token`/`Loc`, `StaticStringMap`, the labeled-`switch` state
machine) is verbatim from `tokenizer.zig`; MIT/Expat license exact. The single caveat (unread `Parse.zig`)
is a one-sentence context claim, honestly flagged, and the perfect-hash trap was correctly avoided.
