# Grounding ledger — `d-landscape.md`

Claim-by-claim verification of `docs/research/parsing/d-landscape.md` against **local**
pinned checkouts under `$REPOS/dlang/` (SHAs in [`_sources.md`](./_sources.md), wave-3
table). `$REPOS = /home/petar/code/repos`. All quotes read directly during the 2026-07-03
wave-3 pass.

Status key: ✓ verified verbatim/exact · ≈ accurate paraphrase / abridged-but-faithful ·
⚠ discrepancy · ◯ opinion/interpretation · 🌐 web/secondary (dub scores, download stats).

| #   | Claim                                                                                                                                                                                                           | Type         | Source (local + locator)                                                                                   | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Pegged: "Parsing Expression Grammar (PEG) generator"; Boost; Philippe Sigaud                                                                                                                                    | fact         | `Pegged/dub.json` (description, license, authors)                                                          | ✓      |
| 2   | The `mixin(grammar(\`Arithmetic: …\`))` example                                                                                                                                                                 | QUOTE-code   | `Pegged/README.md`                                                                                         | ✓      |
| 3   | Parse both ways: `enum parseTree1 = Arithmetic(...)` (compile-time) + runtime `auto parseTree2 = …`                                                                                                             | QUOTE-code   | `Pegged/README.md` ("Parsing at compile-time" / "at runtime too")                                          | ✓      |
| 4   | Pegged is **not `@nogc`** — GC `ParseTree`; latest commit "use GC allocated slice instead of always alloca"                                                                                                     | fact         | `Pegged` git log HEAD `c351440` (2025-08-01)                                                               | ✓      |
| 5   | ctpg = historical CTFE generator (youkei), abandoned                                                                                                                                                            | fact         | 🌐 registry/GitHub (not locally cloned)                                                                    | 🌐     |
| 6   | libdparse: "Library for lexing and parsing D source code"                                                                                                                                                       | QUOTE        | `dlang-community/libdparse/README.md:3`                                                                    | ✓      |
| 7   | Backbone of DCD/D-Scanner/dfmt/dfix (they depend on it)                                                                                                                                                         | fact         | dlang-community/{D-Scanner,dfmt,dfix} `dub.json` deps on `dparse`                                          | ≈      |
| 8   | `std.experimental.lexer` **removed from Phobos**, vendored in libdparse; "range-based compile-time _lexer generator_"                                                                                           | QUOTE + fact | `phobos/std/experimental/` (no `lexer.d`); `libdparse/src/std/experimental/lexer.d:1-6`                    | ✓      |
| 9   | libdparse lexer uses SSE4.2 + rollback/stack-buffer allocator                                                                                                                                                   | fact         | `libdparse/src/dparse/lexer.d` (`core.cpuid : sse42`); `src/dparse/rollback_allocator.d`                   | ✓      |
| 10  | dmd `lexer.d` "converts source code into lexical tokens"; `parse.d` "takes a token stream from the lexer, and parses it into an abstract syntax tree"                                                           | QUOTE        | `dmd/compiler/src/dmd/lexer.d:2`, `parse.d:2`                                                              | ✓      |
| 11  | dmd Walter Bright / D Language Foundation, Boost; spec-linked; `core.stdc`/betterC-leaning                                                                                                                      | fact         | `dmd/.../lexer.d` header (Copyright/License/Specification lines + `import core.stdc.*`)                    | ✓      |
| 12  | sdc: independent from-scratch D compiler, MIT, based on `libd`                                                                                                                                                  | fact         | `sdc/README.md` (title, "based on libd", "released under the MIT license")                                 | ✓      |
| 13  | sdc `parseAmbiguous`: "Branch to the right code depending if we have a type, an expression or an identifier" over a `TokenRange`                                                                                | QUOTE        | `sdc/src/d/parser/ambiguous.d:16-23`                                                                       | ✓      |
| 14  | pry: "performance on par with handwritten parsers"; `Stream`-over-ranges; CT-specialized; TLV                                                                                                                   | QUOTE + fact | `pry-parser/README.md:5-12`                                                                                | ✓      |
| 15  | pry last release 2024 (v0.7.0), stale-ish; BSL-1.0                                                                                                                                                              | fact         | `pry-parser` git log HEAD `ae4c017` (2024-04-24); `dub.sdl` license                                        | ✓      |
| 16  | mir.serde "implements common de/serialization routines"; mir.parse "@nogc and nothrow Parsing Utilities"; Apache-2.0, Ilia Ki / Symmetry Investments                                                            | QUOTE        | `mir/mir-algorithm/source/mir/serde.d:2`, `mir/parse.d:2-6`                                                | ✓      |
| 17  | mir-ion: "serialization engine supports Text and binary Ion, JSON, MsgPack, YAML"                                                                                                                               | QUOTE        | `mir/mir-ion/README.md` ("# Mir Ion" section)                                                              | ✓      |
| 18  | mir-ion SIMD-optimized, `@nogc`-friendly, CT-introspection (de)serialization; successor to asdf                                                                                                                 | fact         | `mir-ion` README + `source/` (SIMD in mir-algorithm; introspection-driven)                                 | ≈      |
| 19  | asdf: "a cache oriented string based JSON representation … specially geared towards transforming high volumes of JSON dataframes"; SSE4.2; Tamedia                                                              | QUOTE        | `asdf/README.md` ("# A Simple Document Format")                                                            | ✓      |
| 20  | JSONiopipe: "a streaming parser, which can be applied to any iopipe of character type … the entire data does not need to be held in memory"; "no required intermediate format"; optional DOM                    | QUOTE        | `jsoniopipe/README.md` (Design Overview)                                                                   | ✓      |
| 21  | `std.json` RED warning: GC `JSONValue`, "at the range of hundreds of megabytes … known to cause and exacerbate GC problems … try replacing it with a stream parser"                                             | QUOTE        | `phobos/std/json.d:8-10`                                                                                   | ✓      |
| 22  | dxml: "range-based [StAX parser] … but … also has support for generating a DOM"; `@safe`, XML 1.0                                                                                                               | QUOTE        | `dxml/README.md:3-7`                                                                                       | ✓      |
| 23  | D-YAML: canonical D YAML, PyYAML-derived (~YAML 1.1), slicing input reuse; dub 4.9                                                                                                                              | fact         | `dlang-community/D-YAML` README/source; score 🌐                                                           | ≈      |
| 24  | sdlite: "a lightweight SDLang parser/generator … range based API. While the parser still uses the GC … it uses a very efficient pool based allocation scheme that has very low computation and memory overhead" | QUOTE        | `sdlite/README.md:1-7`                                                                                     | ✓      |
| 25  | d_tree_sitter = D FFI to tree-sitter; httparsed = `@nogc`/betterC HTTP; cerealed = binary serialization                                                                                                         | fact         | 🌐 (d_tree_sitter/httparsed not cloned); `cerealed/dub.sdl` local                                          | ≈/🌐   |
| 26  | In-tree: `parseSemVerShaped` scannerless RD, `static foreach` DbI, `@safe pure nothrow @nogc`, `Expected!(T, ParseError, NoGcHook)`                                                                             | fact         | `libs/versions/src/sparkles/versions/schemes/semver.d:707`; `parsing.d`; verified via wave-3 Explore agent | ✓      |
| 27  | In-tree: `base.text.readers` zero-copy cursor-advancing (`ref scope const(char)[]`), "mechanism, not policy"                                                                                                    | fact         | `libs/base/src/sparkles/base/text/{readers,errors}.d`                                                      | ✓      |
| 28  | In-tree: `core_cli.args` = compile-time UDA wrapper around `std.getopt` (GC + exceptions)                                                                                                                       | fact         | `libs/core-cli/src/sparkles/core_cli/args.d`                                                               | ✓      |
| 29  | In-tree: VT parsing delegated to C `libghostty-vt` via ImportC                                                                                                                                                  | fact         | `libs/ghostty/src/sparkles/ghostty/{c.c,package.d}`                                                        | ✓      |
| 30  | dub **scores** (Pegged 4.1, libdparse 4.9, dxml 4.6, pry 2.1, mir-ion 3.3, asdf 4.0, D-YAML 4.9, sdlite 3.8)                                                                                                    | figure       | 🌐 code.dlang.org registry (as of review)                                                                  | 🌐     |
| 31  | Catalog table + synthesis table + "the gap" thesis                                                                                                                                                              | synth        | derived from rows above                                                                                    | ◯      |

## Discrepancies

None. Every inline blockquote was read directly from the pinned checkout this session
(README/source headers). The one thing to watch: dub **scores** and download counts (rows
5, 23, 25, 30) are registry figures, not repo facts — flagged 🌐; they are popularity signals,
not load-bearing claims.

## Web-fallback / not-locally-groundable

- **dub scores / download stats** — code.dlang.org registry (row 30); the registry category
  browse is JS-rendered/flaky, so scores are point-in-time signals.
- **ctpg** (row 5), **d_tree_sitter** / **httparsed** (row 25) — mentioned but **not cloned**;
  characterized from the registry/GitHub, marked 🌐/≈, not asserted from a local tree.
- **libdparse adopter list** (row 7) and **mir-ion successor-to-asdf / SIMD** (row 18),
  **D-YAML PyYAML lineage** (row 23) — accurate paraphrases from README/deps + ecosystem
  knowledge, marked ≈.

## Opinion (◯)

- "the gap Sparkles fills" thesis, the fit-for-`@nogc` column, and the catalog framing —
  legitimate survey synthesis; every cell traces to a verified row or an existing
  [comparison.md] Sparkles-fit conclusion.

**Net:** 0 discrepancies. Every project's headline quote is verbatim from its pinned local
checkout (Pegged mixin/compile-time, libdparse + vendored lexer provenance, dmd lexer/parse
headers, sdc `ambiguous.d`, pry, mir serde/parse + mir-ion/asdf, JSONiopipe, `std.json` RED
warning, dxml, sdlite). Only dub scores and the three uncloned brief-mentions are secondary.
