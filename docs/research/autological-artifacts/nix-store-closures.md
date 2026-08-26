# The Nix store and closure computation (package manager · content-addressed store)

The system that gave this catalog the word _closure_: a store whose dependency edges are **discovered by scanning output bytes for hashes** rather than declared, held in a SQLite database that is deliberately _outside_ the artifacts it describes, and reclaimed by a mark-and-sweep collector whose roots include a scan of `/proc`.

| Field           | Value                                                                                                                           |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Package-manager store, reference database, and garbage collector                                                                |
| Language        | C++23 (`libstore`, `cpp_std=c++23`), SQLite DDL, the Nix expression language                                                    |
| License         | LGPL-2.1-or-later ([`COPYING`][copying], `CITATION.cff` `license: LGPL-2.1`)                                                    |
| Repository      | [NixOS/nix][repo]                                                                                                               |
| Documentation   | [Nix manual — Store][manual-store] · [Store Path][manual-store-path] · [glossary][manual-glossary] · [Dolstra's thesis][thesis] |
| First release   | First commit 2003-03-13 (`* Initial version of nix.`); the model published in Eelco Dolstra's PhD thesis, defended 2006-01-18   |
| Axis profile    | Multiplicity **0** / Reflexivity **2** / Closure **3** / Mutability **1**                                                       |
| Index anchoring | **out-of-band** — `/nix/var/nix/db/db.sqlite`; per-object `References:` headers in a binary cache's `.narinfo`                  |
| Dispatch owner  | **consumer** — nothing dispatches on a store object's bytes; store objects are ordinary ELF, scripts and data                   |

> **Latest revision surveyed:** `NixOS/nix` at [`46bc30b6`][repo] (2026-08-26, `.version` `2.36.0`). **Measurements** were taken on 2026-08-26 against a live NixOS `/nix/store` holding 208,442 valid paths, 1,914,130 reference edges and 321.3 GiB of NAR bytes, with `nix` 2.32.8. **Platform:** the store model is portable; the runtime-root scan is Linux-specific (`/proc`) with an `lsof` fallback elsewhere.

> [!NOTE]
> This page is about the _internal structure of the dependency graph_ — how edges are found, where they are stored, how a closure is computed, and how the store is collected. Distribution mechanics (binary caches, substituters, signing infrastructure, channels) belong to [application packaging][app-packaging] and are linked, not re-surveyed. The umbrella is [Autological Artifacts][index].

---

## Overview

### What it solves

Conventional deployment expresses dependencies _nominally_: a `.deb` says `Depends: libc6 (>= 2.34)` and hopes the machine has something that satisfies it. Two failures follow. First, the declaration can be wrong — it is written by a human, and nothing checks that the shipped binary actually needs only what the control file lists, or that it needs _nothing more_. Second, the name does not identify a specific artifact, so the same package installed on two machines can resolve to different bytes.

Nix's answer is to make dependency edges **exact** rather than nominal, and to make them **found** rather than declared. Every store object lives at a path whose 32-character digest is a hash of everything that determined it, and every reference from one store object to another is _the literal appearance of that digest inside the referring object's bytes_. Nothing declares the edge. The build finishes, Nix serialises the output and scans the stream for the digests of the build's inputs, and whichever digests occur become the output's references. The transitive closure of that relation is the set of store objects that must travel together for the artifact to work at all — and that set is what this catalog means by [closure][concepts].

The consequences that matter here are structural, not ergonomic:

| Question                             | Nix's answer                                                                                         |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| What names an artifact?              | A hash of its _inputs_ (input-addressed) or of its _content_ (content-addressed, still experimental) |
| Where are its dependencies recorded? | Nowhere in the artifact — they are recomputed by scanning it                                         |
| Where does the graph live?           | A SQLite database at `/nix/var/nix/db/db.sqlite`, out-of-band from every object it describes         |
| What is a closure?                   | `WITH RECURSIVE` over a two-column `Refs` table                                                      |
| What deletes an unused artifact?     | Tracing mark-and-sweep from GC roots, with a global lock and a `/proc` scan for live processes       |

### Design philosophy

The scanning decision is the surprising one, and Dolstra states it in the thesis as a deliberate refusal to know anything about file formats ([_The Purely Functional Software Deployment Model_][thesis], §2.3, p. 23):

> _"But we do not know the format of every file type, and we do not wish to commit ourselves to a single component composition mechanism. … The hashing scheme comes to the rescue once more. The hash part of component paths is highly distinctive, e.g., `5jq6jgkamxjj...`. Therefore we can discover retained dependencies generically, independent of specific file formats, by scanning for occurrences of hash parts."_

Chapter 3 supplies the theory the technique is borrowed from, and names it without hedging:

> _"The solution to proper dependency identification comes from conservative garbage collection. … we want to borrow the concept of conservatively scanning for pointers from the detection phase. Specifically, we want to scan the contents of files (of which we do not know the layout), and if we see a string of characters that looks like a file name, we assume that the file being scanned has a pointer to the file indicated by the name."_

That is the whole design in one analogy: **a store path is a pointer, a store object is a heap object, the file system is memory, and a package manager is a conservative garbage collector.** Everything else — the store path layout, the immutability rule, the GC roots, the `/proc` scan — is what that analogy costs to make sound. The thesis is explicit about the two properties the pointer had to acquire: pointers must be "shaped in such a way that they are reliably recognisable" (hence 160 bits of Nix32, not `bin`), and "components have to be separated from each other" (hence one directory per store object, so nothing can "hop" between components by pointer arithmetic on a shared prefix).

It is also explicit about the failure mode it inherits, under the name **pointer hiding**: an edge that exists but is not written as contiguous ASCII is invisible.

> _"If the collector searches for ASCII representations of the hash parts of component names, then anything that causes those hash parts to be not represented as contiguous ASCII strings will break the detection. … More threatening is the use of another representation than ASCII. For instance, if paths are represented in UTF-16, Nix's scanner will not find them. … Ultimately, how well the scanning approach works is an empirical question."_

Twenty-three years on, the scanner in [`src/libstore/references.cc`][references-cc] still searches only for the 32-character Nix32 digest and nothing else, and the manual still records the reason as a design rule rather than an implementation detail ([`store/building.md`][building-md]): _"The name part and the store directory path are ignored when scanning; an input's hash part that is neither followed by a `-` nor proceeded by a `/` still scans as a reference."_

---

## How it works

### Store paths: a hash of the inputs, not of the output

The rendered path is three parts, per [`store/store-path.md`][manual-store-path]:

```text
  /nix/store/q06x3jll2yfzckz2bzqak089p43ixkkq-firefox-33.1
  |--------| |------------------------------| |----------|
store directory            digest                 name
```

The digest is a SHA-256 hash "compressed to 160 bits" and rendered in Nix32, so it is exactly 32 characters — `StorePath::HashLen = 32` in [`path.hh`][path-hh]. What is hashed is specified completely in [`protocols/store-path.md`][protocols-store-path]:

```text
fingerprint = type ":sha256:" inner-digest ":" store ":" name
```

For the ordinary case — an output built by a derivation, input-addressed — `type` is `"output:" id` and the `inner-fingerprint` is _"the ATerm serialization of the derivation modulo fixed output derivations."_ The digest is therefore a function of **the build recipe and its inputs**, computed _before the build runs_. Nothing about the resulting bytes participates. Two builds that produce identical bytes from different recipes land at different paths, and a non-reproducible build lands at the _same_ path as the run before it.

The alternative — hashing the output — is the `ca-derivations` experimental feature, whose description in [`experimental-features.cc`][xp-cc] is candid about the motive: _"Allow derivations to be content-addressed in order to prevent rebuilds when changes to the derivation do not result in changes to the derivation's output."_ It has been experimental for years, and the reason is visible in the store-path spec: content-addressing collides head-on with **self-reference**, because a store object commonly contains its own path (an `RPATH` pointing into itself, an installed script naming its own location), which would require solving `digest = hash(… || digest || …)` — a fixed point of a cryptographic hash. Nix's escape is a sentinel:

> _"In all currently-supported store object content-addressing methods, when hashing the file system object data, any occurrence of store object's own store path in the digested data is replaced with a sentinel value."_
>
> — [`store/store-object/content-address.md`][ca-md]

Note the shape of that: the same "look for our own digest in our own bytes" operation as the reference scan, run in reverse, to _erase_ the pointer before hashing. The scan is load-bearing in both directions.

### References are discovered, not declared

The scanner is twenty lines. [`references.cc`][references-cc] walks the byte stream looking for any 32-character run drawn from the Nix32 alphabet, and checks it against a set of candidate digests:

```cpp
/* src/libstore/references.cc — search(), line breaks compacted */
static void search(std::string_view s, StringSet & hashes, StringSet & seen)
{
    for (size_t i = 0; i + refLength <= s.size();) {
        int j; bool match = true;
        for (j = refLength - 1; j >= 0; --j)
            if (!BaseNix32::lookupReverse(s[i + j])) { i += j + 1; match = false; break; }
        if (!match) continue;
        std::string ref(s.substr(i, refLength));
        if (hashes.erase(ref)) { debug("found reference to '%1%' at offset '%2%'", ref, i); seen.insert(ref); }
        ++i;
    }
}
```

`RefScanSink` is a streaming sink, and it re-searches the join of the previous fragment's tail with the current fragment's head so a digest split across a chunk boundary is still found. [`path-references.cc`][path-refs-cc] wraps it: `scanForReferences` dumps the output path as a NAR through a `TeeSink` and maps the surviving digests back to store paths through a `backMap`. The candidate set is bounded — only the build's declared _inputs_ are scanned for, never all store paths — which is what keeps the cost linear in output bytes rather than in store size.

Two properties fall out and are worth naming plainly:

- **The scan is conservative in the GC sense.** A digest occurring by coincidence — in a log file, a test fixture, a hash-of-a-hash — becomes a real edge and pins a real store object. That is a false positive, and it is the _safe_ direction.
- **The scan is unsound in the other direction, permanently.** A compressed executable, a UTF-16 path, a path assembled at run time from two halves: none of these produce an edge. The thesis argued the empirical case; the format offers no guarantee, and none has been added since.

The per-file granularity exists for humans: `nix why-depends --precise` calls `scanForReferencesDeep` ([`path-references.cc`][path-refs-cc]) to report _which file_ inside a store object carries the digest — the closest thing the system has to a debugger for its own edges.

> [!NOTE]
> The scan can be switched off per output. `unsafe-discard-references` tells Nix to record no references for an output at all, and the name is the documentation: an object whose references are discarded can be collected out from under its dependents. See [`store/building.md`][building-md].

### The graph lives in a SQLite database, out-of-band

Once found, the edges go into `/nix/var/nix/db/db.sqlite`. [`schema.sql`][schema-sql] is 40 lines and fits here whole in the parts that matter:

```sql
create table if not exists ValidPaths (
    id               integer primary key autoincrement not null,
    path             text unique not null,
    hash             text not null, -- base16 representation
    registrationTime integer not null,
    deriver          text,
    narSize          integer,
    ultimate         integer, -- null implies "false"
    sigs             text, -- space-separated
    ca               text -- if not null, an assertion that the path is content-addressed
);

create table if not exists Refs (
    referrer  integer not null,
    reference integer not null,
    primary key (referrer, reference),
    foreign key (referrer) references ValidPaths(id) on delete cascade,
    foreign key (reference) references ValidPaths(id) on delete restrict
);

create index if not exists IndexReference on Refs(reference);
```

Three details carry weight.

- **The closure property is a foreign-key constraint.** `on delete restrict` on `reference` means SQLite itself refuses to remove a `ValidPaths` row that something still points at, and [`sqlite.cc`][sqlite-cc] turns the enforcement on (`exec("pragma foreign_keys = 1")`). The manual's [closure property][manual-store-object] — _"A store can only contain a store object if it also contains all the store objects it refers to"_ — is not merely checked by the collector; it is a database invariant. `on delete cascade` in the other direction disposes of the outgoing edges automatically, which is why [`local-store.cc`][local-store-cc]'s `invalidatePath` is three lines with a comment rather than a loop.
- **Self-references need a trigger.** A store object may contain its own digest, producing a row `(N, N)` that `on delete restrict` would block forever. `schema.sql` carries a `DeleteSelfRefs` trigger that removes exactly those rows `before delete on ValidPaths`, with the reasoning inline in the comment.
- **`IndexReference` exists to make the graph traversable backwards.** The GC does not walk _references_; it walks _referrers_, and the index on the second column is what makes that direction affordable. [`local-store.cc`][local-store-cc] prepares both statements side by side, and they differ only in which column they join on.

The irony for this catalog is worth stating explicitly rather than leaving as an aside. **Nix's index of the store is a SQLite database that lives outside the store.** [SELF][self] takes the same two ingredients — a dependency graph and SQLite — and puts the database _inside_ the artifact; Nix keeps every store object a plain, unannotated file system tree and holds the entire relational layer in one file at `/nix/var/nix/db/db.sqlite` that no store object knows about. Both designs work. Which one is right is precisely the question the catalog exists to ask, and the [comparison page][comparison] is where the two sit next to each other.

Out-of-band means [materialized view][concepts], with the usual property: the database is _derivable_. Nothing in it that matters is unrecoverable, because the references can be recomputed by rescanning — which is what `nix-store --verify --check-contents` and `--repair` exist for. But it is also authoritative in practice, and losing it is losing the graph until a full rescan.

> [!WARNING]
> **Reading `db.sqlite` out-of-band with `?immutable=1` silently gives a stale answer.** `immutable=1` tells SQLite to ignore the write-ahead log. On the surveyed machine the main database file reported 207,223 valid paths while the same query against a copy including the 157.9 MiB `db.sqlite-wal` reported **208,442** — a 1,219-path gap, and the same relative gap on `Refs` and on total `narSize`. Nix's own opener ([`sqlite.cc`][sqlite-cc]) uses `immutable=` only for its explicitly read-only mode and otherwise runs WAL. Any external tool querying the store database must copy `db.sqlite`, `-wal` and `-shm` together or it is reading a checkpoint, not the store. This is the [WAL][sqlite-wal] contract, not a Nix bug, and it is the first thing that goes wrong when someone treats an out-of-band index as a file.

### Closure computation

[`Store::computeFSClosure`][misc-cc] is a breadth-first traversal with four knobs: `flipDirection` swaps `references` for `referrers`, `includeOutputs` adds a derivation's outputs, `includeDerivers` adds a path's deriver. That is the whole of it — the "closure" of the glossary is the `flipDirection = false, includeOutputs = false, includeDerivers = false` case:

> _"The closure of a store path is the set of store paths that are directly or indirectly 'reachable' from that store path; that is, it's the closure of the path under the references relation."_
>
> — [`glossary.md`][manual-glossary]

`nix path-info --closure-size` sums `narSize` over that set ([`src/nix/path-info.cc`][path-info-cc]), and the manual is careful that the number is _not_ an intrinsic property of the object: [`store-object.md`][manual-store-object] notes that closure NAR size _"is not quite an intrinsic property"_ because different stores may disagree about what a given path refers to, and that implementations _"currently typically compute this on the fly rather than storing it."_

The traversal is a recursive query wearing C++. On the surveyed machine, four lines of SQL against the raw store database reproduce `nix path-info -S` exactly:

```sql
with recursive closure(id) as (
    select id from ValidPaths where path = '/nix/store/syikk…-git-with-svn-2.51.2'
  union
    select r.reference from Refs r join closure c on r.referrer = c.id)
select count(*), sum(v.narSize) from closure c join ValidPaths v on v.id = c.id;
-- 128 | 456097800      (1 ms)
```

`nix path-info -S` on the same path reports `456097800`, and `nix path-info -r | wc -l` reports 128. The point is not that the numbers match — of course they match, it is the same table. The point is that Nix's central operation is a two-line [`WITH RECURSIVE`][sqlite-cte] and has been reimplemented in C++ anyway, for the same reason CodeQL compiles QL down to relational algebra rather than shipping a SQL prompt: the traversal is on the hot path of every build, every `nix copy`, and every GC, and it wants to interleave with substituter queries and asynchronous path-info lookups. See [code as a database][code-as-db] for the general version of that argument.

### Garbage collection: roots, mark, sweep, and a lock

The thesis states the model in one paragraph and the implementation has not deviated from it:

> _"Garbage collection in Nix is pretty much like garbage collection in programming languages … There is a pointer graph defined by the references relation, and there is a set of roots. The closure of the set of roots under the references relation is the set of live store objects … The garbage collector therefore has the following phases: Determine the set of root paths. Compute the live paths as the closure of the set of root paths. Delete the dead paths."_
>
> — [thesis][thesis], §5.6

**Roots** come from three places, and the shipped collector reads all three ([`gc.cc`][gc-cc]):

1. **Permanent roots** — symlinks under `/nix/var/nix/gcroots`, including the indirect-root scheme (`gcroots/auto/<sha1-of-path>` pointing at a symlink elsewhere, so deleting your `./result` retires the root on the next run). `addIndirectRoot` is four lines.
2. **Temporary roots** — per-process files under `/nix/var/nix/temproots`, each held under an advisory `fcntl` lock. A process about to create or use a path writes it there first. `findTempRoots` tries to take a _write_ lock on each file: succeeding proves the owning process is gone, so the file is stale and is removed.
3. **Runtime roots** — a scan of `/proc`, which is where the design gets interesting.

**`findRuntimeRootsUnchecked`** ([`local-gc.cc`][local-gc-cc]) iterates every numeric directory under `/proc` and reads, per process: `exe`, `cwd`, every entry in `fd/`, every mapped file in `maps` (matched with a regex against the sixth field), and — the aggressive one — the entire `environ` blob, searched with a regex for anything that looks like a store path:

```cpp
/* src/libstore/local-gc.cc — findRuntimeRootsUnchecked() */
auto storePathRegex = boost::regex(quoteRegexChars(config.storeDir) + R"(/[0-9a-z]+[0-9a-zA-Z\+\-\._\?=]*)");
…
std::filesystem::path mapFile = fmt("/proc/%s/maps", ent->d_name);
…
auto envFile = fmt("/proc/%s/environ", ent->d_name);
```

On non-Linux hosts the same job is done by shelling out to `lsof -n -w -F n`, with a comment recording that this is _"really slow on OS X"_ and disabled under test. Linux additionally reads `/proc/sys/kernel/modprobe`, `fbsplash` and `poweroff_cmd`, because those hold paths the kernel will execute with no process to hold them open.

This is the conservative scan applied a second time, to live memory instead of to files, and the thesis anticipated it as future work: _"A possible extension to root discovery is to automatically use open store files as roots. In the scheme described above, it is possible that a currently executing program is garbage collected."_

**Measured, it is not a rounding error.** On the surveyed machine a single `nix-store --gc --print-roots` snapshot emitted 114,964 root links naming 5,660 distinct store paths. Of those links, **107,672 (93.7%) came from `/proc`**, and the single largest source was not open files but environment blocks:

| Root source          | Root links | Distinct store paths |
| -------------------- | ---------: | -------------------: |
| `/proc/PID/environ`  |     91,153 |                  736 |
| `/proc/PID/maps`     |     13,358 |                  679 |
| `/proc/PID/fd/*`     |      2,529 |                   14 |
| `/proc/PID/exe`      |        630 |                   88 |
| `/proc/sys/kernel/*` |          2 |                    2 |
| `{temp:PID}` files   |      3,181 |                3,181 |
| `gcroots` symlinks   |      4,111 |                1,325 |

**1,164 of the 5,660 distinct roots — 20.6% — were reachable only through `/proc`.** Without the scan, a `nix-store --gc` on that machine would have deleted 1,164 store paths that a running process was using. (The counts drift by tens between invocations on a live machine; every figure in this table comes from one snapshot.)

**Marking** is [`gc.cc`][gc-cc]'s `maybeDeleteReferrersClosure`, and it runs the graph _backwards_. Starting from a candidate, it enqueues the candidate's **referrers**; if any node reached that way is a root, a temp root, or already known alive, the whole visited set is marked alive and the traversal bails. Otherwise every node visited is garbage. Deletion then proceeds in `topoSortPaths` order so a referrer is always invalidated before its reference, which is what preserves the closure invariant mid-sweep — the thesis proves exactly this (Theorem 4, §5.6.3) from the fact that the references graph is acyclic apart from self-references.

**Concurrency** is where Nix's answer is most instructive, and it is three mechanisms, not one:

- **A global GC lock.** The collector takes a _write_ lock on `/nix/var/nix/gc`; every other process takes a _read_ lock before registering a root. Held for the whole run.
- **A socket for roots created during the run.** Because the write lock is held, a concurrent process cannot take the read lock — so `addTempRoot` detects the failure, connects to `gc-socket/socket`, sends the path, and waits for an ack (`assert(c == '1')`). The collector's server thread inserts it into `shared->tempRoots` and the marker re-checks that set both when it first visits a path and again immediately before deleting it, with a `pending` hash-part published under a mutex so the socket handler blocks on exactly the path being deleted.
- **A pre-allocated escape hatch.** `/nix/var/nix/db/reserved` is an 8 MiB file (`gc-reserved-space`, [`local-settings.hh`][local-settings-hh]) deleted at the _start_ of a collection, so the collector can still write to a full disk.

That triple — a lock, a channel for new roots, and a re-check under the lock immediately before the destructive step — is the concurrent-GC design this page's payload section maps onto a relational store.

---

## Format identity and multiplicity

**Multiplicity = 0, and the zero is the finding.**

There is no Nix artifact format. A store object is a directory tree — `libstore` calls it a _file system object_ — containing whatever the build produced: ELF binaries, shell scripts, `.desktop` files, fonts. Nothing is stamped, no magic is added, no header is prepended, no footer appended. `file(1)` on a store object reports what it would have reported anywhere else. Nothing in the kernel, the shell, or the loader dispatches on "this is a Nix thing", because no such bit exists.

The only serialised _format_ Nix owns is the **NAR** (Nix Archive), and it is a transport encoding, not an artifact identity: a canonical, deterministic, uncompressed serialisation of a file system object used for hashing, for copying between stores, and for binary caches. A NAR is never what runs; it is unpacked into a store path first. The catalog's [prefix/suffix/hole tolerance][concepts] vocabulary therefore has no purchase here — there are no bytes to be tolerant _of_, because there is no single byte stream that is the artifact.

That absence is worth reading as a deliberate answer rather than an omission, and it is the sharpest available counterweight to [thesis 3, "the container is a tax"][concepts]. Nix pays **no** container tax: nothing wraps, nothing is stapled, nothing must be parsed twice. It achieves that by moving _all_ of the metadata out of the artifact and into an external relational store. [redbean][ape] pays the tax in ZIP; [SELF][self] abolishes it by making the database the container; Nix abolishes it by making the container _nothing at all_ and keeping the database elsewhere. Three distinct positions, and only the third has 23 years of production evidence behind it.

The cost is stated in the manual, and it is severe:

> _"The inclusion of the store directory path in the full rendered store path means that the full rendered store path is not just derived from the referenced store object itself, but depends on the store that the store object is in. … One cannot copy a store object to a store with a different store directory. Instead, it has to be rebuilt, together with all its dependencies."_
>
> — [`store/store-path.md`][manual-store-path]

A Nix closure is not portable in the sense [APE][ape] is portable. It is portable to any machine that has `/nix/store` at that exact path — which is why the store directory is effectively frozen at `/nix/store` across the entire ecosystem, and why `--store` prefixes and `nix-user-chroot` exist. The digest is a hash _of the store directory string_, so relocating a closure means recomputing every path in it, which means rebuilding.

## Index anchoring and random access

**Out-of-band, with a second, per-object copy in transit.**

The reference graph is not in the store objects. It is in `db.sqlite`, and the store objects have no idea it exists. That places Nix in the fourth row of the catalog's [index-anchoring table][concepts] — the row whose failure mode is "the source moved and the view did not". Nix's mitigation is that the view is _rederivable_: `nix-store --verify --check-contents` re-hashes objects, `--repair` re-fetches broken ones, and the reference relation can in principle be recomputed by rescanning every object for every digest. The thesis explains why nobody does that routinely — full-store rescanning means `scanForReferences` over the entire file system with the candidate set equal to _all_ store paths, and _"since there can be many store paths—millions in large installations—this becomes prohibitively expensive."_

**The index costs about a tenth of a percent.** On the surveyed machine:

| Quantity                             |                                  Value |
| ------------------------------------ | -------------------------------------: |
| Valid store paths                    |                                208,442 |
| Reference edges (`Refs` rows)        |              1,914,130 (9.18 per path) |
| `DerivationOutputs` rows             |                                242,497 |
| Total NAR bytes of all store objects |          344,988,556,624 B (321.3 GiB) |
| `db.sqlite`                          | 371,535,872 B (354.3 MiB) — **0.108%** |
| `db.sqlite` + `-wal`                 | 537,073,384 B (512.2 MiB) — **0.156%** |

A relational index over two million edges costing a sixth of a percent of the data it describes is the number that makes the out-of-band choice defensible, and it is the number to hold against SELF's measured 2–3.5× single-binary b-tree overhead. They are not the same trade: Nix's ratio is small because the _artifacts_ are large and the _index_ is only metadata, whereas SELF's b-tree holds the segment bytes too.

**Random access to a remote closure is per-object, not ranged.** A binary cache publishes one `.narinfo` per store object, named by the object's hash part, and that file carries the edges as a header:

```text
StorePath: /nix/store/n5wkd9frr45pa74if5gpz9j7mifg27fh-foo
NarHash: sha256:09ymwqf5i9q7d4dm7x4pjjcqqj0qrcp5lnznbh42gfsci5hcbqqm
NarSize: 34878
References: g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bar n5wkd9frr45pa74if5gpz9j7mifg27fh-foo
Deriver: g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bar.drv
Sig: asdf:AAAA…
```

So the graph is _replicated into the objects_ at exactly the point where it has to travel, and the shape of that replication is a header-anchored index per node. Computing a remote closure is `O(closure size)` HTTP GETs of ~1 KiB each, walked breadth-first — one round trip per node, no range requests, no batch endpoint. That is markedly worse than what a page-oriented remote database would give you ([range-request access][range-request] develops the alternative), and it is the reason `nix copy` over a high-latency link spends its time in `.narinfo` fetches rather than in NAR transfer. `nix path-info --closure-size` against a binary cache is the same walk, which is why it is slow against `cache.nixos.org` and instant locally.

## Reflexivity and query surface

**Reflexivity = 2: designed-in, external, and not self-directed.**

The _interrogable_ half scores high. The graph is in a SQLite file with a 40-line schema; anyone with read access can ask it anything. The four-line recursive CTE above is not a party trick — it is the actual closure computation, reproduced from outside the tool, with byte-identical results. There is also a first-class CLI surface: `nix path-info --json` (documented against a JSON schema), `nix-store --query --requisites`, `--referrers`, `--referrers-closure`, `--roots`, `--deriver`, `nix why-depends --precise`, and `nix-store --dump-db` / `--load-db` for moving the graph itself. The manual defines `requisites`, `referrers`, and _referrers closure_ as graph operations on the transpose ([`store-object.md`][manual-store-object]), which is unusually careful vocabulary for a package manager.

Three things hold the score at 2 rather than 3.

- **The schema is not a public interface.** `schema.sql` ships with the source and the file is world-readable, but nothing documents it as stable, and the `ca-specific-schema.sql` comment shows the maintainers reserving the right to leave _"many abandoned tables lying around"_ across experimental-feature versions. Compare SELF, where the schema plus a `docs` table travels _inside_ every artifact and is the specification. Nix's index is queryable by accident of implementation, not by contract.
- **No store object can interrogate itself.** A running program has no handle on the graph. It cannot ask "what am I", "what do I depend on", or "who depends on me" without shelling out to `nix`, which needs the daemon or the database. There is no `argv[0]`-shaped self-access story, because there is nothing in the artifact to open. This is exactly the axis [SELF][self] maxes out and Nix declines.
- **Transitive queries are ergonomically fine and semantically subtle.** SQLite's `WITH RECURSIVE` handles the traversal in a millisecond. What it does _not_ tell you is which edge relation you should have traversed — see the next section, where choosing wrong changes the answer by 61%.

The interesting reflexive artifact in the Nix world is not the store object; it is the **derivation**. A `.drv` is itself a store object, is itself in the graph, and describes how to produce other store objects — so the store contains the recipes for its own contents, and `keep-derivations` (default `true`) keeps them alive. On the surveyed machine 242,497 `DerivationOutputs` rows record that provenance. That is [embedded provenance][provenance] achieved by putting the provenance _in the store as another object_ rather than _in the artifact as a note section_, and it is the cleanest example in the catalog of the out-of-band answer to a problem everyone else solves in-band.

## Closure, dedup, and size model

**Closure = 3. This is the axis the subject defines, and the catalog borrowed its vocabulary from here.**

The trade the whole cluster exists to quantify is: _if every root ships its own private copy of its dependencies, how much do you pay?_ [SELF][self] answers it once, at userland scale, with the figures this page was asked to cross-link — **611.9 MiB** for a 723-executable userland packed as one closure database, against **5.53 GiB** if each root carried private copies AppImage-style: a **9.0×** amplification. That number is the whole argument for a shared store, and it should be checkable against a real one.

It is. Measured on the surveyed machine, over the 2,384 non-derivation GC roots:

| Model                                          |        Store objects |         NAR bytes |          Size |
| ---------------------------------------------- | -------------------: | ----------------: | ------------: |
| **Private closure per root** (sum of closures) | — (multiply-counted) | 2,353,365,670,472 |  **2.14 TiB** |
| **Shared store** (union of the same closures)  |               23,855 |   295,735,853,080 | **275.4 GiB** |
| Amplification                                  |                      |                   |     **7.96×** |

A smaller, randomly sampled arm of the same experiment (200 roots, 6,443 objects) gives 147.6 GiB against 66.0 GiB — **2.24×** — which is the honest caveat: the amplification factor is a function of how many roots share how much, and it grows with the number of roots. It is 2.2× at 200 roots and 8.0× at 2,384, and SELF's 9.0× at 723 executables is entirely consistent with both. **The self-containment tax is superlinear in root count and there is no single number for it** — which is precisely why per-root self-containment looks cheap in a demo and ruinous in a distribution.

Nix's dedup granularity is the store path, exactly as SELF's `objects.path UNIQUE` is. A library needed by fifty roots is one store object, not fifty. What Nix has that SELF does not is a **second, finer dedup layer underneath**: `optimise-store.cc` hard-links identical _files_ (not paths) into `/nix/store/.links/<nix32-sha256-of-contents>`, so two store paths that differ in one file share the other thousand at the inode level. That layer is content-addressed at file granularity and is off by default (`auto-optimise-store`); `nix store optimise` runs it on demand. It has its own collector, and it is a _different discipline_: the `.links` sweep in [`gc.cc`][gc-cc] deletes any link whose `st_nlink == 1`, which is reference counting, not tracing. Two garbage collectors, two algorithms, one store — a point [content-addressed chunking][chunking] develops, since casync/`zstd:chunked` push the same idea below file granularity to sub-file chunks.

**What the closure does _not_ include is a policy question, and it moves the answer enormously.** `computeFSClosure` takes `includeOutputs` and `includeDerivers` flags, and the collector sets them from `keep-outputs` (default `false`) and `keep-derivations` (default `true`). Measured against the same 5,660 roots on the surveyed store, with the WAL applied:

| Edge relation traversed       | Live paths | Query time |
| ----------------------------- | ---------: | ---------: |
| `references` only             |     77,606 |     0.29 s |
| `references` ∪ `deriver`      |    197,429 |     1.11 s |
| `nix-store --gc --print-live` |    197,457 |          — |

The 28-path gap between the last two rows is drift on a live store between the two measurements. The gap between the _first_ two rows is not drift: **119,823 store paths — 61% of the live set — are alive solely because `keep-derivations` is on.** Two-thirds of that store is build recipes and their inputs, retained for traceability. The reachability question "what is live" has no answer until someone names the edge relation, and the default relation is not the one the glossary defines as _closure_.

## Mutability, dispatch, and trust

**Mutability = 1.** Store objects are immutable by construction and by permission bits: the manual states it as a rule (_"Once created, they do not change nor can any store object they reference be changed"_), the daemon canonicalises permissions to read-only on registration, and the whole model depends on it — a mutable store object would invalidate the digest that names it and every scan result derived from it. What mutates is the _store as a collection_ (objects are added and collected) and the metadata database. There is no self-modifying artifact anywhere in the design; this is the opposite pole from [SELF's `self-httpd`][self] and from [image-based systems][image-based].

That immutability is what buys the trust story, and it is the cleanest in the catalog:

- **Signatures cover a stable object.** `ValidPaths.sigs` is a space-separated column of `key-name:base64` signatures over a canonical fingerprint of the object's path, NAR hash, size and references; `ultimate` marks paths built locally and therefore trusted without one. Because the bytes never change, a signature over them stays valid forever — the exact property [SELF cannot have][self], where a no-op `VACUUM` invalidates any byte-hash attestation and the server commits on every request. [Embedded provenance][provenance] is the general treatment.
- **`ca` records an _assertion_.** The schema comment reads _"if not null, an assertion that the path is content-addressed"_, which is the honest description: for an input-addressed path the name proves nothing about the content, so trust is delegated to whoever signed it. Content-addressing would make the name self-verifying, which is the prize behind `ca-derivations` — still gated as an experimental feature at 2.36, with its tracking milestone recorded in [`experimental-features.cc`][xp-cc].
- **Nothing dispatches on the bytes.** There is no `binfmt_misc` registration, no interpreter, no magic. The nearest thing to dispatch is `ld.so` following an absolute store path baked into `RUNPATH` at link time — which is [dynamic linking][ld] doing its ordinary job, with the store's contribution being that the path is exact rather than nominal. The catalog's "who decides what the file is" question ([concepts][concepts]) answers **consumer**, and the reason it is not a hazard here is that there is no superposition for two dispatchers to disagree about. Compare [parser differentials][differentials], where the entire failure class comes from exactly that disagreement.

The threat surface that _is_ real is the one the design imports from conservative GC. A store object's references are whatever an attacker-controlled build wrote into it. Writing an unrelated digest into a log file creates an edge and pins an object; that is only a denial-of-service-shaped nuisance, and the thesis flags the general form in a footnote (_"a system using conservative garbage collection can be vulnerable to denial-of-service attacks if an attacker has an opportunity to feed it data … that contains many bit patterns that might be misidentified as pointers"_). The sharper direction is **pointer hiding**: a build that encodes a genuine runtime dependency in a form the scanner cannot see produces a closure that is _missing_ an object, and the failure appears at run time on a different machine, after the object has been collected. Nix has no defence against this beyond empiricism. `unsafe-discard-references` makes it available as a setting.

**Page sharing is a non-issue here, and that is itself informative.** Store objects are ordinary files. Two processes running the same store path `mmap` the same inode and share text exactly as they would anywhere, and the `.links` hard-link layer makes even _different_ store paths share physical pages for identical files. Nix pays none of [the cost that decides whether SELF is viable][self] — because it never took the bytes out of the file system. [Thesis 4, `mmap` is the load-bearing constraint][concepts], is satisfied here trivially and by declining to make the move that puts it at risk.

---

## A SELF closure database is a store, so it needs a GC

The source outline asks the question and this page owes it the answer: _"A SELF closure database is a store, so it needs a GC. Nix's mark-and-sweep over `needs` edges becomes a recursive query plus `DELETE` plus `VACUUM`. What are the roots, and what does a concurrent GC look like against a database somebody is executing from?"_ The Nix design maps onto it almost line for line, and every place the mapping breaks is a real problem.

### The roots, when the artifacts are rows

`closure.py`'s `CLOSURE_SCHEMA` has an `objects` table with an `is_root` column and a `needs` table carrying `object_id → resolved_path` ([SELF deep-dive][self]). The naive answer — _roots are the `is_root = 1` rows_ — corresponds to Nix's **permanent roots** only, and Nix's own root set shows that is a third of the story at best:

| Nix root class          | SELF analogue                                                                        | Available?                   |
| ----------------------- | ------------------------------------------------------------------------------------ | ---------------------------- |
| `gcroots` symlinks      | `objects.is_root = 1`                                                                | Yes — one column             |
| Temporary roots         | A `temp_roots(object_id, session)` table written before use, in the same transaction | Yes, and it is the easy part |
| Runtime roots (`/proc`) | "which rows is a running process executing out of?"                                  | **No equivalent exists**     |

The third row is the one that matters, and it is the sharpest thing this page has to say to the SELF design. Nix's runtime-root scan works because a store object is a _file_ and the kernel publishes, per process, which files it has open, which files it has mapped, and what strings are in its environment. Every one of those channels is a file path, and a file path is a store-object identity. Once segments are rows, **none of the three channels report anything**:

- `/proc/PID/maps` names the backing file of each mapping. A SELF process in `native` mode has `MAP_ANONYMOUS` mappings whose bytes were `memcpy`'d out of b-tree pages — the maps file says `[anon]`, not which rows they came from. In `memfd` mode it names `/memfd:…`, a file that no longer exists anywhere.
- `/proc/PID/exe` names the interpreter or a `memfd`, not the database. This is the same `argv[0]` fragility [SELF already documents][self], surfacing in a second place.
- `/proc/PID/fd/*` would name the `.self` file _if the process kept it open_ — but `self-exec` deliberately closes its SQLite connection before jumping, precisely so nothing holds the file open. The one channel that could have worked was closed for an unrelated good reason.

So the honest statement is: **a SELF store cannot discover its own runtime roots by any mechanism Nix uses.** Two designs are available and both cost something.

1. **In-band registration.** A running program registers itself: `INSERT INTO temp_roots(object_id, pid) …` at startup, holding the row under an advisory lock or a session that the collector can probe for liveness. This is Nix's `temproots` mechanism with the file replaced by a row, and it is the design Nix actually landed on for builds. It requires cooperation from every executing process — which SELF can arrange, because it controls the loader.
2. **A file-descriptor discipline.** Keep the database open read-only for the process lifetime, so `/proc/PID/fd/*` names it and the _existing_ Nix scan finds it. That gets you "the database is in use" but not "these rows are in use" — the granularity collapses from per-object to per-store, and the whole store becomes one root.

Measured on Nix, option 2's granularity loss would be catastrophic in the other direction, and option 1's coverage gap is quantified above: **20.6% of live roots on a real machine were reachable only through the runtime scan.** A SELF GC with in-band registration only is correct exactly as long as every executing process registered. A SELF GC with no runtime roots at all is a program that deletes running programs.

### What the recursive query, `DELETE` and `VACUUM` actually do

The mark phase is genuinely a four-line CTE and genuinely fast — 1 ms for a 128-object closure, 1.1 s for a full 197,429-path mark over 1.9 million edges on the measurements above. That part of the outline's guess is correct and this page confirms it with numbers. Three things it gets wrong or leaves out:

- **`DELETE` alone is not the sweep; the ordering is.** Nix deletes in `topoSortPaths` order specifically so that a referrer is invalidated before its reference, preserving the closure invariant at every intermediate state — the thesis proves it (Theorem 4) and the proof depends on the reference graph being acyclic apart from self-references. In SQL the same guarantee is available _for free and better_: declare `needs.resolved_path REFERENCES objects(path) ON DELETE RESTRICT`, turn on `PRAGMA foreign_keys`, and the engine refuses any deletion that would break the invariant, exactly as [`schema.sql`][schema-sql] does for Nix's `Refs`. A store whose closure property is a foreign-key constraint cannot be left inconsistent by a crashed collector. This is the single largest thing SELF's schema should copy from Nix's, and it is one line.
- **Self-references need the trigger.** `DeleteSelfRefs` exists because `ON DELETE RESTRICT` and a `(N, N)` row are incompatible, and a SELF object containing its own `RUNPATH` produces exactly that row. Copy the trigger too.
- **`VACUUM` is not the space reclaim you want, and Nix's own source says so.** [`gc.cc`][gc-cc] ends with:

  ```cpp
  /* While we're at it, vacuum the database. */
  // if (options.action == GCOptions::gcDeleteDead) vacuumDB();
  ```

  The call is **commented out**. Nix's `VACUUM` would rewrite only the metadata database (354.3 MiB on the surveyed machine), would not touch a single store object, and it is _still_ not run after a collection — because rewriting the whole database to reclaim free pages is not worth the I/O when the pages will be reused. In a SELF closure database `VACUUM` rewrites **the segments too**: reclaiming space after `DELETE FROM segments` means copying every remaining program's bytes through a fresh file. For the 611.9 MiB userland that is a full rewrite of the userland to reclaim whatever the dead objects held. `DELETE` marks pages free and SQLite reuses them; `VACUUM` is a whole-store compaction and should be an explicit, offline operation, not the tail of a GC.

### A concurrent GC against a database you are executing from

Nix's answer is a lock, a channel, and a re-check. Transposed:

| Nix mechanism                                    | SELF transposition                                                                                                | Status                                                                   |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Write lock on `/nix/var/nix/gc`                  | `BEGIN IMMEDIATE` / a `gc_lock` row, or WAL's single-writer discipline                                            | Free — SQLite already serialises writers                                 |
| Unix socket for roots created mid-run            | A `temp_roots` table the collector re-reads inside its own transaction                                            | Free, and _better_ — the "channel" and the "database" are the same thing |
| Re-check `tempRoots` immediately before deleting | Re-check `temp_roots` in the same transaction as the `DELETE`                                                     | Free, and atomic rather than mutex-guarded                               |
| `/proc` scan for live processes                  | **nothing**                                                                                                       | The gap above                                                            |
| `reserved` 8 MiB escape hatch for a full disk    | SQLite needs journal/WAL space to commit a large `DELETE`; the same reservation is needed and nothing provides it | Unbuilt                                                                  |

The first three rows are the good news, and they are a genuine structural win for the relational design: Nix needs a lock file, a Unix socket, a server thread, a `poll` loop, per-connection threads, a condition variable and a `pending` hash-part published under a mutex — roughly 200 lines of [`gc.cc`][gc-cc] — to do what one `BEGIN IMMEDIATE` and a table read give you for free. Nix built an ad-hoc transaction manager because its store is a file system; SELF's store already has one.

The bad news is concentrated and it is the same as everywhere else in the SELF design: **a reader executing out of the database is invisible to it.** SQLite's own concurrency control protects the _database_, not the _program_. In WAL mode a reader holds a snapshot and a writer proceeds concurrently, so the collector can `DELETE FROM segments` while a loader is mid-way through `sqlite3_blob_read` on those very rows — and both will succeed, because the reader is reading a snapshot. The program finishes loading. It is the _next_ execution that finds the row gone. Nix has the same class of hazard and closes it with the `/proc` scan; SELF has no channel to close it with.

Worse, the WAL that makes that concurrency work is the thing that breaks the single-file property: [`self-httpd`'s measured journal-mode trade][self] already shows `server-wal` and `server-shm` sitting next to the executable while a connection is open, and a collector running concurrently with executions guarantees such a connection exists. The one-file store and the concurrent collector are in tension, and the resolution is the same shape as the [`mmap`-versus-`VACUUM` opposition][self] the format already faces: you may have any two of _single file_, _concurrent GC_, and _live execution_.

> [!IMPORTANT]
> The general lesson generalises past SELF. Nix's `findRuntimeRootsUnchecked` works because the _operating system_ maintains, for free and for every process, a reverse index from process to the objects it is using — and that index is expressed in the same namespace the store uses (paths). **Any design that moves artifacts out of the file-path namespace loses that index and must rebuild it by hand.** That is a cost of the move nobody prices in advance, and it is invisible until the first collector deletes a running program. It applies equally to [image-based systems][image-based], to [Plan 9's namespaces][plan9] (where the answer is better, because everything including the process's own view is a name), and to any [content-addressed chunk store][chunking] whose chunks are not files.

---

## Strengths

- **Exact dependencies with no declaration.** The edges cannot drift from the artifact, because they _are_ the artifact's bytes. No control file to get wrong, no `Depends:` to forget, no version range to over- or under-constrain. The thesis's claim that this is what makes complete deployment possible has held for 23 years.
- **Format independence, permanently.** The scanner knows about ASCII and Nix32 and nothing else. It found dependencies in ELF in 2003 and finds them in Wasm, Go binaries, `.pyc` files, and JSON manifests today with zero changes, because none of those formats were ever the subject.
- **The closure property is a database constraint, not a convention.** `ON DELETE RESTRICT` plus `PRAGMA foreign_keys = 1` means the store cannot be left inconsistent by a crashed collector.
- **The index is cheap.** 0.108% of store bytes for a two-million-edge relational graph over 208,442 objects.
- **Sharing is measured and large.** 7.96× amplification avoided at 2,384 roots on a real machine, independently reproducing the shape of [SELF's 9.0× figure][self] and confirming that the factor grows with root count.
- **Immutability makes signing trivially correct.** A signature over a store object stays valid forever, which no self-mutating artifact in this catalog can say.
- **Page sharing and demand paging are free**, because the artifacts never left the file system.
- **The collector accounts for live processes.** 20.6% of roots on the surveyed machine existed only because of the `/proc` scan — a mechanism most package managers do not have at all.

## Weaknesses

- **The scan is unsound and always will be.** UTF-16, compression, split paths, or any encoding the scanner does not recognise hides a real edge. The mitigation is empirical, and `unsafe-discard-references` makes it a supported setting.
- **The scan is also imprecise.** A coincidental digest in a log file is an edge that pins an object forever, and there is no way to say "that one is not real".
- **Store paths are not relocatable.** The digest hashes the store directory string, so a closure built for `/nix/store` cannot be moved to `/opt/nix` without rebuilding it. Reach is bought by ecosystem-wide agreement on one absolute path.
- **Input-addressing means the name proves nothing about the content**, so trust is delegated entirely to signatures. `ca-derivations` has been experimental for years and remains so at 2.36.
- **The schema is not a contract.** `db.sqlite` is queryable but undocumented as an interface, and `ca-specific-schema.sql` explicitly reserves the right to leave abandoned tables behind.
- **Remote closures cost one HTTP round trip per node.** `.narinfo` fetches, not range requests; latency-bound rather than bandwidth-bound.
- **"Live" depends on a policy that changes the answer by 61%.** The default `keep-derivations` traversal marks 197,429 paths live where the `references` relation alone marks 77,606.
- **Nothing in a store object can interrogate the store.** No self-access, no schema in the artifact, no reflexivity at run time.
- **The runtime-root scan is expensive and platform-specific.** Reading `environ`, `maps`, `exe` and every `fd` for every process, plus a regex per line of `maps`; off Linux it shells out to `lsof`, with a source comment recording that this is slow enough to break a test.

---

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                                                              | Trade-off                                                                                                                            |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Discover references by scanning outputs for input digests             | Format-independent and cannot drift from the artifact; works for every file type ever invented without changes                         | Conservative in both directions — false positives pin objects, pointer hiding loses real edges, and neither is detectable            |
| Name paths by a hash of the **inputs**, not of the output             | The path is known before the build runs, so builders can bake it in and self-references are expressible                                | The name says nothing about the content; identical outputs from different recipes are stored twice; trust needs a separate signature |
| Include the store directory in the digest                             | Prevents one machine's paths colliding with another's and makes the store location part of the identity                                | Closures are not relocatable; the ecosystem is frozen at `/nix/store`                                                                |
| Hold the reference graph out-of-band in SQLite                        | Store objects stay ordinary files — no container tax, no format, `mmap` and page sharing for free                                      | The index is a materialized view that can go stale; the graph is unrecoverable without an expensive full rescan                      |
| Make the closure property a foreign-key constraint                    | The database refuses an inconsistent state, so a crashed collector cannot leave dangling references                                    | Needs a trigger to special-case self-references, and `PRAGMA foreign_keys` must actually be on                                       |
| Replicate the graph per-object as `.narinfo` headers in binary caches | Each node carries its own edges, so a remote closure is walkable with no server-side query engine                                      | One HTTP round trip per node; a wide closure over a high-latency link is latency-bound                                               |
| Tracing GC for store paths, reference counting for the `.links` layer | The path graph is cyclic-free but arbitrary; hard links have an exact kernel-maintained count, so `st_nlink == 1` is a complete answer | Two collectors with different correctness arguments in one store                                                                     |
| Scan `/proc` for runtime roots                                        | A running program must not be collected, and the kernel already publishes the reverse index                                            | Expensive, Linux-specific, and it reads every process's environment block — which is also 93% of where the roots come from           |
| A global write lock plus a socket for roots created mid-collection    | Solves the thesis's liveness problem — long-running builds no longer block the collector from starting                                 | ~200 lines of ad-hoc transaction management (server thread, `poll` loop, condition variable) that a database would have given free   |
| Do not `VACUUM` after a collection (the call is commented out)        | Rewriting the whole database to reclaim free pages is not worth the I/O when the pages will be reused                                  | The metadata file grows monotonically in practice; the WAL was 157.9 MiB on the surveyed machine                                     |
| Store objects immutable, permissions canonicalised on registration    | Digests stay true, signatures stay valid forever, and page sharing is unconditional                                                    | No artifact-as-state-store; everything mutable lives outside the store, which is a whole separate problem for stateful services      |

---

## Sources

- [NixOS/nix — repository][repo], read at [`46bc30b6`][repo] (2026-08-26, `.version` `2.36.0`)
- [`src/libstore/schema.sql`][schema-sql] — `ValidPaths`, `Refs`, the `on delete restrict` / `on delete cascade` pair, the `DeleteSelfRefs` trigger, `DerivationOutputs`
- [`src/libstore/ca-specific-schema.sql`][ca-schema-sql] — the `BuildTraceV3` extension and the "abandoned tables" comment
- [`src/libstore/references.cc`][references-cc] — `search()`, `RefScanSink`, the chunk-boundary tail, `HashModuloSink`'s self-reference zeroing
- [`src/libstore/path-references.cc`][path-refs-cc] — `scanForReferences`, the digest→path `backMap`, `scanForReferencesDeep` for `why-depends --precise`
- [`src/libstore/misc.cc`][misc-cc] — `Store::computeFSClosure` and its `flipDirection` / `includeOutputs` / `includeDerivers` knobs
- [`src/libstore/gc.cc`][gc-cc] — the GC lock, `addTempRoot`, the roots socket and server thread, `maybeDeleteReferrersClosure`, topological deletion, the `.links` sweep, the commented-out `vacuumDB()`
- [`src/libstore/local-gc.cc`][local-gc-cc] — `findRuntimeRootsUnchecked`: `/proc/PID/{exe,cwd,fd,maps,environ}`, the `lsof` fallback, the kernel `modprobe`/`poweroff_cmd` roots
- [`src/libstore/local-store.cc`][local-store-cc] — prepared statements, `queryReferrers`, `invalidatePath`, `invalidatePathChecked` / `PathInUse`, `dbDir`, `reservedPath`
- [`src/libstore/sqlite.cc`][sqlite-cc] — `sqlite3_open_v2` with the `immutable=` URI, the `unix-dotfile` VFS, `pragma foreign_keys = 1`, the one-hour busy timeout
- [`src/libstore/optimise-store.cc`][optimise-cc] — `/nix/store/.links` hard-link dedup at file granularity
- [`src/libstore/include/nix/store/path.hh`][path-hh] (`HashLen = 32`) · [`local-settings.hh`][local-settings-hh] (`gc-reserved-space`, `keep-outputs`, `keep-derivations`)
- [`src/nix/path-info.cc`][path-info-cc] — `closureSize` and `closureDownloadSize`
- [Nix manual — Store Path][manual-store-path] · [Store Object][manual-store-object] · [Building][building-md] · [Content-Addressing Store Objects][ca-md] · [Complete Store Path Calculation][protocols-store-path] · [glossary][manual-glossary] · [`.narinfo` format][narinfo-md] · [`nix-store --gc`][manual-gc] · [`nix path-info`][manual-path-info] · [`nix why-depends`][manual-why-depends] · [experimental features][manual-xp]
- [Eelco Dolstra, _The Purely Functional Software Deployment Model_][thesis], Utrecht University, 2006-01-18 — §2.3 (hash scanning), §3.4 (conservative GC and pointer hiding), §5.6 (roots, live paths, stop-the-world and concurrent collection, Theorem 4)
- [SQLite — `WITH` clause / recursive CTEs][sqlite-cte] · [`VACUUM`][sqlite-vacuum] · [Write-Ahead Logging][sqlite-wal]
- Measurements taken 2026-08-26 on a NixOS host with `nix` 2.32.8, against a live `/nix/store`: `nix-store --gc --print-roots` / `--print-live` / `--print-dead`, `nix path-info -S` / `-r`, and `WITH RECURSIVE` queries against a WAL-consistent copy of `db.sqlite`
- Related in this tree: [SELF / selfdb][self] · [redbean / Cosmopolitan / APE][ape] · [content-addressed chunking][chunking] · [code as a database][code-as-db] · [dynamic linking][ld] · [range-request access][range-request] · [SQLite as an application file format][sqlite-app] · [the VFS as substrate][sqlite-vfs] · [image-based systems][image-based] · [Plan 9 namespaces][plan9] · [embedded provenance][provenance] · [parser differentials][differentials] · [measurement][measurement] · [open questions][open-questions] · [comparison][comparison] · [concepts][concepts] · [umbrella][index]

<!-- References -->

[repo]: https://github.com/NixOS/nix/tree/46bc30b68293bd82437743c3eef72363d19563d9
[copying]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/COPYING
[schema-sql]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/schema.sql
[ca-schema-sql]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/ca-specific-schema.sql
[references-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/references.cc
[path-refs-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/path-references.cc
[misc-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/misc.cc
[gc-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/gc.cc
[local-gc-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/local-gc.cc
[local-store-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/local-store.cc
[sqlite-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/sqlite.cc
[optimise-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/optimise-store.cc
[path-hh]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/include/nix/store/path.hh
[local-settings-hh]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libstore/include/nix/store/local-settings.hh
[path-info-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/nix/path-info.cc
[xp-cc]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/src/libutil/experimental-features.cc
[building-md]: https://nix.dev/manual/nix/2.32/store/building
[ca-md]: https://nix.dev/manual/nix/2.32/store/store-object/content-address
[narinfo-md]: https://github.com/NixOS/nix/blob/46bc30b68293bd82437743c3eef72363d19563d9/doc/manual/source/protocols/binary-cache/narinfo.md
[manual-store]: https://nix.dev/manual/nix/2.32/store/
[manual-store-path]: https://nix.dev/manual/nix/2.32/store/store-path
[manual-store-object]: https://nix.dev/manual/nix/2.32/store/store-object
[protocols-store-path]: https://nix.dev/manual/nix/2.32/protocols/store-path
[manual-glossary]: https://nix.dev/manual/nix/2.32/glossary.html
[manual-gc]: https://nix.dev/manual/nix/2.32/command-ref/nix-store/gc
[manual-path-info]: https://nix.dev/manual/nix/2.32/command-ref/new-cli/nix3-path-info
[manual-why-depends]: https://nix.dev/manual/nix/2.32/command-ref/new-cli/nix3-why-depends
[manual-xp]: https://nix.dev/manual/nix/2.32/development/experimental-features
[thesis]: https://edolstra.github.io/pubs/phd-thesis.pdf
[sqlite-cte]: https://sqlite.org/lang_with.html
[sqlite-vacuum]: https://sqlite.org/lang_vacuum.html
[sqlite-wal]: https://sqlite.org/wal.html
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[chunking]: ./content-addressed-chunking.md
[code-as-db]: ./code-as-database.md
[ld]: ./dynamic-linking.md
[range-request]: ./range-request-access.md
[sqlite-app]: ./sqlite-application-file-format.md
[sqlite-vfs]: ./sqlite-vfs-substrate.md
[image-based]: ./image-based-systems.md
[plan9]: ./plan9-namespaces.md
[provenance]: ./embedded-provenance.md
[differentials]: ./parser-differentials.md
[measurement]: ./measurement.md
[open-questions]: ./open-questions.md
[comparison]: ./comparison.md
[concepts]: ./concepts.md
[index]: ./index.md
[app-packaging]: ../application-packaging/index.md
