# PCRE2 (C)

The reference backtracking engine, and therefore the reference _counter-example_:
it can express everything, and pays for it with a worst case bounded only by
user-supplied limits.

| Field             | Value                                                            |
| ----------------- | ---------------------------------------------------------------- |
| Language          | C                                                                |
| License           | BSD-3-Clause                                                     |
| Repository        | [PCRE2Project/pcre2][repo]                                       |
| Surveyed revision | `a2b146a3245a930aa4c8ea8b33c0d83092daa7c9` (`pcre2-10.47-90`)    |
| Category          | Regex engine (library)                                           |
| Engine class      | Backtracking interpreter, plus an SLJIT-based JIT                |
| Guarantee         | **None** — bounded by `match_limit`, `depth_limit`, `heap_limit` |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Full Perl-compatible matching: backreferences, lookaround in all four
directions, recursion, conditionals, atomic groups, possessive quantifiers. Every
tool in this catalog that offers `-P` is offering PCRE2, because these constructs
are what a regular language cannot express.

### Design philosophy

Expressiveness first, with **budgets instead of guarantees**. Where RE2 removes
constructs to make the worst case provable, PCRE2 keeps them and gives the caller
three dials to stop a runaway:

```c
pcre2_set_match_limit(pcre2_match_context *, uint32_t);
pcre2_set_depth_limit(pcre2_match_context *, uint32_t);
pcre2_set_heap_limit(pcre2_match_context *, uint32_t);
```

`[source-verified]`

That triple is the honest interface to catastrophic backtracking: the engine
cannot promise termination in reasonable time, so it promises to _stop_.

## How it works

An interpreter over compiled bytecode, plus a **JIT** (`pcre2_jit_compile.c`)
built on SLJIT that emits native code per pattern. The JIT is the reason PCRE2 is
competitive with automata engines on ordinary patterns and does nothing for the
pathological ones — compiling a backtracking search faster does not change its
complexity class.

`git grep -P` probes `pcre2_jit_functional()` at runtime rather than trusting the
build, and routes PCRE2's allocation through its own hooks — a detail worth
copying by anyone embedding it.

### The ten dimensions, briefly

**Pattern language**: the richest surveyed. **Engine**: backtracking, optionally
JIT-compiled. **Prefilter**: a start-of-match optimiser and first-byte tables;
no literal-set extraction of the RE2 kind. **Corpus access**: none.
**Concurrency**: thread-safe with per-thread match contexts.
**Index**: none. **Result model**: full captures, named groups.
**Unicode**: full, with UTF and UCP modes as explicit options.
**Interactive**: no budget in wall-clock terms — the limits are step counts,
not deadlines. **Measured evidence**: none quoted.

## Why it is disqualified here

For Sparkles the exclusion is structural, not aesthetic:

1. **The worst case is unbounded in time**, and the mitigation is a step counter
   the caller must tune per pattern.
2. **`depth_limit` exists because the interpreter recurses**, so stack depth is
   input-dependent — the property a `@safe nothrow @nogc` job body cannot have.
3. **`heap_limit` exists because matching allocates**, which is the same problem
   stated in kilobytes.

It stays in the catalog because _`-P` is a real user need_: a search UI that
refuses lookbehind entirely is worse than one that offers it with a step budget
and a visible failure. Recording that trade is the point.

## Strengths

- **Expressive completeness** — the constructs nothing else offers.
- **Three orthogonal limits**, so a host can bound steps, depth and memory
  independently.
- **A mature JIT** with wide architecture coverage.
- **Widely embedded**, so its failure modes are well documented.

## Weaknesses

- **No complexity guarantee**; catastrophic backtracking is reachable from
  ordinary-looking patterns.
- **Recursion means input-dependent stack depth.**
- **Matching allocates**, hence `heap_limit`.
- **Limits are step counts, not deadlines**, so mapping them onto a frame budget
  is guesswork.

## Key design decisions and trade-offs

| Decision                        | Rationale                                      | Trade-off                                               |
| ------------------------------- | ---------------------------------------------- | ------------------------------------------------------- |
| Backtracking interpreter        | Supports backreferences and lookaround         | No time bound; pathological patterns exist              |
| Three caller-set limits         | The host decides how much runaway to tolerate  | Tuning is per-pattern and per-corpus, i.e. unknowable   |
| SLJIT JIT compilation           | Large constant-factor win on ordinary patterns | Another codegen backend; unchanged complexity class     |
| Full Unicode via explicit modes | Correctness where asked for                    | Behaviour differs sharply between UTF and non-UTF modes |

## Sources

Read at `a2b146a3245a930aa4c8ea8b33c0d83092daa7c9` `[source-verified]`:

- [`src/pcre2.h.in`][pcre2-h] — `pcre2_set_{match,depth,heap}_limit`
- `src/pcre2_jit_compile.c` — the SLJIT JIT

<!-- References -->

[repo]: https://github.com/PCRE2Project/pcre2
[pcre2-h]: https://github.com/PCRE2Project/pcre2/blob/a2b146a3245a930aa4c8ea8b33c0d83092daa7c9/src/pcre2.h.in
