# Parsing survey — grounding ledger

Claim-by-claim source verification of every page under `docs/research/parsing/`. Each page
has a `<page>.md` ledger; every material assertion is checked against a **local** primary
artifact (paper in `$REPOS/papers/parsing/` or a repo pinned in [`_sources.md`](./_sources.md)).
Web is fallback-only. This tree is internal QA evidence — excluded from the VitePress build
(`srcExclude`) and from lychee (`exclude_path`).

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)                           |
| `⚠`  | Discrepancy — wrong/misattributed/fabricated; correction recorded + applied to the doc |
| `◯`  | Not locally groundable — editorial/opinion, or source unobtainable (fallback named)    |

**Types:** `quote` · `fact` (date/author/venue/attribution) · `figure` (number/bound) ·
`behavior` (tool does X) · `exposition` (textbook-standard) · `opinion`.

## Per-page ledgers

| Page                    | Ledger                                                     | Rows | ⚠   | ◯                | Status    |
| ----------------------- | ---------------------------------------------------------- | ---- | --- | ---------------- | --------- |
| theory/formal-languages | [theory-formal-languages.md](./theory-formal-languages.md) | full | 2   | several          | ✅ B1     |
| theory/top-down         | [theory-top-down.md](./theory-top-down.md)                 | full | 2   | RS70             | ✅ B1     |
| theory/bottom-up        | [theory-bottom-up.md](./theory-bottom-up.md)               | full | 4   | Tomita/Pager     | ✅ B1     |
| theory/general-parsing  | [theory-general-parsing.md](./theory-general-parsing.md)   | full | 0   | Leo/Marpa/GLL    | ✅ B1     |
| theory/peg-packrat      | [theory-peg-packrat.md](./theory-peg-packrat.md)           | full | 5   | Medeiros         | ✅ B2     |
| theory/pratt-precedence | [theory-pratt-precedence.md](./theory-pratt-precedence.md) | full | 2   | blogs            | ✅ B2     |
| theory/derivatives      | [theory-derivatives.md](./theory-derivatives.md)           | full | 0   | Antimirov/blog   | ✅ B2     |
| theory/incremental      | [theory-incremental.md](./theory-incremental.md)           | full | 0   | Adapton biblio   | ✅ B6     |
| theory/index            | [theory-index.md](./theory-index.md)                       | full | 0   | —                | ✅ B5     |
| concepts                | [concepts.md](./concepts.md)                               | full | 3   | GLL/Hopcroft     | ✅ B2     |
| comparison              | [comparison.md](./comparison.md)                           | full | 2   | Sparkles-fit     | ✅ B5     |
| index                   | [page-index.md](./page-index.md)                           | full | 2   | biblio dates     | ✅ B5     |
| simdjson                | [simdjson.md](./simdjson.md)                               | full | 5   | port provenance  | ✅ B3     |
| tree-sitter             | [tree-sitter.md](./tree-sitter.md)                         | full | 1   | talk/wiki        | ✅ B3     |
| antlr                   | [antlr.md](./antlr.md)                                     | full | 5   | adopters         | ✅ B3     |
| bison-yacc              | [bison-yacc.md](./bison-yacc.md)                           | full | 2   | Johnson/Lemon    | ✅ B3     |
| menhir                  | [menhir.md](./menhir.md)                                   | full | 3   | blog/C11         | ✅ B4     |
| pest                    | [pest.md](./pest.md)                                       | full | 0   | book/blog        | ✅ B4     |
| rust-nom                | [rust-nom.md](./rust-nom.md)                               | full | 3   | bench/downloads  | ✅ B4     |
| rust-chumsky            | [rust-chumsky.md](./rust-chumsky.md)                       | full | 3   | blog/adoption    | ✅ B4     |
| haskell-parsec          | [haskell-parsec.md](./haskell-parsec.md)                   | full | 1   | FlatParse/ports  | ✅ B5     |
| rust-analyzer           | [rust-analyzer.md](./rust-analyzer.md)                     | full | 0   | matklad/cadence  | ✅ B6     |
| roslyn                  | [roslyn.md](./roslyn.md)                                   | full | 0   | CTP/OSS dates    | ✅ B6     |
| lezer                   | [lezer.md](./lezer.md)                                     | full | 0   | CodeMirror bio   | ✅ B6     |
| rustc-queries           | [rustc-queries.md](./rustc-queries.md)                     | full | 0   | Matsakis/blog    | ✅ B6     |
| simd-json               | [simd-json.md](./simd-json.md)                             | full | 0   | bench/date       | ✅ B7     |
| sonic-rs                | [sonic-rs.md](./sonic-rs.md)                               | full | 0   | bench            | ✅ B7     |
| yyjson                  | [yyjson.md](./yyjson.md)                                   | full | 0   | bench            | ✅ B7     |
| rapidjson               | [rapidjson.md](./rapidjson.md)                             | full | 1   | bench (simdjson) | ✅ B7     |
| hyperscan               | [hyperscan.md](./hyperscan.md)                             | full | 0   | Vectorscan       | ✅ B7     |
| zig-tokenizer           | [zig-tokenizer.md](./zig-tokenizer.md)                     | full | 1   | Parse.zig        | ✅ B7     |
| rust-winnow             | [rust-winnow.md](./rust-winnow.md)                         | full | 0   | downloads        | ✅ B7     |
| haskell-flatparse       | [haskell-flatparse.md](./haskell-flatparse.md)             | full | 0   | bench            | ✅ B7     |
| rust-combine            | [rust-combine.md](./rust-combine.md)                       | full | 0   | downloads        | ✅ B7     |
| ocaml-angstrom          | [ocaml-angstrom.md](./ocaml-angstrom.md)                   | full | 0   | httpaf/RWO       | ✅ B7     |
| fsharp-fparsec          | [fsharp-fparsec.md](./fsharp-fparsec.md)                   | full | 0   | reputation       | ✅ B7     |
| d-landscape             | [d-landscape.md](./d-landscape.md)                         | full | 0   | dub scores       | ✅ B8     |
| syntect                 | [syntect.md](./syntect.md)                                 | full | 0   | 5.3.0 docs.rs    | ✅ B9     |
| bat                     | [bat.md](./bat.md)                                         | full | 0   | v0.1.0 date      | ✅ B9     |
| tree-sitter-highlight   | [tree-sitter-highlight.md](./tree-sitter-highlight.md)     | full | 0   | crate/GH dates   | ✅ B9     |
| shiki                   | [shiki.md](./shiki.md)                                     | full | 0   | release history  | ✅ B9     |
| syntax-highlighting     | [syntax-highlighting.md](./syntax-highlighting.md)         | full | 0   | milestone dates  | ✅ B9+B10 |
| pygments                | [pygments.md](./pygments.md)                               | full | 0   | 2006 date        | ✅ B10    |
| chroma                  | [chroma.md](./chroma.md)                                   | full | 0   | 2017 dates       | ✅ B10    |
| helix                   | [helix.md](./helix.md)                                     | full | 0   | tree-house split | ✅ B10    |
| linguist                | [linguist.md](./linguist.md)                               | full | 0   | 2011 date        | ✅ B10    |
| highlight-js            | [highlight-js.md](./highlight-js.md)                       | full | 0   | 2006 day soft    | ✅ B10    |
| lezer-highlight         | [lezer-highlight.md](./lezer-highlight.md)                 | full | 0   | npm dates        | ✅ B10    |
| lsp-semantic-tokens     | [lsp-semantic-tokens.md](./lsp-semantic-tokens.md)         | full | 0   | VS Code dates    | ✅ B10    |
| intellij-highlighting   | [intellij-highlighting.md](./intellij-highlighting.md)     | full | 0   | IDEA day soft    | ✅ B10    |
| vim-emacs-syntax        | [vim-emacs-syntax.md](./vim-emacs-syntax.md)               | full | 0   | release dates    | ✅ B10    |

## Master discrepancy register

Union of all `⚠` rows. Populated as each batch lands.

| #   | Page                    | Claim                                                                | Correction                                     | Source                          | Fixed?      |
| --- | ----------------------- | -------------------------------------------------------------------- | ---------------------------------------------- | ------------------------------- | ----------- |
| R1  | theory/general-parsing  | Fabricated "Earley abstract" quote ("…linear for almost all LR(k)…") | Replaced with verbatim abstract                | `earley-1970-…pdf` p.94         | ✓ `68bbd78` |
| R2  | theory/pratt-precedence | Associativity inverted (left-assoc said "stronger on left")          | left-assoc ⇒ higher **right** bp; mirror fixed | `pratt-1973-…pdf`; matklad code | ✓ `68bbd78` |
| R3  | theory/derivatives      | "two years before Younger's CYK"                                     | three years (1964→1967)                        | bibliographic                   | ✓ `68bbd78` |
| R4  | simdjson                | "correctly-rounded to within 1 ULP"                                  | nearest representable (½ ULP)                  | `langdale-lemire-2019`          | ✓ `68bbd78` |
| R5  | simdjson                | integer range `[−2^63, 2^63)`                                        | `[−2^63, 2^64)` (unsigned 64-bit)              | simdjson repo                   | ✓ `68bbd78` |
| R6  | haskell-parsec          | Hutton & Meijer 1996/1998 citation conflation                        | split tech-report vs JFP paper                 | `hutton-meijer-1996`            | ✓ `68bbd78` |
| R7  | theory/top-down         | Rosenkrantz & Stearns link = STOC 1969, not 1970 journal             | repointed to Inf.&Control                      | bibliographic                   | ✓ `68bbd78` |

### Batch 1 (theory core)

| #   | Page                    | Claim                                                                               | Correction                                                                    | Source                                                             | Fixed? |
| --- | ----------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------ |
| R8  | theory/formal-languages | Dragon Book quote :67–68 drops "precise"; 2nd sentence is paraphrase in quote marks | restore verbatim / demote 2nd clause to paraphrase                            | `aho-2006…` ch.4 intro                                             | ☐      |
| R9  | theory/formal-languages | Earley quote :178–179 "linear time **for** a large class"                           | "**on** a large class"                                                        | `earley-1970…` p.94                                                | ☐      |
| R10 | theory/top-down         | :111–112 GCC/Clang attributed to ALL(\*) paper (paper says javac only)              | narrow `[allstar]` cite to javac; move GCC/Clang out                          | `parr-2014…`                                                       | ☐      |
| R11 | theory/top-down         | :435–436 O(n⁴)-cost quote located §6; actually §1                                   | change locator to §1                                                          | `parr-2014…` §1                                                    | ☐      |
| R12 | theory/bottom-up        | :67 Knuth handle quote "p. 610"; opening sentence is p. 609                         | "pp. 609–610"                                                                 | `knuth-1965…` scan                                                 | ☐      |
| R13 | theory/bottom-up        | :416–418 tree-sitter quote not verbatim                                             | re-quote real DSL-doc sentence or drop quote marks                            | `…/tree-sitter/docs/src/creating-parsers/2-the-grammar-dsl.md:117` | ☐      |
| R14 | theory/bottom-up        | :291 shift/reduce + reduce/reduce "named by DeRemer & Pennello"                     | D&P use "read-reduce"/"reduce-reduce"; shift/reduce is the yacc term — reword | `deremer-pennello-1982…` §1.1                                      | ☐      |
| R15 | theory/bottom-up        | :99,322,524 "Tomita 1985" book                                                      | Kluwer book is 1986 (GLR work 1985) — reword to "1985/86" or 1986             | Grune&Jacobs bib; Springer                                         | ☐      |

Notes (no edit): Kasami CYK dated 1965 (page) vs "1969" in Grune&Jacobs bib — 1965 is conventional, keep. Leo 1991 block quote (general-parsing:264) unverifiable locally (paper unobtainable) — `◯`, secondary.

### Batch 2 (theory rest + glossary)

| #   | Page                    | Claim                                                                                                                                                              | Correction                                                                                                                 | Source                            | Fixed? |
| --- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | ------ |
| R16 | theory/peg-packrat      | :287 "main disadvantage…space" cited Ford Abstract                                                                                                                 | text is in §1 Intro                                                                                                        | `ford-2002…` §1                   | ☐      |
| R17 | theory/peg-packrat      | :371 quoted "…no guarantee…globally longest match" not in either Ford paper                                                                                        | de-quote (doc's own prose) or source it                                                                                    | —                                 | ☐      |
| R18 | theory/peg-packrat      | :481 Warth quote re-conjugated + cited §3.4                                                                                                                        | quote verbatim "we bypass…re-evaluate"; §3.3                                                                               | `warth-2008…` §3.3                | ☐      |
| R19 | theory/peg-packrat      | :483 Warth quote "can yield" vs source "to yield"                                                                                                                  | fix quote boundary                                                                                                         | `warth-2008…`                     | ☐      |
| R20 | theory/peg-packrat      | :531 `&`/`!` predicates "Parr's contribution"                                                                                                                      | only `&` is Parr's; `!` is Ford's own                                                                                      | `ford-2004…` §6                   | ☐      |
| R21 | theory/pratt-precedence | :184–185 (+:30,:135,:646–647,:688) Dragon **2nd-ed** §4.6 cited for operator-precedence + minus quote; 2nd-ed §4.6 is "Intro to LR/SLR" — quote is 1st-ed material | re-cite 1st ed OR reground in `floyd-1963` + Grune ch.9; drop verbatim quote. (§4.4 panic-mode cite :456 is correct, keep) | `floyd-1963…`; Dragon 1st ed      | ☐      |
| R22 | theory/pratt-precedence | :434 chumsky quote drops "will" ("a<b<c **will** produce an error")                                                                                                | restore "will" or de-quote                                                                                                 | `…/rust/chumsky/src/pratt.rs:485` | ☐      |
| R23 | concepts                | :62–65 Dragon CFG quote — drops "By design…precise"; 2nd sentence paraphrase-in-quotes (same root as R8)                                                           | verbatim or paraphrase outside quotes                                                                                      | `aho-2006…:12859`                 | ☐      |
| R24 | concepts                | :253 Dragon §3.1 lexer/parser lead-in misquoted                                                                                                                    | restore verbatim lead-in                                                                                                   | `aho-2006…:8473`                  | ☐      |
| R25 | concepts                | :424–427 Ford packrat quote pluralized ("Packrat parsers provide…guarantee")                                                                                       | singular: "A packrat parser provides…guarantees"                                                                           | `ford-2002…:14`                   | ☐      |

Notes (no edit): derivatives clean — Adams id `1604.04695` already correct (the `_sources.md` pre-flag is stale); naïve-PWD `O(2²ⁿG²)` confirmed. Optional acquisition to close web-fallbacks: Medeiros et al. (arXiv 1207.0443), pest book.

### Batch 3 (systems I)

| #   | Page        | Claim                                                                         | Correction                                                                                                                              | Source                               | Fixed? |
| --- | ----------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ | ------ |
| R26 | simdjson    | :130 KL21 "three table lookups" block-quote not verbatim in paper/repo        | de-quote/paraphrase or use a real KL21 quote                                                                                            | `keiser-lemire-2021…`                | ☐      |
| R27 | simdjson    | :133 "~13 GB/s" attributed to UTF-8 paper; paper says ">10 GiB/s"             | attribute 13 GB/s to README; keep "more than 10 times" on paper                                                                         | `keiser-lemire-2021…` abstract       | ☐      |
| R28 | simdjson    | :219 quote subject swapped — "both stages" vs source "All three fast parsers" | restore subject                                                                                                                         | `langdale-lemire-2019…` App.C        | ☐      |
| R29 | simdjson    | :33 "validate **the** documents"                                              | drop "the" (source: "validate documents")                                                                                               | `langdale-lemire-2019…`              | ☐      |
| R30 | simdjson    | :39 "fixed cost per input **byte**"                                           | "bytes" (plural)                                                                                                                        | `langdale-lemire-2019…`              | ☐      |
| R31 | tree-sitter | :36 four-goals quote "pure **C**"                                             | "pure **C11**"                                                                                                                          | `…/tree-sitter/docs/src/index.md:13` | ☐      |
| R32 | antlr       | :187 lexer quote cited §2.2                                                   | §2.3 (Lexical analysis); §2.2 is left-rec removal                                                                                       | `parr-2014…` §2.3                    | ☐      |
| R33 | antlr       | :219 left-recursion quote cited §2.4 (nonexistent)                            | §2.2 (Left-recursion removal)                                                                                                           | `parr-2014…` §2.2                    | ☐      |
| R34 | antlr       | :9,271,317,329,354,362 "ten runtime targets in `runtime/`, all first-party"   | repo `runtime/` has **8** subdirs (PHP separate repo, TS via JS); "10 target languages" ok — distinguish 10 langs vs 8 in-repo runtimes | `…/java/antlr4/runtime/`             | ☐      |
| R35 | antlr       | :189 maximal-munch cited `doc/lexer-rules.md` (doesn't state it)              | re-cite or drop locator                                                                                                                 | repo                                 | ☐      |
| R36 | antlr       | :265,340 O(n⁴)/testing-burden quotes cited §1.1                               | §1 (before §1.1 heading)                                                                                                                | `parr-2014…` §1                      | ☐      |
| R37 | bison-yacc  | :36 intro quote 1st sentence (from stale MIT mirror) not in pinned manual     | swap to pinned `bison.texi:588` wording ("annotated CFG…deterministic LR or GLR…")                                                      | `…/bison/doc/bison.texi:588`         | ☐      |
| R38 | bison-yacc  | :151–154 dangling-else counterexample reduce derivation collapsed to 1 line   | reproduce manual's 4-line nested derivation or soften "verbatim"                                                                        | `…/bison/doc/bison.texi:8576`        | ☐      |

Notes (no edit): yacc "1975" = CSTR-32 report date (bison.texi gives 1971/1973 invention, 1978 pub) — defensible, keep. simdjson port provenance (Wayfair/Chromium) web-only.

### Batch 4 (systems II)

| #   | Page         | Claim                                                                                                                | Correction                                                                                              | Source                             | Fixed? |
| --- | ------------ | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------- | ------ |
| R39 | menhir       | :29 intro blockquote misquoted                                                                                       | use pinned wording ("…``semantic actions'' (fragments of executable code), into parsers") or paraphrase | `…/ocaml/menhir/doc/manual.tex:56` | ☐      |
| R40 | menhir       | :142–164 standard-library block labelled "Verbatim" omits `[@name …]` attrs; path is `front/standard.mly` not `src/` | add attrs or relabel "Adapted"; fix path                                                                | `…/menhir/front/standard.mly`      | ☐      |
| R41 | menhir       | :19,:318 mirror link `github.com/savonet/mehnir` fabricated (wrong org + misspelled)                                 | drop or replace with a real mirror                                                                      | —                                  | ☐      |
| R42 | rust-nom     | :332 "bitvec integration (added in 7.0)" backwards                                                                   | added 6.0, split to `nom-bitvec` crate in 7.0                                                           | `…/rust/nom/CHANGELOG.md:185,420`  | ☐      |
| R43 | rust-nom     | :152 quote "(like a number of bytes)" altered                                                                        | restore `src/lib.rs:179` text or move gloss outside quotes                                              | `…/rust/nom/src/lib.rs:179`        | ☐      |
| R44 | rust-nom     | :215 `Parser` trait labelled `src/traits.rs`                                                                         | defined in `src/internal.rs:403`                                                                        | `…/rust/nom/src/internal.rs:403`   | ☐      |
| R45 | rust-chumsky | :184 "error recovery … high up the stack" quote not in repo                                                          | re-cite `recover_with` doc, paraphrase, or mark web                                                     | `…/rust/chumsky/src/lib.rs:1882`   | ☐      |
| R46 | rust-chumsky | :250 "approaching hand-written parser speeds" attributed to 1.0.0-alpha.0 announcement (no local artifact)           | mark as web/blog quote or reground to README "comparable to a hand-written parser"                      | `…/rust/chumsky/README.md:192`     | ☐      |
| R47 | rust-chumsky | :268 Tao "report many … errors at once" not in pinned Tao README                                                     | cite as web (current Tao README) or paraphrase                                                          | web                                | ☐      |

Notes (no edit): pest clean (non-memoizing confirmed in `parser_state.rs`; book quotes web-only — book not cloned). nom "Ed Page's fork"/toml_edit + Suricata 4.0 are web (winnow repo names no author). menhir minor: favour/favor, `resume` `?strategy`.

### Batch 5 (remainder + synthesis)

| #   | Page           | Claim                                                                         | Correction                                                                                      | Source                     | Fixed? |
| --- | -------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | -------------------------- | ------ |
| R48 | haskell-parsec | :311 "Parsec is distributed with GHC's boot libraries" (present tense, stale) | parsec is no longer a GHC boot lib — qualify/past-tense                                         | repo/web                   | ☐      |
| R49 | index          | :172 milestone "nom development begins" dated 2011                            | unsupported — nom CHANGELOG starts 2015; move to ~2014–15 or drop ("nom 1.0 (2015)" is correct) | `…/rust/nom/CHANGELOG.md`  | ☐      |
| R50 | comparison     | :33,:116 chumsky zero-copy labelled "(1.0)"/"chumsky 1.0"                     | shipped in 0.10.0 (1.0 unreleased) — "0.10+"; matches the page's own line 160                   | `rust-chumsky.md` ledger   | ☐      |
| R51 | comparison     | :158 "Parsec (Cabal, GHC, Dhall)" adopters                                    | GHC parser is Happy-generated; Dhall uses megaparsec — drop/qualify GHC & Dhall                 | `haskell-parsec.md` ledger | ☐      |

Notes (no edit): theory/index clean; haskell-parsec otherwise clean (1996/1998 fix confirmed). index Tomita 1985 = same as R15 (mirror). Minor parsec locator slips ([Hackage]→README at :283,:302; [synopsis]→description :284) left as ◯.

### Batch 6 (wave 2 — incremental / query-based, 2026-07-03)

**Zero discrepancies.** The five new pages ([`theory/incremental`](./theory-incremental.md),
[`rust-analyzer`](./rust-analyzer.md), [`roslyn`](./roslyn.md), [`lezer`](./lezer.md),
[`rustc-queries`](./rustc-queries.md)) were grounded against the pinned wave-2 repos + the Wagner /
_à-la-carte_ / Adapton papers. Every material blockquote was confirmed verbatim in-tree (roslyn
`Red-Green Trees.md` / `Incremental Parser.md`; rust-analyzer `syntax.md:125/311/522` + salsa
`durability.rs`/`cancelled.rs`; lezer README + `constants.ts` `File.Version=14` + `stack.ts`
`MinBigReduction=2000`; rustc-dev-guide `query.md` + `incremental-compilation*.md`). One at-risk quote
("surprisingly simple extension to the overall query system") was a **false alarm** — verbatim but
line-wrapped at `incremental-compilation.md:3-4`. Web-attested only: author/creator names, release
cadence/dates, and the Roslyn CTP/OSS milestone dates (all flagged ◯/🌐 in each ledger, none asserted
as tree facts).

### Batch 7 (wave 2 — SIMD / high-performance + combinators, 2026-07-03)

**Effectively zero substantive discrepancies** across the eleven new pages ([simd-json],
[sonic-rs], [yyjson], [rapidjson], [hyperscan], [zig-tokenizer]; [rust-winnow],
[haskell-flatparse], [rust-combine], [ocaml-angstrom], [fsharp-fparsec]). Every material
quote confirmed verbatim in the pinned wave-2 repos + the Hyperscan NSDI'19 paper. Two
non-content locator/scope caveats, both self-flagged in their ledgers:

- **D-R1** (`rapidjson`) — in-tree source disagreement (README RFC 7159 vs `features.md`
  RFC 4627); page follows the README and NOTEs it. Not a page error.
- **D-Z1** (`zig-tokenizer`) — `Parse.zig` not opened; the one-sentence "hand-written RD
  parser" context is asserted from `Ast.zig` + known design. Author also correctly
  **declined** to call `StaticStringMap` a "perfect hash" (unverifiable from the call site).

Corrections applied to task briefs during grounding (agents caught these): `sonic-rs`
license is **Apache-2.0 only** (not dual); `simd-json` makes **no** GB/s claim (no in-repo
benchmarks). Web-attested only: benchmark numbers, release dates, and downstream-adoption
notes (all flagged 🌐 per ledger; none asserted as tree facts).

[simd-json]: ./simd-json.md
[sonic-rs]: ./sonic-rs.md
[yyjson]: ./yyjson.md
[rapidjson]: ./rapidjson.md
[hyperscan]: ./hyperscan.md
[zig-tokenizer]: ./zig-tokenizer.md
[rust-winnow]: ./rust-winnow.md
[haskell-flatparse]: ./haskell-flatparse.md
[rust-combine]: ./rust-combine.md
[ocaml-angstrom]: ./ocaml-angstrom.md
[fsharp-fparsec]: ./fsharp-fparsec.md

### Batch 8 (wave 3 — D landscape, 2026-07-03)

**Zero discrepancies.** The [`d-landscape.md`](./d-landscape.md) page's every project quote
was read directly from a locally pinned checkout under `$REPOS/dlang/` this session (Pegged
`mixin(grammar)`/compile-time; libdparse "Library for lexing and parsing D source code" + the
vendored `std.experimental.lexer` provenance; dmd `lexer.d`/`parse.d` headers; sdc
`ambiguous.d`; pry; mir `serde.d`/`parse.d` + mir-ion/asdf READMEs; JSONiopipe; `std.json`'s
RED GC warning; dxml; sdlite). Web-attested only: **dub scores/download counts** and the three
brief-mention uncloned projects (ctpg, d_tree_sitter, httparsed) — all flagged 🌐/≈, none
asserted as tree facts. The `docs/specs/parsing/` proposal is design, not a research claim, so
it carries no ledger; its prior-art links resolve to real survey pages.

### Batch 9 (wave 4 — syntax highlighting, 2026-07-11)

**Zero discrepancies.** The five new pages ([`syntect`](./syntect.md), [`bat`](./bat.md),
[`tree-sitter-highlight`](./tree-sitter-highlight.md), [`shiki`](./shiki.md),
[`syntax-highlighting`](./syntax-highlighting.md)) were **grounded at authoring time**: every
material blockquote was grep-verified verbatim at the pinned wave-4 checkouts (recorded in
[`_sources.md`](./_sources.md), incl. the new `$REPOS/rust/syntect` clone and the dual
tree-sitter pins) _before_ the prose was written, and the built-site anchors were checked
against dist HTML ids. Two brief-level corrections were caught during authoring and never
reached the pages (bat's compression-constant comment wording; `@shikijs/primitive`'s
self-description) — both noted in their ledgers. Web-attested only: the ten historical dates
(all with primary sources in the [`syntax-highlighting` ledger](./syntax-highlighting.md),
incl. the npm `shiki@0.0.1` squatted-package trap and the GitHub-adoption bound at Wayback
2020-02-23 — no GitHub-authored announcement exists), release-history facts, and
adoption/ecosystem context. The wave-4 edits to `tree-sitter.md`, `comparison.md`, and
`index.md` are cross-links/rows re-stating ledgered claims — no new ledger deltas beyond the
milestone dates covered above.

### Batch 10 (wave 5 — syntax highlighting widened, 2026-07-11)

**Zero page discrepancies** across the nine new pages ([`pygments`](./pygments.md),
[`chroma`](./chroma.md), [`helix`](./helix.md), [`linguist`](./linguist.md),
[`highlight-js`](./highlight-js.md), [`lezer-highlight`](./lezer-highlight.md),
[`lsp-semantic-tokens`](./lsp-semantic-tokens.md),
[`intellij-highlighting`](./intellij-highlighting.md),
[`vim-emacs-syntax`](./vim-emacs-syntax.md)) + the restructured synthesis (B10 addendum in
its ledger). Verification method: each page's **load-bearing quotes were re-grep-verified
directly at the pinned checkouts before authoring**; remaining rows carry the exploration
pass's verbatim locators against the same pins (recorded per ledger). Two **upstream**
doc-vs-code drifts were found and are _reported in the pages as findings_, not page errors:
Chroma's "Lab color space" comments vs its redmean implementation, and Linguist's
"Bayesian" docs vs its nearest-centroid classifier. Authoring-time catches: the LSP repo's
`gh-pages` default branch (a `/blob/main/` spec URL 404s — fixed pre-commit, noted in
`_sources.md`); Helix's engine living in the external `tree-house` crate (dual grounding
declared rather than papered over); the npm `@lezer/highlight` repo-vs-package dating trap.
Web-attested only: the ten D11–D20 historical dates (primary sources in the
[synthesis ledger](./syntax-highlighting.md)), release history, and adoption context.

## Status: all 51 pages grounded (10 batches). 44 discrepancies (R8–R51, all from B1–B5);

wave-2 B6 + B7 + wave-3 B8 + wave-4 B9 + wave-5 B10 added

0 substantive. All minor — quote-precision, citation-locator, version/attribution. No fabricated _facts_
beyond R8/R23 quote-padding and R26/R39/R45–R47 quote-sourcing. Proceed to Phase 3 (apply fixes).

## Pre-flagged for this pass

- **theory/derivatives**: doc cites Adams 2016 as `arXiv:1604.07383`; correct id is
  `1604.04695` (the downloaded PDF) — verify and fix the link if present.
