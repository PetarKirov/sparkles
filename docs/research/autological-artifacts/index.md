# Autological Artifacts

_Files that describe, contain, and interrogate themselves._

A source-grounded survey of what happens when the boundaries between **program,
container, index, dependency graph, and state** collapse into one byte stream.
The two seeds are [redbean/APE][ape] — a file whose own bytes are its archive —
and [SELF][self] — a file whose own bytes are its schema. The catalog exists
because those two artifacts are usually described as the same idea, and the
evidence says they are [opposite corners of the same space][shape].

**Last reviewed:** August 26, 2026

This survey answers ten questions:

1. What does **autological** mean here, what are the four axes every artifact is
   scored on, and what do _prefix-tolerant_, _footer-anchored_, and _dispatch
   owner_ mean? → [Concepts][concepts]
2. How far can format superposition actually be pushed, and what does it cost?
   → [Cosmopolitan/APE/redbean][ape], [polyglot craft][polyglot], [boot
   hybrids][boot]
3. **Which formats compose, and can that be predicted rather than catalogued?**
   → [ZIP parasitism][zip] develops the [tolerance partial order][tolerance];
   [boot hybrids][boot] supplies the amendment
4. What goes wrong when two dispatchers disagree about one byte stream? →
   [Parser differentials and LangSec][differentials]
5. What does it mean for an executable to _be_ a database, and what does it
   break? → [SELF/selfdb/self-httpd][self], with [sqlelf][sqlelf] as the
   precursor that changed no format at all
6. Where does an index live, why, and what does that cost over a network? →
   [Footer-indexed formats][footer], [range-request consumption][range],
   [debug info and out-of-band indexes][dwarf]
7. Who decides what a file is? → [`binfmt_misc`][binfmt], [the dynamic
   loader][ld], [the Wasm component model][wasm]
8. How do you carry your dependencies without carrying them twice? → [The Nix
   store][nix], [content-addressed chunking][chunking]
9. What is already known about programs that mutate themselves, and about
   trusting them? → [Image-based systems][images], [SQLite as an application
   file format][aff], [the VFS seam][vfs], [embedded provenance][provenance],
   [the threat model][threat]
10. Why did the systems that already shipped this idea lose? → [Single-level
    store][sls], [Plan 9 and 9P][plan9]

The synthesis is in [comparison.md][comparison] — including a section of
**corrections to the premises this survey started from**, five of which did not
survive contact with the sources. The research agenda that remains is in
[open-questions.md][open]. Methodology, and an explicit line between _measured_,
_derived_, and _claimed by a source_, is in [measurement.md][measure].

> [!NOTE]
> **Scope.** This tree is about the artifact's **internal structure**. How an
> artifact reaches a machine — installers, stores, notarization, update channels
> — is [`docs/research/application-packaging/`][packaging]'s subject, and is
> cross-linked rather than re-surveyed. General single-binary packaging is out of
> scope unless the artifact is queryable or polyglot; see
> [what is out of scope][oos].

---

## Master catalog

One row per surveyed subject. **M/R/C/Mu** are the four axis scores —
Multiplicity, Reflexivity, Closure, Mutability — each 0–3, defined in
[concepts][axes] and argued in each deep-dive's spine. They are ordinal
judgements assigned by this survey, not measurements.

| Subject                             | Cluster            | M/R/C/Mu    | Index anchoring           | Dispatch owner | What it is                                                                                       | Link                       |
| ----------------------------------- | ------------------ | ----------- | ------------------------- | -------------- | ------------------------------------------------------------------------------------------------ | -------------------------- |
| **Cosmopolitan / APE / redbean**    | Superposition      | **3/2/3/2** | footer (ZIP `EOCD`)       | shell → kernel | The maximal polyglot: PE + ELF + Mach-O + shell script + MBR + ZIP, collapsing on first run      | [deep-dive][ape]           |
| **ZIP suffix parasitism**           | Superposition      | 3/1/2/1     | footer                    | consumer       | The footer index that makes every ZIP-suffixed format from JAR to APK to redbean possible        | [deep-dive][zip]           |
| **Polyglot craft**                  | Superposition      | 3/1/1/0     | mixed by construction     | consumer       | Corkami, `mitra`, and 23 PoC‖GTFO issues — multiplicity maximal, reflexivity zero                | [deep-dive][polyglot]      |
| **Boot-adjacent hybrids**           | Superposition      | 3/1/2/0     | header + reserved hole    | firmware       | An ISO that is also an MBR disk; a PE that is also kernel + initrd + cmdline, signed as one      | [deep-dive][boot]          |
| **Parser differentials / LangSec**  | Superposition      | 3/0/0/1     | footer + stream-scanned   | consumer       | GIFAR, Master Key, Janus, MalDoc-in-PDF — the adversarial dual of every entry above              | [deep-dive][differentials] |
| **SELF / selfdb / self-httpd**      | Binary-as-database | **1/3/2/3** | header (b-tree)           | kernel         | The executable _is_ a SQLite database; `strip`/`ldd`/`patchelf`/`LD_PRELOAD` become SQL          | [deep-dive][self]          |
| **sqlelf**                          | Binary-as-database | 0/2/1/0     | out-of-band               | kernel         | SQL over unmodified ELF — the same reflexivity, achieved by changing no format at all            | [deep-dive][sqlelf]        |
| **Format→query layers**             | Binary-as-database | 1/3/0/2     | out-of-band               | consumer       | LIEF, goblin, pyelftools against the declarative grammars Kaitai and DFDL                        | [deep-dive][inspection]    |
| **Relational system surfaces**      | Binary-as-database | 1/3/1/1     | out-of-band               | consumer       | osquery, Steampipe, Datasette, `dsq` — Datasette is self-httpd run backwards                     | [deep-dive][relational]    |
| **Code as a database**              | Binary-as-database | 1/3/2/1     | out-of-band               | consumer       | CodeQL, Glean, Kythe, SCIP/LSIF, `ddisasm` — and why they all chose Datalog                      | [deep-dive][codedb]        |
| **`binfmt_misc`**                   | Dispatch           | 1/2/1/0     | header (256-byte window)  | kernel         | The kernel turning a masked byte pattern into a choice of interpreter                            | [deep-dive][binfmt]        |
| **The dynamic loader**              | Dispatch           | 1/2/1/1     | header + `ld.so.cache`    | loader         | `ld.so` re-running the same symbol-resolution query at every process start                       | [deep-dive][ld]            |
| **Wasm component model / WIT**      | Dispatch           | 1/3/2/0     | stream-scanned            | loader         | Imports and exports as a typed graph the binary carries — at the price of no index               | [deep-dive][wasm]          |
| **Footer-indexed formats**          | Index anchoring    | 2/2/0/1     | footer                    | consumer       | Parquet, ORC, seekable `zstd`, eStargz — and the writer-side constraint that explains them       | [deep-dive][footer]        |
| **Range-request consumption**       | Index anchoring    | 0/2/1/0     | footer / header+b-tree    | consumer       | DuckDB `httpfs`, `sql.js-httpvfs`, OCI, `debuginfod`: cost is round trips, not bytes             | [deep-dive][range]         |
| **Debug info and OOB indexes**      | Index anchoring    | 1/2/1/1     | stream-scanned + bolt-ons | consumer       | DWARF: five index generations, because the format shipped with no query surface                  | [deep-dive][dwarf]         |
| **The Nix store and closures**      | Closure            | 0/2/**3**/1 | out-of-band               | consumer       | Dependencies _discovered_ by scanning bytes for hashes, never declared                           | [deep-dive][nix]           |
| **Content addressing and chunking** | Closure            | 0/1/**3**/1 | out-of-band + footer TOC  | consumer       | OSTree, casync/desync, OCI layers, `zstd:chunked` — 0.00% vs 99.88% sharing, same two artifacts  | [deep-dive][chunking]      |
| **Image-based systems**             | Self-mutation      | 1/2/2/**3** | header                    | loader         | Squeak, SBCL, Emacs `unexec`→`pdumper`, CRIU, Erlang — five collisions with demand paging        | [deep-dive][images]        |
| **SQLite as an app file format**    | Self-mutation      | 1/3/2/**3** | header                    | consumer       | The design position SELF is a maximal instance of; Fossil is the shipped proof                   | [deep-dive][aff]           |
| **The SQLite VFS as substrate**     | Substrate          | 1/2/0/2     | out-of-band (negotiable)  | consumer       | One b-tree over `pread`, OPFS, HTTP 206, memory — where portability actually lives               | [deep-dive][vfs]           |
| **Embedded provenance**             | Provenance         | 0/2/1/0     | mixed by design           | consumer       | build-id, Go `buildinfo`, `cargo-auditable`, SBOM-in-binary — all opt-in, all unauthenticated    | [deep-dive][provenance]    |
| **Threat model**                    | Trust              | 0/1/0/**3** | out-of-band               | kernel         | Every OS primitive identifies its subject by inode or path — never by content                    | [deep-dive][threat]        |
| **Single-level store**              | Prior art          | 0/3/1/2     | out-of-band               | kernel         | IBM i/OS-400, Multics, Pick, VMS RMS — the commercial system that shipped "the OS is a database" | [deep-dive][sls]           |
| **Plan 9 and 9P**                   | Prior art          | 1/2/0/1     | out-of-band               | kernel         | The namespace, not the table, as the uniform interrogation interface — 13 messages               | [deep-dive][plan9]         |
| **Method and measurement**          | Method             | 0/1/0/1     | out-of-band               | consumer       | A prescriptive protocol; explicitly reports no results                                           | [deep-dive][measure]       |

---

## Taxonomies

The same 26 subjects, re-cut one axis at a time.

### By index anchoring

**Out-of-band is the most common answer** — the index is more often outside the
artifact than in it, and every such index is a [materialized view][terms] that
can go stale.

| Anchoring          | Count | Subjects                                                                                                                                                                                               |
| ------------------ | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Out-of-band**    | 11    | [sqlelf][sqlelf], [inspection][inspection], [relational][relational], [codedb][codedb], [nix][nix], [chunking][chunking], [vfs][vfs], [threat][threat], [sls][sls], [plan9][plan9], [measure][measure] |
| **Header**         | 6     | [SELF][self], [binfmt][binfmt], [ld][ld] (+ cache), [images][images], [aff][aff], [boot][boot] (+ hole)                                                                                                |
| **Footer**         | 5     | [APE][ape], [zip][zip], [footer][footer], [range][range], [chunking][chunking] (`zstd:chunked` TOC)                                                                                                    |
| **Stream-scanned** | 4     | [wasm][wasm], [dwarf][dwarf], [differentials][differentials], [provenance][provenance] (Go `buildinfo`)                                                                                                |

### By dispatch owner

| Dispatcher   | Count | What acts on the bytes                                                                                                |
| ------------ | ----- | --------------------------------------------------------------------------------------------------------------------- |
| **Consumer** | 15    | A library, a SQL engine, a renderer, a sniffing heuristic — no privileged arbiter                                     |
| **Kernel**   | 6     | [`binfmt_misc`][binfmt], `binfmt_elf`, `binfmt_script`, and the systems that were the OS ([sls][sls], [plan9][plan9]) |
| **Loader**   | 3     | [`ld.so`][ld], a Wasm engine, a language runtime opening its own [image][images]                                      |
| **Firmware** | 1     | [BIOS El Torito / UEFI `LoadImage`][boot]                                                                             |
| **Shell**    | 1     | The shebang, and the `ENOEXEC` fallback that [APE][ape] exploits                                                      |

### By axis extreme

| Axis             | Scores 3                                                                                                                 | Reading                                                               |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| **Multiplicity** | [APE][ape], [zip][zip], [polyglot][polyglot], [boot][boot], [differentials][differentials]                               | All five are format-superposition entries; none exceeds reflexivity 2 |
| **Reflexivity**  | [SELF][self], [inspection][inspection], [relational][relational], [codedb][codedb], [wasm][wasm], [aff][aff], [sls][sls] | **None exceeds multiplicity 1** — see [the shape of the space][shape] |
| **Closure**      | [APE][ape], [nix][nix], [chunking][chunking]                                                                             | One carries everything; two share everything                          |
| **Mutability**   | [SELF][self], [images][images], [aff][aff], [threat][threat]                                                             | The axis where signing stops working ([provenance][provenance])       |

---

## Milestones

When the load-bearing capabilities actually landed. Every date is established
and cited on the deep-dive that owns it; entries marked **≈** are approximate
there too.

| Date           | Event                                                                                    | Page                                                                           |
| -------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 1965-11        | Multics segments described at FJCC — one address space over memory and disk              | [sls][sls]                                                                     |
| 1978           | VAX/VMS RMS 1.0; `ETXTBSY` in V7 Unix                                                    | [sls][sls], [threat][threat]                                                   |
| 1980           | Smalltalk-80 images; IBM System/38 ships                                                 | [images][images], [sls][sls]                                                   |
| 1982           | Emacs `unexec` — dumping a running process back into an executable                       | [images][images]                                                               |
| 1986-12        | ECMA-119 (ISO 9660) reserves Logical Sectors 0–15 — hole-tolerance, on purpose           | [boot][boot]                                                                   |
| 1988-06        | AS/400 announced (`OS/400` V1R1): single-level store + TIMI + integrated database        | [sls][sls]                                                                     |
| 1989           | PKZIP 0.9 and `APPNOTE.TXT` — the footer index the whole catalog turns on                | [zip][zip]                                                                     |
| 1993-07-27     | DWARF 2, including `.debug_pubnames` — the first of five index generations               | [dwarf][dwarf]                                                                 |
| 1995           | ELF dynamic linking in Linux; El Torito 1.0                                              | [ld][ld], [boot][boot]                                                         |
| 1997           | `binfmt_misc` in Linux 2.1.43; HTTP byte ranges standardised (RFC 2068, January)         | [binfmt][binfmt], [range][range]                                               |
| 2002-04        | `9P2000` ships with Plan 9 Fourth Edition                                                | [plan9][plan9]                                                                 |
| 2003-03-13     | Nix's first commit — dependencies discovered by scanning, never declared                 | [nix][nix]                                                                     |
| 2004-06-18     | SQLite 3.0.0; the file format has been backwards-compatible ever since                   | [aff][aff]                                                                     |
| 2007           | build-id lands in Fedora 8; `sqlite3_vfs` ships in SQLite 3.5.0                          | [provenance][provenance], [vfs][vfs]                                           |
| 2011           | DFDL v1.0; OSTree's first commit; the term _LangSec_ is coined                           | [inspection][inspection], [chunking][chunking], [differentials][differentials] |
| 2013           | Parquet 1.0.0 and ORC; PoC‖GTFO `0x00` (2013-08-05)                                      | [footer][footer], [polyglot][polyglot]                                         |
| 2013-05-20     | **SQLite 3.7.17 adds `xFetch`/`xUnfetch`** — mapped pages _are_ shared between processes | [aff][aff]                                                                     |
| 2016           | OpenBSD `pledge` (5.9); Kaitai Struct compiler 0.2                                       | [threat][threat], [inspection][inspection]                                     |
| 2017           | `casync` (January); seekable `zstd` 0.1.0 (2017-11-04); DWARF 5 `.debug_names`           | [chunking][chunking], [footer][footer], [dwarf][dwarf]                         |
| 2019           | `debuginfod` (elfutils 0.178); fs-verity (Linux 5.4); Wasm 1.0 W3C Recommendation        | [dwarf][dwarf], [threat][threat], [wasm][wasm]                                 |
| 2020-08-24     | **APE announced** — the maximal artifact of the format-level strategy                    | [ape][ape]                                                                     |
| 2020           | Emacs 27.1 replaces `unexec` with `pdumper`, after ASLR and PIE broke it                 | [images][images]                                                               |
| 2021           | Landlock (Linux 5.13); `sql.js-httpvfs` and DuckDB `httpfs`; OCI distribution-spec v1.0  | [threat][threat], [range][range]                                               |
| 2023-03-09     | sqlelf's first commit — SQL over ELF, changing no format                                 | [sqlelf][sqlelf]                                                               |
| 2023           | systemd `ukify` (253); SLSA v1.0 (2023-04-19); in-toto Attestation v1                    | [boot][boot], [provenance][provenance]                                         |
| 2024-05-06     | The sqlelf paper submitted (arXiv:2405.03883)                                            | [sqlelf][sqlelf]                                                               |
| 2024-08-17     | redbean 3.0.0                                                                            | [ape][ape]                                                                     |
| **2026-07-09** | **SELF's first commit**; the repository is made public 2026-08-23                        | [self][self]                                                                   |

> [!WARNING]
> SELF's repository has been **public for three days** at the time of this
> review, and its first commit is seven weeks old. Several of
> its claims — including the startup cost model and the page-sharing loss — have
> [never been measured by anyone][measure], its own `DESIGN.md` included. Treat
> every SELF performance figure in this tree as the project's claim, not as a
> result.

---

## Runnable examples

Six single-file D programs, compiled and run by the repository's `ci` helper on
every pass, each establishing one structural claim from first principles rather
than asserting it:

| Example                                                                      | What it proves                                                                                                                                          |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`zip-eocd-scan.d`](./cosmopolitan-ape/examples/zip-eocd-scan.d)             | Builds a shell-script + ZIP polyglot with prefix-biased offsets, then enumerates it reading **0.3% of the file**; a system `unzip` independently agrees |
| [`magic-superposition.d`](./cosmopolitan-ape/examples/magic-superposition.d) | Runs ten recognizers over four buffers at once — superposition is independent predicates with no arbiter                                                |
| [`sqlite-header-probe.d`](./self-selfdb/examples/sqlite-header-probe.d)      | Decodes `application_id` at offset 68 and `page_size` at 16, from a synthesized SELF header and a real database                                         |
| [`binfmt-magic-match.d`](./self-selfdb/examples/binfmt-magic-match.d)        | The kernel's magic+mask+offset predicate, transcribed; two ELF headers differing in one byte, separated by the mask                                     |
| [`elf-note-buildid.d`](./self-selfdb/examples/elf-note-buildid.d)            | Reads its own build-id from `/proc/self/exe` — and shows that emitting one is an opt-in **link option**                                                 |
| [`relocation-join.d`](./self-selfdb/examples/relocation-join.d)              | The loader as a query engine: `LD_PRELOAD` as **one inserted row that changes 4 of 8 resolutions**, plus the same query in SQL and Datalog              |

---

## Suggested reading paths

**"I want the argument, not the catalog."**
[concepts][concepts] → [comparison][comparison] → [open-questions][open]. About
an hour; the corrections section in the middle of `comparison` is the part that
changed as a result of the research.

**"I came for redbean / APE."**
[APE][ape] → [ZIP parasitism][zip] → [polyglot craft][polyglot] →
[parser differentials][differentials] → [boot hybrids][boot].

**"I came for SELF."**
[SELF][self] → [sqlelf][sqlelf] → [SQLite as an app file format][aff] →
[`binfmt_misc`][binfmt] → [the VFS seam][vfs] → [measurement][measure]. Read
[the threat model][threat] before forming an opinion about deploying it.

**"I want to know whether this is actually new."**
[Single-level store][sls] → [Plan 9][plan9] → [image-based systems][images] →
[comparison § thesis 2][thesis2]. Short answer: no, and the reasons the
predecessors lost are better documented than the current wave admits.

**"I have to make a format decision."**
[concepts § tolerance][tolerance] → [footer-indexed formats][footer] →
[range-request consumption][range] → [debug info][dwarf]. The writer-side
constraint in `footer-indexed-formats` is the one that will decide it.

**"I need to measure something."**
[measurement][measure], and nothing else first.

## Sources

Each deep-dive owns its own primary sources and pinned citations; this umbrella
cites none of its own. Grounding state at the last review: **590 GitHub blob
citations across the tree, 495 verified to resolve at their pinned commit**
against local clones (`ci --check-blob-paths`), every GitHub URL pinned to a
40-character SHA (`ci --check-vcs-urls`), and **154 individually-recorded claims
that could not be verified**, each either dropped or explicitly marked on the
page that raised it.

<!-- References -->

[concepts]: ./concepts.md
[axes]: ./concepts.md#the-four-axes
[tolerance]: ./concepts.md#tolerance-a-partial-order-on-composability
[terms]: ./concepts.md#terms-used-throughout
[oos]: ./concepts.md#what-is-out-of-scope
[comparison]: ./comparison.md
[shape]: ./comparison.md#the-shape-of-the-space
[thesis2]: ./comparison.md#thesis-2--self-description-is-what-makes-a-format-survivable
[open]: ./open-questions.md
[ape]: ./cosmopolitan-ape/index.md
[zip]: ./zip-parasitism.md
[polyglot]: ./polyglot-craft.md
[boot]: ./boot-hybrids.md
[differentials]: ./parser-differentials.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[inspection]: ./binary-inspection-libraries.md
[relational]: ./relational-system-surfaces.md
[codedb]: ./code-as-database.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[wasm]: ./wasm-component-model.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[nix]: ./nix-store-closures.md
[chunking]: ./content-addressed-chunking.md
[images]: ./image-based-systems.md
[aff]: ./sqlite-application-file-format.md
[vfs]: ./sqlite-vfs-substrate.md
[provenance]: ./embedded-provenance.md
[dwarf]: ./debug-info-and-indexes.md
[threat]: ./threat-model.md
[sls]: ./single-level-store.md
[plan9]: ./plan9-namespaces.md
[measure]: ./measurement.md
[packaging]: ../application-packaging/index.md
