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
| SIMD                 | No precedent in-tree; `intel-intrinsics` + `core.cpuid` exist, the dispatch join does not  |
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

That divergence is itself a finding, and a defect: the same feature, in one
application, means two different things depending on which canvas is painting.
A user who searches `Foo` gets different results in `hue --tui` and `hue --gui`,
and nothing in either implementation records that this was a choice.

**Replacing it is an outcome of this survey, not a by-product**, under two
requirements that follow from where the split came from:

- **Backend-independent.** The matcher belongs above the `sparkles:ui-app` seam,
  in one place both hosts call — the same rule the toolkit already holds
  elsewhere, where one `view` serves the terminal and the window. A search
  implementation per canvas is how the divergence happened.
- **Built on `sparkles:fuzzy`.** One engine, one case rule, one set of match
  positions, serving both the cross-file grep source and the in-document search.
  A third hand-rolled matcher would entrench the split rather than close it.

This is what makes the in-document search a _consumer_ of this survey alongside
the picker's grep source, and it constrains the engine design: whatever is chosen
must answer an incremental query over a single in-memory buffer as cheaply as it
answers a bounded scan over a corpus, and must return positions in both cases.

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

## SIMD: no precedent here, but not greenfield either

**The repository uses no SIMD at all.** A tree-wide grep for `core.simd`,
`ldc.simd`, `__vector` or `ldc.intrinsics` returns exactly one hit — `llvm_trap`
in the test runner's extractor — which is unrelated to data parallelism.

That is a statement about this tree, not about D. Two pieces already exist
outside it, and they solve different halves of the problem.

**Portability is solved** by
[`intel-intrinsics`][intel-intrinsics]
(v1.14.9, ~30 kLOC), the D analogue of `simd-everywhere`: one source using the
Intel `_mm_` API, compiling under **DMD, LDC and GDC**, and — the property that
matters most here — **targeting AArch64 at full speed without code change**.
This repository's CI exercises both `x86_64-linux` and `aarch64-darwin`, so a
hand-written x86 intrinsic would have to be written twice; through this library
it is written once. Coverage runs MMX through SSE4.2, plus BMI2, AVX, F16C and
AVX2 — **no AVX-512**, which costs nothing here given neither runner class offers
it. Its stated guarantee is that _semantics_ are preserved above all, with no
promise that any particular instruction is emitted.

**Detection is solved too, and closer to hand than expected.** Druntime's
`core.cpuid` reports `sse41`, `sse42`, `avx` and `avx2`, and its accessors
compile clean under `@safe nothrow @nogc` — verified on this host
`[host-verified: x86_64-linux]`, where it reports `AuthenticAMD` with all four
true. Nothing in the repository reads it: `sparkles.base.hw_caps` answers _how
many_ CPUs may be used (quota, affinity mask, memory, load, swap) and says
nothing about _what those CPUs can do_. That is the natural home for a capability
surface, and it does not have one.

**What is genuinely missing is the join between them.** `intel-intrinsics`
selects its ISA at **compile time** — above SSE2 every level needs `-mattr=+…`
under LDC — so shipping one binary that uses AVX2 where available and SSE4.2
where not means compiling the same routine more than once and dispatching between
the copies at runtime. Neither the multi-versioning nor the dispatch exists here,
and the first vectorised prefilter to arrive pays to build both.

The `bench` build type already passes `-mcpu=native`, which is the opposite
trade: it produces a binary tuned to the machine that built it, so it can measure
an upper bound but can never be how a shipped artifact selects an implementation.

## GPU: a compute path has to be built first

The repository's Vulkan bindings are **in-house** — `sparkles:vulkan` and
`sparkles:vulkan-wsi` — and that is the surface any GPU work here extends.

They are, today, a rendering stack. **There is no compute path**:
`sparkles:vulkan-wsi` selects a queue family by `VK_QUEUE_GRAPHICS_BIT`
(`libs/vulkan-wsi/.../context.d:303-304`), and a grep for `COMPUTE` across both
libraries returns nothing — no compute queue selection, no compute pipeline, no
descriptor plumbing for a storage buffer.

So a GPU prefilter is not a small program over existing bindings. It is
`sparkles:vulkan` growing a compute queue, a pipeline and a buffer-binding path,
and only then an example on top. Whatever acceleration work this catalog
recommends has to carry that ordering, and thesis T4's transfer-and-compile tax
should be read with the cost of that groundwork added to it.

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

| #   | Gap                                                | Consequence                                                                                                                       |
| --- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| 1   | No content search at all                           | `PKS2` starts from zero; there is no code to refactor, only to write                                                              |
| 2   | No bounded regex engine                            | `std.regex` allocates and throws, so it cannot enter a pool job; the substrate that could carry one is `glob.d`, five gaps away   |
| 3   | No bounded file reader                             | The only read path slurps into GC memory and throws on invalid UTF-8                                                              |
| 4   | No content binary sniff                            | Path/extension guards exist; nothing inspects bytes                                                                               |
| 5   | No public substring primitive                      | The one allocation-free implementation is `private` in `tui.d`, and the GUI uses a different, case-sensitive one                  |
| 6   | No SIMD, and no compile-time/runtime dispatch join | Portability and detection both exist outside the tree; nothing wires them together, so the first vectorised prefilter builds that |
| 7   | No GPU compute path                                | `sparkles:vulkan` must grow a compute queue and pipeline before an accelerator example exists                                     |
| 8   | No index of any kind                               | Every query is a full scan of whatever the walk yields                                                                            |
| 9   | Case semantics are already forked                  | Two in-document searches disagree; a third implementation would entrench it. **Replacing them is an outcome of this survey**      |

Gaps 1–5 are the content-search milestone. **Gap 9 is a defect the same
milestone must close**: one backend-independent matcher on `sparkles:fuzzy`
replacing both in-document implementations, so the engine has two callers rather
than the tree having three matchers. Gaps 6–8 are where this catalog's evidence
decides whether the work is worth doing at all — and 6 and 7 are each smaller
than they look, being a missing _join_ between existing pieces rather than a
missing piece.

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

Read outside this repository, at the revisions named:

- [`AuburnSounds/intel-intrinsics`][intel-intrinsics] `v1.14.9`
  (`14477c6bcadea79c5b71085dec6ddf73ffb9c60c`) — the SIMD portability layer:
  compiler matrix, ISA coverage and the AArch64 guarantee, read from its
  `README.md` and `source/inteli/`
- Druntime `core.cpuid` — capability reporting and its attribute surface, both
  `[host-verified: x86_64-linux]` on this machine

<!-- References -->

[measurement]: ./measurement.md
[fuzzy-spec]: ../../specs/fuzzy/SPEC.md
[async-io]: ../async-io/index.md
[intel-intrinsics]: https://github.com/AuburnSounds/intel-intrinsics/tree/14477c6bcadea79c5b71085dec6ddf73ffb9c60c
