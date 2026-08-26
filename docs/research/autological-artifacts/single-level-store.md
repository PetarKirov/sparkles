# Single-level store (IBM i / OS/400, Multics, Pick, VMS RMS, MVS datasets)

The prior art the current wave under-cites: a family of systems in which the operating system, not the application, owned the schema — one of which shipped commercially, is still shipping, and moved an entire installed base from CISC to POWER without recompiling a single customer application.

| Field           | Value                                                                                                                                                                                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Operating-system architecture family: one address space over memory and disk, typed objects instead of files, a machine-independent program representation, and an integrated relational database as the object model                                                                                               |
| Language        | PL/MI, PL/MP and C++ (IBM i Licensed Internal Code) · PL/I (Multics) · C (`ScarletDME`, the readable Pick-lineage implementation) · BLISS/Macro-32 (VMS RMS) · assembler + PL/X (MVS/DFSMS)                                                                                                                         |
| License         | Proprietary (IBM i, z/OS, OpenVMS) · GPL-2.0-or-later (`ScarletDME`, from the OpenQM 2.6-6 GPL release)                                                                                                                                                                                                             |
| Repository      | No single upstream. The one readable implementation in the family is [geneb/ScarletDME][sdme-repo]; everything else is documented rather than published                                                                                                                                                             |
| Documentation   | [IBM i ILE Concepts (SC41-5606)][ile-pdf] · [IBM i Security reference (SC41-5302)][secref-pdf] · [IBM i Database programming][dbp-pdf] · [`IBM i Program Conversion` (REDP-4293)][redp4293] · [multicians.org][multicians] · [VSI OpenVMS RMS Reference][rms-ref] · [z/OS DFSMS Using Data Sets (SC26-7410)][dfsms] |
| First release   | Multics segments described at FJCC, November 1965 · System/38 shipped 1980 · AS/400 announced June 1988 (`OS/400` V1R1) · Pick lineage from Reality, 1973 · VMS RMS with VAX/VMS 1.0, 1978 · MVS datasets inherited from OS/360, 1966                                                                               |
| Axis profile    | Multiplicity 0 / Reflexivity 3 / Closure 1 / Mutability 2                                                                                                                                                                                                                                                           |
| Index anchoring | Out-of-band, and further out of band than anything else in this catalog — the index is the machine's own object catalog, reached through a resolved pointer, never by scanning an object's bytes                                                                                                                    |
| Dispatch owner  | Kernel — below the kernel, in fact: the type is carried in a hardware-tagged pointer and checked beneath the machine interface, so nothing ever sniffs content                                                                                                                                                      |

> **Revisions surveyed:** IBM i manuals at V6R1 (`SC41-5606-08`, `SC41-5302-10`, and the V6R1 Database programming and Program/CL API books, all from IBM's public manual mirror) · `REDP-4293-01`, second edition, March 2010 · `SG24-7680` (Security Guide for IBM i V6.1) · `SG24-7858` (IBM i 7.1 Technical Overview with Technology Refresh Updates) · IBM i 7.5 documentation via a verified archive snapshot dated 2022-12-02 · `ScarletDME` at `1671cdf689d7257ea6a49e3abea3d5d69f0aec68` (2025-09-29) · `z/OS DFSMS Using Data Sets`, tenth edition, September 2009 (z/OS V1R11) · VSI OpenVMS RMS Reference Manual, © 2014–2026. First-release dates in the table above are sourced where the surveyed documents state them (the 1988/1995/6.1 MI transitions, the FJCC 1965 papers); the System/38, Pick/Reality and VAX/VMS dates are the conventional ones and were **not** verified against a primary source in this survey. **Platforms:** IBM POWER (IBM i), Honeywell 645 (Multics, historical), commodity x86-64/Linux (`ScarletDME`), Alpha/Itanium/x86-64 (OpenVMS), IBM Z (z/OS).

---

## Overview

### What it solves

Every entry in this catalog is a response to the same underlying condition: a file is an untyped byte stream, so anything you want to know about it has to be re-derived by a parser, and anything you want to enforce about it has to be enforced by convention. [ELF][ld] hand-rolls a bloom filter because nothing below it offers an index. [ZIP parasitism][zip] is possible because nothing below the format objects to arbitrary bytes in front. [`sqlelf`][sqlelf] exists because `readelf` answers only the questions `readelf` was written to answer.

The systems on this page refused that condition, decades earlier, by moving the schema _below_ the application into the operating system. Four distinct refusals:

| Refusal                                                                        | System                       | Consequence                                                                                                |
| ------------------------------------------------------------------------------ | ---------------------------- | ---------------------------------------------------------------------------------------------------------- |
| There is no I/O; secondary storage is part of the address space                | Multics, System/38, IBM i    | A pointer is a pointer whether the referent is resident or on disk; no `read`/`write` to a file            |
| A stored thing is a typed object, not a byte stream                            | System/38, IBM i             | `*PGM`, `*FILE`, `*USRSPC`, `*DTAARA`; operations are checked against the type below the machine interface |
| A program is stored in a machine-independent form and translated on the target | IBM i (TIMI)                 | The instruction set can be replaced under a running installed base                                         |
| A file has records, keys, and a schema the OS maintains                        | IBM i / Db2, Pick, RMS, VSAM | The OS can enforce, index, journal, and lock at the record level without the application's help            |

IBM i is the strongest case because it is the only one that shipped all four at once, in a product with paying customers, and still does. And the second refusal purchases the third: because a program is an object rather than a byte stream, IBM could change the _representation_ of that object twice — 48-bit CISC to 64-bit RISC in 1995, and again at 6.1 — and re-derive every customer binary from data the object was already carrying.

> [!NOTE]
> This page is deliberately about the _internal structure_ of the artifact, not about how these systems were sold, operated, or migrated. Where the argument touches distribution, it defers to [`docs/research/application-packaging/`][packaging]. Where it touches "expose the system as tables", it defers to [relational system surfaces][relational], which covers osquery and Steampipe — the point here is that IBM i got there first and did not have to _project_ anything, because the tables were the system's own bookkeeping.

### Design philosophy

The philosophy is stated most sharply where you would least expect it — in a 2010 IBM Redpaper about a mandatory upgrade chore. Explaining why 6.1 re-creates every program on the machine, [`REDP-4293`][redp4293] writes:

> _"Conversion re-creates a program from its MI architecture constructs, so that system integrity cannot be attacked. A converted program conforms to MI semantics, which only allow defined operations on supported object types. Further, unlike many other systems, you do not have to worry about a continual race to update your virus scanning software before someone sends a new form of attack program. Instead of worrying about which sequences of hardware instructions might cause problems, you can refresh a program from its higher level MI operations, letting the system generate appropriate hardware instructions."_
>
> — `IBM i Program Conversion: Getting Ready for 6.1 and Beyond`, §2.3.1 "Integrity"

Three claims are packed into that paragraph, and each one is a direct inversion of a position this catalog otherwise takes for granted. First, **the shipped bytes are not the program** — the program is the MI form, and the hardware instruction stream is a derived artifact the system may regenerate at will. Second, **there is no parser to differentiate**, because "MI semantics only allow defined operations on supported object types" — the entire class of attacks covered by [parser differentials][differentials] has no surface. Third, **integrity is a property of regeneration**, not of signing: you do not verify the bytes, you throw them away and re-derive them.

Multics states the same commitment on the memory side, in Bensoussan, Clingen and Daley's [`CACM` 15(5), May 1972 paper][multics-vm]:

> _"In Multics, the number of segment descriptors available to each computation is sufficiently large to provide a segment descriptor for each file that the user program needs to reference in most applications. … As a result, the Multics user no longer uses files; instead he references all information as segments, which are directly accessible to his programs."_

and Daley and Neumann, in the 1965 FJCC file-system paper, reduce it to seven words: [_"A Multics file is a segment, and all segments are files."_][multics-fs]

The opposing philosophy — the one that won — is stated with equal clarity by Ritchie and Thompson in the 1974 `CACM` UNIX paper:

> _"No particular structuring is expected by the system. … However, the structure of files is controlled by the programs that use them, not by the system."_
>
> — [`The UNIX Time-Sharing System`, §3.1][unix-cacm]

The whole of [Why they lost, and what changed](#why-they-lost-and-what-changed) is an argument about which of those two sentences the modern [SELF][self] wave is actually descended from. The answer is not the one the outline expects.

---

## How it works

### IBM i: one address space, spanning memory and disk

The single-level store is not a caching strategy; it is the absence of a distinction. There is one address space; storage is either resident or not; a pointer to an object is valid regardless. IBM's own comparison table — written to explain _teraspace_, the process-local exception added later — is the cleanest primary statement of what single-level storage is, precisely because it is describing it by contrast ([`ILE Concepts`, Chapter 4, Table 2][ile-pdf]):

```text
Attributes                     Teraspace                          Single-level storage
Locality                       Process local: normally accessible Global: accessible to any job that
                               only to the owning job.            has a pointer to it.
Size                           Approximately 100 TB total         Many 16 MB units.
Supports memory mapping?       Yes                                No
Addressed by 8-byte pointers?  Yes                                No
Supports sharing between jobs? Must be done using shared memory   Can be done by passing pointers to
                               APIs (for example, shmat or mmap). other jobs or using shared memory APIs.
```

Two rows deserve to be read twice by anyone who has followed [the `mmap` thesis][open]. **"Supports memory mapping? No"** — because there is nothing to map; the address _is_ the location. And **"Global: accessible to any job that has a pointer to it"** — cross-process sharing is not a feature of the loader, it is a consequence of there being one address space. IBM i achieves what [SELF loses][self] by removing the mechanism SELF is trying to preserve.

The pointer itself is the other half of the mechanism. The same chapter's Table 5 compares the two pointer widths, and the second row is the entire security architecture in one word ([`ILE Concepts`, Chapter 4, Table 5][ile-pdf]):

```text
Property             8-byte pointer                   16-byte pointer
Length               8 bytes                          16 bytes
Tagged               No                               Yes
Alignment            Byte alignment is permitted      Always 16-byte.
Addressable range    Teraspace storage                Teraspace storage + single-level storage
Pointer content      A 64-bit value which represents  16-byte pointer type bits and a 64-bit
                     an offset into teraspace.        effective address.
Locality of          Process local storage reference. Process local or single-level storage
reference                                             reference. (A 16-byte pointer can reference
                                                      storage that is logically owned by another job.)
```

A single-level-store pointer is 16 bytes, 16-byte aligned, carries pointer _type_ bits alongside a 64-bit effective address, and is **tagged** — hardware maintains an out-of-band bit per aligned quadword that says "these sixteen bytes are a pointer". Any ordinary store through a non-pointer view clears the tag. That is capability addressing in the [Berstis/System-38 sense](#mutability-dispatch-and-trust): a pointer cannot be forged by computing one, because arithmetic on the bytes destroys the property that makes them a pointer. There is no equivalent in any other subject in this catalog, and it is the reason `*USER`-state code cannot reach `*SYSTEM`-domain objects even in principle.

### TIMI: the program is stored as its own machine-independent source

Every IBM i program object is created from a **machine interface (MI) program template** and retains that template as _creation data_. The hardware instruction stream is a translation of it. IBM's marketing name for the property is "technology independent Machine Interface", and [`REDP-4293`][redp4293] states the payoff without hedging:

> _"Most important to nondisruptive growth is the IBM i technology independent Machine Interface (MI). Proven over many years and technology generations, the IBM i MI has protected applications from changing hardware devices and processor generations, even enabling applications to be upgraded to new technology without recompilation."_

The retained creation data is what makes that true, and the same document supplies the exact history:

> _"This conversion is the third in the history of the MI architecture. The first conversion occurred when moving from System/38 to OS/400 V1R1 in 1988. The second conversion occurred for OS/400 V3R6 in 1995, when upgrading from 48-bit to 64-bit addresses and running a different hardware instruction set."_

Read that as a claim about formats rather than about IBM: **three times, an installed base of binaries survived a change of instruction set, address width, or object format, without source.** The reason is that each program object is _self-describing in the strong sense of [thesis 2][concepts]_ — it carries the input to its own regeneration. `readelf` cannot rebuild an ELF file; `STROBJCVN` rebuilds a `*PGM`.

The mechanism has three trigger points and one hard failure mode. Conversion happens on restore, on an explicitly scheduled `STROBJCVN` run, or lazily at first call — and IBM warns that the lazy path is the worst one, because _"first call conversion might be the slowest conversion method, particularly on partitions that have more than one processor available"_, since it serializes on whichever job happened to call first ([`REDP-4293`, §4.4][redp4293]).

The failure mode is the interesting part. A program can be created without full creation data, or have it stripped afterwards with the remove-observability parameter — `CHGMOD RMVOBS(…)` / `CHGPGM RMVOBS(…)`. The V6R1 Program and CL Command APIs book defines the three states an object can be in ([`Retrieve Module Information`][pgm-pdf]):

```text
0     *NO.     Not all the creation data is present.
1     *YES.    All the creation data is present and observable.
2     *UNOBS.  All the creation data is present but not all of that data is observable.
```

with the rule that _"All creation data (either observable or unobservable) is needed to convert the module during restore."_ A program in state `0` cannot be converted. [`REDP-4293`, §3.4][redp4293] is blunt about the consequence: _"If a program without creation data is still in use, then it is necessary to recompile it. Alternatively, if a program was supplied to you without source code, you must replace it with a newer version that contains creation data."_ Programs died at 6.1 in exactly one case: their owners had thrown away the self-description to save space. That is [thesis 2][concepts] with a body count.

### Db2 for i: the object store _is_ the database

On IBM i there is no filesystem underneath the database. The [Database programming][dbp-pdf] manual says it in one sentence — _"DB2 for i5/OS is the integrated relational database manager on the i5/OS operating system. DB2 for i5/OS is part of the i5/OS operating system"_ — and then supplies the identity that matters here:

> _"A database file is one of the several types of the system object type `*FILE`. … A physical file consists of fixed-length records that can have variable-length fields. It contains one record format and one or more members. From the perspective of the SQL interface, physical files are identical to tables. … A logical file is a database file that logically represents one or more physical files. … From the perspective of the SQL interface, logical files are identical to views and indexes."_

So: table ≡ `*FILE` ≡ operating-system object, view/index ≡ logical file ≡ _also_ an operating-system object. There is one namespace, one authority model, one save/restore, one journal. `CREATE TABLE` and `CRTPF` produce the same kind of thing.

The schema is enforced across the compile/run boundary by a mechanism with no analogue in the Unix world. Every record format has a **level identifier** derived from its field definitions; a compiled program records the identifier of the format it was compiled against; the system compares them when the file is opened ([`Database programming`][dbp-pdf]):

> _"When a database file is opened, the system checks whether the description of the record format has been changed since the program was compiled to an extent that it cannot process the file. … Assume that you compiled your program two months ago. At that time, the file was defined as having three fields in each record. Last week another programmer decided to add a field to the record format, so now each record has four fields. When your program tries to open the file, the system notifies your program that a significant change has occurred to the file definition since the last time the program was compiled. This notification is known as a record format level check."_

`LVLCHK` is a [materialized view][concepts] with an explicit version check: the compiled program caches a derivation of the schema, and the OS detects staleness at bind time rather than corrupting rows. Compare the failure modes catalogued in [dynamic linking][ld], where a changed `struct` layout across a shared-library boundary is undetected until it is a crash, and in [debug info and indexes][debug], where a stale `.gdb_index` simply lies. `LVLCHK` is the same problem, solved, in 1978 hardware terms — and, tellingly, it has an override (`OVRDBF … LVLCHK(*NO)`), because sometimes you need to lie to it too.

### The ancestors and cousins

**Multics (1965–2000).** The single-level store's origin. Segments are simultaneously the unit of storage, the unit of addressing, and the unit of protection: a segment descriptor word carries the core address, the length, and the access rights, and the 645 processor checks all three on every reference ([`Multics Virtual Memory`, §5.1][multics-vm]). The design goals are stated as a pair: _"(1) it must be possible for all on-line information stored in the system to be addressed directly by a processor … (2) it must be possible to control access, at each reference, to all on-line information in the system."_ The consequence Multics draws is the one IBM i inherited: _"The fundamental advantage of direct addressability is that information copying is no longer mandatory."_ Multics has, in the vocabulary of [concepts][concepts], **page sharing as an axiom** — you cannot have two copies of a segment, because there is only one name for it.

**Pick (1973–), read here as `ScarletDME`.** The one member of the family whose implementation can be read. Pick's filesystem is a multivalued database: a file is a hash-partitioned store of variable-length _items_, each item a string carrying its own structure through four reserved delimiters ([`gplsrc/qmdefs.h`][sdme-qmdefs]):

```c
/* ScarletDME — gplsrc/qmdefs.h */
#define U_TEXT_MARK     ((u_char)'\xFB')
#define U_SUBVALUE_MARK ((u_char)'\xFC')
#define U_VALUE_MARK    ((u_char)'\xFD')
#define U_FIELD_MARK    ((u_char)'\xFE')
#define U_ITEM_MARK     ((u_char)'\xFF')
```

Those five bytes are `0xFB`–`0xFF`, which is exactly the range [RFC 3629][rfc3629] declares unreachable in UTF-8 — _"The octet values C0, C1, F5 to FF never appear."_ Pick chose its delimiters in the 1970s from the top of the byte range for EBCDIC/ASCII reasons and, by accident, chose the only bytes that a Unicode-era text pipeline can never legitimately produce. It is the one place in this family where an in-band, self-delimiting encoding was chosen over out-of-band metadata, and it is the one place where the format survived transplantation onto a foreign substrate.

The schema is data in the same store. Every Pick file has a _dictionary_, itself a file, whose items describe the fields of the data portion; `OPEN 'DICT' filename` and `OPEN filename` differ by one string, and [`gplsrc/op_dio1.c`][sdme-dio1] resolves both through the same path:

```c
/* ScarletDME — gplsrc/op_dio1.c, op_open() */
(void)k_get_c_string(dict_descr, s, 4);
open_dict = (stricmp(s, "DICT") == 0);
/* ... */
if (!get_voc_file_reference(voc_name, open_dict, mapped_name)) {
```

And the namespace itself is a file. `VOC` — the vocabulary — holds one item per verb, per file, per keyword; `get_voc_file_reference` is a lookup _in a database file_ for every name the command language can resolve. The shipped `VOC` contains an entry for `VOC` ([`qmsys/NEWVOC/VOC`][sdme-voc], fields shown one per line):

```text
File - Vocabulary
VOC
@QMSYS/VOC.DIC
```

That is autology in the catalog's strict sense: the file that resolves every name contains the record that resolves its own. Compare the [`sqlite_schema` table][sqlite-format] describing the table it is stored in, and [redbean serving assets out of the ZIP it is executing from][ape].

Pick's secondary indexes ("alternate keys", AK subfiles) go one step further and embed the schema _inside the index_, with an explicit staleness check ([`gplsrc/dh_fmt.h`][sdme-dhfmt]):

```c
/* Although the following items refer to I-types, the entire
   dictionary record is stored here for all indices, not just I-types */
int32_t itype_len;                 /* Length of i-type expression */
int32_t itype_ptr;                 /* Pointer if I-type elsewhere, else 0 */
u_char  itype[AK_CODE_BYTES];      /* Buffer for short i-type */
char    ak_name[MAX_AK_NAME_LEN + 1];
int32_t data_creation_timestamp;   /* Creation timestamp of data file */
```

and, on open, [`gplsrc/dh_open.c`][sdme-dhopen] refuses to proceed if the index does not belong to this data file:

```c
/* Cross-check the index subfile with the primary data subfile */
if (header.creation_timestamp != ak_header.data_creation_timestamp) {
  dh_err = DHE_AK_CROSS_CHECK;
  goto exit_dh_open;
}
```

An index that carries the compiled definition that produced it, plus the identity of the data it indexes, is the design [`prelink` and `ldconfig` never had][ld] — and the design [the catalog's materialized-view problem][concepts] keeps asking for.

**VMS RMS (1978–).** RMS is the schema layer without the single-level store: files have an _organization_ (sequential, relative, indexed), a _record format_ (fixed, variable, and more), and keys, all declared at creation and enforced by the OS afterwards. The [VSI RMS Reference][rms-ref] enumerates the surface: _"RMS supports sequential, relative, and indexed file organizations, and fixed-length and variable-length record formats are supported for each file organization. … The RMS record access modes permit you to access records sequentially, directly by key value, directly by relative record number, or directly by record file address (RFA)."_ The schema is carried in control blocks — a `FAB` for the file, a `RAB` for a record stream, and extended attribute blocks (`XAB`s) that supersede and supplement them, including `XABKEY`, which _"defines the key characteristics to be associated with an indexed file"_. Critically, the same structures answer questions as well as ask them; the manual titles a section "Dual Purpose of Control Blocks" and notes that programs _"specifically allocate a NAM or NAML block or one or more `XAB`s dedicated to receiving information returned by RMS"_. That is a reflection API for files, in 1978, with a fixed menu of questions.

**MVS/z/OS datasets (1966–).** The same idea at IBM's other end. A dataset is _"a collection of logically related data"_ with a record format (`RECFM`), a logical record length (`LRECL`), and a `DSORG`; VSAM adds five typed shapes — `KSDS`, `ESDS`, `RRDS`, variable-length `RRDS`, and `LDS` — chosen when the dataset is defined, and catalogued so the system can find them ([`z/OS DFSMS Using Data Sets`, Chapter 1][dfsms]). The manual contains one sentence that is worth the whole rest of this page, filed as an exception:

> _"Exception: z/OS UNIX files are different from the typical data set because they are byte oriented rather than record oriented."_

In 2009, on the platform where record-structured files were invented, the byte stream is documented as _the special case_.

---

## Format identity and multiplicity

**Multiplicity is 0, and the zero is a design position rather than an oversight.**

For an IBM i object there is no byte stream a second parser could reach. A `*PGM` is not a file with a header; it is a typed object reached through a resolved system pointer, and the operations available on it are constrained by its type below the machine interface. The tolerance vocabulary of [concepts][concepts] — prefix-tolerant, suffix-tolerant, hole-tolerant — does not merely fail to apply; it has no referent, because there is no self-declared extent within an addressable stream for a foreign format to occupy. You cannot append a ZIP to a `*PGM`, not because the system forbids it, but because there is no operation that would express it.

The consequences run both ways, and both are findings:

- **The whole adversarial cluster evaporates.** [Parser differentials][differentials], MIME sniffing, GIFAR, `binfmt_misc` magic collisions — every one of these requires two consumers to disagree about one byte stream. There is exactly one consumer here and it is beneath the ABI. The [`REDP-4293`][redp4293] integrity argument quoted above is precisely this claim, stated as a product feature: MI semantics _"only allow defined operations on supported object types"_.
- **The format could be changed under everyone, and was.** Because no third party had a parser, IBM was free to alter the on-disk program representation in 1988, 1995, and 6.1. A format nobody can parse is a format nobody depends on. This is the exact inverse of ELF's situation, where the [installed base of parsers][binlib] is the thing that makes the format immortal — and, as [thesis 2][concepts] would predict, immortal in a way that accretes conventions rather than schema.

The ancestors sit at different points. Multics segments are as unparseable as IBM i objects, for the same reason. VMS and MVS separate the _record bytes_ from the _schema_: on MVS the shape is declared in the `DCB` and the dataset's label — `DCB DDNAME=DD1,DSORG=PS,...,LRECL=80,RECFM=FB` is a line of assembler in [the DFSMS manual][dfsms], not a header in the data — and the record bytes themselves carry no delimiters — which means a dataset's bytes are meaningless without out-of-band metadata, and a `KSDS` extracted onto a Unix filesystem is not a file so much as a rubble pile. Only Pick put its structure _in band_, in the `0xFB`–`0xFF` mark characters, and Pick is consequently the only one of the four whose data survives a `cat`.

That is a small, sharp result for the tolerance partial order: **in-band self-delimiting structure is what makes data portable off the system that created it, and every system here except Pick chose out-of-band metadata instead.** [SQLite's file format][sqlite-format] is in-band all the way down, with the header at offset 0 and the schema in `sqlite_schema`, and that — not b-trees — is the property [SELF][self] inherits.

## Index anchoring and random access

**Anchoring is out-of-band, and radically so: the artifact does not know its own index, because the artifact does not have a beginning.**

On IBM i, the "index" that finds an object is the machine's context/library structure, and the address that reaches it is a resolved 16-byte pointer. There is no scan, no header, no footer, no signature search. Once the pointer is resolved, random access costs a page fault and nothing else — which is the single-level store's whole efficiency argument, and it is why "partial read" is not a concept the architecture has. This is also why nothing in this family can participate in the strategy described in [range-request access][range]: you cannot `Range:`-request an object whose only identity is an address in a store you are not part of. The comparison is stark — [footer-indexed formats][footer] are designed so that 40 KiB of a remote file answers a question about the whole; a single-level store answers questions only from inside.

Above that layer, Db2 for i's access paths are ordinary materialized views with ordinary staleness management: a logical file is a separate object, `MAINT` selects immediate, rebuild or delayed maintenance, and — as covered above — `LVLCHK` guards the compiled program's cached copy of the record format.

Pick's dynamic files are the family's most interesting answer, because they have _no primary index at all_. The group a record lives in is a function of its key: `ScarletDME`'s `DH_HEADER` carries a `hash` type and `user_hash` code, groups are numbered from 1, and a record lookup is a hash, a seek, and a linear walk of the group ([`gplsrc/dh_fmt.h`][sdme-dhfmt]). The record header is four fields plus the key inline:

```c
struct DH_RECORD {
  int16_t next;         /* Record size (offset to next record) */
  unsigned char flags;  /* DH_BIG_REC */
  unsigned char id_len; /* Bytes in id */
  union { int32_t data_len; int32_t big_rec; } data;
  char id[1];           /* Id starts here, followed by data */
};
#define MAX_KEY_LEN 255 /* Because id_len is u_char */
```

A single-byte `id_len` caps keys at 255 bytes; a `int16_t next` caps a record's in-group extent; oversized records escape to a `DHT_BIG_REC` chain. The file grows by _splitting groups_ rather than rebuilding an index — which is why Pick files degrade gracefully and why "resize the file" is an administrative verb on these systems rather than a transparent operation. Secondary access requires an explicit AK subfile, and that subfile, as shown above, carries its own copy of the dictionary record that defines it.

VSAM and RMS make the choice architectural: `KSDS` versus `ESDS` versus `RRDS` versus `LDS` is chosen at define time and cannot be changed afterwards without a copy, and `RFA` — the record file address — is a stable row identifier the application may keep and re-present. `RFA` is a rowid, twenty years before rowids.

## Reflexivity and query surface

**Reflexivity is 3, and this is the axis on which the family is genuinely ahead of the modern wave.**

IBM i today ships **IBM i Services**: SQL views and table functions in the `QSYS2` schema over the operating system's own state. `SG24-7858` documents dozens, including `QSYS2.OBJECT_STATISTICS`, whose signature is `OBJECT_STATISTICS(library-name, object-type-list)` and whose columns are `OBJNAME`, `OBJTYPE`, `OBJOWNER`, `OBJDEFINER`, `OBJCREATED`, `OBJSIZE`, `OBJTEXT`, `LAST_USED_TIMESTAMP`, `DAYS_USED_COUNT`, `IASP_NUMBER`, `OBJATTRIBUTE` ([`SG24-7858`, §5.4.3][sg247858]):

```sql
SELECT * FROM TABLE (QSYS2.OBJECT_STATISTICS('MJATST ', '*JRN *JRNRCV')) AS X;
```

alongside `QSYS2.USER_INFO`, `QSYS2.FUNCTION_USAGE`, `QSYS2.PTF_INFO`, `QSYS2.SYSDISKSTAT`, `QSYS2.TCPIP_INFO`, and `QSYS2.GET_JOB_INFO()`. Read the column list next to an [osquery `.table` spec][relational] and the resemblance is not a resemblance. The difference is structural and it favours IBM: **osquery reifies — a `processes` row is computed by walking `/proc` at the instant the planner asks — whereas `OBJECT_STATISTICS` reads the object catalog the system is already maintaining for its own purposes.** osquery's own documentation concedes the cost of reification, warning that _"query-time synchronous data retrieval is lossy"_. IBM i does not have that problem for objects, because the rows are not a projection of the truth; they are the truth.

The reflexivity extends to the platform's own migrations. `ANZOBJCVN`'s conversion-readiness analysis writes its results into Db2 files — `QAIZACVN`, `QAIZAOBJ`, `QAIZADIR`, `QAIZASPL` — and [`REDP-4293`, §3.5][redp4293] tells administrators to query them:

```sql
-- Total conversion time in seconds for *PGM and *SRVPGM objects
SELECT DECIMAL(SUM(DIOCTM))/1000 FROM QUSRSYS/QAIZACVN
 WHERE (DIOBTP = 'PGM' OR DIOBTP = 'SRVPGM');

-- File system objects still requiring Java program conversion, with full path
SELECT O.QIZAOBJNAM, D.QIZADIRNAM1 FROM QUSRSYS/QAIZAOBJ AS O
 INNER JOIN QUSRSYS/QAIZADIR AS D ON D.QIZADIRIDX = O.QIZADIRIDX
 WHERE O.QIZACVNFLG = 1 OR O.QIZANAMFLG = 1;
```

"Which of my binaries cannot be re-translated for the new instruction set, and how long will translating the rest take?" is answered by a `JOIN`. That is [`ldd` becomes a `JOIN`][self] and [`sqlelf`][sqlelf], shipped as an upgrade tool in 2008.

Pick's reflexivity is older and cruder but more complete: `VOC` and the per-file dictionaries mean the _command vocabulary_, the _file catalog_, and the _schema_ are all items in files, queried with the same query verbs (`LIST`, `SORT`) as application data. The shipped `VOC` entry for the query processor is three fields — a description, a class code, and the name of the program that implements it ([`qmsys/NEWVOC/LIST`][sdme-list]):

```text
Verb - Query processor
CA
$QPROC
2
```

Adding a verb to the shell is an `INSERT`. That is the same collapse [`self-httpd` performs with its `handlers` table][self], reached from the other direction and forty-five years earlier.

Multics scores lower on the _general query surface_ half of the axis and maximally on the _self-interrogation_ half: a directory is a segment, so a program reads the file system by reading memory, but there is no query language — only a fixed menu of supervisor entries. RMS is fixed-menu too, but explicitly bidirectional (the `XAB`-as-output-parameter idiom).

## Closure, dedup, and size model

**Closure is 1 — incidental, and the score needs defending, because the intuition points the other way.**

An IBM i program object carries the input to its own regeneration (creation data) but _not_ its dependencies. A bound `*PGM` still resolves its `*SRVPGM` imports by name at activation, exactly as `DT_NEEDED` resolution works in [dynamic linking][ld]. What the platform has instead of closures is a store: one machine, one address space, one copy of everything, shared by everyone with a pointer. In [concepts][concepts]' terms, IBM i does not compute a closure and copy it (the AppImage model) nor compute it and share it (the [Nix][nix] model) — it never partitions the world into closures at all, so there is nothing to deduplicate.

That is the strength and the fatal weakness in one property. Dedup is perfect and free: the ILE Concepts table's _"Global: accessible to any job that has a pointer to it"_ is a stronger sharing guarantee than `mmap` provides, because it holds without alignment requirements, without a page cache, and without two processes agreeing on a path. Multics states the same result as a design consequence: _"information copying is no longer mandatory. Since all instructions and data items in the system are processor-addressable, duplication of procedures and data is unnecessary."_

The cost is that **there is no artifact to ship.** An object exists inside a store; its identity is an address in that store; the only export is `SAVOBJ`/`SAVLIB` into a save file readable by the same architecture. You cannot `scp` a `*PGM`. Compare [SELF's headline number][self]: 723 executables and their transitive dependencies packed into one 611.9 MiB database, against 644.4 MiB of the equivalent ELF files, and 5.53 GiB under a per-root private-closure model. IBM i can beat all three on disk and _cannot produce any of them as a file_.

**Concrete numbers on the cost of self-description.** IBM publishes no per-object figure for what creation data costs, and the honest reading of that absence is that the cost was material enough to make removable but not embarrassing enough to quantify: `RMVOBS` exists on `CHGMOD` and `CHGPGM`, and the `DSPPGM`/`DSPMOD` output breaks an object into a dozen separately-sized components (alias, associated space, binding specifications, binding work area, debug space, debug statement mapping table) precisely so an administrator can see where the bytes went ([`Program and CL Command APIs`][pgm-pdf]). What IBM _does_ quantify is the cost of _using_ the self-description. A sample `ANZOBJCVN` `*LIBSUM` report in [`REDP-4293`, §3.3.3][redp4293] shows:

```text
Total analyzed objects . . . . . . . . . . . . . :  6,557
Objects that can be converted with no lost attributes :  6,545
Total objects to convert . . . . . . . . . . . . :  6,546
Total estimated conversion time for library objects. :  00:39:41
```

6,546 objects, 2,381 seconds — **≈0.36 s per object** to re-translate a userland from its machine-independent form, on a 2008-era single-processor estimate, with individual programs reported at 0.124 s. That is the number to hold next to [the measurement page's][measurement] decomposition of SELF's ~5 ms startup: IBM i pays install-time translation once per object per architecture generation; SELF pays interpretation cost per exec. The two are the same trade — a [materialized view of the resolved program][concepts] — resolved at different points on the eager/lazy axis, and IBM's warning that first-call conversion is the _worst_ method is an empirical vote for eager materialization.

## Mutability, dispatch, and trust

**Mutability is 2.** The single-level store makes the durable store and the process image the same thing: a store instruction to a space object is a write to persistent storage, and there is no `write()` in the path. Journaling and commitment control make it transactional at the record level, and — the detail that matters for [the signing problem][provenance] — journaling was retrofitted onto the byte-stream namespace too: _"In OS/400 V5R1M0, journal support was added to the integrated file system. You can journal changes to directories, stream files, and symbolic links"_ ([IFS backup experience report][ifs-pdf]). What the family does _not_ have is the specific autological form: a `*PGM` is not its own state store the way [`self-httpd`'s `visits` table][self] is. State lives in adjacent objects — data areas, user spaces, database members — in the same store, under the same authorities, saved by the same command. Hence 2, not 3.

**Dispatch has no ambiguity to resolve.** Nothing sniffs. The type of an object is carried in the tagged pointer that reaches it and enforced beneath the machine interface, so the four dispatch owners of [concepts][concepts] collapse to one that sits _below_ the kernel/loader distinction entirely. There is no [`binfmt_misc`][binfmt] equivalent because there is no magic number, no shebang because there is no text, and no `ld.so` search order because binding is a system function over a namespace the system owns. The catalog's recurring failure mode — two dispatchers disagreeing about one byte stream — is structurally impossible.

**Trust is where this family is decades ahead, and the reasons are worth enumerating** against [the threat-model page][threat]:

| Mechanism                            | What it enforces                                                                                                                                          | Source                            |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| Tagged 16-byte pointers              | A pointer cannot be synthesized; any non-pointer store through the same bytes clears the tag                                                              | [`ILE Concepts` Table 5][ile-pdf] |
| Domain / state                       | *"Every object belongs to either the `*SYSTEM`domain or the`*USER`domain.`*SYSTEM`domain objects can be accessed only by`_SYSTEM` state programs"_        | [Security reference][secref-pdf]  |
| Enhanced hardware storage protection | Blocks defined read-write / read-only / no-access; some _"critical system control blocks"_ are read-only _"from any program state"_                       | [`SG24-7680`][sg247680]           |
| Parameter validation                 | At level 40+, _"the system specifically checks every parameter passed between a user state program and a system state program in the user domain"_        | [Security reference][secref-pdf]  |
| Address-space isolation between jobs | At level 50, _"a user state program cannot obtain the address for another job on the system"_                                                             | [Security reference][secref-pdf]  |
| Pointer scrubbing in messages        | At level 50, *"when a user state program receives a message from an external source (`*EXT`), any pointers in the message replacement text are removed"\* | [`SG24-7680`][sg247680]           |
| Validation value on restore          | Computed at creation, recomputed at restore; mismatch handled per `QFRCCVNRST` / `QALWOBJRST`                                                             | [Security reference][secref-pdf]  |
| Re-creation from MI                  | _"any unsupported alterations (for example, changing the hardware instruction stream with a service tool) are eradicated"_                                | [`REDP-4293` §2.3.1][redp4293]    |

Note what the last row implies. **IBM i's answer to "how do you trust a binary" is not a signature over bytes; it is regeneration from a higher-level representation.** Signatures exist, and [`REDP-4293` §3.3.3][redp4293] warns that 6.1 conversion _drops_ them — _"Objects that will lose their digital signatures if `YES` is displayed under 'Digitally Signed'"_ — precisely because the bytes being signed are about to be replaced by better ones. That is the sharpest available data point for [the catalog's open signing question][provenance]: a platform that has to re-derive its executables cannot sign their bytes, and IBM's resolution was to make the signature the _less_ trusted artifact. `W^X` in the [threat model][threat] sense is likewise not a policy here but a type property: user-state code cannot write to a `*PGM`'s associated space at any security level.

---

## Why they lost, and what changed

The [source outline][concepts] proposes three candidate explanations for why this architecture lost and why the idea is being revisited now. All three are testable against the sources above, and only one survives unmodified.

### (a) SQLite's ubiquity and stability removed the format-adoption cost — **supported, but misstated**

The candidate is right about the outcome and wrong about the quantity. The adoption cost these systems faced was never the _format_; it was the _toolchain that had to know about it_. TIMI required IBM to own the compilers, the operating system, the licensed internal code, and the processor design simultaneously — that is what it took to be able to say _"even enabling applications to be upgraded to new technology without recompilation"_. Pick required its own language (DataBASIC), its own query processor, and its own shell. RMS required every VMS language's runtime to speak `FAB`/`RAB`. In each case the schema layer could only be adopted by adopting the entire vendor stack.

[SQLite][sqlite-appfmt] changes exactly this variable. It is, by its own account, [_"likely the most widely deployed and used database engine"_][sqlite-mostdeployed], with [long-term support committed through 2050][sqlite-lts], and it is already linked into the toolchain — every one of these deep-dives' subjects can read a SQLite file today without a new dependency. A format nobody has to adopt has an adoption cost of zero. That, and not b-trees, is what makes [SELF's `application_id` at byte 68][self] a plausible proposal where TIMI's program template was not.

### (b) Storage got cheap enough that a 2× b-tree overhead is negotiable — **refuted by the primary measurement**

There is no 2× overhead to negotiate. [SELF's own numbers][fz-self] are 611.9 MiB of database against 644.4 MiB of the equivalent ELF files for 723 executables plus their transitive dependencies — the database is _smaller_, because the schema deduplicates shared libraries and symbols across closures the way a store does. The AppImage-style comparison (5.53 GiB) is a comparison against a different architecture, not against the overhead of b-trees.

The measured overhead is negative at closure scale and, at single-artifact scale, is dominated by a different variable entirely: how much self-description you keep. IBM i's history says this precisely. The platform shipped `RMVOBS` because creation data cost real bytes; the programs whose owners used it are exactly the programs that could not be converted at 6.1 and had to be recompiled or repurchased. **The negotiable quantity was never storage; it was retention of the self-description, and the systems that kept it survived their architecture transitions while the ones that stripped it did not.** [Thesis 2][concepts] gets a hard confirmation from the only long-run natural experiment available.

### (c) LLM assistance dropped the cost of rewriting toolchains — **partly supported, and the stated enabler is something else**

The outline says both `fzakaria` posts are explicit that this is why now. They are explicit about AI, but not about that mechanism. The first post's statement is about _motivation to revisit_:

> _"I never let the idea go and with the recent improvements with LLMs, I find it compelling to revisit these ideas to explore further. Specifically, can we replace ELF with SQLite as an executable format?"_
>
> — [`Your executable is a SQLite database`, 2026-08-23][fz-self]

and the second's is an admission about the prototype's provenance: _"It is probably a bit half-baked, and definitely AI assisted, but that's OK with me"_ ([`Actually Queryable Executables`, 2026-08-24][fz-queryable]). Neither says LLMs made rewriting a toolchain feasible. The enabler the first post actually names, in its opening sentence and again in its closing one, is **Nix**:

> _"I have been probably obsessed with two things in the last few years: Nix as a tool to explore innovative ideas that require the capability to rebuild the world and replacing ELF with SQLite as an executable format."_ … _"Nix lets us explore radical ideas like this. We can rebuild the world down to the Linux kernel if needed."_

That correction sharpens the comparison rather than weakening it. Two eras, two answers to the same problem — _the world's binaries are in the wrong format_:

| Era       | Answer                                                                                                  | Cost                                                         |
| --------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| IBM, 1978 | Insert a machine interface so the world never has to be rebuilt; keep each program's regeneration input | Own the whole stack; pay ~0.36 s per object per transition   |
| Nix, 2026 | Rebuild the world, from the kernel up, whenever the format changes                                      | Own a build-graph closure; pay a full rebuild per experiment |

They are the same insight — the derived form is disposable if the source form is retained — applied at different layers. TIMI keeps the source form _inside the artifact_; [Nix][nix] keeps it _outside_, in the derivation graph. LLM assistance is a third-order effect on top of either.

### (d) The byte stream composed, and the schema did not — **the answer the outline omits**

Ritchie and Thompson's sentence is the whole mechanism: _"the structure of files is controlled by the programs that use them, not by the system."_ A byte stream composes with pipes, with `grep`, with `diff`, with `git`, with HTTP, and with every tool written by someone who never heard of your format. A record-structured file composes with the vendor's tools, and stops.

Every system on this page paid for its schema with a closed toolchain, and the price is visible in what you _cannot_ do:

- You cannot `diff` a `KSDS` or a `*FILE` without an export step that discards the schema you were paying for.
- You cannot version-control a Pick item without picking an encoding for `0xFB`–`0xFF`.
- You cannot pipe an IBM i object anywhere at all.
- You cannot write a third-party tool for any of them without the vendor's control-block layouts — which is the same fact that made the format immune to [parser differentials][differentials], viewed from the other side.

The concession is documented on both sides. z/OS files the byte stream as an _exception_ to the dataset — and then ships one. IBM i grew the **Integrated File System**, a POSIX byte-stream namespace with directories, stream files and symbolic links; then mounted the object store _inside it_, so that the library `QSYS` is reachable as the path `/QSYS.LIB`, and a tape device is `/QSYS.LIB/media-device-name.DEVD` ([IFS backup report][ifs-pdf]). The schema-enforcing system grew a byte-stream namespace and gave it a path into the object store. The byte-stream systems never grew an object store. **The direction of the concession is the evidence.**

### (e) They were unshippable, and that is the whole answer

Combine (b), (d), and the closure discussion, and the result is not a story about cost or fashion. Every property that made these systems strong was a property of _the store_, not of _an artifact_: pointer tags are a property of the address space; `LVLCHK` is a property of the catalog; TIMI regeneration is a property of the machine you are regenerating on; `VOC` is a property of the account. None of them survives being copied to a machine that does not implement the architecture. A single-level store cannot produce a single-level artifact.

This is where the catalog's [fifth thesis][concepts] pays out. Portability has migrated from the format to the access layer — and these systems have neither. They achieved reach by owning the substrate outright, which is the strategy that scales to exactly one vendor.

The corollary is the honest conclusion about the current wave, and it is not flattering to the naive reading of [SELF][self]:

> **The modern wave is viable only because it puts the database _inside_ the Unix file rather than replacing it.**

Every part of SELF's design is a concession to the byte-stream file it lives in, and each concession buys something IBM i cannot have:

| SELF property                                               | Concession to the byte stream       | What it buys                                                             |
| ----------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------ |
| SQLite header at offset 0, `application_id` at byte 68      | Header-anchored, in a real file     | [`binfmt_misc` can dispatch on it][binfmt]; `file(1)` identifies it      |
| Segments stored as rows, copied out of b-tree pages at load | No control over page alignment      | The file is `scp`-able, `git`-able, servable over HTTP                   |
| Runs on any SQLite [VFS][vfs]                               | Access goes through a file-like API | OPFS, HTTP range requests, S3 — [portability at the access layer][range] |
| Loses cross-process page sharing                            | Cannot own the address space        | Runs on a kernel that owes it nothing                                    |

That last row is the trade stated exactly. IBM i has page sharing _because_ it owns the address space; SELF loses page sharing _because_ it does not — and gets to exist on a machine it does not own in exchange. [The sharpest open question in the catalog][open] — can SELF recover `mmap` semantics — is therefore a question about how much of the single-level store can be smuggled back in under a Unix file without giving up the file. On the evidence of this page, the answer is: some of it, through the VFS, and never all of it, because the last increment requires the thing IBM had and nobody else can get.

---

## Strengths

- **Self-description survived three architecture transitions with a paying installed base.** 1988 (System/38 → `OS/400` V1R1), 1995 (48-bit CISC → 64-bit RISC), and 6.1. No other subject in this catalog has evidence of this kind, because no other subject is old enough to have any.
- **The security model is a type system, not a policy.** Tagged pointers, domain/state, hardware storage protection, and parameter validation give guarantees that `W^X`, `seccomp`, and code signing approximate from outside the machine. Forging a pointer is not forbidden; it is inexpressible.
- **Perfect deduplication with no dedup machinery.** _"Global: accessible to any job that has a pointer to it"_ is stronger than `mmap` sharing and requires no alignment, no page cache agreement, and no shared path.
- **The relational surface is not a projection.** `QSYS2.OBJECT_STATISTICS` reads the catalog the system already maintains; osquery's `processes` table must reconstruct one, and [its own docs concede the result is lossy][relational].
- **The schema is enforced across the compile/run boundary.** `LVLCHK` catches the exact class of silent corruption that stale [debug indexes][debug] and mismatched [shared-library layouts][ld] produce elsewhere.
- **Pick's in-band delimiters are the family's one portable decision**, and they landed in the byte range [RFC 3629][rfc3629] permanently reserves — the only member whose data survives leaving the platform.
- **Migration is a query.** `ANZOBJCVN` writes its analysis into Db2 files and IBM documents the `SELECT`s. "Which binaries cannot be re-translated" is a `JOIN`, in 2008.

## Weaknesses

- **There is no artifact.** No file to copy, sign, mirror, range-request, or content-address. The entire strategy of [footer-indexed remote access][footer] and [content-addressed chunking][cas] is unavailable in principle.
- **Multiplicity 0 is a closed door in both directions.** Immunity to [parser differentials][differentials] is bought by making third-party tooling impossible.
- **Out-of-band schema does not travel.** Extract a `KSDS`, a `*FILE`, or a VMS indexed file onto a foreign system and you have bytes without meaning — the exact failure mode [self-description][concepts] is supposed to prevent, reintroduced at the platform boundary.
- **Self-description was optional, and the option was exercised.** `RMVOBS` made the surviving-forever property opt-out, and programs that opted out died at 6.1 — which also means the guarantee was never a guarantee.
- **The whole store is one failure domain and one authority domain.** Independent ASPs partition it somewhat; nothing partitions it the way a file does.
- **Vendor singularity.** IBM i is the only surviving implementation of its architecture; Multics is dead; Pick survives as a handful of forks of one GPL release; RMS and VSAM are alive only inside their own operating systems.
- **The lazy path is the slow path.** IBM's own guidance is that first-call conversion is the worst method — an install-time materialization presented as a runtime fallback, with the pathologies that implies under concurrency.
- **No published size accounting for self-description.** IBM quantifies conversion _time_ (0.36 s/object) but not creation-data _bytes_; the cost that drove `RMVOBS` adoption is undocumented.

## Key design decisions and trade-offs

| Decision                                                                                                         | Rationale                                                                                                                                | Trade-off                                                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **One address space spanning memory and disk** ([`ILE Concepts` Table 2][ile-pdf])                               | Removes copying and explicit I/O; sharing is a consequence of naming, not of `mmap`; _"information copying is no longer mandatory"_      | _"Supports memory mapping? No"_ — there is nothing to map, so nothing can be exported as a mappable file either                                         |
| **Programs stored as a machine-independent template, translated on the target** ([`REDP-4293` §2.2][redp4293])   | The instruction set becomes a private implementation detail; three transitions without recompilation                                     | Install-time translation cost (~0.36 s/object measured); IBM must own compiler, OS, LIC and CPU together                                                |
| **Creation data retained per object, but removable** (`CHGPGM RMVOBS`, [`Retrieve Module Information`][pgm-pdf]) | Bytes cost money and not everyone wants to ship their program's higher-level form                                                        | Objects in state `*NO` cannot be converted; the survivability guarantee is voided exactly for the programs whose vendors are gone                       |
| **Pointers are 16 bytes and hardware-tagged** ([`ILE Concepts` Table 5][ile-pdf])                                | Capability addressing: a pointer cannot be manufactured, so `*SYSTEM`-domain access is unreachable rather than merely forbidden          | 2× pointer size, mandatory 16-byte alignment, and — per IBM's own table — slower loads and stores than the untagged 8-byte teraspace pointer            |
| **The database is the object model, not a layer on a filesystem** ([Database programming][dbp-pdf])              | One namespace, one authority model, one journal, one save/restore; physical files _are_ tables and logical files _are_ views and indexes | No filesystem to fall back to — which is why the IFS had to be added later and `QSYS.LIB` mounted inside it                                             |
| **Record-format level identifiers checked at open** (`LVLCHK`, [Database programming][dbp-pdf])                  | The compiled program's cached schema is a materialized view; staleness is detected at bind time, not at corruption time                  | Recompilation is required for benign schema changes; the escape hatch `OVRDBF … LVLCHK(*NO)` reintroduces exactly the hazard it prevents                |
| **Structure in band, in `0xFB`–`0xFF`** (Pick, [`gplsrc/qmdefs.h`][sdme-qmdefs])                                 | Items are self-delimiting strings; no out-of-band metadata is needed to read one                                                         | Five byte values are unusable as data; the encoding predates Unicode and is only accidentally compatible with it                                        |
| **Index carries the definition that produced it** (Pick AK subfiles, [`gplsrc/dh_fmt.h`][sdme-dhfmt])            | _"the entire dictionary record is stored here for all indices"_, plus a creation-timestamp cross-check on open                           | The index duplicates the dictionary; the two can be edited independently and only the timestamp catches it                                              |
| **File organization fixed at define time** (VSAM `KSDS`/`ESDS`/`RRDS`/`LDS`, RMS sequential/relative/indexed)    | The OS can index, lock, journal, and share at record granularity because it knows the shape                                              | Changing the shape means copying the data; _"You cannot process VSAM data sets with non-VSAM access methods"_                                           |
| **Integrity by regeneration rather than by signature** ([`REDP-4293` §2.3.1][redp4293])                          | _"any unsupported alterations … are eradicated"_; no race against a virus-signature database                                             | Digital signatures are _lost_ during conversion, because the bytes they covered no longer exist — the unsolved [signing problem][provenance] in reverse |

---

## Sources

- [`IBM i Program Conversion: Getting Ready for 6.1 and Beyond`, REDP-4293-01, March 2010][redp4293] — TIMI, program conversion, creation data/observability, the three-transition history, conversion-time reports, the `ANZOBJCVN` SQL queries ([abstract page][redp4293-abs])
- [`ILE Concepts`, SC41-5606-08, V6R1][ile-pdf] — Chapter 4 "Teraspace and Single-Level Storage": Table 2 (locality, size, memory mapping, sharing) and Table 5 (8-byte vs 16-byte pointers, tagging, addressable range)
- [`Security reference`, SC41-5302-10, V6R1][secref-pdf] — domain/state rules, enhanced hardware storage protection, parameter validation, level-50 address-space isolation, restore validation values
- [`Security Guide for IBM i V6.1`, SG24-7680][sg247680] — security levels 40 and 50 in narrative form, pointer scrubbing in `*EXT` messages, Common Criteria/CAPP lineage
- [`Database programming`, V6R1][dbp-pdf] — Db2 for i as part of the OS, `*FILE` as the object type, physical/logical files as tables/views/indexes, `LVLCHK` record-format level checking, `MAINT`
- [`Program and CL Command APIs`, V6R1][pgm-pdf] — creation-data states (`*NO`/`*YES`/`*UNOBS`), `RMVOBS`, per-component object sizes, `*SNGLVL`/`*TERASPACE`/`*INHERIT` storage models
- [`IBM i 7.1 Technical Overview with Technology Refresh Updates`, SG24-7858][sg247858] — IBM i Services: `QSYS2.OBJECT_STATISTICS` and the `QSYS2` view/table-function catalog
- [`Backing up the integrated file system`, iSeries Experience Report][ifs-pdf] — the IFS namespace, `/QSYS.LIB` as a path, IFS journaling added in `OS/400` V5R1M0
- [IBM i 7.5 documentation — "Teraspace and Single-Level Storage"][ibmi75-tera] (verified archive snapshot, 2022-12-02) — the current-release restatement of the storage-model choice
- [Bensoussan, Clingen & Daley, "The Multics Virtual Memory: Concepts and Design", `CACM` 15(5), May 1972][multics-vm] — segmentation, the two design goals, "information copying is no longer mandatory", the 645 `SDW` algorithm
- [Daley & Neumann, "A General-Purpose File System for Secondary Storage", FJCC 1965][multics-fs] — "A Multics file is a segment, and all segments are files"
- [Vyssotsky, Corbató & Graham, "Structure of the Multics Supervisor", FJCC 1965][multics-sup] · [Corbató & Vyssotsky, "Introduction and Overview of the Multics System", FJCC 1965][multics-intro]
- [Ritchie & Thompson, "The UNIX Time-Sharing System", `CACM` 17(7), July 1974][unix-cacm] (verified archive snapshot) — §3.1 "the structure of files is controlled by the programs that use them, not by the system"
- [geneb/ScarletDME][sdme-repo] — the readable Pick-lineage implementation: [`gplsrc/qmdefs.h`][sdme-qmdefs] (mark characters), [`gplsrc/dh_fmt.h`][sdme-dhfmt] (dynamic file format, `DH_RECORD`, AK header with embedded dictionary record), [`gplsrc/dh_open.c`][sdme-dhopen] (AK cross-check), [`gplsrc/op_dio1.c`][sdme-dio1] (`DICT` resolution via `VOC`), [`qmsys/NEWVOC/VOC`][sdme-voc] and [`qmsys/NEWVOC/LIST`][sdme-list] (the vocabulary containing its own entry)
- [VSI OpenVMS Record Management Services Reference Manual][rms-ref] — file organizations and record formats, `FAB`/`RAB`/`XAB`, `XABKEY`, `RFA`, "Dual Purpose of Control Blocks"
- [`z/OS DFSMS Using Data Sets`, SC26-7410-09, September 2009][dfsms] — datasets, `RECFM`/`DSORG`, the five VSAM types, and the byte-oriented-UNIX-file exception
- [RFC 3629, "UTF-8, a transformation format of ISO 10646"][rfc3629] — "The octet values C0, C1, F5 to FF never appear"
- [SQLite: "Most Widely Deployed and Used Database Engine"][sqlite-mostdeployed] · [Long Term Support][sqlite-lts] · [SQLite As An Application File Format][sqlite-appfmt] · [Database File Format][sqlite-format]
- [Farid Zakaria, "Your executable is a SQLite database", 2026-08-23][fz-self] · ["Actually Queryable Executables", 2026-08-24][fz-queryable] — the LLM and Nix statements, and the 611.9 MiB / 644.4 MiB / 5.53 GiB closure numbers
- Related in this tree: [concepts][concepts] · [SELF / selfdb][self] · [`sqlelf`][sqlelf] · [relational system surfaces][relational] · [code as a database][codeasdb] · [image-based systems][image] · [SQLite as an application file format][sqlite-appfmt-page] · [the SQLite VFS as substrate][vfs] · [range-request access][range] · [footer-indexed formats][footer] · [Nix store closures][nix] · [content-addressed chunking][cas] · [dynamic linking][ld] · [`binfmt_misc`][binfmt] · [parser differentials][differentials] · [ZIP parasitism][zip] · [Cosmopolitan / APE][ape] · [Plan 9 namespaces][plan9] · [binary inspection libraries][binlib] · [debug info and indexes][debug] · [embedded provenance][provenance] · [threat model][threat] · [measurement][measurement] · [comparison][comparison] · [open questions][open]

<!-- References -->

[redp4293]: https://www.redbooks.ibm.com/redpapers/pdfs/redp4293.pdf
[redp4293-abs]: https://www.redbooks.ibm.com/abstracts/redp4293.html
[sg247680]: https://www.redbooks.ibm.com/redbooks/pdfs/sg247680.pdf
[sg247858]: https://www.redbooks.ibm.com/redbooks/pdfs/sg247858.pdf
[ile-pdf]: https://public.dhe.ibm.com/systems/power/docs/systemi/v6r1/en_US/sc415606.pdf
[secref-pdf]: https://public.dhe.ibm.com/systems/power/docs/systemi/v6r1/en_US/sc415302.pdf
[dbp-pdf]: https://public.dhe.ibm.com/systems/power/docs/systemi/v6r1/en_US/rbafo.pdf
[pgm-pdf]: https://public.dhe.ibm.com/systems/power/docs/systemi/v6r1/en_US/pgm.pdf
[ifs-pdf]: https://public.dhe.ibm.com/systems/power/docs/systemi/v6r1/en_US/ifsystem.pdf
[ibmi75-tera]: https://web.archive.org/web/20221202090625/https://www.ibm.com/docs/en/i/7.5?topic=concepts-teraspace-single-level-storage
[multicians]: https://multicians.org/multics.html
[multics-vm]: https://multicians.org/multics-vm.html
[multics-fs]: https://multicians.org/fjcc4.html
[multics-sup]: https://multicians.org/fjcc3.html
[multics-intro]: https://multicians.org/fjcc1.html
[unix-cacm]: https://web.archive.org/web/20201229210131/https://www.bell-labs.com/usr/dmr/www/cacm.html
[rms-ref]: https://docs.vmssoftware.com/vsi-openvms-record-management-services-reference-manual/
[dfsms]: https://publibz.boulder.ibm.com/epubs/pdf/dgt2d480.pdf
[rfc3629]: https://www.rfc-editor.org/rfc/rfc3629
[sqlite-mostdeployed]: https://sqlite.org/mostdeployed.html
[sqlite-lts]: https://sqlite.org/lts.html
[sqlite-appfmt]: https://sqlite.org/appfileformat.html
[sqlite-format]: https://sqlite.org/fileformat2.html
[fz-self]: https://fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database
[fz-queryable]: https://fzakaria.com/2026/08/24/actually-queryable-executables
[sdme-repo]: https://github.com/geneb/ScarletDME
[sdme-qmdefs]: https://github.com/geneb/ScarletDME/blob/1671cdf689d7257ea6a49e3abea3d5d69f0aec68/gplsrc/qmdefs.h
[sdme-dhfmt]: https://github.com/geneb/ScarletDME/blob/1671cdf689d7257ea6a49e3abea3d5d69f0aec68/gplsrc/dh_fmt.h
[sdme-dhopen]: https://github.com/geneb/ScarletDME/blob/1671cdf689d7257ea6a49e3abea3d5d69f0aec68/gplsrc/dh_open.c
[sdme-dio1]: https://github.com/geneb/ScarletDME/blob/1671cdf689d7257ea6a49e3abea3d5d69f0aec68/gplsrc/op_dio1.c
[sdme-voc]: https://github.com/geneb/ScarletDME/blob/1671cdf689d7257ea6a49e3abea3d5d69f0aec68/qmsys/NEWVOC/VOC
[sdme-list]: https://github.com/geneb/ScarletDME/blob/1671cdf689d7257ea6a49e3abea3d5d69f0aec68/qmsys/NEWVOC/LIST
[concepts]: ./concepts.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[relational]: ./relational-system-surfaces.md
[codeasdb]: ./code-as-database.md
[image]: ./image-based-systems.md
[sqlite-appfmt-page]: ./sqlite-application-file-format.md
[vfs]: ./sqlite-vfs-substrate.md
[range]: ./range-request-access.md
[footer]: ./footer-indexed-formats.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[ld]: ./dynamic-linking.md
[binfmt]: ./binfmt-misc.md
[differentials]: ./parser-differentials.md
[zip]: ./zip-parasitism.md
[ape]: ./cosmopolitan-ape/index.md
[plan9]: ./plan9-namespaces.md
[binlib]: ./binary-inspection-libraries.md
[debug]: ./debug-info-and-indexes.md
[provenance]: ./embedded-provenance.md
[threat]: ./threat-model.md
[measurement]: ./measurement.md
[comparison]: ./comparison.md
[open]: ./open-questions.md
[packaging]: ../application-packaging/index.md
