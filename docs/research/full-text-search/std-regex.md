# Phobos `std.regex` (D)

D's own regex engine: a 30-opcode bytecode IR, two engines, a ShiftOr prefilter
and CTFE code generation. The closest prior art Sparkles has to the thing it is
deciding whether to build — and the page that turns "`std.regex` allocates" from
an assumption into a measurement.

| Field             | Value                                                             |
| ----------------- | ----------------------------------------------------------------- |
| Language          | D                                                                 |
| License           | Boost 1.0                                                         |
| Repository        | [dlang/phobos][repo] — `std/regex/`                               |
| Surveyed revision | `6be6c38096b43b97dc24fa94b29877c23ae5462a`                        |
| Size              | 8,947 lines (`package.d` + `internal/`)                           |
| Category          | Regex engine (standard library)                                   |
| Engine class      | Thompson NFA (Pike VM) **and** backtracking, selected per pattern |
| Prefilter         | ShiftOr "kickstart", bit-parallel                                 |

> **Last reviewed:** August 28, 2026.

> [!IMPORTANT]
> The headline finding contradicts the assumption this catalog started with.
> `std.regex`'s **matching** path does not allocate from the GC: a matcher is one
> `enforceMalloc` block, arena-carved, refcounted, freed with `pureFree`, with
> threads served from a preallocated freelist. What is not `@nogc` is
> **compilation** and the **input model**. That moves the answer to research
> question 2a substantially toward _re-hosting_ rather than _rewrite_.

---

## Overview

### What it solves

The standard library's general-purpose regex, with both a runtime (`regex`) and a
compile-time (`ctRegex`) path, full Unicode, backreferences and lookaround.

### Design philosophy

A **bytecode IR** as the common representation, with more than one engine able to
execute it, and a cheap bit-parallel prefilter in front of both. Structurally, it
is the same shape as [`regex-automata`][rust-regex] with two engines instead of
five — and it predates it.

## How it works

### The instruction set — the artifact that matters most

`internal/ir.d` defines thirty opcodes. `sparkles:fuzzy`'s glob engine has eight,
and they are visibly a subset:

| Group       | Opcodes                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| Atoms       | `Char`, `Any`, `CodepointSet`, `Trie`, `OrChar`, `Nop`, `End`                                                |
| Anchors     | `Bol`, `Eol`, `Bof`, `Eof`, `Wordboundary`, `Notwordboundary`                                                |
| Groups      | `GroupStart`, `GroupEnd`, `Backref`                                                                          |
| Alternation | `OrStart`, `OrEnd`, `Option`, `GotoEndOr`                                                                    |
| Repetition  | `InfiniteStart/End`, `InfiniteQStart/QEnd`, `InfiniteBloomStart/End`, `RepeatStart/End`, `RepeatQStart/QEnd` |
| Lookaround  | `Lookahead`, `Neglookahead`, `Lookbehind`, `Neglookbehind` (each Start/End)                                  |

`[source-verified]`

Three observations for the subset question:

- **Greedy and lazy are distinct opcodes** (`InfiniteStart` vs `InfiniteQStart`),
  not a flag — so alternation priority is encoded in the program, which is
  exactly what `glob.d` lacks.
- **`OrChar` exists for case-insensitive runs**, holding a count in its upper
  bits: a compiled representation of "any of these consecutive characters".
- **`InfiniteBloomStart`** — a bloom-filtered repetition — is an optimisation no
  other engine surveyed here has an opcode for.

A grep needs the atoms, the anchors, alternation and repetition. It does **not**
need `Backref`, the four lookaround pairs, or `GroupStart`/`GroupEnd` — which is
thirteen of the thirty, and precisely the set
[`regex-automata`][rust-regex] refuses in order to keep its time bound.

### Two engines

`internal/thompson.d` (1,219 lines) is the Pike VM, and its header states the
property exactly:

> _"Implementation of Thompson NFA std.regex engine. Key point is evaluation of
> all possible threads (state) at each step in a breadth-first manner, thereby
> geting some nice properties: - looking at each character only once - merging of
> equivalent threads, that gives matching process linear time complexity"_
> `[source-verified]`

`internal/backtracking.d` (1,514 lines) is the other, and **`ctRegex` pins it**:
`package.d` builds a `CtfeFactory!(BacktrackingMatcher, Char, func)` over a
CTFE-generated matching function. So D already has the engine ladder this catalog
went to Rust to describe — just two rungs, chosen by `defaultFactory`.

### Memory — the finding

`GenericFactory.create` is the whole story:

```d
immutable size = EngineType!Char.initialMemory(re) + classSize;
auto memory = enforceMalloc(size)[0 .. size];
scope(failure) pureFree(memory.ptr);
GC.addRange(memory.ptr, classSize);
auto engine = construct(re, input, memory);
```

`[source-verified]` — one `malloc`, sized from the compiled pattern; the GC is
told about the **class header only**; `pureFree` on release; refcounted via
`incRef`/`decRef`. That is the same device `sparkles.base.unique` uses, arrived
at independently.

`initExternalMemory` then carves that block: `prepareFreeList(re.threadCount,
memory)` links the Pike VM's threads into a freelist, and `arrayInChunk` slices
out the merge table and the four op caches. Thread allocation at match time is a
freelist pop with an assertion, not an allocation:

```d
//get a dirty recycled Thread
Thread!DataIndex* allocate()
{
    assert(freelist, "not enough preallocated memory");
    …
}
```

`[source-verified]`

So the per-match steady state is **arena-based over caller-owned memory with a
bounded thread count** — architecturally the same contract `sparkles:fuzzy`
already holds everywhere.

### What actually blocks `@nogc nothrow` (question 2a)

Reading rather than assuming, the blockers are:

1. **Compilation.** `internal/parser.d` builds the IR with `appender`, GC arrays,
   `CodepointSet`s and `Trie`s. This is a genuine rewrite, not a re-hosting — but
   it is also the part a bounded engine most wants to replace anyway, since
   Sparkles needs compile-to-fixed-capacity with an error value on overflow.
2. **A process-global, unsynchronised cache.** `getMatcher(CodepointSet)` memoises
   character-class matchers in a module-level `CharMatcher[CodepointSet]
matcherCache`, flushed wholesale at `maxCachedMatchers = 8`. A GC-allocated AA
   on a shared mutable path is unusable from a pool job.
3. **`enforceMalloc` throws** on OOM, so `create` is not `nothrow`.
4. **The input is a range, not a slice.** `ThompsonMatcher` is generic over a
   `Stream` with a `BackLooper` for lookbehind. A `@nogc` grep wants
   `const(char)[]`, which removes the abstraction but changes every signature.
5. **`dip1000` refuses it.** Independently of allocation, `std.regex` does not
   accept `scope` parameters — the clash the repository's guidelines already
   record.

**None of those is the matching loop.** The Pike VM itself, given a compiled
program and an arena, is close to portable. That is the answer question 2a was
asking for, and it is the opposite of what "std.regex allocates and throws" would
have led us to conclude.

### `kickstart.d` — a bit-parallel prefilter, in D, already

> _"Kickstart is a coarse-grained 'filter' engine that finds likely matches to be
> verified by full-blown matcher."_ … _"Kickstart engine using ShiftOr algorithm,
> a bit parallel technique for inexact string searching."_ `[source-verified]`

`ShiftOr(Char)` builds a `uint[] table` with a `charsetThreshold = 32_000`
bail-out for classes too large to be worth encoding. This is the same shift-or
family the fuzzy-matching research already flagged as transferable, sitting in the
standard library, and it applies to a plain-text mode regardless of how the regex
question resolves.

### `generator.d` — `ctRegex`

187 lines that emit D source for a specific pattern at compile time, executed by
the backtracking engine. No counterpart exists in any other engine surveyed here.
It is useless for a user-typed grep pattern and exactly right for a fixed one —
worth recording as the boundary rather than as a candidate.

### The ten dimensions, briefly

**Pattern language**: Perl-ish, leftmost-first, with backreferences and all four
lookaround forms. **Engine**: Pike VM or backtracking, per pattern.
**Prefilter**: ShiftOr kickstart. **Corpus access**: none — a library over
ranges. **Concurrency**: none; the matcher cache is shared and unsynchronised.
**Index**: none. **Result model**: `Captures` with named groups. **Unicode**:
full, via `std.uni` `CodepointSet`/`Trie`. **Interactive**: none.
**Measured evidence**: none quoted; `std.regex`'s compile-time cost is
independently recorded in this repository's test-runner design notes as a reason
to avoid it in build-sensitive code.

## Strengths

- **A designed 30-opcode IR** that a grep's needs can be expressed as a subset of.
- **Greedy/lazy as distinct opcodes** — alternation priority is in the program.
- **Matching already runs on caller-supplied external memory**, malloc-backed,
  refcounted, with a preallocated thread freelist.
- **A bit-parallel prefilter in the standard library**, with a sensible bail-out.
- **CTFE code generation**, unique among the engines surveyed.

## Weaknesses

- **The compiler is thoroughly GC-bound** and is the real rewrite.
- **A process-global unsynchronised `matcherCache`**, flushed by clearing.
- **Threads are an intrusive linked list of pointers** — the freelist bounds the
  allocation but not the pointer-chasing; a sparse set would be both bounded and
  cache-friendlier.
- **Range-based input** rather than a slice.
- **Rejects `scope`**, so it cannot sit on a `dip1000` hot path at all.
- **Backreferences and lookaround are supported**, which means no linear-time
  guarantee in general — the opposite trade from [`regex-automata`][rust-regex].

## Key design decisions and trade-offs

| Decision                                      | Rationale                                       | Trade-off                                                        |
| --------------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------------- |
| A bytecode IR shared by two engines           | One compiler, several execution strategies      | The IR must express everything the richest engine needs          |
| Greedy and lazy as separate opcodes           | Priority is data, not interpretation            | Twice the repetition opcodes                                     |
| One `malloc` per matcher, arena-carved        | No GC pressure per match; bounded thread count  | Manual lifetime, refcounting, `GC.addRange` for the class header |
| Intrusive linked-list threads from a freelist | Simple, and allocation-free after setup         | Pointer chasing; a sparse set would be denser                    |
| Global `matcherCache`, cleared at 8           | Character-class matchers are expensive to build | Shared mutable state; unusable from a worker thread              |
| Support backreferences and lookaround         | General-purpose standard library                | No linear-time guarantee; a backtracking engine must exist       |
| `ctRegex` via CTFE codegen                    | A fixed pattern can become straight-line code   | Only for compile-time-known patterns; heavy build cost           |

## What this means for Sparkles

The subset question has a concrete frame now: **which of these thirty opcodes**,
and the answer for a code-search grep is the atoms, the anchors, alternation and
repetition — dropping the thirteen concerned with captures, backreferences and
lookaround, which is exactly the refusal that buys a linear-time bound.

The re-hosting question has a concrete answer too: the matching loop and its
memory model are already close: compile to a fixed-capacity program with an error
value on overflow, take a `const(char)[]` instead of a range, replace the freelist
with a sparse set, and drop the global class cache. The engine that results is
recognisably `thompson.d`, not a reinvention.

## Sources

Read at `6be6c38096b43b97dc24fa94b29877c23ae5462a` `[source-verified]`:

- [`std/regex/internal/ir.d`][ir] — the 30-opcode IR, `GenericFactory`, `matcherCache`
- [`std/regex/internal/thompson.d`][thompson] — the Pike VM, `initExternalMemory`, `prepareFreeList`, `allocate`
- [`std/regex/internal/backtracking.d`][backtracking] — the second engine
- [`std/regex/internal/kickstart.d`][kickstart] — the ShiftOr prefilter
- [`std/regex/internal/generator.d`][generator] — `ctRegex` codegen
- [`std/regex/package.d`][package-d] — `ctRegex` factory wiring
- `std/regex/internal/parser.d` — the compiler (read for allocation behaviour)

<!-- References -->

[repo]: https://github.com/dlang/phobos
[ir]: https://github.com/dlang/phobos/blob/6be6c38096b43b97dc24fa94b29877c23ae5462a/std/regex/internal/ir.d
[thompson]: https://github.com/dlang/phobos/blob/6be6c38096b43b97dc24fa94b29877c23ae5462a/std/regex/internal/thompson.d
[backtracking]: https://github.com/dlang/phobos/blob/6be6c38096b43b97dc24fa94b29877c23ae5462a/std/regex/internal/backtracking.d
[kickstart]: https://github.com/dlang/phobos/blob/6be6c38096b43b97dc24fa94b29877c23ae5462a/std/regex/internal/kickstart.d
[generator]: https://github.com/dlang/phobos/blob/6be6c38096b43b97dc24fa94b29877c23ae5462a/std/regex/internal/generator.d
[package-d]: https://github.com/dlang/phobos/blob/6be6c38096b43b97dc24fa94b29877c23ae5462a/std/regex/package.d
[rust-regex]: ./rust-regex.md
