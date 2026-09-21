# Fileset decisions & open questions

_Companion to [SPEC.md](./SPEC.md). Records consequential choices, the
alternatives rejected, and the questions still open. A decision here is
accepted unless marked **open**._

## Accepted

### A1 — One package, not two

Addressing and filesets both live in `sparkles:build-primitives`, behind a
strict module boundary, rather than in two packages.

The original argument for splitting was closure hygiene. It does not survive
inspection: the addressing layer adds SHA-1/SHA-256 (already in Phobos),
BLAKE3 later, and pure serializers — no system dependencies, nothing like the
`event-horizon` case. The one motivation that would carry weight —
"`sparkles:nix` must not inherit `event-horizon`" — evaporates, because
`sparkles:nix` binds `libnixstore-c` and has no need of a reimplementation.
Enumerated, every plausible digest consumer already wants `event-horizon`
anyway (a future iroh port needs QUIC).

Splitting later is mechanical if the module boundary held; maintaining two
packages costs CI time on every run in a repository that already carries ~50.

### A2 — Where the FSO vocabulary lives

Inside `sparkles:build-primitives`, in a module with no dependencies of its
own.

Candidates that would want it without being able to depend on this package are
real but hypothetical: `event-horizon`'s `fs.d` (a `Statx` → `FsoKind` helper),
and `sparkles:test-utils` (fixture tree literals). Neither is a current need,
and `sparkles:metadata` and `sparkles:input` are the repository's precedent for
a vocabulary-only package _when there are consumers_.

**Relocation trigger:** the first consumer that needs the vocabulary and cannot
depend on `build-primitives`. The move is then mechanical and
`build-primitives` re-exports, so no consumer's imports break.

### A3 — `glob.d` stays in `sparkles:fuzzy`

`build-primitives` gains `sparkles:fuzzy` as a runtime dependency rather than
moving the bounded Thompson NFA down into `sparkles:base`. Rejected
alternatives: duplicating a simpler matcher (two glob semantics in one
repository), and a DbI matcher seam (indirection with one implementation).

### A4 — Production I/O goes through `sparkles:event-horizon`

All four consumers therefore gain that dependency, including `libs/docs`, which
walks a documentation tree once at build time. The alternative — shipping a
synchronous production driver so light consumers avoid the dependency — was
rejected in favour of uniformity; the synchronous driver survives as test and
documentation material only ([`FSD3`](./SPEC.md#11-drivers-fsd)).

`event-horizon` is cross-platform (`uring` on Linux, `kqueue` on macOS, IOCP on
Windows), so this does not strand the Windows CI leg. Note that directory
enumeration is a _blocking_ call on the `cpuBound` pool: there is no
`getdents` ring opcode. `statx` is a ring operation.

### A5 — Schemes own their content I/O

The seam hands a scheme an opaque reference, never bytes
([`FSS4`](./SPEC.md#8-the-scheme-seam-fss)).

A push-based `content(span)` visitor does not merely fail to exploit
parallelism — it **forbids** it, because BLAKE3's disjoint aligned ranges hash
concurrently and an in-order feed serializes exactly that. It also imposes the
driver's read size on every scheme, when NAR wants 8-byte-padded serial writes,
git wants a header-prefixed stream and Bao wants 16 KiB-aligned groups.

Tempering fact: for the two schemes of immediate interest the intra-file work
is irreducibly serial anyway — a NAR hash is one SHA-256 over one stream, and
git's per-file hash is serial. Intra-file parallelism arrives only with the
BLAKE3 family. The seam must not forbid it; nothing in v1 exercises it.

### A6 — The admission budget belongs to `event-horizon`

Not to this library. `event-horizon` already hand-rolls the concept three
times — `loop.inFlight`, `forkserver.outstanding`, and `channel`'s bounded
parking. Three ad-hoc instances in one library is the standard signal that a
primitive is missing.

**Adoption gate:** the primitive must be able to express all three existing
call sites. If it cannot, it is this library's budget wearing a wider name, and
should not be adopted.

### A7 — Dispatch policy is a compile-time seam decided by measurement

Candidate policies — per file on visit, per leaf directory, whole list at the
end, buffer-N — are four schedulings of the same work, and
[`FSS3`](./SPEC.md#8-the-scheme-seam-fss)'s post-order fold already constrains
the space: "leaf directories first" is the fold's natural completion order, not
a competing policy.

Two things must hold before the measurement is worth running. The invariant:
digest, ordering and error set are **identical** under every policy. And the
workload: the existing `polyglot-walks` numbers are syscall-bound with zero
content reads, so they do not predict a content-hashing walk, which is
bandwidth- and page-cache-bound and usually wants a _narrower_ fan-out.

Before writing buffer-N, measure whether per-entry submission costs anything
against the pool's existing steal-half batching. If the cost is the closure per
job, the fix is a job representation, not a buffering layer.

### A8 — Breaking rewrite, alongside, consumers migrated one at a time

New module names beside the old ones; consumers migrated per PR; old modules
deleted last ([PLAN](./PLAN.md) M9). This keeps every commit green and
bisectable, and it lets the old walker serve as a behaviour-preservation oracle
until it is removed.

### A9 — Incremental invalidation stops at level 2

A content-keyed subtree cache, re-validated against a staleness heuristic, is
in scope. Filesystem watching is **not**: `watch.d` is Linux-only today,
a watcher over a large tree is its own subsystem (watch-descriptor limits,
overflow, rename storms), and its overflow fallback is a full rescan anyway.
Make the full rescan fast first.

Normative rule for any staleness heuristic: a false **"changed"** is permitted
(it costs work); a false **"unchanged"** is forbidden (it costs correctness).
The evidence that this is not a stylistic preference is
[`ccache`'s direct-mode hole](../../../research/content-addressing/build-input-caches.md) —
headers that "would have been used if they existed" are unrecorded, so a newly
added shadowing header is a false "unchanged", accepted there on cost grounds.
And the cache itself must be **advisory, never an authority**, as
[git's `cache-tree`](../../../research/content-addressing/git-cache-tree.md) is.

## Open

### D1 — Which Merkle shape

**Blocks:** the content-addressing contract and `PLAN` M6. **Does not block:**
M0–M5.

The internal identity is a Merkle tree hash; _which_ is open. The research
produced a production counter-example to the assumption that git's shape is
obvious.

|                                | git-shaped                             | REAPI/Snix-shaped                                         |
| ------------------------------ | -------------------------------------- | --------------------------------------------------------- |
| Ordering hazard (`a` vs `a.b`) | present; needs the `/`-suffix trick    | structurally absent (three sorted arrays)                 |
| Independent oracle             | **`git write-tree`, on every machine** | none comparable                                           |
| Hash                           | SHA-1 or SHA-256                       | BLAKE3, parallel by construction                          |
| Canonicity rests on            | a byte format                          | deterministic protobuf, which Snix itself flags as a risk |

[Snix](../../../research/content-addressing/tvix-castore.md), a production Nix
reimplementation, chose the second and wrote down why: git's encoding is "very
binary, error-prone and 'made-to-be-read-and-written-from-C'", and SHA-1 "isn't
really a hash function to fundamentally base everything on in 2023". It keeps
NAR strictly as a boundary format, which is the half of our position it
validates.

**Decision criterion:** how much the free `git write-tree` oracle is worth
against structural immunity to an ordering hazard that has bitten git, irmin,
Nix, Software Heritage and bup. A bounded spike — implement `gitTreeOrder`
against `git write-tree` on the fixture set — would price the oracle before the
choice is made.

### D2 — Whether `NarHash` is stored or recomputed

Provisionally **stored**, beside the Merkle identity, rather than recomputed on
demand. Snix makes `NarCalculationService` a trait precisely so a remote store
can answer without re-walking the tree and re-streaming every blob. Confirm
when the content-addressing contract is written.

### D3 — The collision escape hatch

[`FSE1`](./SPEC.md#10-errors-and-partial-results-fse) and invariant 5 imply
refusing a tree whose entries collide under case folding or normalization.
Software Heritage demonstrates a fourth position — detect at ingest, keep the
digest byte-exact via a `raw_manifest`, repair only the _model_ — which matters
for any consumer that must reproduce an upstream digest and therefore cannot
refuse. Whether this library offers that hatch, and at which layer, is open.

### D4 — Extended attributes

Out of scope for v1, but [`FSM2`](./SPEC.md#7-the-resolution-machine-fsm)
requires the request vocabulary to be open so that adding
`listxattr`/`getxattr` is not a breaking change. Whether OSTree-style identity
is ever a goal is undecided.
