# Grounding ledger — `roslyn.md`

Claim-by-claim verification of `docs/research/parsing/roslyn.md` against the **local**
pinned source tree `$REPOS/dotnet/roslyn` `e42c3902` (2026-07-02). `$REPOS = /home/petar/code/repos`.
Primary docs used: `docs/compilers/Design/Red-Green Trees.md`, `docs/compilers/Design/Incremental Parser.md`,
`docs/wiki/Roslyn-Overview.md`, `License.txt`.

Status key: ✓ verified verbatim/exact · ≈ accurate paraphrase / abridged-but-faithful ·
⚠ discrepancy · ◯ opinion/interpretation · 🌐 web/secondary (not locally groundable).

| #   | Claim                                                                                                                                                                                                  | Type       | Source (local + locator)                                        | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | --------------------------------------------------------------- | ------ |
| 1   | License MIT ("The MIT License (MIT) … Copyright (c) .NET Foundation and Contributors")                                                                                                                 | fact       | `License.txt:1` "The MIT License (MIT)"                         | ✓      |
| 2   | Compilers themselves written in C#/VB; subject = C# front-end + syntax model                                                                                                                           | fact       | repo layout `src/Compilers/{CSharp,VisualBasic}`                | ✓      |
| 3   | Mission quote: "compilers are black boxes — source code goes in one end … through Roslyn, compilers become platforms — APIs …"                                                                         | QUOTE      | `docs/wiki/Roslyn-Overview.md` (opening)                        | ✓      |
| 4   | Incremental parser: "typical edit allocates only bytes: a handful of new parent nodes and some pointers"                                                                                               | QUOTE      | `docs/compilers/Design/Incremental Parser.md:64`                | ✓      |
| 5   | The **blender** supplies tokens/nodes from the old tree or the lexer; maintains a cursor into the old tree                                                                                             | fact+QUOTE | `Incremental Parser.md:119,122,125`                             | ✓      |
| 6   | Green nodes = "internal, immutable representation … store only their syntactic kind, their width (character count), and their children. They do not store absolute text positions or parent pointers." | QUOTE      | `Red-Green Trees.md` §"The Red/Green Pattern"                   | ✓      |
| 7   | Red nodes = public wrappers computing `Span`/`Parent` on demand                                                                                                                                        | fact       | `Red-Green Trees.md` §"The Red/Green Pattern"                   | ✓      |
| 8   | Green structure is "a directed acyclic graph (DAG), not a tree" — shared within & across trees                                                                                                         | QUOTE      | `Red-Green Trees.md` §"Intra-Tree Sharing"                      | ✓      |
| 9   | Incremental re-parses "complete in microseconds with memory reuse approaching 99.99% for typical edits."                                                                                               | QUOTE      | `Red-Green Trees.md` §"Incremental Parsing and Subtree Reuse"   | ✓      |
| 10  | Green node caching: only nodes with "3 or fewer children" eligible; cache = 65,536 entries; "55% cache hit rate"                                                                                       | QUOTE/fig  | `Red-Green Trees.md` §"Green Node Caching"                      | ✓      |
| 11  | List opts: empty=null; singleton=direct child; 2/3/4 specialized (`WithTwoChildren`…); "90% or more of lists contain 4 elements or fewer"                                                              | fact/QUOTE | `Red-Green Trees.md` §"List Optimizations"                      | ✓      |
| 12  | "Tokens, lists, and trivia typically constitute 75% or more of a syntax tree's elements" → no red allocations                                                                                          | QUOTE      | `Red-Green Trees.md` §"Everything Is a Node at the Green Level" | ✓      |
| 13  | Full fidelity: "every character from the source file is represented somewhere in the tree … Concatenating all tokens and trivia in order reproduces the original source exactly."                      | QUOTE      | `Red-Green Trees.md` §"Full Fidelity"                           | ✓      |
| 14  | Green nodes "fully immutable. Once created, a green node never changes"; `WithXxx` reallocs only root-to-edit spine                                                                                    | QUOTE      | `Red-Green Trees.md` §"Immutability"                            | ✓      |
| 15  | Red node creation lazy + cached (reference identity for `SyntaxNode`; structs need no cache)                                                                                                           | fact       | `Red-Green Trees.md` §"Red Node Creation: Lazy and Cached"      | ≈      |
| 16  | Hand-written recursive-descent parser, "mostly context-free"                                                                                                                                           | fact       | `Red-Green Trees.md` / compiler design docs; parser is RD       | ≈      |
| 17  | Incremental reuse keyed on the `TextChange`; unchanged green nodes reused by object identity                                                                                                           | fact       | `Incremental Parser.md` (blender + cursor over old tree)        | ≈      |
| 18  | Immutable `Compilation` snapshots + workspace model, not a general memoized-query engine (contrast rust-analyzer)                                                                                      | interp     | cross-page framing; `Red-Green Trees.md` scope                  | ◯      |
| 19  | Design "popularized" red-green; `rowan`/Lezer are later descendants                                                                                                                                    | interp     | community history                                               | ◯      |
| 20  | Weakly-held red children for large blocks (GC-reclaimable) — current usage: member/accessor blocks                                                                                                     | fact       | `Red-Green Trees.md` §"Weakly-held red children"                | ✓      |
| 21  | "More than a decade in production", versioned with C#/.NET SDK                                                                                                                                         | fact       | 🌐 project history (Roslyn CTP 2011, OSS 2014)                  | 🌐     |
| 22  | Strengths / Weaknesses / trade-off tables                                                                                                                                                              | synthesis  | derived from verified rows                                      | ◯      |

## Discrepancies

None. Every blockquote in the page was matched against `Red-Green Trees.md`, `Incremental Parser.md`,
or `Roslyn-Overview.md` in the pinned tree and is verbatim; numeric figures (99.99%, 65,536, 55%, 75%,
90%, "3 or fewer children") are quoted exactly from `Red-Green Trees.md`.

## Web-fallback / not-locally-groundable

- **Maturity framing** ("more than a decade in production", Roslyn CTP 2011 / open-sourced 2014, Anders
  Hejlsberg association) — project history, not in the pinned tree. The page keeps the metadata **Key
  authors** row generic ("Microsoft — the .NET Foundation and Contributors"), which `License.txt`
  supports, and does not assert a Hejlsberg quote. Milestone dates (2011/2014) live only in `index.md`'s
  timeline and are widely attested but web-sourced.

## Opinion (◯) — legitimate survey voice

- "the design that took the red-green model … into a mainstream production compiler" (positioning).
- Roslyn's incrementality is "concentrated in the parse" vs. a general query engine (rows 18–19).
- Strengths/Weaknesses/Key-design-decision tables (row 22).

**Net:** 0 discrepancies. All load-bearing quotes and figures verbatim-grounded in the pinned
`docs/compilers/Design/` notes; only the decade-in-production / CTP-date framing is web-attested.
