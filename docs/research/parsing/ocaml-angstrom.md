# Angstrom (OCaml)

OCaml's high-performance [parser-combinator][concepts] library: a direct descendant of Haskell's [attoparsec][parsec], it keeps the continuation-passing core but adapts it to OCaml with `Bigstringaf`-backed **zero-copy** input, a **buffered and an unbuffered incremental** interface, and non-blocking integration with the `Async`/`Lwt` concurrency libraries. Parsers backtrack by default and support unbounded lookahead, with an explicit `commit` to bound backtracking for streaming.

| Field                     | Value                                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Language                  | OCaml (`>= 4.04.0`)                                                                                          |
| License                   | BSD-3-Clause                                                                                                 |
| Repository                | [inhabitedtype/angstrom][angstrom-repo]                                                                      |
| Package                   | [`angstrom` on OPAM][angstrom-opam]                                                                          |
| Key author                | Spiros Eliopoulos (Inhabited Type LLC)                                                                       |
| Category                  | Parser combinator (OCaml; high-performance)                                                                  |
| Algorithm / grammar class | PEG-like **backtracking recursive descent** with **unbounded lookahead**; ordered, left-biased choice        |
| Input model               | `string` / `bigstring`; **buffered** and **unbuffered** incremental interfaces                               |
| Zero-copy                 | `Bigstringaf`-backed buffer; unbuffered interface + `Unsafe` primitives expose the buffer without copying    |
| Error posture             | Backtracking by default; `commit` bounds it; failure carries marks (`<?>`) + a message — **no line numbers** |
| Lineage                   | CPS port of [attoparsec][parsec]; diverged for memory efficiency + monadic-concurrency (`Async`/`Lwt`) fit   |

> [!NOTE]
> Angstrom sits in the same niche as [attoparsec][parsec] — high-throughput, zero-copy, incremental combinators for network protocols and serialization formats — but in OCaml. Where the [Parsec/attoparsec/Megaparsec lineage][parsec] spans four Haskell libraries along an _error-quality-vs-speed_ axis, Angstrom is squarely at the attoparsec end: it trades rich errors for speed and streaming, and (unlike Parsec) **always backtracks** rather than distinguishing consumed from empty failure. Its unusual combination is doing this while also supporting an unbuffered, non-blocking, zero-copy input model that the Haskell lineage does not.

---

## Overview

### What it solves

A [parser combinator][concepts] builds a parser as an ordinary host-language value composed from smaller parsers, with no separate grammar DSL or code-generation step — the same stance the [Haskell lineage][parsec] canonicalised. Angstrom takes that model and aims it at one target: **efficient, incremental parsing of network protocols and serialization formats**. The OPAM synopsis states the goal tersely ([`angstrom.opam`][angstrom-repo]):

> _"Parser combinators built for speed and memory-efficiency"_

The README opens on the same three-way promise — efficiency, expressiveness, and control over blocking ([`README.md`][angstrom-repo]):

> _"Angstrom is a parser-combinator library that makes it easy to write efficient, expressive, and reusable parsers suitable for high-performance applications. It exposes monadic and applicative interfaces for composition, and supports incremental input through buffered and unbuffered interfaces. Both interfaces give the user total control over the blocking behavior of their application, with the unbuffered interface enabling zero-copy IO. Parsers are backtracking by default and support unbounded lookahead."_

The distribution is explicit about the intended workloads: it ships full parsers for real RFCs as worked examples — an [HTTP/1.1 parser][http-example] (`examples/rFC2616.ml`) and a [JSON parser][json-example] (`examples/rFC7159.ml`) ([`README.md`][angstrom-repo]):

> _"Angstrom is written with network protocols and serialization formats in mind. As such, its source distribution includes implementations of various RFCs that are illustrative of real-world applications of the library."_

### Design philosophy

Angstrom's design is best understood as a **critique of the lazy-character-stream model** used by the OCaml Parsec ports. Its README lays out the argument directly ([`README.md`, "Comparison to Other Libraries"][angstrom-repo]):

> _"Most of them are derivatives of or inspired by [Parsec]. As such, they require the use of a `try` combinator to achieve backtracking, rather than providing it by default. They also all use something akin to a lazy character stream as the underlying input abstraction. While this suits Haskell quite nicely, it requires blocking read calls when the entire input is not immediately available — an approach that is inherently incompatible with monadic concurrency libraries such as [Async] and [Lwt] … Another consequence of this approach to modeling and retrieving input is that the parsers cannot iterate over sections of input in a tight loop, which adversely affects performance."_

Two design decisions fall out of that critique:

1. **Backtracking by default, not opt-in.** Where Parsec makes `<|>` predictive and forces `try` to recover arbitrary lookahead ([see the Parsec deep-dive][parsec]), Angstrom's `<|>` simply resets the input and tries the alternative. The README's feature table marks _"Backtracking by default"_ ✅ for Angstrom and ❌ for the Parsec-derived `mparser`, `planck`, and `opal`.
2. **Explicit input model instead of a lazy stream.** Input is a `Bigstringaf.t` region the parser iterates over in a tight loop, fed incrementally through a buffered or an unbuffered interface — the latter handing raw buffer bytes to the caller with no copy.

The genealogy is stated in the acknowledgements ([`README.md`][angstrom-repo]):

> _"This library started off as a direct port of the inimitable [attoparsec] library. While the original approach of continuation-passing still survives in the source code, several modifications have been made in order to adapt the ideas to OCaml, and in the process allow for more efficient memory usage and integration with monadic concurrency libraries."_

---

## How it works

### The parser as a CPS function with two continuations

A parser is a record wrapping a single polymorphic `run` field — a **continuation-passing** function that receives the input, a position, a "more input?" flag, a **failure continuation**, and a **success continuation** ([`lib/parser.ml`][angstrom-repo]):

```ocaml
type 'a with_state = Input.t ->  int -> More.t -> 'a
type 'a failure = (string list -> string -> 'a State.t) with_state
type ('a, 'r) success = ('a -> 'r State.t) with_state

type 'a t =
  { run : 'r. ('r failure -> ('a, 'r) success -> 'r State.t) with_state }
```

This is the same CPS technique attoparsec uses, but with **two** continuations, not Megaparsec's four ([contrast the Parsec deep-dive's `ParsecT`][parsec]). Angstrom has no consumed/empty distinction to encode, so it needs only "this parse failed" and "this parse succeeded" paths. `More.t` is a two-valued flag — `Complete` or `Incomplete` — that tells a parser at end-of-buffer whether more input may still arrive ([`lib/more.ml`][angstrom-repo]).

The monad and applicative operators are ordinary continuation plumbing. `>>=` threads the result of `p` into `f` by wrapping the success continuation ([`lib/parser.ml`, `Monad`][angstrom-repo]):

```ocaml
let (>>=) p f =
  { run = fun input pos more fail succ ->
    let succ' input' pos' more' v = (f v).run input' pos' more' fail succ in
    p.run input pos more fail succ'
  }
```

`>>|` (map), `<*>` (apply), `<$>`, `*>`/`<*` (sequence-and-discard), and `lift2`/`lift3`/`lift4` are all defined the same way. The `mli` notes the `liftn` family is deliberately more efficient than the applicative chain and should be preferred ([`lib/angstrom.mli`][angstrom-repo]):

> _"These functions are more efficient than using the applicative interface directly, mostly in terms of memory allocation but also in terms of speed. Prefer them over the applicative interface … Even with the partial application, it will be more efficient than the applicative implementation."_

Angstrom exposes **both** the monadic (`>>=`/`bind`) and applicative (`<*>`/`lift2`) styles, plus a `Let_syntax` module and `let+`/`let*`/`and+` binding operators for `ppx_let` and native OCaml let-syntax ([`lib/angstrom.mli`][angstrom-repo]).

### Backtracking, and how `commit` bounds it

The choice operator `<|>` is where "backtracking by default" lives. On failure of the left parser it resets to the _original_ starting position and runs the right — **unless** a `commit` has since advanced the committed watermark past that position ([`lib/parser.ml`, `Choice`][angstrom-repo]):

```ocaml
let (<|>) p q =
  { run = fun input pos more fail succ ->
    let fail' input' pos' more' marks msg =
      if pos < Input.parser_committed_bytes input' then
        fail input' pos' more marks msg
      else
        q.run input' pos more' fail succ in
    p.run input pos more fail' succ
  }
```

Note `q` is run from the saved `pos`, so the input is rewound with no bookkeeping — there is no `try` and no consumed/empty tag. The source comment explains the committed-bytes guard ([`lib/parser.ml`][angstrom-repo]):

> _"The only two constructors that introduce new failure continuations are `[<?>]` and `[<|>]`. If the initial input position is less than the length of the committed input, then calling the failure continuation will have the effect of unwinding all choices and collecting marks along the way."_

`commit` is the streaming-critical primitive. It sets the parser's committed watermark to the current position ([`lib/input.ml`][angstrom-repo]: `t.parser_committed_bytes <- pos`), which does two things: it **forbids any enclosing `<|>` from backtracking before that point**, and it **releases the preceding bytes so the input manager can reclaim them** ([`lib/angstrom.mli`][angstrom-repo]):

> _"`[commit]` prevents backtracking beyond the current position of the input, allowing the manager of the input buffer to reuse the preceding bytes for other purposes. The `{!module:Unbuffered}` parsing interface will report directly to the caller the number of bytes committed … allowing the caller to reuse those bytes for any purpose."_

`commit` is the mirror image of Parsec's `try`: Parsec is predictive-by-default and uses `try` to _widen_ lookahead; Angstrom is backtracking-by-default and uses `commit` to _narrow_ it — bounding memory in a stream where holding all uncommitted input is not an option.

### Buffered vs. unbuffered incremental input

Both incremental interfaces are driven by the same underlying `Partial` state, which carries how many bytes were committed and a `continue` continuation awaiting more input ([`lib/parser.ml`, `State`][angstrom-repo]):

```ocaml
type 'a state =
  | Partial of 'a partial
  | Lazy    of 'a t Lazy.t
  | Done    of int * 'a
  | Fail    of int * string list * string
and 'a partial =
  { committed : int
  ; continue  : Bigstringaf.t -> off:int -> len:int -> More.t -> 'a t }
```

- **`Buffered`** copies fed input into an internally managed, auto-growing `Bigstringaf` buffer; the caller just calls `feed` with a `` `String ``/`` `Bigstring ``/`` `Eof `` input and reads back `Partial`/`Done`/`Fail`. The buffer compresses and grows as needed and reuses the committed region ([`lib/buffering.ml`][angstrom-repo]). The `mli` calls this "much easier to use."
- **`Unbuffered`** performs **no** internal buffering: the caller owns a buffer holding all unconsumed input, drops `partial.committed` bytes after each step, and passes the remainder plus new input back via `partial.continue`, along with a `Complete`/`Incomplete` flag ([`lib/angstrom.mli`, `Unbuffered`][angstrom-repo]):

  > _"Use this module for total control over memory allocation and copying. Parsers run through this module perform no internal buffering. … The logic that must be implemented in order to make proper use of this module is intricate and tied to your OS environment."_

The two convenience runners — `parse_string` and `parse_bigstring` — sit on top of the unbuffered engine for the whole-input case, taking a `Consume.t` of `Prefix` (allow leftover input) or `All` (require end-of-input) ([`lib/angstrom.mli`][angstrom-repo]). `parse_string` copies the string into a fresh bigstring; `parse_bigstring` parses in place ([`lib/angstrom.ml`][angstrom-repo]).

### Zero-copy and the tight-loop scanners

Input is always a `Bigstringaf.t` window described by `off`/`len` and a committed offset; `Input.apply` hands a slice straight to a callback without copying, and `unsafe_get_char`/`unsafe_get_int32_be`/… index the buffer directly ([`lib/input.ml`][angstrom-repo]). The bulk scanners — `take_while`, `skip_while`, `take_till`, `scan` — are built on `count_while`, which walks the buffer in a plain `while` loop with no per-char combinator overhead ([`lib/input.ml`, `count_while`][angstrom-repo]):

```ocaml
let count_while t pos ~f =
  let buffer = t.buffer in
  let off    = offset_in_buffer t pos in
  let i      = ref off in
  let limit  = t.off + t.len in
  while !i < limit && f (Bigstringaf.unsafe_get buffer !i) do
    incr i
  done;
  !i - off
```

The default `take_while`/`take` still allocate a result `string` (via `Bigstringaf.substring`), but the `Unsafe` module skips even that: `Unsafe.take_while check f` hands the raw `buffer ~off ~len` to `f` with no allocation, for "performance-sensitive parsers that want to avoid allocation at all costs" ([`lib/angstrom.mli`, `Unsafe`][angstrom-repo]). This tight-loop, zero-copy scanning is exactly the capability the README says the lazy-stream ports cannot offer.

### Recursion and `fix`

Recursive grammars use `fix : ('a t -> 'a t) -> 'a t`, which ties the knot so a parser can reference itself — the `mli` illustrates it with `many` and a JSON value parser ([`lib/angstrom.mli`][angstrom-repo]). On native/bytecode backends `fix` is a direct mutable-reference knot; when compiling to JavaScript via `Js_of_ocaml` it falls back to `fix_lazy ~max_steps:20`, which periodically yields a `State.Lazy` node to break CPS tail-call chains that `Js_of_ocaml` cannot tail-optimise ([`lib/angstrom.ml`, `fix`][angstrom-repo]).

---

## Algorithm & grammar class

Angstrom is a **recursive-descent, top-down, ordered-choice** parser ([Top-down & combinator parsing][top-down]). Because `<|>` commits to the first alternative that succeeds and backtracks on failure with unbounded lookahead, the effective grammar class is a [Parsing Expression Grammar][peg] rather than a classical CFG:

- **Unbounded lookahead, always backtracking.** Unlike Parsec's LL(1)-with-`try` default, `<|>` will retry the alternative no matter how much input the failed branch scanned. The README lists _"Unbounded lookahead"_ ✅. There is **no memoization** (no packrat table), so a backtracking-heavy grammar can rescan the same span repeatedly.
- **No ambiguity / no parse forest.** Ordered choice returns the first success; ambiguous grammars resolve by source order. For all-parses enumeration use a [GLR/Earley general parser][general] instead.
- **No left recursion.** As with every recursive-descent scheme, a left-recursive production loops forever; it must be rewritten to right recursion or folded with a helper. The README's arithmetic example defines `chainl1` by hand for exactly this reason and notes Angstrom deliberately ships no infix/precedence combinators ([`README.md`][angstrom-repo]): _"it does not include combinators for creating infix expression parsers. Such combinators, e.g., `chainl1`, are nevertheless simple to define."_ (Contrast [Pratt / precedence climbing][pratt] and Megaparsec's `makeExprParser`.)
- **Context-sensitive by construction.** Sequencing is monadic (`>>=`), so a later parser can depend on an earlier runtime result — strictly more than pure applicative composition.
- **Scannerless.** The token is the byte/`char`; there is no separate lexer phase, the same stance as [PEG tools][peg] and the [Haskell combinator lineage][parsec].

## Interface & composition model

The interface is an **internal DSL**: a grammar is an OCaml value, composed with the operators above and a rich primitive set — `char`, `satisfy`, `string`/`string_ci`, `take`/`take_while`/`take_till`, `scan`, big/little-endian fixed-width integer and float readers (`BE`/`LE` modules), and derived combinators `many`, `many1`, `sep_by`, `count`, `option`, `choice`, `many_till` ([`lib/angstrom.mli`][angstrom-repo]). The README's arithmetic evaluator shows the composition style — the whole grammar is a value built with `*>`, `<*`, `<|>`, `>>=`, and `fix`:

```ocaml
let parens p = char '(' *> p <* char ')'
let integer =
  take_while1 (function '0' .. '9' -> true | _ -> false) >>| int_of_string

let expr : int t =
  fix (fun expr ->
    let factor = parens expr <|> integer in
    let term   = chainl1 factor (mul <|> div) in
    chainl1 term (add <|> sub))
```

- **AST construction is explicit and host-native** — as in the Haskell lineage, results are mapped into user types with `<$>`/`>>|`/`lift2`; no CST is produced for free (contrast [tree-sitter][tree-sitter]).
- **Repetition/choice are derived, not primitive** — `many`, `sep_by`, `many_till`, `skip_many` are all defined from `<|>`, `fix`, and `lift2` in the library itself ([`lib/angstrom.ml`][angstrom-repo]), and a user can write new ones the same way.
- **Two composition styles + let-syntax** — monadic, applicative, `Let_syntax`/`ppx_let`, and `let+`/`let*`/`and+` all coexist.

## Performance

Performance is the whole point of the design, and it comes from four levers, all visible in the source:

- **Zero-copy `Bigstringaf` input** with direct indexing and slice-callbacks (`Input.apply`, `unsafe_get_*`), plus an `Unsafe` module that avoids result allocation entirely ([above](#zero-copy-and-the-tight-loop-scanners)).
- **Tight-loop bulk scanners** (`count_while`) instead of per-character combinator dispatch — the capability the README says lazy-stream ports lack.
- **Allocation-frugal fast paths.** The `BE`/`LE` integer readers are hand-written to "not allocate in the fast (success) path," with a source comment weighing the trade-off ([`lib/angstrom.ml`, `BE`][angstrom-repo]): _"By inlining `[ensure]` you can recover about 2 nanoseconds on average. That may add up in certain applications."_ The `liftn` family exists specifically to cut allocation versus the applicative chain.
- **`commit`-bounded memory in streams** — committing lets the buffer manager reclaim consumed bytes, so a long-running protocol parser does not accumulate the whole stream.

The repository ships a `benchmarks/` directory (`pure_benchmark.ml`, `async_benchmark.ml`, `lwt_benchmark.ml`) exercising these paths, though the tree carries no published headline numbers to quote. Like the [attoparsec][parsec] lineage it descends from, Angstrom is a **scalar, sequential** engine — it does no SIMD or data-parallel scanning; for that design point see [simdjson][simdjson].

## Error handling & recovery

This is Angstrom's weakest dimension, by design — the attoparsec trade of diagnostics for throughput carries over:

- **Failures are a marks list plus a flat message.** A `Fail` carries `int * string list * string` — the committed byte count, a list of "marks" (context labels), and a message ([`lib/parser.ml`][angstrom-repo]). `<?>` pushes a name onto the marks list on the failure path, and `choice` takes an optional `failure_msg`. There is **no expected-set merging** across alternatives the way Parsec builds its "expecting …" reports.
- **No line/column numbers.** The README's own comparison table marks _"Reports line numbers in errors"_ ❌ for Angstrom (and ✅ for `mparser`). Positions are byte offsets; turning them into line/column is the caller's job.
- **No error recovery.** There is no `withRecovery`/error-bundle equivalent (contrast [Megaparsec][parsec]); a `Fail` is terminal for that parse. `commit` interacts with errors only by forbidding backtracking past the commit point.
- **Incremental _input_, not incremental _reparsing_.** The `Partial`/`continue` machinery streams bytes into a one-shot parse; it does not re-use a prior parse tree across edits the way [tree-sitter][tree-sitter] does. Angstrom is a streaming parser, not an IDE/edit-reparse engine.

## Ecosystem & maturity

Angstrom is a mature, widely-depended-upon library in the OCaml ecosystem and the de-facto choice when throughput and streaming matter:

- **License & provenance.** BSD-3-Clause (`angstrom.opam` `license: "BSD-3-clause"`; `LICENSE` "Copyright (c) 2016, Inhabited Type LLC"), maintained by Spiros Eliopoulos / Inhabited Type LLC; minimum OCaml 4.04.0, built on `bigstringaf` ([`angstrom.opam`][angstrom-repo]).
- **Concurrency integration.** First-class `Async` and `Lwt` support (both ✅ in the README table; `async_benchmark.ml`/`lwt_benchmark.ml` in-tree), the non-blocking story the lazy-stream ports cannot match.
- **Real-world adoption.** Angstrom is the parsing layer of Inhabited Type's HTTP stack — notably `httpaf` — and is used broadly for network-protocol and format parsing across the MirageOS/Jane-Street-adjacent OCaml ecosystem. The distribution's own worked examples are production-grade RFC parsers ([HTTP/1.1][http-example], [JSON][json-example]). _(The httpaf/broader-adoption claim is from ecosystem knowledge; only the in-tree RFC examples and `Async`/`Lwt` benchmark files were verified locally.)_
- **Sibling landscape.** Among OCaml combinator libraries the README positions Angstrom against `mparser`, `planck`, and `opal` — all Parsec-style, `try`-based, lazy-stream, no zero-copy/incremental/`Async`/`Lwt`. Across languages its closest cousins are [attoparsec][parsec] (its direct ancestor), Rust's [`nom`][nom]/[`winnow`][winnow]/[`combine`][combine], Haskell's [`flatparse`][flatparse], and F#'s [`fparsec`][fparsec] — with Angstrom distinctive for pairing the combinator model with zero-copy _and_ non-blocking incremental input.

---

## Strengths

- **Backtracking by default with unbounded lookahead** — no `try` ceremony; alternatives just work, with `commit` to bound cost where needed.
- **Zero-copy, tight-loop scanning** — `Bigstringaf` input, direct indexing, `count_while` bulk scanners, and an `Unsafe` allocation-free path.
- **Two incremental interfaces** — an easy `Buffered` one and a total-control, zero-copy `Unbuffered` one, both non-blocking.
- **Native `Async`/`Lwt` fit** — designed around monadic-concurrency IO, unlike the blocking lazy-stream ports.
- **Both monadic and applicative styles** — plus `lift`n fast paths, `Let_syntax`, and `let+`/`let*`/`and+`.
- **Battle-tested** — the parsing layer under real HTTP/protocol stacks, with production RFC parsers shipped as examples.

## Weaknesses

- **Poor diagnostics** — marks + flat message, **no line numbers**, no expected-set merging; unsuitable when humans must read parse errors (a deliberate attoparsec-style trade).
- **No error recovery** — a `Fail` ends the parse; no bundles, no `withRecovery`.
- **No memoization** — backtracking-heavy grammars can rescan input; no packrat linear-time guarantee.
- **No left recursion, no built-in precedence** — `chainl1`/infix parsers are hand-rolled; deliberately absent from the library.
- **`Unbuffered` is hard to use correctly** — the `mli` itself warns the required logic is "intricate and tied to your OS environment."
- **Not incremental _reparsing_** — streaming input only; not an edit-and-reparse IDE engine.
- **Manual AST construction** — no CST for free.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                  | Trade-off                                                                     |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------- |
| Backtracking by default (`<                                         | >` always rewinds)                                                         | No `try` ceremony; matches the attoparsec model and suits protocol grammars   | Unbounded rescanning possible; no memoization to bound it |
| `commit` to _narrow_ backtracking (dual of Parsec's `try`)          | Bounds memory in streams — lets the buffer manager reclaim consumed bytes  | Manual placement; forgetting it can hold unbounded uncommitted input          |
| CPS core with **two** continuations (not four)                      | No consumed/empty tag needed → simpler, faster core                        | Cannot reconstruct Parsec-quality expected-sets from the control flow         |
| `Bigstringaf` zero-copy input + `Unsafe` allocation-free primitives | Tight-loop scanning and no-copy IO for high throughput                     | `Unsafe` exposes the raw buffer — caller must not leak or mutate it           |
| Buffered **and** unbuffered incremental interfaces                  | One easy path, one total-control zero-copy path                            | Unbuffered logic is intricate and OS-coupled                                  |
| Drop rich errors (marks + message only, no line numbers)            | Avoids per-branch error book-keeping → speed                               | Weak diagnostics; caller derives line/column and readable messages            |
| Monadic sequencing (`>>=`), plus `liftn` fast paths                 | Context-sensitive grammars; `liftn` cuts allocation vs. applicative chains | Cannot statically analyse the grammar; precludes generator-style optimisation |
| No built-in infix/precedence combinators                            | Keeps the core focused on protocols/formats; `chainl1` is easy to define   | Expression grammars need hand-written helpers                                 |

---

## Sources

- [inhabitedtype/angstrom source tree][angstrom-repo] (SHA `76c5ef5`) — `README.md` (positioning, comparison table, acknowledgements), `angstrom.opam`/`LICENSE` (BSD-3-Clause), `lib/angstrom.mli` (the interface), `lib/angstrom.ml` (combinators, `commit`, scanners, `BE`/`LE`, `fix`), `lib/parser.ml` (CPS core, `Monad`, `Choice`), `lib/input.ml`/`lib/buffering.ml` (zero-copy buffer, `count_while`), `examples/` (RFC2616 HTTP, RFC7159 JSON), `benchmarks/`
- [`angstrom` on OPAM][angstrom-opam] — package metadata, synopsis "Parser combinators built for speed and memory-efficiency"
- Related deep-dives: [Parsec/attoparsec/Megaparsec (Haskell)][parsec] (direct ancestor — the closest cousin) · [`nom` (Rust)][nom] · [`winnow` (Rust)][winnow] · [`combine` (Rust)][combine] · [`flatparse` (Haskell)][flatparse] · [FParsec (F#)][fparsec] · [Top-down & combinator parsing][top-down] · [PEG & packrat][peg] · [General parsing (GLR/Earley)][general] · [Pratt / precedence][pratt] · [tree-sitter][tree-sitter] · [simdjson][simdjson] · [shared concepts][concepts] · [the comparison capstone][comparison] · [the parsing umbrella][umbrella]

<!-- References -->

[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[parsec]: ./haskell-parsec.md
[nom]: ./rust-nom.md
[winnow]: ./rust-winnow.md
[combine]: ./rust-combine.md
[flatparse]: ./haskell-flatparse.md
[fparsec]: ./fsharp-fparsec.md
[tree-sitter]: ./tree-sitter.md
[simdjson]: ./simdjson.md
[top-down]: ./theory/top-down.md
[peg]: ./theory/peg-packrat.md
[general]: ./theory/general-parsing.md
[pratt]: ./theory/pratt-precedence.md
[angstrom-repo]: https://github.com/inhabitedtype/angstrom
[angstrom-opam]: https://opam.ocaml.org/packages/angstrom/
[http-example]: https://github.com/inhabitedtype/angstrom/blob/master/examples/rFC2616.ml
[json-example]: https://github.com/inhabitedtype/angstrom/blob/master/examples/rFC7159.ml
