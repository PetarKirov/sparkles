# ccache & sccache — hashing build inputs

The subject that inverts the survey: every other system digests a tree in order
to **name** it, while a compiler cache digests a hand-picked bag of inputs in
order to **predict** an output — and ships the approximation as documented,
user-facing configuration.

|                    |                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------- |
| **Ecosystem**      | C/C++/Rust build caching — `ccache`, `sccache`, and the wrappers around them (`distcc`) |
| **What is hashed** | compiler identity + `argv` + source bytes (preprocessed, or raw plus a header manifest) |
| **Level 1**        | **none** — no directory tree, no subtree digests, no entry ordering                     |
| **Level 2**        | whole file, always; no chunking                                                         |
| **Digest**         | BLAKE3 (ccache: 160 bit in direct mode); XXH3 checksums guard stored entries            |
| **Documentation**  | [`doc/manual.adoc`][manual], [sccache `docs/Caching.md`][sccache-caching]               |

## Overview

### What it solves

Avoiding a compiler invocation whose result is already known. The unit is one
translation unit, not a tree, and the question is not "what is this tree
called?" but "will this compiler, on these bytes, with these flags, produce
what it produced last time?" ([`doc/manual.adoc`][manual]):

> Ccache detects when you're compiling the same code and reuses previously
> stored output. It works by creating a unique hash (the "input hash") from
> various information that affects the compilation. When the same hash is
> encountered again, ccache can supply all the correct compiler outputs from
> the cache.

sccache states the same shape and is explicit that the hash is an assembled
approximation rather than a derived identity
([`docs/Caching.md`][sccache-caching]):

> To know if the storage contains the artifact we need, we are computing some
> hashes to make sure the input is the same.
>
> Because the configuration and environment matter, the hash computation takes
> a few parameters into account.

"A few parameters" is the whole finding. The set is enumerated by hand, in
code, and it is not the set of bytes the compiler reads.

### Design philosophy

The default is conservatism, and the relaxations are named, listed and
owned by the user rather than hidden ([`doc/manual.adoc`][manual]):

> By default, ccache tries to give as few false cache hits as possible.
> However, in certain situations it's possible that you know things that ccache
> can't take for granted. This option makes it possible to tell ccache to relax
> some checks in order to increase the hit rate.

That sentence has no analogue anywhere else in this survey. [NAR][nar],
[git][git], [OSTree][ostree] and [REAPI][reapi] have no knob that trades
correctness for speed, because there is nothing to trade: a content address
either names the bytes or is wrong. A cache key has a second failure mode —
being _too precise_ — and so it has a tuning surface.

LLVM's CAS library draws the same line architecturally, separating the store
that names objects from the table that remembers a computation
([`llvm/docs/ContentAddressableStorage.md`][llvm-cas]):

> `ActionCache` is a key value storage can be used to associate two CASIDs. It
> is usually used with an `ObjectStore` to map an input CASObject to an output
> CASObject with their CASIDs.

The `ObjectStore` is the content-addressing layer; the `ActionCache` is the
prediction layer. ccache and sccache are an `ActionCache` whose keys were never
CASIDs to begin with.

## How it works

ccache has three strategies, and which one runs decides what is hashed.

```text
preprocessor mode:  hash(common ‖ `cc -E` output ‖ argv minus -I/-D/-include ‖ cpp stderr)
                      -> result

direct mode:        hash(common ‖ source bytes ‖ argv)
                      -> manifest -> [(header path, header hash)] -> result

depend mode:        direct-mode hash ‖ headers read from the -MD/-MMD/`/showIncludes` depfile
                      -> result
```

The **common** part is the same in all three ([`doc/manual.adoc`][manual]): the
preprocessed-output extension (`.i`/`.ii`), the compiler's size and mtime (or
whatever [`compiler_check`](#the-compiler-identity-problem) selects), the
compiler's name, the current directory when `hash_dir` is enabled, and the
contents of any `extra_files_to_hash`.

Direct mode is a **two-step lookup**, and the manifest is the only structured
object in the design:

> Based on the hash, a data structure called "manifest" is looked up in the
> cache. The manifest contains:
>
> - references to cached compilation results (object file, dependency file,
>   etc) that were produced by previous compilations that matched the hash
> - paths to the include files that were read at the time the compilation
>   results were stored in the cache
> - hash sums of the include files at the time the compilation results were
>   stored in the cache

Preprocessor mode needs no manifest because `cc -E` has already inlined every
header into the bytes being hashed — it pays a preprocessor run to buy a
one-step lookup. Direct mode skips the preprocessor and must therefore keep its
own record of which headers were read, plus their digests, and re-hash them on
every lookup. sccache implements the same idea one layer up, caching the
_preprocessor result_ keyed on the source and the preprocessor arguments
([`docs/Architecture.md`][sccache-arch]):

> Before computing the object-cache key, sccache looks up a **preprocessor
> cache entry** keyed on the source file (path + contents) and the preprocessor
> arguments. That entry records every file included by the source. If the entry
> exists and all of those included files are unchanged, sccache reuses it and
> never runs the preprocessor; otherwise it preprocesses normally and stores a
> fresh entry.

### The direct-mode hole

The manifest records the headers that _were_ read. It cannot record the headers
that _would_ have been read had they existed — a new `foo.h` earlier on the
`-I` path silently shadows the one that was hashed:

> There is a catch with the direct mode: header files that were used by the
> compiler are recorded, but header files that were **not** used, but would
> have been used if they existed, are not. To mitigate this problem, ccache
> records whether directories specified with `-I` and similar exist at the time
> of compilation, which handles most cases. Still, when ccache checks if a
> result can be taken from the cache, it currently can't check with 100%
> accuracy if the existence of a new header file should invalidate the result.
> In practice, the direct mode is safe to use in the absolute majority of
> cases.

The manual repeats this as the sole entry under its `Caveats` heading. It is a
**false "unchanged"** — precisely the failure mode [git's `cache-tree` and
racy-git][cache-tree] treatment exists to make impossible — accepted here
because the cost of closing it (enumerating the non-existence of every file on
every include path) exceeds the value of the cache.

### The compiler identity problem

The compiler is an input the cache cannot hash cheaply and cannot skip safely,
so `compiler_check` exposes the whole ladder: `mtime` (the default — mtime and
size, fast), `content` (hash the binary, "very slightly slower ... but makes it
cope better with compiler upgrades during a build bootstrapping process"),
`string:value` (a caller-supplied revision identifier), an arbitrary command
whose stdout and stderr are hashed (`%compiler% -dumpmachine; %compiler%
-dumpversion`), and `none`:

> Don't hash anything. This may be good for situations where you can safely use
> the cached results even though the compiler's mtime or size has changed [...]
> You should only use **none** if you know what you are doing.

The default is the _weakest_ of the sound options, because hashing a
multi-hundred-megabyte binary on every invocation is not free. The manual also
names the wrapper trap: when `ccache anotherwrapper compiler args` is used,
`mtime` hashes the wrapper, so "Compiler upgrades will not be detected
properly."

sccache resolves the same problem further up the precision scale, and for Rust
reaches past the binary into its runtime closure
([`docs/Caching.md`][sccache-caching]): the path to `rustc`, its host triple,
its sysroot path, and "digests of all the shared libraries in rustc's
`$sysroot/lib`". For C/C++ it hashes the compiler binary, and — unlike ccache —
also "Hash of the assembler binary the compiler hands the compilation off to,
and the version it reports, when there is one", plus environment variables.

### Paths, which are inputs the output remembers

An absolute path is not part of the semantics of a compilation but is
frequently part of its output: `__FILE__`, `DW_AT_comp_dir` in debug info,
`.gcno` coverage files. ccache's `hash_dir` therefore includes the working
directory in the hash by default —

> The reason for including the CWD in the hash by default is to prevent a
> problem with the storage of the current working directory in the debug info
> of an object file, which can lead ccache to return a cached object file that
> has the working directory in the debug info set incorrectly.

— and `base_dir` rewrites absolute paths under a given prefix to relative ones
before they reach the compiler _or_ the hash, so two checkouts share hits. The
manual is candid about what that costs:

> WARNING: Rewriting absolute paths to relative is kind of a brittle hack. It
> works OK in many cases, but there might be cases where things break. One
> known issue is that absolute paths are not reproduced in dependency files,
> which can mess up dependency detection in tools like Make and Ninja. If
> possible, use relative paths in the first place instead of using `base_dir`.

sccache's `SCCACHE_BASEDIRS` is the same lever with a sharper rule
([`README.md`][sccache-readme]): "By default, sccache requires absolute paths
to match for cache hits", and stripping applies "from the preprocessed source
and from the compiler arguments alike", but only at positions that can
plausibly spell a pathname and only on whole path components — so
`-DROOT="/home/user/project"`, which the compiler bakes into the output
verbatim, is deliberately left alone.

### The race that makes a key wrong before it is used

Both a source file and the key derived from it are read at different instants.
ccache disables caching outright when a source or include file's mtime or ctime
is not older than the invocation, and spells out why:

> 1. A source code file is read by ccache and added to the input hash.
> 2. The source code file is modified.
> 3. The compiler is executed and reads the modified source code.
> 4. Ccache stores the compiler output in the cache associated with the
>    incorrect key (based on the unmodified source code).

This is [racy-git][cache-tree] with the arrow reversed. Git's index risks
reading a _stale_ digest for a file that changed inside the timestamp tick;
ccache risks _writing_ a fresh key for content the compiler never saw. Both
mitigations are the same shape — distrust the ambiguous window — and both are
opt-out-able, here via the `include_file_ctime` / `include_file_mtime`
sloppiness values.

## The six dimensions, mostly as absences

The spine this survey applies to every subject does not fit, and the way it
fails to fit is the result. Five of six dimensions are genuine absences.

### Dimension 1 — node model

**Absent.** There is no file system object model: no directories, no symlinks,
no mode bits. A header's executable bit, its ownership, its being a symlink
into another tree — none of it is hashed, because none of it changes what the
compiler emits. Directories enter only as an _existence_ predicate (ccache
"records whether directories specified with `-I` and similar exist"), which is
the weakest possible statement about a directory a system can make.

The closest thing to a node is a **manifest entry**: a pair of `(include path,
digest)`. That is a node model with exactly one field — enough to answer
"changed?", not enough to answer "what is this?". Set beside [REAPI's][reapi]
`FileNode` with `is_executable` and open `NodeProperties`, the contrast is the
whole difference between naming an input tree and predicting an output.

### Dimension 2 — canonical form and ordering

**Absent, and replaced by two lossy normalizations.** There is no set of
sibling entries, therefore no ordering question, therefore no
[case-collision][concepts] question either. What exists instead is
canonicalization of _inputs_:

- **path canonicalization** — `base_dir` / `SCCACHE_BASEDIRS`, applied because
  two semantically identical builds differ textually;
- **argument canonicalization** — `ignore_options`, a glob list whose entries
  "will neither be interpreted specially nor be part of the input hash", and
  `keep_comments_cpp`, which is `false` by default so comments are discarded
  from preprocessor output before hashing.

Both are _user-declared equivalences_: the tool is told that two different
byte-strings mean the same compilation. A canonical form in the
[concepts][concepts] sense is derived from the data; these are asserted about
it.

The only published description of the actual hashed byte-stream is a debugging
artifact — `<objectfile>.<timestamp>.ccache-input-c`, `-input-d`, `-input-p`,
and a human-readable `-input-text` combining them, emitted at `debug_level` 2
with the sections `COMMON`, `DIRECT MODE` and `PREPROCESSOR MODE`. The
recommended workflow for an unexpected miss is to diff two of these files.
That is the honest admission: **the canonical form is whatever the program
fed the hasher**, and the remedy for disagreement is a diff, not a spec.

### Dimension 3 — level-1 composition

**Absent.** A flat concatenation into a single hash. No subtree digests, hence
none of what [the index's composition table][index] attributes to a Merkle
DAG: no reuse of a subtree value, no `O(depth)` rehash, no object-granular
verification. In this respect a compiler cache sits alongside [NAR][nar], for
the same reason — the digest is consumed whole, so structure would buy nothing.

Direct mode re-introduces **exactly one** level of indirection, and it is worth
being precise about what kind: `input hash -> manifest -> (header digests) ->
result`. That is an indirection built for **invalidation**, not for naming.
Compare [`cache-tree`][cache-tree], which caches subtree OIDs that are
independently meaningful and is "an optimization, never an authority" — a lost
`cache-tree` node costs time. A lost ccache manifest costs the hit; a _wrong_
ccache manifest costs correctness, because the manifest **is** the authority
for a direct-mode hit. The two structures look alike and have opposite failure
modes.

### Dimension 4 — level-2 granularity

**Whole file, always.** No chunking, no intra-file Merkle tree, nothing
resembling [Bao][bao] or [REAPI's `SHA256TREE`][reapi] — inputs are source
files and headers, small enough that chunk-level verification and partial fetch
would be pure overhead.

The one refinement is a memo rather than a structure: ccache's `inode_cache`
"will cache source file hashes based on device, inode and timestamps", reducing
"the time spent on hashing include files since the result can be reused between
compilations". This is [git's stat cache][cache-tree] rebuilt for a different
consumer, and it carries the same staleness obligation, which is why it needs a
local filesystem of a supported type.

### Dimension 5 — digest

**BLAKE3**, in both tools; ccache takes "the 160 bit BLAKE3 hash" of the
concatenated common plus mode-specific input, and separately protects stored
data with XXH3 checksums "to detect corruption". Note that the two hashes have
different jobs: BLAKE3 forms the key, XXH3 guards the value.

The digest is also **not a name**. It is never exchanged, never published, and
never claims to identify the bytes it was computed from — and ccache's
`namespace` option proves it, adding "the namespace string [...] to the hashed
data for each compilation" purely so that one user can partition one cache
across unrelated projects. A content address with a user-chosen salt would be a
contradiction; a cache key with one is a feature.

### Dimension 6 — partial verification

**Absent, and structurally impossible.** There is nothing to verify against: a
key names a _prediction_, and no amount of the prediction can be checked
against a part of the input. What stands in its place is **integrity**
checking — the XXH3 checksums detect a corrupted stored result — which catches
a damaged entry and cannot catch an intact but wrong one. A false hit is
undetectable by construction, which is exactly why the false-hit hazards below
must be managed at key-derivation time or not at all.

## What is hashed, what is skipped, and the hazard

| Mode              | Hashed                                                                                      | Not hashed                                                         | Hazard                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Common (all)      | compiler name, size + mtime, `.i`/`.ii` extension, CWD if `hash_dir`, `extra_files_to_hash` | compiler _contents_ by default; linked libraries; wrapper identity | A rebuilt-but-identical compiler misses; a changed wrapper's compiler is missed |
| Preprocessor      | `cc -E` output, `argv` minus `-I`/`-D`/`-include`, preprocessor stderr                      | comments (`keep_comments_cpp` is `false`); header _paths_ as such  | `-Wdocumentation` results differ without the opt-in; slow (a preprocessor run)  |
| Direct            | raw source bytes, full `argv`, then manifest-recorded header paths + digests                | headers that do not exist yet but would shadow one that does       | **False hit**: a newly added header on the `-I` path is invisible               |
| Direct (excluded) | —                                                                                           | anything in `ignore_headers_in_manifest`                           | Documented: "this can cause stale cache hits if those headers do indeed change" |
| Depend            | direct-mode hash plus headers from the `-MD`/`-MMD` / `/showIncludes` depfile               | with `-MMD`, system headers entirely                               | "ccache will ignore changes in them"; lower hit rate, no preprocessor fallback  |
| Time/identity     | —                                                                                           | `__DATE__`, `__TIME__`, `__TIMESTAMP__` under `time_macros`        | Cached output carries the _recording_ time, not the build time                  |
| Paths             | absolute paths, unless rewritten by `base_dir` / `SCCACHE_BASEDIRS`                         | the rewritten prefix, deliberately                                 | `__FILE__`, `DW_AT_comp_dir` and `.gcno` paths can be wrong on a hit            |

`__TIME__` is handled by refusal rather than relaxation: direct mode is
**disabled outright** when "the string `__TIME__` is present in the source
code".

### `sloppiness` — the relaxation list, as documented

The most unusual artifact in this subject. Every entry is a correctness
guarantee the user may surrender in writing, and each ships with its own stated
trade-off ([`doc/manual.adoc`][manual]):

| Value                     | Effect                                                               | Documented trade-off                                                               |
| ------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `clang_index_store`       | Ignores `-index-store-path` / `-index-unit-output-path` when hashing | "Index won't update correctly on cache hits."                                      |
| `file_stat_matches`       | "Uses file timestamps instead of content for cache validation."      | "May miss content changes with identical timestamps."                              |
| `file_stat_matches_ctime` | Ignores ctime when `file_stat_matches` is enabled                    | "May miss some file system changes."                                               |
| `gcno_cwd`                | Ignores the CWD when creating `.gcno` files                          | "Directory information in coverage files may be incorrect."                        |
| `incbin`                  | Allows caching files with `.incbin` directives                       | "Won't detect changes to included binary files."                                   |
| `include_file_ctime`      | Ignores ctime when checking for recent modifications                 | "May miss recent changes to source files."                                         |
| `include_file_mtime`      | Ignores mtime when checking for recent changes                       | "May miss recent modifications to source files."                                   |
| `ivfsoverlay`             | Ignores the `-ivfsoverlay` virtual filesystem option                 | "May not detect VFS-related changes."                                              |
| `locale`                  | Ignores `LANG`, `LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`                  | "Compiler warning messages may vary between cached and fresh builds."              |
| `modules`                 | Allows caching when C++ modules are used                             | "May not detect changes in module internal state, or in implicitly built modules." |
| `pch_defines`             | "Relaxes checking of `#define` directives in precompiled headers."   | "May not detect some macro definition changes."                                    |
| `random_seed`             | Ignores `-frandom-seed` values in the compilation hash               | "Builds may not be fully reproducible."                                            |
| `system_headers`          | "Only tracks non-system headers in direct mode."                     | "Won't detect system header changes that affect compilation."                      |
| `time_macros`             | Ignores `__DATE__`, `__TIME__`, `__TIMESTAMP__` in source            | "Time values in output will be from cached compilation."                           |

Read as a list, it is a taxonomy of everything a compilation depends on that a
key-derivation function would rather not look at: timestamps, locale
environment, virtual filesystems, randomness, system headers, and macro
expansions of the build's own clock. **Every line is a documented,
user-selectable route to a false cache hit** — and half of them exist only
because the compiler's _output_ records something about _where and when_ it ran
rather than about the program it compiled.

`ignore_options` is the same instrument with no fixed vocabulary: it drops
arbitrary flags from the key, "useful when you know it doesn't affect the
result (and ccache doesn't know that), **or when it does and you don't care**."

## A cache key is not a content address

The distinction this page exists to make.

|                     | Content address ([NAR][nar], [git][git], [REAPI][reapi]) | Cache key (ccache, sccache)                                                  |
| ------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Names               | exactly these bytes                                      | a prediction about an output                                                 |
| Derived from        | all of the object, canonically                           | a hand-enumerated subset of what the process reads                           |
| Wrong is            | impossible without a hash break                          | routine, and configurable                                                    |
| Over-approximation  | meaningless                                              | a _miss_ — costs time (see `hash_dir`, absolute paths, `-MD` system headers) |
| Under-approximation | meaningless                                              | a _false hit_ — costs correctness (see `sloppiness`, the direct-mode hole)   |
| Tuning surface      | none, by design                                          | `sloppiness`, `compiler_check`, `ignore_options`, `base_dir`, `namespace`    |
| Verification        | recompute from the bytes                                 | impossible; only stored-value integrity (XXH3)                               |

The catalog's staleness rule — a heuristic may produce a false "changed" but
never a false "unchanged" ([racy-git][cache-tree]) — is the rule a _content_
system must obey. A compiler cache obeys it by default and then sells the
exception: `sloppiness` is a list of sanctioned false "unchanged" results, each
priced. That is not a defect to be fixed; it is what the layer is for. The
mistake is only ever _confusing the two layers_ — which is why LLVM's design
puts them in separate classes, `ObjectStore` and `ActionCache`
([`llvm/docs/ContentAddressableStorage.md`][llvm-cas]):

> Unlike other kinds of storage systems, like file systems, CAS is immutable.
> It is more reliable to model a computation by representing the inputs and
> outputs of the computation using objects stored in CAS.

The lesson for [`sparkles:build-primitives`][bp]: a tree digest and a build
cache key may share a hash function and share nothing else. The digest layer
must have no `sloppiness` equivalent at all; if a consumer wants one, it
belongs _above_ the digest, as a separate, named, over-ridable mapping — the
way `ActionCache` sits above `ObjectStore`.

## sccache's distributed story

The remote-cache design is where the two diverge. ccache treats remoteness as a
storage tier: `remote_storage` backends hold "compilation results and
manifests" while statistics stay local, and `remote_only` disables the local
tier. The key derivation does not change.

sccache also compiles remotely ([`docs/Distributed.md`][sccache-dist]), which
forces one input to become an explicit, transferable object: the toolchain.
Its distributed mode is a client, a scheduler that decides "where a compilation
job should run", and servers, with the toolchain shipped by
`POST /api/v1/distserver/submit_toolchain` and cached server-side under a
configured `cache_dir` and `toolchain_cache_size`; "Linux compilations will
attempt to automatically package the compiler in use, while Windows and macOS
users will need to specify a toolchain for cross-compilation ahead of time."

Once a compiler must be _shipped_, "which compiler?" stops being a cheap local
approximation (`mtime` and size) and becomes a real content question about a
real archive. That is the pressure that turns a cache key back into a content
address, and it is precisely the pressure [REAPI][reapi] is built entirely
around: there, the toolchain is simply more files in the input `Directory`
tree.

sccache's caveats follow from the same place ([`README.md`][sccache-readme]):
"Crates that invoke the system linker cannot be cached", "Incrementally
compiled crates cannot be cached", and several Clang module flags "bypass the
cache" — when the real input set becomes a mutable directory of state rather
than a list of files, the enumerate-by-hand approach simply declines.

## Strengths

- **The approximation is documented.** `sloppiness` publishes every relaxation
  with its consequence; almost no cache in the field does this.
- **Two hash strategies with an honest cost model** — preprocessor mode buys a
  one-step lookup with a preprocessor run; direct mode buys speed with a
  manifest it must re-validate.
- **A debuggable key.** `ccache-input-text` makes an unexpected miss a diff
  rather than an investigation.
- **The compiler is treated as an input**, with a precision ladder from `none`
  to hashing the binary's contents and (sccache) its sysroot libraries.
- **Deliberate refusals** where relaxation would be indefensible: `__TIME__` in
  the source disables direct mode; a too-new mtime disables caching entirely.
- **Path normalization is a first-class concern** (`base_dir`,
  `SCCACHE_BASEDIRS`), acknowledging that builds are location-dependent in
  practice and should not be in principle.

## Weaknesses

- **False hits are reachable by configuration and undetectable at use.** There
  is no verification step that could catch one.
- **The direct-mode hole is unfixed**: a newly created header that would shadow
  a hashed one is not noticed.
- **The input set is hand-enumerated in source** (`src/compiler/c.rs`,
  `src/compiler/rust.rs`), so it drifts behind compilers; each new flag family
  (C++20 modules, coverage, index stores) is a fresh correctness question.
- **No canonical form to agree on.** Two implementations cannot interoperate on
  keys; sccache and ccache share concepts and no keyspace.
- **No structure to reuse.** No subtree digests, so nothing composes: the cache
  of a file tells you nothing about the cache of the directory containing it.
- **`base_dir` is acknowledged as "a brittle hack"** with known breakage in
  dependency files.
- **Default `compiler_check = mtime`** is the weakest sound option, chosen for
  speed, and silently wrong behind another compiler wrapper.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                   | Trade-off                                                                         |
| ----------------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Hash an enumerated input set, not the process's reads | Cheap, needs no syscall interception or sandbox                             | The set is always an approximation and drifts behind compiler features            |
| Preprocessor mode: hash `cc -E` output                | Headers are inlined, so one hash names everything that mattered             | Pays a full preprocessor run on every lookup                                      |
| Direct mode: hash source + validate a header manifest | Skips the preprocessor entirely on a hit                                    | New-header shadowing is invisible — a documented false-hit path                   |
| Depend mode: take headers from the compiler's depfile | No preprocessor even on a miss; good behind `distcc`                        | `-MMD` omits system headers; lower hit rate; no tolerant fallback                 |
| `compiler_check` defaults to mtime + size             | Hashing a large binary per invocation is unaffordable                       | Misses a content change that keeps size and mtime; hashes wrappers, not compilers |
| `sloppiness` as explicit opt-in relaxations           | Users often know invariants the tool cannot verify                          | Each value is a sanctioned route to a false hit                                   |
| `hash_dir` on by default; `base_dir` to opt out       | The CWD really does end up in debug info                                    | Either cache-miss across directories, or possibly wrong paths in output           |
| Disable caching on too-new mtime/ctime                | Closes the read-then-modify-then-compile race                               | Whole-cache disablement on coarse-timestamp filesystems                           |
| BLAKE3 for keys, XXH3 for stored data                 | Key needs collision resistance; stored bytes only need corruption detection | Two algorithms; neither can detect a semantically wrong entry                     |
| `namespace` salts the key                             | One cache can be partitioned and selectively evicted per project            | Confirms the key is not an identity — the same inputs can have many keys          |
| sccache ships the toolchain for distributed builds    | A remote worker must actually have the compiler                             | The compiler becomes a transferable artifact, i.e. a content-addressing problem   |

## Sources

- [`ccache/ccache` `doc/manual.adoc`][manual] — "How ccache works", `sloppiness`, `compiler_check`, `base_dir`, `hash_dir`, `ignore_options`, `ignore_headers_in_manifest`, `inode_cache`, `namespace`, cache debugging, newly-created-source race
- [`ccache/ccache` `src/ccache/core/manifest.cpp`][ccache-manifest] — the manifest format backing direct mode
- [`ccache/ccache` `src/ccache/hashutil.cpp`][ccache-hashutil] — input hashing helpers
- [`mozilla/sccache` `docs/Caching.md`][sccache-caching] — the enumerated hash inputs for Rust and C/C++
- [`mozilla/sccache` `docs/Architecture.md`][sccache-arch] — preprocessor-cache ("direct") mode, client/server split
- [`mozilla/sccache` `docs/Distributed.md`][sccache-dist] — scheduler/server protocol, toolchain submission and caching
- [`mozilla/sccache` `README.md`][sccache-readme] — `SCCACHE_BASEDIRS`, known caveats, C++20 module support
- [`mozilla/sccache` `src/compiler/c.rs`][sccache-c] and [`src/compiler/rust.rs`][sccache-rust] — the hand-enumerated input sets
- [`llvm/llvm-project` `llvm/docs/ContentAddressableStorage.md`][llvm-cas] — `ObjectStore` versus `ActionCache`
- [`llvm/llvm-project` `llvm/include/llvm/CAS/ActionCache.h`][llvm-actioncache] — the action-cache interface

<!-- References -->

[concepts]: ./concepts.md
[index]: ./index.md
[nar]: ./nar.md
[git]: ./git-objects.md
[cache-tree]: ./git-cache-tree.md
[reapi]: ./reapi.md
[ostree]: ./ostree.md
[bao]: ./bao-blake3.md
[bp]: ../../../libs/build-primitives/src/sparkles/build_primitives/gitignore.d
[manual]: https://github.com/ccache/ccache/blob/b471bbde2923994781821e8d8893e7180ba45168/doc/manual.adoc
[ccache-manifest]: https://github.com/ccache/ccache/blob/b471bbde2923994781821e8d8893e7180ba45168/src/ccache/core/manifest.cpp
[ccache-hashutil]: https://github.com/ccache/ccache/blob/b471bbde2923994781821e8d8893e7180ba45168/src/ccache/hashutil.cpp
[sccache-caching]: https://github.com/mozilla/sccache/blob/0f9467c40e012ef7ea103ac11e0c6935830b18f0/docs/Caching.md
[sccache-arch]: https://github.com/mozilla/sccache/blob/0f9467c40e012ef7ea103ac11e0c6935830b18f0/docs/Architecture.md
[sccache-dist]: https://github.com/mozilla/sccache/blob/0f9467c40e012ef7ea103ac11e0c6935830b18f0/docs/Distributed.md
[sccache-readme]: https://github.com/mozilla/sccache/blob/0f9467c40e012ef7ea103ac11e0c6935830b18f0/README.md
[sccache-c]: https://github.com/mozilla/sccache/blob/0f9467c40e012ef7ea103ac11e0c6935830b18f0/src/compiler/c.rs
[sccache-rust]: https://github.com/mozilla/sccache/blob/0f9467c40e012ef7ea103ac11e0c6935830b18f0/src/compiler/rust.rs
[llvm-cas]: https://github.com/llvm/llvm-project/blob/f10b0b1554d31fdea2dd3963e179fa75ea2e262e/llvm/docs/ContentAddressableStorage.md
[llvm-actioncache]: https://github.com/llvm/llvm-project/blob/f10b0b1554d31fdea2dd3963e179fa75ea2e262e/llvm/include/llvm/CAS/ActionCache.h
