# Grounding sources — local-artifact map

Lookup table for the per-page verification pass. Every external citation in the parsing
survey maps here to a **local** artifact: a PDF under `$REPOS/papers/parsing/` or a repo
cloned under `$REPOS` (pinned below). Web is a fallback **only** for the handful marked
_unobtainable_. `$REPOS` = `/home/petar/code/repos`.

**Acquisition:** 31 of 36 cited primaries downloaded (2026-06-29); 5 publisher-paywalled with
no open copy → grounded against secondary local artifacts (noted per row).

## Source repos (pinned to reviewed HEAD)

| Repo            | Path                             | Pinned SHA  | As of      |
| --------------- | -------------------------------- | ----------- | ---------- |
| bison           | `$REPOS/parsing/bison`           | `8d101c19`  | 2026-04-23 |
| simdjson        | `$REPOS/parsing/simdjson`        | `9b33047a`  | 2026-06-15 |
| tree-sitter     | `$REPOS/parsing/tree-sitter`     | `cbee4672`  | 2026-06-26 |
| re2c            | `$REPOS/parsing/re2c`            | `fccdffc9`  | 2026-06-24 |
| derp-3          | `$REPOS/parsing/derp-3`          | `86bca8a`   | 2016-03-30 |
| valiant-parsing | `$REPOS/parsing/valiant-parsing` | `e27c7c6`   | 2016-01-27 |
| menhir          | `$REPOS/ocaml/menhir`            | `054f73ca`  | 2026-06-15 |
| antlr4          | `$REPOS/java/antlr4`             | `7d5770395` | 2026-02-16 |
| pest            | `$REPOS/rust/pest`               | `b24fa55`   | 2026-06-23 |
| nom             | `$REPOS/rust/nom`                | `51c3c4e`   | 2025-08-26 |
| winnow          | `$REPOS/rust/winnow`             | `cbeda8e0`  | 2026-06-16 |
| chumsky         | `$REPOS/rust/chumsky`            | `246c80b`   | 2026-06-21 |
| parsec          | `$REPOS/haskell/parsec`          | `6845fdd`   | 2026-06-09 |
| megaparsec      | `$REPOS/haskell/megaparsec`      | `39e7760`   | 2026-06-23 |
| attoparsec      | `$REPOS/haskell/attoparsec`      | `7244e6b`   | 2024-12-11 |

Wave 2 — incremental / query-based (added 2026-07-03):

| Repo            | Path                          | Pinned SHA | As of      |
| --------------- | ----------------------------- | ---------- | ---------- |
| rust-analyzer   | `$REPOS/rust/rust-analyzer`   | `3033d4f`  | 2026-07-02 |
| salsa           | `$REPOS/rust/salsa`           | `9447e2f`  | 2026-07-02 |
| rowan           | `$REPOS/rust/rowan`           | `0c1077e`  | 2025-07-27 |
| rustc-dev-guide | `$REPOS/rust/rustc-dev-guide` | `646dd8e`  | 2026-07-01 |
| lezer-lr        | `$REPOS/js/lezer-lr`          | `ed59b8b`  | 2026-04-15 |
| lezer-common    | `$REPOS/js/lezer-common`      | `d87b56c`  | 2026-04-15 |
| roslyn          | `$REPOS/dotnet/roslyn`        | `e42c3902` | 2026-07-02 |

Wave 2 — SIMD / data-parallel + combinators (added 2026-07-03):

| Repo      | Path                       | Pinned SHA | As of      |
| --------- | -------------------------- | ---------- | ---------- |
| simd-json | `$REPOS/rust/simd-json`    | `0662a83`  | 2026-03-11 |
| sonic-rs  | `$REPOS/rust/sonic-rs`     | `03545a9`  | 2026-04-15 |
| yyjson    | `$REPOS/c/yyjson`          | `12797c6`  | 2026-07-02 |
| rapidjson | `$REPOS/cpp/rapidjson`     | `24b5e7a`  | 2025-02-05 |
| hyperscan | `$REPOS/cpp/hyperscan`     | `828b4fe`  | 2026-06-29 |
| combine   | `$REPOS/rust/combine`      | `203b76a`  | 2026-02-03 |
| angstrom  | `$REPOS/ocaml/angstrom`    | `76c5ef5`  | 2024-09-11 |
| fparsec   | `$REPOS/fsharp/fparsec`    | `156cbd7`  | 2022-12-04 |
| flatparse | `$REPOS/haskell/flatparse` | `df7e978`  | 2025-10-08 |

(`winnow` was already pinned above, wave 1; the Zig tokenizer is read from the existing
`$REPOS/zig/zig/lib/std/zig/tokenizer.zig` checkout. Hyperscan paper:
`papers/parsing/wang-2019-hyperscan-nsdi.pdf`, NSDI 2019, 19 pp.)

In-repo docs/manuals to use for quote-grounding: bison `doc/bison.texi`; menhir
`doc/` + `CHANGES.md`; tree-sitter `docs/src/`; nom/winnow/chumsky/pest `doc/` + `README` +
`src/`; the Haskell libs' `.cabal`/`CHANGELOG`/`src` + Haddocks in-tree. For wave 2:
roslyn `docs/compilers/Design/Red-Green Trees.md` + `Incremental Parser.md`; salsa
`README.md` + `src/{durability,cancelled,cycle}.rs` + `book/`; rustc-dev-guide
`src/query.md` + `src/queries/incremental-compilation-in-detail.md`; lezer-lr
`README.md` + `src/{parse,stack,token}.ts`; rowan `README.md` + `src/`.

## Papers present — `$REPOS/papers/parsing/`

All PDFs have an extractable text layer (use `nix shell nixpkgs#poppler-utils -c pdftotext`);
classic scans are OCR'd. Dragon-book p1 is an image cover — body text extracts fine.

```
adams-2016-complexity-performance-pwd-pldi.pdf      knuth-1965-translation-left-to-right-infcontrol.pdf
aho-2006-dragon-book-2nd-ed.pdf                     langdale-lemire-2019-parsing-gigabytes-json-vldbj.pdf
aycock-horspool-2002-practical-earley-compj.pdf     lee-2002-cf-parsing-requires-bmm-jacm.pdf
bour-2018-merlin-language-server-icfp.pdf           leijen-meijer-2001-parsec-real-world.pdf
brzozowski-1964-derivatives-regular-expressions-jacm.pdf  lewis-stearns-1968-syntax-directed-transduction-jacm.pdf
chifflier-couprie-2017-writing-parsers-2017-langsec.pdf   might-2011-parsing-with-derivatives-icfp.pdf
deremer-pennello-1982-lalr-lookahead-toplas.pdf     owens-2009-regex-derivatives-reexamined-jfp.pdf
earley-1970-efficient-context-free-parsing-algorithm-cacm.pdf  parr-2014-adaptive-allstar-oopsla.pdf
floyd-1963-syntactic-analysis-operator-precedence-jacm.pdf     parr-fisher-2011-llstar-pldi.pdf
ford-2002-packrat-parsing-icfp.pdf                  pratt-1973-top-down-operator-precedence-popl.pdf
ford-2004-parsing-expression-grammars-popl.pdf      thompson-1968-regular-expression-search-cacm.pdf
grune-jacobs-ptapg-1st-ed-book.pdf                  valiant-1975-general-cf-recognition-subcubic-jcss.pdf
hutton-meijer-1996-monadic-parser-combinators-techreport.pdf  wagner-1997-incremental-parsing-thesis-berkeley.pdf
isradisaikul-myers-2015-counterexamples-parsing-conflicts-pldi.pdf  warth-2008-packrat-left-recursion-pepm.pdf
jourdan-2012-validating-lr1-parsers-esop.pdf        keiser-lemire-2021-validating-utf8-spe.pdf
keiser-lemire-2024-on-demand-json-spe.pdf
```

Wave 2 — incremental / query-based (added 2026-07-03):

```
mokhov-2018-build-systems-a-la-carte-icfp.pdf       hammer-2014-adapton-pldi.pdf
```

(`wagner-1997-incremental-parsing-thesis-berkeley.pdf` was already present from wave 1.)

## Unobtainable primaries → secondary grounding

| Citation                                        | Why                            | Ground instead against                                                            |
| ----------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------- |
| Antimirov 1996, partial derivatives (TCS)       | Elsevier paywall, no open copy | `owens-2009-…pdf` ref-list + §; bibliographic only                                |
| Rosenkrantz & Stearns 1970 (Inf.&Control)       | Elsevier paywall               | bibliographic (already-fixed link); LL(k) claims via Dragon Book / `grune-jacobs` |
| Birman & Ullman 1973, TDPL/GTDPL (Inf.&Control) | Elsevier paywall               | `ford-2004-…pdf` §2 (cites TDPL/GTDPL roots)                                      |
| Pager 1977, minimal LR(k) (Acta Inf.)           | Springer paywall, no open copy | menhir `doc/` + `CHANGES`; bibliographic                                          |
| Denny & Malloy 2010, IELR(1) (SCP)              | Elsevier paywall               | bison `doc/bison.texi` IELR section; bibliographic                                |

## Per-page citation → artifact

Format: page → {claim source : local artifact}. "secondary" = see table above. Official
manuals/blogs/Wikipedia reground in the primary paper or repo named.

- **theory/formal-languages.md** — Chomsky 1956 → _no PDF; bibliographic + Dragon Book/grune-jacobs_; Earley 1970 → `earley-1970`; Valiant 1975 → `valiant-1975`; Lee 2002 → `lee-2002`; CYK/pumping/closure → `aho-2006-dragon-book`, `grune-jacobs`; Knuth 1965 (DCFL=LR(1)) → `knuth-1965`.
- **theory/top-down.md** — Lewis & Stearns 1968 → `lewis-stearns-1968`; Rosenkrantz & Stearns 1970 → secondary; LL(_) → `parr-fisher-2011`; ALL(_) → `parr-2014`; Dragon §4.4 → `aho-2006`; grune-jacobs ch.6,8.
- **theory/bottom-up.md** — Knuth 1965 → `knuth-1965`; DeRemer & Pennello 1982 → `deremer-pennello-1982`; Tomita 1985 (book, no PDF) → tree-sitter repo + grune-jacobs; Pager 1977 → secondary; Bison manual → `$REPOS/parsing/bison/doc/bison.texi`.
- **theory/general-parsing.md** — Earley 1970 → `earley-1970`; Younger 1967/Kasami 1965 (no PDF) → `aho-2006`/`grune-jacobs`; Leo 1991 (no PDF) → bibliographic + grune-jacobs; Aycock & Horspool 2002 → `aycock-horspool-2002`; Marpa → bibliographic/secondary.
- **theory/peg-packrat.md** — Ford 2002 → `ford-2002`; Ford 2004 → `ford-2004`; Warth 2008 → `warth-2008`; Birman & Ullman 1973 → secondary (`ford-2004`); Brzozowski 1964 → `brzozowski-1964`.
- **theory/pratt-precedence.md** — Floyd 1963 → `floyd-1963`; Pratt 1973 → `pratt-1973`; Crockford/matklad/Norvell → blogs, reground in `pratt-1973` + code logic.
- **theory/derivatives.md** — Brzozowski 1964 → `brzozowski-1964`; Thompson 1968 → `thompson-1968`; Antimirov 1996 → secondary (`owens-2009`); Owens 2009 → `owens-2009`; Might 2011 → `might-2011`; Adams 2016 → `adams-2016` (NB: doc cites arXiv 1604.07383 — correct id is 1604.04695; flag); derp → `$REPOS/parsing/derp-3`; re2c → `$REPOS/parsing/re2c`.
- **theory/index.md, concepts.md, comparison.md, index.md** — aggregate of the above; verify cross-page consistency against the same artifacts. Valiant/Lee landscape → `valiant-1975`,`lee-2002`. ALL(\*) O(n⁴) → `parr-2014`. packrat/PEG → `ford-2002`/`ford-2004`.
- **simdjson.md** — Langdale & Lemire 2019 → `langdale-lemire-2019`; Keiser & Lemire 2021 → `keiser-lemire-2021`; 2024 On-Demand → `keiser-lemire-2024`; code/figures → `$REPOS/parsing/simdjson` (`src/`, `include/`, `doc/`).
- **tree-sitter.md** — Wagner 1997 → `wagner-1997`; Jourdan 2012 → `jourdan-2012`; GLR/incremental/scanners → `$REPOS/parsing/tree-sitter` (`lib/src/`, `docs/src/`); Brunsfeld 2018 (talk) → repo + secondary.
- **antlr.md** — ALL(_) → `parr-2014`; LL(_) → `parr-fisher-2011`; targets/version/left-rec/predicates → `$REPOS/java/antlr4` (`doc/`, `tool/`, runtimes).
- **bison-yacc.md** — Johnson 1975 yacc (no PDF) → bison `doc/` + bibliographic; IELR Denny-Malloy 2010 → secondary (bison `doc/bison.texi`); Isradisaikul & Myers 2015 → `isradisaikul-myers-2015`; manual quotes → `$REPOS/parsing/bison/doc/bison.texi`.
- **menhir.md** — Jourdan/Pottier/Leroy 2012 → `jourdan-2012`; Jourdan & Pottier 2017 (no PDF) → bibliographic; Bour/Refis/Scherer 2018 → `bour-2018`; manual/`--GLR`/flags/stdlib → `$REPOS/ocaml/menhir` (`doc/`, `CHANGES.md`, `src/standard.mly`).
- **pest.md** — Ford 2002/2004 → `ford-2002`/`ford-2004`; non-memoizing/PrattParser/sigils → `$REPOS/rust/pest` (`pest/src/`, `meta/`, `book/`); Couprie blog → secondary.
- **rust-nom.md** — Chifflier & Couprie 2017 → `chifflier-couprie-2017`; combinators/streaming/zero-copy/winnow-fork → `$REPOS/rust/nom` + `$REPOS/rust/winnow` (`src/`, `doc/`, `README`, `CHANGELOG`).
- **rust-chumsky.md** — error-recovery/zero-copy-0.10/Pratt/left-rec → `$REPOS/rust/chumsky` (`src/`, `CHANGELOG.md`, `README`); Barretto blog → secondary.
- **haskell-parsec.md** — Hutton & Meijer 1996 → `hutton-meijer-1996`; Hutton & Meijer 1998 (no PDF) → bibliographic; Leijen & Meijer 2001 → `leijen-meijer-2001`; Leo 1991/Aycock-Horspool 2002 → `aycock-horspool-2002` + secondary; lib behavior → `$REPOS/haskell/{parsec,megaparsec,attoparsec}`.
