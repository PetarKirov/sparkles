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

**Gate met (November 7, 2026).** The primitive is `Admission` in
`sparkles.event_horizon.admission`
([event-horizon SPEC §14.2](../../event-horizon/SPEC.md#_14-2-admission)), and
all three call sites now count with it, each ported in a commit of its own
with `dub test :event-horizon` green. `Channel` is two admissions, free slots
and buffered items, the second starting fully in use. The loop's `OpSlab`
reserves its held op slots as the reserved share. The fork server holds a unit
from `submit` to `release`. Two of the ports changed behaviour, each towards
what the surrounding code documented. The op slab no longer counts an active
internal cancel against the user budget. The fork server's `inFlight` now
counts a taken but unreleased response, as its comment always said.

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

### A11 — Patterns compile one component at a time

A pattern is split at `/` and each component other than `**` compiles to its
own bounded NFA from `sparkles.fuzzy.glob`; the pattern is then an automaton
over path components whose state is one bit per segment position, so a
directory's state for one pattern is a single word
([`FSG1`](./SPEC.md#5-matching-fsg), [`FSG4`](./SPEC.md#5-matching-fsg)).

The alternative, one NFA over the whole relative path, was rejected because
the planner needs a verdict per _directory_
([`FSA3`](./SPEC.md#6-analysis-and-planning-fsa)): with a whole-path NFA a
directory's verdict is a question about every possible continuation of a
prefix, which the engine does not answer, whereas a set of live segment
positions answers it directly (empty means `skip`; a completed pattern means
`acceptAll`). It also keeps each match bounded by one name's length, 255
bytes ([`FSM7`](./SPEC.md#7-the-resolution-machine-fsm)), instead of a
path's, which is what lets evaluation be infallible
([`FSV5`](./SPEC.md#4-the-fileset-value-fsv)).

Three consequences are recorded in `FSG1` as amended: a brace alternative may
not contain `/` (`{src/a,lib}` is refused rather than silently split), a `.`
or `..` component is refused because no listing yields one, and a leading `!`
is refused because `.gitignore` reads it as negation. And one is recorded in
`FSG3`: the engine normalizes both sides to NFC, so normalization is part of
every policy, not only of a case-insensitive one.

### A12 — A start root is a literal no other name matches

The planner opens a start root directly, without listing its ancestors
([`FSA2`](./SPEC.md#6-analysis-and-planning-fsa)). That is sound only if the
literal it opens is the _only_ name the pattern's component matches; otherwise
a sibling spelled differently, but matching, is never listed and its members
are lost, which is an `FSA1` violation.

Matching normalizes to NFC under every policy ([A11](#a11-patterns-compile-one-component-at-a-time)),
and NFC maps three non-ASCII code points onto ASCII: U+212A KELVIN SIGN to
`K`, U+1FEF GREEK VARIA to `` ` ``, and U+037E GREEK QUESTION MARK to `;`. No
other non-ASCII sequence normalizes to pure ASCII, because composition only
ever produces non-ASCII characters. So under the case-sensitive policy an
ASCII literal without those three characters is matched by its own bytes and
nothing else; under the case-insensitive policy no literal is, since case
folding is itself a second spelling.

Rejected: matching literal components byte-exactly while globs normalize.
It would make root derivation trivially sound, but `Keep` and `K*` would then
disagree about a directory named with the Kelvin sign, so a fileset's meaning
would depend on whether a component happened to contain a metacharacter.

### A13 — An empty directory is a memberless leaf of the walk

[`FSV4`](./SPEC.md#4-the-fileset-value-fsv) asked for "the directories that
were entered and yielded no members" while its detection wants exactly the
empty directory reported, never its ancestors. Read recursively, the first
phrase reports `src` as well as `src/empty`, because `src` yields no member
either. FSV4 now reports a directory the resolution listed that holds no
member file and no subdirectory the resolution entered: the leaves of the
walk that hold nothing selected. Each one is decided from the directory's own
listing, with no second pass.

The rejected reading, "physically empty", is narrower. It would not report a
directory that holds only non-members, which a consumer copying the
selection must still create to keep the shape.

**Open:** with an unanchored pattern in the fileset, every directory is live,
so every memberless leaf is reported: `*.md` over a source tree reports each
directory without Markdown. Whether consumers want that, or want the report
limited to directories beneath an `acceptAll` verdict or a literal root, is
the owner's call. The build graph's listings, the first consumer, do not read
the report.

### A14 — The driver opens every directory with `walk`

The capability VFS applies a root's resolution policy, link following and
mount checking, in `walk`. `openDir` performs the bare single-name open.
So the driver opens each fileset root and each child directory with `walk`
on one name, and the root's policy decides every crossing
([`FSD6`](./SPEC.md#11-drivers-fsd), [`FSD7`](./SPEC.md#11-drivers-fsd)).
Opening children with `openDir` would cross mounts silently.

Two consequences. First, the VFS's own lookups may `stat`: its
device comparison does so on every step. `FSO4`'s count is of the machine's
`stat` requests, not of backend calls. Second, under `symlinks = beneath` a
link is judged as both a directory and a file: it is listed at its own path if
its target is a directory beneath the root, and stays a member as a link value
if its target is a file or is missing. A link the policy refuses is reported
as incomplete and is not a member, so a consumer that, like the build graph
(BGF3), must reject an escaping link finds it in the report.

The executable bit is read only from a regular file (`FSO1`). On Linux a link's
mode is always 0777, so `executable` would otherwise select every link on
disk and none in `MemVfs`; the three-backend gate found that.

### A15 — A `.gitignore` line is read as git reads it

[`FSI4`](./SPEC.md#9-ignore-scopes-fsi) copies git's precedence, and the
verdicts follow only if each line means what it means to git. So a line is
read by git's rules and then translated into fileset pattern syntax
(`readIgnoreLine`). A trailing `\r` is dropped. Only unescaped trailing
spaces are trimmed, never tabs. One leading `!` negates, and a second is
literal. `\!` and `\#` stay escapes. Git's globs have no brace alternatives, so
`{` and `}` are escaped and stay literal. The rest of the syntax means the
same in both: `*`, `?`, classes, `**`, escapes, anchoring by a leading or
middle `/`, and a trailing `/` for directories.

The root `.gitignore` leaf of M1 had read lines with its own rules. It trimmed
trailing tabs, dropped the backslash of `\!`, which made the rule fail to
compile, and gave braces their fileset meaning. It now shares the reader.

A line git reads but no fileset pattern can express, such as one with a `.`
or `..` component, is skipped and counted (`IgnoreScopes.skippedRules`). It
is not an error, because a stray line in a vendored `.gitignore` must not
fail a resolution. Git never matches a `.` or `..` component against a
listed name, so skipping such a line changes no verdict. A rule over
[`FSG4`](./SPEC.md#5-matching-fsg)'s bounds is the one case where skipping
can change a verdict, and it is counted like the rest.

### A16 — The resolution finds the scopes, and reads only `.gitignore` files

`Filesets.gitignored` is a leaf whose scopes only a resolution knows: the
machine reads each `.gitignore` as it walks, applying it to the paths beneath
its own directory ([`FSI1`–`FSI4`](./SPEC.md#9-ignore-scopes-fsi)). This is
the one content read the machine makes
([`FSM4`](./SPEC.md#7-the-resolution-machine-fsm)). Which files it reads:

- **Above a start root:** the fileset root's and each directory's on the
  way down to the root, one `readFile` batch each, before the root is
  listed. A start root may sit deep in the tree ([`FSA2`](./SPEC.md#6-analysis-and-planning-fsa)),
  and the rules above it still apply to it.
- **In the walk:** a directory's own, after it is listed and before its
  entries are evaluated. Its entries' verdicts depend on those rules, so
  that read is a batch of its own, ahead of the entries' one `stat` batch
  ([`FSM3`](./SPEC.md#7-the-resolution-machine-fsm)).
- **Not read:** one in an excluded directory, which git never reads either,
  so forced entry beneath it ([`FSA5`](./SPEC.md#6-analysis-and-planning-fsa))
  sees nothing re-included. One listed as a link, which git no longer
  follows.
  Anything outside the fileset root: `$GIT_DIR/info/exclude`,
  `core.excludesFile`, and the `.gitignore` of a directory above the fileset
  root.

So the fileset root is the repository's root when git's view is wanted. The
other exclude sources are the repository's or the user's configuration, not
files of the tree, and a consumer composes them with
`Filesets.ignored(text)` at that root.

The alternative rejected was a caller-supplied chain: the caller would read
every `.gitignore` before resolving, which is a walk of its own.

Failure is split by cause. A `.gitignore` that cannot be read is reported
incomplete ([`FSE2`](./SPEC.md#10-errors-and-partial-results-fse)) and its
rules do not apply. One larger than `IgnoreLimits.maxFileBytes`, or scopes
beyond any other `IgnoreLimits` bound, end the resolution with
`capacityExceeded` ([`FSM7`](./SPEC.md#7-the-resolution-machine-fsm)). A
silently dropped scope would include what git excludes.

Reading needs a root opened with read rights. `filesetRights` alone answers
`readFile` with `unsupported`, so a `gitignored` fileset there fails naming
the kind ([`FSM2`](./SPEC.md#7-the-resolution-machine-fsm)) rather than
resolving as if no `.gitignore` existed.

`FilesetEvaluator.contains` and the planner have no scopes. For them the
leaf excludes nothing beyond what is already known, so a directory beneath
no excluded one is `maybe` excluded and is still descended (`FSA1`).

### A17 — The M4 divergence record

M4's gate (`fileset.gate.m4.behaviourPreservation`) runs the old walker and
the machine over real repositories. Each divergence falls into one of three
classes; anything else fails the gate.

- **The old walker's defect.** On the `.gitignore` walk alone
  (`walkGitRepository` against `everything - gitignored - /.git`), git
  itself (`git check-ignore -v --no-index`) agrees with the machine. These
  are fixed by the machine, not reproduced by it.
- **Anchoring ([`FSG2`](./SPEC.md#5-matching-fsg)).** Through the glob
  layer (`globWalkGitRepository` against the fileset stating the same
  include and exclude), the old `globAny` and the fileset pattern decide the
  path differently: the old matcher lets `*` cross `/`, tries every glob
  against the base name too, and has no `**` that matches zero components.
- **Forced entry ([`FSA5`](./SPEC.md#6-analysis-and-planning-fsa)).** An
  include glob reaches a file beneath a directory `.gitignore` excludes; the
  old walker never enters one.

The PLAN named only `FSG2`. The other two are the machine meeting
requirements the old walker misses, so the gate accepts them and records
them here rather than reproducing them.

Recorded on November 8, 2026 (Linux x86_64, DMD 2.112.1):

| Tree                                                                 | Files  | Old defects | Anchoring | Forced entry | Unexplained |
| -------------------------------------------------------------------- | ------ | ----------- | --------- | ------------ | ----------- |
| this repository                                                      | 5 234  | 0           | —         | —            | 0           |
| `docs/`, the site's own `srcExclude`                                 | 2 672  | 0           | 290       | 0            | 0           |
| `libs/`, include `*-test-*`, exclude `*/src/sparkles/*.d` and `*.md` | 1 929  | 0           | 992       | 3            | 0           |
| linux                                                                | 72 857 | 15          | —         | —            | 0           |
| FrameworkBenchmarks                                                  | 5 853  | 7           | —         | —            | 0           |
| eight smaller repositories                                           | 2 712  | 0           | —         | —            | 0           |

The old walker's defects are two:

- **A negated bracket expression.** linux's
  `tools/testing/selftests/arm64/signal/.gitignore` reads `mangle_*`,
  `fake_sigreturn_*`, `!*.[ch]`. Git keeps the 15 `.c` and `.h` files; the
  old walker drops them.
- **A negation with a leading globstar.** FrameworkBenchmarks' root
  `bin/` is countered by `frameworks/OCaml/.gitignore`'s `!**/bin`. Git
  enters those `bin` directories (7 files); the old walker does not.

The 290 anchoring divergences in `docs/` matter to the migration: the site's
`srcExclude` globs are written for VitePress, whose `**/` matches zero
directories as the fileset's does. Where the two readings of `**/` disagree, the
fileset's is the one the site means. M9 reviews each consumer's globs with this
record; it is closed when the last consumer is migrated.

### A18 — The scheme seam, as built

A scheme is a struct, and what it declares are enums read by `shapeOf`:
`order`, `metadata` and `traversal`, each defaulting to what a path collector
needs (`none`, nothing, `stream`). `shapeOf` refuses a fold over `none` with a
`static assert`, so `FSS5` holds wherever a scheme is used, not only in
`resolveScheme`. A stream implements `visit`, a fold `fold`, and both
`incomplete` and `finish`; each returns `false` to abort, which fails the
resolution with `schemeFailed` (`FSE1`). Where an incomplete entry lands is
the scheme's to decide (`FSE2`, `FSE4`): `PathScheme` keeps a list in its
result, and a digest returns `false` from `incomplete`.

**Orders.** `none` is byte order, the machine's own. `partitionedOrder` is
directories, then regular files, then links, each by name, as Snix's
`Directory` message keeps them. `narOrder` and `gitTreeOrder` are the formats'
own; `precedes` is the one comparison all four use.

**A stream's unit comes after its subdirectories are listed.** That is still
before any of their units, so the order is pre-order, and it lets the unit say
which subdirectories opened, and whether the directory is empty (`FSV4`).
Units from a stream used to arrive post-order, like a fold's; nothing outside
the package consumed them.

**A fold ends at the fileset root.** A fold's result is one value, but a
plan's start roots may lie beneath the root. The machine hands over the
directories above them as units of their own, each holding the subdirectories
through which a start root that held anything was reached. It sorts the start
roots by bytes, which keeps each directory's descendants together, so these
units also arrive post-order. A directory above the roots that ends up holding
nothing is dropped; the fileset root never is. Its handle is not alive: it was
never opened.

**Metadata is per member, and only on request.** A declared `executable` or
`mtime` stats each member file not already stat-ed; `mtime` also stats member
links; `linkTarget` reads each member link's target in the same batch as the
stats. A link's executable bit is `false` by `FSO1`, so a fileset that asks
for it decides a link without a stat. Directories carry no metadata: no
scheme of interest needs it, and REAPI's directory properties can be added
later without changing a unit's shape.

**An `FsoRef` is borrowed for one call.** The driver retires a directory's
handle once its unit is consumed, because keeping handles alive for deferred
work would make descriptor use unbounded (`FSD4`). A scheme that wants
concurrent reads opens its files during the call and hands the open files to
spawned work, as `fileset.scheme.FSS4.schemeOwnedReads` does. A closure that
captures a struct with a destructor still destroys it when the capturing
frame ends, so such work holds the file on the heap.

**The supplied tree of `FSS8` has no type yet.** The seam lets a scheme find
one through an entry's reference and verify without opening the entry. The
tree's shape is the content-addressing contract's, so `FSS8` stays partial
until M6.

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

### A10 — Handles, not paths, through the capability VFS

A driver materializes an `FsoRef` as a directory handle plus a name, and every
request is a single-name operation on a handle the walk already holds
([`FSD5`](./SPEC.md#11-drivers-fsd)–`FSD7`). The handles are the
[capability VFS](../../base/vfs/SPEC.md)'s, and the three drivers are one
adapter over its three backends.

Path-based resolution was rejected on three counts, of which only the first is
about speed: the kernel re-walks an absolute path on every operation, so
resolution is `O(depth)` per entry rather than `O(1)`; a path re-resolved after
a rename above it names a different file, which makes
[`FSE3`](./SPEC.md#10-errors-and-partial-results-fse)'s
"an entry vanished mid-walk" indistinguishable from "an ancestor moved"; and
"the walk stayed beneath its root" is a property a path cannot assert, only
hope for.

An earlier version of this decision had the event-horizon driver call
`openat2` itself, with `RESOLVE_BENEATH`, `RESOLVE_NO_MAGICLINKS` and
`RESOLVE_NO_XDEV`, and not `RESOLVE_NO_SYMLINKS`, since that flag would also
refuse opening a link to read its target. It was replaced for three reasons:

- **One mechanism, not two.** `sparkles:test-utils` checked its fixture paths
  with a portable string comparison while the walker would have used the
  kernel. Both now resolve through the VFS, whose component walk gives the
  same answer as the kernel resolver on every platform
  ([`VFR1`](../../base/vfs/SPEC.md#vfr1-two-resolvers-one-result)), so the
  guarantee no longer depends on the leg.
- **The link exception disappears.** The VFS never follows the named entry
  ([`VFO2`](../../base/vfs/SPEC.md#vfo2-the-named-entry-is-never-followed));
  reading a target is `readlinkAt` on the link's directory, so refusing every
  link during resolution costs the node model nothing.
- **Absence is already a typed answer.** The root reports its resolver, and a
  consumer that needs the kernel's guarantee asks for it and gets
  `unsupported` where it is absent
  ([`VFR2`](../../base/vfs/SPEC.md#vfr2-the-root-reports-its-resolver),
  [`VFR3`](../../base/vfs/SPEC.md#vfr3-a-root-may-require-the-kernel-resolver)).
  The fileset library no longer needs its own capability channel for it.

### D4 — Extended attributes

Out of scope for v1, but [`FSM2`](./SPEC.md#7-the-resolution-machine-fsm)
requires the request vocabulary to be open so that adding
`listxattr`/`getxattr` is not a breaking change. Whether OSTree-style identity
is ever a goal is undecided.
