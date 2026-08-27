# ripgrep (Rust)

The reference architecture for unindexed content search, and the source of the
vocabulary this catalog uses: a `Matcher` finds patterns in bytes, a `Searcher`
feeds it bytes and owns every policy around them, and a `Sink` receives results.

| Field             | Value                                                          |
| ----------------- | -------------------------------------------------------------- |
| Language          | Rust                                                           |
| License           | MIT / Unlicense                                                |
| Repository        | [BurntSushi/ripgrep][repo]                                     |
| Surveyed revision | `3fce3b5bb0236da2df6d99672afb8a719642eca7`                     |
| Category          | Unindexed scanner (with an unfinished index crate — see below) |
| Engine class      | Rust `regex` meta-engine, plus optional PCRE2                  |
| Index             | None shipped; `crates/index/` is in-progress                   |
| Interactive       | Process-per-invocation; no budget, no cursor                   |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Recursive content search over a source tree, respecting `.gitignore`, at
throughput. ripgrep's contribution is less any single algorithm than the
**decomposition**: it separates "what is a pattern" from "how do bytes arrive"
from "what happens to a result", and each of the three has its own crate with its
own configuration surface.

The crate documentation states the split precisely:

> _"A `Searcher` is responsible for reading bytes from a source (e.g., a file),
> executing a search of those bytes using a `Matcher` (e.g., a regex) and then
> reporting the results of that search to a `Sink` (e.g., stdout). The `Searcher`
> itself is principally responsible for managing the consumption of bytes from a
> source and applying a `Matcher` over those bytes in an efficient way. The
> `Searcher` is also responsible for inverting a search, counting lines,
> reporting contextual lines, detecting binary data and even deciding whether or
> not to use memory maps."_ — [`grep-searcher/src/lib.rs`][searcher-lib]
> `[source-verified]`

That last sentence is the design's centre of gravity: **everything awkward is the
`Searcher`'s problem**, deliberately, so that a `Matcher` can stay a pure
predicate over bytes. It is why [fff's vendored fork][fff-grep] could delete so
much and still work — the deletions are all `Searcher` policy.

### Design philosophy

**Search lines, and exploit that.** Nearly every optimisation follows from the
line-oriented contract; the multi-line mode is a separate, slower strategy rather
than the general case.

**Make the fast path a literal search.** The regex engine is what runs _after_
something cheap has found a candidate line.

**Default to the safe thing, and make the fast thing opt-in and honest about
why.** Memory maps and binary detection are both off by default, and the API says
what you are trading.

## How it works

### The ten dimensions

#### 1. Pattern language

Rust `regex` syntax by default (leftmost-first, no backreferences, no lookaround),
with `-P/--pcre2` swapping in PCRE2 for patterns that need those. Smart case,
word boundaries, whole-line mode, fixed-string mode, and multi-line as an
explicit flag.

A line-oriented searcher cannot let a pattern match its own line terminator, and
ripgrep enforces that structurally rather than by convention: `strip.rs` rewrites
the parsed HIR so it is _"guaranteed to never match the given line terminator,
if possible"_, and **errors** when it is not. `[source-verified]`

#### 2. Engine architecture

The `Matcher` trait (`crates/matcher/src/lib.rs`) is the seam. Its required
surface is `find_at`, with `captures_at` for implementations that support groups
and defaulted methods for the rest — the same shape fff's fork reduced to a single
method. Two implementations ship: `grep-regex` over the `regex` crate's
meta-engine, and `grep-pcre2`.

The engine itself is surveyed in `rust-regex` (Phase 2); what matters here is
that ripgrep treats it as replaceable.

#### 3. Prefilter and literal extraction

This is ripgrep's most-copied idea, and `crates/regex/src/literal.rs` states both
the technique and its own diminishing returns:

> _"The main idea underlying the validity of this technique is the fact that
> ripgrep searches individual lines and not across lines. […] Namely, we can
> pluck literals out of the regex, search for them, find the bounds of the line
> in which that literal occurs and then run the original regex on only that line.
> This overall works really really well in throughput oriented searches because
> it potentially allows ripgrep to spend a lot more time in a fast vectorized
> routine for finding literals as opposed to the (much) slower regex engine."_
> `[source-verified]`

And, unusually honestly:

> _"This optimization was far more important in the old days, but since then,
> Rust's regex engine has actually grown its own (albeit limited) support for
> inner literal optimizations. So this technique doesn't apply as much as it used
> to."_

Two things follow for this catalog. First, **the prefilter is the architecture**,
not a tweak: search for a literal, recover the line, re-run the real pattern on
that line alone. Second, the boundary between "the tool's prefilter" and "the
engine's prefilter" moved over time — evidence for question 5 that the layer
where acceleration lives is a choice, not a fact.

Supporting machinery: `ast.rs` and `non_matching.rs` (deriving what a pattern
cannot match), `ban.rs`, and `strip.rs`.

#### 4. Corpus access

Two decisions worth copying, both defaulting to the conservative option.

**Memory maps are off by default**, and the enabling constructor is `unsafe` with
one of the more candid safety comments in the ecosystem:

> _"The specific contract the caller is required to uphold isn't precise, but it
> basically amounts to something like, 'the caller guarantees that the underlying
> file won't be mutated.' This, of course, isn't feasible in many environments.
> However, command line tools may still decide to take the risk of, say, a
> `SIGBUS` occurring while attempting to read a memory map."_
> — [`searcher/mmap.rs`][mmap-rs] `[source-verified]`

`MmapChoice` is `Never` by default and `auto()` is `unsafe fn`. A search backend
inside a long-lived editor process — which is what hue would be — has _less_
licence to take that risk than a command-line tool, not more.

**Otherwise, a roll buffer.** `line_buffer.rs` maintains a growable buffer with an
allocation limit, so a line spanning two reads is still a single slice by the
time a `Matcher` sees it. This is the piece a fixed-capacity `@nogc`
implementation cannot copy directly, and the reason fff's fork supports only
`search_slice`.

**Binary detection is a three-state policy, defaulting to off:**

```rust
pub(crate) enum BinaryDetection {
    None,
    Quit(u8),
    Convert(u8),
}
```

with the rationale stated: detection is _"the process of heuristically
identifying whether a given chunk of data is binary"_, and _"there are many cases
in which this isn't true, which is why binary detection is disabled by
default."_ `Quit` makes the buffer behave as if it hit EOF; `Convert` replaces
the byte with the line terminator. In both cases the buffer _"guarantees that
this byte will never be observable by callers"_. `[source-verified]`

Contrast with [fff][fff-grep], which decides binary status once at index time and
caches it: ripgrep decides mid-stream, correctly, and pays per file.

#### 5. Concurrency

The `ignore` crate owns the walk: a _"fast recursive directory iterator that
respects various filters such as globs, file types and `.gitignore` files"_, with
a parallel variant. Work distribution is per-file; ordering guarantees are given
up in the parallel walk, which is why the printer buffers per file.

#### 6. Index

**None shipped** — but `crates/index/` exists in the tree at the surveyed
revision, and it is worth recording precisely because it is unfinished: 1,223
lines, `#![allow(warnings)]`, an `Index`/`IndexBuilder`/`IndexDiscovery` surface
over [`redb`][redb], a 1,000-line `literal.rs`, and a most-recent commit whose
message is _"index: remove incorrect README"_. There is no trigram or n-gram
vocabulary in it. `[source-verified]`

It is not evidence of anything about indexing performance. It _is_ evidence for
thesis T2: the author of the fastest unindexed scanner is building an index, and
has not yet described it.

#### 7. Ranking and result model

None — results are in walk order. The `Sink` receives `SinkMatch` values carrying
the matched bytes, absolute byte offset and line number; `grep-printer` turns
those into grep-style, JSON or pretty output. No classification, no scoring.

`--max-columns` with `--max-columns-preview` is ripgrep's answer to long lines:
truncate for display and say so, rather than dropping the match.

#### 8. Unicode

On by default and taken seriously: `\w`, `\b` and `\p{…}` are Unicode-aware,
case-insensitivity is Unicode-aware, and `-a`/`--no-unicode` exists precisely
because that costs something. This is the opposite default from
[fff][fff-grep]'s `.unicode(false)`, and the divergence is a real decision each
tool made about its corpus.

#### 9. Interactive behaviour

**There is none, by design.** ripgrep is a process: no time budget, no abort
signal, no pagination cursor, no partial-result contract. Interactive integrations
get those properties by _killing the process_ and starting another — the pattern
surveyed in `live-grep-hosts` (Phase 6).

That absence is the sharpest argument for hue writing an engine rather than
shelling out: every property `PIK5` requires is one ripgrep deliberately does not
have.

#### 10. Measured evidence

ripgrep's published benchmarks are the field's most-cited, and this catalog does
not reproduce them here — under the [measurement protocol][measurement] no
cross-tool timing is quoted unless one harness produced every row. What the
source _does_ support without measurement is structural: the number of layers a
byte passes through before reaching the regex engine, and how many of them can
reject it.

## Strengths

- **The three-way decomposition is the durable contribution**, and it survives
  being cut down: fff's fork keeps `Matcher`/`Searcher`/`Sink` and deletes only
  policy.
- **Line-orientation is exploited rather than assumed** — the literal-recovery
  trick, and the HIR rewrite that makes a pattern structurally unable to match a
  line terminator.
- **Dangerous fast paths are opt-in, `unsafe`, and documented as trades.**
- **The code is honest about its own obsolescence**, recording that inner-literal
  extraction matters less now that the engine does it.

## Weaknesses

- **Nothing for an interactive host**: no budget, cursor, cancellation or partial
  results. Every editor integration re-implements them by process management.
- **The roll buffer assumes a growable allocation** with a limit, which a
  fixed-capacity allocation-free implementation cannot adopt as-is.
- **Binary detection off by default** is right for a CLI and wrong for a viewer
  that must never paint control bytes.
- **The index crate is undocumented and unfinished**, so the most interesting
  current question — what BurntSushi thinks an index should look like — is not
  yet answerable from source.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                              | Trade-off                                                                    |
| ------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `Matcher` / `Searcher` / `Sink` split             | A matcher stays a pure predicate; all policy is one layer up           | The `Searcher` accretes everything — binary, mmap, context, counting, invert |
| Extract literals, recover the line, re-run        | Spend time in vectorized literal search, not the automaton             | A large heuristic surface; the engine has since duplicated part of it        |
| Rewrite the HIR so it cannot match `\n`           | Line-orientation becomes structural, not a convention                  | Some patterns are rejected outright rather than degraded                     |
| `MmapChoice::Never` by default, `auto()` `unsafe` | Correctness first; the risk is named (`SIGBUS` on concurrent mutation) | The faster path needs an explicit, unsafe opt-in                             |
| `BinaryDetection::None` by default                | Binary detection is a heuristic and is often wrong                     | A CLI default that a UI must override                                        |
| Unicode on by default                             | `\w`/`\b` mean what a user expects                                     | Larger automata; `--no-unicode` exists because it costs                      |
| No interactive contract at all                    | A process is the unit; the shell composes                              | Every editor integration rebuilds budget and cancellation from process kills |

## Sources

Read at `3fce3b5bb0236da2df6d99672afb8a719642eca7` `[source-verified]`:

- [`crates/searcher/src/lib.rs`][searcher-lib] — the architecture statement
- [`crates/searcher/src/line_buffer.rs`][line-buffer] — the roll buffer and `BinaryDetection`
- [`crates/searcher/src/searcher/mmap.rs`][mmap-rs] — `MmapChoice` and its safety contract
- [`crates/matcher/src/lib.rs`][matcher-lib] — the `Matcher` trait
- [`crates/regex/src/literal.rs`][literal-rs] — inner-literal extraction and its own caveat
- [`crates/regex/src/strip.rs`][strip-rs] — making a pattern unable to match the line terminator
- [`crates/ignore/src/lib.rs`][ignore-lib] — the walk
- [`crates/index/src/`][index-rs] — the unfinished index crate

<!-- References -->

[repo]: https://github.com/BurntSushi/ripgrep
[searcher-lib]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/searcher/src/lib.rs
[line-buffer]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/searcher/src/line_buffer.rs
[mmap-rs]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/searcher/src/searcher/mmap.rs
[matcher-lib]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/matcher/src/lib.rs
[literal-rs]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/regex/src/literal.rs
[strip-rs]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/regex/src/strip.rs
[ignore-lib]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/lib.rs
[index-rs]: https://github.com/BurntSushi/ripgrep/tree/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/index/src
[redb]: https://github.com/cberner/redb
[fff-grep]: ./fff-grep.md
[measurement]: ./measurement.md
