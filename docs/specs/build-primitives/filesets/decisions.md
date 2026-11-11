# Fileset decisions & open questions

_Companion to [SPEC.md](./SPEC.md). Records consequential choices, the
alternatives rejected, and the questions still open. A decision here is
accepted unless marked **open**, or **proposed**, which awaits the owner._

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

With an unanchored pattern in the fileset, every directory is live, so this
reading alone reports every memberless leaf: `*.md` over a source tree would
report each directory without Markdown.
[D5](#d5-the-extent-of-the-empty-directory-report-accepted) limits the
report to directories whose whole content the fileset selects. For content
addressing the extent does not matter: a name holds only the directories on
the way to a member
([C3](../content-addressing/decisions.md#c3-memberless-directories-in-an-id-accepted)),
so the report never reaches an id.

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
A link whose one-name walk escapes its own directory is walked again by its
whole path from the fileset root, so `..` in its target is judged against
the root, not its parent ([D6](#d6-a-symlink-cycle-under-symlinks-beneath-accepted)).

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
`{` and `}` are escaped and stay literal. A bracket expression is read as
git's `wildmatch` reads it. A `]` that comes first is literal, `^` negates as
`!` does, and POSIX classes such as `[:digit:]` expand into the ASCII ranges
they name. An expression git cannot read, either unclosed or naming an
unknown class, makes the pattern match nothing, so the line is no rule. An
external review found that classes and a leading `]` had been passed
through unchanged.

Three more readings differ between the syntaxes, and a second review found
each. A trailing `/**` matches everything inside a directory but not the
directory itself, so `foo/**` then `!foo/keep.txt` keeps `foo/keep.txt`;
the fileset's `**` also matches no component, so the translation appends a
`*` component (`foo/**/*`, and `foo/**/*/` for `foo/**/`). Git decides
anchoring by looking for a `/` in the bytes of the pattern, so one inside a
bracket expression anchors it, and one there never matches, since wildmatch
keeps a bracket from matching `/`. The translation escapes such a `/`, so
the segment splitter no longer cuts the expression in two, and gives the
pattern a leading `/` to keep git's anchoring; the `/` in the `[:punct:]`
expansion is escaped too. `\/` matches `/` to git, so it becomes a
separator. Last, git skips a UTF-8 byte order mark before a file's first
line (`skipUtf8Bom`), which had made the first rule unmatchable. The review
noted that the tests for the earlier fix compared translations with
hand-written strings and matched no name. Every reading here is now checked
against git itself (`fileset.listing.FSI4.linesMatchGit`), which lists each
case's work tree with `git ls-files --others --exclude-standard`.

The rest of the syntax means the same in both: `*`, `?`, `**` elsewhere,
escapes, anchoring by a leading or middle `/`, and a trailing `/` for
directories.

**Matching is by NFC and code point, and git's by byte.** A rule is a fileset
pattern, and fileset patterns match names normalized to NFC, by code point
([A11](#a11-patterns-compile-one-component-at-a-time),
[`FSG3`](./SPEC.md#5-matching-fsg)). Git compares bytes, so two readings
differ. A literal rule written in NFC matches a name spelled in NFD, where
git's does not, and `?` or a bracket expression matches one non-ASCII code
point where git's matches one byte. Both differences need a non-ASCII name,
and the first also needs a `.gitignore` and a tree that spell the name in
two normalizations. That is what git's own `core.precomposeUnicode` exists to
paper over on macOS. Matching bytes would take a second matching mode in the
glob engine (`sparkles:fuzzy`), and a byte-matched pattern beside every
normalized one in the arena. The cost is out of proportion to the cases it
serves, so the difference is accepted and recorded here. **Revisit** if a
consumer meets it in a real tree.

The root `.gitignore` leaf of M1 had read lines with its own rules. It trimmed
trailing tabs, dropped the backslash of `\!`, which made the rule fail to
compile, and gave braces their fileset meaning. It now shares the reader.

A line git reads but no fileset pattern can express, such as one with a `.`
or `..` component, is skipped and counted (`IgnoreScopes.skippedRules`). It
is not an error, because a stray line in a vendored `.gitignore` must not
fail a resolution. Git never matches a `.` or `..` component against a
listed name, so skipping such a line changes no verdict. A rule over
[`FSG4`](./SPEC.md#5-matching-fsg)'s bounds is the one case where skipping
can change a verdict, and it is counted like the rest. Such a rule is
usually a glob with a long literal part, like `*-<sixty bytes>.json`. A
count nobody reads would hide that a listing holds a file git ignores, so a
sink with `ignoreRulesSkipped` receives it once the resolution is done.
`Listing.skippedIgnoreRules` carries it to applications, and
`Listing.caveat` words it for the user
([A23](#a23-a-listing-is-the-view-git-has-of-the-directory-it-names)).

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
fileset's is the one the site means. M9 reviewed each consumer's globs with this
record and closed it on 2026-11-09, when the last consumer was migrated and
the old walker, with the gate that ran it, was deleted.

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
roots by path, component by component, which keeps each directory's
descendants together, so these
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

### A19 — Content addressing is a family of schemes, with Snix castore as the default

_Was open as D1, "Which Merkle shape"; decided November 8, 2026._

**The default identity is Snix's
[castore](../../../research/content-addressing/tvix-castore.md).** A blob's
digest is BLAKE3 over its bytes, with no header. A directory's is BLAKE3 over
its canonical protobuf `Directory` message, which keeps directories, files and
links in three arrays, each sorted by name (`partitionedOrder`). Each entry
carries a size beside its digest: a file's length, and the number of entries
beneath a directory.

The other candidate was git's tree with SHA-256. Three reasons decided against
it:

- **iroh.** An iroh blob is named by plain BLAKE3 over its bytes, the same
  digest as a castore blob
  ([blobs](../../../research/iroh/blobs.md#hashseq-collections-and-the-hash-newtype)).
  Once the iroh port publishes filesets, git's shape would hash every file
  twice, with SHA-256 and with BLAKE3. The castore shape hashes it once.
- **The ordering hazard cannot arise.** Files and directories never compare
  against each other, so the `a` versus `a.b` case that git, irmin, Nix,
  Software Heritage and bup each had to handle does not exist.
- **BLAKE3 is a tree.** One large file can be hashed on several cores, and the
  same pass can produce the bao outboard that iroh serves, which is the
  supplied tree of `FSS8`.

Two costs are accepted:

- **Snix is not in nixpkgs.** The oracle comes from Snix's own repository,
  added to the dev shell; establishing it is M6's first task.
- **Canonicity rests on deterministic protobuf**, which Snix itself flags as a
  risk. The encoder is written by hand for the one message, and the oracle
  catches drift.

**Content addressing is generic.** A scheme is assembled from parts over the
seam (A18), each part a struct with required primitives and optional hooks, in
the [design-by-introspection](../../../guidelines/design-by-introspection-01-guidelines.md)
style:

| Part                     | Is                                   | Required                       | Optional hooks (and what their absence means)                                                          |
| ------------------------ | ------------------------------------ | ------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `MerkleFold!(Dir, Leaf)` | a fold scheme                        | a `Dir` and a `Leaf`           | `Supply`, trees supplied out of band (no `FSS8`; content-addressing C2)                                |
| `Dir`                    | the directory encoding               | `order`, `Id`, `entry`, `seal` | `keepEmpty` (dropped), `metadata` (none), `embed` (raw digest bytes), `shard` (one object)             |
| `Leaf`                   | a file's identity, as a byte sink    | `start(size)`, `put`, `finish` | `blockSize` and `hashBlock` (serial)                                                                   |
| `BlockTree!(H, P)`       | a binary tree over fixed blocks      | `blockSize`                    | `leafPrefix`/`nodePrefix` (no domain separation), `pad` (RFC 6962's split), `finalize` (the bare root) |
| `Serial!(Format, H)`     | a stream scheme over one byte stream | the format's framing           | —                                                                                                      |
| `Tee!(S...)`             | several schemes on one walk          | —                              | —                                                                                                      |

`Tee` declares the union of its parts' metadata and one order, re-sorts a
directory's entries for a part that declared another, and reads each file
once, feeding every part's leaf. A directory's id is the format's own type,
not a digest: castore and REAPI carry a size, OSTree a pair of digests, a CID
its codec.

**Instances are built only with an oracle,** and the dev shell may gain any
nixpkgs package to supply one:

| Instance                           | Use                                          | Oracle                   |
| ---------------------------------- | -------------------------------------------- | ------------------------ |
| castore, BLAKE3                    | the default identity                         | Snix                     |
| NAR, SHA-256                       | the Nix boundary (D2)                        | `nix hash path`          |
| git tree, SHA-1 and SHA-256        | git interoperability; the D1 spike           | `git write-tree`         |
| iroh `Collection` and bao outboard | publishing a fileset to iroh                 | `b3sum`, `bao`, `sendme` |
| fs-verity                          | the instance that checks `BlockTree`'s hooks | `fsverity digest`        |

A `Collection` is flat, its names relative paths, so it is a stream scheme over
castore's leaves rather than a fold. REAPI, IPFS unixfs, BitTorrent v2, OSTree
and casync wait for a consumer; each fits the parts above. Tahoe-LAFS, SSZ and
hypercore do not name file system trees by their bytes, and stay out of scope.

**Two changes to the seam.** A serial format writes a directory's later
entries after the whole subtree of an earlier one. A stream already sees
directories depth first, subdirectories in byte order, which is NAR's; what
it lacked was hearing where a subtree ends while the directory holding it can
still be read. A stream that declares `leave(path, ref exec)` now hears it
(`StepKind.leave`), and the references its `visit` was given for that
directory stay valid until then: the driver retires a directory only after
its subtree, so this costs no descriptor. A fold may not declare it. Start
roots are sorted by path component instead of by bytes, so `a/b` comes
before `a-c`, as the directory `a` does in NAR; that still keeps each
directory's descendants together. The other change is still possible, not
made: OSTree's identity needs a file's owner, which arrives in the `statx`
already issued, so `FsoMetadata` can admit `owner` as cheaply as it admitted
`mtime`.

**The spike.** `GitTreeFold`, a test-only fold over the seam, computed git's
tree hash in about 130 lines with SHA-1 from Phobos, the `gitTreeOrder` of
`FSS1`, and the `executable` and `linkTarget` metadata, allocating nothing
while hashing. On 207 trees (hand-written ones aimed at the hazard, M1's
fixture set, and 200 seeded random trees with links, executables and empty
directories), it matched `git add -A -f` followed by `git write-tree`. Sorted
by bytes instead, the same fold differed on 95 of them. It showed that an
empty directory has no git identity, while castore keeps one, and that the
hazard lives only in `precedes`. It is now `GitTree`, the git instance of
`MerkleFold`, and its test is `content_addressing.git.writeTree`.

**As built.** `MerkleFold` reads each file through its entry's reference
during `fold`, at its `stat`-ed size, and fails rather than name a file whose
size changed while it was read. BLAKE3 is `sparkles.base.hash.blake3`, native
D with SIMD backends, so no C library joins the build. The castore id matches
`snix-castore ingest` on the first run, on every oracle tree: empty
directories, links, executables, nested sizes and a case collision included
(`content_addressing.castore.snix`). Snix comes from its own repository as
the flake input `snix-src`, built with our nixpkgs' Rust; the shells
export it as `$SPARKLES_SNIX_CASTORE`, in the CI tier, because without it the
gate of the default identity would degrade to a skip.

`Serial!(Format, H)` is not built: NAR is the one serial format with a
consumer, so it is `NarScheme!(H, Ref)`, a stream declaring `leave`, and the
generic part waits for a second one (casync's `catar`). Its result is
`NarHash`, the digest and the length together. It keeps a directory's
entries after its first subdirectory, with their references, which is why
it is parameterized on the reference type. It writes the directories above
the start roots itself, and the empty directory for a fileset holding
nothing. `content_addressing.nar.dump` compares its digest and length with
those of `nix-store --dump` on every oracle tree, and
`content_addressing.nar.startRoots` with start roots beneath the root.

`Tee!(S...)` is not built as a general product of schemes either, for the
same reason: the one combination with a consumer is the identity and its
`NarHash` (D2). The NAR stream takes the Merkle directory encodings as
parts instead: `NarScheme!(H, Ref, Dirs)` reads each file once, feeding the
NAR and every `Dir`'s leaf, keeps a file's leaf ids and a subdirectory's ids
in the entry it already kept, and encodes each directory when it closes,
re-sorting its entries from NAR's byte order into the `Dir`'s own. A part
is an encoding, not a fold: `leave` already gives the post-order a fold
needs. `CastoreNar` is castore with NAR by SHA-256.
`content_addressing.tee.parts` checks a tee
of castore and git against each scheme alone on every oracle tree,
`content_addressing.tee.startRoots` with start roots beneath the root and a
root that is a file, and `content_addressing.tee.readsOnce` counts what the
leaf hears: each file once, each byte once.

### A20 — The subtree cache, as built

M7 delivers [`FSC1`–`FSC6`](./SPEC.md#12-the-subtree-cache-fsc) under
[A9](#a9-incremental-invalidation-stops-at-level-2). The requirements leave
the following choices open.

- **The cache is a fold's part, not the machine's.** `MerkleFold` takes a
  fourth parameter, `Cache`, as it takes `Supply`, and `CachedFold` names
  the result. The machine is unchanged apart from the fingerprint it
  forwards. It still lists every directory and stats every member, because
  without a watcher nothing else can tell it that a directory is unchanged.
  The cache saves file reads and directory encodings. A serial scheme such
  as NAR has no subtree ids to cache, as the research found for git's
  `cache-tree`.
- **One record per directory, keyed by its path.** A record holds the
  directory's id and each entry the fold encoded: a file's id, size,
  executable bit and fingerprint, a link's target, and a subdirectory's id.
  A directory whose entries all match is reused without being encoded. The
  match compares a subdirectory by its id, so a change deep in the tree
  invalidates exactly its path, as git's `cache-tree` invalidates every
  parent of a changed path. A directory that does not match still reuses
  each file its validator accepts. An entry's record is found by walking
  the recorded entries in the scheme's order alongside the listing.
- **The fingerprint adds the change time to the cache's key.**
  `FsoFingerprint` is the size, both times, the device and the inode, all
  from the one `stat` the fold already needed for the executable bit. The
  change time came from the VFS for this use
  ([DV32](../../base/vfs/decisions.md#dv32-the-change-time)). Without it, a
  rewrite whose modification time was put back would be a false
  "unchanged", which is
  [`ccache`'s class of hole](../../../research/content-addressing/build-input-caches.md).
  On Windows a caller can set `ChangeTime` as well, so the NT backend
  reports it as `ctimeSettable`. The machine then gives such a file no
  fingerprint, so on Windows the cache is correct but reads every file
  again.
- **The stamp rule is racy-git's, against a caller's stamp.** `begin` takes
  a stamp no later than the run's first `stat`, and the next run trusts a
  file only if its recorded change time is more than `marginNs` older than
  that stamp. The margin defaults to two seconds, which covers the coarse
  clock's lag and FAT's two-second modification times. The library cannot
  read a clock (invariant 1), so the caller supplies the stamp. On a local
  file system the current time serves. On a remote one whose clock may
  differ, a file just written there supplies its change time, which is how
  git dates its index file.
- **The validator is a parameter.** `StatValidator` is the default. The
  oracle substitutes validators that lie, and M7's gate requires that each
  makes the oracle fail: trusting everything, ignoring the change time, and
  dropping the stamp rule.
- **The stored form is the records' bytes, checksummed.** A header holds
  the format version, the record sizes, a digest of the encoding's and the
  identity's type names, and a canary. The directories follow in path
  order, so `load` can bisect, then the entries and the names, then a BLAKE3
  digest of everything before it. Any mismatch rejects the whole cache.
  The canary is the ids that the scheme gives a fixed small tree. A cache
  recorded under an encoding that has since changed, with its type names
  unchanged, fails the canary rather than reusing ids the new encoding
  would not give. The records are host-endian, since a cache belongs to
  one checkout on one machine.
- **Nothing consumes it yet.** The build graph's planning reads
  ([D44](../build-graph/decisions.md#d44-the-build-graph-reaches-files-through-the-vfs-accepted))
  are the intended consumer. Where the cache's bytes live, such as one file
  per checkout under the build directory, is that consumer's decision.

### A21 — What a step's budget counts

[`FSM6`](./SPEC.md#7-the-resolution-machine-fsm) said that a step performs
work bounded by its budget. As built, the budget counts entries evaluated
against the fileset. A step also begins by absorbing the batch it was given:
it sorts a listing and issues the next requests, and that work is
proportional to the directory, not to the budget. An external review found
the mismatch. The amendment states what is counted, and leaves absorption to
[`FSM7`](./SPEC.md#7-the-resolution-machine-fsm)'s limits on entries and
pending requests, which already bound it. Making absorption resumable would
bound a step by the budget alone, at the cost of a cursor inside the sort.
No consumer steps with a budget small enough to need that.

### A22 — A batch is split at its size, and shared by the workers that can run

[`FSM3`](./SPEC.md#7-the-resolution-machine-fsm) asked for one batch per
directory, and `ResolutionLimits.maxPending` (4096) bounded a batch. A
directory needing more stats than that failed the whole resolution with
`tooManyPending`. Every file needs a stat when `executable` is asked for, or
when the subtree cache ([A20](#a20-the-subtree-cache-as-built)) is on, so a
directory of more than 4096 files could not be resolved at all. The
amendment splits such a directory's stats, and its subdirectories'
listings, into consecutive batches of `maxPending`, and removes the error.
A batch's size now bounds only the storage its requests take. A
subdirectory's listing is tagged with its rank among its parent's
subdirectories, not with its request's index, so the listings of several
batches sort together.

`LoopExecutor` ran a batch on one fiber per request. The scheduler's fiber
slab holds 256 by default, so beyond that every request ran on the resolving
fiber, one at a time, while the budget still had room. The executor now asks
the budget for its capacity, and the scheduler for its free fibers when it
can tell, and starts as many workers as the smaller of the two and the
batch. Each worker takes the next request until none is left.

The default batch size stays 4096, because no larger one measured faster. A
resolution of `executable`, which stats every file, was timed with a warm
cache on Linux x86_64 (a 32-thread host, tmpfs and ZFS), as the median of
31 interleaved runs:

| Tree                    | Executor                  | 2048     | 4096     | 8192     | 16384    |
| ----------------------- | ------------------------- | -------- | -------- | -------- | -------- |
| 20,000 files, one dir   | inline, `BlockingVfs`     | 41.1 ms  | 40.3 ms  | 40.1 ms  | 39.9 ms  |
| 20,000 files, one dir   | `LoopExecutor`, budget 32 | 192.2 ms | 192.7 ms | 193.7 ms | 192.6 ms |
| this repository (5,251) | inline, `BlockingVfs`     | 34.2 ms  | 34.5 ms  | 34.1 ms  | 34.1 ms  |
| this repository (5,251) | `LoopExecutor`, budget 32 | 79.9 ms  | 80.4 ms  | 80.5 ms  | 80.5 ms  |

The differences are within the runs' spread. Below 1024 a batch costs more:
64 took 88 ms inline on the flat tree. 65,536 cost 49 ms there, a larger
working set for no fewer round trips. A request costs 51 bytes of storage,
so 4096 takes about 200 KiB per resolution. The workers made the flat tree
at budget 32 faster: 189 ms, where one fiber per request took 303 ms.

The event loop is slower than the inline executor on a warm cache, by 2.3×
on the repository and 4.8× on the flat tree. Only about 2 ms of that is the
loop's setup. The rest is each stat's trip through the blocking pool, which
pays off only where a stat waits on the device. Choosing the executor by
how warm the cache is lies outside this decision.

**Revisit when** a backend submits a batch as one `io_uring_enter`, which
would make a batch's size matter.

### A23 — A listing is the view git has of the directory it names

`listRepository` serves applications that show a user the files of a
directory, and the old walker it replaced listed what git lists. A review
found four ways the listing fell short of that.

- **The directory is taken by its real path.** The repository root was found
  from the lexical path, so a link to a directory inside a repository named
  an entry the walk would not follow (`FSD6`), and the listing came back
  empty with only an `unreadable` line, which no consumer read. The path is
  now resolved first (`realpath`). A link lists the directory it names,
  beneath the `.gitignore` files above that directory, wherever the link
  lies (`fileset.listing.listRepository.linkedDirectory`). On Windows the
  path stays lexical.
- **A directory that cannot be read is an error.** When the start root
  itself is incomplete ([`FSE2`](./SPEC.md#10-errors-and-partial-results-fse)),
  the listing fails, because an empty listing would look like an empty
  directory (`fileset.listing.listRepository.unreadableDirectory`).
- **No `.git` is listed, at any depth.** `workTree` excluded only the
  repository's own `/.git`, so a nested repository's `.git/*` was listed. Git
  never lists a `.git` entry or anything beneath one, so `workTree` and
  `withGlobs` exclude `.git` wherever it is. Git lists a nested repository as
  one entry, `sub/`. A listing of files has no such entry, so it lists the
  nested work tree's files, read under the outer repository's
  `.gitignore` files (`fileset.listing.nestedRepository`).
- **What did not apply is said.** `Listing.skippedIgnoreRules` counts the
  `.gitignore` lines no fileset pattern expresses
  ([A15](#a15-a-gitignore-line-is-read-as-git-reads-it)). `Listing.caveat`
  words that count, and the unreadable entries, for a user, and hue's
  pickers, its site, and the docs source set log it as a warning.

The listing's own loop can also fail after the resolution began. The inline
fallback then appended to the sink the loop had half filled. Now a
resolution the loop finished is kept even if the loop fails afterwards; one
it never began is made again, inline, into a fresh sink; and one it began
and did not finish is an error (`fileset.listing.settle`).

### D5 — The extent of the empty-directory report (accepted)

**Question.** [`FSV4`](./SPEC.md#4-the-fileset-value-fsv) reports every
memberless leaf the walk listed ([A13](#a13-an-empty-directory-is-a-memberless-leaf-of-the-walk)).
An unanchored pattern makes the walk list every directory, so `*.md` over a
source tree reports each directory that holds no Markdown. Which directories
should the report hold?

**Alternatives.**

- **Every memberless leaf, as now.** Nothing is lost, and the report is
  decided from each listing alone. For an unanchored pattern it is mostly
  noise, and a consumer that copies the selection creates a skeleton of the
  whole tree.
- **Only beneath an `acceptAll` verdict.** A directory is reported when
  the plan selects everything beneath it, as `src/**` or the literal root
  `src` do. There the fileset asked for the directory's whole content, so
  its emptiness is part of what was selected; under `*.md` it is not. The
  verdict is already known when the directory is listed, so the cost stays
  one test per directory.
- **Everything, each marked with its verdict.** The consumer filters. This
  moves the question to every consumer instead of answering it once.

**Decision.** Only beneath an `acceptAll` verdict, accepted 2026-11-10. It is
the one reading under which "the selection has this empty directory" is
true, it matches what a copy of `src/**` is expected to keep, and it makes
the report independent of how the fileset was spelled, as
[C3](../content-addressing/decisions.md#c3-memberless-directories-in-an-id-accepted)
made ids. The build graph's listings, the first consumer, do not read the
report, so nothing depended on the earlier extent.

**As built.** The verdict is judged with each difference's excluded side set
aside: a directory is reported when its listing holds no member and no
entered subdirectory, and the fileset with every difference replaced by its
left operand gives it `acceptAll`. Read literally, the work tree,
`everything - gitignored - /.git`, would report nothing, because a deeper
`.gitignore` may still exclude a file and so no directory of it is ever
`acceptAll`. An exclusion narrows what was selected; it does not turn the
selection into a search the way `*.md` is one, so a directory holding only
ignored files is reported, as `tree --gitignore` shows it. The evaluator
computes the second verdict in the pass that computes the first
(`FilesetEvaluator.wholeContent`), and a directory inherits it from its
parent. A directory above the start roots is never reported: a plan starts
beneath one only when the fileset does not select it whole.

**Revisit** if a consumer needs the skeleton of directories a pattern
searched, which would be a separate report, not this one.

### D6 — A symlink cycle under `symlinks = beneath` (accepted)

**Question.** With [`FSD6`](./SPEC.md#11-drivers-fsd)'s `symlinks = beneath`,
a link to a directory inside the root is walked as that directory. A link to
an ancestor, `a/up -> ..`, makes the walk descend until
[`FSM7`](./SPEC.md#7-the-resolution-machine-fsm)'s depth bound, and the
whole resolution fails with `depthExceeded`. Should a cycle fail the
resolution, or be one incomplete entry?

**Alternatives.**

- **Fail at the bound, as now.** No new mechanism, and no cycle can go
  unnoticed. One link anywhere in the tree fails every fileset over it, after
  up to 64 levels of work, and the error names the depth, not the link.
- **Report the link as an incomplete entry.** Before entering a linked
  directory, compare its identity with the directories on the current path;
  a match is reported per entry, as an escape from the root already is
  (`unreadable`, with a `cycle` kind), and the walk goes on. A scheme still
  fails on it, since an incomplete tree has no id
  ([`FSE1`](./SPEC.md#10-errors-and-partial-results-fse)), but a listing
  completes. This needs a file's identity, its inode beside the device that
  `Stat` already carries: a change to the capability VFS, whose backends
  all have one to give.
- **Never walk a linked directory twice.** Treat any directory already
  visited, not only an ancestor, as a repeat. That also drops a second link
  to the same directory, which is not a cycle and whose files are members
  under both names.

**Decision.** Report the link as an incomplete entry, compared against the
ancestors only, accepted 2026-11-10. It matches how the walk already treats
a link that escapes the root, it names the offending link, and it costs one
comparison per ancestor when a link is followed, with the depth bound still
in place behind it. The VFS change is the cost, and it went through that
contract's own decisions
([DV31](../../base/vfs/decisions.md#dv31-a-file-s-identity-and-a-directory-s-own-stat)).

**As built.** The capability VFS gained what
[`VFO6`](../../base/vfs/SPEC.md#vfo6-stat) already specified and its plan
had left for later: `StatMask.identity` fills `Stat.inode` (the inode on
POSIX, the file index on Windows, a node's index on `MemVfs`), and a `Dir`
gained `stat` of the directory it holds. Under `symlinks = beneath` each
`readDir` asks for the opened directory's identity, one `fstat` per
directory; without links followed nothing is asked, since no directory can
then repeat. A directory reached through a link, directly or below one, is
compared with the directories above it, and a match fails it with the
existing `symlinkLoop` kind rather than a new one: `ErrorKind` is the I/O
vocabulary every backend shares, and the kind already names a loop of links.

The question's example was right after all, once links that climb are
handled. The driver opens each directory with a `walk` of one name from its
parent's handle, so a `..` in a target leaves that handle and fails with
`escapesRoot`. For a link, the driver then walks the link's whole path from
the fileset root, so a target that climbs out of its own directory but stays
beneath the root resolves (`FSD6`). `a/up -> ..` then reaches the root
itself and is the cycle reported, as is `self -> .`, a link to its own
directory, reached directly or through another link to that directory
(`fileset.driver.FSD6.climbingLinkInsideRoot`, `fileset.driver.FSD6.cycle`).
An external review found that the first version refused every climbing
link, which `FSD6` and the build graph's committed relative links do not
allow.

**Revisit** if a consumer wants cycles to be a hard error: it can still
refuse a resolution with any incomplete entry.

## Open

### D2 — Whether `NarHash` is stored or recomputed (resolved)

Moved to the content-addressing contract as
[C1](../content-addressing/decisions.md#c1-narhash-is-stored-beside-the-identity-accepted),
which stores it.

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
