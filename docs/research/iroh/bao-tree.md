# BLAKE3 Verified Streaming (`bao-tree`)

The BLAKE3 hash tree, exposed as a codec: a pure-math library that turns a blob's content hash into an incrementally-verifiable stream, so a downloader detects a single corrupt byte after at most one 16 KiB chunk group — the algorithmic heart of [`iroh-blobs`][blobs].

| Field               | Value                                                                                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate               | `bao-tree`                                                                                                                                                |
| Version             | `0.16.0`                                                                                                                                                  |
| Repository          | [`n0-computer/bao-tree`][repo]                                                                                                                            |
| Documentation       | [docs.rs/bao-tree/0.16.0][docs] · [crates.io][crate]                                                                                                      |
| ALPN(s)             | n/a — `bao-tree` is a codec, not a wire protocol; the transfer ALPN (`/iroh-bytes/4`) is defined by [`iroh-blobs`][blobs]                                 |
| Approx. size (LoC)  | ≈5,600 (`src/`, excl. tests; ≈7,700 with tests)                                                                                                           |
| Category            | Protocols                                                                                                                                                 |
| Upstream spec/draft | [BLAKE3 spec][blake3-spec]; wire-compatible with the [`bao`][bao-crate] crate at block size 0 with a size prefix and a single range ([`lib.rs:196`][lib]) |
| Author / MSRV       | Rüdiger Klaehn (n0); Rust 1.75; `MIT OR Apache-2.0`                                                                                                       |

> [!NOTE]
> This page covers only the `bao-tree` crate and the verified-streaming math. The
> store that persists these trees to disk (`.obao4`/`.sizes4` files, the `redb`
> catalog, partial-entry state machines, the download write path) lives one layer
> up in [`iroh-blobs`][blobs]; its concurrency inventory is in
> [Tokio Concurrency Inventory][concurrency].

---

## Overview

### What it solves

BLAKE3 is not merely a fast hash; internally it computes the digest as a binary
Merkle tree over 1024-byte _chunks_, combining chunk chaining values pairwise up
to a single root. `bao-tree` exposes that internal tree so it can be used for
**verified streaming**: given only a blob's 32-byte root hash, a receiver can pull
the blob (or an arbitrary subset of it) from an untrusted peer and verify each
piece against the root _as it arrives_, aborting the moment a hash fails to match
— before a single unverified byte is surfaced to the application.

This is the property that makes content-addressed transfer safe over a hostile
network: the hash _is_ the request, the answer is deterministic, and tampering is
detected locally within a bounded window. The two problems `bao-tree` solves on
top of raw BLAKE3 are:

1. **Granularity.** Plain BLAKE3's tree bottoms out at 1024-byte chunks, so a
   verified-streaming _outboard_ (the tree of interior hashes) would be roughly
   `size/1024 * 64` bytes ≈ 6.25% of the payload. `bao-tree` makes the leaf
   granularity a _runtime_ parameter — a `BlockSize` — so iroh can hash down to
   16 KiB groups and cut the outboard 16× (see [Chunk groups](#chunk-groups-and-block-size)).
2. **Range queries.** Instead of verifying only whole blobs or single prefixes,
   `bao-tree` encodes an arbitrary sorted set of non-overlapping chunk ranges —
   `[0..1000, 5000..6000]` in one query — interleaving exactly the interior hash
   pairs needed to verify exactly those ranges against the root ([`lib.rs:224`][lib]).

### Design philosophy

The crate is a deliberately narrow, `no-io`-in-spirit codec. Its README states the
compatibility contract that governs the whole design:

> _"The network wire format for encoded data and slices is compatible with the bao
> crate, except that this crate has builtin support for `runtime` configurable
> chunk groups. … It also allows encoding not just single ranges but sets of
> non-overlapping ranges."_ — [`README.md`][readme]

The security guarantee it exists to provide is stated most crisply in the
`iroh-blobs` design note that consumes it:

> _"for every request, there is exactly one sequence of bytes that is the correct
> answer. And the requester will notice if data is incorrect after at most 16 KiB
> of data."_ — [`iroh-blobs/DESIGN.md:5`][design]

Three consequences shape the API, and each matters directly for a D port:

1. **The geometry is pure integer arithmetic.** Every node address, span, offset,
   and outboard size is a closed-form bit trick over a `u64` node index — no
   allocation, no I/O, `const fn` throughout ([`TreeNode`, `lib.rs:545`][lib]).
   This layer is trivially `@safe pure nothrow @nogc` in D.
2. **Hashing uses BLAKE3's _hazmat_ (hazardous-materials) API**, not the one-shot
   `blake3::hash`. Verified streaming needs to hash a _subtree_ starting at a
   non-zero chunk offset and combine chaining values with and without the ROOT
   finalization flag — operations the safe API hides ([`hash_subtree`/`parent_cv`,
   `lib.rs:235`][lib]). A D reimplementation must expose BLAKE3's chunk-counter
   chaining values and parent-merge internals, not just the top-level digest (see
   [Cryptography & identity](#cryptography--identity)).
3. **I/O is a trait parameter, chosen at the call site.** The same traversal logic
   backs a synchronous `Read`/`Write` path, a `tokio`-style async finite-state
   machine, and a "mixed" sync-read/async-send path (three feature-gated modules
   over one core), so the codec never dictates a runtime (see
   [Concurrency & I/O model](#concurrency--io-model)).

---

## How it works

### Chunks, chunk groups, and block size

The atomic unit is the BLAKE3 chunk: `BLAKE3_CHUNK_SIZE = 1024` bytes
([`tree.rs:119`][tree]). A `ChunkNum(u64)` counts chunks; a `BlockSize(u8)` is the
base-2 log of the _chunk group_ size measured in chunks ([`tree.rs:121`][tree]):

```rust
// bao-tree/src/tree.rs:130 — log2(group bytes / 1024)
pub struct BlockSize(pub(crate) u8);
// BlockSize(0) => 1024 B (== a BLAKE3 chunk); BlockSize(4) => 16 * 1024 = 16 KiB
pub const fn bytes(self) -> usize { BLAKE3_CHUNK_SIZE << self.0 }
```

iroh fixes the group size at 16 KiB for every blob:

```rust
// iroh-blobs/src/store/mod.rs:17 — "Block size used by iroh, 2^4*1024 = 16KiB"
pub const IROH_BLOCK_SIZE: BlockSize = BlockSize::from_chunk_log(4);
```

n0 calls this **"n0-flavoured bao"**: interior hashes are stored and transmitted
only down to 16 KiB granularity. Because the outboard has one 64-byte record per
group boundary rather than per 1024-byte chunk, its size drops by a factor of 16
versus classic bao — at the cost that ranges _below_ group granularity cannot be
served straight from stored hashes and must be recomputed from data (see
[the encoded slice](#the-encoded-slice-response-format)).

### Node addressing: the in-order index

A `BaoTree` is fully described by two fields — the geometry contains no data
([`lib.rs:274`][lib]):

```rust
// bao-tree/src/lib.rs:274
pub struct BaoTree {
    size: u64,             // total bytes
    block_size: BlockSize, // log2 of the chunk-group size
}
```

Every node is a `TreeNode(u64)` whose value is its **in-order index** in the binary
tree over chunks ([`lib.rs:545`][lib]). All node relationships are pure bit tricks
on that index — no pointers, no allocation:

| Property        | Formula                                             | Source              |
| --------------- | --------------------------------------------------- | ------------------- |
| `level()`       | `index.trailing_ones()` (0 for a leaf)              | [`lib.rs:612`][lib] |
| `is_leaf()`     | `index & 1 == 0` (leaves are even)                  | [`lib.rs:618`][lib] |
| `mid()`         | `ChunkNum(index + 1)`                               | [`lib.rs:601`][lib] |
| `half_span()`   | `1 << level()`                                      | [`lib.rs:606`][lib] |
| `chunk_range()` | `[mid - span, mid + span)` with `span = 1 << level` | [`lib.rs:738`][lib] |
| `left_child()`  | `index - (1 << (level - 1))`                        | [`lib.rs:680`][lib] |
| `right_child()` | `index + (1 << (level - 1))`                        | [`lib.rs:686`][lib] |
| `root(chunks)`  | `ceil(chunks / 2).next_power_of_two() - 1`          | [`lib.rs:596`][lib] |

Because the level is the count of trailing one-bits, a leaf (index even → zero
trailing ones) has level 0, and the root sits at the highest power-of-two-minus-one
index. Hash-validation errors carry the offending `TreeNode` (or `ChunkNum`) so a
mismatch is positionally attributable ([`io/error.rs:10`][ioerror]).

### The shifted tree

Iterating a tree at a non-zero block size would waste work descending into
sub-group nodes that carry no stored hash. `bao-tree` instead computes a **shifted
tree** whose leaves _are_ the chunk groups, then maps shifted node indices back to
real ones ([`lib.rs:319`][lib]):

```rust
// bao-tree/src/lib.rs:319 — BaoTree::shifted() (block_size == level)
let shift = 10 + level;                       // bits per chunk group (16 KiB => 14)
let full_blocks = size >> shift;
let open_block  = ((size & ((1 << shift) - 1)) != 0) as u64;
let blocks = (full_blocks + open_block).max(1); // a 0-byte blob still has 1 block
let n = blocks.div_ceil(2);
let root = n.next_power_of_two() - 1;          // shifted root node
let filled_size = n + n.saturating_sub(1);      // total nodes in the shifted tree
```

Conversion between the two index spaces is a single bit operation:
`subtract_block_size(n)` appends `n` trailing one-bits (`!(!x << n)`) to descend
into a smaller block size; `add_block_size(n)` strips `n` trailing one-bits
(`x >> n`, or `None` if the node has fewer than `n` of them, i.e. it is too small
to exist in the coarser tree) ([`lib.rs:630`, `lib.rs:643`][lib]).

### Hashing: subtrees and chaining values

Two functions do all the cryptography, both via BLAKE3's `hazmat` module
([`lib.rs:235`][lib]):

```rust
// bao-tree/src/lib.rs:235
fn hash_subtree(start_chunk: u64, data: &[u8], is_root: bool) -> blake3::Hash {
    if is_root {
        blake3::hash(data)                          // whole blob fits one subtree
    } else {
        let mut hasher = blake3::Hasher::new();
        hasher.set_input_offset(start_chunk * 1024); // subtree's chunk counter
        hasher.update(data);
        blake3::Hash::from(hasher.finalize_non_root()) // chaining value, no ROOT flag
    }
}

// bao-tree/src/lib.rs:249
fn parent_cv(left: &blake3::Hash, right: &blake3::Hash, is_root: bool) -> blake3::Hash {
    if is_root { merge_subtrees_root(left, right, Mode::Hash) }
    else       { merge_subtrees_non_root(left, right, Mode::Hash).into() }
}
```

`hash_subtree` hashes a run of chunks as a subtree at a known chunk offset;
`parent_cv` merges the two child chaining values into their parent's. The `is_root`
flag is load-bearing security-critical state: only the single node covering the
_entire_ blob is finalized with the ROOT flag, so a subtree hash can never be
confused with a whole-blob hash (a length-extension / substitution defense inherited
from BLAKE3's design).

### The outboard: interior hashes on the side

An **outboard** stores the interior tree separately from the data, "so that the data
can be used as-is" ([`DESIGN.md:11`][design]). Each record is a 64-byte hash pair —
left child chaining value ‖ right child chaining value ([`io/mod.rs:204`][iomod]):

```rust
// bao-tree/src/io/mod.rs:204 — one outboard record, 64 bytes
pub(crate) fn combine_hash_pair(l: &blake3::Hash, r: &blake3::Hash) -> [u8; 64] {
    let mut res = [0u8; 64];
    res[0..32].copy_from_slice(l.as_bytes());  // left CV
    res[32..64].copy_from_slice(r.as_bytes()); // right CV
    res
}
```

There is exactly one record per _branch node of the shifted tree_, so the record
count is `blocks - 1` and `outboard_size = (blocks - 1) * 64` bytes
([`lib.rs:439`][lib]). A blob of at most one chunk group has an outboard of size 0 —
its root hash alone verifies the single leaf. Two nodes are deliberately _not_
persisted ([`is_relevant_for_outboard`, `lib.rs:476`][lib]): anything below group
level (no stored hash exists) and the **half-leaf** — a final leaf whose midpoint is
at or beyond the blob size (a last group that is at most half full), whose "right"
child is empty and whose hash equals its parent's expected value.

`bao-tree` defines two on-disk layouts:

- **Pre-order** (`PreOrderOutboard`) — the record for node `N` lives at byte
  `pre_order_offset(N) * 64` ([`io/sync.rs:145`][iosync]), where `pre_order_offset`
  counts left-subtree nodes minus set bits plus in-tree ancestors
  ([`pre_order_offset_loop`, `lib.rs:796`][lib]). This is the layout of iroh's
  `.obao4` files and inline outboards. Its doc comment fixes the wire contract:

  > _"Caution: unlike the outboard implementation in the bao crate, this
  > implementation does not assume an 8 byte size prefix."_ — [`io/outboard.rs:101`][iooutboard]

- **Post-order** (`PostOrderOutboard`) — records at `post_order_offset(N) * 64`,
  where offsets are `Stable` (fully left of the current size, never move) or
  `Unstable` (shift as data is appended) ([`PostOrderOffset`, `lib.rs:283`][lib]).
  Post-order is append-friendly for synchronizing growing files, but **iroh-blobs
  uses only the pre-order layout on disk** — post-order is effectively legacy in the
  iroh stack.

### The encoded slice (response format)

Given a query as `ChunkRanges` (`= range_collections::RangeSet2<ChunkNum>`, a sorted
boundary set, [`lib.rs:224`][lib]), the encoder walks
`ranges_pre_order_chunks_iter_ref(ranges, min_level)` — a pre-order traversal that
emits, for each visited branch node whose range intersection is non-empty, a 64-byte
`Parent` pair, and for each needed leaf a `Leaf` of chunk-group bytes (the last may
be short) ([`lib.rs:370`][lib]; [`iter.rs`][iter]). The wire stream is those items
concatenated in traversal order, prefixed by the blob size:

```text
n0-bao encoded slice for (root_hash, ranges):

    size : u64  (little-endian, 8 bytes)          # EncodedItem::Size, first item
    then, in pre-order over the requested ranges:
      Parent : 32-byte left CV ‖ 32-byte right CV  # 64 bytes, one per branch node
      Leaf   : up to 16384 data bytes              # last leaf = size - start_offset
    ... recursing below group level only for partially-requested groups
```

The size prefix is `EncodedItem::Size(u64)` in the streaming path
([`io/mixed.rs:87`][iomixed]) and a literal `size.to_le_bytes()` prepended by iroh's
`create_n0_bao` helper ([`iroh-blobs/src/store/util.rs:430`][blobsutil]).

Two subtleties make the format both compact and honest:

- **Sub-group ranges recurse from data.** `ResponseIterRef` re-instantiates the tree
  at `BlockSize::ZERO` with `min_full_level` set to the real block size, so a fully
  requested group stops at group granularity, but a _partial_ group descends below
  it ([`iter.rs:657`][iter]). For a partially-covered 16 KiB group the encoder calls
  `encode_selected_rec`, which recomputes the sub-tree hashes from the data on the
  fly and interleaves sub-group parent pairs plus only the needed 1024-byte chunks
  ([`io/sync.rs:470`][iosync]) — even though those sub-group hashes were never stored.
- **Ranges past EOF become size proofs.** Before traversal the query is
  canonicalized by `truncate_ranges`: any boundary at or beyond the last chunk is
  turned into an open range, so a request for a blob of _unknown_ size returns the
  final chunk and the hashes that pin the total length ([`rec.rs:26`][rec]). This is
  how a downloader learns and verifies a blob's size without trusting the sender's
  claim.

### Verified decode: the hash-stack machine

Decoding is a pull-parser driven by a stack of _expected_ hashes. Its entire state
is: the response iterator (which recomputes the same traversal from `(size,
block_size, ranges)`), a hash stack seeded with the root, and the reader
([`io/sync.rs:262`][iosync]):

```rust
// bao-tree/src/io/sync.rs:262
pub struct DecodeResponseIter<'a, R> {
    inner: ResponseIterRef<'a>,          // recomputes traversal; not trusted from the wire
    stack: SmallVec<[blake3::Hash; 10]>, // expected hashes; pushed with the root
    encoded: R,
    buf: BytesMut,
}
```

Per traversal item ([`io/sync.rs:313`][iosync]):

- **Parent** → read exactly 64 bytes into `(l_hash, r_hash)`; pop the expected hash;
  if `parent_cv(l_hash, r_hash, is_root) != expected`, fail with
  `ParentHashMismatch(node)`; otherwise push `r_hash` then `l_hash` — but each side
  only when the iterator's `right`/`left` flag says that child's range is non-empty
  (so the stack holds exactly the hashes future items will consume, in order).
- **Leaf** → read `size` bytes; pop the expected hash; if
  `hash_subtree(start_chunk, data, is_root) != expected`, fail with
  `LeafHashMismatch(start_chunk)`; otherwise surface the verified `Leaf`.

Because a node's expected hash is on the stack _before_ its bytes are read, **every
byte is checked against the root chain before it is handed to the application**, and
corruption is localized to a single 16 KiB group. The async FSM keeps the identical
state (`ResponseDecoderInner { iter, stack, encoded }`, [`io/fsm.rs:316`][iofsm]) but
pushes children _before_ comparing the parent hash, "so that we could in principle
continue" past a mismatch ([`io/fsm.rs:417`][iofsm]) — a minor ordering difference
from the sync path, with no effect on what is accepted.

The decode error set is small and positional ([`io/error.rs:10`][ioerror]):
`ParentNotFound(TreeNode)` / `LeafNotFound(ChunkNum)` (EOF — the peer lacks that
part of the tree/data), `ParentHashMismatch(TreeNode)` / `LeafHashMismatch(ChunkNum)`
(tampering or corruption), and `Io`.

### Partial trees and validation

With the `validate` feature, `valid_ranges(outboard, data, ranges)` re-hashes chunk
data against a _possibly incomplete_ outboard and yields the chunk ranges that
verify ([`io/sync.rs:657`][iosync]). iroh-blobs uses this to reconstruct a partial
blob's possession bitfield after a crash — the store can hold a half-downloaded blob
whose outboard covers only the chunks it has, and later prove exactly which ranges
are intact.

---

## Analysis

### Wire format & framing

All multi-byte integers are little-endian; a "CV" is a 32-byte BLAKE3 chaining
value. `bao-tree` defines four byte layouts, all built from the 64-byte hash pair:

| Artifact                        | Layout                                                                                                               | Size / notes                                           |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Outboard record                 | `left CV (32) ‖ right CV (32)`                                                                                       | 64 bytes per shifted-tree branch node                  |
| Pre-order outboard (`.obao4`)   | records concatenated in `pre_order_offset` order; **no header, no size prefix** ([`io/outboard.rs:101`][iooutboard]) | `(blocks - 1) * 64` bytes; `blocks = ceil(size/16384)` |
| Post-order outboard             | records at `post_order_offset * 64`; legacy variant appends `size` as LE `u64`                                       | unused by the iroh store                               |
| Encoded slice (n0-bao response) | `size: u64 LE`, then pre-order interleave of 64-byte parent pairs and leaf bytes (16384 per full group)              | recurses below group level only for partial groups     |

The framing is _self-describing through the tree geometry_, not through length
delimiters: a decoder that knows `(root, size, block_size, ranges)` recomputes the
exact sequence of Parent/Leaf items and their sizes, so the wire carries only hashes
and payload — no per-item tags or lengths. This is what makes the response for a
given `(hash, ranges)` a single canonical byte string. Byte-level compatibility with
the original `bao` crate holds only at block size 0, with a size prefix, and a single
range ([`lib.rs:196`][lib]); iroh's block size 4 is intentionally its own dialect.

Serialization of the higher-level currency types (`Bitfield`, `EntryState`,
collection metadata) belongs to `iroh-blobs` and its `postcard` codec, covered in
[Wire Formats & Serialization][wire] and [Blobs][blobs]; `bao-tree` itself defines
only the four raw layouts above.

### Cryptography & identity

`bao-tree` is a pure consumer of BLAKE3; it implements no cipher, signature, or key
exchange. Its cryptographic surface is exactly the `blake3` (1.8) `hazmat` API
([`blake3::hazmat`][blake3-hazmat]): `Hasher::set_input_offset` +
`finalize_non_root` for subtree chaining values, and `merge_subtrees_root` /
`merge_subtrees_non_root` for parent merging with and without the ROOT flag
([`lib.rs:235`][lib]). The security properties it inherits and relies on:

- **Collision/second-preimage resistance of BLAKE3** — the root hash uniquely pins
  the blob and every subtree, so "there is exactly one sequence of bytes that is the
  correct answer" ([`DESIGN.md:5`][design]).
- **Domain separation via the ROOT flag** — a subtree hash is finalized without the
  ROOT flag and can never equal a whole-blob hash, defeating attempts to pass off an
  interior subtree as a complete blob or to length-extend.
- **Bounded detection window** — because the tree bottoms out at 16 KiB groups, a
  corrupt or malicious byte is caught after at most one group's worth of data, before
  it reaches the application.

The "identity" in this subsystem is _content identity_: a blob's name is its BLAKE3
root hash (`iroh_blobs::Hash`, a 32-byte wrapper). This is distinct from iroh's
_endpoint_ identity, which is an Ed25519 public key (`EndpointId`) — see
[Identity & Cryptography][identity]. The one place the two families meet is that both
use 32-byte values and BLAKE3 appears on both sides (content hashing here; TLS
transcript/key derivation there), but `bao-tree` neither knows nor cares about
endpoints or signatures.

### State machines & lifecycle

The crate contains three explicit state machines, all pure:

1. **Verified decode** — state = `(response-iterator position, hash stack)`, seeded
   with the root; `Parent` pops → verifies → pushes right-then-left (gated by range
   flags), `Leaf` pops → verifies; terminal when the iterator is exhausted
   ([`io/sync.rs:313`][iosync], [`io/fsm.rs:390`][iofsm]). Errors are positional and
   fatal to the stream.
2. **Range-validated encode** — the mirror image: walk the traversal, `load` each
   parent pair from the outboard, verify it against the same hash stack (so a
   corrupt _local_ outboard is caught before it is sent), and write parent pairs and
   leaf bytes; abort with `ParentHashMismatch` / `LeafHashMismatch` /
   `SizeMismatch`, or `ParentWrite` / `LeafWrite` if the receiver hangs up
   ([`io/sync.rs:417`][iosync], [`io/error.rs:91`][ioerror]).
3. **Outboard construction** — a _post-order_ traversal of the data computes leaf
   hashes then parent CVs bottom-up, writing them into a _pre-order_ outboard and
   returning the root ([`outboard`, `io/sync.rs:534`][iosync]). This is the import /
   "compute outboard" step; it reads the whole blob exactly once.

None of these owns a socket, file, timer, or task — lifecycle is entirely "advance
the state machine until the iterator is done or a hash fails." The durable
lifecycle (partial → complete entries, crash recovery, `.bitfield` dirty markers)
is imposed by the `iroh-blobs` store, not by `bao-tree`.

### Dependencies & coupling

| Dependency                   | Role                   | Port implication                                                                                                                                                                                                                      |
| ---------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `blake3` (1.8, `hazmat`)     | load-bearing algorithm | Must expose chunk-counter CVs, `set_input_offset`, `finalize_non_root`, `merge_subtrees_{root,non_root}` — a full BLAKE3, not just one-shot hashing.                                                                                  |
| `range-collections` (0.4.5)  | load-bearing algorithm | `RangeSet2<ChunkNum>` sorted-boundary sets with union/intersection and a zero-copy `split(mid)` on borrowed boundary slices ([`lib.rs:839`][lib]); the split-by-reference trick drives the whole traversal and must be reimplemented. |
| `smallvec`                   | convenience            | Hash stacks are `SmallVec<[Hash; 10]>` — depth ≈ `log2(chunks)`; maps to `SmallBuffer!(Hash, 10)`.                                                                                                                                    |
| `bytes`                      | zero-copy buffers      | `Leaf.data: Bytes`; maps to an owned/refcounted D buffer (`isOwnedIoBuf`) or a GC slice off the hot path.                                                                                                                             |
| `self_cell`                  | convenience            | Owning iterator over `ChunkRanges` ([`iter.rs:682`][iter]); a D fiber or index-based iterator makes it moot.                                                                                                                          |
| `positioned-io` / `iroh-io`  | I/O trait surface      | `ReadAt`/`WriteAt` pread/pwrite; io_uring positioned ops cover these natively.                                                                                                                                                        |
| `futures-lite` (`tokio_fsm`) | async FSM plumbing     | Feature-gated; the fibered EH port needs neither.                                                                                                                                                                                     |
| `genawaiter` (`validate`)    | generator streams      | `valid_ranges` uses a generator; a D fiber makes this trivial.                                                                                                                                                                        |

Feature flags select the I/O flavor: `tokio_fsm` (the async FSM), `validate`
(`valid_ranges`), `serde`, `experimental-mixed` (the sync-read/async-send path used
by `iroh-blobs`'s `ExportBao`), and `fs`. iroh-blobs enables
`experimental-mixed, tokio_fsm, validate, serde`.

The coupling to the rest of the stack is thin and downward: `bao-tree` knows nothing
about iroh; `iroh-blobs` couples _to_ it by fixing `IROH_BLOCK_SIZE = 4` and framing
the n0-bao size prefix. This makes `bao-tree` the most self-contained, cleanly
portable subsystem in the whole survey.

### Concurrency & I/O model

`bao-tree` has **no internal concurrency** — no threads, tasks, channels, locks, or
timers. This is a finding, not an omission: the crate is a codec, and it pushes the
I/O model entirely to the caller through three interchangeable front-ends over one
traversal core:

- **sync** (`io/sync.rs`) — blocking `std::io::Read`/`Write` + `ReadAt`/`WriteAt`.
- **fsm** (`io/fsm.rs`, `tokio_fsm`) — a hand-rolled state machine whose `next()`
  is `async` and returns the machine plus one item, so it drops into any executor.
- **mixed** (`io/mixed.rs`, `experimental-mixed`) — synchronous positioned reads of
  local data, `async` sends of `EncodedItem`s to a `Sender`, for the serve path.

What the crate _is_ is **CPU-bound**: every Parent verifies a BLAKE3 parent merge
and every Leaf hashes up to 16 KiB. A full verified decode or encode of an N-byte
blob performs ≈ `N/16384` group hashes plus ≈ `N/16384` parent merges — pure compute
with no yield points of its own. In the Rust stack this is masked because
`iroh-blobs` runs it inside `tokio` tasks that `.await` between groups; the hashing
still occupies a worker thread, and the store notably does its file I/O with
blocking `std::fs` calls on a dedicated multi-thread runtime rather than offloading
to `spawn_blocking` (see [Tokio Concurrency Inventory][concurrency]).

### Mapping to event-horizon

`bao-tree` is the friendliest subsystem for the [event-horizon][eh-spec] port: the
geometry and both codec state machines are pure and translate almost line-for-line,
while the crate's I/O-agnosticism collapses neatly onto a single tier-B byte-stream
implementation. Two things need deliberate design — buffer ownership and, above all,
the single-threaded implication of CPU-bound hashing.

**The geometry ports to `@safe pure nothrow @nogc` verbatim.** `TreeNode` and its bit
tricks have no I/O and no allocation:

```rust
// bao-tree/src/lib.rs:545 (Rust, verbatim shape)
pub struct TreeNode(u64);
impl TreeNode {
    pub const fn level(&self) -> u32 { self.0.trailing_ones() }
    pub const fn is_leaf(&self) -> bool { (self.0 & 1) == 0 }
    pub fn left_child(&self) -> Option<Self> {
        let offset = 1 << self.level().checked_sub(1)?;
        Some(Self(self.0 - offset))
    }
}
```

```d
// proposed / sketch — pure geometry, no runtime, no GC
struct TreeNode
{
    ulong index;

@safe pure nothrow @nogc const:
    uint level() => cast(uint) trailingOnesCount(index); // popcnt on ~index low bits
    bool isLeaf() => (index & 1) == 0;
    ChunkNum mid() => ChunkNum(index + 1);

    // left/right children exist only for branch nodes (level >= 1)
    Nullable!TreeNode leftChild()
    {
        const lvl = level();
        if (lvl == 0) return typeof(return).init;
        return nullable(TreeNode(index - (1UL << (lvl - 1))));
    }
}
```

**The decoder is a pull parser, not an async task.** Under tier B a byte stream is a
blocking-looking verb (`recv`/`readExact`) that parks the fiber and resumes on the
terminal CQE, so the verified-decode state machine needs no `async`/`Future`
coloring at all — it is a plain struct with a `SmallBuffer` hash stack that reads
from any `isByteStream` source:

```rust
// bao-tree/src/io/sync.rs:262 (Rust, verbatim shape)
pub struct DecodeResponseIter<'a, R> {
    inner: ResponseIterRef<'a>,
    stack: SmallVec<[blake3::Hash; 10]>,
    encoded: R,
    buf: BytesMut,
}
```

```d
// proposed / sketch — verified pull-decoder; hashing runs on the loop fiber
struct BaoDecoder(Reader) if (isByteStream!Reader)
{
    ResponseIter        iter;   // recomputes traversal from (size, blockSize, ranges)
    SmallBuffer!(Hash, 10) stack; // expected hashes, seeded with the root
    Reader              encoded;

    // Blocks the fiber on `encoded` (tier-B), verifies, returns one item.
    IoResult!(Option!BaoContentItem) next()
    {
        auto step = iter.next();
        if (step.isNull) return ok(Option!BaoContentItem.init); // Done
        final switch (step.kind)
        {
            case Step.parent:
                ubyte[64] pair = void;
                if (auto e = encoded.readExact(pair[])) return e.propagate;
                const expected = stack.popBack();
                if (parentCv(pair[0 .. 32], pair[32 .. 64], step.isRoot) != expected)
                    return err!(...)(ParentHashMismatch(step.node));
                if (step.right) stack ~= Hash(pair[32 .. 64]);
                if (step.left)  stack ~= Hash(pair[0 .. 32]);
                return ok(some(BaoContentItem.parent(step.node, pair)));
            case Step.leaf:
                // read `step.size` bytes into an owned buffer, hashSubtree, verify, surface
                ...
        }
    }
}
```

Mapping table for the constructs that do and do not carry over:

| Rust / bao-tree                                    | event-horizon                                                                                                  |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `TreeNode` bit tricks, `BaoTree::shifted`, offsets | Pure D `@safe pure nothrow @nogc` structs/functions — direct translation                                       |
| `SmallVec<[blake3::Hash; 10]>` hash stack          | `SmallBuffer!(Hash, 10)` (depth ≈ `log2(chunks)`, never large)                                                 |
| sync / fsm / mixed I/O front-ends                  | **one** tier-B implementation over `isByteStream` verbs — the three-flavor split disappears                    |
| `Leaf.data: Bytes` (refcounted)                    | an owned buffer (`isOwnedIoBuf`) for the hot path; a refcounted immutable buffer where cheap sharing is wanted |
| `range_collections::RangeSet2<ChunkNum>`           | must be reimplemented, incl. the zero-copy `split(mid)` on a borrowed boundary slice ([`lib.rs:839`][lib])     |
| `genawaiter` generator in `valid_ranges`           | a fiber that yields verified ranges                                                                            |
| BLAKE3 `hazmat` (CVs, ROOT flag)                   | **no equivalent yet** — the port must ship a full BLAKE3 with chunk-counter chaining values and parent merges  |

**Single-threaded implication (flag this).** Under the default `single` topology
there is one loop, one thread, and a started fiber is pinned to it for life; there is
no `spawn_blocking` thread pool. A verified decode/encode of a multi-GiB blob is a
long CPU-bound run of BLAKE3 that **executes on the loop fiber and will monopolize
the loop** for the duration — starving every other connection, timer, and accept.
The Rust stack hides this behind a multi-thread `tokio` runtime; the D port cannot.
Two mitigations, in increasing order of effort:

1. **Insert explicit checkpoints per 16 KiB group.** The traversal already has a
   natural boundary at every Leaf; make `next()` a cancellation/yield point so a
   long transfer cooperatively cedes the loop and honors deadlines
   (`withDeadline`) and cancellation (a parked fiber resumes only at its terminal
   CQE). This bounds latency without adding threads.
2. **Optional worker topology for bulk hashing.** For import of very large local
   files (outboard computation re-hashes the whole blob) or crash-recovery
   `valid_ranges`, an opt-in `workStealing` topology or a dedicated hashing worker
   keeps the accept loop responsive. This is the one place the port genuinely wants
   more than one thread, and it is isolable because the hashing is pure and takes an
   owned buffer in, a hash out — no shared mutable state to lock.

Everything else about the crate is _better_ on event-horizon than on tokio: no
`Send + Sync` tax on the pure structs, no runtime coloring across the three I/O
flavors, and positioned reads/writes (`ReadAt`/`WriteAt`) become native io_uring
read-at/write-at ops with registered fds rather than the store's blocking `std::fs`
calls.

---

## Strengths

- **Provable, incremental verification.** A single 32-byte root hash lets a receiver
  verify arbitrary ranges of a blob from an untrusted peer, detecting tampering
  within one 16 KiB group ([`DESIGN.md:5`][design]).
- **Compact outboards.** Runtime-configurable chunk groups cut the interior-hash
  overhead 16× at iroh's `BlockSize(4)` versus classic 1024-byte bao, while still
  serving sub-group ranges by recomputing hashes from data.
- **Range-set queries.** One request can ask for several disjoint ranges and get a
  single canonical, minimal proof stream interleaving exactly the needed hashes.
- **Canonical, delimiter-free framing.** The response for `(hash, ranges)` is a
  single deterministic byte string; a decoder reconstructs all framing from the tree
  geometry, so the wire carries only hashes and payload.
- **Pure, self-contained core.** No I/O, concurrency, or allocation in the geometry
  and codec state machines — the most cleanly portable subsystem in the survey, and
  `no_std`-friendly in spirit.
- **Size proofs for unknown-size blobs.** `truncate_ranges` turns past-EOF requests
  into verified length proofs, so a downloader never trusts a sender's size claim.
- **I/O-model-agnostic.** One traversal core backs sync, async-FSM, and mixed
  front-ends via feature flags, so it drops into any runtime.

## Weaknesses

- **CPU-bound with no built-in yielding.** The codec hashes every byte and never
  yields on its own; a naïve single-threaded host will stall on large transfers
  (see [Mapping to event-horizon](#mapping-to-event-horizon)).
- **Depends on BLAKE3's hazmat internals.** A reimplementation must expose
  chunk-counter chaining values and parent-merge-with/without-ROOT, not just the
  one-shot digest — a non-trivial slice of BLAKE3 to port correctly.
- **Sub-group ranges cost recomputation.** Because hashes below 16 KiB are not
  stored, serving a partial group re-hashes that group's data
  ([`io/sync.rs:470`][iosync]) — cheaper storage, more serve-time CPU.
- **Two outboard layouts, one used.** Post-order support and its `Stable`/`Unstable`
  offset machinery are legacy within the iroh stack (iroh-blobs is pre-order only),
  yet remain in the surface area a faithful port must understand.
- **`experimental-mixed` is exactly that.** The serve path iroh-blobs relies on is
  behind an experimental feature flag, so its API is not yet stable upstream.
- **Non-trivial range algebra.** The zero-copy `split` on borrowed boundary slices
  ([`lib.rs:839`][lib]) and `range_collections` semantics are load-bearing and must
  be reimplemented precisely for byte-compatible proofs.

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                                     | Trade-off                                                                                          |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Runtime chunk groups (`BlockSize`), iroh fixes 16 KiB                       | 16× smaller outboards than 1024-byte bao; less metadata to store and transmit                 | Sub-group ranges can't be served from stored hashes — must recompute from data at serve time       |
| Store the tree as a separate outboard, not interleaved                      | "data can be used as-is" ([`DESIGN.md:11`][design]); reflink/zero-copy export of the raw file | Two artifacts per blob to keep consistent; a partial download tracks data and outboard separately  |
| BLAKE3 `hazmat` (subtree CVs + ROOT-flag merges)                            | Reuses BLAKE3's proven tree; ROOT-flag domain separation defeats subtree/whole-blob confusion | Ties the codec to hazardous internals; a port can't lean on the one-shot hash API                  |
| In-order `u64` node index with pure bit tricks                              | No pointers/allocation; every relation is a `const fn`; error positions are attributable      | Two index spaces (real vs shifted) plus half-leaf special cases to get exactly right               |
| Pre-order outboard, **no** size prefix ([`io/outboard.rs:101`][iooutboard]) | Append-agnostic, fixed offset per node; matches iroh's `.obao4` on-disk layout                | Diverges from the `bao` crate's prefixed format; compatibility only at block size 0 with a prefix  |
| Canonical, geometry-derived framing (no length tags)                        | One deterministic byte string per `(hash, ranges)`; minimal wire; verifiable framing          | Decoder must independently recompute the traversal; a desync is unrecoverable, not resynchronizing |
| Verify before surfacing (hash stack seeded with root)                       | Bad bytes caught within one 16 KiB group, before the app sees them                            | Every byte is hashed on the read path — pure CPU cost, no shortcut                                 |
| I/O-agnostic core, three feature-gated front-ends                           | One traversal backs sync/async/mixed; the codec never dictates a runtime                      | Three code paths to maintain; `experimental-mixed` (the serve path) is unstable                    |

---

## Sources

- [`n0-computer/bao-tree` — GitHub repository (v0.16.0)][repo]
- [bao-tree on docs.rs (0.16.0)][docs] · [crates.io][crate]
- [`bao-tree/README.md` — wire compatibility, chunk groups, range sets][readme]
- [`bao-tree/src/lib.rs` — `BaoTree`/`TreeNode` geometry, `hash_subtree`/`parent_cv`, shifted tree, offsets][lib]
- [`bao-tree/src/tree.rs` — `ChunkNum`, `BlockSize`, `BLAKE3_CHUNK_SIZE`][tree]
- [`bao-tree/src/iter.rs` — pre/post-order iterators, `ResponseIterRef`, `BaoChunk`][iter]
- [`bao-tree/src/rec.rs` — `truncate_ranges` (size proofs), `encode_selected_rec`][rec]
- [`bao-tree/src/io/mod.rs` — `Parent`/`Leaf`/`BaoContentItem`, `combine_hash_pair`][iomod]
- [`bao-tree/src/io/sync.rs` — sync encode/decode, outboard load/save, `DecodeResponseIter`][iosync]
- [`bao-tree/src/io/fsm.rs` — async `ResponseDecoder` state machine][iofsm]
- [`bao-tree/src/io/mixed.rs` — `EncodedItem`, `traverse_ranges_validated`][iomixed]
- [`bao-tree/src/io/outboard.rs` — `PreOrderOutboard`/`PostOrderOutboard`, "no 8 byte size prefix"][iooutboard]
- [`bao-tree/src/io/error.rs` — `DecodeError`/`EncodeError` (positional)][ioerror]
- [`iroh-blobs/src/store/mod.rs` — `IROH_BLOCK_SIZE = 16 KiB`][blobsstore]
- [`iroh-blobs/src/store/util.rs` — `create_n0_bao` size prefix][blobsutil]
- [`iroh-blobs/DESIGN.md` — verified-streaming rationale, one-correct-answer guarantee][design]
- [BLAKE3 specification (BLAKE3-team)][blake3-spec] · [`blake3::hazmat` API][blake3-hazmat] · [`bao` crate][bao-crate]
- Related iroh pages: [Blobs: Content-Addressed Transfer][blobs] · [Identity & Cryptography][identity] · [Wire Formats & Serialization][wire] · [Tokio Concurrency Inventory][concurrency]

<!-- References -->

[repo]: https://github.com/n0-computer/bao-tree
[docs]: https://docs.rs/bao-tree/0.16.0/bao_tree/
[crate]: https://crates.io/crates/bao-tree
[readme]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/README.md
[lib]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/lib.rs
[tree]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/tree.rs
[iter]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/iter.rs
[rec]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/rec.rs
[iomod]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/mod.rs
[iosync]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/sync.rs
[iofsm]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/fsm.rs
[iomixed]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/mixed.rs
[iooutboard]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/outboard.rs
[ioerror]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/error.rs
[blobsstore]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/mod.rs
[blobsutil]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/util.rs
[design]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md
[blake3-spec]: https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf
[blake3-hazmat]: https://docs.rs/blake3/latest/blake3/hazmat/index.html
[bao-crate]: https://github.com/oconnor663/bao
[blobs]: ./blobs.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[concurrency]: ./concurrency.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
