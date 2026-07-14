# Zig tokenizer (Zig)

The Zig standard library's lexer — a hand-written, table-free, `comptime`-driven scanner that turns `[:0]const u8` source into a flat stream of `Token`s (each a tag plus a byte range), allocating nothing and consulting no transition table. It is the front half of the self-hosted Zig compiler's parse pipeline.

| Field                    | Value                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Language                 | Zig                                                                                                           |
| License                  | MIT (Expat) — verified at [`LICENSE`][license] ("The MIT License (Expat) … Copyright (c) Zig contributors")   |
| Repository               | [`ziglang/zig`][repo] (path [`lib/std/zig/tokenizer.zig`][tokenizer])                                         |
| Documentation            | [ziglang.org][zig] · the source file itself (no separate API docs for the internal lexer)                     |
| Category                 | Hand-written lexer — table-free, zero-allocation                                                              |
| Algorithm class          | Hand-written DFA-style state machine, expressed with Zig's labeled-`switch` continuation idiom                |
| Output                   | Flat `Token`s — a `Tag` enum + a `loc: { start, end }` byte range; zero-copy into the source buffer           |
| Performance / allocation | No heap, no transition table; operates in place on a sentinel-terminated (`[:0]const u8`) buffer              |
| Keyword lookup           | A compile-time-built `std.StaticStringMap(Tag)` — no runtime initialization, no heap                          |
| Notes                    | Feeds a hand-written recursive-descent parser (`Parse.zig`) → a compact `Ast` (`MultiArrayList`, index nodes) |

> [!NOTE]
> This subject is a **lexer / tokenizer, not a full parser** — it produces a token stream, not a tree. The catalog's analysis spine still applies (the algorithm class is a hand-written [DFA][formal]-style scanner; "error recovery" is invalid-token handling; the performance/allocation model is zero-allocation and table-free), but where the spine asks about grammar composition or ASTs, the answer is "that lives one layer up, in [`Parse.zig`][top-down]." It is the survey's cleanest example of a **hand-written, allocation-free lexer**, to be read against the generator-based approach (Ragel, [`re2c`][re2c]) and the whole-input SIMD approach of [`simdjson`][simdjson].

---

## Overview

### What it solves

The lexer converts a Zig source buffer into the token stream that the recursive-descent parser consumes. It is deliberately minimal: the entire mutable state is a buffer reference and a cursor.

```zig
pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,
```

([`tokenizer.zig:325`][tokenizer]) There is no allocator field, no output buffer, no lookahead ring — the tokenizer is a **pull API**: each call to `next()` scans forward from `index` and returns one `Token`. A token carries no text, only a tag and the byte range it covers:

```zig
pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };
```

([`tokenizer.zig:3`][tokenizer]) Because a `Token` is just `{ tag, start, end }`, the lexeme is recovered by slicing the source (`buffer[loc.start..loc.end]`) — the tokenizer never copies or allocates a string. Keywords, identifiers, numbers, and string bodies all remain zero-copy views into the original buffer.

### Design philosophy

A compiler standard library _could_ generate its lexer from a regular-expression spec (the [`re2c`][re2c] / Ragel / flex route). Zig hand-writes it instead, for three reasons visible in the code:

1. **No build-time codegen, no data tables.** The state machine is ordinary Zig control flow (a `switch` over an enum of states); there is no generated transition table to ship, regenerate, or keep in sync with the grammar. The keyword set is the only "table," and it is a `comptime` value baked into the binary (below).
2. **Zero allocation, in place.** The lexer reads a `[:0]const u8` and mutates a `usize` cursor. Nothing is heap-allocated at any point — a property the compiler relies on for speed and which makes the lexer trivially usable in `comptime` and in freestanding contexts.
3. **Deterministic recovery over precise diagnostics.** On a bad byte the lexer emits an `.invalid` token and resynchronizes at the next newline rather than throwing — it always finishes, always ending with `eof`. Its own doc comment states the contract:

   > `/// After this returns invalid, it will reset on the next newline, returning tokens starting from there.`
   > `/// An eof token will always be returned at the end.`
   > — [`tokenizer.zig:389`][tokenizer]

---

## How it works

### The `Token` and its `Tag`

`Token.Tag` ([`tokenizer.zig:65`][tokenizer]) is a flat enum of ~120 variants: the trivia-free lexical categories (`identifier`, `number_literal`, `string_literal`, `char_literal`, `doc_comment`, `container_doc_comment`, `builtin`, `eof`, `invalid`), every operator and punctuator spelled out (`plus`, `plus_plus`, `plus_percent`, `plus_pipe_equal`, `angle_bracket_angle_bracket_left_pipe_equal`, …), and one `keyword_*` per Zig keyword. Two helpers project a tag back to text: `lexeme()` returns the fixed spelling for tags that have one (operators, keywords) or `null` for the variable ones (identifiers, literals), and `symbol()` turns any tag into a human-readable name for diagnostics ([`tokenizer.zig:184`, `:308`][tokenizer]).

Note what is _absent_ from the tag set: there is **no whitespace token and no ordinary-comment token**. In `next()`'s start state, spaces, tabs, newlines and CRs advance the cursor and reset the token start (`tokenizer.zig:414`), and `//` line comments are consumed and discarded (`tokenizer.zig:991`). Only `///` (`doc_comment`) and `//!` (`container_doc_comment`) survive as tokens. The token stream is therefore **trivia-free** — a sharp contrast with lossless-CST lexers like [`tree-sitter`][tree-sitter]'s or Roslyn's, which retain every space and comment.

### The `comptime` keyword map

Keywords are not baked into the state machine. The scanner reads a maximal identifier run and _then_ does a single map lookup:

```zig
pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "addrspace", .keyword_addrspace },
    .{ "align", .keyword_align },
    // … 45 entries …
    .{ "while", .keyword_while },
});

pub fn getKeyword(bytes: []const u8) ?Tag {
    return keywords.get(bytes);
}
```

([`tokenizer.zig:12`, `:61`][tokenizer]) `std.StaticStringMap(...).initComptime(...)` builds the lookup structure **at compile time**, so no runtime initialization and no heap allocation occur; the map is a constant in the binary. In the identifier state the default tag stays `.identifier` and is overwritten only on a hit:

```zig
.identifier => {
    self.index += 1;
    switch (self.buffer[self.index]) {
        'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
        else => {
            const ident = self.buffer[result.loc.start..self.index];
            if (Token.getKeyword(ident)) |tag| {
                result.tag = tag;
            }
        },
    }
},
```

([`tokenizer.zig:656`][tokenizer]) This keeps keyword recognition entirely out of the character-level DFA: the DFA only distinguishes "identifier-shaped run"; whether that run _is_ a keyword is a post-hoc, `comptime`-map question.

### The labeled-`switch` state machine

The heart of `next()` is a table-free hand-written DFA written with Zig's **labeled-`switch` continuation** idiom. A labeled `switch` whose cases can `continue` back to the same switch with a new operand:

```zig
state: switch (State.start) {
    .start => switch (self.buffer[self.index]) {
        // …
        '=' => continue :state .equal,
        // …
    },
    .equal => {
        self.index += 1;
        switch (self.buffer[self.index]) {
            '=' => { result.tag = .equal_equal; self.index += 1; },
            '>' => { result.tag = .equal_angle_bracket_right; self.index += 1; },
            else => result.tag = .equal,
        }
    },
    // … ~50 more states …
}
```

([`tokenizer.zig:399`][tokenizer]) `State` is an ordinary enum of the DFA's ~50 states ([`tokenizer.zig:342`][tokenizer]). A transition is `continue :state .<target>`: control jumps to that case and re-evaluates the outer `switch` with the new state. Because each target is a compile-time-known enum value, the Zig compiler can lower `continue :state .foo` to a **direct jump to that case** rather than recomputing a dispatch — the same shape a generated lexer gets from a computed-`goto` ladder, but with the transitions written as readable control flow instead of stored in a table. States that consume no further input (single-character tokens) just set `result.tag` and fall through; states that need one more character (`+` vs `+=` vs `++` vs `+%` vs `+|`, `tokenizer.zig:606`) peek `self.buffer[self.index]` and branch. This is **maximal munch** with bounded lookahead, encoded structurally.

### Character-class dispatch

The `.start` case is a `switch` over the current byte whose _ranges_ are the character classes ([`tokenizer.zig:400`][tokenizer]):

| Byte class (range pattern)         | Action                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------- |
| `' ', '\n', '\t', '\r'`            | skip; advance `result.loc.start`; re-enter `.start` (whitespace = trivia) |
| `'a'...'z', 'A'...'Z', '_'`        | `tag = .identifier`; → `.identifier`                                      |
| `'0'...'9'`                        | `tag = .number_literal`; → `.int`                                         |
| `'"'` / `'\''`                     | `tag = .string_literal` / `.char_literal`; → the matching state           |
| `'@'`                              | → `.saw_at_sign` (either a `builtin` or a `@"…"` quoted identifier)       |
| operator bytes (`=`,`+`,`<`,`.`,…) | → the per-operator state that resolves the maximal munch                  |
| `'\\'`                             | `tag = .multiline_string_literal_line`; → `.backslash`                    |
| `0` (the sentinel)                 | EOF **iff** `index == buffer.len`, else `.invalid`                        |
| `else`                             | → `.invalid`                                                              |

The ranges (`'a'...'z'`) _are_ the classification — no lookup table, no `isAlpha` call. `@"…"` quoted identifiers and `@builtin` calls are disambiguated in `.saw_at_sign` (`tokenizer.zig:533`): `@"` reuses the string-literal scanner but tags the result `.identifier`, while `@name` becomes a `.builtin`.

### The sentinel trick

The buffer type is `[:0]const u8` — a slice with a guaranteed `0` byte one past the end. This lets the hot loop **omit a per-byte bounds check**: the scanner reads `self.buffer[self.index]` freely, and the only `0`-handling is a branch that asks whether the `0` is the real terminator or an embedded null:

```zig
0 => {
    if (self.index == self.buffer.len) {
        return .{ .tag = .eof, .loc = .{ .start = self.index, .end = self.index } };
    } else {
        continue :state .invalid;
    }
},
```

([`tokenizer.zig:401`][tokenizer]) An embedded NUL is thus an `.invalid` token, but the common case (running off the end) costs one comparison, made once, at the very end of the input. `init()` also uses the buffer directly to skip a leading UTF-8 BOM before scanning ([`tokenizer.zig:334`][tokenizer]).

### Numbers: deliberately permissive

The number states (`.int`, `.int_period`, `.int_exponent`, `.float`, `.float_exponent`) accept a **broad superset** of valid literals — essentially "digits, letters except the exponent markers `e`/`E`/`p`/`P`, underscores, and at most the structural `.`" (`tokenizer.zig:1030`). So `0b9`, `0x0z`, and `1z_1` all tokenize as a single `number_literal`; the tests assert exactly this (`try testTokenize("0b9", &.{.number_literal});`, `tokenizer.zig:1417`). The lexer's job is only to find the _extent_ of the number; validating that the digits are legal for the radix is deferred to a separate number-parsing pass. This is a recurring lexer pattern — over-accept cheaply now, diagnose precisely later — and it keeps the DFA small.

### Invalid tokens and newline resync

There is no exception path. Any malformed construct routes to the `.invalid` state, which scans forward to the next newline (or EOF) and emits one `.invalid` token spanning the bad region (`tokenizer.zig:520`). Control characters inside strings, char literals, and comments (`0x01...0x09, 0x0b...0x1f, 0x7f`) are likewise rejected into `.invalid` (e.g. `tokenizer.zig:697`), as are stray CR and TAB inside comments and multi-line strings (per [zig-spec#38][zigspec38], asserted across `tokenizer.zig:1616`). After an `.invalid`, the next `next()` call resumes cleanly at the following line — the resync contract quoted above.

---

## Algorithm & grammar class

The tokenizer recognizes a **regular language** — Zig's lexical grammar — with a **hand-written deterministic finite automaton**. Every state consumes zero or one byte and transitions to a compile-time-known next state; there is no stack, no backtracking, and no re-scanning of consumed input. Lookahead is bounded (maximal munch resolves multi-character operators with one peek at a time), so the scan is a **single linear left-to-right pass**, O(n) in the input length. The pushdown/context-free machinery — matching braces, expression nesting — lives one layer up in the [recursive-descent parser][top-down], not here; the lexer emits a flat stream and knows nothing of nesting. Compared with [`simdjson`][simdjson], which reformulates the same class of finite-state work as branchless SIMD over 64-byte windows, Zig's lexer is resolutely **character-at-a-time** — but table-free and branch-light, with the classification folded into `switch` ranges.

## Interface & composition model

The interface is a minimal **pull iterator**: `Tokenizer.init(buffer)` then repeated `next()`, each returning one `Token`; `eof` is returned indefinitely once reached. There is no token buffer — the caller drives consumption. This composes directly into the compiler's next stage: [`Parse.zig`][top-down] is a hand-written recursive-descent parser that pulls tokens and builds a compact `Ast` — a `std.MultiArrayList` of index-referenced nodes (the AST's top comment: "_Abstract Syntax Tree for Zig source code. … the root node is at nodes[0]_", [`Ast.zig:1`][ast]). Notably, the AST's stored `TokenList` keeps only each token's `tag` and `start` offset (`Ast.zig:29`), not the full `{start, end}` range — a token's end is recomputed by re-tokenizing on demand, trading a little recomputation for a smaller AST. There is **no grammar DSL and no composition across grammars**: like [`simdjson`][simdjson], this parses exactly one language, and its reusability is as a concrete, copyable design rather than a configurable engine.

## Performance

- **Allocation: none.** No heap at any point; the only state is a slice reference and a `usize`. The keyword map is a `comptime` constant.
- **No transition table.** The DFA is control flow; `continue :state .foo` lowers to direct jumps. Nothing is loaded from a data table per byte.
- **Single O(n) pass, no backtracking, no memoization.** Each byte is visited a bounded number of times (maximal-munch peeks aside). This is the structural opposite of [PEG/packrat][concepts] memoization.
- **Sentinel-terminated input** removes the per-byte length check from the hot path; the end-of-buffer test is made once.
- **Branch-light classification** via `switch`-range character classes rather than table lookups or chained comparisons.

The lexer is not SIMD and makes no throughput claims in-tree; its performance argument is _low constant factor per byte and zero allocation_, which is what a self-hosted compiler front-end and `zig fmt` (which re-tokenizes constantly) need. For raw bytes/second on structured input, the SIMD [`simdjson`][simdjson] is the other pole of the [comparison][comparison].

## Error handling & recovery

Errors are **values, not exceptions**: a malformed lexeme becomes an `.invalid` token, and the tokenizer resynchronizes at the next newline, guaranteeing forward progress and a terminating `eof`. Diagnostics are coarse by design — an `.invalid` token marks _that_ a region is bad and its extent (start of the bad run to the newline/EOF), leaving precise messages to the parser and later stages. The invariants are **fuzz-tested**: `testPropertiesUpheld` (`tokenizer.zig:1689`) drives the tokenizer on weighted-random bytes and asserts, among others, that "_invalid token always ends at newline or eof_" (`tokenizer.zig:1716`) and that the `eof` token is always zero-length at `source.len`. This recover-and-continue posture is milder than [`simdjson`][simdjson]'s strict first-error-stop, but far simpler than the full incremental error recovery of [`tree-sitter`][tree-sitter] — appropriate for a lexer whose consumer (the parser) does its own higher-level recovery.

## Ecosystem & maturity

The tokenizer is a core, heavily exercised component of the Zig standard library and the self-hosted compiler: it is the lexer for the whole toolchain, for `zig fmt`, and for downstream tools like the Zig Language Server that build on `std.zig`. It ships with an extensive in-file test suite (`tokenizer.zig:1091` onward) covering keywords, every number-literal radix and edge case, unicode escapes, comment/doc-comment disambiguation, saturating operators, BOM handling, and control-character rejection, plus the fuzz harness above. As part of `ziglang/zig` it is MIT-licensed and tracks the language: the labeled-`switch` continuation form used here is itself a relatively recent Zig control-flow feature, and this file is one of its showcase uses in the standard library.

---

## Strengths

- **Zero allocation, tiny state.** A slice + a cursor; usable in `comptime` and freestanding contexts, and cheap to embed.
- **Table-free and codegen-free.** The DFA is readable control flow — no generated transition table to ship or resync with the grammar; the only "table" is a `comptime` keyword map.
- **Zero-copy tokens.** `{ tag, start, end }` slices back into the source; no lexeme strings are ever materialized.
- **Fast, branch-light hot path.** `switch`-range character classes plus a sentinel-terminated buffer keep per-byte work minimal and bounds-check-free.
- **Deterministic recovery.** Always terminates with `eof`; `.invalid` + newline resync makes it robust on arbitrary bytes, and the property is fuzz-tested.
- **Clean layering.** Keyword recognition is a post-scan map lookup, and radix validation is deferred — the DFA stays small and each concern lives in one place.

## Weaknesses

- **Coarse diagnostics.** `.invalid` marks a bad region but not _why_; precise error messages must come from later stages.
- **Trivia-free stream.** Discarding whitespace and ordinary comments means the token stream is not lossless; reconstructing exact formatting (for `zig fmt`) relies on re-tokenizing from stored offsets rather than a preserved trivia stream — unlike lossless-CST designs ([`tree-sitter`][tree-sitter], Roslyn).
- **Over-accepting number literals** pushes real validation downstream; a `number_literal` token is not guaranteed to be a valid number.
- **Single grammar, not an engine.** It is Zig-specific; reuse means copying the design, not configuring a generator (contrast Ragel / [`re2c`][re2c]).
- **Character-at-a-time.** No data-parallelism; for pure scan throughput on large inputs, a SIMD design ([`simdjson`][simdjson]) does more per instruction.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                           | Trade-off                                                                      |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Hand-written DFA** via labeled-`switch` continuation, no table   | Readable control flow, no build-time codegen, jumps as fast as a computed-`goto`    | The grammar lives in code, not a spec; changes are manual edits, not regen     |
| **Zero allocation**, state is a slice + cursor                     | Usable in `comptime` / freestanding; predictable, fast; trivial to embed            | Caller owns the buffer and its lifetime; no owned token storage                |
| **Tokens as `{ tag, start, end }`**, zero-copy                     | No lexeme allocation; lexemes recovered by slicing source                           | Token is meaningless without the original buffer; text must be re-sliced       |
| **Sentinel-terminated `[:0]const u8`** buffer                      | Drops per-byte bounds checks; sentinel doubles as the stop condition                | Caller must supply a NUL-terminated slice; embedded NUL is an `.invalid` token |
| **Keywords via `comptime` `StaticStringMap`**, looked up post-scan | DFA only recognizes identifier shape; no runtime init, no heap; keywords stay a set | One map lookup per identifier (cheap, but not folded into the scan)            |
| **Discard whitespace and `//` comments** (trivia-free stream)      | Smaller token stream; parser sees only meaningful tokens                            | Not lossless; formatters must recompute layout from offsets                    |
| **Over-accept number literals**, validate later                    | Keeps the DFA small; extent-finding is cheap and unambiguous                        | A `number_literal` token may still be an invalid number; needs a second pass   |
| **`.invalid` token + newline resync**, never throw                 | Always terminates; robust to arbitrary bytes; simple, fuzz-tested contract          | Diagnostics are coarse; precise errors are someone else's job                  |

---

## Relevance to Sparkles

For a `@nogc` D tokenizer, this is the **closest model in the survey**. Every one of its load-bearing choices maps onto a Sparkles constraint:

- **Zero allocation, cursor-only state** is exactly the `@nogc` posture the [`base` text package][concepts] already takes — a lexer as a `struct { const(char)[] buffer; size_t index; }` with a `nextToken()` method needs no allocator and can be `@safe pure nothrow @nogc`, mirroring `Tokenizer`.
- **Zero-copy `{ tag, start, end }` tokens** avoid the string allocations that would otherwise break `@nogc`; D slices (`buffer[start .. end]`) recover lexemes exactly as Zig's do.
- **`switch`-range character classes** and **maximal-munch operator states** translate directly to D's `switch`/`case 'a': .. case 'z':` range cases — no `std.regex`, no generated table, which sidesteps the [`dip1000`/`scope` clashes][concepts] that Phobos regex triggers under this repo's preview flags.
- **`comptime` keyword recognition** has a direct D analogue: a CTFE-built perfect-hash or a `static immutable` sorted table, keeping keyword lookup allocation-free and out of the DFA.
- **`.invalid` + resync** is the D [`Expected`][concepts]-friendly stance: a lexer that returns tokens (including an invalid one) rather than throwing composes with `Expected!(Token, LexError)` and with `@nogc nothrow` callers.

The contrast points are equally instructive: where a generator (Ragel, [`re2c`][re2c]) would emit a transition table and a build step, Zig shows that a **hand-written** table-free DFA is both readable and fast — the right default for a small, well-understood lexical grammar embedded in a library; and where [`simdjson`][simdjson] goes data-parallel for raw throughput, Zig stays character-at-a-time, which is the sane starting point unless profiling proves a scan bottleneck. A Sparkles lexer should start here and reach for SIMD only if measurements demand it.

---

## Sources

- [`ziglang/zig` — GitHub repository][repo] · [ziglang.org][zig]
- [`lib/std/zig/tokenizer.zig` — the tokenizer: `Token`, `Tag`, `keywords`, `Tokenizer.next` labeled-`switch` DFA, tests + fuzz harness][tokenizer]
- [`lib/std/zig/Ast.zig` — the compact index-based AST the hand-written `Parse.zig` builds from this token stream][ast]
- [`LICENSE` — MIT (Expat), "Copyright (c) Zig contributors"][license]
- [ziglang/zig-spec#38 — TAB/CR handling inside comments and multi-line strings (cited in the tests)][zigspec38]
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · [formal languages / DFA][formal] · [top-down / recursive descent (the parser it feeds)][top-down] · [`simdjson` (SIMD data-parallel)][simdjson] · [`tree-sitter` (its own lexer, lossless & recovering)][tree-sitter]

<!-- References -->

[repo]: https://github.com/ziglang/zig
[zig]: https://ziglang.org/
[tokenizer]: https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/zig/tokenizer.zig
[ast]: https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/zig/Ast.zig
[license]: https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/LICENSE
[zigspec38]: https://github.com/ziglang/zig-spec/issues/38
[re2c]: https://re2c.org/
[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[formal]: ./theory/formal-languages.md
[top-down]: ./theory/top-down.md
[simdjson]: ./simdjson.md
[tree-sitter]: ./tree-sitter.md
