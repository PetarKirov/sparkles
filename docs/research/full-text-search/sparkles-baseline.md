# Sparkles — the baseline (system under improvement)

An audit of what this repository can do for full-text search **today**, read from
the tree rather than from intent — the system every subject in this catalog is
measured against, and the one the recommendations (Phase 7) feed back into.

| Field                | Value                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------ |
| Subject              | The `sparkles` monorepo (this repository)                                                  |
| Language             | D, built with LDC 1.41 (DMD 2.111) and DMD                                                 |
| Content search today | **None.** Two in-document literal scans, no cross-file search of any kind                  |
| Path search today    | `sparkles:fuzzy` + hue's picker (`<leader>ff`), specified in [`fuzzy/SPEC.md`][fuzzy-spec] |
| Pattern engine       | One bounded Thompson NFA, glob-shaped, anchored — `libs/fuzzy/.../glob.d`                  |
| Regex                | `std.regex` only, in tooling and `sparkles:syntax`; never on a hot or `@nogc` path         |
| SIMD                 | **No precedent.** No `core.simd`, no runtime feature detection                             |
| Index                | None                                                                                       |

> **Last reviewed:** August 27, 2026.

> [!NOTE]
> This is a _baseline_ page, not a third-party deep-dive. It records only what is
> observably true in the tree at the reviewed commit, names real modules and line
> numbers, and ends with an honest gap analysis. Where a capability is absent,
> the absence is the finding. For what the field does instead, see the
> comparison (Phase 7); for the staged plan this feeds, see the
> recommendations (Phase 7).

---

## Overview

The repository has a mature answer to _"which of these 500,000 **paths** did you
mean"_ — `sparkles:fuzzy`, an allocation-free bounded matcher with its own
[specification][fuzzy-spec], benchmark baseline and Diátaxis tree — and no answer
at all to _"which of these 2 GB of file **contents** match this pattern"_. The
gap is not a missing optimisation; it is a missing subsystem. Nothing in the tree
opens a second file looking for a byte pattern.

What does exist is worth cataloguing carefully, because three pieces of it are
closer to a content-search engine than they first appear: a bounded NFA, a
`@nogc` text toolkit, and a persistent closure-free CPU-job pool that hue's
picker already drives.

## What hue does for search today

### Cross-file: nothing

There is no content search, and nothing shells out to one. `<leader>ff` opens the
**files** picker over `sparkles:fuzzy`; `<leader>/`, `<leader>s` and `<leader>g`
are reserved but deliberately unbound, with a comment in `apps/hue/src/keymap.d`
recording that they await later picker sources. Greping hue's sources for `rg`,
`ripgrep` or a spawned `grep` returns nothing.

### In-document: two implementations that disagree

Both backends implement `FND` — search within the open document — and they do not
agree on semantics:

|              | GUI                                          | TUI                                       |
| ------------ | -------------------------------------------- | ----------------------------------------- |
| Entry point  | `findMatches` (`apps/hue/src/gui_text.d:98`) | `containsIC` (`apps/hue/src/tui.d:91`)    |
| Matcher      | `std.string.indexOf` in a loop               | naive `O(n·m)` byte loop                  |
| Case         | **sensitive**                                | **ASCII-insensitive** (`lowerAscii` fold) |
| Allocation   | GC — builds a `Match[]`                      | none — `@safe pure nothrow @nogc`         |
| Result model | materialised list + `curMatch` + `Rect[][]`  | no list; "a live query IS the match set"  |
| Unicode      | none beyond byte equality                    | ASCII only, by construction               |

The GUI's `Match` (`gui_text.d:74`) carries both grid coordinates and a **source
byte range**, which is the shape a grep hit also needs. The TUI's `containsIC` is
the only allocation-free substring primitive in the repository, and it is
`private`.

That divergence is itself a finding: the same feature, in one application, means
two different things depending on the backend. Any content-search design must fix
the case rule in one place rather than inherit this split.

## The bounded NFA that already ships

`libs/fuzzy/src/sparkles/fuzzy/glob.d` is a complete, tested, `@safe pure nothrow
@nogc` Thompson NFA — the closest thing in the tree to a regex engine, and the
substrate any bounded engine would most plausibly extend.

Its instruction set is eight opcodes (`glob.d:13-23`):

```d
enum GlobOp : ubyte
{
    literal, anySegment, starSegment, starAny,
    charClass, split, jump, accept,
}
```

Execution is the textbook two-bitset simulation: seed `current[0]`, take the
epsilon closure (`epsilonClosure`, `glob.d:531`), then step every live thread per
input unit. The [`fuzzy` specification][fuzzy-spec] states the bound it maintains
— `O(programInstructions * pathUnits)`, no recursion, no brace-product expansion —
and the workspace is fixed-capacity and caller-owned, like everything else in that
library.

**Five gaps stand between it and a content matcher**, and each has a cost:

1. **Anchored-only.** `globMatch` seeds position 0 once and tests `accept` at end
   of input: it answers "does the whole path match", not "where in this line".
   Unanchored search needs either a restart-per-position loop or a `.*?` prefix
   thread, plus a match-start slot.
2. **No match positions.** Nothing records where a match began or ended, which is
   exactly what highlighting a grep hit requires.
3. **The bitsets are cleared per input unit** — `foreach (i; 0 .. MaxInstructions)
workspace.next[i] = false;` at `glob.d:476-477`. The constant factor is
   therefore the program _capacity_, not the live thread count: a 512-instruction
   program stepping 100,000 analyzed units pays ~51 M byte-writes it does not
   need, whatever the live thread count. A
   sparse-set thread list removes that without changing semantics.
4. **Path-separator semantics are baked in** to `literal`, `anySegment` and
   `charClass` — `starSegment` versus `starAny` is the `**`-versus-`*`
   distinction. Line content has no segments.
5. **No alternation priority.** Brace alternation is a set, not an ordered
   preference, so there is no leftmost-first rule to report a _first_ match under.

None of the five is a redesign; together they are the honest scope of "extend the
existing NFA" versus "write a new engine", and that is the question
recommendations (Phase 7) must answer.

## The `@nogc` text toolkit

`sparkles:base` supplies more than a content matcher needs for analysis and less
than it needs for I/O.

**Present:**

- `sparkles.base.text.analysis.analyzeText` — the Unicode-aware normalising,
  case-folding tokenizer, with `AnalysisCase.{sensitive, simpleFold}` and the
  `codePath` / `generalLanguage` profiles the fuzzy engine drives.
- `sparkles.base.text.lineindex.LineIndex` — `lineStart`, `lineColAt`,
  `offsetAt`, byte columns, `\r\n` handled. **Its constructor is `@safe pure
nothrow` but not `@nogc`** — it appends a `size_t[]` — so it cannot be built
  inside a closure-free pool job.
- `sparkles.base.text.utf8.indexOfInvalidUtf8` — `@safe pure nothrow @nogc`,
  word-at-a-time, CTFE-able. The natural primitive for a bounded binary sniff.
- `SmallBuffer`, the `@nogc` readers/writers, and `tryToCString` for a fixed-buffer
  path.

**Absent:**

- Any **bounded or streaming file reader**. Every read in hue is
  `std.file.readText` (`apps/hue/src/document.d:496-528`), which slurps into GC
  memory and throws `UTFException` on invalid UTF-8 — that throw is the de-facto
  binary guard.
- Any **content-based binary detection**. The guards that exist are path- and
  size-based and live in the docs-site path (`isRenderable` +
  `binaryExtensions`, `libs/docs/.../source_set.d:118-172`).
- Any **public substring-search primitive**. `containsIC` is private to `tui.d`;
  there is no `memmem`, no Two-Way, no Boyer-Moore anywhere.

## Concurrency and I/O substrate

`sparkles:event-horizon` is a completion-first event loop (io_uring on Linux,
kqueue, IOCP) with a measured work-stealing pool, and — more relevant here — a
**persistent raw CPU-job pool**: fixed capacity, closure-free, jobs typed
`void function(void*) @safe nothrow @nogc` over a caller-owned address-stable
context, with explicit `queueFull` / `notStarted` / `shuttingDown` outcomes and
no implicit cancellation.

hue's picker already drives it (`apps/hue/src/picker.d`), including the
degradation path: when the pool refuses a job the same bounded step runs
synchronously on the calling thread. That pool, and its generation-counter
cancellation protocol, are directly reusable by a scanner — and its job signature
is the hardest constraint any matcher in this repository faces, because it admits
no allocation, no exception and no closure.

Whether a search backend should reach for `io_uring` for the _reads_ is open. The
loop exists and [`async-io/`][async-io] surveys the substrate, but nothing in the
tree currently issues file reads through it.

## SIMD: available, with zero precedent

LDC exposes `core.simd`, `ldc.simd`, the GCC-builtin modules and target
attributes. **The repository uses none of them.** A tree-wide grep for
`core.simd`, `ldc.simd`, `__vector` or `ldc.intrinsics` returns exactly one hit —
`llvm_trap` in the test runner's extractor — which is unrelated to data
parallelism.

There is also **no runtime CPU feature detection**. `sparkles.base.hw_caps`
answers _how many_ CPUs may be used (quota, affinity mask, memory, load, swap) and
says nothing about _what those CPUs can do_: no `cpuid`, no AVX/SSE probing, no
dispatch table. Every measured prefilter in this catalog — `memchr`'s packed-pair
heuristic, Teddy, ShiftOr over a word — would land on bare ground here, and the
first one to arrive pays for the dispatch machinery.

The benchmark build type already passes `-mcpu=native`, which is the opposite
trade: it produces non-portable binaries and therefore cannot be how a shipped
artifact selects an implementation.

## GPU: further away than the plan assumed

The repository has **in-house Vulkan bindings** (`sparkles:vulkan`,
`sparkles:vulkan-wsi`) rather than `erupted`; `erupted` appears in the tree only
as a citation inside `docs/research/vulkan/d-erupted.md`.

More importantly, **there is no compute path**. `sparkles:vulkan-wsi` selects a
queue family by `VK_QUEUE_GRAPHICS_BIT` (`libs/vulkan-wsi/.../context.d:303-304`)
and a grep for `COMPUTE` across both libraries returns nothing: no compute queue
selection, no compute pipeline, no descriptor plumbing for a storage buffer. A
GPU prefilter example is therefore not a small program over existing bindings —
it needs a compute path built first. That should be reflected in whatever
acceleration work this catalog proposes.

## Hosts available for measurement

CI runs on `ubuntu-latest` (x86_64-linux, under both `ldc2` and `dmd`) and
`macos-latest` (aarch64-darwin, `ldc2`), plus a `windows-latest` leg for the
Win32 demos. Two consequences for [measurement][measurement]:

- Both a **x86_64 and an aarch64** target are routinely exercised, so an
  ISA-specific claim can be checked on two architectures — but AVX-512 is
  available on neither runner class by default.
- GitHub-hosted runners are shared and noisy, and this repository has already been
  bitten by it (the macOS leg's timeout comment records a 5-minute job stalling
  for 78). **No timing claim in this catalog should be produced by CI.** Numbers
  come from a designated local runner, as `fuzzy/benchmarks.md` already does.

The test runner supplies the harness: `@benchmark` with auto-scaling statistics,
`--perf` hardware counters on Linux, `--bench-json` snapshots, and a `bench` build
type. That machinery is a solved problem here and should be reused rather than
re-invented.

## Gap analysis

| #   | Gap                                     | Consequence                                                                                                                     |
| --- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 1   | No content search at all                | `PKS2` starts from zero; there is no code to refactor, only to write                                                            |
| 2   | No bounded regex engine                 | `std.regex` allocates and throws, so it cannot enter a pool job; the substrate that could carry one is `glob.d`, five gaps away |
| 3   | No bounded file reader                  | The only read path slurps into GC memory and throws on invalid UTF-8                                                            |
| 4   | No content binary sniff                 | Path/extension guards exist; nothing inspects bytes                                                                             |
| 5   | No public substring primitive           | The one allocation-free implementation is `private` in `tui.d`, and the GUI uses a different, case-sensitive one                |
| 6   | No SIMD precedent, no feature detection | The first vectorised prefilter pays for the dispatch machinery                                                                  |
| 7   | No GPU compute path                     | An accelerator example needs a compute pipeline built first                                                                     |
| 8   | No index of any kind                    | Every query is a full scan of whatever the walk yields                                                                          |
| 9   | Case semantics are already forked       | Two in-document searches disagree; a third implementation would entrench it                                                     |

Gaps 1–5 are the content-search milestone. Gap 9 is a defect that milestone
should close rather than widen. Gaps 6–8 are where this catalog's evidence
decides whether the work is worth doing at all.

## Sources

Read from this repository at the reviewed commit. Paths are repository-relative
and the claims above are `[source-verified]` against them:

- `libs/fuzzy/src/sparkles/fuzzy/glob.d` — the bounded NFA
- `libs/base/src/sparkles/base/text/{analysis,lineindex,utf8}.d` — the text toolkit
- `libs/base/src/sparkles/base/hw_caps.d` — parallelism probing
- `libs/event-horizon/src/sparkles/event_horizon/raw_pool.d` — the CPU-job pool
- `libs/vulkan-wsi/src/sparkles/vulkan_wsi/context.d` — queue selection
- `apps/hue/src/{gui_text,tui,document,picker,keymap}.d` — hue's current search surface
- `docs/specs/fuzzy/SPEC.md`, `docs/specs/fuzzy/benchmarks.md` — the path-search contract
- `.github/workflows/ci.yml` — the runner matrix

<!-- References -->

[measurement]: ./measurement.md
[fuzzy-spec]: ../../specs/fuzzy/SPEC.md
[async-io]: ../async-io/index.md
