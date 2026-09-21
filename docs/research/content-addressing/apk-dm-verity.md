# dm-verity + APK Signature Scheme v4

The Merkle root as a **trust anchor** rather than a name — and the one subject
here that ships its hash tree as a separate file so the verifier never builds
one.

|                    |                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Linux kernel (`dm-verity`, `drivers/md/`); Android verified boot; `apksigner`, IncFS, `adb install --incremental`                               |
| **Level 1**        | **none for `dm-verity`** — it addresses a block range, not a tree; APK v4 inherits the ZIP archive as its "tree"                                |
| **Level 2**        | a fixed-fanout Merkle tree over `data_block_size` blocks (4096 bytes in practice)                                                               |
| **Node model**     | **none** — `dm-verity` sees a linear array of blocks; APK v4 sees one file's bytes                                                              |
| **Entry ordering** | not applicable; geometry is determined by block index, "stored a depth at a time (starting from the root), sorted in order of increasing index" |
| **Digest**         | the hash of the root hash block **and the salt**, hex-encoded (`dm-verity`); the `fs-verity`-shaped root hash inside `hashing_info` (APK v4)    |
| **Documentation**  | [`Documentation/admin-guide/device-mapper/verity.rst`][verity-rst], [APK Signature Scheme v4][aosp-v4]                                          |

> [!NOTE]
> **Scope.** This page covers `dm-verity` and APK v4 as content-addressing
> schemes, and the block-device/file/package contrast they complete with
> [`fs-verity`][cfs]. It is not a treatment of Android Verified Boot, the
> `vbmeta` chain, or the APK Signing Block's v2/v3 cryptography beyond what the
> v4 signature composes with. Its closest sibling here is
> [composefs + fs-verity][cfs]; read that first.

## Overview

### What it solves

`dm-verity` answers a question none of the tree-shaped subjects in this survey
ask: how does a device establish that _everything it will ever read from this
partition_ is the artifact that was signed, without reading the partition
first? The answer is a hash tree built offline, a single root digest carried in
an already-trusted channel, and per-block verification in the block layer.
From [`verity.rst`][verity-rst]:

> `dm-verity` is meant to be set up as part of a verified boot path. This may be
> anything ranging from a boot using tboot or trustedgrub to just booting from
> a known-good device (like a USB drive or CD).
>
> When a `dm-verity` device is configured, it is expected that the caller has
> been authenticated in some way (cryptographic signatures, etc). After
> instantiation, all hashes will be verified on-demand during disk access. If
> they cannot be verified up to the root node of the tree, the root hash, then
> the I/O will fail.

The root digest is where the chain of trust terminates, and the documentation
says so in one sentence about the `<digest>` construction parameter:

> The hexadecimal encoding of the cryptographic hash of the root hash block and
> the salt. **This hash should be trusted as there is no other authenticity
> beyond this point.**

APK v4 answers a narrower question: an APK lives on a read-write partition, is
user-installed, and is often only partially read — exactly the case
[`fs-verity`][cfs] exists for, per [`fsverity.rst`][fsverity]:

> A standard file hash could be used instead of `fs-verity`. However, this is
> inefficient if the file is large and only a small portion may be accessed.
> This is often the case for Android application package (APK) files, for
> example.

The kernel documentation is equally explicit that the two are peers, not
alternatives:

> `fs-verity` does not replace or obsolete `dm-verity`. `dm-verity` should still
> be used on read-only filesystems. `fs-verity` is for files that must live on
> a read-write filesystem because they are independently updated and
> potentially user-installed, so `dm-verity` cannot be used.

### Design philosophy

Both designs push verification _below_ the consumer and keep the digest's
authentication _outside_ the scheme. `dm-verity` does not read its own
metadata header — "the verity kernel code does not read the verity metadata
on-disk header. It only reads the hash blocks which directly follow the
header" — and expects either a userspace tool or a verified kernel command
line to supply the trusted parameters:

> Alternatively, the header can be omitted and the `dmsetup` parameters can be
> passed via the kernel command-line in a rooted chain of trust where the
> command-line is verified.

The kernel's only in-tree way to authenticate the root itself is the optional
`root_hash_sig_key_desc` parameter, which names a `USER_KEY` holding "the
`pkcs7` signature of the roothash", checked against the builtin trusted keyring
at device-construction time ([`dm-verity-target.c`][dmv-target] calls
`verity_verify_root_hash` from the constructor, before the device exists).

APK v4's philosophy is the shipping one: **the tree is an artifact, not a
computation**. [AOSP][aosp-v4] states that the v4 signature "is based on the
Merkle hash tree calculated over all bytes of the APK" and "follows the
structure of the `fs-verity` hash tree exactly (for example, zero-padding the
salt and zero-padding the last block)", and that "Android 11 stores the
signature in a separate file, `<apk name>.apk.idsig`." The separation is the
whole point: the installer hands the prebuilt tree to the kernel, so pages can
be verified as they arrive rather than after the archive has landed.

## How it works

### `dm-verity`: a table line, a root digest, and a second device

A `dm-verity` target is constructed from a flat parameter list
([`verity.rst`][verity-rst]):

```text
<version> <dev> <hash_dev>
<data_block_size> <hash_block_size>
<num_data_blocks> <hash_start_block>
<algorithm> <digest> <salt>
[<#opt_params> <opt_params>]
```

The documentation's own worked example, which is the most compact statement of
the model in this survey:

```bash
dmsetup create vroot --readonly --table \
  "0 2097152 verity 1 /dev/sda1 /dev/sda2 4096 4096 262144 1 sha256 "\
  "4392712ba01368efdf14b05c76f9e4df0d53664630b5d48632ed17a137f39076 "\
  "1234000000000000000000000000000000000000000000000000000000000000"
```

`/dev/sda1` supplies data, `/dev/sda2` supplies the hash tree, and the 64 hex
characters are the identity of 262144 four-kilobyte blocks. The tree itself is
fixed-fanout and block-packed:

> Each entry in the tree is a collection of neighboring nodes that fit in one
> block. The number is determined based on `block_size` and the size of the
> selected cryptographic digest algorithm. The hashes are linearly-ordered in
> this entry and any unaligned trailing space is ignored but included when
> calculating the parent node.

With `sha256` and 4096-byte blocks that is a fanout of 128, which the
documentation draws for `num_blocks = 32768`: root, then `entry_0`/`entry_1`,
then 128 leaves each covering 128 data blocks. Two on-disk formats exist and
differ only in salt placement and digest padding — version `0` (Chromium OS)
appends the salt and packs digests contiguously; version `1`, "the current
format that should be used for new devices", prepends the salt and pads "each
digest with zeroes to the power of two". Two devices built from identical
bytes under the two versions therefore have different root digests: like
[`fs-verity`][cfs]'s descriptor-covering digest, this is a **parameterized**
identity.

Failure policy is a construction-time choice rather than a property of the
scheme — `ignore_corruption`, `restart_on_corruption`, `panic_on_corruption`,
plus the I/O-error variants `restart_on_error`/`panic_on_error`, with
`ignore_corruption` mutually exclusive with the enforcing modes. That
configurability has no analogue anywhere else in this survey: a corrupt
[git][git] object is simply a corrupt object, whereas a corrupt verity block
can be defined to reboot the machine. `check_at_most_once` goes further and
trades the property itself away — verifying each data block only on first read
"provides a reduced level of security because only offline tampering of the
data device's content will be detected, not online tampering."

`dm-verity` is also alone here in carrying **forward error correction**: an
optional Reed-Solomon `RS(255, k)` layer, `k = 255 - fec_roots`, interleaved
across the whole device, invoked only when a hash mismatch or read failure
occurs, and — crucially for the integrity story — "dm-verity validates any
FEC-corrected block against the wanted hash before using it. Therefore, FEC
doesn't affect the security properties of dm-verity." Every other subject
treats a digest mismatch as terminal; this one treats it as an erasure
location.

### APK v4: `.apk.idsig`, complete and stripped

The v4 signature is a small container with three parts ([AOSP][aosp-v4]):

```text
V4Signature
├── hashing_info   -- hash_algorithm, log2_blocksize, salt, raw_root_hash
├── signing_info   -- apk_digest, certificate, additional_data,
│                     public_key, signature_algorithm_id, signature
└── merkle_tree    -- optional; present iff the signature is "complete"
```

The parameter space is deliberately a single point: the hash algorithm is
"only 1 == SHA256 supported", the block size "only 12 (`log2_blocksize`, which
equals 4096 bytes) supported now", and the salt is "used exactly as in
`fs-verity`, 32 bytes max". `apksig`'s
[`V4Signature.java`][apksig-v4] carries the same constants —
`HASHING_ALGORITHM_SHA256 = 1`, `LOG2_BLOCK_SIZE_4096_BYTES = 12`.

The two forms of the file are the finding worth extracting:

> If the v4 signature contains the Merkle tree it's called `_complete_`, and
> without the Merkle tree it's `_stripped_`.

A _complete_ `.apk.idsig` ships the tree; a _stripped_ one ships only the root
hash and the signature over it, because the receiver already has (or will
rebuild) the tree. The install path consumes the complete form: "`adb` expects
the `.apk.idsig` file to be present next to the APK when running the
`adb install --incremental` command", and the streaming `PackageInstaller` API
takes a stripped v4 signature as a separate argument when a file is added to a
session, with `signing_info` "passed into IncFS as a whole blob" and later
retrieved by `PackageManagerService` through an `ioctl` for verification.

v4 does not replace v2/v3; it **requires** one of them. The signature is taken
over a serialized `V4DataForSigning` covering the file size, the hashing
parameters and an `apk_digest` selected from the available v3 or v2 signing
block, so the v4 root hash is bound to the archive identity that the v2+
schemes already define — and those, per [AOSP][aosp-general], work the other
way round entirely: "during validation, v2+ scheme treats the APK file as a
blob and performs signature checking across the entire file."

That is the composition in one line: **v2/v3 give the APK a whole-file identity;
v4 gives the same bytes a block-granular verification structure and signs the
root of it.**

## The six dimensions

### Dimension 1 — node model

**There is none, and for `dm-verity` the absence is total.** The target
addresses `num_data_blocks` blocks of `data_block_size` bytes on a block
device. There is no file, no name, no directory, no mode bit, no symlink — the
filesystem living on the protected device is invisible to the mechanism
protecting it. This is the most extreme reduction in the survey: [Bao][bao] at
least models "one blob"; `dm-verity` models "a numbered block range".

The consequence is that `dm-verity` cannot answer any question this survey's
level-1 subjects exist to answer. It cannot name a subtree, cannot say whether
two trees are equal, cannot dedup a file shared between two images, and cannot
be computed incrementally when one file changes — a single changed byte
rewrites its block, its leaf digest, and the whole path to the root, and that
root is baked into a signed boot artifact. It is content addressing used
exclusively for **authenticity**, never for naming.

APK v4's node model is one step less degenerate and still not a file system
object model: it is the byte sequence of one ZIP archive. The tree structure of
the package — entries, names, directories — is the ZIP central directory,
which v2/v3 cover as an undifferentiated blob and v4 does not model at all.

### Dimension 2 — canonical form and ordering

Not applicable in the entry-ordering sense: there are no named entries. Both
schemes get canonicity the way [Bao][bao] does — the geometry is a function of
the length and the parameters — but unlike Bao the parameters are numerous
enough to matter. `dm-verity`'s digest depends on `version`, `algorithm`,
`data_block_size`, `hash_block_size`, `num_data_blocks` and `salt`; APK v4
collapses that space by permitting exactly one hash algorithm and one block
size, leaving the salt as the only degree of freedom.

The one ordering rule either scheme states is the _layout_ of the hash device
([`verity.rst`][verity-rst]):

> Directly following the header (and with sector number padded to the next hash
> block boundary) are the hash blocks which are stored a depth at a time
> (starting from the root), sorted in order of increasing index.

Breadth-first by level, index-ordered within a level — an offset arithmetic
rule, not a comparison function. Note the direction: `dm-verity` stores the
tree **root-first**, which is what lets a reader seek to a node's parent
without an index, and is the opposite of [Bao][bao]'s pre-order interleave of
parents with payload.

### Dimension 3 — level-1 composition

Absent. Neither scheme composes children into a parent by name. The only
composition present is the _external_ one: for Android, `dm-verity` protects
the system partition, whose root digest is carried in a signed `vbmeta`
structure, and individual user-installed APKs are protected one file at a time
by v4/`fs-verity`. Where [OSTree][ostree] and [composefs][cfs] chain a signature
down through a tree of digests, this pair chains a signature down to a _device_
and then starts again, separately, per package.

### Dimension 4 — level-2 granularity

This is the dimension both schemes actually inhabit, and their answers are
nearly identical: fixed 4096-byte blocks, a fixed-fanout tree over block
digests, zero padding of the final partial block, and a salt folded into every
hashed block. The block size is nominally configurable in `dm-verity`
(`data_block_size` and `hash_block_size` are independent parameters — though
FEC requires them equal) and effectively frozen in APK v4.

Compare the field: [Bao][bao] uses 1024-byte BLAKE3 chunks grouped into 16 KiB
I/O blocks and derives interior nodes from the hash function's own tree mode;
this pair uses 4096-byte blocks matching the page size, because the verification
has to happen exactly where a page is faulted in.

### Dimension 5 — digest

`dm-verity`'s digest is "the cryptographic hash of the root hash block and the
salt", hex-encoded on the target line, with the algorithm named separately
("like `sha1`") and no self-describing tag. It is a bare hash of a block, not of
a descriptor — which distinguishes it from [`fs-verity`][cfs]'s digest, a hash
of a `fsverity_descriptor` structure that _includes_ `root_hash`, `data_size`,
`log_blocksize` and `salt`. APK v4 stores the `fs-verity`-shaped
`raw_root_hash` in `hashing_info` beside the parameters that produced it, and
the signature covers the serialized whole, reaching the same binding by an
explicit serialization rather than by a struct layout.

Neither digest is comparable with a `sha256sum` of the same bytes, and the
`dm-verity` digest is not comparable with the `fs-verity` digest of the same
data either. Three closely related mechanisms, three incomparable digests over
identical content.

### Dimension 6 — partial verification

Complete, at block granularity, and — like [`fs-verity`][cfs] — **mandatory**.
A consumer holding only the root can verify any single block by reading the
path from that block to the root — a depth logarithmic in the device size, four
levels at most for the sizes in the documentation's own diagram — which is the
entire reason for the design.
Sequential reads are nearly free because the bottom-level hash block is usually
already cached; [`fsverity.rst`][fsverity] quantifies the same optimization for
both mechanisms:

> This optimization, which is also used by `dm-verity`, results in excellent
> sequential read performance. This is because usually (e.g. 127 in 128 times
> for 4K blocks and SHA-256) the hash block from the bottom level of the tree
> will already be cached and checked from reading a previous data block.
> However, random reads perform worse.

APK v4 adds the property that makes it worth a page in this survey: because the
tree _travels with the artifact_, the verifier's cost at install time is a
signature check over a few hundred bytes rather than a full pass over the APK.
Partial verification is normally a property a consumer gains by building a
tree; v4 makes it a property a consumer **receives**.

## Three scopes, one primitive

| Scope        | Mechanism          | Unit protected                                   | Tree built by                                         | Root anchored by                                                                 |
| ------------ | ------------------ | ------------------------------------------------ | ----------------------------------------------------- | -------------------------------------------------------------------------------- |
| Block device | `dm-verity`        | a read-only partition (`num_data_blocks` blocks) | an offline tool (`veritysetup format`)                | a verified kernel command line, a signed boot image, or `root_hash_sig_key_desc` |
| File         | [`fs-verity`][cfs] | one file on a live read-write filesystem         | the kernel, at `FS_IOC_ENABLE_VERITY` time            | trusted userspace, IMA/IPE policy, or a builtin PKCS#7 signature                 |
| Package      | APK v4             | one APK's bytes, before and during install       | the _packager_ (`apksigner`), shipped in `.apk.idsig` | the v4 signature, bound to the v2/v3 `apk_digest`                                |

The axis that separates them is **who computes the tree and when**, and it runs
in one direction: offline tool → kernel-on-demand → shipped alongside. Only the
third removes the computation from the verifier entirely. The identical
mechanics underneath (4096-byte blocks, fixed fanout, salted, zero-padded) are
what let APK v4 declare itself `fs-verity`-shaped and hand its tree to IncFS
for the kernel to enforce.

## Strengths

- **The digest is an anchor, not a name** — the whole design assumes the root
  arrives through a trusted channel, which makes the scheme composable with any
  signing policy and committed to none.
- **Verification is unskippable and block-granular**, in the block layer
  (`dm-verity`) or the page-fault path (`fs-verity`/IncFS).
- **A prebuilt tree can be shipped** (`.apk.idsig`), turning partial
  verification from something a consumer earns into something it receives.
- **Forward error correction is integrated with the hashes**, using mismatches
  as erasure locations and re-checking every corrected block — recoverability
  without weakening integrity.
- **Policy on failure is explicit and configurable** (`ignore_`/`restart_`/
  `panic_on_corruption`), which no other subject here offers.

## Weaknesses

- **No file system object model at all** — `dm-verity` cannot name, compare,
  dedup or incrementally update anything; it is unusable as an addressing
  scheme for a tree.
- **A one-byte change rewrites the root**, and the root is embedded in a signed
  artifact, so every update is a full re-sign.
- **Parameterized, mutually incomparable digests** — version `0` versus `1`,
  block size, salt, and `dm-verity` versus `fs-verity` framing all produce
  different values for identical bytes.
- **Two or three artifacts to keep consistent**: data device plus hash device
  (plus FEC device); APK plus `.apk.idsig`.
- **Read-only by construction**, and `dm-verity` additionally requires the
  protected content to be an entire block device image.
- `check_at_most_once` and `ignore_corruption` are documented escape hatches
  that silently reduce the guarantee.
- APK v4's single supported hash algorithm and block size are stated as
  "supported now", i.e. as implementation limits rather than as a designed
  canonical form.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                                          | Trade-off                                                                                     |
| --------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Address blocks, not file system objects             | Protects everything on the device, including the filesystem metadata itself        | No naming, no subtree identity, no incremental update; unusable for a content-addressed store |
| Build the tree offline and pass the root in         | Verification starts at block zero with no bootstrap pass                           | The image is immutable and every change is a full rebuild plus re-sign                        |
| Keep the hash tree on a separate device/offset      | Data blocks stay byte-identical to the unprotected image                           | A second region to place, size and keep in sync                                               |
| Put the salt in the digest and prepend it per block | Precomputed-hash attacks and cross-image digest reuse are blocked                  | The digest is parameterized and not comparable with a plain content hash                      |
| Store the tree root-first, level by level           | A node's parent is reachable by arithmetic; no index to distribute                 | Layout is fixed; the format version changes the digest                                        |
| Integrate Reed-Solomon FEC with the hash check      | Corruption becomes recoverable without weakening the guarantee                     | Correcting one block may read ~254 others; a third artifact to generate                       |
| Make the corruption response a target option        | One mechanism serves a phone, a server and a debug image                           | The security property is a deployment choice, not a property of the digest                    |
| Ship the Merkle tree beside the APK (`.apk.idsig`)  | The kernel can verify pages as they stream in; install needs no full pass          | A second file that must accompany the artifact everywhere                                     |
| Define _complete_ and _stripped_ forms              | The tree is redundant once the receiver holds it; only the signed root must travel | Two on-disk shapes for one logical signature, and callers must know which they hold           |
| Require a v2/v3 signature underneath v4             | The root hash is bound to an existing whole-archive identity                       | v4 alone authenticates nothing; three schemes now coexist per APK                             |

## Sources

- [`Documentation/admin-guide/device-mapper/verity.rst`][verity-rst] — construction parameters, the trust statement about `<digest>`, the hash-tree fanout diagram, the on-disk layout, FEC, and the `veritysetup` worked example
- [`Documentation/filesystems/fsverity.rst`][fsverity] — the APK use case, the "does not replace or obsolete `dm-verity`" statement, the shared caching optimization, the descriptor
- [`drivers/md/dm-verity-target.c`][dmv-target] — the constructor's `verity_verify_root_hash` call and the corruption-handling modes
- [`drivers/md/dm-verity-verify-sig.c`][dmv-sig] — `root_hash_sig_key_desc` PKCS#7 verification against the trusted keyring
- [APK Signature Scheme v4][aosp-v4] — `.apk.idsig`, `hashing_info`/`signing_info`/`merkle_tree`, complete versus stripped, IncFS and `adb install --incremental`
- [Application signing][aosp-general] — the APK Signing Block and the v2+ "treats the APK file as a blob" statement
- [`V4Signature.java`][apksig-v4] — `HASHING_ALGORITHM_SHA256`, `LOG2_BLOCK_SIZE_4096_BYTES`, the field layout

> [!NOTE]
> `V4Signature.java` was read through `android.googlesource.com` at
> `refs/heads/main`, which is a moving reference; its constants are quoted only
> where they corroborate the [AOSP documentation page][aosp-v4], which is the
> primary citation for every v4 claim here.

<!-- References -->

[cfs]: ./composefs-fs-verity.md
[bao]: ./bao-blake3.md
[git]: ./git-objects.md
[ostree]: ./ostree.md
[verity-rst]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/admin-guide/device-mapper/verity.rst
[fsverity]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/filesystems/fsverity.rst
[dmv-target]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/drivers/md/dm-verity-target.c
[dmv-sig]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/drivers/md/dm-verity-verify-sig.c
[aosp-v4]: https://source.android.com/docs/security/features/apksigning/v4
[aosp-general]: https://source.android.com/docs/security/features/apksigning
[apksig-v4]: https://android.googlesource.com/platform/tools/apksig/+/refs/heads/main/src/main/java/com/android/apksig/internal/apk/v4/V4Signature.java
