# Consumption over range requests (HTTP access pattern · four ecosystems)

The access pattern that turns a footer index or a b-tree root into a remote query surface: `Range: bytes=…`, a `206 Partial Content` response, and an artifact that is read but never downloaded.

| Field           | Value                                                                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Access pattern + protocol feature, surveyed through four implementations (a query engine, a browser VFS, a registry API, a symbol server)                                                 |
| Language        | C++ (DuckDB `httpfs`), TypeScript + Emscripten (`sql.js-httpvfs`), Go/spec prose (OCI distribution), C (`debuginfod`)                                                                     |
| License         | MIT (DuckDB, `sql.js-httpvfs`) · Apache-2.0 (OCI distribution-spec) · GPL-3.0-or-later (elfutils `debuginfod`)                                                                            |
| Repository      | [duckdb/duckdb][duckdb-repo] · [duckdb/duckdb-httpfs][httpfs-repo] · [phiresky/sql.js-httpvfs][httpvfs-repo] · [opencontainers/distribution-spec][oci-repo]                               |
| Documentation   | [RFC 9110 §14 — Range Requests][rfc-range] · [`debuginfod(8)`][debuginfod-man] · [phiresky, "Hosting SQLite databases on GitHub Pages"][phiresky-post]                                    |
| First release   | HTTP byte ranges standardised in RFC 2068 (January 1997); `sql.js-httpvfs` and DuckDB `httpfs` both 2021; OCI distribution-spec v1.0 2021-05-04; `debuginfod` in elfutils 0.178 (2019-12) |
| Axis profile    | Multiplicity **0** / Reflexivity **2** / Closure **1** / Mutability **0**                                                                                                                 |
| Index anchoring | **footer** for Parquet and ZIP, **header-plus-b-tree** for SQLite, **out-of-band** for `debuginfod` — the access layer is indifferent, the round-trip count is not                        |
| Dispatch owner  | **consumer** — the client library decides what the bytes are and which of them it needs; no kernel, shell, or loader is involved                                                          |

> **Latest revisions surveyed:** `duckdb/duckdb` [`d9958734`][duckdb-repo] (2026-08-26) · `duckdb/duckdb-httpfs` [`c942cee6`][httpfs-repo] (2026-08-20) · `phiresky/sql.js-httpvfs` [`c64536d2`][httpvfs-repo] (2023-03-02, npm `0.8.12`) · `opencontainers/distribution-spec` [`fee21197`][oci-repo] (2026-07-30) · elfutils `debuginfod` man pages at `HEAD`. **Platform:** any HTTP/1.1 or later origin that honours `Range`; `sql.js-httpvfs` additionally requires WebAssembly and a dedicated Worker.

---

## Overview

### What it solves

[Footer-indexed formats][footer-indexed] and SQLite both answer the same question locally — _which bytes do I actually need?_ — and answer it by reading a small, self-locating index first. That property is worth almost nothing on a local disk, where the page cache and readahead have already made a full read cheap. It becomes the entire design when the file is on the other side of a network.

The pattern is: fetch the index with one or two requests, plan the read from it, fetch only the byte ranges the plan named. What travels is not the artifact but an answer computed _about_ the artifact. The four systems surveyed here instantiate it at four different layers:

| System           | The artifact             | The index fetched first                            | What a query pulls                                      |
| ---------------- | ------------------------ | -------------------------------------------------- | ------------------------------------------------------- |
| DuckDB `httpfs`  | a remote Parquet file    | the 8-byte magic + footer length, then the footer  | the column chunks the projection and predicates survive |
| `sql.js-httpvfs` | a remote SQLite database | page 1 (header + `sqlite_schema` root)             | the b-tree pages the query descends through             |
| an OCI registry  | an image                 | the manifest, by digest or tag                     | the layer blobs the manifest names and the client lacks |
| `debuginfod`     | a debuginfo file         | _nothing client-side_ — the server holds the index | one file, or with `/section`, one ELF section           |

The last row is deliberately the odd one out and is the page's control case: `debuginfod` reaches the same end — "do not transfer the whole file" — by moving the index and the slicing to the _server_, so the client makes exactly one request and never speaks `Range` at all. Comparing it against the other three is the cleanest available way to see what client-side ranged access actually costs.

### Design philosophy

The governing fact is that **round trips, not bytes, are the unit of cost**, and the clearest statement of it in any of the surveyed sources is a code comment in DuckDB's Parquet reader, sitting above the decision to over-fetch on purpose ([`extension/parquet/parquet_reader.cpp`][parquet-reader]):

> ```cpp
> // We have to do two reads here:
> // 1. The 8 bytes from the back to check if it's a Parquet file and the footer size
> // 2. The footer (after getting the size)
> // For local reads this doesn't matter much, but for remote reads this means two round trips,
> // which is especially bad for small Parquet files where the read cost is mostly round trips.
> // So, we prefetch more, to hopefully save a round trip.
> ```

`sql.js-httpvfs` states the same trade from the opposite end, as a tuning problem rather than a constant ([phiresky's post][phiresky-post]):

> _"Since fetching data via HTTP has a pretty large overhead, we need to fetch data in chunks and find some balance between the number of requests and the used bandwidth."_

And RFC 9110 is careful that none of this is guaranteed by the protocol ([§14.2][rfc-range]):

> _"A server MAY ignore the Range header field. However, origin servers and intermediate caches ought to support byte ranges when possible, since they support efficient recovery from partially failed transfers and partial retrieval of large representations."_

That `MAY` is load-bearing for this catalog: an artifact's suitability for ranged access is not a property of the artifact. It is a property of the artifact _and_ the origin serving it, and every serious client below carries a fallback path for the case where the origin declines.

---

## How it works

### The protocol surface, precisely

[RFC 9110][rfc-range] defines range requests as "an OPTIONAL feature of HTTP, designed so that recipients not implementing this feature (or not supporting it for the target resource) can respond as if it is a normal GET request without impacting interoperability." Four pieces matter here:

| Element                     | Section        | What it does                                                                                                                                                    |
| --------------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Range: bytes=first-last`   | §14.1.2, §14.2 | Requests a subrange. `bytes=-500` is a _suffix range_ — the final 500 bytes — which is how a footer is found                                                    |
| `Accept-Ranges: bytes`      | §14.3          | Advertises support. Advisory only: "A client MAY generate range requests regardless of having received an `Accept-Ranges` field"                                |
| `206 Partial Content`       | §15.3.7        | The success code. A `200` in reply to a `Range` request means the server ignored it and sent everything                                                         |
| `416 Range Not Satisfiable` | §15.5.17       | Rejects the range set, _including_ "because the client has requested an excessive number of small or overlapping ranges (a potential denial of service attack)" |

Two consequences that shape every client below:

- **The suffix range is what makes footer anchoring work remotely.** `bytes=-8` retrieves a Parquet file's trailing magic and footer length without the client knowing the file's size; `bytes=-65557` is the equivalent scan window for a ZIP `EOCD` record. See [footer-indexed formats][footer-indexed] and [ZIP parasitism][zip] for what those footers contain.
- **Multi-range requests exist and are unusable in practice.** RFC 9110 permits `bytes=0-999, 4500-5499, -1000`, answered as a `multipart/byteranges` body — which would collapse a whole read plan into one round trip. None of the four systems surveyed here emits one. The §15.5.17 DoS carve-out is the reason origins are entitled to refuse, and the parsing cost of `multipart/byteranges` is the reason clients do not bother. The pattern is therefore _one range per request_, and the round-trip count is the read plan's length.

### `sql.js-httpvfs`: a SQLite VFS whose disk is `206` responses

The implementation is a single class, `LazyUint8Array` in [`src/lazyFile.ts`][lazyfile], substituted for an Emscripten filesystem node's backing store. SQLite believes it is calling `read(fd, buf, len, off)`; the node's `stream_ops.read` forwards to `copyInto`, which slices the request into fixed-size chunks and fetches any chunk it does not already hold:

```ts
// src/lazyFile.ts — copyInto()
const chunkOffset = idx % this.chunkSize;
const chunkNum = (idx / this.chunkSize) | 0;
const wantedSize = Math.min(this.chunkSize, end - idx);
let inChunk = this.getChunk(chunkNum);
```

`getChunk` is where the interesting behaviour lives. The fetch is a **synchronous** `XMLHttpRequest` — `xhr.open("GET", url, false)` — which is why the whole thing must run in a dedicated Worker, and which means every page SQLite reads is a blocking network stall on that thread.

**The read-ahead heuristic.** Rather than fetching one chunk, `getChunk` consults up to three _virtual read heads_, each remembering a start chunk and a doubling `speed`:

```ts
// src/lazyFile.ts — moveReadHead()
const fetchStartChunkNum = head.startChunk + head.speed;
const newSpeed = Math.min(this.maxSpeed, head.speed * 2);
const wantedIsInNextFetchOfHead =
  wantedChunkNum >= fetchStartChunkNum &&
  wantedChunkNum < fetchStartChunkNum + newSpeed;
```

If the wanted chunk falls inside a head's _next_ projected fetch, that head's request size doubles and the head advances; otherwise a new head is created and the least-recently-used one is evicted (`maxReadHeads` defaults to 3). `maxSpeed` is `maxReadSpeed / chunkSize` with `maxReadSpeed` defaulting to 5 MiB, so a sequential scan ramps `1 → 2 → 4 → … → 5 MiB` per request. The author's summary of the effect ([phiresky's post][phiresky-post]) is the sentence to keep:

> _"Index scans or table scans reading more than a few KiB of data will only cause a number of requests that is logarithmic in the total byte length of the scan."_

Three heads rather than one is not an arbitrary constant: a b-tree descent interleaved with a table-row fetch is two concurrent sequential-ish streams, and a merge join is three. The heuristic is shaped to the access pattern SQLite actually produces.

**Chunked mode.** [`create_db.sh`][create-db] splits the database into 10 MiB files and writes a JSON config; the `rangeMapper` in [`src/sqlite.worker.ts`][worker] maps an absolute offset onto `(file, offset)` so the same code path serves both a single URL with `Range` and a directory of static chunks. The second form exists for hosts that cap file size or do not honour `Range` at all, and it makes the CDN cache the pieces a user's queries actually touch rather than the whole database.

**Two configuration facts that turn out to be the whole story.** The worker sets `pragma cache_size=0`, because the VFS layer already retains every chunk it has fetched and a second cache would only duplicate it; and it warns, at open time, if the request chunk size and the database's page size disagree:

```ts
// src/sqlite.worker.ts
const pageSizeResp = await this.db.exec(
  'pragma page_size; pragma cache_size=0',
);
const pageSize = pageSizeResp[0].values[0][0];
if (pageSize !== mainFileConfig.requestChunkSize)
  console.warn(`Chunk size does not match page size: …`);
```

### DuckDB `httpfs`: coalesce first, then fetch

DuckDB's Parquet reader has an advantage `sql.js-httpvfs` structurally lacks: after reading the footer it knows _every_ byte range the query will need, before issuing any of them. It exploits that in three stages.

**Stage 1 — over-fetch the footer.** Rather than `bytes=-8` followed by the footer read, [`LoadMetadata`][parquet-reader] guesses the footer size as one-thousandth of the file, clamped to `[16 KiB, 256 KiB]` and rounded up to a power of two, and prefetches that whole suffix; the second request happens only if the guess was too small (`if (footer_len > prefetch_size - 8)`).

**Stage 2 — register ranges, merge adjacent ones.** `ReadAheadBuffer` in [`extension/parquet/include/thrift_tools.hpp`][thrift-tools] is described in the source as a "Two-step read ahead buffer: 1: register all ranges that will be read, merging ranges that are consecutive / 2: prefetch all registered ranges". Merging is implemented as a `std::set` whose comparator treats two ranges as equal when they are within `accepted_column_gap` bytes of each other:

```cpp
// extension/parquet/include/thrift_tools.hpp — ReadHeadComparator
static constexpr uint64_t DEFAULT_ACCEPTED_COLUMN_GAP = 1 << 14; // 16 KiB
…
if (a_end <= NumericLimits<idx_t>::Maximum() - accepted_column_gap) {
        a_end += accepted_column_gap;
}
return a_start < b_start && a_end < b_start;
```

Two column chunks 12 KiB apart therefore become one request that also transfers the 12 KiB nobody wants — because 12 KiB of wasted body is cheaper than one extra round trip.

**Stage 3 — learn the gap from the network.** The static 16 KiB is only the default. [`parquet_prefetch_cost_model.hpp`][cost-model] defines the gap as the **bandwidth–delay product**, clamped to `[4 KiB, 32 MiB]`:

```cpp
//! Cost model that decides how large a gap between two needed byte ranges may be
struct PrefetchCostModel {
    double latency_seconds;
    double bandwidth_bytes_per_s;
    static constexpr uint64_t GAP_MIN = 1ULL << 12; //! 4 KiB
    static constexpr uint64_t GAP_MAX = 32ULL << 20; //! 32 MiB
};
```

`GetColumnGapSize()` returns `latency_seconds * bandwidth_bytes_per_s` and `RefineFromEstimate` folds each measured throughput sample in with `ALPHA = 0.5`. The semantics are exactly right: the gap worth skipping is the number of bytes the link would have delivered during one round trip. A 50 ms, 200 Mbit/s link yields ≈ 1.25 MiB — two ranges a megabyte apart should be one request.

**The read unit.** Underneath all of that, DuckDB's external file cache blocks remote reads at a different granularity than local ones ([`src/common/settings.json`][settings-json]):

| Setting                                 | Default | Description (verbatim from `settings.json`)                                                 |
| --------------------------------------- | ------: | ------------------------------------------------------------------------------------------- |
| `external_file_cache_local_block_size`  |   16384 | "Block size in bytes for the external file cache when reading local (non-remote) files."    |
| `external_file_cache_remote_block_size` | 2097152 | "Block size in bytes for the external file cache when reading remote files (e.g. HTTP/S3)." |
| `cache_local_files`                     |   false | "Whether the external file cache also caches local files (remote files are always cached)"  |

A **128× larger read unit for remote files**, and remote files cached unconditionally while local ones are not, is the round-trips-not-bytes thesis expressed as two defaults. The comment on `ShouldCacheFile` says why the local half is off: "Local files are not cached: the OS page cache already serves repeated reads" ([`external_file_cache.cpp`][efc]).

### OCI registries: a manifest is an index, and `Range` is a footnote

The registry protocol is the pattern at coarse granularity and with the index promoted to a first-class resource. [`spec.md`][oci-spec] describes pulling as "retrieving two components: the manifest and one or more blobs", with the manifest fetched first from `/v2/<name>/manifests/<tag-or-digest>` and the blobs, by content digest, from `/v2/<name>/blobs/<digest>`.

What the client skips is decided by content addressing rather than by byte offsets: a layer whose digest is already in the local store is simply not requested, which is [content-addressed dedup][chunking] doing the work byte ranges do elsewhere. `Range` appears only twice, and both are recovery rather than random access:

> _"A registry SHOULD support the `Range` request header in accordance with [RFC 9110 (section 14)]."_ (§ Pulling blobs)

> _"When downloading a blob, the connection is interrupted before completion. The client keeps the partial data and uses http `Range` requests to avoid downloading repeated data."_ (§ Resumable Pull)

That `SHOULD`, and the absence of any index _inside_ a layer, is precisely why the lazy-pulling formats — eStargz, `zstd:chunked` — had to append a TOC to the tar in the first place; they are [covered with the chunking literature][chunking], not here.

### `debuginfod`: the index is out-of-band and so is the slicing

[`debuginfod(8)`][debuginfod-man] serves a webapi keyed on ELF build-ids: `/buildid/BUILDID/debuginfo`, `/executable`, `/source/SOURCE/FILE`, and — the one that matters for this page — `/buildid/BUILDID/section/SECTION`:

> _"If the given buildid is known to the server, the server will attempt to extract the contents of an ELF/DWARF section named SECTION from the debuginfo file matching BUILDID. … If the section is successfully extracted then this request results in a binary object of the section's contents. Note that this result is the raw binary contents of the section, not an ELF file."_

This is the same economics with the labour moved across the wire. The client sends one request and receives exactly the bytes it needs; the _server_ holds the index and does the seeking. And the index is, characteristically, a database — "debuginfod stores its index in an sqlite database in a densely packed set of interlinked tables" ([`debuginfod(8)`][debuginfod-man], DATA MANAGEMENT). Results are cached client-side under `~/.cache/debuginfod_client/BUILDID/` ([`debuginfod-find(1)`][debuginfod-find-man]), keyed by an immutable content identifier, which is why the cache never needs invalidating — a point the mutable cases below cannot match.

---

## Format identity and multiplicity

**Multiplicity = 0, and the zero is the finding.** Ranged consumption creates no new parses and requires none. It is orthogonal to the [multiplicity axis][concepts] in the strict sense: the bytes on the origin are one format, the client already knows which, and the `Content-Type` of a `206` response is the type of the _whole_ representation, not of the fragment. RFC 9110 §15.3.7 requires the client to "inspect a 206 response's `Content-Type` and `Content-Range` field(s) to determine what parts are enclosed" — the fragment is identified by _offset_, never by sniffing.

What the pattern does interact with is **tolerance**, and it interacts with it sharply:

| Property                 | Consequence for ranged access                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Footer-anchored index    | One suffix range (`bytes=-N`) finds the index without knowing the file size. Best case: two round trips to a plan      |
| Header-anchored + b-tree | One request finds the root, then each level of descent is a _dependent_ request. Cost is `O(depth)` **serial** trips   |
| Stream-scanned           | No index; there is nothing to range for. `tar` and raw `gzip` are simply not remotely queryable                        |
| Out-of-band index        | Zero client round trips against the artifact — but the artifact does not know its own index, and the view can be stale |

That table is the reason this page sits next to [footer-indexed formats][footer-indexed] rather than inside it. Footer anchoring is not merely convenient over HTTP; it is the anchoring that converts a read plan into a _parallel_ set of independent ranges, and the b-tree is the anchoring that does not.

**Prefix and suffix tolerance are irrelevant here, and that is worth saying.** A parasitic ZIP appended to a host file remains findable over HTTP by exactly the same `bytes=-65557` scan that finds it locally — which is a nice confirmation that suffix parasitism is a property of the format's self-location and not of the storage medium — but ranged access neither creates nor destroys the tolerance. The one real interaction is `Content-Encoding`: `sql.js-httpvfs` warns explicitly that a compressing origin invalidates every offset the client computed, "since the ranges will be based on the compressed data instead of the uncompressed data" ([`src/lazyFile.ts`][lazyfile]), and cannot suppress it because `Accept-Encoding` is a forbidden header in browser `fetch`/XHR. A transparently-compressing CDN silently converts a working ranged reader into a broken one.

---

## Index anchoring and random access

This is the section the subject exists for, and the central claim is this: **the two anchorings differ not in bytes but in whether the requests can be issued at once.**

DuckDB, having read a Parquet footer, holds a list of `(offset, length)` extents that were computed _without_ reading any of them. Those ranges are independent; they get merged by the gap heuristic and then fetched, and nothing forbids issuing them concurrently. SQLite, descending a b-tree, cannot know which page it needs at level `k+1` until it has parsed the page at level `k`. The descent is a **data-dependent pointer chase**, and the wall-clock cost is `depth × RTT` no matter how much bandwidth is available. HTTP/2 and HTTP/3 multiplexing do not help: multiplexing removes head-of-line blocking between _independent_ requests, and these are not independent.

A read plan's cost model, then, is:

```text
time  ≈  (serial dependent hops) × RTT  +  (total bytes fetched) / bandwidth
```

with the first term dominating for metadata queries and the second for scans. Every mechanism in the surveyed code is an attack on one of the two terms:

| Mechanism                                             | Term attacked   | System                                           |
| ----------------------------------------------------- | --------------- | ------------------------------------------------ |
| Footer over-fetch (16 KiB–256 KiB power-of-two guess) | serial hops     | DuckDB (`LoadMetadata`)                          |
| Gap coalescing at the bandwidth–delay product         | serial hops     | DuckDB (`PrefetchCostModel`)                     |
| 2 MiB remote cache block vs 16 KiB local              | serial hops     | DuckDB (`external_file_cache_remote_block_size`) |
| Three doubling read heads, capped at 5 MiB            | serial hops     | `sql.js-httpvfs` (`moveReadHead`)                |
| Chunk size == page size                               | wasted bytes    | `sql.js-httpvfs` (`create_db.sh`)                |
| Covering indexes so a query never touches table pages | both            | `sql.js-httpvfs` (documented practice)           |
| Content-digest skip of already-held layers            | both            | OCI registries                                   |
| Server-side section extraction                        | both, to ~1 hop | `debuginfod` `/section`                          |

### The page-size problem, and why the project's own numbers are the interesting part

SQLite's default page size is 4 KiB. As an HTTP request unit that is poor in both directions at once: too small to amortise a round trip, and — once a read head has doubled a few times — not actually what gets requested anyway. `sql.js-httpvfs` therefore requires the caller to state `requestChunkSize` explicitly, warns when it differs from `pragma page_size`, and [`create_db.sh`][create-db] simply derives one from the other:

```sh
# set request chunk size to match page size
requestChunkSize="$(sqlite3 "$indb" 'pragma page_size')"
```

The README's own preparation recipe is the part usually quoted, and it points _down_, not up:

```sql
pragma journal_mode = delete; -- to be able to actually set page size
pragma page_size = 1024; -- trade off of number of requests that need to be made vs overhead.
vacuum; -- reorganize database and apply changed page size
```

> [!IMPORTANT]
> **The repository's own benchmark contradicts the simple reading of that advice, and the contradiction is the lesson.** [`databench.txt`][databench] records one query (`select * from videoData where author = 'Adam Ragusea' limit 20`) against the same data rebuilt at four page sizes plus one page-aligned variant, request size always equal to page size, _with_ an index on `videoData(author)`:
>
> |        Page size | Bytes fetched | Requests |
> | ---------------: | ------------: | -------: |
> |              512 |        24,017 |       47 |
> |            4,096 |        98,280 |       24 |
> |           16,384 |       327,660 |       20 |
> |           32,768 |       491,505 |       15 |
> | 16,384 (aligned) |        98,298 |    **6** |
>
> Bytes and requests move in **opposite** directions across a 64× page-size sweep, exactly as the README's comment says. There is no page size that optimises both, so the choice is a statement about the deployment: at a 100 ms mobile RTT the 512-byte row costs 4.7 s of latency to save 74 KiB; on a LAN it is the right answer. The `aligned` row is the one that matters most — same 16 KiB pages, but roughly one third the bytes _and_ one third the requests of the unaligned build — because it shows that _layout_, not page size, is the larger lever. Without the index, the same query costs 142 requests and 581 KiB at 4 KiB pages.

The project's second piece of guidance is the one that generalises beyond SQLite: **precompute the index so the query never scans.** The README's debugging procedure is to read `explain query plan` and treat `SCAN TABLE t1` as "will have to be downloaded pretty much fully", `… USING INDEX i1 (a=?)` as index lookup plus a row fetch, and `… USING COVERING INDEX i1 (a)` as "the fastest" — with the explicit recommendation to build an index containing both the filter columns and the selected columns, "which SQLite reads as a COVERING INDEX in a sequential manner (no random access at all!)". A covering index turns two dependent descents into one, halving the serial-hop term; and because the leaves are contiguous, the read heads convert the remaining traversal into a small number of doubling requests.

The whole-post claim to hold onto for the next section is the measured one:

> _"The above query should do 10-20 GET requests, fetching a total of 130 - 270KiB."_

---

## Reflexivity and query surface

**Reflexivity = 2.** Ranged access supplies a _general_ query surface over a remote artifact — full SQL in both SQLite cases, DuckDB's full dialect over Parquet — and that is designed-in rather than incidental. It stops short of 3 because nothing here is self-interrogating: the artifact is inert data on an origin server, and the querying party is elsewhere. Contrast `self-httpd` in [the SELF deep-dive][self], where the running process queries the file it was loaded from; that is the 3.

What is genuinely novel about the surface is _who_ can hold it. `sql.js-httpvfs` puts a complete SQL engine in a browser tab against a database on a static host, with no server-side query capability at all — the origin is GitHub Pages, and it serves bytes. This is the same collapse [Datasette and the relational system surfaces][relational-surfaces] perform, run in the opposite direction: instead of a server exposing a database over HTTP, a client exposes HTTP as a database. The API even carries the accounting, which is unusual and useful — `worker.worker.bytesRead` is readable and assignable, `getStats()` returns `{totalBytes, totalFetchedBytes, totalRequests}`, `getResetAccessedPages()` returns the page-read log, and a `maxBytesToRead` budget is enforced by a `requestLimiter` that raises `EAGAIN` as a SQLite disk-I/O error rather than letting a bad plan silently download a gigabyte ([`src/sqlite.worker.ts`][worker]).

That budget mechanism deserves emphasis: a remote query surface without a cost meter is a footgun, because the difference between a 6-request query and a 142-request query is one missing index and is invisible in the SQL.

### The centrepiece: can you `SELECT` from a SELF binary over HTTP?

The source outline poses this as the catalog's most concrete testable proposal, and the honest answer is **yes for metadata, no for execution, and the arithmetic says which queries are on which side of that line.**

The mechanism requires no new engineering. A `.self` file is an ordinary SQLite database with `PRAGMA page_size = 4096` ([`elf2self.py`][elf2self]), and SQLite reaches its bytes through [a swappable VFS][sqlite-vfs]. `sql.js-httpvfs` already is such a VFS. Pointing it at `https://example.org/gdb.self` and running `SELECT name FROM exports` requires configuration, not code.

> [!WARNING]
> **Everything below is a derived estimate, computed from the SQLite file format and published sizes. Nothing here was measured.** No HTTP request was issued, no `.self` file was built, and no page counts were observed. The purpose is to make the proposal falsifiable, not to report a result.

**Assumptions, stated so they can be attacked:**

1. Page size 4096, as `elf2self` sets it; the file has been `VACUUM`ed, as `elf2self` does, so b-trees and overflow chains are compactly and contiguously allocated.
2. The schema is `schema/self.sql` at [`e63f7c47`][selfdb-schema] — nine tables, three views, one index (`idx_symbols_name ON symbols(name, version)`).
3. SQLite page-format constants from the [file format documentation][sqlite-fileformat]: a 100-byte database header on page 1; b-tree page header 8 bytes (leaf) or 12 (interior); a 2-byte cell-pointer per cell; a table-interior cell is a 4-byte child page number plus a varint key; an index cell is the key payload plus a 4-byte child pointer on interior pages.
4. Request chunk size == page size == 4096, and each uncached page costs one round trip. Read-ahead is ignored for the dependent-hop count (it cannot help a pointer chase) and credited only for scans.
5. Symbol row width ≈ 90 bytes and index entry ≈ 46 bytes, from the twelve columns of `symbols` and the two-column-plus-rowid index key, with `name` averaging 25 bytes and `version` 11.

**Sizing the b-trees.** For `N` symbols, with usable leaf space ≈ 4080 bytes:

| Structure                   | Entry size | Entries/page | For `N` = 346,386 — the userland closure's symbol count, borrowed as a large-`N` anchor |
| --------------------------- | ---------: | -----------: | --------------------------------------------------------------------------------------- |
| `symbols` table leaf        |      ~92 B |          ~44 | ~7,870 leaves ≈ 30.7 MiB                                                                |
| `symbols` table interior    |       ~9 B |         ~450 | ~18 pages at level 1, 1 root → **depth 3**                                              |
| `idx_symbols_name` leaf     |      ~46 B |          ~88 | ~3,940 leaves ≈ 15.4 MiB                                                                |
| `idx_symbols_name` interior |      ~51 B |          ~80 | ~50 pages at level 1, 1 root → **depth 3**                                              |

**Query 1 — `ldd` over HTTP.** `SELECT soname FROM needed ORDER BY ord` against `gdb.self` (95,940 KiB, 47 libraries, per [`bench/big.md`][bench-big]). Opening the database reads page 1, which carries both the file header and the root of `sqlite_schema`; the SELF schema's DDL text is roughly 2.5 KiB, so `sqlite_schema` is a single-page b-tree and page 1 _is_ that page. 47 rows of a two-column table is one leaf.

> **2 round trips, 8 KiB, against a 93.7 MiB artifact.**

**Query 2 — one symbol lookup.** `SELECT value, size FROM symbols WHERE name = 'main'`, warm-open. Index descent: root, interior, leaf = 3 dependent hops. Table descent by the resulting rowid: root, interior, leaf = 3 more. Plus page 1 on a cold open.

> **7 round trips, 28 KiB.** The outline's "query a remote executable's symbol table for 40 KiB" survives, for a single lookup, with room to spare.

**Query 3 — twenty symbols, as an `nm`-style listing.** The index and table roots and level-1 interiors are cached after the first lookup (~70 pages in total, of which a handful actually get touched), so each subsequent lookup costs one index leaf plus one table leaf. Estimated `7 + 19 × 2 ≈ 45` round trips and ~180 KiB, before read-ahead. This lands inside the same order of magnitude as phiresky's measured "10-20 GET requests, fetching a total of 130 - 270KiB" for a comparable 20-row indexed query, which is the only external calibration available and is reassuring rather than confirming.

**Query 4 — the whole symbol table.** `SELECT name, value FROM symbols` is a full table scan: ~7,870 leaves, 30.7 MiB. Sequentially accessed, so the read heads ramp to 5 MiB and the request count is small — roughly `log2(5 MiB / 4 KiB) + 30.7/5 ≈ 17` requests — but the bytes are the bytes. **Downloading the symbol table costs about what downloading the symbol table costs.** A covering index on `symbols(name, value)` would cut it to the index leaves alone.

**Query 5 — execution.** `SELECT content FROM segments` on `gdb.self` is ~40 MiB of BLOB. SELF's own design document notes that SQLite "stores big blobs on overflow-page chains (4-byte next-pointer + 4092 bytes payload per page)" ([`DESIGN.md`][selfdb-design] §8). Read literally, a blob read is a linked-list traversal — one dependent round trip per 4092 bytes, or ~10,000 serial hops for gdb's text, which at a 30 ms RTT is five minutes. In practice the chain is contiguous after `VACUUM` and the doubling read heads convert it into a sequential scan; but the _bytes_ are unavoidable, and they are the entire image. **Executing a remote SELF binary over HTTP is downloading it, with extra steps.**

**What the estimate says.** The dividing line is not "SELF over HTTP: yes or no". It is:

- **Metadata queries are essentially free** — 2 to 10 round trips, tens of KiB, against artifacts of any size, because b-tree depth grows logarithmically and everything the tools ask (`ldd`, `readelf -l`, `nm --defined-only foo`) is a point or small-range lookup. This is a strictly better remote story than ELF has: there is no remote equivalent of `readelf` short of fetching the file, because ELF's section header table is at an offset the client must first read the header to learn, and then every string is in a `.strtab` somewhere else. Two dependent hops minimum, and no index at all for "which library defines `foo`".
- **Latency, not size, is the budget.** Seven serial hops is 35 ms against same-region object storage and 700 ms against a poorly-peered CDN. The artifact's size never enters.
- **Anything proportional to the image is proportional to the image.** Loading, `self2elf`, and full-table scans are downloads.

**What a real experiment must do**, in the order the confounds bite:

1. Build a `.self` from a real binary with `elf2self`, `VACUUM`, and record `page_size` and the `dbstat` page counts per table and index — which is the direct check on assumptions 1, 3, and 5 above.
2. Serve it from an origin that honours `Range` and returns `206`, confirmed by inspecting the status code rather than the body length; then repeat against a compressing CDN to demonstrate the `Content-Encoding` failure.
3. Drive it through `sql.js-httpvfs` in `serverMode: "full"` with `requestChunkSize: 4096`, `logPageReads: true`, and run each of the five queries above, reading `getStats()` and `getResetAccessedPages()` rather than a stopwatch. The page log is the ground truth; wall time is not, because it convolves the plan with the link.
4. Repeat at page sizes 1024 / 4096 / 16384, rebuilding with `VACUUM` each time, to reproduce the [`databench.txt`][databench] shape on this schema.
5. Control for cold vs warm: SQLite's own cache is disabled (`cache_size=0`), so the only cache is the VFS chunk map, and `totalRequests` for the _second_ execution of the same query is the number that matters for a server-side deployment.
6. Report round trips and bytes; report latency only with the measured RTT alongside, since the whole claim is that the first number is the interesting one.

Steps 1–3 are an afternoon. That is the point of writing the estimate down.

---

## Closure, dedup, and size model

**Closure = 1.** Ranged consumption is the _opposite_ of carrying dependencies: it is a technique for not moving things. Where closure appears at all it is incidental to the pattern:

- An **OCI manifest is a closure descriptor** — the list of layer digests that constitute the image — and the client's job is to fetch only the elements of that closure it lacks. Dedup is by content digest, at layer granularity, which is coarse; the finer-grained answer belongs to [content-addressed chunking][chunking], and the store-path-granular answer to [Nix closures][nix-closures].
- **`debuginfod` federates**: a server may forward queries upstream, so a client's single request can traverse a chain of servers — closure over _servers_ rather than over content.
- A **`self closure` database** would be the interesting case for ranged access precisely because it is a closure: one database containing 1,123 objects, 346,386 symbols and 3,808 dependency edges in 611.9 MiB ([the SELF deep-dive][self] records the figures). Remotely querying "which of these objects imports `dlopen`" is a handful of index descents against a 612 MiB artifact, and there is no ELF-world equivalent at any price.

**The size model that actually matters here is not the artifact's, it is the transfer's.** The surveyed numbers bound it:

| Source, same query and same data ([`databench.txt`][databench])                      |     Fetched | Requests |
| ------------------------------------------------------------------------------------ | ----------: | -------: |
| no index, 4 KiB pages, 4 KiB request size                                            |   581,490 B |      142 |
| index on `videoData(author)`, 4 KiB pages, 4 KiB request size                        |    98,280 B |       24 |
| the same index, 16 KiB pages, page-aligned rebuild                                   |    98,298 B |    **6** |
| [phiresky's post][phiresky-post]: a different query, 670 MiB DB (6 tables, 8M+ rows) | 130–270 KiB |    10–20 |

The two steps separate the levers cleanly. Adding the index, holding page size fixed, divides both bytes and requests by 5.9. Re-laying-out at 16 KiB aligned pages, holding the index fixed, leaves the bytes identical and divides the requests by 4. Neither lever is the artifact's size, and the artifact's size does not appear anywhere in the model.

Caching then decides whether the cost recurs, and the four systems answer differently:

| System           | Cache                                                                                                                               | Invalidation                                                                                                                               |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| DuckDB `httpfs`  | external file cache, 2 MiB blocks, remote always cached; plus an `HTTPMetadataCache` of `{length, last_modified, etag, version_id}` | `If-Match` on every range request; `validate_external_file_cache` modes                                                                    |
| `sql.js-httpvfs` | the VFS's own chunk map, unbounded, in-Worker; plus whatever the browser HTTP cache and CDN do                                      | a manual `cacheBust` query parameter; the README warns of "caching-related database corruption" and notes "there's also no cache eviction" |
| OCI registry     | content-addressed local store                                                                                                       | none needed — a digest names immutable bytes                                                                                               |
| `debuginfod`     | `~/.cache/debuginfod_client/BUILDID/`                                                                                               | none needed — a build-id names immutable bytes                                                                                             |

The pattern is unmissable: **the two content-addressed systems have no invalidation problem, and the two offset-addressed ones have nothing else.** That is the strongest argument in this page for content addressing, and it is an argument about _identity_, not about storage.

---

## Mutability, dispatch, and trust

**Mutability = 0, and this is the axis where ranged consumption is most sharply constrained.** Every system surveyed here is read-only against the remote artifact, and more than that: **ranged access assumes the artifact does not change during the read.** A b-tree descent that reads a root from version _A_ and a leaf from version _B_ does not return a wrong row; it returns a page that is not a b-tree page at all, and the failure surfaces as corruption rather than as an error.

**DuckDB solves this properly, and the mechanism is worth copying.** After a `HEAD`, it captures the `ETag`, checks that it is a _strong_ validator (rejecting `W/`-prefixed and malformed ones in `IsStrongETag`), and then attaches it to every subsequent range request ([`src/http/http_request.cpp`][http-request]):

```cpp
static void ApplyReadCondition(HTTPHeaders &headers, const HTTPReadConfig &read_config) {
    if (read_config.condition.type == HTTPReadConditionType::ETAG) {
        headers["If-Match"] = read_config.condition.value;
    }
}
```

A `412 Precondition Failed` then means the file changed mid-query, and `ThrowIfReadConditionFailed` erases the cache entry and raises "ETag on reading file … changed after it was opened: the server rejected …". The S3 path uses a version id instead. There is an escape hatch, `unsafe_disable_etag_checks`, and it is named honestly.

**`sql.js-httpvfs` has nothing equivalent.** It sends no conditional header; its answer is the `cacheBust` config property — "If you set it to a random value when you update the database you can avoid caching-related database corruption" — which addresses a _stale CDN copy_, not a _concurrent write_. For a static-hosted database updated by re-uploading a file, that is adequate. For anything mutating, it is not.

**Which is exactly the problem with a remote SELF binary.** `self-httpd` `INSERT`s a `visits` row on every request into the file it is executing from, and the example README records the artifact growing from 155,648 to 200,704 bytes over a few thousand requests ([the SELF deep-dive][self]). Under a correct `If-Match` client, _every_ remote query against a live `self-httpd` would `412` — the strong `ETag` changes on essentially every request. Under `sql.js-httpvfs`, it would instead silently read a torn b-tree. So:

> The `SELECT`-over-HTTP proposal works against an **immutable** `.self` artifact — a release binary on a CDN, a Nix store path, a registry blob — and does not work against a **live** one. [Mutability and remote ranged access are mutually exclusive without a snapshot mechanism][open-questions], and HTTP does not have one: `If-Match` detects the collision, it does not prevent it.

That is a real result and it is the reason the axis score is 0 rather than 1.

**Dispatch is the consumer's, and only the consumer's.** No kernel, shell, or loader participates. The client library decides the artifact's format from the URL, an out-of-band declaration, or a magic check it performs itself; nothing in a `206` response identifies the fragment. Compare [`binfmt_misc`][binfmt], where the kernel decides from magic at a fixed offset — a dispatch that cannot be performed at all over a range request, because the deciding bytes and the executing entity are on different machines. A remote `.self` file is queryable but never executable _as such_: something must first make it local.

**What a Range-ignoring server does, and how each client notices.** This is the trust boundary that actually bites in production, and the two SQL engines disagree on how seriously to take it:

| Client           | Detection                                                                                                                 | Response                                                                                                                                                                                                            |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DuckDB `httpfs`  | `Content-Length` of the response `!=` the requested range length (`ValidateContentLength`) — status codes are not trusted | Marks range requests unsupported, returns `false` up to `ReadAtWithFallback`, logs a warning, downloads the whole file, retries the read, and cross-checks the downloaded length against the `HEAD`-reported length |
| `sql.js-httpvfs` | `Accept-Ranges: bytes` absent from a `HEAD` response                                                                      | `console.warn` — the `throw Error(msg)` on the next line is commented out                                                                                                                                           |

DuckDB's choice not to trust the status code is the correct one and follows directly from RFC 9110's note under §15.5.17: "Because servers are free to ignore Range, many implementations will respond with the entire selected representation in a 200 (OK) response." The observable difference is the body length, so that is what it checks. `sql.js-httpvfs`'s warning text is candid about the several ways the signal can be wrong — a CORS origin that does not expose `Accept-Ranges` looks identical to one that does not support ranges — and it proceeds anyway, which for a browser demo is defensible and for a library is a trap.

**Verification is unsolved in the offset-addressed cases.** A digest over the whole artifact cannot be checked by a client that never fetches the whole artifact; that is the same structural problem [signing a mutable artifact][provenance] has, arriving from a different direction. The content-addressed systems dodge it entirely: an OCI client verifies each blob against the digest that named it, and `debuginfod` keys on a build-id embedded in the file by the linker ([`.note.gnu.buildid`][debug-info]). For a ranged Parquet or SQLite read, per-range verification would need per-range digests — a Merkle structure inside the format, which is what `fs-verity` provides for local files and what no footer format currently carries.

---

## Strengths

- **The cost is logarithmic in the artifact and linear in the answer.** Two round trips and 8 KiB to run `ldd` against a 93.7 MiB executable is not a marginal improvement over downloading it; it is a different category of operation.
- **No format work is required.** Both SQLite cases and the Parquet case reuse an existing, unmodified format. This is [thesis 5][concepts] — portability migrating from the format to the access layer — in its most literal form: the same `.sqlite3` file works from a local disk, from OPFS, and from a URL, because only the [VFS][sqlite-vfs] changed.
- **The read plan is inspectable and budgetable.** `explain query plan` predicts the request count before any request is made; `bytesRead`, `getStats()` and `maxBytesToRead` make the cost observable and boundable at run time. Very few network abstractions expose their own cost model this well.
- **It composes with CDNs for free.** Static hosting plus `Range` is the cheapest possible serving infrastructure, and the chunked mode makes even a host without `Range` support workable.
- **Coalescing heuristics are well-founded rather than magic.** DuckDB's coalescing gap is the bandwidth–delay product, which is the physically correct answer to "how many wasted bytes are cheaper than one round trip."

## Weaknesses

- **A b-tree descent is a serial pointer chase and no amount of bandwidth fixes it.** This is structural, not an implementation gap: the pages are data-dependent, so HTTP/2 multiplexing, connection pooling, and parallel fetching are all inapplicable to the dependent hops.
- **Multi-range requests would collapse a whole read plan into one round trip, and nobody uses them.** RFC 9110 permits them; §15.5.17 blesses refusing them as DoS mitigation; no surveyed client emits one. This is a standing, unexploited win for the footer-indexed case, where the ranges _are_ known in advance.
- **Correctness depends on the origin's behaviour, and the failure is silent.** A compressing CDN, a proxy that ignores `Range`, or a server that returns a `200`, all produce wrong offsets rather than errors. Only DuckDB checks properly.
- **Mutability is excluded.** Concurrent modification of the artifact turns a ranged read into either a `412` storm or silent corruption, and HTTP offers detection but not isolation.
- **Verification does not survive partial reads.** A whole-file digest is unusable by a client that fetches 28 KiB of 93.7 MiB, and no footer-indexed format currently carries per-range digests.
- **Tuning is per-deployment and there is no good default.** [`databench.txt`][databench] shows bytes and requests moving in opposite directions across the page-size sweep; the right page size depends on the RTT of a link the artifact's author does not know.
- **`sql.js-httpvfs` is explicitly not production-grade.** Its README says so — "no cache eviction, so the more data is fetched the more RAM it will use", "the virtual file system part doesn't have any tests" — and the last commit surveyed is from March 2023.

---

## Key design decisions and trade-offs

| Decision                                                                             | Rationale                                                                                                             | Trade-off                                                                                                               |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Over-fetch the Parquet footer (16 KiB–256 KiB, power-of-two, `file_size/1000` guess) | Saves a round trip on the overwhelmingly common case where the footer is small; "the read cost is mostly round trips" | Wastes up to 256 KiB per file when the guess is far too large; a wrong guess costs the round trip anyway                |
| Coalesce ranges at the bandwidth–delay product, clamped `[4 KiB, 32 MiB]`            | The physically correct break-even: skip bytes cheaper than a round trip                                               | Requires a measured `latency`/`bandwidth` estimate; the first query on a connection runs at the 4 KiB floor             |
| 2 MiB remote cache blocks vs 16 KiB local                                            | The OS page cache serves local repeats; a remote repeat is a full round trip                                          | 2 MiB of memory and transfer per touched block, even for a 100-byte read                                                |
| Three doubling virtual read heads, capped at 5 MiB                                   | Matches SQLite's actual concurrency — descent plus row fetch plus a join side; makes scans logarithmic in bytes       | Purely heuristic; a random-access pattern trains three heads badly and prefetches waste                                 |
| `requestChunkSize == page_size`, enforced by warning                                 | A partial page is a useless fetch; a chunk spanning pages fetches bytes SQLite will not look at                       | Couples an HTTP tuning parameter to a database property fixed at `VACUUM` time                                          |
| Disable SQLite's page cache (`cache_size=0`) in the Worker                           | The VFS already retains every chunk; a second cache doubles memory for nothing                                        | No eviction anywhere in the stack — a long session's memory grows monotonically                                         |
| `If-Match` on every range request (DuckDB)                                           | Turns a mid-query modification from silent corruption into a `412`                                                    | Excludes mutating artifacts entirely; requires a strong `ETag`, which many origins do not emit                          |
| Detect Range-ignoring servers by `Content-Length`, not status (DuckDB)               | RFC 9110 warns that servers "are free to ignore Range" and answer `200`; the body length is the observable signal     | A malformed `Content-Length` disables the check; the fallback silently downloads the entire file                        |
| Split the database into 10 MiB static chunks (`create_db.sh`)                        | Works on hosts that cap file size or lack `Range`; lets a CDN cache only the touched pieces                           | Rebuilding requires re-splitting; the chunk size must be a multiple of `page_size`; cache-busting is manual             |
| Server-side section extraction (`debuginfod` `/section`)                             | One request, no client index, no `Range`, and results cache forever under an immutable build-id                       | The server must hold and maintain the index; the client cannot ask a question the endpoint does not implement           |
| Content-digest addressing (OCI, `debuginfod`) rather than byte offsets               | Eliminates cache invalidation and gives per-unit verification for free                                                | Granularity is whatever the producer chose — a whole layer, a whole file — so partial reuse within a unit is impossible |

---

## Sources

- [RFC 9110, _HTTP Semantics_, §14 Range Requests, §15.3.7 `206`, §15.5.17 `416`][rfc-range] — the `MAY ignore` clause, `Accept-Ranges` as advisory, multi-range syntax, and the DoS note under `416`
- [`phiresky/sql.js-httpvfs`][httpvfs-repo], read at [`c64536d2`][httpvfs-repo] (2023-03-02): [`src/lazyFile.ts`][lazyfile] (`LazyUint8Array`, the three doubling read heads, `checkServer`'s `Accept-Ranges` and `Content-Encoding` warnings, the synchronous XHR), [`src/sqlite.worker.ts`][worker] (`rangeMapper`, chunked vs full server mode, `cache_size=0`, the page-size mismatch warning, `requestLimiter`/`maxBytesToRead`, `getStats`/`getResetAccessedPages`), [`create_db.sh`][create-db] (10 MiB chunks, `requestChunkSize` derived from `pragma page_size`), [`README.md`][httpvfs-readme] (the preparation recipe, `explain query plan` guidance, covering indexes, the production-readiness caveats), [`databench.txt`][databench] (the five-page-size sweep, indexed and unindexed)
- [phiresky, "Hosting SQLite databases on GitHub Pages (or any static file hoster)" (2021)][phiresky-post] — the request/bandwidth balance, the 4 KiB default, the logarithmic-scan claim, and the 10–20 requests / 130–270 KiB demo figure
- [`duckdb/duckdb`][duckdb-repo], read at [`d9958734`][duckdb-repo] (2026-08-26): [`extension/parquet/parquet_reader.cpp`][parquet-reader] (the two-round-trip comment and the footer over-fetch), [`extension/parquet/include/thrift_tools.hpp`][thrift-tools] (`ReadAheadBuffer`, `ReadHeadComparator`, the 16 KiB default gap), [`extension/parquet/include/parquet_prefetch_cost_model.hpp`][cost-model] and [its implementation][cost-model-cpp] (the bandwidth–delay product, `GAP_MIN`/`GAP_MAX`, `ALPHA`), [`src/common/settings.json`][settings-json] (the remote vs local cache block sizes), [`src/storage/external_file_cache/external_file_cache.cpp`][efc] (`GetCacheBlockSize`, `ShouldCacheFile`)
- [`duckdb/duckdb-httpfs`][httpfs-repo], read at [`c942cee6`][httpfs-repo] (2026-08-20): [`src/http/httpfs.cpp`][httpfs-cpp] (`TryRangeRequest`, `ReadAtWithFallback`, `IsStrongETag`, `BuildReadConfig`), [`src/http/http_request.cpp`][http-request] (`ApplyReadCondition`'s `If-Match`, `ValidateContentLength`, `ThrowIfReadConditionFailed`), [`src/include/http/httpfs.hpp`][httpfs-hpp] (`RangeRequestNotSupportedException::MESSAGE`), [`src/http/http_settings.cpp`][http-settings] (`force_download`, `auto_fallback_to_full_download`, `unsafe_disable_etag_checks`), [`src/include/http/http_metadata_cache.hpp`][metadata-cache]
- [`opencontainers/distribution-spec`][oci-repo], read at [`fee21197`][oci-repo] (2026-07-30): [`spec.md`][oci-spec] — manifest-before-blobs, the `SHOULD` on `Range`, and the Resumable Pull use case
- [`debuginfod(8)`][debuginfod-man] and [`debuginfod-find(1)`][debuginfod-find-man] (elfutils; quoted from `doc/debuginfod.8` and `doc/debuginfod-find.1` as served by [sourceware cgit][elfutils-cgit] on 2026-08-26) — the `/buildid/BUILDID/{debuginfo,executable,source,section}` webapi, the sqlite-backed index, and `~/.cache/debuginfod_client/`; the project overview is [elfutils — Debuginfod][debuginfod-overview]
- [SQLite — Database File Format][sqlite-fileformat] (page 1's 100-byte header, b-tree page headers, cell formats, overflow-page chains) · [`PRAGMA page_size`][sqlite-pragma] · [`sqlite3_blob_read`][blob-read] · [The SQLite OS Interface (VFS)][sqlite-vfs-doc]
- [`fzakaria/selfdb`][selfdb-repo], read at [`e63f7c47`][selfdb-repo], for the artifact the estimate is computed against: [`schema/self.sql`][selfdb-schema] (the `symbols` columns and `idx_symbols_name`), [`converter/selfconv/elf2self.py`][elf2self] (`PRAGMA page_size = 4096`, `VACUUM`), [`DESIGN.md`][selfdb-design] §8 (overflow-page chains, "4-byte next-pointer + 4092 bytes payload per page"), [`bench/big.md`][bench-big] (`gdb.self` = 95,940 KiB)
- Related in this tree: [footer-indexed formats][footer-indexed] · [the VFS as substrate][sqlite-vfs] · [SELF / selfdb][self] · [SQLite as an application file format][sqlite-app] · [content-addressed chunking][chunking] · [Nix store closures][nix-closures] · [debug info and indexes][debug-info] · [ZIP parasitism][zip] · [relational system surfaces][relational-surfaces] · [`binfmt_misc`][binfmt] · [embedded provenance][provenance] · [threat model][threat] · [measurement][measurement] · [open questions][open-questions] · [concepts][concepts] · [comparison][comparison] · [umbrella][umbrella]

<!-- References -->

[rfc-range]: https://www.rfc-editor.org/rfc/rfc9110#section-14
[phiresky-post]: https://phiresky.github.io/blog/2021/hosting-sqlite-databases-on-github-pages/
[debuginfod-man]: https://man.archlinux.org/man/debuginfod.8
[debuginfod-find-man]: https://man.archlinux.org/man/debuginfod-find.1
[debuginfod-overview]: https://sourceware.org/elfutils/Debuginfod.html
[elfutils-cgit]: https://sourceware.org/git/?p=elfutils.git;a=tree;f=doc
[sqlite-fileformat]: https://sqlite.org/fileformat2.html
[sqlite-pragma]: https://sqlite.org/pragma.html#pragma_page_size
[blob-read]: https://sqlite.org/c3ref/blob_read.html
[sqlite-vfs-doc]: https://sqlite.org/vfs.html
[httpvfs-repo]: https://github.com/phiresky/sql.js-httpvfs/tree/c64536d2acc78feeac17c34bfa1895df01050129
[lazyfile]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/src/lazyFile.ts
[worker]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/src/sqlite.worker.ts
[create-db]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/create_db.sh
[httpvfs-readme]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/README.md
[databench]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/databench.txt
[duckdb-repo]: https://github.com/duckdb/duckdb/tree/d99587345c05f20e036ff9088f0f0f69b775e410
[parquet-reader]: https://github.com/duckdb/duckdb/blob/d99587345c05f20e036ff9088f0f0f69b775e410/extension/parquet/parquet_reader.cpp
[thrift-tools]: https://github.com/duckdb/duckdb/blob/d99587345c05f20e036ff9088f0f0f69b775e410/extension/parquet/include/thrift_tools.hpp
[cost-model]: https://github.com/duckdb/duckdb/blob/d99587345c05f20e036ff9088f0f0f69b775e410/extension/parquet/include/parquet_prefetch_cost_model.hpp
[cost-model-cpp]: https://github.com/duckdb/duckdb/blob/d99587345c05f20e036ff9088f0f0f69b775e410/extension/parquet/parquet_prefetch_cost_model.cpp
[settings-json]: https://github.com/duckdb/duckdb/blob/d99587345c05f20e036ff9088f0f0f69b775e410/src/common/settings.json
[efc]: https://github.com/duckdb/duckdb/blob/d99587345c05f20e036ff9088f0f0f69b775e410/src/storage/external_file_cache/external_file_cache.cpp
[httpfs-repo]: https://github.com/duckdb/duckdb-httpfs/tree/c942cee64bb1bc848168d4ad74fcd9eff2c616e7
[httpfs-cpp]: https://github.com/duckdb/duckdb-httpfs/blob/c942cee64bb1bc848168d4ad74fcd9eff2c616e7/src/http/httpfs.cpp
[http-request]: https://github.com/duckdb/duckdb-httpfs/blob/c942cee64bb1bc848168d4ad74fcd9eff2c616e7/src/http/http_request.cpp
[httpfs-hpp]: https://github.com/duckdb/duckdb-httpfs/blob/c942cee64bb1bc848168d4ad74fcd9eff2c616e7/src/include/http/httpfs.hpp
[http-settings]: https://github.com/duckdb/duckdb-httpfs/blob/c942cee64bb1bc848168d4ad74fcd9eff2c616e7/src/http/http_settings.cpp
[metadata-cache]: https://github.com/duckdb/duckdb-httpfs/blob/c942cee64bb1bc848168d4ad74fcd9eff2c616e7/src/include/http/http_metadata_cache.hpp
[oci-repo]: https://github.com/opencontainers/distribution-spec/tree/fee21197eb94360ddfa6dda0b7edabcd12456809
[oci-spec]: https://github.com/opencontainers/distribution-spec/blob/fee21197eb94360ddfa6dda0b7edabcd12456809/spec.md
[selfdb-repo]: https://github.com/fzakaria/selfdb/tree/e63f7c470302f089a677ec87679a7df60b628547
[selfdb-schema]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/schema/self.sql
[selfdb-design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[elf2self]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/converter/selfconv/elf2self.py
[bench-big]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/big.md
[footer-indexed]: ./footer-indexed-formats.md
[sqlite-vfs]: ./sqlite-vfs-substrate.md
[sqlite-app]: ./sqlite-application-file-format.md
[self]: ./self-selfdb/index.md
[chunking]: ./content-addressed-chunking.md
[nix-closures]: ./nix-store-closures.md
[debug-info]: ./debug-info-and-indexes.md
[zip]: ./zip-parasitism.md
[relational-surfaces]: ./relational-system-surfaces.md
[binfmt]: ./binfmt-misc.md
[provenance]: ./embedded-provenance.md
[threat]: ./threat-model.md
[measurement]: ./measurement.md
[open-questions]: ./open-questions.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
