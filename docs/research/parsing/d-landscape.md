# The D parsing landscape

The survey's inward turn: what the **D ecosystem itself** offers for parsing, mapped onto
the [taxonomy][umbrella] the cross-ecosystem deep-dives established, and read against
Sparkles' allocation-conscious (`@nogc`/`@safe`) needs. Where the other pages ask "how does
Rust/Haskell/C++ do it," this one asks "what can a D project reach for today, and what is
missing" — the evidence base for the [Sparkles parsing proposal][proposal]. Every project
below is grounded against a **locally pinned** checkout under `$REPOS/dlang/`
(`$REPOS = /home/petar/code/repos`; per-claim verification lives in the survey's internal
grounding tree, which the published pages do not link).

**Last reviewed:** July 3, 2026

---

## The landscape at a glance

D's parsing story has four strong pillars and one conspicuous gap. The pillars: a
**compile-time PEG generator** ([Pegged][pegged-repo]), a **production hand-written
front-end** for D itself (three of them — [libdparse][libdparse-repo], [dmd][dmd-repo],
[sdc][sdc-repo]), a **world-class `@nogc`/SIMD serialization stack**
([mir-ion][mir-ion-repo]/[asdf][asdf-repo]), and solid **range-based structured-data
parsers** ([dxml][dxml-repo], [D-YAML][dyaml-repo], [sdlite][sdlite-repo]). The gap: **no
modern, maintained, `@nogc` zero-copy _ordered-choice combinator_** ([nom][nom]/[winnow]
style) and **no recovering parser** ([chumsky]-style) — the two designs the survey
identifies as the [Sparkles design center][comparison-fit].

| Project                       | Category (survey link)                  | Grammar / approach                                | Compile-time?    | `@nogc` / zero-copy             | Maturity (dub score) |
| ----------------------------- | --------------------------------------- | ------------------------------------------------- | ---------------- | ------------------------------- | -------------------- |
| [Pegged][pegged-repo]         | [PEG generator][peg] (cf. [pest])       | PEG string → parser via `mixin`; `ParseTree`      | **Yes** (CTFE)   | ✗ (GC `ParseTree`)              | Flagship, 4.1        |
| [libdparse][libdparse-repo]   | [Hand-written RD][top-down] + lexer-gen | vendored `std.experimental.lexer` + RD → AST      | tables at CT     | perf-tuned (pools), not `@nogc` | Backbone, **4.9**    |
| [dmd][dmd-repo]               | [Hand-written RD][top-down]             | reference D lexer + RD parser → AST               | no               | `core.stdc`/betterC-leaning     | Reference            |
| [sdc][sdc-repo]               | [Hand-written RD][top-down]             | independent RD over a `TokenRange`; `ambiguous.d` | no               | perf-oriented                   | Independent          |
| [pry][pry-repo]               | [Parser combinator][nom]                | `Stream`-over-ranges combinators; TLV             | CT-specialized   | Stream/zero-copy-leaning        | Stale-ish, 2.1       |
| [mir-ion][mir-ion-repo]       | [SIMD / data-parallel][simdjson]        | Ion/JSON/YAML/MsgPack (de)serialization engine    | CT introspection | **`@nogc`**, SIMD, zero-copy    | Active, 3.3          |
| [asdf][asdf-repo]             | [SIMD / data-parallel][simdjson]        | fast JSON + compact IR; SSE4.2                    | CT introspection | cache-oriented, low-alloc       | Active, 4.0          |
| [JSONiopipe][jsoniopipe-repo] | Streaming ([Angstrom][angstrom]-like)   | pull tokenizer over an `iopipe` char stream       | no               | streaming, no required DOM      | Niche                |
| [`std.json`][stdjson]         | Built-in DOM (baseline)                 | GC `JSONValue` DOM                                | no               | ✗ (GC; RED at-scale warning)    | Stdlib               |
| [dxml][dxml-repo]             | Pull (StAX)                             | range-based StAX pull + optional DOM              | no               | `@safe`, slicing, some `@nogc`  | Active, 4.6          |
| [D-YAML][dyaml-repo]          | Hand-written (spec-heavy)               | PyYAML-derived YAML 1.1 parser                    | no               | slicing input reuse             | Active, **4.9**      |
| [sdlite][sdlite-repo]         | Range-based (config)                    | SDLang parser/generator; pool allocator           | no               | pooled GC, low overhead         | Active, 3.8          |

<sub>dub scores are the registry's 0–5 popularity/quality signal at review time; "compile-time?"
distinguishes _parsing at CT_ (Pegged) from _tables/reflection generated at CT_ (libdparse,
mir). Per-cell sources are recorded in the survey's internal grounding tree.</sub>

---

## Compile-time PEG generation — Pegged

[Pegged][pegged-repo] (Philippe Sigaud; Boost) is D's flagship parser generator and the
ecosystem's headline demonstration of _metaprogramming as a parser generator_ — the D
answer to [pest]/ANTLR, but with a twist no runtime generator has: it can run the parser
**at compile time**. You write a PEG as a string, pass it to `grammar`, and `mixin` the
result:

```d
import pegged.grammar;

mixin(grammar(`
Arithmetic:
    Term     < Factor (Add / Sub)*
    Add      < "+" Factor
    Factor   < Primary (Mul / Div)*
    Primary  < Parens / Number / Variable
    Number   < ~([0-9]+)
    Variable <- identifier
`));
```

The generated `Arithmetic` parser then works _both_ ways ([`README.md`][pegged-repo]):

```d
enum parseTree1 = Arithmetic("1 + 2 - (3*x-5)*6");   // Parsing at compile-time
auto parseTree2 = Arithmetic(" 0 + 123 - 456 ");     // ...and at runtime too
```

It implements the full [PEG][peg] operator set (ordered choice `/`, `*`/`+`/`?`, syntactic
predicates `&`/`!`), supports semantic actions and a `dynamic/` runtime-grammar variant, and
generates packrat-style memoizing recursive-descent parsers. The cost is the one the
[PEG/packrat theory][peg] predicts and that matters for Sparkles: the output is a
**GC-allocated `ParseTree`** — Pegged is _not_ `@nogc` (the latest commit is literally "use
GC allocated slice instead of always alloca on stack"). It is the right tool for a
throwaway DSL or a compile-time grammar, the wrong tool for an allocation-bounded hot path.
The historical alternative, `ctpg` (youkei's Compile-Time Parser Generator), predates Pegged
with the same CTFE idea but is effectively abandoned.

---

## The D-language front-ends — three hand-written recursive-descent parsers

The most instructive data point in the D landscape is that the D _language itself_ is
parsed, in production, by **three independent hand-written recursive-descent parsers** — not
one of them generated. This is the same lesson the [top-down][top-down] page draws from
GCC/Clang/rustc: nobody _generates_ a production language parser.

- **[libdparse][libdparse-repo]** (dlang-community; dub score **4.9**, the highest in the
  space) — "Library for lexing and parsing D source code" ([`README.md`][libdparse-repo]).
  It is the ecosystem's backbone: **DCD, D-Scanner, dfmt, dfix** all parse D through it.
  Two-stage: a lexer built on a **compile-time lexer generator** feeding a hand-written RD
  parser (`src/dparse/parser.d`) that builds an AST. Its lexer is where
  **`std.experimental.lexer`** actually lives — the generator was **removed from Phobos**
  and the canonical copy is now vendored at
  [`src/std/experimental/lexer.d`][libdparse-lexer], documented as "a range-based
  compile-time _lexer generator_" driven by `staticTokens`/`dynamicTokens`/`tokenHandlers`
  declarations. The lexer uses SSE4.2 (`core.cpuid : sse42`) and a rollback/stack-buffer
  allocator for speed — perf-conscious, though not a blanket `@nogc`.
- **[dmd][dmd-repo]** (Walter Bright / D Language Foundation; Boost) — the **reference**
  implementation. `compiler/src/dmd/lexer.d` "converts source code into lexical tokens" and
  `compiler/src/dmd/parse.d` "takes a token stream from the lexer, and parses it into an
  abstract syntax tree" ([spec-linked][dmd-repo] to `dlang.org/spec/{lex,grammar}.html`). It
  leans on `core.stdc` and is written in a betterC-friendly style — the authoritative D
  grammar, hand-written throughout.
- **[sdc][sdc-repo]** (Amaury "deadalnix" Séchet; MIT; built on `libd`) — an **independent
  from-scratch** D compiler. Its parser (`src/d/parser/`) is RD over a `TokenRange`, and its
  standout file `ambiguous.d` confronts head-on the thing that makes D genuinely hard to
  parse — the type/expression/identifier ambiguity. `parseAmbiguous` is documented as
  ["Branch to the right code depending if we have a type, an expression or an
  identifier"][sdc-ambiguous] and drives a mode-parameterized disambiguation, a concrete
  worked example of the [general-parsing][general] problem of local ambiguity handled inside
  a deterministic RD parser.

For Sparkles the takeaway is direct: the [hand-written scannerless RD][top-down] the repo
already uses for [version schemes][v-parsing] is exactly what D's own toolchain does for a
_much_ harder grammar. The proposal builds on that grain, not against it.

---

## Parser combinators — pry (and the gap)

[pry][pry-repo] (Dmitry Olshansky — the `std.regex` author; BSL-1.0) is D's most serious
parser-combinator library and the closest local analogue to [nom]/[winnow]. It is
explicitly pragmatic: "the focus of development is pragmatic qualities such as achieving
performance on par with handwritten parsers" ([`README.md`][pry-repo]), with generic input
via a thin **`Stream`** wrapper over D ranges, compile-time-specialized building blocks
("one of a set of values", "given value"), and support for **TLV** (type-length-value)
binary formats. Architecturally it is the D design the survey most wants for an `@nogc`
combinator — but its last release is **2024** (v0.7.0), it is small, and it never grew the
zero-copy/`@nogc`-by-construction discipline of [nom]/[flatparse]. Other combinator attempts
(`sdpc`, `parsed`, `pushdown`) are one-off and low-signal. **This is the gap:** D has no
maintained, `@nogc`, zero-copy ordered-choice combinator, and none with [chumsky]-style
error recovery.

---

## High-performance JSON & serialization — the mir stack, asdf, JSONiopipe

D's answer to [simdjson][simdjson] + [serde](https://serde.rs) is the **mir** stack, and it
is genuinely world-class — but it is a **serialization** framework, not a general parsing
toolkit. `mir-algorithm` ships the `@nogc` substrate: `mir.serde` "implements common
de/serialization routines" and `mir.parse` is billed as "@nogc and nothrow Parsing
Utilities" ([Apache-2.0][mir-algo-repo], Ilia Ki / Symmetry Investments). The actual
parsers sit on top:

- **[mir-ion][mir-ion-repo]** — a "serialization engine [that] supports Text and binary
  [Ion](http://amzn.github.io/ion-docs), JSON, MsgPack, YAML" and more ([`README.md`][mir-ion-repo]).
  Amazon Ion is the core model; JSON/YAML/CSV are frontends. SIMD-optimized, `@nogc`-friendly,
  and driven by heavy compile-time introspection-based (de)serialization — the D design that
  most resembles [simdjson][simdjson] (SIMD) fused with [serde](https://serde.rs)
  (derive-based mapping). It is the high-performance successor to asdf.
- **[asdf][asdf-repo]** — the original libmir fast JSON: "a cache oriented string based JSON
  representation … specially geared towards transforming high volumes of JSON dataframes"
  ([`README.md`][asdf-repo]), SSE4.2-accelerated, built at Tamedia for click-stream
  processing. Its "Simple Document Format" is a compact binary intermediate — a
  [simdjson-tape][simdjson]-adjacent idea.
- **[JSONiopipe][jsoniopipe-repo]** (Steven Schveighoffer) — the streaming outlier, the D
  cousin of [Angstrom][angstrom]/attoparsec: "a streaming parser, which can be applied to
  any iopipe of character type … the entire data does not need to be held in memory for
  parsing" and "there is no required intermediate format" ([`README.md`][jsoniopipe-repo]),
  with an optional DOM. Pull/lazy, low-allocation, JSON5-capable.

The stdlib baseline is [`std.json`][stdjson], and it is honest about its limits — the module
header carries a red warning that its GC `JSONValue` DOM, "at the range of hundreds of
megabytes … is known to cause and exacerbate GC problems … try replacing it with a stream
parser" ([`std/json.d`][stdjson]). It is the correctness-first baseline every faster D JSON
parser is measured against. (`hipjson` is a newer SIMD-DOM attempt; niche.)

---

## Structured-data & config parsers

- **[dxml][dxml-repo]** (Jonathan M Davis) — "a library … for parsing XML 1.0 [whose] parser
  is a range-based [StAX parser](https://en.wikipedia.org/wiki/StAX), but … also has support
  for generating a DOM" ([`README.md`][dxml-repo]). `@safe`, pure-D, slicing over the input;
  the clean **pull-parser** design point in D.
- **[D-YAML][dyaml-repo]** (dlang-community; dub score 4.9) — the canonical D YAML, PyYAML-derived
  (~YAML 1.1), a spec-heavy hand-written parser with slicing input reuse.
- **[sdlite][sdlite-repo]** (Sönke Ludwig) — "a lightweight SDLang parser/generator … providing
  a range based API. While the parser still uses the GC … it uses a very efficient pool based
  allocation scheme that has very low computation and memory overhead" ([`README.md`][sdlite-repo]).
  The modern SDLang parser (SDLang is dub's own recipe format; dub bundles its own copy).
  Supersedes the older `sdlang-d`.

A few adjacent points worth a line: **[d_tree_sitter][dtreesitter]** provides D FFI bindings
to the [tree-sitter][tree-sitter] C runtime — the D path to incremental parsing without
reimplementing it; **[httparsed][httparsed]** is a `@nogc`/betterC HTTP/1 request-response
parser (picohttpparser-style), a nice small proof that `@nogc` parsing is idiomatic in D;
and **cerealed** is a compile-time-introspection _binary_ serialization library (the D
`cereal`), parsing-adjacent but not a grammar parser.

---

## The in-tree Sparkles parsers — the baseline

Sparkles already hand-parses several small languages, and they set the idiom the
[proposal][proposal] must fit:

- **Version schemes** ([`sparkles.versions.parsing`][v-parsing] + `schemes/`) — hand-written
  **scannerless recursive descent** over a `scope const(char)[]` cursor. The engine
  `parseSemVerShaped` walks a scheme's components with `static foreach` (design-by-introspection
  over the scheme struct), advancing the slice and a byte offset in lockstep; the node-semver
  range grammar is a second, deeper RD layer. Entry points are `@safe pure nothrow @nogc`, and
  the result type is `Expected!(T, ParseError, NoGcHook)` — no exceptions, structured
  `(code, offset)` errors, fail-fast.
- **The `@nogc` text substrate** ([`sparkles.base.text`][base-text]) — `readers.d` provides
  **zero-copy, cursor-advancing** primitives (`readInteger`, `skipSpaces`, `tryConsume`,
  `readUntil`) that take `ref scope const(char)[]` and advance only on success, returning
  slices into the input; `writers.d` mirrors them for output ranges (`SmallBuffer`); `errors.d`
  defines the shared `ParseError`/`ParseErrorCode`/`Expected` vocabulary. Documented as
  "mechanism, not policy" — the ideal foundation for a combinator layer.
- **CLI arguments** ([`sparkles.core_cli.args`][cli-args]) — the pragmatic exception: a
  compile-time UDA (`@CliOption`) wrapper around Phobos `std.getopt`, which uses **GC +
  exceptions**. Explicitly _not_ the `@nogc`/`Expected` idiom; a candidate to migrate onto the
  proposed toolkit.
- **Terminal VT sequences** (`sparkles:ghostty`) — delegated to the C `libghostty-vt` engine
  via ImportC; Sparkles owns no D-side VT state machine.

---

## Synthesis — the gap Sparkles fills

Map the D landscape onto the survey's taxonomy and the shape is clear:

| Survey category                  | D's strongest option                      | Fit for an `@nogc` Sparkles parser                          |
| -------------------------------- | ----------------------------------------- | ----------------------------------------------------------- |
| [PEG generator][peg]             | [Pegged][pegged-repo] (compile-time)      | ✗ GC `ParseTree`; great for DSLs, wrong for hot paths       |
| [Hand-written RD][top-down]      | dmd / libdparse / sdc                     | ✓ the grain Sparkles already follows (version schemes)      |
| [Combinator][nom]                | [pry][pry-repo] (stale)                   | ✗ no maintained `@nogc`, zero-copy combinator exists        |
| [SIMD / high-perf][simdjson]     | [mir-ion][mir-ion-repo]/[asdf][asdf-repo] | ✓ but _serialization_, not general parsing; heavyweight dep |
| Streaming ([Angstrom][angstrom]) | [JSONiopipe][jsoniopipe-repo]             | ~ iopipe-coupled; JSON-specific                             |
| [Recovering][chumsky]            | — (none)                                  | ✗ no D parser offers [chumsky]-style recovery               |

D has a strong compile-time generator (but GC-bound), a proven hand-written-RD tradition
(D-specific), and a world-class `@nogc`/SIMD _serialization_ stack (mir) — yet **nothing in
the middle**: no small, maintained, `@nogc`, zero-copy **ordered-choice combinator** over
`const(char)[]` slices, and no **error-recovering** parser. That middle is exactly where
Sparkles' needs sit (version constraints, config, CLI, small DSLs), exactly what the existing
[`sparkles.base.text`][base-text] readers are shaped to support, and exactly the
[design center the comparison identifies][comparison-fit]: zero-copy scannerless RD in the
[nom]/[winnow] mold, zero-allocation validators ([flatparse]'s proof), a [Pratt][pratt] loop
for constraint grammars, and `Expected!(T, E)` results. The
[Sparkles parsing proposal][proposal] cashes this in.

---

## Sources

Every project characterization is grounded against a locally pinned checkout under
`$REPOS/dlang/` (pinned SHAs and per-claim verification are recorded in the survey's internal
grounding tree, `docs/research/parsing/grounding/`, which the published pages do not link).
Primary artifacts: the project READMEs and source trees named inline (Pegged `README.md`; libdparse `README.md`

- vendored `src/std/experimental/lexer.d`; dmd `compiler/src/dmd/{lexer,parse}.d`; sdc
  `src/d/parser/ambiguous.d`; pry `README.md`; mir-algorithm `source/mir/{serde,parse}.d`;
  mir-ion & asdf `README.md`; JSONiopipe `README.md`; Phobos `std/json.d`; dxml/D-YAML/sdlite
  `README.md`), plus the in-tree Sparkles sources.

<!-- References -->

<!-- Within-tree: survey -->

[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[comparison-fit]: ./comparison.md#where-a-sparkles-parser-would-fit
[peg]: ./theory/peg-packrat.md
[top-down]: ./theory/top-down.md
[general]: ./theory/general-parsing.md
[pratt]: ./theory/pratt-precedence.md
[incremental]: ./theory/incremental.md
[pest]: ./pest.md
[nom]: ./rust-nom.md
[winnow]: ./rust-winnow.md
[chumsky]: ./rust-chumsky.md
[flatparse]: ./haskell-flatparse.md
[simdjson]: ./simdjson.md
[angstrom]: ./ocaml-angstrom.md
[tree-sitter]: ./tree-sitter.md

<!-- The proposal this page feeds -->

[proposal]: ../../specs/parsing/index.md

<!-- D ecosystem (external) -->

[pegged-repo]: https://github.com/PhilippeSigaud/Pegged
[libdparse-repo]: https://github.com/dlang-community/libdparse
[libdparse-lexer]: https://github.com/dlang-community/libdparse/blob/master/src/std/experimental/lexer.d
[dmd-repo]: https://github.com/dlang/dmd/blob/master/compiler/src/dmd/parse.d
[sdc-repo]: https://github.com/snazzy-d/sdc
[sdc-ambiguous]: https://github.com/snazzy-d/sdc/blob/master/src/d/parser/ambiguous.d
[pry-repo]: https://github.com/DmitryOlshansky/pry-parser
[mir-algo-repo]: https://github.com/libmir/mir-algorithm
[mir-ion-repo]: https://github.com/libmir/mir-ion
[asdf-repo]: https://github.com/libmir/asdf
[jsoniopipe-repo]: https://github.com/schveiguy/jsoniopipe
[stdjson]: https://github.com/dlang/phobos/blob/master/std/json.d
[dxml-repo]: https://github.com/jmdavis/dxml
[dyaml-repo]: https://github.com/dlang-community/D-YAML
[sdlite-repo]: https://github.com/s-ludwig/sdlite
[dtreesitter]: https://github.com/aminya/d-tree-sitter
[httparsed]: https://github.com/tchaloupka/httparsed

<!-- In-tree Sparkles sources -->

[v-parsing]: https://github.com/PetarKirov/sparkles/blob/main/libs/versions/src/sparkles/versions/parsing.d
[base-text]: https://github.com/PetarKirov/sparkles/blob/main/libs/base/src/sparkles/base/text/package.d
[cli-args]: https://github.com/PetarKirov/sparkles/blob/main/libs/core-cli/src/sparkles/core_cli/args.d
