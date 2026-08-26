# Content addressing, chunking, and deduplication (storage and distribution systems)

The other resolution of the closure/size trade-off: rather than avoid duplication, make duplication free — name every blob by the hash of its bytes, then choose the _grain_ at which bytes get named, because that single choice, and nothing else, determines how much a second artifact costs.

| Field           | Value                                                                                                                                                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | A family of four storage/distribution systems, compared: content-addressed filesystem trees, content-defined chunking, container layers, and partially-pullable layers                                                  |
| Language        | C (`OSTree`, `casync`), Go (`desync`, `containers/storage`), specification (OCI)                                                                                                                                        |
| License         | LGPL-2.0+ (`OSTree`), LGPL-2.1+ (`casync`), BSD-3-Clause (`desync`), Apache-2.0 (`containers/storage`, OCI specs)                                                                                                       |
| Repository      | [`ostreedev/ostree`][ostree-repo] · [`systemd/casync`][casync-repo] · [`folbricht/desync`][desync-repo] · [`containers/storage`][cstorage-repo] · [`opencontainers/image-spec`][oci-repo]                               |
| Documentation   | [ostreedev.github.io/ostree][ostree-docs] · [`casync` README][casync-readme] · [`desync` README][desync-readme] · [`containers-storage-zstd-chunked(1)`][zstd-chunked-doc] · [OCI Image Format Specification][oci-spec] |
| First release   | `OSTree` first commit **October 9, 2011**; `casync` first commit **January 10, 2017**, announced **June 20, 2017**; `desync` first commit **November 8, 2017**; OCI Image Spec **v1.1.1, February 24, 2025**            |
| Axis profile    | Multiplicity **0** / Reflexivity **1** / Closure **3** / Mutability **1**                                                                                                                                               |
| Index anchoring | **Out-of-band** — chunk-index files (`.caibx`/`.caidx`), `dirtree` objects, OCI manifests. `zstd:chunked` is the exception: its TOC is **footer**-anchored inside the layer blob                                        |
| Dispatch owner  | Consumer — no kernel, shell, or loader ever decides what these bytes are                                                                                                                                                |

> **Latest release / revision surveyed:** `ostree` at `1d5a312a` (August 25, 2026), `casync` at `b4b7e560` (June 4, 2023 — the project is dormant), `desync` at `ff9ccfab` (August 5, 2026), `containers/storage` at `83cf5746` (August 29, 2025), `image-spec` at `af26a05f` (July 9, 2026), `distribution-spec` at `fee21197`. **Measurements:** Linux x86-64, NixOS, **August 26, 2026**.

---

## Overview

### What it solves

The [Closure axis][concepts-closure] is the catalog's only axis with an unavoidable price attached. An artifact that carries its transitive dependencies can be copied to a machine and run; an artifact that does not, cannot. The naive way to carry them is to copy them, and copying is what produces the SELF paper's headline comparison: 723 executables and their libraries cost **611.9 MiB** when the closure is shared inside one database and **5.53 GiB** when each root gets a private copy — a factor of **9.0×** for the identical guarantee ([SELF][self]).

There are exactly two ways out of that factor, and the catalog contains both.

- **Do not duplicate.** Give every dependency a globally unique name, install it once, and have every consumer reference it. This is [Nix's store][nix], and SELF's `objects.path UNIQUE` inside one closure database.
- **Duplicate, but share the bytes.** Give every _blob_ a name derived from its content, so two duplicates are automatically the same object. Nothing has to agree on names in advance, nothing has to be installed once, and — the part that matters — the _grain_ of the blob is a free parameter.

This page is about the second answer and, specifically, about that free parameter. Four systems pick four different grains:

| System                  | What is addressed                                                   | Grain            | Second copy of a modified artifact costs         |
| ----------------------- | ------------------------------------------------------------------- | ---------------- | ------------------------------------------------ |
| **OSTree**              | one file's content + `uid`/`gid`/mode/xattrs, hashed together       | a file           | every changed file, whole                        |
| **casync** / **desync** | a variable-length run of bytes cut by a rolling hash                | ~64 KiB          | every changed _chunk_, ~64 KiB each              |
| **OCI image layers**    | one `tar` archive, compressed, named by its digest                  | a whole layer    | the entire layer containing the change           |
| **`zstd:chunked`**      | a file, and optionally sub-file chunks, inside a `+zstd` layer blob | a file / ~64 KiB | only the ranges the client does not already have |

The grain is not a tuning knob at the margins. Measured below on a real point-release upgrade of a 179 MiB shared library, it moves the reuse ratio from **0.00%** (whole-file) through **0.07%** (fixed-size blocks) to **18.87%** (content-defined chunks) — and moves it again, to **26.91%**, when the chunk size alone is changed.

> [!NOTE]
> Container image formats are [out of scope for this tree][concepts-scope] _as formats_. They appear here for the one reason the exclusion allows: `zstd:chunked` exists to change where a layer's index lives, and that is exactly this catalog's subject. Everything about registries, signing infrastructure, and distribution policy belongs to [`docs/research/application-packaging/`][packaging].

### Design philosophy

Lennart Poettering's announcement of `casync` states the design brief as a list of simultaneous constraints, and is explicit that the existing systems each satisfy a proper subset:

> _"Most importantly, make updates cheap traffic-wise […] Put boundaries on disk space usage on servers […] Put boundaries on disk space usage on clients […] Be friendly to Content Delivery Networks (CDNs), i.e. serve neither too many small nor too many overly large files, and only require the most basic form of HTTP."_
> — [casync — A tool for distributing file system images][casync-blog], June 20, 2017

The same post names the specific complaint against each incumbent, and the complaints are complaints about _grain_:

> _"Docker's layered tarball approach dumps the "delta" question onto the feet of the image creators […] OSTree's serving of individual files is unfriendly to CDNs (as many small files in file trees cause an explosion of HTTP GET requests)."_
> — [casync announcement][casync-blog]

And the mechanism, in the author's own words, is the definition of content-defined chunking:

> _"The chunking algorithm is supposed to create variable, but similarly sized chunks from the data stream, and do so in a way that the same data results in the same chunks even if placed at varying offsets."_
> — [casync announcement][casync-blog]

That last clause — _"even if placed at varying offsets"_ — is the whole subject. OSTree's philosophy is stated at the other end of the grain scale, and is equally explicit that the choice is about _sharing_, not about compression:

> _"The OSTree data format intentionally does not contain timestamps. The reasoning is that data files may be downloaded at different times, and by different build systems, and so will have different timestamps but identical physical content. These files may be large, so most users would like them to be shared, both in the repository and between the repository and deployments."_
> — [`docs/repo.md`][ostree-repo-md]

---

## How it works

### Content addressing: the identity function

Every system here is built on the same primitive — a blob's _name_ is a cryptographic hash of its _bytes_ — and every system differs in what it decides to feed the hash.

| System         | Hash                              | Over what, exactly                                                                                       | Path in the store                                                 |
| -------------- | --------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| OSTree         | SHA-256                           | an internal header (`uid`, `gid`, mode, symlink target, xattrs) followed by the **uncompressed** content | `objects/<2 hex>/<62 hex>.filez` ([`ostree-core.c`][ostree-core]) |
| `casync`       | SHA-512/256 (SHA-256 legacy)      | the **uncompressed** chunk bytes, nothing else                                                           | `<4 hex>/<64 hex>.cacnk` ([`cachunkid.c`][casync-chunkid])        |
| OCI layer      | SHA-256 (`descriptor.digest`)     | the layer blob **as transferred**, i.e. after compression                                                | registry blob, addressed by digest                                |
| OCI `DiffID`   | SHA-256                           | the layer's **uncompressed** `tar`                                                                       | not stored; recorded in the image config                          |
| `zstd:chunked` | SHA-256 (`digest`, `chunkDigest`) | the file's uncompressed contents, and each chunk's                                                       | recorded in the TOC ([`minimal/compression.go`][cs-minimal])      |

Two consequences fall straight out of this table.

**OSTree deliberately hashes metadata into the content identity.** `docs/repo.md` says the header _"contains uid, gid, mode, and symbolic link target (for symlinks), as well as extended attributes […] These parts together form the SHA256 hash for content objects"_. Two byte-identical files with different modes are therefore two objects. That is correct for a filesystem-tree store (a checkout must reproduce the mode) and it costs sharing.

**OCI names layers by their compressed form, and that is the reason layer dedup is fragile.** `config.md` warns about the split directly:

> _"Layers SHOULD be packed and unpacked reproducibly to avoid changing the layer DiffID, for example by using [tar-split][] to save the tar headers. NOTE: Do not confuse DiffIDs with layer digests, often referenced in the manifest, which are digests over compressed or uncompressed content."_
> — [`config.md` §Layer DiffID][oci-config]

A registry deduplicates on the _digest_. Recompress the same `tar` with a different `gzip` implementation and the digest changes while the `DiffID` does not; the registry now stores the layer twice.

### Fixed-size chunking, and why it cannot work

The obvious way to sub-divide a stream is to cut every `N` bytes. It is trivially fast, needs no state, and produces a perfectly uniform chunk-size distribution. It also fails completely against the single most common edit in a binary artifact.

Let a stream be cut at offsets `N, 2N, 3N, …`. Insert one byte at offset `k`. Every byte after `k` now sits one position later, so chunk `i` of the new stream — the bytes at `[iN, (i+1)N)` — contains what used to live at `[iN−1, (i+1)N−1)` for every `i > k/N`. Not one of those chunks hashes to what it hashed to before. **A one-byte insertion invalidates every chunk after it**, and the reuse ratio collapses from ~100% to `k/L`.

That is not a worst case; it is the _normal_ case. Linkers insert. Compilers emit one more instruction. A string table gains an entry.

Content-defined chunking (CDC) fixes this by making the boundary a function of the _content in a sliding window_ rather than of the absolute offset. If a boundary is placed wherever the last `w` bytes hash to a distinguished value, then a boundary is a property of those `w` bytes and travels with them. An insertion perturbs boundaries only within one chunk on either side of the edit; the stream **resynchronizes** after at most one chunk.

### The rolling-hash boundary rule, concretely

`casync` uses [buzhash][buzhash] — a cyclic polynomial over a fixed table of 256 random 32-bit words — with a 48-byte window. The entire rule is nine lines of [`src/cachunker.c`][casync-chunker]:

```c
/* casync src/cachunker.c */
uint32_t ca_chunker_roll(CaChunker *c, uint8_t leave, uint8_t enter) {
        c->h = rol32(c->h, 1) ^
               rol32(buzhash_table[leave], c->window_size) ^
               buzhash_table[enter];
        return c->h;
}

static bool shall_break(CaChunker *c, uint32_t v) {
        if (c->chunk_size >= c->chunk_size_max)
                return true;

        return (v % c->discriminator) == (c->discriminator - 1);
}
```

Read it as three separate decisions.

1. **The window.** `CA_CHUNKER_WINDOW_SIZE` is 48 bytes ([`cachunker.h`][casync-chunker-h]). The hash depends on exactly those 48 bytes; a byte leaving the window is XOR-ed out at the rotation it entered with. This is what makes the boundary _positional-independent_.
2. **The cut test.** `h % d == d − 1` for a _discriminator_ `d`. Any fixed residue would do; the choice of `d − 1` is arbitrary and shared with `desync`.
3. **The clamps.** A cut is refused before `chunk_size_min` (the scanner literally skips those bytes: _"We don't need to scan the first `chunk_size_min - CA_CHUNKER_WINDOW_SIZE` bytes"_) and forced at `chunk_size_max`. The clamps are what keep the size distribution usable, and they are also the only two places where a boundary is _not_ content-defined.

The defaults are stated in [`cachunker.h`][casync-chunker-h]: `CA_CHUNK_SIZE_AVG_DEFAULT` is 64 KiB, `chunk_size_min` is `avg/4`, `chunk_size_max` is `avg*4`, with hard limits of 1 byte and 128 MiB in [`cachunk.h`][casync-chunk-h].

**The chunk-size math.** If the cut test fires independently with probability `p = 1/d` on each byte past the minimum, the chunk length is `min` plus a geometric variable with mean `d`, so

> **`E[L] = chunk_size_min + d`**, truncated above at `chunk_size_max`.

To hit a target average of `avg` you therefore want `d ≈ avg − min = 3·avg/4`, not `d = avg`. `casync` does not use that closed form; it uses a fitted one, and its comment says why:

```c
/* casync src/cachunker.h */
/* The chunk cut discriminator. In order to get an average chunk size of avg, we cut whenever for a hash value "h" at
 * byte "i" given the descriminator "d(avg)": h(i) mod d(avg) == d(avg) - 1. Note that the discriminator
 * calculated like this only yields correct results as long as the minimal chunk size is picked as avg/4, and the
 * maximum chunk size as avg*4. */
#define CA_CHUNKER_DISCRIMINATOR_FROM_AVG(avg) ((size_t) (avg / (-1.42888852e-7 * avg + 1.33237515)))
```

and, at the call site in [`cachunker.c`][casync-chunker]:

> _"Correct the average chunk size for our cut test. In the relevant range the chunks end up being ~1.32 times larger than the raw configured chunk size since the chunk sizes are not distributed evenly."_

For `avg = 65536` the formula yields `d = 49535`, giving a predicted `E[L] = 16384 + 49535 = 65919` — within 0.6% of the 64 KiB target. Measured on real data below it comes out **8.6% high**, because buzhash values over machine code are not uniform modulo `d`. The fitted constant is a fitted constant.

`desync` reproduces `discriminatorFromAvg` **bit for bit**, including the two floating-point literals ([`chunker.go`][desync-chunker]), which is what lets it claim _"identical output to casync, up to 10× faster"_ ([README][desync-readme]). Its optimisation is instructive: it replaces `h % d == d − 1` with a division-free divisibility test on `h + 1`, using Lemire's modular-inverse trick, and pre-rotates the whole hash table by the window size to remove one `RotateLeft32` per byte. The _rule_ is inviolable — the boundaries must match `casync`'s exactly or the chunk store forks — so all the freedom is in evaluating it.

### The other rolling hash: `zstd:chunked`

`containers/storage` uses a different family. [`pkg/chunked/compressor/rollsum.go`][cs-rollsum] is a vendored copy of Perkeep's `rollsum`, itself derived from `bup`, itself derived from `librsync`: an Adler-32-style pair `(s1, s2)` over a **64-byte** window with a `charOffset` of 31.

```go
// containers/storage pkg/chunked/compressor/rollsum.go
func (rs *RollSum) OnSplitWithBits(n uint32) bool {
	mask := (uint32(1) << n) - 1
	return rs.s2&mask == (^uint32(0))&mask
}
```

The cut test is "the low `n` bits of `s2` are all ones", with `RollsumBits = 16` in [`compressor.go`][cs-compressor] — an average of 65 536 bytes, the same target `casync` picks, reached by a power-of-two mask instead of a division. The differences from `casync` are substantive:

- **No minimum and no maximum chunk size.** A pathological input can produce single-byte chunks. What `casync` gets from clamps, `zstd:chunked` gets from a separate `holesFinder` that detects runs of ≥ 1 KiB of zeros (`holesThreshold`) and emits them as `ChunkTypeZeros` entries carrying no bytes at all.
- **Chunking is _inside_ files.** `casync` explicitly _"remove[s] file boundaries before chunking things up"_ ([README][casync-readme]); `zstd:chunked` restarts the rolling hash at every file, because its unit of reuse is a file and chunks are a refinement of it.

### Measured: what the grain actually buys

To get numbers rather than adjectives, `ca_chunker` was ported to D (48-byte window, the verbatim 256-word `buzhash_table`, `discriminatorFromAvg`, `min`/`avg`/`max` clamps), alongside the `bup` rollsum, a fixed 64 KiB cutter, and a whole-file cutter. Chunks are identified by SHA-512/256, as `casync` does. Subject: `libLLVM.so.21.1`, 187 668 968 bytes, from two NixOS store paths.

**Chunk-size distribution**, `min` 16 KiB / `avg` 64 KiB / `max` 256 KiB, `d = 49535`:

```console
A = libLLVM.so.21.1 (187668968 B)
chunker: min 16384 avg 65536 max 262144 discriminator 49535
max-capped cuts: 60/2622 (2.29%)
content-defined (buzhash)  2622 chunks, mean 71575 B
bup rollsum, 16 bits       2533 chunks, mean 74090 B
```

The predicted mean is 65 919 B; the observed mean is 71 575 B, **8.6% high**, and 2.29% of the cuts were not content-defined at all but forced by `chunk_size_max`. Both rolling hashes land within 3.5% of each other, which is the first result worth stating plainly: _the hash function is not where the leverage is_.

**Experiment 1 — one byte inserted at offset 1 MiB.** This is the catastrophe fixed-size chunking is built to lose:

| Strategy                        | Chunks (A) | Chunks (B) | Bytes of B reused |      Reuse |
| ------------------------------- | ---------: | ---------: | ----------------: | ---------: |
| content-defined, buzhash 64 KiB |      2 622 |      2 622 |       187 580 398 | **99.95%** |
| content-defined, `bup` 16 bits  |      2 533 |      2 533 |       187 597 475 | **99.96%** |
| fixed 64 KiB                    |      2 864 |      2 864 |         1 114 112 |  **0.59%** |
| whole file (OSTree grain)       |          1 |          1 |                 0 |  **0.00%** |

`0.59%` is 17 chunks: the 16 that precede the insertion point plus one coincidental match. The rest of a 179 MiB file is retransmitted to move one byte. Content-defined chunking loses **88 571 bytes** — one chunk's worth — for the same edit. This is the entire argument for CDC, in one row.

**Experiment 2 — the same library built twice.** Two NixOS store paths, same upstream version `21.1.7`, byte-length identical, differing only in embedded store-path strings:

| Strategy                        | Bytes of B reused |      Reuse |
| ------------------------------- | ----------------: | ---------: |
| content-defined, buzhash 64 KiB |       187 443 785 | **99.88%** |
| fixed 64 KiB                    |       186 489 320 | **99.37%** |
| whole file (OSTree grain)       |                 0 |  **0.00%** |

This row is the sharpest thing on the page and it is aimed squarely at [Nix][nix]. Two derivations that differ only in a hash embedded in a path are, to a store keyed by path, _two entirely separate closures sharing nothing_. To a chunk store they are **99.88% the same object**. The path-based identity that gives Nix its correctness guarantees is also what stops it from noticing that it is holding the same 179 MiB twice. Substitutions differing only in an interpreter path or an unused `RUNPATH` entry are exactly this shape, and they are why NixOS store sizes are what they are.

**Experiment 3 — a real point release, `21.1.7 → 21.1.8`**, a genuine recompile of a 179 MiB library:

| Strategy                       |  `avg` | Chunks (B) | Bytes of B reused |      Reuse |
| ------------------------------ | -----: | ---------: | ----------------: | ---------: |
| content-defined, buzhash       | 64 KiB |      2 702 |        35 510 421 | **18.87%** |
| content-defined, `bup` 16 bits | 64 KiB |      2 494 |        33 838 523 | **17.98%** |
| content-defined, buzhash       | 16 KiB |     10 815 |        44 793 481 | **23.80%** |
| content-defined, buzhash       |  4 KiB |     43 689 |        50 654 865 | **26.91%** |
| fixed 64 KiB                   |      — |      2 872 |           131 072 |  **0.07%** |
| whole file (OSTree grain)      |      — |          1 |                 0 |  **0.00%** |

Three findings. **Fixed-size chunking dies** (0.07%) because a recompile is a dense sequence of insertions. **CDC survives but does not work miracles**: 19% of a recompiled binary is reusable, not 90%, because a code change shifts addresses in relocations and offsets scattered throughout the file, and any chunk containing one of them differs. **Halving the chunk size buys reuse and costs index**: 64 KiB → 4 KiB moves reuse from 18.87% to 26.91% while multiplying the index by 16×.

**Experiment 4 — a directory tree, where OSTree's grain wins.** Two `dmd` compiler trees, `2.110.0` and `2.112.1` (730 and 748 files, ~120 MiB), serialized with a normalized `tar` (`--sort=name --mtime=@0`) so that chunking sees the same input a `.catar` would:

| Strategy                        | Bytes of B reused |      Reuse |
| ------------------------------- | ----------------: | ---------: |
| **file granularity (OSTree)**   |         5 637 792 |  **4.48%** |
| content-defined, buzhash 64 KiB |         3 272 490 |  **2.59%** |
| content-defined, buzhash 16 KiB |         8 298 321 |  **6.56%** |
| content-defined, buzhash 8 KiB  |        11 354 912 |  **8.97%** |
| content-defined, buzhash 4 KiB  |        15 495 258 | **12.24%** |
| fixed 64 KiB                    |                 0 |  **0.00%** |

At its default chunk size **`casync` loses to OSTree on this tree** — 2.59% against 4.48% — and only overtakes it at a 16 KiB average. The mechanism is simple: a tree of many small files packs dozens of them into one 64 KiB chunk, so a single changed file poisons every unchanged file sharing its chunk. Poettering's _"small files are lumped together with their siblings"_ is stated in the README as an advantage, and on a tree whose changes are file-shaped it is a liability. **There is no grain that is right for all inputs**, which is why the `--chunk-size=` knob exists and why the announcement post describes tuning it as the repository administrator's job.

> [!WARNING]
> Every measurement above is _pre-compression_ logical reuse: it counts bytes of the new artifact whose chunk is already present. Real transfer sizes are smaller because chunks are stored compressed (`zstd` in current `casync`/`desync`; the 2017 announcement says `xz`, and the README now says `zstd` — the post has drifted from the code). The ratios are what is being compared, not the absolute bytes.

---

## Format identity and multiplicity

**Multiplicity 0, and the zero is the finding.** Nothing in this cluster is a polyglot, and the reason is structural rather than incidental: _there is no artifact_. A `casync` deployment is a `.caibx` file plus a `.castr` directory of tens of thousands of `.cacnk` files; an OSTree repository is a `objects/` tree of `.filez`, `.dirtree`, `.dirmeta`, and `.commit` files plus `refs/`; an OCI image is a manifest plus N blobs. The unit of distribution is a _set of files related by hash_, and a set of files cannot be simultaneously a PE image and a shell script.

This is the exact inverse of [APE][ape] and the whole [ZIP-parasitism][zip] ecosystem, and it is worth stating as a contrast rather than an omission. Those formats achieve reach by making _one_ byte stream satisfy many parses. These achieve reach by making a _large_ byte stream decompose into many independently-named pieces. Both are answers to "how does a thing get somewhere and work"; they are answers at opposite ends of the granularity scale, and they compose badly, because a chunk store's efficiency depends on the input being _stable_, and a polyglot's construction depends on the input being _carefully misaligned_.

Where a serialization format does exist, its design is dictated by the chunker. `casync`'s `.catar` is a tar replacement, and the announcement is explicit that its most important property is not what it records but what it _does not_:

> _"The file system serialization format is nicely composable. By this I mean that the serialization of a file tree is the concatenation of the serializations of all files and file sub-trees located at the top of the tree, with zero meta-data references from any of these serializations into the others. This property is essential to ensure maximum reuse of chunks when similar trees are serialized."_
> — [casync announcement][casync-blog]

**No back-references, because a back-reference is a pointer, and a pointer contains an offset, and an offset changes when anything before it changes.** That is the same reasoning that makes ZIP's absolute `relative offset of local header` a liability under a prefix ([ZIP parasitism][zip]) — restated as a positive design constraint. It is also, precisely, why _tar_ is a bad input to a chunker and `.catar` is a good one: `tar` is stream-scanned with per-entry headers containing sizes and (unless normalized) timestamps, so a rebuild perturbs headers throughout.

The one place multiplicity appears at all is `zstd:chunked`, and it appears as **backwards compatibility rather than polyglottism**. A `zstd:chunked` layer is a valid `application/vnd.oci.image.layer.v1.tar+zstd` blob; its index rides in `zstd` _skippable frames_, which RFC 8478 requires decoders to ignore. An unaware client decompresses it and gets the `tar`. That is [hole tolerance][concepts-tolerance] used exactly as the concepts page describes: the format reserves a region a foreign payload may occupy, and neither format bends. Contrast [`eStargz`][fif], which achieves the same trick by appending its TOC as extra `tar` entries plus a gzip footer.

---

## Index anchoring and random access

### Where each index lives

| System         | Index                                                                                         | Anchoring                  | Size                           | Found by                                         |
| -------------- | --------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------ | ------------------------------------------------ |
| `casync`       | `.caibx` / `.caidx`: `CaFormatIndex` header + `CaFormatTable` of `(offset, 32-byte chunk id)` | **Out-of-band**            | 40 bytes per chunk             | the URL you were given                           |
| OSTree         | `commit` → `dirtree`/`dirmeta` → content objects                                              | **Out-of-band**, recursive | one object per directory       | `refs/`, or the `summary` file                   |
| OCI image      | manifest → array of layer descriptors                                                         | **Out-of-band**, one level | one descriptor per layer       | tag → manifest digest                            |
| `zstd:chunked` | JSON TOC in a `zstd` skippable frame near EOF, plus a 64-byte binary footer                   | **Footer**                 | proportional to the file count | a layer annotation, _not_ the footer (see below) |

`casync`'s index is a flat array and nothing else. [`caformat.h`][casync-format] defines it in twenty lines: a `CaFormatIndex` header carrying `feature_flags` and the three chunk sizes, then `CaFormatTableItem { le64 offset; uint8 chunk[32]; }` repeated, then a `CaFormatTableTail` with a marker. Each entry stores the chunk's _end_ offset, so a chunk's size is a subtraction — `desync`'s [`index.go`][desync-index] does exactly that when converting to its own `IndexChunk { ID, Start, Size }`.

At 40 bytes per entry, the index cost is a direct function of the grain, and the two ends of the earlier measurements bracket it:

| Grain        | Chunks for 179 MiB | Index size | Index as % of payload |
| ------------ | -----------------: | ---------: | --------------------: |
| `avg` 64 KiB |              2 622 |    104 880 |            **0.056%** |
| `avg` 16 KiB |             10 674 |    426 960 |            **0.227%** |
| `avg` 4 KiB  |             43 917 |  1 756 680 |            **0.936%** |

A 16× finer grain buys 8 percentage points of reuse on a point release and costs 0.88 percentage points of index. On that trade the fine grain wins outright — until you count the _store side_, where 43 917 chunks means 43 917 files, 43 917 HTTP `GET`s in the worst case, and a directory fan-out that `casync` mitigates with a two-level layout: `ca_chunk_id_make_path` writes the chunk's first four hex digits as a directory prefix ([`cachunkid.c`][casync-chunkid]), exactly as OSTree writes two (`objects/<2 hex>/<62 hex>`, [`ostree-core.c`][ostree-core]) and Git writes two.

### What a partial fetch costs

This is where the four systems diverge most sharply.

| System           | To get one file / range you fetch…                                 | Requests            | Wasted bytes                     |
| ---------------- | ------------------------------------------------------------------ | ------------------- | -------------------------------- |
| OSTree `archive` | the `commit`, then `dirtree`s down the path, then the one `.filez` | O(depth) + 1        | none                             |
| `casync`         | the `.caibx`, then one `.cacnk` per covering chunk                 | 1 + O(bytes/64 KiB) | up to one chunk on each end      |
| OCI              | the whole layer blob containing the file                           | 1                   | **the entire rest of the layer** |
| `zstd:chunked`   | the TOC (one range read), then merged ranges over the _same_ blob  | 1 + few             | the merge slack (see below)      |

OSTree's per-file addressing is why it needs no delta machinery for the incremental case — and precisely why Poettering called it _"unfriendly to CDNs"_. `docs/formats.md` concedes the point in the project's own words:

> _"The biggest disadvantage of this format is that for a client to perform an update, one HTTP request per changed file is required."_
> — [`docs/formats.md`][ostree-formats]

OSTree's answer is a materialized view: **static deltas**, precomputed server-side between two named commits, stored at `deltas/$fromprefix/$fromsuffix-$to`, and — the interesting part — not data but a program:

> _"one critical thing to understand about the design is that delta payloads are a bit more like "restricted programs" than they are raw data. There's a "compilation" phase which generates output that the client executes."_
> — [`docs/formats.md`][ostree-formats]

That is `casync`'s objection made concrete: deltas exist per _pair_ of commits, so the server's storage grows with the number of pairs it wants to serve, and the client's update path depends on which pairs the administrator chose to precompute. A chunk store has no pairs. This is the same [materialized-view][concepts-mv] failure mode the concepts page names — the view is precomputed against assumptions, and the assumption here is "which version are you upgrading _from_".

`zstd:chunked`'s partial fetch is the most carefully engineered of the four, because it is fetching ranges of _one_ blob over HTTP and range requests are not free. [`storage_linux.go`][cs-storage] caps outstanding ranges at `maxNumberMissingChunks = 1024` and merges any two ranges separated by less than `autoMergePartsThreshold = 1024` bytes, deliberately downloading the gap rather than paying for another range:

```go
// containers/storage pkg/chunked/storage_linux.go
const (
	maxNumberMissingChunks  = 1024
	autoMergePartsThreshold = 1024 // if the gap between two ranges is below this threshold, automatically merge them.
)
```

Registries are required to cooperate: the distribution spec says a registry _"SHOULD support the `Range` request header in accordance with RFC 9110 (section 14)"_ ([`spec.md`][oci-dist]). The general pattern — an index fetched first, then targeted ranges — is [range-request access][rra]'s subject; `zstd:chunked` is its container-shaped instance.

### The footer that nobody reads

`zstd:chunked` writes a 64-byte footer as the last skippable frame, carrying the TOC's offset and lengths and the magic `GNUlInUx`. It also records the same information in two OCI **annotations**, `io.github.containers.zstd-chunked.manifest-position` and `…manifest-checksum`. The comment on the footer struct is remarkable, and it is a finding about footer-anchoring in general:

```go
// containers/storage pkg/chunked/internal/minimal/compression.go
// ZstdChunkedFooterData contains all the data stored in the zstd:chunked footer.
// This footer exists to make the blobs self-describing, our implementation
// never reads it:
// Partial pull security hinges on the TOC digest, and that exists as a layer annotation;
// so we are relying on the layer annotations anyway, and doing so means we can avoid
// a round-trip to fetch this binary footer.
```

The reference implementation carries a footer index it never consults, purely so the blob remains **self-describing** when separated from its manifest. A footer costs one extra round trip (you must fetch the tail before you know where anything is); an out-of-band annotation is already in your hands when you have the manifest. Both are kept, and the redundancy is the price of [thesis 2][concepts-thesis2] — self-description is what makes the blob survivable outside the system that produced it, even when the producing system never uses it.

---

## Reflexivity and query surface

**Reflexivity 1, and the score is generous.** There is no general query surface anywhere in this cluster. What exists is a fixed menu:

- `casync list`, `casync mtree` (a BSD `mtree(5)`-compatible manifest), and `casync digest` — the last of which answers a genuinely reflexive question, _"what is the identity of this tree under exactly this metadata policy"_, tunable with `--with=`/`--without=` down to individual `chattr(1)` flags.
- `ostree ls`, `ostree log`, `ostree diff` over the object graph; `ostree summary` produces an enumerable ref listing precisely because the raw repository is not enumerable.
- A `zstd:chunked` TOC _is_ structured data — JSON, versioned, with one `FileMetadata` per entry — but it is consumed by one program for one purpose.

The interesting reflexivity is not in the CLIs. It is in the fact that **each of these systems hand-rolled a database index and can be caught doing it**, which is [thesis 1][concepts-thesis1] outside ELF. The clearest specimen is `containers/storage`'s per-layer chunk index, documented as:

> _"Each layer has an associated "big data" key called `chunked-manifest-cache` that is a custom binary format suitable for mmap() that contains index metadata for each layer with the full sha256 digest of each file plus its "chunks""_
> — [`containers-storage-zstd-chunked(1)`][zstd-chunked-doc]

[`cache_linux.go`][cs-cache] builds it as: a version-tagged binary header; a **Bloom filter** over the digests, sized at `bloomFilterScale = 10` bits per entry with `bloomFilterHashes = 3`; a sorted array of fixed-width tags searched by `findBinaryTag`; and side arrays for file locations and names. `findDigestInternal` consults the Bloom filter first and skips the binary search on a miss.

That is a hash index with a Bloom pre-filter over a memory-mapped, sorted, fixed-width key table. It is also, feature for feature, `.gnu.hash` — the bloom-filter-plus-sorted-buckets design the catalog's first thesis calls _a hand-rolled database, badly_. The difference is that this one is honest about being an index, is versioned (`cacheVersion = 3`), and is a _cache_ that can be rebuilt from the TOC, so a schema change is a recompute rather than a compatibility break. **Thesis 1 is confirmed and its "badly" is complicated**: the reimplementation is real, and this instance is competent.

The absence of a query layer is nonetheless a genuine gap with a concrete cost, visible in `casync`'s garbage collector. `casync gc BLOB_INDEX|ARCHIVE_INDEX...` takes the index files as **roots**, opens each one, and inserts every chunk ID into a set ([`gc.c`][casync-gc]) before sweeping the store. Mark and sweep, over a set, with the roots supplied on the command line. There is no query that answers "which chunks are unreachable"; there is a program that computes it. That is exactly the shape [the SELF GC open question][open] asks about, already built once, in C, with the roots problem solved by _making the operator name them_.

---

## Closure, dedup, and size model

**Closure 3 — the defining axis.** These systems exist for no other reason.

### The Closure axis has a hidden third value

The catalog's [Closure axis][concepts-closure] is described as a scale from "does not carry its dependencies" to "carries them". The measurements above show that binary framing is wrong, because it conflates two systems that behave completely differently at scale:

| Model                          | Carries dependencies? | Second artifact costs       | Example                                           |
| ------------------------------ | --------------------- | --------------------------- | ------------------------------------------------- |
| **Does not carry**             | No                    | nothing, but it may not run | a dynamically linked ELF ([dynamic linking][dyn]) |
| **Carries, private copy**      | Yes                   | the full closure, again     | AppImage; SELF's 5.53 GiB figure                  |
| **Carries, shares by name**    | Yes                   | the new paths only          | [Nix][nix]; SELF `objects.path UNIQUE`            |
| **Carries, shares by content** | Yes                   | the changed _chunks_ only   | `casync`, OSTree, `zstd:chunked`                  |

The third and fourth rows are not the same thing, and Experiment 2 is the proof: two Nix store paths of the _same library_ share **0%** by name and **99.88%** by content. Name-based sharing is exactly as good as the discipline that assigns names, and the discipline that assigns Nix store names deliberately makes the name depend on the whole build recipe — which is what makes it _correct_, and what makes it _blind_. Content addressing is the opposite: it cannot tell you why two blobs are the same, only that they are.

Nix knows this; its `--store` content-addressed derivations and the `nix store optimise` hardlink pass are both attempts to recover content-level sharing _after_ path-level identity has been assigned. `casync`'s answer is simply not to have a name in the first place.

### Where SELF sits, and what it would have to become

[SELF][self] stores an executable's segments as `BLOB` rows in a SQLite database. Within one database, `objects.path UNIQUE` gives it path-level sharing, which is why `self closure` fits 723 executables and 400 libraries into 611.9 MiB against 5.53 GiB for private copies. Across two `self closure` outputs there is **no sharing at all**: each `.self` file is an independent SQLite database, and two databases containing the same `libc.so.6` contain it twice, in full.

So SELF is row three, restricted to a single file. To reach row four it would have to become a _store with an index_, and the shape of that change is unusually well-determined:

1. **Segments become chunks.** `segments` stops holding one `BLOB` per segment and holds `(object_id, seq, chunk_id)` rows referencing a `chunks(chunk_id BLOB PRIMARY KEY, data BLOB)` table. The `.caibx` "flat array of `(offset, id)`" is a table with two columns; it maps onto SQL with no impedance at all.
2. **Identity moves from the path to the bytes.** `chunk_id` is the SHA-512/256 of the chunk. `objects.path` becomes metadata rather than identity — which is exactly the change Experiment 2 says is worth 99.88% on rebuild-identical libraries.
3. **The store outlives the artifact.** Two `.self` files sharing a chunk means the chunk lives somewhere neither of them owns: a `system.db` that both `ATTACH`, or a `.castr` next to them. **At that point the artifact is no longer autological** — it stops being a file whose own bytes are its closure and becomes a file whose bytes are a _reference_ into a store. That is the honest cost, and it is the same cost Nix pays: [thesis 3][concepts-thesis3] says the container is a tax, and content addressing says the _closure_ is a tax that can only be avoided by giving up self-containment.
4. **A GC becomes mandatory**, with roots. `casync gc` shows the minimal viable design: the operator names the index files that are alive; everything unreferenced is swept. The recursive-CTE version of that over a `needs`/`chunks` schema is a few lines, and the hard part — as [the open questions][open] note — is doing it against a database somebody is executing from.

The measurements sharpen the recommendation. Point 1 is worth 18.87% on a recompiled binary at the default grain and 26.91% at 4 KiB; but Experiment 4 says that for a _tree of many small objects_ — which a closure database is — chunking at 64 KiB is **worse** than per-object addressing. A SELF store should therefore chunk _large_ segments and address _small_ objects whole, which is precisely the hybrid `zstd:chunked` arrived at: address files, and refine into chunks only where a file is big enough for it to pay.

### The compression interaction

Compression and dedup fight, and every system here resolves the fight the same way: **compress each unit separately, after chunking**. `casync` stores each `.cacnk` compressed independently; OSTree's `archive` mode _"simply gzip-compresses each content object"_; `zstd:chunked` compresses per file so a client can decompress one file's range without the preceding megabytes. Compressing the concatenation would give better ratios and destroy random access, because a `DEFLATE` or `zstd` stream's state at byte `k` depends on every byte before it — the same property that makes [BGZF and seekable `zstd`][fif] restart their windows on purpose.

The cost is measurable and is the one number this survey does not have: per-chunk compression at 64 KiB gives up the long-range matching a whole-stream compressor would find. The [`zstd:chunked` documentation][zstd-chunked-doc] does not quantify it; neither does `casync`'s. **Unverified.**

---

## Mutability, dispatch, and trust

**Mutability 1.** No artifact here is its own transactional state store. Stores _accumulate_ — chunks are added, GC removes them — but an OSTree deployment is a read-only hardlink farm and a `.caibx` is immutable by construction, since changing a byte changes its digest. What replaces mutability is **versioning by new identity**, which is [image-based systems][image]' pattern: you never modify, you produce a new commit and re-point a ref.

### Content addressing _is_ the verification story

The most important trust property in this cluster is one nobody had to add. If a blob's name is the hash of its bytes, then fetching it and hashing it is a complete integrity check against the name, and the name came from an index whose own integrity you established once. `casync` exploits this to the point of impersonating a block-integrity layer:

> _"Note that in this mode, casync also plays a role similar to "dm-verity", as all blocks are validated against the strong digests in the chunk index file before passing them on to the kernel's block layer."_
> — [casync announcement][casync-blog]

The chain reduces to one signature over one small file: sign the `.caibx`, and every chunk is transitively covered. The announcement admits this was still a to-do at publication (_"you still need to validate the downloaded .caidx or .caibx file yourself, for example with some gpg signature"_), which is exactly the shape of [embedded provenance][prov]'s argument — the hard part is never the hashing, it is deciding what the root of trust covers.

OSTree took the chain further, and where it ended up is directly relevant to [thesis 4][concepts-thesis4]. A deployment is _"primarily composed of a set of hardlinks into the repository"_ ([`docs/introduction.md`][ostree-intro]) — checkout is `linkat(2)` ([`ostree-repo-checkout.c`][ostree-checkout]), not `read`+`write`. Two deployments sharing a file share an **inode**, so two processes executing it map the same physical pages. **OSTree gets deduplication and page sharing from the same mechanism**, because the hardlink is simultaneously the sharing primitive and the identity primitive. That is the property SELF loses by copying segment bytes out of b-tree pages, and it is worth naming as the reference point: a store that dedups by hardlink preserves `mmap` for free, and a store that dedups by row does not.

The hardlink is also OSTree's weakness, and it is the same weakness `casync` warns about for `--hardlink=yes`:

> _"this only works for very specific use-cases where disk images are considered read-only after extraction, as any changes made to one tree will propagate to all other trees sharing the same hard-linked files"_
> — [casync announcement][casync-blog]

Deduplication by hardlink is _aliasing_. Writing through one name corrupts every other artifact that shares the blob — the storage-layer version of the W^X problem [the threat model][threat] tracks, with the blast radius multiplied by the sharing factor. OSTree contains it by mounting `/usr` read-only, and more recently by delegating containment to the kernel: with [`composefs`][ostree-composefs], an EROFS image is generated whose content comes from the object store, an `fs-verity` digest over that image is *"inject[ed] … as metadata into the ostree commit" under `ostree.composefs.v0`, and the commit is signed with Ed25519. Signing an image whose data blocks live in a shared store is exactly the problem [embedded provenance][prov] poses for a mutable artifact, solved by signing a *manifest of digests\* rather than the bytes.

### The partial-pull consistency hazard

`zstd:chunked` introduces a trust problem the other three do not have, and `containers/storage` is unusually candid about it. A partial pull reconstructs a layer from the TOC, not from the layer's bytes; if the TOC disagrees with the `tar` it claims to describe, a partially-pulled image differs from the same image pulled normally — while both satisfy the same manifest. The implementation refuses that situation by default:

```go
// containers/storage pkg/chunked/storage_linux.go
} else if !pullOptions.insecureAllowUnpredictableImageContents {
    // With no tar-split, we can't compute the traditional UncompressedDigest.
    return nil, newErrFallbackToOrdinaryLayerDownload(fmt.Errorf(
        "zstd:chunked layers without tar-split data don't support partial pulls with guaranteed consistency with non-partial pulls"))
```

The escape hatch's own documentation is the strongest warning text in any source read for this page:

> _"This should ALMOST NEVER be set. It allows partial pulls of images without guaranteeing that "partial pulls" and non-partial pulls both result in consistent image contents. […] If this consistency enforcement were disabled, malicious images could be built in a way designed to evade other audit mechanisms."_
> — [`storage.conf`, `insecure_allow_unpredictable_image_contents`][cs-storageconf]

The fix is the **tar-split** data, stored as a second skippable frame and digested in `TOC.TarSplitDigest`: it records the exact `tar` headers and padding, so the client can rebuild the byte-identical uncompressed `tar` and recompute the `DiffID` that the image config already commits to. **An index that lets you fetch part of an artifact creates a second, cheaper way to answer "what is this artifact", and the two answers must be forced to agree.** That is precisely the [parser-differential][pd] shape — two readers, one byte stream, no shared notion of identity — arising not from a legacy format but from a deliberate 2020s design, and it is why the feature is gated at all rather than being simply on. (The gate's own status is documented inconsistently: the shipped `storage.conf` comments `enable_partial_images = "false"`, while [`containers-storage-zstd-chunked(1)`][zstd-chunked-doc] says _"At the time of this writing, support for this is enabled by default in the code."_)

### Dispatch

The dispatch owner is the **consumer**, unambiguously and everywhere. No kernel magic, no shebang, no loader involvement. A `.caibx` is a `.caibx` because you passed it to `casync`; an OCI layer is identified by a `mediaType` string in a manifest the client already trusts. The one near-exception proves the rule: `zstd:chunked` is _dispatched_ by an OCI annotation on the layer descriptor, so a client that does not know the annotation performs a normal pull of the same bytes and gets a correct result. That is graceful degradation by design, and it is the opposite of [`binfmt_misc`][binfmt]'s model, where a magic match at a fixed offset is authoritative and a mismatch is fatal.

---

## Strengths

- **Content addressing makes deduplication a consequence of naming rather than a feature.** No index of "what do I already have" is needed; the name _is_ the query.
- **Content-defined chunking is insertion-proof, measurably.** 99.95% reuse against fixed-size chunking's 0.59% for a single inserted byte, on a 179 MiB library.
- **The boundary rule is 9 lines of code and stable across reimplementations.** `desync` reproduces `casync`'s cuts exactly while running an order of magnitude faster, because everything except the rule is free to change.
- **Grain is a tunable, and the trade is quantified**: 64 KiB → 4 KiB moved point-release reuse from 18.87% to 26.91% at a cost of 0.88 percentage points of index.
- **Static-webserver distribution.** OSTree's `archive` and `casync`'s chunk store both require nothing but `GET`; `zstd:chunked` requires only `Range`. No smart server, which OSTree's `docs/formats.md` argues is a security and compute property, not just a convenience.
- **Integrity comes for free and composes upward.** One signature over one index covers every byte transitively; `casync mkdev` turns that into a `dm-verity`-like guarantee on a block device.
- **OSTree's hardlink checkout gets dedup and page sharing from one mechanism**, which is the reference answer to [thesis 4][concepts-thesis4].
- **`zstd:chunked` degrades gracefully**: an unaware client sees a perfectly ordinary `tar+zstd` layer.

## Weaknesses

- **The artifact stops being one file.** Everything in this cluster trades self-containment for sharing; a chunk index without its store is inert. This is the axis on which the whole catalog's seed artifacts win.
- **No grain is right for all inputs.** On a many-small-files tree, `casync` at its default 64 KiB average achieved 2.59% reuse where OSTree's per-file grain achieved 4.48%.
- **CDC does not rescue a recompile.** 18.87% on a genuine point release; address shifts scattered through a binary poison chunks everywhere.
- **Clamps make some boundaries non-content-defined.** 2.29% of measured cuts were forced by `chunk_size_max`, and those boundaries do _not_ survive an insertion.
- **The discriminator is a curve fit.** `-1.42888852e-7 * avg + 1.33237515` is valid only when `min = avg/4` and `max = avg*4`, says so in the header, and still came out 8.6% high on real machine code.
- **Fine grains explode the store.** 43 917 chunks for one library means 43 917 files and, over `archive`-style HTTP, potentially 43 917 requests — the exact complaint `casync` levelled at OSTree.
- **Hardlink dedup is aliasing.** A write through one path corrupts every artifact sharing the blob; both OSTree and `casync --hardlink=yes` document this as a use-at-your-own-risk mode.
- **Partial pulls create a second answer to "what is this artifact"**, and forcing the two answers to agree requires carrying `tar-split` data whose absence disables the feature.
- **OCI layer dedup is coarse and brittle**: the unit is a whole compressed `tar`, named by its _compressed_ digest, so a recompression duplicates a layer that has not changed.
- **`casync` is dormant.** Last commit June 4, 2023; the announcement post still says SHA-256 and `xz` where the code says SHA-512/256 and `zstd`. `desync` is the maintained implementation.
- **No query surface anywhere.** Every question is answered by a purpose-built program, including garbage collection, whose roots must be named by hand.

---

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                                                | Trade-off                                                                                                             |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Name blobs by the hash of their content                                     | Duplicates collapse with no coordination, and the name doubles as an integrity check                     | The name says nothing about provenance; you cannot ask _why_ two blobs match, only _that_ they do                     |
| `casync`: cut chunks by a rolling hash over a 48-byte window                | Boundaries travel with content, so an insertion perturbs one chunk instead of every subsequent one       | Chunk sizes are a distribution, not a constant; a chunker must be re-derived bit-exactly by any second implementation |
| `casync`: clamp chunks to `[avg/4, avg*4]`                                  | Bounds the tail of the geometric distribution; keeps CDN object sizes sane                               | Boundaries at the clamp are positional, so they do **not** survive insertion — 2.29% of cuts, measured                |
| `casync`: fit the discriminator to a measured curve rather than `avg − min` | The observed distribution is not uniform; the fit lands within 0.6% of the target in the supported range | The constant is valid only for the documented `min`/`max` ratios and was still 8.6% off on real machine code          |
| `casync`: remove file boundaries before chunking                            | Small files lump together, large files split; chunk sizes become independent of the tree's shape         | A single changed small file poisons every unchanged sibling in its chunk — measured as a **loss** to OSTree's grain   |
| `casync`: no back-references in the `.catar` serialization                  | A pointer contains an offset; an offset moves; a moved offset destroys chunk reuse                       | The format cannot express structural sharing; identical subtrees are re-serialized                                    |
| `casync`: index is a flat `(end offset, chunk id)` array, out-of-band       | Trivially parsed, trivially streamed, trivially signed                                                   | 40 bytes per chunk, and the index is useless without a store that may be anywhere                                     |
| OSTree: address a file _with its metadata_ hashed in                        | A checkout must restore mode/`uid`/xattrs; hashing them makes the object self-sufficient                 | Two byte-identical files with different modes are two objects                                                         |
| OSTree: check out by `linkat(2)` into a hardlink farm                       | Deduplication and page sharing from one mechanism; works on any POSIX filesystem                         | Aliasing: a write through one deployment corrupts the others, so `/usr` must be enforced read-only                    |
| OSTree: precompute static deltas per commit pair                            | Recovers batched-update efficiency without giving up static hosting                                      | Server storage grows with the number of pairs; a client on an unanticipated version falls back to per-file fetches    |
| OCI: name layers by their _compressed_ digest                               | The registry can verify and dedup what it actually stores, byte for byte                                 | Recompressing an unchanged layer creates a new blob; dedup is defeated by a `gzip` version bump                       |
| OCI: layer = whole `tar` changeset                                          | Trivially simple to build, apply, and cache; whiteouts express deletion within the same primitive        | The dedup grain is an entire layer: one changed byte means re-fetching every byte of it                               |
| `zstd:chunked`: put the TOC in `zstd` skippable frames                      | The blob stays a valid `tar+zstd` layer, so unaware clients are unaffected                               | The index is inside the thing it indexes, so a naive reader must fetch the tail before it can fetch anything else     |
| `zstd:chunked`: also publish the TOC position/digest as OCI annotations     | The manifest is already trusted and already in hand — no extra round trip                                | The footer becomes redundant; the reference implementation admits it _"never reads it"_                               |
| `zstd:chunked`: address files first, sub-file chunks second                 | Matches the grain of change in container images, where whole files are added and removed                 | Two rolling-hash regimes to reason about; chunking restarts at every file boundary                                    |
| `zstd:chunked`: merge ranges separated by < 1 KiB and cap at 1024 ranges    | HTTP range requests have per-range overhead; downloading a small gap is cheaper than another range       | Deliberately transfers bytes the client already has                                                                   |
| `zstd:chunked`: require `tar-split` for partial pulls by default            | Forces a partial pull to produce byte-identical contents to a full one, verifiable via `DiffID`          | Layers built without it silently fall back to a full pull; the override is documented as _"ALMOST NEVER"_             |
| `casync gc`: roots are the index files named on the command line            | Mark-and-sweep with no ambient notion of "installed"; trivial to implement and to audit                  | The operator is the reachability oracle; forget an index and its chunks are swept                                     |

---

## Sources

- [casync — A tool for distributing file system images][casync-blog] — Lennart Poettering, June 20, 2017: the design brief, the critique of Docker layers and OSTree per-file serving, seeding, reflinks, `mkdev`/`dm-verity`, and the composability requirement on `.catar`
- [`casync` — `src/cachunker.c` and `src/cachunker.h`][casync-chunker] — `ca_chunker_roll`, `shall_break`, `ca_chunker_scan`, `CA_CHUNKER_DISCRIMINATOR_FROM_AVG`, the 48-byte window, the min/avg/max defaults
- [`casync` — `src/caformat.h`][casync-format] — `CaFormatIndex`, `CaFormatTableItem`, `CaFormatTableTail`; [`src/cachunkid.c`][casync-chunkid] — the 4-hex-digit store prefix; [`src/gc.c`][casync-gc] — index files as GC roots
- [`casync` — `README.md`][casync-readme] — file suffixes (`.catar`/`.caidx`/`.caibx`/`.castr`/`.cacnk`), the encode/decode summary, and the prior-art list (LBFS, bup, restic, Venti, zsync)
- [`desync` — `chunker.go`][desync-chunker] — a bit-exact `discriminatorFromAvg`, Lemire divisibility, the pre-rotated table; [`index.go`][desync-index] — `caibx` parsing and the `SHA512/256` feature-flag check; [`README.md`][desync-readme] — parallel chunking, seeds, null seed, self seed, reflinks
- [OSTree — `docs/repo.md`][ostree-repo-md] — object types, what the content hash covers, repository modes, the `summary` file; [`docs/formats.md`][ostree-formats] — `archive` efficiency, the per-file-request disadvantage, static deltas as "restricted programs"
- [OSTree — `docs/introduction.md`][ostree-intro] and [`docs/deployment.md`][ostree-deploy] — deployments as hardlink farms, `/etc` three-way merge, stateroots; [`docs/composefs.md`][ostree-composefs] — `ostree.composefs.v0`, `fs-verity`, Ed25519 commit signatures
- [OSTree — `src/libostree/ostree-core.c`][ostree-core] (`_ostree_get_relative_object_path`) and [`ostree-repo-checkout.c`][ostree-checkout] (`checkout_file_hardlink`)
- [OCI Image Format Specification][oci-spec]: [`layer.md`][oci-layer] (changesets, whiteouts), [`config.md`][oci-config] (`DiffID`, `ChainID`, the `tar-split` note), [`descriptor.md`][oci-descriptor] (digest grammar, verification)
- [OCI Distribution Specification — `spec.md`][oci-dist] — `Range` support, cross-repository blob mounting (`?mount=<digest>&from=<other_name>`)
- [`containers-storage-zstd-chunked(1)`][zstd-chunked-doc] — the format's purpose, the `chunked-manifest-cache`, and the admission that it is not standardized
- [`containers/storage` — `pkg/chunked/internal/minimal/compression.go`][cs-minimal] — `TOC`, `FileMetadata`, skippable frames, the annotation keys, the footer that is never read
- [`containers/storage` — `pkg/chunked/compressor/rollsum.go`][cs-rollsum] and [`compressor.go`][cs-compressor] — the `bup`-derived rolling checksum, `RollsumBits = 16`, `holesThreshold`
- [`containers/storage` — `pkg/chunked/cache_linux.go`][cs-cache] — the Bloom filter + sorted tag table; [`storage_linux.go`][cs-storage] — range merging, `tar-split` consistency enforcement; [`storage.conf`][cs-storageconf] — `enable_partial_images`, `insecure_allow_unpredictable_image_contents`
- Measurements taken for this page on Linux x86-64, August 26, 2026: a D port of `ca_chunker` (verbatim `buzhash_table`, 48-byte window, `discriminatorFromAvg`), the `bup` rollsum, fixed 64 KiB and whole-file cutters, SHA-512/256 chunk identity; subjects `libLLVM.so.21.1` (21.1.7 and 21.1.8, from NixOS store paths) and normalized `tar` serializations of two `dmd` trees
- Related in this tree: [concepts][concepts] · [Nix store closures][nix] · [SELF / selfdb][self] · [footer-indexed formats][fif] · [range-request access][rra] · [ZIP parasitism][zip] · [image-based systems][image] · [embedded provenance][prov] · [threat model][threat] · [parser differentials][pd] · [dynamic linking][dyn] · [`binfmt_misc`][binfmt] · [Cosmopolitan / APE][ape] · [measurement][measurement] · [open questions][open] · [comparison][comparison]
- Adjacent tree: [application packaging][packaging]

<!-- References -->

[casync-blog]: https://0pointer.net/blog/casync-a-tool-for-distributing-file-system-images.html
[casync-repo]: https://github.com/systemd/casync
[casync-readme]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/README.md
[casync-chunker]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/src/cachunker.c
[casync-chunker-h]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/src/cachunker.h
[casync-chunk-h]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/src/cachunk.h
[casync-format]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/src/caformat.h
[casync-chunkid]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/src/cachunkid.c
[casync-gc]: https://github.com/systemd/casync/blob/b4b7e5606f785572b78a43626a27a45fe3df2fbd/src/gc.c
[desync-repo]: https://github.com/folbricht/desync
[desync-readme]: https://github.com/folbricht/desync/blob/ff9ccfab7db1dc89395f56079f4de66626f2af1d/README.md
[desync-chunker]: https://github.com/folbricht/desync/blob/ff9ccfab7db1dc89395f56079f4de66626f2af1d/chunker.go
[desync-index]: https://github.com/folbricht/desync/blob/ff9ccfab7db1dc89395f56079f4de66626f2af1d/index.go
[ostree-repo]: https://github.com/ostreedev/ostree
[ostree-docs]: https://ostreedev.github.io/ostree/
[ostree-repo-md]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/repo.md
[ostree-formats]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/formats.md
[ostree-intro]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/introduction.md
[ostree-deploy]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/deployment.md
[ostree-composefs]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/docs/composefs.md
[ostree-core]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/src/libostree/ostree-core.c
[ostree-checkout]: https://github.com/ostreedev/ostree/blob/1d5a312a3189b0fbd70fe6769aadb19a366fedb2/src/libostree/ostree-repo-checkout.c
[cstorage-repo]: https://github.com/containers/storage
[zstd-chunked-doc]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/docs/containers-storage-zstd-chunked.md
[cs-minimal]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/pkg/chunked/internal/minimal/compression.go
[cs-rollsum]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/pkg/chunked/compressor/rollsum.go
[cs-compressor]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/pkg/chunked/compressor/compressor.go
[cs-cache]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/pkg/chunked/cache_linux.go
[cs-storage]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/pkg/chunked/storage_linux.go
[cs-storageconf]: https://github.com/containers/storage/blob/83cf57466529353aced8f1803f2302698e0b5cb7/storage.conf
[oci-repo]: https://github.com/opencontainers/image-spec
[oci-spec]: https://github.com/opencontainers/image-spec/blob/af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc/spec.md
[oci-layer]: https://github.com/opencontainers/image-spec/blob/af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc/layer.md
[oci-config]: https://github.com/opencontainers/image-spec/blob/af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc/config.md
[oci-descriptor]: https://github.com/opencontainers/image-spec/blob/af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc/descriptor.md
[oci-dist]: https://github.com/opencontainers/distribution-spec/blob/fee21197eb94360ddfa6dda0b7edabcd12456809/spec.md
[buzhash]: https://en.wikipedia.org/wiki/Rolling_hash#Cyclic_polynomial
[concepts]: ./concepts.md
[concepts-closure]: ./concepts.md#closure
[concepts-scope]: ./concepts.md#what-is-out-of-scope
[concepts-tolerance]: ./concepts.md#tolerance-a-partial-order-on-composability
[concepts-mv]: ./concepts.md#terms-used-throughout
[concepts-thesis1]: ./concepts.md#every-binary-format-eventually-reimplements-a-database-badly
[concepts-thesis2]: ./concepts.md#self-description-is-what-makes-a-format-survivable
[concepts-thesis3]: ./concepts.md#the-container-is-a-tax
[concepts-thesis4]: ./concepts.md#mmap-is-the-load-bearing-constraint
[nix]: ./nix-store-closures.md
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[zip]: ./zip-parasitism.md
[fif]: ./footer-indexed-formats.md
[rra]: ./range-request-access.md
[image]: ./image-based-systems.md
[prov]: ./embedded-provenance.md
[threat]: ./threat-model.md
[pd]: ./parser-differentials.md
[dyn]: ./dynamic-linking.md
[binfmt]: ./binfmt-misc.md
[measurement]: ./measurement.md
[open]: ./open-questions.md
[comparison]: ./comparison.md
[packaging]: ../application-packaging/index.md
