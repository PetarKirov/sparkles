# `sparkles:build-primitives` filesets — Specification

_**Status:** proposed; no requirement is implemented · **Date:** September 21, 2026
· **Owner:** `sparkles:build-primitives`_

_Normative at the contract level. Delivery order and gates live in
[PLAN.md](./PLAN.md); consequential choices and unresolved questions live in
[decisions.md](./decisions.md). The evidence base is the
[fileset-languages](../../../research/fileset-languages/index.md) and
[content-addressing](../../../research/content-addressing/index.md) research
catalogs. The textual query language is a separate track and is **not**
specified here._

## 1. Purpose and scope

A **fileset** names a set of files. This specification defines the value that
names it, the machine that resolves it against a filesystem, and the seam
through which a consumer observes the result.

The problem it replaces is concrete. `sparkles:build-primitives` today exposes
a depth-first, GC-allocating, exception-throwing walker whose `.gitignore`
verdict is a mutable push/pop stack. It cannot run in parallel, cannot be
budgeted, allocates per directory, and its include/exclude layer cannot express
"these files **and** those files" (see [`FSA5`](#fsa-analysis-and-planning)).
Four consumers depend on it: `apps/hue` (three call sites), `libs/docs`, and
two examples.

**In scope.** The fileset value and its algebra; compilation to a resolution
plan; the sans-I/O resolution machine and its I/O request vocabulary; the
scheme seam; drivers; error and partial-result semantics; the file-system
object vocabulary shared with content addressing.

**Non-goals for the first delivery.** The textual query language (separate
track). Content digests, serialization and NAR/Merkle schemes — a sibling
contract under `docs/specs/build-primitives/content-addressing/`, not yet
written; this document specifies only the _seam_ such a scheme plugs into.
Filesystem watching. Extended attributes. A REPL.

**Deferred with entry conditions.** Cross-run subtree caching (`FSC*`) is
specified but not delivered until a Merkle scheme exists to key it; see
[decisions.md](./decisions.md#d1-which-merkle-shape).

## 2. Invariants

Normative, and every later requirement is read against them.

1. **The library performs no I/O.** No module under
   `sparkles.build_primitives` opens, reads, stats, or enumerates anything. All
   filesystem effects are performed by a driver outside the library and
   supplied as responses to explicit requests (`FSM*`).
2. **Evaluation is `@safe pure nothrow @nogc` and allocation-free.**
   Compilation may allocate into a caller-supplied arena; the resolution
   machine's step, verdict and membership operations may not allocate at all.
   `@nogc` is necessary and is not accepted as proof; see
   [§9](#9-evidence-and-oracles).
3. **Borrowed input, owned output.** Every span a fileset exposes borrows from
   caller memory. The library owns no string. A source buffer must outlive
   every operation borrowing it.
4. **Errors are values.** Public operations return `Expected`. Public
   assertions never reject caller-controlled data; malformed input is a
   returned error, not an assertion failure.
5. **Identity is byte-exact.** No path comparison used for identity, ordering
   or membership performs case folding or Unicode normalization. Case policy
   exists only in _matching_ (`FSG3`).
6. **Analysis may only widen.** Every static conclusion the planner draws is a
   sound over-approximation of the fileset's true membership (`FSA1`).

## 3. The file-system object vocabulary (`FSO`)

Shared with the content-addressing contract, and deliberately minimal.

**`FSO1` — Node kinds.** An entry must be exactly one of `regular`,
`directory`, or `symlink`. A `regular` entry carries one boolean, `executable`.
A `symlink` carries its target as an opaque byte string. No other node kind is
representable. _Detection:_ the kind enum has three members and construction of
any other shape does not compile.

**`FSO2` — Symlinks are values.** The machine must never follow a symlink to
determine membership, kind, or content. A symlink's target is data. _Detection:_
a fixture whose symlink points outside the root resolves without the driver
issuing any request against the target path.

**`FSO3` — Excluded metadata.** Ownership, permission bits other than the
executable bit, timestamps, hard-link counts and extended attributes are not
part of `FSO1` and must not affect membership. _Detection:_ two fixtures
differing only in mtime and mode (executable bit held constant) produce
identical resolution results.

**`FSO4` — Metadata is requested, never assumed.** A consumer declares the
metadata it needs (`FSS2`); the machine must issue a `stat` request only when
a declared need or an undecidable kind requires one. _Detection:_ a consumer
declaring no metadata resolves a fixture with zero `stat` requests recorded by
the driver.

> The vocabulary is a dependency-free module inside `sparkles:build-primitives`.
> It moves to `sparkles:base` only when a consumer appears that cannot depend
> on this package; see [decisions.md](./decisions.md#d2-where-the-fso-vocabulary-lives).

## 4. The fileset value (`FSV`)

**`FSV1` — Closed algebra.** A fileset is a value closed under union,
intersection and difference. Two filesets composed by any of those operations
yield a fileset with no loss of information. _Detection:_ the operations are
total functions over the type; there is no failure mode for composition itself.

**`FSV2` — No unary complement.** The algebra must not provide complement.
_Rationale:_ a complement has no literal path prefix, so `FSA2`'s analysis must
widen to `⊤` and the plan degenerates to walking every reachable directory.
_Detection:_ no complement operation exists; difference against an explicit
universe is the supported spelling.

**`FSV3` — Directories are not members.** A fileset contains files. A directory
is never a member, and no operation admits one. _Detection:_ resolving a
fileset that names a directory path yields the files beneath it, never an entry
for the directory.

**`FSV4` — Empty directories are reported, not contained.** The resolution
result must carry, separately from its members, the set of directories that
were entered and yielded no members. _Rationale:_ nixpkgs' `lib.fileset`
documents the absence of this as a known gap requiring an extra `toSource`
argument; making it an explicit side output costs nothing and closes it.
_Detection:_ a fixture containing an empty directory under the selected roots
reports exactly that directory and no members.

**`FSV5` — Compilation is fallible; evaluation is not.** Constructing a fileset
from patterns may fail (a malformed glob, a bound exceeded) and returns
`Expected`. Once compiled, membership and verdict operations return values and
cannot fail. _Detection:_ evaluation entry points are `nothrow` and return
non-`Expected` types.

## 5. Matching (`FSG`)

**`FSG1` — Anchoring.** A pattern containing `/` is anchored to the fileset
root; a pattern containing no `/` matches at any depth; a leading `/` forces
the root. This is `.gitignore`'s rule. _Detection:_ `*.md` matches `a/b.md`;
`src/*.d` does not match `lib/src/x.d`; `/*.md` does not match `a/b.md`.

**`FSG2` — This replaces `globAny`.** The current implementation matches each
glob against both the base name and the root-relative path, which makes
anchoring inexpressible. `FSG1` is a behaviour change to `apps/hue`'s tree pane
and `libs/docs`' `srcExclude`; those call sites must be reviewed during
migration (`PLAN` M9). _Detection:_ the M4 differential gate reports the
divergence set rather than hiding it.

**`FSG3` — Case and normalization are matching policy only.** A fileset carries
an explicit case policy. Its default is case-sensitive. No policy affects
identity or ordering (invariant 5). _Detection:_ changing the policy changes
which entries match and never changes the ordering of those that do.

**`FSG4` — Glob compilation is bounded.** Patterns compile to the bounded
Thompson NFA in `sparkles.fuzzy.glob`. A pattern exceeding a configured bound
returns an error rather than allocating further. _Detection:_ a pattern beyond
the bound returns the bound-exceeded error; no allocation occurs after it.

## 6. Analysis and planning (`FSA`)

**`FSA1` — Widening soundness.** For every fileset `F` and every directory `D`
reachable from a root, if any file beneath `D` is a member of `F`, the plan
must not mark `D` as `skip`. The analysis may mark a directory `descend` that
contains no members; it must never mark one `skip` that does.
_Detection:_ the differential oracle in [§9](#9-evidence-and-oracles) compares
the planned resolution against a brute-force walk that ignores all verdicts;
any member present in the brute-force result and absent from the planned one is
a failure.

**`FSA2` — Root derivation.** The planner must derive a set of start roots from
the fileset's literal path prefixes, with a `⊤` (unknown) element for
constructs it cannot analyse. Union takes the union of prefix sets;
intersection may take the longest; difference takes the left operand's roots.
_Detection:_ `src/**/*.d` starts at `src`; `src/** | libs/**` starts at both;
an expression containing an unanalysable operand starts at the fileset root.

**`FSA3` — Directory verdicts.** A plan assigns each entered directory exactly
one of `skip` (do not enumerate), `descend` (enumerate and evaluate children),
or `acceptAll` (enumerate recursively; no further matching is performed).
_Detection:_ a fileset naming a whole subtree reports `acceptAll` for that
directory and the machine issues no match evaluation beneath it.

**`FSA4` — File verdicts include `undecided`.** A file verdict is `accept`,
`reject`, or `undecided`. `undecided` obliges the machine to issue the request
that resolves it and re-evaluate. _Detection:_ a fileset whose membership
depends on the executable bit yields `undecided` before the `stat` response and
a definite verdict after.

**`FSA5` — Forced entry.** If a fileset admits any file beneath a directory
that a `.gitignore` scope would exclude, the plan must still `descend` that
directory. _Rationale:_ the current `GitGlobFilter` documents the opposite — an
include glob "re-admits files the walk reaches, it does not force entry" — so
`gitTracked | build/**/*.o` is unobtainable today. _Detection:_ that exact
fileset over a fixture with an ignored `build/` yields the object files.

**`FSA6` — Statically empty expressions are detectable.** The planner must
report when the prefix lattice proves the result empty (for example an
intersection of operands with disjoint literal prefixes). This is a diagnostic,
not an error. _Detection:_ `src/** & libs/**` reports statically empty;
`src/** & src/a/**` does not.

## 7. The resolution machine (`FSM`)

**`FSM1` — Request/response, not effects.** The machine advances by emitting a
batch of requests and consuming their responses. It must never perform an
effect itself. _Detection:_ the machine's modules import nothing from
`std.file`, `std.stdio`, `core.sys` or `sparkles:event-horizon`.

**`FSM2` — Request vocabulary.** The request kinds are `readDir`, `stat`,
`readlink` and `readFile`. The set is **open**: a scheme or policy may require
a kind a driver does not implement, and the driver must answer with a typed
`unsupportedRequest` error naming the kind rather than omitting the response.
_Detection:_ a scheme declaring a need no driver satisfies fails with that
error, naming the kind.

**`FSM3` — Requests are batched per directory.** All requests arising from one
directory's entries must be emitted as one batch. _Rationale:_ a
request-at-a-time coroutine serializes the fan-out the design exists for, and a
driver can submit a batch as one `io_uring_enter`. _Detection:_ resolving a
directory of `n` entries needing metadata emits one batch, not `n` batches.

**`FSM4` — The machine issues no content requests.** `readFile` exists to
satisfy `.gitignore` scopes (`FSI*`) only. File _content_ is never requested by
the fileset machine. _Rationale:_ content acquisition belongs to a scheme
(`FSS4`), and a pushed content stream forecloses intra-file parallel hashing.
_Detection:_ a consumer that declares no scheme resolves any fixture without a
single content byte being read.

**`FSM5` — Emission is directory-granular.** The machine emits a directory's
entries as one unit, in the scheme's declared order (`FSS1`). _Detection:_ a
fold scheme receives each directory exactly once, after its children.

**`FSM6` — Bounded work per step.** A step performs work bounded by a
caller-supplied budget and returns a resumable cursor. A cursor is valid only
for the resolution that produced it. _Detection:_ a fixture resolved in one
step and in many steps with a small budget yields identical results; a cursor
from one resolution is rejected by another.

**`FSM7` — Bounds.** Directory nesting, entry-name length and pending-request
count are bounded by configured limits. Exceeding a limit is a returned error.
Defaults: depth 64, name 255 bytes — the values NAR and Snix independently
chose, the former explicitly to bound stack use on a coroutine stack.
_Detection:_ fixtures at depth 65 and with a 256-byte name return the
respective errors.

## 8. The scheme seam (`FSS`)

A **scheme** is a consumer of a resolution: a digest producer, a path
collector, a picker corpus.

**`FSS1` — Declared ordering.** A scheme declares its required entry ordering
as one of `none`, `narOrder`, `gitTreeOrder`, `partitionedOrder`. The machine
sorts each directory's entries accordingly. _Detection:_ each ordering is
pinned by the `a` versus `a.b` fixture, which distinguishes `narOrder` from
`gitTreeOrder`.

**`FSS2` — Declared metadata.** A scheme declares a metadata mask. The mask
must be able to include `mtime` even though `FSO3` excludes it from membership
and identity. _Rationale:_ REAPI carries an optional `mtime` node property; the
value arrives in the `stat` already issued for the executable bit.
_Detection:_ a scheme declaring `mtime` receives it; one that does not causes
no `stat` on that account.

**`FSS3` — Declared traversal mode.** A scheme is `stream` (pre-order,
side-effecting into a sink) or `fold` (post-order, returning a value per
directory computed from its sorted entries and its children's values). The
machine's completion order is derived from the declaration. _Detection:_ a fold
scheme's directory callback is never invoked before all of its children's.

**`FSS4` — Schemes own their content I/O.** The machine hands a scheme an
opaque driver-defined reference per entry, never bytes and never a digest. A
scheme performs its own reads, at its own concurrency, through the shared
budget (`FSS6`). _Detection:_ a scheme that reads disjoint ranges of one file
concurrently is expressible and the machine issues no content request.

**`FSS5` — `none` ordering is excluded from fold schemes at compile time.**
_Rationale:_ `readdir` order is nondeterministic and varies across runs and
hosts, so a digest over it is silently wrong. _Detection:_ instantiating a fold
scheme with `none` fails to compile.

**`FSS6` — One shared admission budget.** The walk and every scheme acquire
in-flight operations, bytes and descriptors from one budget object owned by the
driver, so a scheme reading a very large file applies backpressure to the walk
rather than racing it. Defaults derive from `sparkles.base.hw_caps`.
_Detection:_ with a budget of one in-flight operation, a resolution completes
and never exceeds it.

**`FSS7` — The walk joins scheme work.** A resolution does not report
completion until every scheme operation it initiated has completed.
_Detection:_ a scheme that defers work cannot observe completion before its
deferred work runs.

**`FSS8` — A level-2 tree may arrive out of band.** A scheme must be able to
_receive_ a precomputed intra-file Merkle tree instead of constructing one.
_Rationale:_ APK v4 ships `.apk.idsig` alongside the artifact; iroh stores an
outboard. _Detection:_ the scheme interface accepts a supplied tree and the
verification path does not require hashing the artifact.

## 9. Ignore scopes (`FSI`)

**`FSI1` — Immutable shareable scopes.** A `.gitignore` scope chain is an
immutable structure in which a child refers to its parent by index into an
arena. It must be copyable by value and safe to share between concurrently
resolving directories. _Rationale:_ the current push/pop stack cannot be shared
at all; reference counting was rejected on the event-horizon benchmark's
cross-core-bouncing evidence. _Detection:_ a scope handle is an integer-sized
value type, and two sibling directories resolve concurrently against one chain.

**`FSI2` — Arena lifetime.** The scope arena is owned by the resolution and
released when it completes. _Detection:_ peak arena residency is reported and
bounded by the count of directories containing a `.gitignore`.

**`FSI3` — Rule provenance.** Each rule must carry the path of the
`.gitignore` that declared it and its 1-based line number. _Detection:_
`git check-ignore -v` parity on a fixture: the reported file and line match
git's for every path.

**`FSI4` — Deeper scopes win.** Precedence is git's: within a scope, the last
matching rule decides; a deeper scope overrides a shallower one; a negation
cannot re-include a file beneath an excluded directory. _Detection:_ a nested
fixture exercising each clause matches `git check-ignore`'s verdicts.

## 10. Errors and partial results (`FSE`)

**`FSE1` — Failures split by consequence, not by source.** A failure that makes
the result **wrong** is fatal to the resolution. A failure that makes it merely
**incomplete** is recorded per entry and the resolution continues.
_Detection:_ a fixture with one unreadable directory completes and reports it;
a fixture whose scheme fails mid-file aborts.

**`FSE2` — Incompleteness is observable.** A completed resolution must report
the set of paths it could not read, with the reason. A consumer that requires
completeness must be able to detect its absence without inspecting logs.
_Detection:_ the result type carries the list; a digest consumer refuses a
result whose list is non-empty.

**`FSE3` — Vanishing entries are incompleteness, not corruption.** An entry
enumerated but gone by the time it is examined is recorded per `FSE1` and does
not fail the resolution. _Detection:_ a driver fixture that removes an entry
between `readDir` and `stat` completes with that entry recorded.

**`FSE4` — The result type is the scheme's.** A resolution returns
`Expected!(Scheme.Result, ResolutionError)`. No common "list of files" is
imposed. _Detection:_ a path-collecting scheme returns paths; a digest scheme
returns a digest; neither type mentions the other.

## 11. Drivers (`FSD`)

**`FSD1` — Three drivers, one machine.** An in-memory driver, a synchronous
driver, and an `sparkles:event-horizon` driver must satisfy the same request
vocabulary. _Detection:_ the differential gate in [§12](#12-evidence-and-oracles)
runs all three over one fixture set and compares results byte for byte.

**`FSD2` — The in-memory driver ships.** It is a supported, documented driver
and not a test double: it answers from a declared tree literal with no
filesystem. _Rationale:_ it makes the whole contract testable `@nogc`,
deterministically, on every platform, with no temp directories.
_Detection:_ the acceptance suite runs entirely against it on Windows and macOS.

**`FSD3` — The synchronous driver is test and documentation only.** It is not a
shipped production path. _Detection:_ it is not reachable from the library's
public configuration.

**`FSD4` — Descriptor policy is the driver's.** Any `RLIMIT_NOFILE` strategy
belongs to a driver, never to the machine or the seam. _Detection:_ the machine
contains no descriptor accounting.

## 12. Evidence and oracles

The trace required for acceptance is
`requirement -> falsifying scenario -> oracle -> scoped evidence`.

| Oracle                                                                                                       | Independence                                                | Establishes                                                 |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- | ----------------------------------------------------------- |
| **Brute-force resolution** — evaluate the predicate against every file under the root, ignoring all verdicts | A different algorithm, not a second instance of the planner | `FSA1` widening soundness; `FSA3` and `FSA5` verdicts       |
| **Three-driver differential** — in-memory, synchronous, event-horizon over one fixture set                   | Three independent effect implementations                    | `FSD1`; `FSM1`'s claim that the machine is effect-free      |
| **`git check-ignore -v`**                                                                                    | An independent implementation of the semantics being copied | `FSI3` provenance, `FSI4` precedence                        |
| **The old walker** — retained until M9                                                                       | The implementation being replaced                           | M4's behaviour-preservation gate; the `FSG2` divergence set |
| **`a` versus `a.b` fixture**                                                                                 | A published, reproducible ordering divergence               | `FSS1`'s two orderings are not one function                 |
| **Allocation instrumentation** — libc wrap plus the GC counter, as `sparkles:fuzzy` does                     | Measures the property `@nogc` does not prove                | Invariant 2                                                 |

Each requirement's evidence state is `unverified`, `partial` (naming the
missing case), or `verified` (naming the configuration whose acceptance suite
passed). Every requirement in this document is currently **unverified**.

Two limits are stated rather than papered over. The three-driver differential
proves the drivers agree, not that any of them is correct; the brute-force
oracle supplies that for membership. And a deterministic in-memory driver does
not establish that real concurrent interleavings are safe — `FSI1` and `FSS6`
need native concurrent tests, not model-level ones.

## 13. Requirement index

| Group                                                     | Covers                                                                                |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| [`FSO1`–`FSO4`](#3-the-file-system-object-vocabulary-fso) | Node kinds, symlinks, excluded metadata, requested metadata                           |
| [`FSV1`–`FSV5`](#4-the-fileset-value-fsv)                 | Algebra, no complement, directories, empty directories, fallibility                   |
| [`FSG1`–`FSG4`](#5-matching-fsg)                          | Anchoring, the `globAny` replacement, case policy, bounds                             |
| [`FSA1`–`FSA6`](#6-analysis-and-planning-fsa)             | Widening, roots, verdicts, forced entry, static emptiness                             |
| [`FSM1`–`FSM7`](#7-the-resolution-machine-fsm)            | Sans-I/O, requests, batching, no content, emission, budget, bounds                    |
| [`FSS1`–`FSS8`](#8-the-scheme-seam-fss)                   | Ordering, metadata, traversal mode, scheme-owned I/O, budget, join, out-of-band trees |
| [`FSI1`–`FSI4`](#9-ignore-scopes-fsi)                     | Immutable scopes, arena lifetime, provenance, precedence                              |
| [`FSE1`–`FSE4`](#10-errors-and-partial-results-fse)       | Fatal versus incomplete, observability, vanishing entries, result type                |
| [`FSD1`–`FSD4`](#11-drivers-fsd)                          | Three drivers, in-memory ships, synchronous is test-only, descriptors                 |

Consumers of this contract: `apps/hue`'s picker ([`PKS1`, `PKC4`](../../hue/picker.md)),
`libs/docs`' source set, and `apps/ci`.
