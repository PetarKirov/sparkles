# Embedded provenance (ELF notes, Go `buildinfo`, `cargo-auditable`, SBOMs, attestations)

What an artifact already says about itself — its build identity, its ABI floor, its package of origin, its module graph — and why the layer above it, the one that _signs_ those claims, is defined in terms the catalog's mutable artifacts cannot satisfy.

| Field           | Value                                                                                                                                                                                                                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Format conventions + linker options + toolchain features, plus an out-of-band attestation layer that never touches the artifact                                                                                                                                                                                           |
| Language        | C++ (`lld`), C (GNU `ld`, `.NET` host), Go (`cmd/link`, `debug/buildinfo`), Rust (`cargo-auditable`), C# (`Microsoft.NET.HostModel`), specification prose (UAPI, in-toto, SLSA)                                                                                                                                           |
| License         | Apache-2.0-with-LLVM-exception (`lld`), GPL-3.0-or-later (GNU `ld`), BSD-3-Clause (Go), MIT OR Apache-2.0 (`cargo-auditable`), MIT (`dotnet/runtime`), CC-BY-4.0 (UAPI.8, SLSA), Apache-2.0 (in-toto, `cosign`)                                                                                                           |
| Repository      | [golang/go][go-repo] · [rust-secure-code/cargo-auditable][ca-repo] · [dotnet/runtime][dotnet-repo] · [llvm/llvm-project][llvm-repo] · [in-toto/attestation][intoto-repo] · [slsa-framework/slsa][slsa-repo] · [sigstore/cosign][cosign-repo]                                                                              |
| Documentation   | [ELF gABI, program header / notes][gabi-phdr] · [`ld` `--build-id`][ld-options] · [UAPI.8 Package Metadata for Executable Files][uapi8] · [`runtime/debug.ReadBuildInfo`][godoc-readbuildinfo] · [slsa.dev][slsa-site] · [in-toto.io][intoto-site] · [reproducible-builds.org][rb-def]                                    |
| First release   | `.note.ABI-tag`: glibc 2.x era · build-id: Fedora 8, 2007 · Go module `buildinfo`: Go 1.12 (2019-02-25), inline format Go 1.18 (2022-03-15) · `.NET` single-file bundles: .NET Core 3.0 (2019-09-23), v2 header .NET 5 · `cargo-auditable` 0.1: 2022 · UAPI.8 v1.0 · in-toto Attestation v1: 2023 · SLSA v1.0: 2023-04-19 |
| Axis profile    | Multiplicity **0** / Reflexivity **2** / Closure **1** / Mutability **0**                                                                                                                                                                                                                                                 |
| Index anchoring | **Mixed by design** — header-anchored (ELF section/segment tables), stream-scanned (Go's magic, the `.NET` bundle marker), and out-of-band (every attestation)                                                                                                                                                            |
| Dispatch owner  | **Consumer** — nothing in the system dispatches on provenance; it is read by whoever chooses to look, which is why it can be absent without anything breaking                                                                                                                                                             |

> **Revisions surveyed:** `golang/go` [`620058f8`][go-repo] (2026-08-25), `rust-secure-code/cargo-auditable` [`e0932726`][ca-repo] (2026-08-22), `llvm/llvm-project` [`73802c2e`][llvm-repo] (2026-06-04), `dotnet/runtime` [`714432e0`][dotnet-repo] (2026-08-26), `systemd/systemd` `9bb06d5c`, `uapi-group/specifications` `1375569c`, `in-toto/attestation` [`2dcd055e`][intoto-repo] (2026-08-24), `slsa-framework/slsa` [`1686afeb`][slsa-repo] (2026-08-06), `sigstore/cosign` [`58aae9e1`][cosign-repo] (2026-08-19), `android/apksig` [`184702d9`][apksig-repo] (2025-03-08), Linux `e43ffb69`. **Platform:** measurements taken on NixOS x86-64 against `gh` 2.96.0 (a Go 1.26.5 binary, 40 356 736 bytes) and `ripgrep` 15.1.0 (a `cargo auditable`-built binary, 6 557 168 bytes) from the local Nix store.

---

## Overview

### What it solves

Five questions get asked about a binary after it has left the machine that produced it, and each has grown its own answer inside the file:

| Question                                         | Mechanism                                  | Where it lives                                                  | Who wrote it                    |
| ------------------------------------------------ | ------------------------------------------ | --------------------------------------------------------------- | ------------------------------- |
| "Which build is this, exactly?"                  | `NT_GNU_BUILD_ID`                          | a `PT_NOTE` segment                                             | the linker, on an opt-in flag   |
| "What is the minimum kernel/ABI it needs?"       | `NT_GNU_ABI_TAG`                           | a `PT_NOTE` segment                                             | the C runtime's startup objects |
| "Which distribution package shipped it?"         | `.note.package` / `.pkgnote` JSON          | an _allocated_ note or COFF section                             | the distribution's build system |
| "What did it link against, and at what version?" | Go `buildinfo`, `.dep-v0`, bundle manifest | a data-segment blob, a non-allocated section, a footer manifest | the toolchain                   |
| "Was it built by whom it claims, from what?"     | SLSA / in-toto / sigstore                  | **nowhere in the file** — a registry or a transparency log      | the build platform              |

The first four are the subject of this page's _format_ half. The fifth is the subject of its argument, because the attestation layer is specified in terms of an immutable subject digest, and this catalog's most interesting artifacts — [SELF and `self-httpd`][selfdb], [redbean under `-*`][ape] — mutate themselves by design.

The line against the [application-packaging tree][packaging] is drawn as follows: how an SBOM is _published, distributed, and consumed by a scanner_ is that tree's subject. What is _inside the byte stream_, and what a signature can therefore cover, is this one's.

### Design philosophy

The single most load-bearing sentence in this entire cluster is in the GNU linker's own documentation of `--build-id` ([`ld` Options][ld-options]):

> _"The `md5`, `sha1`, and `xx` styles produces an identifier that is always the same in an identical output file, but are almost certainly unique among all nonidentical output files. **It is not intended to be compared as a checksum for the file's contents.** A linked file may be changed later by other tools, but the build ID bit string identifying the original linked file does not change."_

Read it twice. The build-id is an _identity_, not an _integrity check_, and it is explicitly specified to **survive mutation of the file it names**. That is the exact property a mutable artifact needs and the exact property a signature cannot have — and the whole tension of [the signing problem](#mutability-dispatch-and-trust) is already latent in it.

`lld` says the same thing from the implementer's side, in a comment that names Fedora as the source of the requirement ([`lld/ELF/Writer.cpp`][lld-writer]):

```cpp
// lld/ELF/Writer.cpp — writeBuildId()
// Fedora introduced build ID as "approximation of true uniqueness across all
// binaries that might be used by overlapping sets of people". It does not
// need some security goals that some hash algorithms strive to provide, e.g.
// (second-)preimage and collision resistance. In practice people use 'md5'
// and 'sha1' just for different lengths. Implement them with the more
// efficient BLAKE3.
```

`--build-id=sha1` does not compute SHA-1 and `--build-id=md5` does not compute MD5; both compute truncated BLAKE3, because the field was never an integrity claim and the length is the only part anyone depends on.

The [UAPI.8 specification][uapi8] states the opposite design pressure — provenance that must be _present in memory_, not merely present in the file:

> _"This metadata is stored as a section in the executable file, so that it will be loaded into memory along with the text and data of the binary, and will be preserved in a core dump. This metadata can also be easily read from the file on disk, so it can be used to identify provenience of files, independently of any package management system, even if the file is renamed or copied."_

And `cargo-auditable`'s README is refreshingly blunt about what embedded provenance is _not_ ([README][ca-readme]):

> _"Software Bills of Materials (SBOMs) do not prevent supply chain attacks. They cannot even be used to assess the impact of such an attack after it is discovered, because **any malicious library worth its bytes will remove itself from the SBOM.** This applies to nearly every language and build system, not just Rust and Cargo."_

An unauthenticated self-description is a convenience for honest builds and worthless against a dishonest one. Everything in the [attestation layer](#sboms-and-the-attestation-layer) exists to close that gap, and it closes it by leaving the artifact entirely.

---

## How it works

### ELF notes: a typed blob table with no index and no schema

The [ELF gABI][gabi-phdr] defines a note as a length-prefixed triple — `n_namesz`, `n_descsz`, `n_type`, then the name and descriptor each padded to 4-byte alignment — packed end to end inside an `SHT_NOTE` section, which is in turn covered by a `PT_NOTE` program header so the loader maps it. There is no count, no offset table, and no registry of types: the _only_ way to answer "which notes does this file carry?" is to walk every note in every `PT_NOTE` and decode it. `(name, type)` is the composite key, and it is unenforced.

[`./self-selfdb/examples/elf-note-buildid.d`][ex-notes] is the runnable companion: it opens `/proc/self/exe`, walks the program headers to each `PT_NOTE`, decodes `NT_GNU_BUILD_ID`, `NT_GNU_ABI_TAG` and any vendor note, and prints the `debuginfod` key derived from the build-id. Its recipe carries a deliberate flag:

```sdl
lflags "--build-id"
```

with the comment that this is _"a **link option**, not a property of the format, and a toolchain that does not ask for one produces an image that cannot name itself."_ That is the first structural fact of this page and it generalizes: **every mechanism surveyed here is opt-in at build time, and absent by default in at least one major toolchain.** `--build-id` is defaulted on by most distributions' compiler drivers and by none of the linkers.

How the identifier is actually computed matters for the signing argument. `lld` hashes the _entire output buffer_ — not a semantic subset — through a two-level tree ([`lld/ELF/Writer.cpp`][lld-writer]):

```cpp
// lld/ELF/Writer.cpp — computeHash()
// Computes a hash value of Data using a given hash function.
// In order to utilize multiple cores, we first split data into 1MB
// chunks, compute a hash for each chunk, and then compute a hash value
// of the hash values.
```

The output is therefore a hash-of-hashes over 1 MiB blocks, computed in parallel and finalized over the concatenated chunk digests — structurally a one-level Merkle tree, and _not_ equal to any plain digest of the file. It is also computed over a buffer in which the note's own descriptor bytes are still zero, since `writeBuildId()` runs after the rest of the image is laid out and then patches the note in place. Both facts recur, in more careful form, in [Authenticode and APK v2](#how-the-deployed-systems-dodge-it). Sizes are fixed by style: 8 bytes for `xx`/`Fast`, 16 for `md5`/`uuid`, 20 for `sha1`, arbitrary for `0xhexstring` ([`SyntheticSections.h`][lld-synth]).

`.note.package` is the richest of the notes and the only one carrying a schema-ish payload. Per [UAPI.8][uapi8] it is a **4-byte-aligned, allocated, NUL-padded, read-only** note with owner `FDO` and type `0xcafe1a7e`, whose descriptor is a single JSON object with conventional keys (`type`, `os`, `osVersion`, `name`, `version`, `architecture`, `osCpe`, `appCpe`, `debugInfoUrl`), and the spec instructs parsers not to assume a fixed key set. GNU `ld` emits it from `--package-metadata=JSON` ([`ld` Options][ld-options]) — again an opt-in flag, again nothing enforcing the content. The PE/COFF twin is a `.pkgnote` section with the same JSON.

### Go `buildinfo`: a magic-delimited blob, located by a scan

Go embeds the richest self-description of any mainstream toolchain, and it does so without a section-name contract on most platforms. `cmd/link` synthesizes a symbol ([`data.go`][go-linker]):

```go
// src/cmd/link/internal/ld/data.go — (*Link).buildinfo()
s := ldr.CreateSymForUpdate("go:buildinfo", 0)
s.SetType(sym.SBUILDINFO)
s.SetAlign(16)

// The \xff is invalid UTF-8, meant to make it less likely
// to find one of these accidentally.
const prefix = "\xff Go buildinf:" // 14 bytes, plus 1 data byte filled in below
```

The 32-byte header is `prefix` (14 bytes), a pointer-size byte, a flags byte (bit 0 = big-endian, bit 1 = the post-Go-1.18 inline format), and 16 reserved bytes that used to hold two target pointers. Two varint-length-prefixed strings follow: the toolchain version, then the module info. The linker also emits a `go:buildinfo.ref` symbol in `.rodata` pointing at the blob, solely so that external linking with `-Wl,--gc-sections` does not garbage-collect the provenance.

The reader is [`debug/buildinfo`][go-buildinfo], and it is the catalog's clearest example of a **bounded stream scan standing in for an index**. It sniffs the container by its first 16 bytes (ELF, PE, Mach-O, fat Mach-O, XCOFF, Plan 9 `a.out`), asks the container for a search window, then brute-forces:

```go
// src/debug/buildinfo/buildinfo.go
const (
    buildInfoAlign      = 16
    buildInfoHeaderSize = 32
)
// Read segment or section to find the build info blob.
// On some platforms, the blob will be in its own section, and DataStart
// returns the address of that section. On others, it's somewhere in the
// data segment; the linker puts it near the beginning.
```

`DataStart()` returns `.go.buildinfo` on ELF and `__go_buildinfo` on Mach-O; `searchMagic` then reads the window in 1 MiB chunks, rejects any hit whose offset is not 16-byte aligned, and keeps going. Misaligned occurrences of the magic — in a string constant, say — are skipped rather than trusted, and because the magic must be 16-byte aligned it can never straddle a chunk boundary, which is why chunked reading is safe.

The module payload is framed by two 16-byte sentinels chosen for improbability ([`modload/build.go`][go-modload]):

```go
infoStart, _ = hex.DecodeString("3077af0c9274080241e1c107e6d618e6")
infoEnd, _   = hex.DecodeString("f932433186182072008242104116d8f2")
```

and the reader validates the framing with a length-and-position check (`len(mod) >= 33 && mod[len(mod)-17] == '\n'`) before stripping 16 bytes from each end. If the check fails, the module info is discarded rather than reported as suspect — a silent degradation, not an error.

Measured on `gh` 2.96.0, the whole thing accounts for itself exactly:

| Field                                 | Bytes    | Value                                                                 |
| ------------------------------------- | -------- | --------------------------------------------------------------------- |
| Header                                | 32       | `ff 20 47 6f 20 62 75 69 6c 64 69 6e 66 3a` `08` `02` + 16 zero bytes |
| Version string (varint 0x08 + data)   | 9        | `go1.26.5`                                                            |
| Module string (varint `e5 3d` + data) | 2 + 7909 | 176 lines: 1 `path`, 1 `mod`, 166 `dep`, 1 `build` ×7 …               |
| **Total**                             | **7952** | = the whole `.go.buildinfo` section (`0x1f10`)                        |

The section sits at file offset `0x2521000`, which is byte 0 of the read-write `LOAD` segment — "the linker puts it near the beginning" is literally true, so the scan terminates on the first chunk. Section flags are `WA`: allocated _and writable_. That single flag is what makes Go's provenance self-readable at runtime (see [Reflexivity](#reflexivity-and-query-surface)) and, incidentally, what makes it writable by the process that carries it.

The build settings are the part most people underestimate. `BuildSetting` is a free-form key/value list whose documented keys ([`runtime/debug/mod.go`][go-mod]) include `-buildmode`, `-compiler`, `-trimpath`, every `CGO_*` variable, `DefaultGODEBUG`, `GOARCH`/`GOOS`/`GOAMD64`, `GOFIPS140`, and the VCS quartet `vcs`, `vcs.revision`, `vcs.time`, `vcs.modified`. The VCS stamp is conditional and the conditions are strict ([`load/pkg.go`][go-pkg]): `-buildvcs` enabled, a non-test package in a main module, the working directory and the module root in the _same_ repository, and the VCS binary present on `PATH` — with `-buildvcs=auto` silently omitting the metadata when the tool is missing. The `gh` binary measured above carries `-trimpath=true` and **no** `vcs.*` settings at all, because it was built by Nix from a source tarball rather than a checkout. Provenance that depends on the build environment's shape is provenance that a hermetic build system deletes.

### `cargo-auditable`: a compressed dependency graph in a section nothing maps

`cargo auditable` wraps `rustc`, calls `cargo metadata` (or reads Cargo's unstable SBOM precursor when `CARGO_SBOM_PATH` is set), serializes a `VersionInfo` to JSON, zlib-compresses it, and synthesizes a one-section object file that is handed to the linker ([`collect_audit_data.rs`][ca-collect], [`object_file.rs`][ca-object]):

```rust
// cargo-auditable/src/object_file.rs — create_metadata_file()
let section = file.add_section(
    file.segment_name(StandardSegment::Data).to_vec(),
    b".dep-v0".to_vec(),
    SectionKind::ReadOnlyData,
);
if let BinaryFormat::Elf = file.format() {
    // Explicitly set no flags to avoid SHF_ALLOC default for data section.
    file.section_mut(section).flags = SectionFlags::Elf { sh_flags: 0 };
};
```

`sh_flags = 0` means **not `SHF_ALLOC`**: the section exists in the file and is never mapped into the process. On Mach-O and PE a symbol is additionally emitted so the linker does not discard it. Extraction is by section name across four containers plus Wasm custom sections ([`auditable-extract`][ca-extract]), and the documented parser is five lines of Python ([`PARSING.md`][ca-parsing]).

Measured on `ripgrep` 15.1.0 from the Nix store (NixOS builds its Rust packages with `cargo auditable`):

| Quantity                              | Value                                      |
| ------------------------------------- | ------------------------------------------ |
| `.dep-v0` size in the binary          | 713 bytes                                  |
| Decompressed JSON                     | 3 265 bytes                                |
| Packages described                    | 42 (1 `root`, kinds `runtime` and `build`) |
| `format` revision                     | `1`                                        |
| Binary size                           | 6 557 168 bytes                            |
| Provenance as a fraction of the image | **0.0109 %** (≈1 in 9 200)                 |

The schema is where this becomes interesting for the catalog. Edges are **integer indices into the `packages` array**, not names — a normalized edge list, i.e. the database move — and the array's order is therefore load-bearing. Because `cargo metadata`'s order is not stable, `cargo-auditable` has to manufacture one ([`auditable_from_metadata.rs`][ca-meta]):

```rust
// cargo-auditable/src/auditable_from_metadata.rs
// This function is the simplest place to introduce sorting, since
// it contains enough data to distinguish between equal-looking packages
// and provide a stable sorting that might not be possible
// using the data from VersionInfo struct alone.
// …
// they're supplied by in arbitrary order by cargo-metadata anyway
// and the order even varies between executions.
packages.sort_unstable_by(|a, b| { … a.id.repr.cmp(&b.id.repr) });
…
package.dependencies.sort_unstable();
```

A canonical order was invented so the artifact would be byte-reproducible, and the price is that **node identity is positional**: renumber the array and every edge in the graph changes meaning. Hold that thought — it is [exactly the `rowid`-under-`VACUUM` problem](#four-things-that-break-it), arrived at independently by a project that never touched a database.

The `format` field's compatibility rule is a small piece of genuine self-description ([`cargo-auditable.schema.json`][ca-schema]): _"Format revisions are backwards compatible. If an unknown format is encountered, it should be treated as the highest known preceding format."_ A consumer can decode a future artifact conservatively. Compare an ELF note type, where an unknown `n_type` carries no ordering information at all.

### `.NET` single-file bundles: two indexes for one datum

A `.NET` single-file app is an `apphost` executable with every managed assembly and (optionally) the runtime appended after it, followed by a manifest ([`Manifest.cs`][dn-manifest]):

```text
AppHost
------------ Embedded Files -------------------
------------ Bundle Header --------------------
    MajorVersion / MinorVersion / NumEmbeddedFiles / ExtractionID
    DepsJson Location (Offset, Size)        [v2+]
    RuntimeConfigJson Location (Offset, Size) [v2+]
    Flags                                   [v2+]
- - - - - - Manifest Entries - - - - - - - - - -
    Series of FileEntries [Type, Name, Offset, Size]
```

That is a footer index in the [ZIP tradition][footer], and it is located the way redbean's is not. The `apphost` ships with a 40-byte placeholder: eight zero bytes followed by a 32-byte constant that is _"SHA-256 for `.net core bundle`"_. `dotnet publish` finds the constant by scanning the file and writes the header offset into the eight bytes ahead of it ([`Bundler.cs`][dn-bundler]):

```csharp
int position = BinaryUtils.SearchInFile(accessor, BundleHeaderSignature);
if (position == -1)
    throw new PlaceHolderNotFoundInAppHostException(BundleHeaderSignature);
headerOffset = accessor.ReadInt64(position - sizeof(long));
```

The _running_ host does not scan. It reads the same 40 bytes as a `static volatile` array compiled into its own data segment ([`bundle_marker.c`][dn-marker]):

```c
// src/native/corehost/apphost/bundle_marker.c
volatile bundle_marker_data_t* marker = (volatile bundle_marker_data_t*)placeholder;
return marker->locator.bundle_header_offset;
```

One datum, two anchorings: **stream-scanned for an external tool, header-anchored (as a symbol) for the artifact interrogating itself.** That split is not an accident of implementation; it is the general shape of every mechanism on this page, and it is the reason the [index anchoring](#index-anchoring-and-random-access) row of this page's metadata table has to say "mixed".

`BundleID` is a content-derived name: SHA-256 over the contents of every embedded file in manifest order, base64url-encoded and truncated to 12 characters, with the manifest object frozen the moment the ID is taken (_"It is forbidden to change Manifest state after it was written or BundleId was obtained"_). It is used as the extraction directory name for files that must hit disk, which makes it a cache key over the closure — the same trick as [a Nix store path][nix], at a quarter of the entropy.

### SBOMs and the attestation layer

Neither of the two dominant SBOM formats says where the document goes. [CycloneDX][cdx-spec] specifies encodings (JSON, XML, protobuf), registered media types (`application/vnd.cyclonedx+json`) and conventional filenames (`bom.json`, `*.cdx.json`); [SPDX][spdx-spec] likewise specifies a document and its serializations. **Placement is out of scope for both.** That absence is the finding: everything in the previous four subsections is a placement convention invented by a toolchain because the format specifications declined to have an opinion, which is why there are five incompatible ones.

The attestation layer above resolves the question by _not_ embedding. An [in-toto Statement][intoto-statement] binds a predicate to subjects identified purely by digest:

> _"`subject` … Set of software artifacts that the attestation applies to. Each element MUST have `digest` set. \*\*Subjects are assumed to be \_immutable_, i.e. the artifacts identified by the subject SHOULD NOT change.\*\* … IMPORTANT: Subject artifacts are matched purely by digest, regardless of content type."\_

[SLSA's attestation model][slsa-model] repeats the assumption in its vocabulary — _"**Artifact:** Immutable blob of data described by an attestation, usually identified by cryptographic content hash"_ — and `cosign` states the operational consequence ([`SIGNATURE_SPEC.md`][cosign-sig]):

> _"Because signatures are **detached**, the payload MUST contain the digest of the image it references, in a well-known location."_

`cosign` went further and _withdrew_ the in-band option: SBOM attachments are deprecated in favour of attestations ([`SBOM_SPEC.md`][cosign-sbom], warning dated 2024-02-22). The industry's answer to "where does the SBOM live?" converged on "in a registry, keyed by the artifact's digest" — an **out-of-band index**, which [concepts.md][concepts] classifies as a [materialized view][concepts] with exactly the staleness failure mode that implies.

The floor under all of it is reproducibility ([reproducible-builds.org][rb-def]): _"A build is reproducible if given the same source code, build environment and build instructions, any party can recreate bit-by-bit identical copies of all specified artifacts."_ SLSA is careful to separate that from _verified_ reproducibility ([FAQ][slsa-faq]) and to note that _"Reproducible builds do not address source, dependency, or distribution threats."_ Note the direction of dependence: **the whole tower rests on the artifact's bytes being a function of its inputs**, which is precisely the property that a program storing its own state in its own image forfeits on the first request it serves.

---

## Format identity and multiplicity

**Multiplicity 0, and the zero is the point.** Nothing here creates a second parse of the same bytes. A `PT_NOTE` descriptor, a zlib stream in `.dep-v0`, a `.NET` manifest and a Go `buildinfo` blob are all _payloads carried opaquely by a host format that does not interpret them_ — [concepts.md][concepts]'s **container**, defined there as "the absence of multiplicity purchased with a tax". The tax is visible and small (a section-table entry, a program header, 713 bytes), and it is paid for exactly the reason the [UKI pays its much larger one][boot]: the incumbent parser already exists and will carry anything you name.

Three refinements are worth making, because they are where the identity question actually bites.

**The host's tolerance decides the mechanism, not the payload's.** ELF is [suffix-tolerant and header-anchored][concepts]: it declares its own extent through the section and program header tables, so a new payload must be _named_ in one of those tables. That is why every ELF-based mechanism here is a section, and why none of them can simply be appended. The `.NET` bundle, whose host format is PE, is appended anyway — and needs a scanned marker to find it, because PE's header does not know the payload exists. The same structural rule that generates [the ZIP-parasitic ecosystem][zip] generates the split between "named section" and "appended blob with a magic" seen on this page.

**Two containers, one JSON.** `.note.package` and `.pkgnote` are the same object in an ELF note and a COFF section ([UAPI.8][uapi8]). This is the closest thing here to genuine multiplicity, and it is not: the bytes are not simultaneously both, they are re-encoded per container. The _schema_ is portable, the _placement_ is not — which is the same asymmetry the SBOM formats institutionalized by declining to specify placement at all.

**The scanned mechanisms buy a parser differential.** Go's `\xff Go buildinf:` prefix is invalid UTF-8 on purpose, is required to be 16-byte aligned, and is searched only inside a container-provided window; a misaligned hit is skipped and the search continues. `.NET`'s marker is a 32-byte SHA-256 constant searched over the whole file with no alignment or window constraint, and the offset is read from the eight bytes _before_ the match. A crafted file containing the constant earlier than the real marker will hand the reader an attacker-chosen `int64`. Both are exercises in making a scan safe enough; neither is an index. See [parser differentials][differentials] for the general form, and note that the failure here is benign only because [nothing dispatches on provenance](#mutability-dispatch-and-trust).

## Index anchoring and random access

| Mechanism                 | Anchoring                                                                   | Cost of finding it                                                   | Consumable from a ranged read?                                                                              |
| ------------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `NT_GNU_BUILD_ID`         | Header — `PT_NOTE` in the program headers                                   | ehdr → phdr table → one note walk; a few hundred bytes               | **Yes**, in two round trips                                                                                 |
| `.note.ABI-tag`           | Header — same segment                                                       | same walk                                                            | Yes                                                                                                         |
| `.note.package`           | Header — allocated note                                                     | same walk                                                            | Yes                                                                                                         |
| Go `buildinfo`            | **Stream-scanned inside a bounded window**                                  | container sniff → `DataStart()` → chunked 16-byte-aligned search     | Yes, if `.go.buildinfo` exists; on platforms without the named section the window is the whole data segment |
| `.dep-v0`                 | Header — section table                                                      | shdr table → name lookup → one read                                  | Yes, three round trips                                                                                      |
| `.NET` bundle header      | **Stream-scanned over the whole file**, or a data-segment symbol at runtime | `SearchInFile` over an `mmap` of the entire executable               | **No** — the scan has no bound                                                                              |
| SLSA / in-toto / sigstore | **Out-of-band**                                                             | a registry or transparency-log lookup keyed by the artifact's digest | N/A — the artifact is not read                                                                              |

Two consequences follow, and they are the reason this page's metadata row says "mixed by design".

**Header-anchored provenance is cheap over a network.** A build-id is three bounded reads from an ELF file: 64 bytes of `Elf64_Ehdr`, `e_phnum × 56` bytes of program headers, then the `PT_NOTE` extent — a few hundred bytes to identify a binary you have not downloaded, which is the same trick [range-request access][range] plays against footer-indexed formats and the same trick `debuginfod` relies on at the other end. The [runnable companion][ex-notes] deliberately reads the whole file instead, because it is reading `/proc/self/exe`, where a ranged read buys nothing.

**Scanned provenance is not.** `.NET`'s `SearchInFile` has to touch every byte of a possibly 100 MiB self-contained bundle before it can say "not a bundle". Go's scan is bounded by the container's data segment, and the linker cooperates by placing the blob at its start — a _convention_ doing an index's job, which is [thesis 2][concepts] in miniature.

**The out-of-band row is the interesting one.** An attestation stored in a registry is a materialized view over a build that already happened, and it can go stale in a way none of the in-band mechanisms can: the artifact can be rebuilt, re-tagged, or moved, and the attestation's subject digest simply stops matching anything. In exchange it is the only mechanism here that can be _revoked_, updated after the fact, or authored by a party other than the toolchain. [Nix's `references` graph][nix] sits in the same position and pays the same price.

## Reflexivity and query surface

Score **2**, and the justification is a single ELF flag.

| Mechanism            | Mapped into the process?                                           | Self-readable without I/O?                                                | In a core dump?              |
| -------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------- | ---------------------------- |
| `NT_GNU_BUILD_ID`    | Yes — `PT_NOTE` is loaded                                          | Yes, by walking one's own phdrs (via `dl_iterate_phdr`)                   | Yes                          |
| `.note.package`      | Yes — allocated _by specification_, explicitly to reach core dumps | Yes                                                                       | **Yes — the stated purpose** |
| Go `buildinfo`       | Yes — `.go.buildinfo` is `WA`                                      | Yes — `ReadBuildInfo` calls `runtime.modinfo()`, a Go string in the image | Yes                          |
| `.NET` bundle marker | Yes — a `static volatile` array                                    | Yes                                                                       | Yes                          |
| `.dep-v0`            | **No — `sh_flags = 0`**                                            | **No** — the process must re-open its own file                            | **No**                       |

`runtime/debug.ReadBuildInfo` performs no file I/O whatsoever ([`mod.go`][go-mod]): it takes `modinfo()` from the runtime, strips the 16-byte sentinels, parses the text, and splices in `runtime.Version()` because the version is stored separately "mostly for historical reasons". A Go program can answer "which version of `golang.org/x/net` am I running?" in the middle of handling a request. A Rust program built with `cargo auditable` cannot answer the equivalent question without opening `/proc/self/exe` — and under [`binfmt_misc`][binfmt] that path names the _interpreter_, not the file that was executed, which is the exact hazard the [note-decoding companion][ex-notes] documents and [SELF][selfdb] has to work around.

That is the whole reflexivity story, and its ceiling is low: every one of these surfaces is a **fixed menu**. `go version -m` prints; `rust-audit-info` prints; `readelf -n` prints. There is no join. You cannot ask "which of my dependencies also appear in that other binary", "which notes exist across this tree", or "which packages are reachable from the root but only through a build-kind edge" without first exporting the data into something relational — which is precisely what [sqlelf][sqlelf] does for ELF and what [SELF][selfdb] does by making the format relational in the first place. SELF's schema has a `notes` table (`CREATE TABLE notes (kind TEXT, name TEXT, content BLOB)`) and a `self_meta` row for `build_id`: the note walk becomes a `SELECT`, and the `(name, type)` composite key that ELF leaves unenforced becomes something a `UNIQUE` constraint could enforce.

This is [thesis 1][concepts] — _every binary format eventually reimplements a database, badly_ — with a fresh witness that is not ELF's symbol table. `cargo-auditable`'s `.dep-v0` is a **normalized relational encoding**: a node table (`packages`) and an edge list expressed as foreign keys (`dependencies: [25, 30, 35]`), with a sort order defined to make the keys stable and a `format` column for schema evolution. It is a two-table database, serialized as JSON, compressed, and stored in a section — because there was no relational substrate available and one was needed anyway. See [code as a database][code-db] for the same convergence arrived at from the source-code side.

The one query surface on this page that is genuinely general is the one _outside_ the artifact: an attestation store keyed by digest, holding typed predicates, is a document database with a well-defined join key. The reflexivity the artifact lacks is available to anyone willing to give up in-band-ness.

## Closure, dedup, and size model

Score **1**, incidental — and the reason is worth stating precisely: **these mechanisms name a closure, they do not carry one.**

| Artifact                      | Provenance payload                                                                  | Binary size  | Fraction                      | What it describes                    |
| ----------------------------- | ----------------------------------------------------------------------------------- | ------------ | ----------------------------- | ------------------------------------ |
| `gh` 2.96.0 (Go 1.26.5)       | 7 952 B (`.go.buildinfo`)                                                           | 40 356 736 B | 0.0197 %                      | 166 modules + 7 build settings       |
| `ripgrep` 15.1.0 (Rust)       | 713 B (`.dep-v0`, zlib)                                                             | 6 557 168 B  | 0.0109 %                      | 42 packages, runtime and build kinds |
| `cargo-auditable`'s own claim | "under 4 kB even on large dependency trees with 400+ entries" ([README][ca-readme]) | —            | "between 1/1000 and 1/10 000" | —                                    |
| `NT_GNU_BUILD_ID` (`sha1`)    | 36 B (16-byte note header + 20-byte descriptor)                                     | any          | ~0                            | one build                            |

Four orders of magnitude separate the _description_ of a closure from the closure. That asymmetry is why nobody has ever needed to deduplicate embedded provenance, and it is the sharpest available contrast with the artifacts this catalog is otherwise about: [SELF reports 611.9 MiB for a 723-executable userland against 5.53 GiB under the AppImage model][selfdb], and [Nix][nix] exists to make a carried closure shareable. A named closure needs none of that machinery, and buys none of its guarantees — the names are only as good as the resolver that will later turn them into bytes, and [`cargo-auditable`'s own FAQ][ca-readme] notes that `format` `0` and `1` "may still include slightly more dependencies than are actually used".

Two internal compression choices are worth noting because they are the format doing database work again. Go's module block is **plain tab-separated text**, repeated in full, with no interning: the 166 `dep` lines of `gh` restate `github.com/` 100-odd times, and the 7 909-byte payload compresses trivially but is never compressed. `cargo-auditable` normalizes (indices, not names) _and_ compresses (zlib level 7, chosen because it "complete[s] in a few milliseconds") and lands at 713 bytes for a comparable graph. Same information, one order of magnitude apart, entirely because one of them modelled the data as a graph and the other as a log.

What is _not_ carried anywhere is the thing a closure would need to be actionable: no hashes of the dependencies as built, no store paths, no source digests. Go carries `Module.Sum` in its type but the field is documented as the module checksum, not the binary's; the ELF notes carry nothing of the kind. To go from "this binary says it used `aho-corasick` 1.1.3" to "these exact bytes" you must trust a registry — the [content-addressed chunking][cas] and [Nix closure][nix] pages are where that gap is actually closed.

## Mutability, dispatch, and trust

Score **0** on the mutability axis, and this section is the page's payload, because the zero is not a property of provenance — it is an _assumption baked into every layer above it_ that the catalog's mutable artifacts violate.

**Nothing here is dispatched on.** No kernel, loader, or shell inspects a build-id, a `.note.package`, or a `.dep-v0` before deciding what a file is; the dispatch owner is the consumer, who may not look at all. That is why an absent build-id breaks nothing, why `strip` removing a note breaks nothing, and why a hostile toolchain can emit whatever it likes. Compare [`binfmt_misc`][binfmt], where the bytes at a fixed offset _are_ the decision.

**Nothing here is signed in band, either.** Every mechanism surveyed is unauthenticated plaintext or unauthenticated compressed text sitting in a region the artifact's producer controls and any post-processor can rewrite. `--build-id` is documented as "not intended to be compared as a checksum". `.note.package` is JSON with no signature slot. Go's blob is in a _writable_ segment. `cargo-auditable`'s README says the quiet part out loud: an attacker who has compromised a dependency will simply delete the row that names it.

### The obvious first design

Take [SELF][selfdb] as the concrete mutable artifact, since it is the one with a schema. The [source outline][concepts] proposes, and this page is charged with developing, the following:

> If an SBOM is a view and an attestation is a signed subset of rows, you need a canonical serialization — per-table Merkle roots over a canonical row encoding, with the signature covering only the immutable tables, is the obvious first design. Nobody has built it.

Spelled out against SELF's actual DDL, that is: partition the schema into _code_ tables (`self_meta`, `segments`, `needed`, `dynamic_entries`, `symbols`, `relocations`, `sections`, `notes`) and _state_ tables (a `visits` table, a `handlers` table, whatever the application adds); define a canonical byte encoding for a row; compute a Merkle root per code table; sign the tuple of roots plus the schema; store the signature somewhere the hash does not cover. `VACUUM` may rewrite every byte in the file and the roots do not move, because they are computed over _rows_, not pages. `INSERT`ing into `visits` does not invalidate anything, because `visits` is not covered.

It is the right first design. It does not survive contact.

### Four things that break it

**1. Row order is not canonical in SQL.** A table is a multiset; a `SELECT` without `ORDER BY` has no defined order, and a Merkle root over rows is a function of an order. So a sort key must be _defined_, per table, as part of the format — and SELF's schema does not have one to hand: `dynamic_entries (tag TEXT, value ANY)` and `notes (kind TEXT, name TEXT, content BLOB)` declare no key at all, and `dynamic_entries` legitimately holds repeated tags (`DT_NEEDED`-adjacent multiplicities, several `INIT_ARRAY`-family entries). Sorting by the full tuple resolves ties only if no two rows are identical, and identical rows are legal. The evidence that this is a real cost rather than a theoretical one is [`cargo-auditable`][ca-meta], which hit the identical wall from the other direction: `cargo metadata`'s order "varies between executions", so a sort had to be invented, and the comment concedes the sort key is a workaround for a type that "does not implement `Ord`".

**2. Identity is positional, and positions move.** SQLite's `VACUUM` is unambiguous ([sqlite.org][sqlite-vacuum]):

> _"The VACUUM command rebuilds the database file, repacking it into a minimal amount of disk space. … **The VACUUM command may change the ROWIDs of entries in any tables that do not have an explicit INTEGER PRIMARY KEY.** … The VACUUM command works by copying the contents of the database into a temporary database file and then overwriting the original with the contents of the temporary file."_

In SELF's schema, `segments`, `needed`, `symbols` and `relocations` do declare `INTEGER PRIMARY KEY`, so their `rowid`s are stable; `dynamic_entries` and `notes` do not, so theirs are not. Any canonical encoding that includes a `rowid`, or any _other_ table that references one, is invalidated by an operation the format's own design documents as routine — `strip` is specified as `DELETE` + `VACUUM`. And this is the same defect as `cargo-auditable`'s index-based edges: the moment a node's name is its position, re-serialization renumbers the graph. Two projects, no shared code, one bug class.

**3. A signature over a subset does not bind the subset to the whole.** Sign the code tables and leave the state tables free, and an attacker does not need to forge anything — they need only _add_. SELF's own design puts `LD_PRELOAD` in a row and handlers in a table; [`self-httpd`][selfdb] makes request handling a `SELECT` against a table the running server writes. A signature over `segments` and `symbols` says nothing about a new `preload` row, a new trigger, or a new view shadowing `exports`. Binding the subset to the whole requires signing the _schema_ — but `sqlite_schema` is itself a table that a legitimately mutating artifact appends to (a migration is a `CREATE TABLE`), so the covered set and the mutable set intersect. The honest form of the requirement is: **the signature must enumerate what may change, not what may not**, which is a closed-world assumption that a self-modifying artifact is precisely designed to escape.

**4. The signature has nowhere to live.** Put it in a table and it is inside the b-tree you are hashing; put it in SQLite's reserved-per-page region and `VACUUM` rewrites the pages; put it in the 100-byte header and there are 20 free bytes and no defined semantics for them. And even setting the signature aside, a whole-file hash of a SQLite database is not stable under logically-identical content: the [file format][sqlite-format] puts a file change counter at offset 24 and a version-valid-for number at offset 92, the freelist and page ordering depend on write history, and two databases with byte-identical row sets routinely differ. **A mutable artifact cannot be verified by a signature over its bytes** — which is where [concepts.md][concepts] points at this page — and it turns out it cannot trivially be verified by a signature over its rows either.

### How the deployed systems dodge it

Nobody solved this. Four ecosystems worked around it in four distinguishable ways, and the taxonomy is the useful output.

| System                                   | Strategy                                 | Mechanism                                                                                                                 |
| ---------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Authenticode (PE, and thus [UKIs][boot]) | **Exclude the mutating region**          | Hash everything except the `CheckSum` field, the certificate-table data directory entry, and the certificate table itself |
| APK Signature Scheme v2                  | **Normalize the self-referential field** | Sign contents-before-signing-block, the central directory, and an EOCD whose CD offset has been rewritten                 |
| dm-verity / fs-verity                    | **Give up on semantics**                 | A Merkle tree over fixed-size _blocks_, verified lazily on read; the file is then read-only                               |
| sigstore / SLSA / in-toto                | **Leave**                                | Detached signature over a digest, stored in a registry or transparency log                                                |

**Authenticode is a canonicalization, not a hash.** The algorithm, implemented plainly in systemd's [`pe_hash()`][pe-binary] so a UKI can be verified without Windows, hashes: everything up to the `CheckSum` field; everything between it and the certificate-table data directory entry; the rest of the headers and section table; then each section's raw data **in file-offset order after an explicit sort**; then any trailing data minus the certificate table; then zero-padding to an 8-byte multiple. Three exclusions and one imposed ordering — i.e. it defines a canonical serialization of a PE file precisely because the naive one is not signable. This is the closest deployed analogue to "per-table Merkle roots over a canonical row encoding", and it is instructive that the canonicalization is about a hundred lines and has already produced a hashing-denial-of-service fix.

**APK v2 normalizes the field the signature's own insertion would break.** Inserting the signing block moves the central directory, so the EOCD's CD offset changes as a _consequence of signing_. `apksig` handles it by hashing a modified copy ([`ApkSigningBlockUtils.java`][apksig-utils]):

```java
// For the purposes of verifying integrity, ZIP End of Central Directory (EoCD) must be
// treated as though its Central Directory offset points to the start of APK Signing Block.
// We thus modify the EoCD accordingly.
ZipUtils.setZipEocdCentralDirectoryOffset(modifiedEocd, beforeApkSigningBlock.size());
```

and the content digest itself is a domain-separated two-level tree:

> _"1. Each segment of contents is split into consecutive chunks of 1 MB in size. … 2. The digest of each chunk is computed over the concatenation of byte `0xa5`, the chunk's length in bytes (uint32 little-endian) and the chunk's contents. 3. The output digest is computed over the concatenation of the byte `0x5a`, the number of chunks (uint32 little-endian) and the concatenation of digests of chunks of all segments in-order."_

The `0xa5`/`0x5a` prefixes are leaf/interior domain separation — the thing `lld`'s otherwise structurally identical [build-id tree hash](#elf-notes-a-typed-blob-table-with-no-index-and-no-schema) omits, because `lld`'s is not a security construction. Anyone building a per-table Merkle root should copy the prefixes and the explicit length framing verbatim; in-toto's [`gitTree` and `dirHash` digest algorithms][intoto-digest] are the same discipline applied to trees of files (`<type> SP <size> NUL <content>`; `find | sort` in the C locale), and their existence proves the attestation model already accepts a digest over a _canonicalized semantic structure_ rather than over bytes. That is the escape hatch: a `selfTables` digest algorithm would be a legitimate in-toto `DigestSet` key, and nothing in the Statement spec forbids it.

**fs-verity is the one that actually handles a large file cheaply, by refusing to handle mutation** ([`Documentation/filesystems/fsverity.rst`][fsverity]):

> _"fs-verity is essentially a way to hash a file in constant time, subject to the caveat that reads which would violate the hash will fail at runtime."_

and

> _"After this, the file is made readonly, and all reads from the file are automatically verified against the file's Merkle tree. Reads of any corrupted data, including `mmap` reads, will fail."_

`FS_IOC_ENABLE_VERITY` must run on an `O_RDONLY` descriptor with no writers, returning `ETXTBSY` otherwise, "to guarantee that no writable file descriptors will exist after verity is enabled". A verity Merkle tree over 4 KiB blocks is _exactly_ the shape a SQLite database wants — SQLite's default page size is 4096 bytes, so pages and verity blocks align one-to-one, and demand-paged verification would preserve the [`mmap` and page-sharing property][concepts] that everything else in this catalog is judged on. It is also exactly the wrong granularity for a mutable artifact, which brings the argument to its actual conclusion.

### What the tension actually is

Two Merkle granularities, and each is destroyed by the operation the other survives:

| Granularity                                        | Survives `VACUUM`                                    | Survives `INSERT` into a covered table | Preserves demand-paged verification          | Binds _meaning_          |
| -------------------------------------------------- | ---------------------------------------------------- | -------------------------------------- | -------------------------------------------- | ------------------------ |
| **Pages** (dm-verity / fs-verity shaped)           | **No** — every byte moves                            | No — the page is rewritten             | **Yes**                                      | No — a page is not a row |
| **Rows** (per-table roots over canonical encoding) | **Yes** — rows are order-defined, not offset-defined | No — the table's root changes          | **No** — verification needs the decoded rows | **Yes**                  |

`VACUUM` rewrites pages while preserving rows. `INSERT` preserves pages while adding rows. There is no granularity that is invariant under both, and so **choosing the Merkle granularity is choosing which operation you are willing to make expensive** — a full re-sign after every `VACUUM`, or a per-transaction re-root of one table plus the loss of lazy page verification. Nobody has picked, which is why the open question is still open, and it is a sharper statement of the problem than "you need a canonical serialization": you need _two_, and they disagree.

The one primitive that survives the whole mess is the one the GNU linker documented at the top of this page. A build-id "does not change" when the file is changed later by other tools — a stable _name_ for a lineage rather than a hash of a state. A mutable artifact can carry an immutable name, and everything an attestation wants to say ("this lineage was produced by this builder from these sources") can be said about the name. What it cannot say is "and the bytes in front of you are still that", which is the entire value proposition of a signature. [Threat model][threat] develops what is left: a signed measurement of a legitimately-mutating file (IMA/EVM's answer), and whether a self-querying server can hold a read-only handle to its code tables and a writable one to its state tables, enforced below the application. That decomposition — _code tables verity-protected and mapped read-only, state tables writable and unsigned_ — is the only design in view that gets both halves, and it needs the [VFS seam][selfdb] to exist at all.

> [!NOTE]
> **What was not verified.** No implementation of per-table Merkle roots over SQLite exists to measure; the design above is derived from the primitives, not observed. The claim that a page-aligned verity tree over a SELF database would preserve page sharing follows from fs-verity's documented `mmap` behaviour but has not been tested against a SELF binary, which does not yet have an `mmap`-based loader ([milestone M4 is unstarted][selfdb]).

---

## Strengths

- **Free identity.** A 36-byte note gives every binary a stable, toolchain-computed name that survives stripping, copying, renaming, and later modification — and turns into a network-resolvable key for debug info through `debuginfod` ([debug info and indexes][debug]).
- **Provenance in the core dump.** `.note.package` is allocated by specification, so a crash report carries the distribution, version and `debuginfod` URL of the binary that produced it, with no package database and no network.
- **Self-interrogation without I/O, where the section is mapped.** `runtime/debug.ReadBuildInfo` and the `.NET` `bundle_marker` read the artifact's provenance out of the artifact's own memory, mid-execution.
- **Astonishing information density.** 713 bytes describes a 42-crate dependency graph in a 6.5 MB binary; the "under 4 kB for 400+ entries" claim holds because the payload is a normalized graph, not a log.
- **Reproducibility-compatible by construction.** `cargo-auditable` sorts its output and embeds no timestamps precisely so the payload does not perturb bit-for-bit reproducibility; Go's blob is a pure function of the module graph plus recorded flags.
- **Format-agnostic extraction.** `.dep-v0` is read identically from ELF, Mach-O, PE and Wasm custom sections; the payload's meaning never depended on the container.
- **Forward-compatible versioning where anyone bothered.** `cargo-auditable`'s "treat an unknown `format` as the highest known preceding one" rule lets a 2026 tool decode a 2030 artifact conservatively.
- **The attestation layer composes with anything.** Because it is keyed by digest and stored out of band, in-toto/SLSA/sigstore apply unchanged to an ELF, a container image, a Git commit, or a tarball — including artifacts whose format has no room for metadata at all.

## Weaknesses

- **Every mechanism is opt-in and silently absent.** `--build-id` is a link option, `--package-metadata` is a link option, `-buildvcs=auto` drops VCS data without a word when the VCS binary is missing, and `cargo auditable` is a wrapper you must remember to invoke.
- **Hermetic builds delete the most valuable field.** The measured `gh` binary carries `-trimpath=true` and no `vcs.revision`, because it was built from a tarball — exactly the build style that provenance is supposed to reward.
- **Nothing is authenticated in band.** All of it is attacker-writable plaintext in a region the producer controls, and a compromised dependency removes itself.
- **Five incompatible placement conventions,** because both SBOM specifications declined to define one.
- **Non-allocated sections are invisible to the process that carries them.** `.dep-v0` cannot be read without re-opening `/proc/self/exe`, which under `binfmt_misc` names the wrong file.
- **The query surface is a fixed menu everywhere.** No mechanism supports a join, a projection, or a question its printer was not written to answer.
- **Two of the mechanisms are unbounded scans.** `.NET`'s marker search reads the whole executable; a crafted earlier copy of the 32-byte constant redirects the header offset.
- **Positional identity is fragile in both encodings surveyed.** `cargo-auditable`'s edges are array indices; SQLite's `rowid`s move under `VACUUM` for any table without an explicit `INTEGER PRIMARY KEY` — including two of SELF's.
- **The whole attestation tower assumes an immutable subject,** stated normatively in the in-toto Statement spec and repeated in SLSA's model, and there is no defined behaviour for an artifact that legitimately changes.
- **Detached, digest-keyed storage can go stale in ways in-band metadata cannot** — the artifact and its attestation are joined by a value that a rebuild silently invalidates.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                                | Trade-off                                                                                                                 |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Build-id is an identity, explicitly not a checksum                   | It must remain stable when other tools modify the file, so it can key debug info for the _original_ link | It authenticates nothing; two tools can disagree about a file that both call by the same name                             |
| `lld` implements `md5`/`sha1` styles with truncated BLAKE3           | The field has no security goals, and only the length is depended on                                      | The style name lies about the algorithm; anyone who assumed a real SHA-1 is wrong                                         |
| Build-id is a chunked hash-of-hashes over the whole output buffer    | Parallelizable across cores on large links                                                               | Not equal to any plain digest, and computed over the note's own not-yet-written bytes; no leaf/interior domain separation |
| `.note.package` is an _allocated_ section                            | It must reach memory, and therefore core dumps, without a package database or a network                  | It occupies resident memory in every process forever, for data most processes never read                                  |
| `cargo-auditable` marks `.dep-v0` non-`SHF_ALLOC`                    | Costs no runtime memory and no page faults                                                               | The process cannot read its own dependency list; self-inspection needs `/proc/self/exe`                                   |
| `cargo-auditable` encodes edges as array indices and sorts the array | Compact, and byte-reproducible despite `cargo metadata`'s unstable ordering                              | Node identity is positional; any re-serialization renumbers the entire graph                                              |
| Go locates its blob by a 16-byte-aligned magic scan                  | Works across six container formats with one code path and no per-format section-name contract            | Unbounded on containers without the named section; correctness depends on the linker's placement convention               |
| Go stores the module graph as repeated tab-separated text            | Trivially parseable by anything, including a human reading `strings`                                     | An order of magnitude larger than the same graph normalized and compressed                                                |
| Go's VCS stamping is conditional and fails open                      | Avoids build errors in the many legitimate no-repository cases                                           | The single most valuable field is silently absent exactly where builds are most hermetic                                  |
| `.NET` uses a scanned marker externally and a data symbol internally | One datum readable both by an offline tool and by the running host                                       | Two anchorings to keep in sync; the external one is an unbounded whole-file scan with an attacker-influenceable result    |
| SPDX and CycloneDX define a document and not a placement             | Keeps the formats independent of every container and toolchain                                           | Five incompatible in-binary conventions grew in the vacuum                                                                |
| in-toto binds attestations to immutable subject digests              | Predicate-agnostic storage and lookup, and one join key for every artifact type                          | Mutable artifacts are outside the model entirely, normatively so                                                          |
| `cosign` deprecated SBOM attachments in favour of attestations       | An unsigned attachment adds no trust; an attestation is authenticated and typed                          | Provenance now lives out of band and can be lost, stale, or simply never fetched                                          |
| Authenticode excludes three regions and imposes a section ordering   | A signature cannot cover itself, and PE section order is not canonical                                   | "Is this the file I signed?" becomes a hundred-line algorithm with its own denial-of-service surface                      |
| APK v2 normalizes the EOCD's central-directory offset before hashing | The act of signing moves the central directory; the field must be canonicalized, not excluded            | Verifiers must reimplement the normalization exactly, or reject valid APKs                                                |
| fs-verity hashes blocks, not semantics, and then freezes the file    | Constant-time enablement, lazy verification, `mmap` reads covered                                        | The artifact becomes read-only; nothing in the tree survives a `VACUUM`-style rewrite                                     |

---

## Sources

- [ELF gABI — program header and note sections][gabi-phdr] · [`elf(5)`][elf-man] — the `n_namesz`/`n_descsz`/`n_type` note layout and `PT_NOTE`
- [GNU `ld` — `--build-id` and `--package-metadata`][ld-options] — the normative "not intended to be compared as a checksum" statement
- [Fedora — build-id feature page][fedora-buildid] — the original "approximation of true uniqueness" framing `lld` cites
- [UAPI.8 — Package Metadata for Executable Files][uapi8] and its [repository copy][uapi8-src] — `.note.package`, type `0xcafe1a7e`, owner `FDO`, the allocated-section requirement
- [`llvm-project` `lld/ELF/Writer.cpp`][lld-writer] · [`lld/ELF/SyntheticSections.h`][lld-synth] — `writeBuildId()`, `computeHash()`, per-style hash sizes
- [Go `src/cmd/link/internal/ld/data.go`][go-linker] — the `go:buildinfo` symbol, the `\xff Go buildinf:` prefix, the `go:buildinfo.ref` anti-GC reference
- [Go `src/debug/buildinfo/buildinfo.go`][go-buildinfo] — container sniffing, `DataStart()`, `searchMagic()`, the two header formats
- [Go `src/runtime/debug/mod.go`][go-mod] — `ReadBuildInfo`, `BuildInfo`, the documented `BuildSetting` keys
- [Go `src/cmd/go/internal/modload/build.go`][go-modload] — the 16-byte `infoStart`/`infoEnd` framing sentinels
- [Go `src/cmd/go/internal/load/pkg.go`][go-pkg] — the exact conditions under which `vcs.*` settings are stamped
- [`cargo-auditable` README][ca-readme] · [`PARSING.md`][ca-parsing] · [JSON schema][ca-schema] — the format, the size claims, the SBOM caveat, the `format` revision rule
- [`cargo-auditable/src/object_file.rs`][ca-object] · [`collect_audit_data.rs`][ca-collect] · [`auditable_from_metadata.rs`][ca-meta] · [`auditable-extract/src/lib.rs`][ca-extract] — `.dep-v0` creation, the `sh_flags = 0` decision, the canonical sort, extraction across four containers
- [`dotnet/runtime` `Bundle/Manifest.cs`][dn-manifest] · [`Bundler.cs`][dn-bundler] · [`apphost/bundle_marker.c`][dn-marker] · [`bundle/header.h`][dn-header] — bundle layout, the SHA-256 placeholder, the deterministic `BundleID`
- [in-toto Attestation — Statement layer][intoto-statement] · [DigestSet][intoto-digest] — the immutable-subject requirement and the `gitTree`/`dirHash` canonicalizations
- [SLSA — attestation model][slsa-model] · [SLSA FAQ on reproducible builds][slsa-faq] · [slsa.dev][slsa-site]
- [`cosign` `SIGNATURE_SPEC.md`][cosign-sig] · [`SBOM_SPEC.md`][cosign-sbom] — detached signatures keyed by digest, and the deprecation of in-band SBOM attachments
- [Reproducible Builds — definition][rb-def]
- [`android/apksig` `ApkSigningBlockUtils.java`][apksig-utils] · [APK Signature Scheme v2][apk-v2] — EOCD normalization and the `0xa5`/`0x5a` chunked digest
- [systemd `src/shared/pe-binary.c`][pe-binary] · [Microsoft PE format][pe-format] — the Authenticode exclusion regions, implemented outside Windows
- [Linux `Documentation/filesystems/fsverity.rst`][fsverity] · [dm-verity][dm-verity] — Merkle trees over blocks, and the read-only precondition
- [SQLite `VACUUM`][sqlite-vacuum] · [SQLite file format][sqlite-format] — `ROWID` instability and the mutating header fields
- [CycloneDX specification overview][cdx-spec] · [SPDX specifications][spdx-spec] — documents without placements
- Runnable companion: [`./self-selfdb/examples/elf-note-buildid.d`][ex-notes] — decodes build-id, ABI-tag and vendor notes from `/proc/self/exe`
- Related in this catalog: [Concepts][concepts] · [SELF/selfdb][selfdb] · [Boot-adjacent hybrids][boot] · [Threat model][threat] · [Debug info and indexes][debug] · [`sqlelf`][sqlelf] · [Code as a database][code-db] · [Nix store closures][nix] · [Content-addressed chunking][cas] · [Footer-indexed formats][footer] · [Range-request access][range] · [ZIP parasitism][zip] · [Parser differentials][differentials] · [Dispatch via `binfmt_misc`][binfmt] · [Dynamic linking][ld] · [Wasm component model][wasm] · [Cosmopolitan/APE][ape] · [Comparison][comparison] · [Catalog index][index] · [Application packaging][packaging]

<!-- References -->

[go-repo]: https://github.com/golang/go/tree/620058f867b26c29f76198b170e816004ecd4144
[ca-repo]: https://github.com/rust-secure-code/cargo-auditable/tree/e0932726c020618f5d0d7cd82527c0d8bf65aa8d
[dotnet-repo]: https://github.com/dotnet/runtime/tree/714432e0b98bbdb976a55fe5897d1ba2dd263c82
[llvm-repo]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[intoto-repo]: https://github.com/in-toto/attestation/tree/2dcd055e9f72e746687c306e35f4e59720ff45be
[slsa-repo]: https://github.com/slsa-framework/slsa/tree/1686afeba11a456e470235ecf50cfc0d2f9ecbc3
[cosign-repo]: https://github.com/sigstore/cosign/tree/58aae9e112fa1de80594eed34667e920ac4d4a3b
[apksig-repo]: https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb
[gabi-phdr]: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html
[elf-man]: https://man7.org/linux/man-pages/man5/elf.5.html
[ld-options]: https://sourceware.org/binutils/docs/ld/Options.html
[fedora-buildid]: https://fedoraproject.org/wiki/Releases/FeatureBuildId
[uapi8]: https://uapi-group.org/specifications/specs/package_metadata_for_executable_files/
[uapi8-src]: https://github.com/uapi-group/specifications/blob/1375569c37d32dd905a1b1fb2f00d1a191f9ff38/specs/package_metadata_for_executable_files.md
[lld-writer]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/lld/ELF/Writer.cpp
[lld-synth]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/lld/ELF/SyntheticSections.h
[go-linker]: https://github.com/golang/go/blob/620058f867b26c29f76198b170e816004ecd4144/src/cmd/link/internal/ld/data.go
[go-buildinfo]: https://github.com/golang/go/blob/620058f867b26c29f76198b170e816004ecd4144/src/debug/buildinfo/buildinfo.go
[go-mod]: https://github.com/golang/go/blob/620058f867b26c29f76198b170e816004ecd4144/src/runtime/debug/mod.go
[go-modload]: https://github.com/golang/go/blob/620058f867b26c29f76198b170e816004ecd4144/src/cmd/go/internal/modload/build.go
[go-pkg]: https://github.com/golang/go/blob/620058f867b26c29f76198b170e816004ecd4144/src/cmd/go/internal/load/pkg.go
[godoc-readbuildinfo]: https://pkg.go.dev/runtime/debug#ReadBuildInfo
[ca-readme]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/README.md
[ca-parsing]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/PARSING.md
[ca-schema]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/cargo-auditable.schema.json
[ca-object]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/cargo-auditable/src/object_file.rs
[ca-collect]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/cargo-auditable/src/collect_audit_data.rs
[ca-meta]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/cargo-auditable/src/auditable_from_metadata.rs
[ca-extract]: https://github.com/rust-secure-code/cargo-auditable/blob/e0932726c020618f5d0d7cd82527c0d8bf65aa8d/auditable-extract/src/lib.rs
[dn-manifest]: https://github.com/dotnet/runtime/blob/714432e0b98bbdb976a55fe5897d1ba2dd263c82/src/installer/managed/Microsoft.NET.HostModel/Bundle/Manifest.cs
[dn-bundler]: https://github.com/dotnet/runtime/blob/714432e0b98bbdb976a55fe5897d1ba2dd263c82/src/installer/managed/Microsoft.NET.HostModel/Bundle/Bundler.cs
[dn-marker]: https://github.com/dotnet/runtime/blob/714432e0b98bbdb976a55fe5897d1ba2dd263c82/src/native/corehost/apphost/bundle_marker.c
[dn-header]: https://github.com/dotnet/runtime/blob/714432e0b98bbdb976a55fe5897d1ba2dd263c82/src/native/corehost/bundle/header.h
[intoto-statement]: https://github.com/in-toto/attestation/blob/2dcd055e9f72e746687c306e35f4e59720ff45be/spec/v1/statement.md
[intoto-digest]: https://github.com/in-toto/attestation/blob/2dcd055e9f72e746687c306e35f4e59720ff45be/spec/v1/digest_set.md
[intoto-site]: https://in-toto.io/
[slsa-model]: https://github.com/slsa-framework/slsa/blob/1686afeba11a456e470235ecf50cfc0d2f9ecbc3/spec/attestation-model.md
[slsa-faq]: https://github.com/slsa-framework/slsa/blob/1686afeba11a456e470235ecf50cfc0d2f9ecbc3/spec/faq.md
[slsa-site]: https://slsa.dev/spec/v1.1/provenance
[cosign-sig]: https://github.com/sigstore/cosign/blob/58aae9e112fa1de80594eed34667e920ac4d4a3b/specs/SIGNATURE_SPEC.md
[cosign-sbom]: https://github.com/sigstore/cosign/blob/58aae9e112fa1de80594eed34667e920ac4d4a3b/specs/SBOM_SPEC.md
[rb-def]: https://reproducible-builds.org/docs/definition/
[apksig-utils]: https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/main/java/com/android/apksig/internal/apk/ApkSigningBlockUtils.java
[apk-v2]: https://source.android.com/docs/security/features/apksigning/v2
[pe-binary]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/shared/pe-binary.c
[pe-format]: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
[fsverity]: https://docs.kernel.org/filesystems/fsverity.html
[dm-verity]: https://docs.kernel.org/admin-guide/device-mapper/verity.html
[sqlite-vacuum]: https://sqlite.org/lang_vacuum.html
[sqlite-format]: https://sqlite.org/fileformat2.html
[cdx-spec]: https://cyclonedx.org/specification/overview/
[spdx-spec]: https://spdx.dev/use/specifications/
[ex-notes]: ./self-selfdb/examples/elf-note-buildid.d
[concepts]: ./concepts.md
[selfdb]: ./self-selfdb/index.md
[boot]: ./boot-hybrids.md
[threat]: ./threat-model.md
[debug]: ./debug-info-and-indexes.md
[sqlelf]: ./sqlelf.md
[code-db]: ./code-as-database.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[zip]: ./zip-parasitism.md
[differentials]: ./parser-differentials.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[wasm]: ./wasm-component-model.md
[ape]: ./cosmopolitan-ape/index.md
[comparison]: ./comparison.md
[index]: ./index.md
[packaging]: ../application-packaging/index.md
