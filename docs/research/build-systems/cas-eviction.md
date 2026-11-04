# CAS & Action-Cache Eviction (Theme)

Eviction is the only part of a content-addressed build store that can turn a hit
into a dangling pointer. The action key, the sandbox and the trace settle whether
a result _may_ be reused; eviction settles whether the bytes behind it still
exist. This page separates the two stores that share the word "cache" (blobs by
content, results by action digest), inventories the policies the catalog's
systems ship, and collects what their sources state about the cost. Claims with no
named source are marked **catalog inference**.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                         |
| ---------- | --------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                       |
| Question   | What does a store keep, what does it discard, and what keeps a discard from breaking a build? |
| Mechanisms | byte-budgeted LRU, watermarks, block rotation, scan-and-sort GC, reachability, leases         |
| Systems    | Buildbarn, BuildBuddy, NativeLink, Bazel `--disk_cache`, Buck2, Pants, Please, Nix, Moon      |
| Vocabulary | [concepts] — this page does not redefine _store_, _trace_, _rebuilder_ or _correctness_       |

> [!NOTE]
> Scope is the **eviction policy of a build store**: capacity accounting, the
> recency signal, eviction ordering, and the action-cache/blob-store integrity
> rules. Deduplication appears only where it changes that accounting.

## Overview

### What it solves

A build cache has two address spaces with different shapes. The **CAS** maps a
digest of content to bytes — large, immutable, shared between actions and users.
The **Action Cache** maps a digest of an `Action` to an `ActionResult` — small,
rewritten by re-execution, referenced by one action. [concepts] §6 names the pair:
a content-addressable cache plus a memo table.

Capacity is what that model leaves out — the à-la-carte account puts policy out
of scope ([a-la-carte] §4) — and it is where production diverges. Three costs
compete: **bytes** (the disk bill), **retention** (the hit rate), and
**integrity** (whether a surviving `ActionResult` still has every blob it names).
The last is a correctness property, not a knob.

### Design philosophy

The REAPI states the obligation and hands the policy back:

> "The lifetime of entries in the action cache is implementation-specific, but
> the server SHOULD assume that more recently used entries are more likely to be
> used again."
>
> — [`remote_execution.proto`][reapi], `ActionCache`

The CAS clause is weaker and load-bearing: entries must live "long enough to
allow for newly-added and recently looked-up entries to be used in subsequent
calls (e.g. to `Execute`)" ([reapi]). A client cannot ask how much is kept —
`CacheCapabilities` has no capacity, retention or policy field, only a per-request
`ResultsCachePolicy.priority` where "a lower value means a longer retention time
… but the interpretation of a given value is server-dependent" ([reapi]).
**Catalog inference:** that absence is deliberate; retention is an operational
promise, so any hit is provisional.

## How it works — the policy families

| Family                 | Eviction unit              | Recency signal                     | Used by                     |
| ---------------------- | -------------------------- | ---------------------------------- | --------------------------- |
| Byte-budgeted LRU      | one entry                  | timestamp updated on hit           | NativeLink, BuildBuddy      |
| Watermark / hysteresis | one entry, in batches      | same, evicted to a low watermark   | NativeLink, BuildBuddy      |
| Block rotation         | a whole block of blobs     | copy-on-access from "old" to "new" | Buildbarn `LocalBlobAccess` |
| Scan-and-sort GC       | one file, ordered by mtime | mtime touched on read and write    | Bazel `--disk_cache`        |
| Reachability / roots   | a closure from named roots | liveness, not popularity           | Nix, Buck2 `clean --stale`  |
| Lease / refcount       | a shared inode             | reference count plus age           | Please, Pants, BuildKit     |

The first two need an index of every entry, the third needs none, the fourth a
full walk, and the last two a reference count — so no two rows substitute.

### 1. One budget or two

Whether the AC and CAS share a pool shows in the configuration surface. Buildbarn
declares separate `BlobAccess` trees, each with its own blocks ([`blobstore.proto`][bb-proto]);
BuildBuddy puts both in the same partition LRU, distinguished by an `ac/` vs
`cas/` path segment ([`disk_cache.go`][bb-disk]); NativeLink's `eviction_policy`
is per named store ([`stores.rs`][nl-stores]).

Sharing one pool is simpler but makes eviction order responsible for integrity;
Bazel states the invariant that keeps it safe:

> "Update the mtime on the action result itself before any of the blobs it
> references. This ensures that the blobs are always newer than the action
> result, so that trimming the cache in LRU order cannot create dangling
> references."
>
> — [`DiskCacheClient.java`][bazel-disk]

The same rule reappears as a tie-break, sorting "AC entries … before CAS entries
with the same age, making it less likely for garbage collection to break
referential integrity in the event that mtime resolution is insufficient"
([`DiskCacheGarbageCollector.java`][bazel-gc]). Servers that do not maintain the
ordering check instead. Buildbarn's `completeness_checking` decorator returns an
`ActionResult` only if every output blob is still present — "Certain clients, such
as Bazel, require the use of this decorator" ([bb-proto]). Bazel's client has the
mirror switch, `checkActionResultIntegrity`, which treats a partially present
result as stale ([bazel-disk]). The protocol's escape hatch is
`ExecuteRequest.skip_cache_lookup`, for "replacing action cache entries that
reference outputs no longer available or that are poisoned in any way" ([reapi]).

**Catalog inference:** of the three repairs — ordering, completeness check,
skip-and-replace — only ordering is free; a completeness probe costs a CAS
existence check per hit ([bb-proto]).

### 2. Size, watermark, and the moment of eviction

Exact per-entry LRU is the stated policy of both in-memory implementations:

> "Eviction policy always works on LRU (Least Recently Used). Any time an entry
> is touched it updates the timestamp. Inserts and updates will execute the
> eviction policy removing any expired entries and/or the oldest entries until
> the store size becomes smaller than `max_bytes`."
>
> — [`stores.rs`][nl-stores]

An exact budget evicts on every insert once full, which thrashes, so both add
hysteresis. NativeLink's `evict_bytes` "continue[s] until `max_bytes - evict_bytes`
is met to create a low watermark. This stops operations from thrashing when the
store is close to the limit" ([nl-stores]). BuildBuddy evicts to 90% of capacity
(`janitorCutoffThreshold = .90`) from a 100 ms janitor ([bb-disk]).

Buildbarn approximates harder by making the **block** the eviction unit: "Blocks
are the unit at which `LocalBlobAccess` performs garbage collection. If storage
space in all used blocks is exhausted, `LocalBlobAccess` discards the contents of
a block so that space may be reused." Its documentation does the arithmetic — "If
the total number of blocks is 32, `LocalBlobAccess` will only discard 100% / 32 =
3.125% of its data at a time" — so the collector touches blocks, not blobs, and
there is no per-entry recency ledger to maintain ([bb-proto]). The README sells
the result: "This storage backend is self-cleaning; no garbage collection is
needed" ([`bb-storage` README][bb-readme]).

Bazel's disk cache is the outlier: eviction is **off until configured**, then runs
as an idle task — `--disk_cache_gc_max_size` and `--disk_cache_gc_max_age` both
default to `0`, and `--disk_cache_gc_idle_delay` (`5m`) sets the idle time before
collection "occurrs in the background" ([bazel-opt]). The collector admits its
cost: "This process may take a significant amount of time on large disk caches
and slow filesystems, and may be interrupted at any time" ([bazel-gc]).
**Catalog inference:** that is the trade in one line — a global sort buys a cheap
integrity argument by paying a full walk; block rotation buys a cheap steady
state by giving up per-blob precision.

### 3. What counts as a touch

Recency is only as good as the event that records it, and the implementations
differ on purpose:

- **NativeLink** keeps the timestamp in an `EvictingMap` and separates a promoting
  `get` from a non-promoting `peek` — "Note: `peek` may still evict, but won't
  promote" ([`evicting_map.rs`][nl-evict]) — so `FindMissingBlobs` probes need not
  keep cold blobs alive.
- **BuildBuddy** treats even `Contains` as a use, citing the protocol: "any blobs
  referenced from the `ContentAddressableStorage` are available at the time of
  returning the `ActionResult`" ([bb-disk]).
- **Bazel** deliberately uses mtime, not atime — "the atime is more likely to be
  externally modified and may be unavailable on some filesystems" — refreshing it
  on store and retrieve ([bazel-disk]).
- **Buildbarn** refreshes only from the "old" generation: "Data in the 'current'
  group is assumed to remain present for the time being" ([bb-proto]). A hit
  mid-ring does not move the blob.

Restart is the same problem from the other side. BuildBuddy keeps no ledger:
"Rather than serialize this ledger, we regenerate it from scratch on startup by
looking at the filesystem", sorting by atime until the LRU is full ([bb-disk]).
NativeLink takes the filesystem's atime: "Using access time is not perfect, but
better than random. We do not update the atime when a file is actually 'touched',
we rely on whatever the filesystem does when we read the file"
([`filesystem_store.rs`][nl-fs]). Bazel and Buildbarn persist the signal instead —
mtime on disk, the block ring in a protobuf state file — so a restart resumes the
same order ([bazel-disk], [bb-proto]).

**Frequency and segmentation.** No surveyed server implements LFU: none of the
four counts hits, and NativeLink's map is a plain `LruCache` ([nl-evict]).
Buildbarn's old/current/new ring is the closest thing to a segmented policy —
promotion happens only once a blob has aged into the old group, with the source
warning that too few old blocks "would cause this storage backend to become a FIFO
instead of being LRU-like" ([bb-proto]). That is segmented LRU (`SLRU`) in all but
name; the four-segment generalization sometimes called `S4LRU` appears in no
surveyed document. **Catalog inference.**

### 4. Deduplication changes the accounting

Content addressing means one blob satisfies many results, so "one entry" is
rarely one entry's bytes. Systems that expose this handle it explicitly:

- **Please** hardlinks entries to and from `plz-out`, so "eviction counts only
  unshared bytes and cleans by LRU to watermarks, age and free-space floors"
  ([please] §4) — three limits, not one.
- **Nix** makes liveness the criterion: "Garbage collection uses profiles and
  generations as roots" ([nix-thesis] §4), with `--optimise` hardlinking identical
  files.
- **Buildbarn** at its tip makes content-defined chunking mandatory: the CAS is a
  Chunk Storage plus a Chunk Mapping Storage, and "individual chunks of large
  blobs are deduplicated such that the chunks are stored only once"
  ([bb-storage] tip commit).

Chunking breaks the per-blob lifetime model, and the protocol says so: "A blob
and any chunk derived from it MAY be evicted from the CAS at different times"
([reapi], `GetChunkMapping`). A related hazard sits in the index: Buildbarn's
`key_location_map` is lossy, so an index eviction can orphan a blob that still
occupies blocks — eviction in the _index_ before the _data_, looking like capacity
pressure while the disk is not full ([bb-proto]). **Catalog inference.**

## Shallow builds and hash passthrough

Shallow builds are where eviction stops being a cache concern and joins the
correctness model. The trace is kept, the intermediate value is not, so a hash
"passes through" the store after its blob is gone: [concepts] §6 lists eviction
among the four things the cloud model still owes, since "shallow builds gain from
keeping traces whose values were evicted, so a hash passes through until
materialised".

The client half is deployed. Bazel's `RemoteOutputsMode` names "build without the
bytes" with `ALL`, `TOPLEVEL` and `MINIMAL`, the last downloading only stdout,
stderr and dep files ([bazel] §4); Buck2's deferred materialization leaves
eviction to the backend and offers `clean --stale`, which "does not fully wipe
`buck-out` but it should not negatively impact build performance" ([buck2] §4).
The clause that makes both safe is §1's: on an AC hit the server "SHOULD ensure
that any blobs referenced … are available at the time of returning the
`ActionResult` and will be for some period of time afterwards" ([reapi]).
**Catalog inference:** a shallow build is exactly the client that clause is
written for — it accepts a hit without materialising anything and relies on the
retention window until it does. Violating the window yields a lazy fetch, not a
wrong artifact, provided the fetch is checked against the digest the trace named.

## Cost, as published

No surveyed project publishes an eviction benchmark; what they publish is
instrumentation and the shape of the cost.

| System     | Published statement                                                                                                 | Source     |
| ---------- | ------------------------------------------------------------------------------------------------------------------- | ---------- |
| Bazel      | GC reports `Deleted %d of %d files, reclaimed %s of %s in %.2f seconds (%d files/s, %s/s)…` — a report, no baseline | [bazel-gc] |
| Buildbarn  | worst-case retention is a query: `time() - …last_removed_old_block_insertion_time_seconds`                          | [bb-proto] |
| BuildBuddy | eviction age as a histogram (`DiskCacheEvictionAgeMsec`) plus `DiskCacheLastEvictionAgeUsec` per partition          | [bb-disk]  |
| NativeLink | `evicted_bytes`, `evicted_items`, `replaced_bytes`, `lifetime_inserted_bytes` on the eviction map                   | [nl-evict] |

The design answer is structural: keep eviction off the hot path. Bazel runs it as
an idle task, BuildBuddy's janitor is a 100 ms background loop, and NativeLink
evicts on insert inside the map's lock ([bazel-opt], [bb-disk], [nl-evict]).
**Catalog inference:** the number that predicts next week's hit rate is the
_eviction age_ these systems export — how old a blob is when it dies.

## Correctness risks

| Risk                                      | Documented in                                                                | Mitigation there                                                                             |
| ----------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| AC entry survives, its blobs do not       | [reapi] `GetActionResult`; [bb-proto]; [bazel-disk]                          | completeness probe, or AC-before-CAS order                                                   |
| A hit is evicted mid-build                | [bb-proto] refresh-on-access; [bazel-disk] mtime refresh on read             | copy into "new" blocks; touch on retrieve                                                    |
| Index entry lost, data orphaned           | [bb-proto] `key_location_map` metrics                                        | size the hash map against the block store                                                    |
| Existence cache serves a stale "present"  | [bb-proto] `existence_caching`                                               | backend "must also be robust enough to guarantee that objects don't disappear shortly after" |
| Chunk outlives or precedes its blob       | [reapi] `GetChunkMapping`                                                    | declared legal; clients must tolerate the split                                              |
| A read races a delete                     | [bazel-disk] class comment                                                   | "an affected build is able to automatically recover by retrying"                             |
| Poisoned results cannot be evicted by age | [reapi] `Action.salt`; [bb-proto] `action_result_expiring.minimum_timestamp` | disown the namespace, or expire below a timestamp                                            |

Two entries are policy, not bugs. Bazel accepts the race on purpose — "although we
could have arranged for an ongoing garbage collection to block a concurrent
build, we judge it to not be worth the extra complexity" ([bazel-disk]) — which is
only defensible because a miss is always legal. Buildbarn adds **age** as an
independent eviction reason: `action_result_expiring` hides results older than
`minimum_validity`, with deterministic jitter "so that actions that were built at
around the same time don't also expire at around the same time, therefore
amortizing the rate at which actions are rebuilt" ([bb-proto]). Retention has two
clocks — bytes and age — and the age clock bounds staleness of a _correct_ result.
A store is only proven correct under eviction if its miss path runs, which is why
all four servers ship an integrity check or an ordering invariant.

## Strengths and weaknesses

- **Exact LRU is affordable only at small scale**: it needs a full index and a
  lock on the hit path, and both implementations add a watermark so the index does
  not thrash ([nl-stores], [bb-disk]).
- **Block rotation is the only design without a per-entry recency index**, and it
  buys corruption resistance: live data is never overwritten ([mono-buildbarn]).
  It pays in precision — a block of cold blobs dies with the warm ones — and its
  retention bound is block count, not demand.
- **Scan-and-sort is the only design that can order AC before CAS globally**, and
  the only one that needs a full walk ([bazel-gc]).
- **Reachability is precise about liveness and blind about popularity**: Nix keeps
  an ancient result forever if a profile points at it ([nix-thesis]).
- **Deduplication makes "size" ambiguous** — logical, physical and referenced
  bytes diverge ([please], [bb-storage]) — and no surveyed system publishes a
  hit-rate-versus-capacity curve, so sizing remains a guess plus a metric
  ([bb-proto] retention query).

## Key design decisions and trade-offs

| Decision                               | Rationale                                                  | Trade-off                                                                |
| -------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------ |
| Separate AC and CAS capacities         | Different sizes and reuse distances; independent retention | Two things to size; a small AC can starve while the CAS is idle          |
| Share one LRU, order AC before CAS     | One knob; ordering keeps references valid without a probe  | Integrity rests on timestamp resolution or explicit tie-breaks           |
| Completeness-check on AC read          | Correct under arbitrary eviction, including external GC    | A CAS probe per hit; needs a view of the whole store                     |
| Evict on insert with a low watermark   | No background thread; budget barely exceeded               | Eviction latency lands on the writer                                     |
| Evict in blocks (generational ring)    | No index, no GC, no in-place overwrite                     | Coarse: one block of cold data at a time; retention is block-count-bound |
| Sweep on idle, ordered by mtime        | Exact global order, invisible to the critical path         | A full walk that "may take a significant amount of time"                 |
| Expire results by age as well as bytes | Bounds staleness even when capacity is ample               | Rebuild waves, damped only by jitter                                     |

## Sparkles relevance

`sparkles.build_primitives.task` has no store at all: `TaskNode`, `TaskEdge` and
`OutputPolicy` describe a DAG to execute, and the executor writes into the
workspace
(`libs/build-primitives/src/sparkles/build_primitives/task/executor.d`).
A grep for `cache`, `digest` or `content-address` across
`libs/build-primitives/src/sparkles/build_primitives/task/`
finds nothing: the project is not choosing a policy yet, only whether to have a
store. If one arrives, three findings transfer cheaply and one is an advantage:

- **Two budgets, not one.** Action keys are small, hot, one-to-one; blobs are
  large, cold, shared. Collapsing them is the mistake Bazel and BuildBuddy repair
  with ordering rules ([bazel-disk], [bb-disk]) — and dedup means accounting
  inodes and references, not logical sizes ([please], [bb-storage]).
- **Order the touch, or check on read.** Touch an action entry before its blobs,
  or verify presence at read time; doing neither is the dangling-reference bug.
- **Watermarks and a background sweep.** Exact budgets on the write path turn a
  burst into a stall ([nl-stores], [bb-disk]).
- **The explicit DAG is an eviction oracle the surveyed servers lack.** Sparkles
  knows which outputs a requested target needs, so retention can be a reachability
  mark from the requested roots — Nix's criterion — rather than a recency guess
  over an opaque namespace ([nix-thesis] §4). **Catalog inference:** an
  opportunity, not a shipped property; a remote store would still need a recency
  fallback for blobs no local DAG names.

## Sources

In-corpus pages synthesized first, and what each supplied: [concepts] (§4 shallow
correctness, §6 CAS + memo table and the eviction/passthrough obligation),
[a-la-carte] (§4 policy out of scope), [bazel] (three caches,
`RemoteOutputsMode`), [buck2] (`clean --stale`), [pants] (lease-based eviction
still incomplete), [please] (eviction by watermarks, age and free-space floors),
[moon] (`BLOB_GRACE` reachability sweep), [nix-thesis] (GC roots), [nixception]
(the Nix store as CAS and action cache), [rattle] and [perfect-dependencies]
(research stores with no eviction). Monorepo pages: [mono-buildbarn] (the ADR's
no-GC rationale), [mono-buildbuddy] (`ttl_days`), [mono-nativelink]
(`eviction_policy` per store). Primary sources opened, all read at these pins:

- REAPI `remote-apis@c2c07e3d`: [`remote_execution.proto`][reapi] — lifetimes,
  the `GetActionResult` clause, `CacheCapabilities`, `ResultsCachePolicy`,
  `skip_cache_lookup`, chunk lifetimes.
- Buildbarn `bb-storage@ca3d8b49`: [`blobstore.proto`][bb-proto] (block ring,
  completeness checking, existence caching, `action_result_expiring`),
  [README][bb-readme], tip commit [ca3d8b4][bb-storage] (CDC).
- BuildBuddy `buildbuddy@67b39185`: [`disk_cache.go`][bb-disk] (per-partition
  LRU, 90% janitor, atime rebuild).
- Bazel `bazel@2105aec3`: [`RemoteOptions.java`][bazel-opt] (GC flags),
  [`DiskCacheClient.java`][bazel-disk] (mtime semantics, touch ordering,
  integrity check), [`DiskCacheGarbageCollector.java`][bazel-gc] (sort order).
- NativeLink as vendored in `nixception@0d3fa7bb`: [`stores.rs`][nl-stores]
  (`EvictionPolicy`), [`evicting_map.rs`][nl-evict] (LRU map, counters),
  [`filesystem_store.rs`][nl-fs] (atime on restart),
  [`CHANGELOG-nativelink.md`][nl-changelog] (low watermark, touch failures).

<!-- References -->

[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[pants]: ./pants.md
[please]: ./please.md
[moon]: ./moon.md
[nix-thesis]: ./nix-thesis.md
[nixception]: ./nixception.md
[rattle]: ./rattle.md
[perfect-dependencies]: ./perfect-dependencies.md
[mono-buildbarn]: ../monorepo-tooling/buildbarn/index.md
[mono-buildbuddy]: ../monorepo-tooling/buildbuddy/index.md
[mono-nativelink]: ../monorepo-tooling/nativelink/index.md
[reapi]: https://github.com/bazelbuild/remote-apis/blob/c2c07e3d718d3d490a4958344d9c3e47de0bfaf3/build/bazel/remote/execution/v2/remote_execution.proto
[bb-proto]: https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5af52eb02ed473dd689d19b949c9e41/pkg/proto/configuration/blobstore/blobstore.proto
[bb-readme]: https://github.com/buildbarn/bb-storage/blob/ca3d8b49a5af52eb02ed473dd689d19b949c9e41/README.md
[bb-storage]: https://github.com/buildbarn/bb-storage/commit/ca3d8b49a5af52eb02ed473dd689d19b949c9e41
[bb-disk]: https://github.com/buildbuddy-io/buildbuddy/blob/67b391858e6a26fe22310a638ed3f68c0f8ea91d/server/backends/disk_cache/disk_cache.go
[bazel-opt]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/options/RemoteOptions.java
[bazel-disk]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/disk/DiskCacheClient.java
[bazel-gc]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/disk/DiskCacheGarbageCollector.java
[nl-stores]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/nativelink-config/src/stores.rs
[nl-evict]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/nativelink-util/src/evicting_map.rs
[nl-fs]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/nativelink-store/src/filesystem_store.rs
[nl-changelog]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/CHANGELOG-nativelink.md
