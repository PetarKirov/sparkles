# Debug info and out-of-band indexes (DWARF, `.gdb_index`, split DWARF, `debuginfod`)

DWARF is the best-developed case in the wild of an index that outgrew its artifact: a hand-rolled database bolted onto ELF, with no query surface, that acquired three generations of acceleration index, then left the executable entirely for a `.dwo` file, then for a `.dwp` package, and finally for an HTTP endpoint keyed by the build-id.

| Field           | Value                                                                                                                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Debugging-information format (DWARF) + its acceleration indexes + an out-of-band delivery protocol (`debuginfod`)                                                                      |
| Language        | Specification (DWARF); consumers in C/C++ (GDB, `libdw`, LLVM), producers in GCC/Clang/linkers                                                                                         |
| License         | DWARF 5 spec: freely copyable per its own notice; GDB/`gold`: GPL-3.0-or-later; elfutils `debuginfod`: GPL-3.0-or-later (client `libdebuginfod`: LGPL/GPL dual)                        |
| Repository      | [gnutools/binutils-gdb][repo] (GDB + `gold`, mirror of `sourceware.org/git/binutils-gdb.git`) · [elfutils][elfutils] (release tarballs)                                                |
| Documentation   | [DWARF 5 standard][dwarf5] · [GDB manual, "Index Files" and appendix "`.gdb_index` section format"][gdbdoc] · [elfutils `debuginfod`][debuginfod-doc]                                  |
| First release   | DWARF 2 (UNIX International PLSIG): 1993-07-27, incl. `.debug_pubnames`; `.gdb_index`: GDB 7.3 (2011); DWARF 5 / `.debug_names`: 2017-02-13; `debuginfod`: elfutils 0.178 (2019-11-26) |
| Axis profile    | Multiplicity 1 / Reflexivity 2 / Closure 1 / Mutability 1                                                                                                                              |
| Index anchoring | **Stream-scanned** (the DIE tree is walked from each unit header), with bolted-on header-anchored indexes and, finally, **out-of-band** (`debuginfod`)                                 |
| Dispatch owner  | Consumer (the debugger decides which sections to read, in what order, and which index to trust)                                                                                        |

> **Revisions surveyed:** DWARF 5 (2017-02-13, `dwarfstd.org`); binutils-gdb at commit `09a7362522ef0447210042a4f0309559edae82bb` (2026-08-19); elfutils 0.195 source tarball (`sha256:37629fdf7f1f3dc2818e138fca2b8094177d6c2d0f701d3bb650a561218dc026`). **Platform for all measurements:** NixOS, x86-64, GCC 15.3.0, binutils 2.46 (`readelf`, `dwp`), GDB 16.3, Clang/LLD 20.1.8 / 21.1.7, elfutils 0.195.

---

## Overview

### What it solves

A compiled binary has thrown away everything a human cares about. DWARF's job is to put it back: types, scopes, variable locations as a function of PC, the line table, inlining, and call sites — enough for a debugger to answer "what is `p` right now" and "which source line is this address". It does this in a set of parallel ELF sections (`.debug_info`, `.debug_abbrev`, `.debug_line`, `.debug_str`, `.debug_loclists`, `.debug_rnglists`, …) joined to each other by byte offsets.

The information is enormous — routinely larger than the program it describes. For `libpython3.12.so.1.0` on this machine, the stripped shared object is **8,571,368 bytes** and its separate debug file is **12,960,480 bytes**, of which **11,632,453** are `.debug_*`:

| Section           |      Bytes | Share of debug |
| ----------------- | ---------: | -------------: |
| `.debug_info`     |  7,593,844 |         65.3 % |
| `.debug_loclists` |  2,291,112 |         19.7 % |
| `.debug_line`     |  1,155,678 |          9.9 % |
| `.debug_rnglists` |    432,674 |          3.7 % |
| `.debug_str`      |    126,134 |          1.1 % |
| `.debug_abbrev`   |     30,262 |          0.3 % |
| `.debug_line_str` |      2,658 |          0.0 % |
| `.debug_aranges`  |         91 |          0.0 % |
| **total**         | 11,632,453 |                |

That `.debug_info` holds **1,219,833** debugging information entries (DIEs) across **156** compilation units — an average of 6.2 bytes per DIE. Nothing in the format indexes them. The catalog's structural question _[where does the index live?][concepts]_ has, for DWARF proper, the least convenient answer available: **nowhere**. A consumer that wants to know where the function `PyObject_Str` is defined walks the tree.

Everything else on this page is a consequence of that sentence.

### Design philosophy

DWARF's designers were explicit that they were compressing a table, and they said so in the language of tables. On the line-number program, the standard writes ([DWARF 5][dwarf5] §6.2, p. 149):

> _"If space were not a consideration, the information provided in the `.debug_line` section could be represented as a large matrix, with one row for each instruction in the emitted object code. The matrix would have columns for: the source file name; the source line number; the source column number; whether this instruction is the beginning of a source statement; whether this instruction is the beginning of a basic block; and so on. Such a matrix, however, would be impractically large. We shrink it with two techniques. First, we delete from the matrix each row whose file, line, source column and discriminator is identical with that of its predecessors. … Second, we design a byte-coded language for a state machine and store a stream of bytes in the object file instead of the matrix. … To the line number information a consumer must "run" the state machine to generate the matrix for each compilation unit of interest."_

A matrix with named columns, run-length-deduplicated on a sort key, delta-encoded into a byte program, and reconstructed by the reader. That is a column store with a hand-written codec, described as such, in 1993, and unchanged in shape since.

The second commitment is genuine self-description, and it is the thing DWARF gets right that ELF proper does not. Every DIE begins with an abbreviation code; the code indexes `.debug_abbrev`, which declares the tag and the ordered list of (attribute, form) pairs that follow ([DWARF 5][dwarf5] §7.5.3, p. 202):

> _"The abbreviation table for a single compilation unit consists of a series of abbreviation declarations. Each declaration specifies the tag and attributes for a particular form of debugging information entry. Each declaration begins with an unsigned LEB128 number representing the abbreviation code itself. It is this code that appears at the beginning of a debugging information entry in the `.debug_info` section."_

A DWARF reader that has never heard of `DW_TAG_call_site` can still skip it correctly, because the abbrev declaration tells it how many attributes follow and what form each takes. Nothing in ELF says what `.gnu.hash` means; `.debug_abbrev` says what every byte of `.debug_info` means. This is [thesis 2][concepts] — self-description is what makes a format survivable — holding, in a format that otherwise fails [thesis 1][concepts] comprehensively.

## How it works

### Units, DIEs, and the tree

`.debug_info` is a concatenation of units, each with a header giving `unit_length`, `version`, `unit_type`, the `.debug_abbrev` offset, and the address size. After the header comes a tree of DIEs, depth-encoded by a "has children" flag in the abbrev declaration and terminated by a zero abbreviation code. The standard's definition ([DWARF 5][dwarf5] §2.1, p. 15):

> _"DWARF uses a series of debugging information entries (DIEs) to define a low-level representation of a source program. Each debugging information entry consists of an identifying tag and a series of attributes."_

A four-line C program compiled with `gcc -g -O0` (DWARF 5) produces this — note that the row payload carries no field names, only values in the order the schema fixed:

```text
$ readelf --debug-dump=info a
  Compilation Unit @ offset 0:
   Length: 0x10e  Version: 5  Unit Type: DW_UT_compile (1)  Abbrev Offset: 0
 <0><c>: Abbrev Number: 3 (DW_TAG_compile_unit)
    <d>   DW_AT_producer    : (indirect string, offset: 0x55): GNU C23 15.3.0 …
    <17>  DW_AT_name        : (indirect line string, offset: 0x8): a.c
    <1f>  DW_AT_low_pc      : 0x1139
    <27>  DW_AT_high_pc     : 0x57
 <1><7d>: Abbrev Number: 7 (DW_TAG_structure_type)
    <7e>   DW_AT_name       : (indirect string, offset: 0x35): point
    <86>   DW_AT_sibling    : <0x9d>
 <2><8a>: Abbrev Number: 2 (DW_TAG_member)
    <8b>   DW_AT_name       : x
    <8e>   DW_AT_type       : <0x5d>
    <92>   DW_AT_data_member_location: 0
```

and the schema that decodes it:

```text
$ readelf --debug-dump=abbrev a
   2      DW_TAG_member    [no children]
    DW_AT_name         DW_FORM_string
    DW_AT_decl_file    DW_FORM_implicit_const: 1
    DW_AT_decl_line    DW_FORM_implicit_const: 2
    DW_AT_decl_column  DW_FORM_data1
    DW_AT_type         DW_FORM_ref4
    DW_AT_data_member_location DW_FORM_data1
```

Read as a database, this excerpt contains five distinct database techniques and one missing one:

| DWARF construct                       | Database equivalent                                                    |
| ------------------------------------- | ---------------------------------------------------------------------- |
| Abbreviation code → declaration       | Row-type interning; the schema, stored once per unit                   |
| `DW_FORM_ref4` (`DW_AT_type: <0x5d>`) | Foreign key, as a byte offset inside the current unit                  |
| `DW_FORM_strp` / `DW_FORM_line_strp`  | String interning into `.debug_str` / `.debug_line_str`                 |
| `DW_FORM_strx` + `.debug_str_offsets` | Dictionary encoding — an integer code into an offsets table            |
| `DW_FORM_addrx` + `.debug_addr`       | Dictionary encoding of addresses, so the DIEs need no relocations      |
| `DW_FORM_implicit_const`              | A constant folded into the schema; the row stores nothing              |
| `DW_AT_sibling: <0x9d>`               | A hand-maintained skip pointer — the only "index" inside `.debug_info` |
| _(absent)_                            | Any name-, type-, or address-keyed index over the rows                 |

`DW_AT_sibling` is the tell. It exists because walking past a subtree you do not care about otherwise costs decoding every DIE in it; so the producer optionally writes down where the subtree ends. That is a B-tree's right-sibling pointer, implemented as an optional attribute a producer may or may not emit, with no consumer guarantee.

### The line-number state machine

The `.debug_line` program for the same four-line file is 117 bytes and expands to 13 rows:

```text
$ readelf --debug-dump=rawline a
  Opcode Base: 13   Line Base: -5   Line Range: 14
  [0x00000041]  Extended opcode 2: set Address to 0x1139
  [0x0000004c]  Special opcode 7: advance Address by 0 to 0x1139 and Line by 2 to 3
  [0x0000004f]  Special opcode 117: advance Address by 8 to 0x1141 and Line by 0 to 3
  [0x00000062]  Extended opcode 4: set Discriminator to 1
  [0x00000076]  Extended opcode 1: End of Sequence
```

One byte per row in the common case, because a "special opcode" packs an address delta and a line delta into a single byte against the `line_base`/`line_range` parameters declared in the header. The consumer's obligation is to _execute_ it: there is no way to seek to "the row for address X" without running the program from the start of that unit's sequence. `.debug_line` is the catalog's purest stream-scanned index — random access costs a full scan of the unit, which is exactly the property [`footer-indexed-formats.md`][footer] contrasts with a footer TOC.

### "Which function is at this address" requires walking a tree

The standard is candid that this is the weak spot ([DWARF 5][dwarf5] §6.1, p. 136):

> _"To find the debugging information associated with a subroutine, given an address, a debugger can use the low and high PC attributes of the compilation unit entries to quickly narrow down the search, but these attributes only cover the range of addresses for the text associated with a compilation unit entry. To find the debugging information associated with a data object, given an address, an exhaustive search would be needed. Furthermore, any search through debugging information entries for different compilation units within a large program would potentially require the access of many memory pages, probably hurting debugger performance."_

The address query decomposes into two steps and only the first is ever indexed:

1. **address → compilation unit.** `.debug_aranges` answers this, when it exists; it was 91 bytes for the whole of `libpython3.12.so` above, and many toolchains no longer emit it by default.
2. **compilation unit → DIE.** Not indexed at all. The consumer decodes the unit's abbrev table, walks the DIE tree, compares `DW_AT_low_pc`/`DW_AT_high_pc` or resolves `DW_AT_ranges` into `.debug_rnglists`, and descends into `DW_TAG_inlined_subroutine` children to get the innermost frame. There were 83,215 `DW_TAG_inlined_subroutine` DIEs in that one library.

Every accelerator described below attacks step 1 and none of them attacks step 2. That asymmetry survives every generation of index and is measured at the end of [Index anchoring and random access](#index-anchoring-and-random-access).

## Format identity and multiplicity

**Multiplicity: 1/3 — incidental.** DWARF is not a byte stream with several parses; it is a set of sections inside a host object format, and it has no identity of its own. `\x7fELF` is at offset 0 and the section table is header-anchored, so the tolerance vocabulary from [concepts][concepts] applies to the _host_, not to DWARF: an ELF file is suffix-tolerant (it declares its own extent) and prefix-intolerant, and DWARF inherits both.

What is interesting is the direction the container tax runs. When the debug information leaves the executable, it does not stop being ELF; it becomes ELF used as nothing but a bag of tables:

| Artifact     | ELF type | Program headers | Sections | What it is                                              |
| ------------ | -------- | --------------: | -------: | ------------------------------------------------------- |
| `prog`       | `ET_DYN` |              12 |      ~30 | The program                                             |
| `prog.debug` | `ET_DYN` |              12 |      ~30 | Same headers, `.text`/`.data`/`.rodata` turned `NOBITS` |
| `prog.dwo`   | `ET_REL` |           **0** |    **9** | A section bag: `.debug_*.dwo` only                      |
| `prog.dwp`   | `ET_REL` |           **0** |    **9** | A section bag plus `.debug_cu_index`/`.debug_tu_index`  |

A `.dwo` is an object file that can never be linked and never be run: zero program headers, nine sections, no symbol table worth the name. A separate `.debug` file is stranger still — it keeps every program header and section header of the original and marks the code and data `NOBITS`, so that tools which expect an ELF layout still work on a file whose entire content is metadata. This is [thesis 3][concepts] — the container is a tax — in its clearest observed form anywhere in this catalog: four different files, all paying the full ELF header/section-table overhead, none of them a program, all of them existing solely to carry tables that ELF does not understand. `sqlite3` in the same role would have carried a schema; ELF carries a section name and a convention.

> [!NOTE]
> A separate-debug file is found by convention, not by structure: either the `.gnu_debuglink` section (a filename plus a CRC-32) or the build-id path `…/lib/debug/.build-id/b0/a8b5dd….debug`. The latter is content addressing by another name and is the hinge this page shares with [`embedded-provenance.md`][prov].

## Index anchoring and random access

DWARF's index history is four generations of the same admission — that the tree is not queryable — each one anchoring the answer somewhere further from the data.

| Generation | Index                                 | Lives                         | Anchoring                     | Fatal flaw                                                      |
| ---------- | ------------------------------------- | ----------------------------- | ----------------------------- | --------------------------------------------------------------- |
| 0          | none (walk `.debug_info`)             | —                             | stream-scanned                | O(all DIEs) per question                                        |
| 1 (1993+)  | `.debug_pubnames` / `.debug_pubtypes` | in the artifact               | header-anchored               | per-CU sets, globals only, no kind, no static, no address       |
| 1′ (2012)  | `.debug_gnu_pubnames` (GNU extension) | in the artifact               | header-anchored               | not the standard; announced by `DW_AT_GNU_pubnames`             |
| 2 (2011)   | `.gdb_index`                          | in the artifact, or beside it | header-anchored / out-of-band | GDB-private, versioned 1–9, two producers disagreed             |
| 3 (2017)   | `.debug_names`                        | in the artifact               | header-anchored               | standardized, but consumers reject foreign augmentation strings |
| 4 (2019)   | `debuginfod`                          | on another machine            | **out-of-band**               | staleness and trust move onto the network                       |

### Generation 1: why `.debug_pubnames` failed

DWARF 2 through 4 specified two name tables ([DWARF 4][dwarf4] §6.1.1, p. 106):

> _"For lookup by name, two tables are maintained in separate object file sections named `.debug_pubnames` for objects and functions, and `.debug_pubtypes` for types. Each table consists of sets of variable length entries. Each set describes the names of global objects and functions, or global types, respectively, whose definitions are represented by debugging information entries owned by a single compilation unit."_

Four properties in that paragraph, together, made the table nearly useless to a debugger:

- **Per-CU sets.** The section is a concatenation of one set per compilation unit, each with its own header. There is no global ordering and no hash; finding a name means reading every set — a scan, cheaper than scanning `.debug_info` but the same complexity class.
- **Globals only.** A `static` function is not in it. A debugger must be able to break on a `static` function, so it had to scan anyway.
- **No kind.** An entry is an offset and a name. Whether the name is a type, a variable, or a function is not recorded, so the consumer resolves the DIE to find out — a random access into the very tree it was trying to avoid.
- **No addresses.** The address query is not served at all.

GNU's response was not to fix the standard table but to define a private one with the same section semantics and an extra byte. `gold`'s `--gdb-index` reader treats each entry as a name plus a `flag_byte` and passes both to the index builder ([`gold/gdb-index.cc`][goldidx], `read_pubtable`), and the CU announces the dialect with an extension attribute:

```c++
// gold/gdb-index.cc — read_pubnames_and_pubtypes (abridged)
off_t offset = die->ref_attribute(elfcpp::DW_AT_GNU_pubnames, &shndx);
// Newer versions of GCC generate CUs, but not TUs, with DW_AT_FORM_flag_present.
unsigned int flag = die->uint_attribute(elfcpp::DW_AT_GNU_pubnames);
if (offset == -1 && flag == 0)
  …  // no attribute: the caller must parse the DIEs manually to find the names
```

GCC's manual is blunt about what the flag means ([GCC 15 Debugging Options][gccdbg]):

> _"`-ggnu-pubnames`: Generate `.debug_pubnames` and `.debug_pubtypes` sections in a format suitable for conversion into a GDB index. This option is only useful with a linker that can produce GDB index version 7."_

A section named by the standard, carrying a payload the standard does not define, whose usefulness is conditioned on a specific consumer's index version. Observed on this machine (GCC 15.3.0, `-gsplit-dwarf`), the GNU flavour indeed carries the missing kind and linkage columns:

```text
$ readelf --debug-dump=pubnames asplit
Contents of the .debug_gnu_pubnames section (loaded from asplit):
  Offset into .debug_info section:     0
  Size of area in .debug_info section: 206
    Offset  Kind          Name
    85      g,function    main
    ab      s,function    helper
```

`g`/`s` is the global/static column DWARF 4 omitted, and `function` is the kind column it omitted. Note also what those offsets index: `0x85` and `0xab` are offsets into the _`.dwo` file's_ `.debug_info.dwo`, in a section that lives in the executable. The index and the data it names are already in different files, one generation before split DWARF made that official.

GDB, meanwhile, stopped reading pubnames altogether. At the surveyed commit, the string `pubnames` does not occur anywhere in `gdb/`'s core sources — only in the test suite, in the `gold` linker, and in one contributed cross-checking script whose docstring records what the community actually did with these tables ([`gdb/contrib/test_pubnames_and_indexes.py`][pubtest]):

> _"Test that the gdb_index produced by gold is identical to the gdb_index produced by gdb itself. Further check that the pubnames and pubtypes produced by gcc are identical to those that gdb produces."_

That is a differential test between three producers of the same index, which is the shape of a problem, not a solution — the same shape [`parser-differentials.md`][differentials] catalogues for parsers.

### Generation 2: `.gdb_index`, a debugger-private materialized view written into the file

`.gdb_index` is GDB's answer: build the index once, store it in the ELF file, `mmap` it thereafter. Its format is documented in an appendix of GDB's own manual — not in any DWARF document — and the first design constraint is the access pattern ([`gdb/doc/gdb.texinfo`][gdbtexi], appendix "`.gdb_index` section format"):

> _"The mapped index file format is designed to be directly `mmap`able on any architecture. In most cases, a datum is represented using a little-endian 32-bit integer value, called an `offset_type`. … The data is laid out such that alignment is always respected."_

The layout is a seven-field header of offsets followed by six regions, written in [`gdb/dwarf2/index-write.c`][idxwrite] (`write_gdbindex_1`): version (currently 9), CU list, types-CU list, address area, symbol table, shortcut table, constant pool. Three of the regions are worth reading as schema:

- **The CU list** is _"a sequence of pairs of 64-bit little-endian values, sorted by the CU offset"_ — `(offset, length)` — and _"references to a CU elsewhere in the map are done using a CU index, which is just the 0-based index into this table."_ A surrogate key, generated by position.
- **The address area** is `(low, high, cu_index)` triples: address → CU, the same step-1-only answer `.debug_aranges` gives.
- **The symbol table** is _"an open-addressed hash table"_ of `(name_offset, cu_vector_offset)` pairs with a documented hash (`r = r * 67 + tolower(c) - 113`) and a documented probe step (`((hash * 17) & (size - 1)) | 1`). The CU vector it points at holds one 32-bit word per _use_ of the name, packed: bits 0–23 the CU index, bits 28–30 the symbol kind, bit 31 static-vs-global.

So the two columns pubnames lacked — kind and linkage — arrived as bitfields inside a foreign key, in a format defined by a debugger, versioned nine times. And the manual's remark on C++ names is the most honest sentence in the whole area:

> _"The names of C++ symbols in the hash table are canonicalized. We don't currently have a simple description of the canonicalization algorithm; if you intend to create new index sections, you must read the code."_

Two programs did produce these sections — GDB itself and `gold --gdb-index` — and they disagreed. GDB's reader carries the scars in a comment ([`gdb/dwarf2/read-gdb-index.c`][readgdbidx]):

```c
/* Version 7 indices generated by gold refer to the CU for a symbol instead
   of the TU (for symbols coming from TUs),
   http://sourceware.org/bugzilla/show_bug.cgi?id=15021.
   Plus gold-generated indices can have duplicate entries for global symbols,
   http://sourceware.org/bugzilla/show_bug.cgi?id=15646.
   These are just performance bugs, and we can't distinguish gdb-generated
   indices from gold-generated ones, so issue no warning here.  */
```

An out-of-band index maintained by two programs, with no field recording which one wrote it, and a consumer that cannot tell them apart. This is the identical failure mode `/etc/ld.so.cache` has in [`dynamic-linking.md`][ld] — the sort order is a contract between two programs and violating it yields a different answer, not an error — and it is the generic hazard of a **materialized view** as [concepts][concepts] defines it.

### Generation 3: `.debug_names`, standardized and still not portable

DWARF 5's headline change list puts it first among the replacements ([DWARF 5][dwarf5] §1.4, p. 9):

> _"Replace the `.debug_pubnames` and `.debug_pubtypes` sections with a single and more functional name index section, `.debug_names`."_

The new section is a real index: a header, CU/TU lists, an optional bucket+hash array using the DJB hash with Unicode simple case folding (§6.1.1.4.5), a name table, an **abbreviations table of its own**, and an entry pool. The rules for what must be indexed are finally stated (§6.1.1.1: non-defining declarations excluded, `DW_TAG_variable` included only when its location uses `DW_OP_addr` or `DW_OP_form_tls_address`, linkage names given an additional entry), and the intent is spelled out:

> _"The intent of the above rules is to provide the consumer with some assurance that looking up an unqualified name in the index will yield all relevant debugging information entries that provide a defining declaration at global scope for that name."_

The index entries are themselves abbreviated exactly like DIEs — the schema-interning trick applied to the index (§6.1.1.4.7). Observed, from a Clang 20.1.8 + LLD 21.1.7 build with `-gpubnames -Wl,--debug-names`:

```text
$ llvm-dwarfdump --debug-names aclang
  Header { Version: 5, CU count: 1, Bucket count: 12, Name count: 12,
           Abbreviations table size: 0x29, Augmentation: 'LLVM0700' }
  Abbreviations [
    Abbreviation 0x1 { Tag: DW_TAG_subprogram
                       DW_IDX_die_offset: DW_FORM_ref4
                       DW_IDX_parent: DW_FORM_flag_present
                       DW_IDX_compile_unit: DW_FORM_data1 } ]
```

And then the punchline. GDB 16.3, handed that section, refuses it:

```text
$ gdb -q -nx -batch -ex "info address sqlite3_open" sq_names
warning: .debug_names not created by gdb; ignoring
```

This is not a bug; it is the documented design. GDB's manual has a whole section, "Extensions to `.debug_names`", explaining that _"in order to work with GDB, some extensions were necessary"_ — `DW_IDX_GNU_internal` (0x2000), `DW_IDX_GNU_main` (0x2002), `DW_IDX_GNU_language` (0x2003), `DW_IDX_GNU_linkage_name` (0x2004) — and that the augmentation string must be `GDB2` or `GDB3`. The reader implements exactly that ([`gdb/dwarf2/read-debug-names.c`][readnames]):

```c
if (augmentation_string == gdb::make_array_view (dwarf5_augmentation_2))
  { map.augmentation_is_gdb = true; map.gdb_augmentation_version = 2; }
else if (augmentation_string == gdb::make_array_view (dwarf5_augmentation_3))
  { map.augmentation_is_gdb = true; map.gdb_augmentation_version = 3; }

if (!map.augmentation_is_gdb)
  {
    warning (_(".debug_names not created by gdb; ignoring"));
    return false;
  }
```

GDB also declines the standard's hash table outright: _"GDB does not use the specified hash table. Therefore, because this hash table is optional, GDB also does not write it."_ Twenty-four years after `.debug_pubnames`, the standardized index exists, is emitted by LLVM, costs real bytes, and is discarded by the reference debugger because the standard's columns were still not the columns a debugger needs. The bytes it costs, measured on the SQLite 3.50.4 amalgamation shell built with Clang:

| Quantity                                                            |     Bytes |
| ------------------------------------------------------------------- | --------: |
| binary with `.debug_names`                                          | 5,386,224 |
| binary without it (all other `.debug_*` sections identical in size) | 5,184,968 |
| `.debug_names`                                                      |   201,177 |
| `.debug_info`                                                       | 1,169,466 |
| all `.debug_*` except the index                                     | 3,579,336 |

The index costs **17.2 %** of `.debug_info`, **5.6 %** of the debug total, **3.7 %** of the shipped file — and, for GDB, buys nothing.

### The index that is not in the file at all

GDB's other answer is to keep the same bytes and move them out of the artifact. With `set index-cache enabled on`, the index is written to `$XDG_CACHE_HOME/gdb/`, named by the build-id ([`gdb/dwarf2/index-cache.c`][idxcache], `index_cache_store_context`):

```c
  /* Get build id of objfile.  */
  const bfd_build_id *build_id = build_id_bfd_get (per_bfd->obfd);
  if (build_id == nullptr)
    { index_cache_debug ("objfile %s has no build id", per_bfd->filename ()); … }
  m_build_id_str = build_id_to_string (build_id);
  …
  /* Write the index itself to the directory, using the build id as the filename.  */
  write_dwarf_index (per_bfd, m_dir, m_build_id_str.c_str (), …, dw_index_kind::GDB_INDEX);
```

Observed, on the Python debug file:

```text
$ gdb -q -nx -batch -iex "set index-cache enabled on" -ex "maint wait-for-index-cache" -ex quit py.debug
$ ls -l $XDG_CACHE_HOME/gdb/
-rw------- 1 petar users 785047 … b0a8b5ddad265ff9ed4d90bb794bc39f35e1486f.gdb-index
$ eu-readelf -n py.debug | grep 'Build ID'
    Build ID: b0a8b5ddad265ff9ed4d90bb794bc39f35e1486f
```

785,047 bytes — **the same 785,047 bytes** that `gdb-add-index` embeds as a `.gdb_index` section. One index, three possible anchorings: inside the artifact (a section), beside the artifact (a cache file keyed by the build-id), or nowhere (rebuilt on each run). The catalog's index-anchoring taxonomy is not a classification imposed on this subject from outside; it is a runtime setting.

### What the index actually buys — measured

The Python debug file (12,960,480 bytes, 156 CUs, 1.2 M DIEs), GDB 16.3, index cache disabled, best of three:

| Command                                     |           No index |     With `.gdb_index` |
| ------------------------------------------- | -----------------: | --------------------: |
| load and exit (`-ex quit`)                  | 0.15 s / 86 MB RSS |    0.07 s / 54 MB RSS |
| load and exit, `maint set worker-threads 0` | 0.18 s / 81 MB RSS |    0.07 s / 55 MB RSS |
| `info address PyObject_Str`                 |             1.21 s |                1.19 s |
| file size                                   |       12,960,480 B | 13,745,608 B (+6.1 %) |

Two findings, and the second is the important one.

1. **Getting to a prompt is 2.1–2.5× faster and uses ~33 % less memory** with the index. `set debug dwarf-read 1` confirms the mechanism — `[dwarf-read] dwarf2_initialize_objfile: found gdb index from file` — and the manual's claim is the same one: _"For large programs, this delay can be quite lengthy, so GDB provides a way to build an index, which speeds up startup."_
2. **Asking an actual question costs the same either way.** `info address PyObject_Str` is ~1.2 s indexed or not, because the index answers _which CU_ and then GDB expands that CU: decode its abbrev table, walk its DIEs, build symbols. Step 2 of the address/name query is still a tree walk. Thirty years of index work has not produced a way to read a _fact_ out of DWARF without reconstructing the neighbourhood it lives in.

Without any index, GDB's fallback is not a scan-on-demand but a full parallel pre-scan, the "cooked index", whose design comment states the strategy ([`gdb/dwarf2/cooked-index.h`][cooked]):

> _"The basic idea behind this design is (1) to do as much work as possible in worker threads, and (2) to start the work as early as possible. This combination should help hide the effort from the user to the maximum possible degree."_

The pipeline ends `maybe write to index cache` — i.e. the fallback path's final act is to materialize the view for next time. A modern GDB is a small database engine that reads a format with no index, builds one in parallel, and caches it under a content hash.

### The package-file index, and the one place DWARF states a load factor

`.debug_cu_index`, added for DWARF package files, is the only structure in DWARF that is unambiguously a hash-indexed table rather than a stream ([DWARF 5][dwarf5] §7.3.5.3, p. 191):

> _"Both index sections have the same format, and serve to map an 8-byte signature to a set of contributions to the debug sections. Each index section begins with a header, followed by a hash table of signatures, a parallel table of indexes, a table of offsets, and a table of sizes."_
>
> _"The size of the hash table, S, must be 2^k such that: 2^k > 3 \* U/2"_

Open addressing with double hashing (primary hash the low `k` bits of the signature, secondary `(((REP(X) >> 32) & MASK(k)) | 1)`, guaranteed to terminate because `S > U` and the step is coprime to `S`), a load factor capped at 2/3, a header row naming the columns, and `U` data rows of `N` four-byte offsets. That is a column-oriented row group with a hash index over it, specified in prose, in an appendix, for one file type. Observed on a two-unit package:

```text
$ readelf --debug-dump=cu_index ab.dwp
  Version: 2   Number of columns: 4   Number of used entries: 2   Number of slots: 16
  Offset table
  slot  dwo_id                 info   abbrev     line  str_off
  [  1] 0x1d9d7177153db6c1      204      223      118       56
  [  6] 0x225c42b9b43709f6        0        0        0        0
```

> [!WARNING]
> Observed, not diagnosed: with DWARF 5 `.dwo` files (`DW_UT_split_compile`, GCC 15.3.0 `-gdwarf-5 -gsplit-dwarf`), binutils 2.46 `dwp` exits 0 and writes a package containing **no `.debug_info.dwo` at all** and a 16-byte — i.e. empty — `.debug_cu_index`, which `readelf` then rejects with _"Section .debug_cu_index is too small to contain a CU/TU header"_. The same inputs at `-gdwarf-4` package correctly (a 288-byte index, shown above). A silently empty index that the producer reports as success is the worst failure mode an out-of-band index has, and it is reproducible here in three commands. I did not chase the cause and make no claim about where the defect is.

## Reflexivity and query surface

**Reflexivity: 2/3 — designed-in.** DWARF is, of everything in this catalog, the richest _model_ an artifact carries of itself: every type, every scope, every variable's location as a function of PC, every inlining decision, every call site. It is also the clearest demonstration that a rich model and a query surface are different things.

What exists:

| Surface                        | Who uses it                                   | Shape                                                                        |
| ------------------------------ | --------------------------------------------- | ---------------------------------------------------------------------------- |
| `libdw` / `libdwfl` (elfutils) | `perf`, `systemd-coredump`, `eu-stack`        | C iterators over CUs, DIEs, attributes                                       |
| LLVM `DWARFContext`            | `llvm-dwarfdump`, LLDB, sanitizer symbolizers | C++ object model, `--lookup=ADDR`                                            |
| `pyelftools`, `LIEF`, `goblin` | analysis scripts, security tooling            | language-native object models — see [`binary-inspection-libraries.md`][libs] |
| `.eh_frame` / `.debug_frame`   | the **running process** (unwinders)           | a second, redundant CFI table read at runtime                                |
| `debuginfod` client            | GDB, `perf`, `systemd-coredump`, `eu-stack`   | build-id → bytes over HTTP                                                   |

Every one of these is a hand-written walker. There is no DWARF query language, no `WHERE`, no join; "find every function larger than 4 KiB that was inlined into more than three call sites" is a program in each of the five ecosystems above and is answered by re-walking 1.2 M DIEs each time. This is the exact gap [`sqlelf.md`][sqlelf] closes for ELF's own tables and [`code-as-database.md`][codedb] closes for source, and DWARF is the strongest argument either page has: the data is already a typed, normalized, foreign-keyed graph, and the only reason it is not queryable is that no one wrote the surface.

The self-interrogation sub-question splits sharply:

- **A running process reads its own unwind tables constantly** — `.eh_frame` is consulted on every exception throw and every backtrace. That is genuine live self-inspection, and it is telling that this one query was so hot it got its own duplicate table in a loadable segment rather than being served from `.debug_frame` in the (non-loaded) debug sections. When a DWARF query has to be fast, the answer has historically been "emit a second copy of the data in a different section", not "index the first copy".
- **Almost nothing reads its own `.debug_info` at runtime.** Symbolizers do (sanitizers, `libbacktrace`, `backward-cpp`), but the common deployment strips the section out of the artifact entirely, which forecloses the question. A stripped binary cannot describe itself; it can only name a build-id and hope a server can.

That last sentence is the whole of generation 4, and it is why this page scores 2 and not 3.

## Closure, dedup, and size model

**Closure: 1/3 — incidental, and deliberately decreasing.** DWARF references source files it does not carry (`DW_AT_decl_file` into the line-table file table), and every mechanism invented since 2011 has removed _more_ from the artifact.

### Split DWARF: the moment the debug info formally left the artifact

`-gsplit-dwarf` writes the bulk of the debug information into a `.dwo` file and leaves behind a **skeleton unit** ([DWARF 5][dwarf5] §3.1.2, p. 66):

> _"When generating a split DWARF object file, the compilation unit in the `.debug_info` section is a "skeleton" compilation unit with the tag `DW_TAG_skeleton_unit`, which contains a `DW_AT_dwo_name` attribute as well as a subset of the attributes of a full or partial compilation unit. In general, it contains those attributes that are necessary for the consumer to locate the object file where the split full compilation unit can be found, and for the consumer to interpret references to addresses in the program. A skeleton compilation unit has no children."_

Observed — the entire `.debug_info` of a split executable:

```text
$ readelf --debug-dump=info asplit
  Compilation Unit @ offset 0:   Length: 0x31   Unit Type: DW_UT_skeleton (4)
   DWO ID: 0xf8eb456ebbd39025
 <0><14>: Abbrev Number: 1 (DW_TAG_skeleton_unit)
    DW_AT_low_pc      : 0x1139
    DW_AT_high_pc     : 0x57
    DW_AT_stmt_list   : 0
    DW_AT_dwo_name    : asplit-a.dwo
    DW_AT_comp_dir    : /tmp/dw
    DW_AT_GNU_pubnames: 1
    DW_AT_addr_base   : 0x8
```

Six attributes and a 64-bit `DWO ID`. The artifact now carries a _reference_ to its own description, keyed by a hash, exactly as a dynamically linked ELF carries `DT_NEEDED` strings rather than libraries ([`dynamic-linking.md`][ld]). The `DWO ID` is what the package-file index is keyed on; the standard notes it "should be suitable for detecting file version skew or other kinds of mismatched files".

Measured on the SQLite 3.50.4 amalgamation (`sqlite3.c`, 262,899 lines), GCC 15.3.0 `-g -O2`:

| Quantity                            |    Plain `-g` | `-gsplit-dwarf` |
| ----------------------------------- | ------------: | --------------: |
| object file                         |     6,590,384 |       3,738,136 |
| `.dwo` file                         |             — |       1,359,424 |
| `.debug_info` in the object         |       380,724 |          **49** |
| `.debug_line` in the object         |       425,214 |         425,214 |
| `.rela.debug_info` (relocations)    | **2,750,256** |         **144** |
| all `.rela.debug*`                  |     3,749,568 |       1,848,504 |
| total debug bytes (object + `.dwo`) |     1,405,957 |       1,812,946 |

The trade is unmistakable. The linker's input shrinks by 43 % and the relocations it must apply to debug sections shrink by 51 % — `.rela.debug_info` by a factor of **19,100** — because `DW_FORM_addrx` funnels every address through the small `.debug_addr` table instead of relocating the DIE tree in place. But the _total_ debug bytes went **up** by 29 %: split DWARF is not a compression technique, it is a relocation-avoidance and link-time technique, and it pays for that with duplicated per-unit tables and a second file to lose. Note also that `.debug_line` stayed behind in the object at full size — the line table is needed by the linker and by tools that never open the `.dwo`.

`dwp` then packages the `.dwo` files ([DWARF 5][dwarf5] §7.3.5, p. 190): _"Using split DWARF object files allows the developer to compile, link, and debug an application quickly with less link-time overhead, but a more convenient format is needed for saving the debug information for later debugging of a deployed application."_ The `.dwp` is a section-wise concatenation plus the two hash indexes analysed above — and the reason those indexes have to exist is that concatenation destroys the only addressing DWARF had. Inside a `.dwp`, "unit at offset X" is meaningless; every unit's contribution to every section must be recorded explicitly, per column, per row.

### Deduplication, three ways

DWARF has acquired three separate dedup mechanisms, each content-addressed, none of them shared:

| Mechanism                                         | Unit of dedup              | Key                                               | Where it lives                                   |
| ------------------------------------------------- | -------------------------- | ------------------------------------------------- | ------------------------------------------------ |
| Type units (`DW_UT_type`, DWARF 4 `.debug_types`) | one type's DIE subtree     | 64-bit type signature                             | COMDAT sections, merged by the linker            |
| `dwz` supplementary object files                  | any duplicated DIE subtree | the supplementary file + checksum in `.debug_sup` | a separate file referenced by `DW_FORM_ref_sup4` |
| `debuginfod`                                      | the whole debug file       | the build-id                                      | a server                                         |

The middle one is the most database-shaped ([DWARF 5][dwarf5] §7.3.6, p. 195):

> _"A supplementary object file permits a post-link utility to analyze executable and shared object files and collect duplicate debugging information into a single file that can be referenced by each of the original files."_

That is a normalization pass, run after the fact, by a third-party tool (`dwz`), producing a shared table with cross-file foreign keys and a checksum for referential integrity — which GDB must then understand as a special case ([`gdb/dwarf2/dwz.c`][dwz]), and which `.gdb_index` and `.debug_names` must each special-case again (the GDB manual: _"Definitions in partial units are handled differently. These most typically are seen in the output of `dwz`"_). Content addressing arrives in DWARF the same way it arrives everywhere else in this catalog — see [`content-addressed-chunking.md`][cas] and [`nix-store-closures.md`][nix] — but three times, incompatibly.

### `debuginfod`: closure delegated to the network

The endgame is to ship no debug information at all and resolve it later. elfutils' description ([elfutils `debuginfod`][debuginfod-doc]):

> _"elfutils debuginfod is a client/server in elfutils 0.178+ that automatically distributes elf/dwarf/source-code from servers to clients such as debuggers across HTTP."_

The webapi is `GET /buildid/HEXID/{debuginfo,executable,source/PATH,section/NAME}`. Run locally against elfutils 0.195 with a stripped program and its separate debug file:

```text
$ debuginfod -F /tmp/dw/dfd -d dbginfo.sqlite -p 8123 &
$ BID=0b54e6cb9e52d25313b321edca45cbbabcdc403d
$ curl -s -o /dev/null -w '%{http_code} %{size_download}\n' localhost:8123/buildid/$BID/debuginfo
200 9784
$ curl … /buildid/$BID/executable            → 200 15912
$ curl … /buildid/$BID/section/.debug_line   → 200 121
$ curl … /buildid/$BID/source/tmp/dw/a.c     → 200 188
```

Four observations that matter to this catalog:

1. **The key is the build-id and nothing else.** The client formats the requested build-id into the URL and into its cache path (`debuginfod-client.c`: `xalloc_str (target_cache_dir, "%s/%s", cache_path, build_id_bytes)`). The whole scheme rests on the ELF note that [`embedded-provenance.md`][prov] is about; a binary without one is unresolvable, and GDB's index cache disables itself for exactly the same reason.
2. **`/section/NAME` is ranged out-of-band consumption.** Fetching `.debug_line` alone cost 121 bytes against 9,784 for the whole debug file — **80.9×** less — and elfutils implements a graceful degradation for servers that lack the endpoint: `debuginfod_find_section` falls back to downloading the whole file and slicing locally (`extract_section`). This is the same "fetch the index, then fetch only what it points at" pattern [`range-request-access.md`][range] develops for Parquet and SQLite over HTTP, arriving independently in a debugger.
3. **The server also serves source.** `/source/tmp/dw/a.c` returned the file that `DW_AT_decl_file` names. The artifact's closure now includes files that were never in any artifact at all.
4. **The out-of-band index is, finally, an actual database.** `debuginfod`'s index is SQLite, and its schema — printed here from the live file — is what DWARF's internal structures have been imitating by hand for thirty years:

```sql
-- from the running server's index, elfutils 0.195
CREATE TABLE buildids10_fileparts (           -- string interning, done properly
        id integer primary key not null,
        name text unique not null);
CREATE TABLE buildids10_files (
        dirname integer not null, basename integer not null,
        unique (dirname, basename),
        foreign key (dirname) references buildids10_fileparts(id) on delete cascade,
        foreign key (basename) references buildids10_fileparts(id) on delete cascade);
CREATE TABLE buildids10_f_de (                -- build-id → (debuginfo?, executable?, file)
        buildid integer not null, debuginfo_p integer not null,
        executable_p integer not null, file integer not null, mtime integer not null,
        foreign key (buildid) references buildids10_buildids(id) on update cascade on delete cascade,
        primary key (buildid, file, mtime)) without rowid;
CREATE VIEW buildids10_query_d2 AS …          -- the webapi's D query, as a view
```

Interned path components, real foreign keys with cascade semantics, `WITHOUT ROWID` clustered tables, secondary indexes, and the HTTP endpoints implemented as SQL views. Every one of those is something `.debug_str`, `DW_FORM_ref4`, `.debug_cu_index`, and `.gdb_index` reimplement badly inside the artifact. The moment the index was allowed to stop being a section, it became a database in one step — which is [thesis 1][concepts] stated as a natural experiment rather than an assertion.

## Mutability, dispatch, and trust

**Mutability: 1/3 — incidental, but real.** DWARF is not a state store; nothing writes to `.debug_info` at runtime, and the debug sections are not in any `PT_LOAD` segment, so they are never even mapped by the loader. Page sharing ([thesis 4][concepts]) is therefore untouched: debug information is the one large payload in an ELF file that costs nothing at run time because nobody maps it.

What _is_ mutated is the artifact's index, after the fact, by tools:

```bash
$ gdb-add-index symfile        # runs gdb, writes symfile.gdb-index, then:
$ objcopy --add-section .gdb_index=symfile.gdb-index \
    --set-section-flags .gdb_index=readonly symfile symfile
```

The GDB manual documents this as the supported workflow, along with the more elaborate `--dump-section`/`--update-section` dance needed for `-dwarf-5` (because `.debug_names` entries reference `.debug_str`, so the string table must be extended in the same operation). Three consequences:

- **Adding an index rewrites a shipped binary**, changing its bytes and therefore every hash anyone has recorded of it — the same collision with verification that killed `prelink` (see [`dynamic-linking.md`][ld]) and the same problem [`embedded-provenance.md`][prov] states for signing mutable artifacts. The build-id note itself is _not_ recomputed, which is what makes the operation usable at all and simultaneously means the build-id no longer identifies the bytes: two files with the same build-id may differ by 785 KB of index.
- **The index can be stale in the ordinary way.** Nothing in `.gdb_index` records a checksum of the `.debug_info` it describes; it stores CU offsets and lengths, and a mismatch is undefined behaviour rather than a detected error. Contrast `.debug_sup`, which does carry a checksum, and `prelink`'s `.gnu.liblist`, which carried three validity predicates.
- **The consumer arbitrates.** GDB rejects `.gdb_index` below version 7 (_"Skipping obsolete .gdb_index section"_) and above 9, offers `set use-deprecated-index-sections on` to override, and rejects foreign `.debug_names`. **Dispatch here belongs to the consumer**, not to the kernel, the shell, or the loader — the only subject in this catalog where that is unambiguously true. The artifact proposes; the debugger decides which of the four possible indexes it will believe, and silently rebuilds its own when it believes none of them.

**Trust.** The out-of-band generation moves the threat surface onto the network, and the honest summary is short:

1. **`debuginfod` fetches are unauthenticated by default.** Reading `debuginfod-client.c` at 0.195, the client formats the build-id into the URL, streams the response into `$DEBUGINFOD_CACHE_PATH/BUILDID/`, and — outside the optional IMA path — I found no check that the returned bytes are in fact debug information for that build-id. The only cryptographic verification available is IMA per-file signatures, enabled by prefixing a server URL with `ima:enforcing` and compiled in behind `ENABLE_IMA_VERIFICATION`; the upstream page describes it as _"serving per-file signatures, which allows a debuginfod client to cryptographically verify downloads in ima:enforcing mode."_ Everything else is trust in the server plus TLS.
2. **What arrives is a description, and descriptions are executable inputs.** DWARF carries location expressions and call-frame programs — a stack machine (`DW_OP_*`) interpreted by the debugger and by unwinders in the target process. A malicious or corrupt debug file is untrusted input to an interpreter running in the analyst's process. That is [`threat-model.md`][threat]'s territory and the reason "just fetch the debuginfo" is not the innocuous operation it looks like.
3. **The view drifts silently.** During the local experiment above, the server's `X-DEBUGINFOD-FILE` header reported the source of the returned bytes as `/tmp/dw/dfd/fetched.debug` — the copy the previous `curl` had written into the indexed directory. The index had re-scanned and preferred a file that had not existed when the first request was served. Nothing is wrong with the answer, and nothing announced that the provenance had changed: this is precisely the materialized-view failure mode [concepts][concepts] names, observed live, in the least consequential possible form.

---

## The evidence for thesis 1, stated precisely

[Thesis 1][concepts] — _every binary format eventually reimplements a database, badly_ — is usually argued from ELF's `.gnu.hash` and `.strtab`. DWARF is a stronger case, because the reimplementation is more complete, better documented, and its failures are recorded in the standard's own revision history.

**What DWARF reimplements, and where.**

| Database concept              | DWARF's version                                                        | Grade                                                                   |
| ----------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Schema                        | `.debug_abbrev` declarations                                           | **Good.** Genuinely self-describing; unknown tags are skippable         |
| Schema interning              | 11,684 abbrev declarations (30,262 B) for 1,219,833 DIEs               | **Good.** 0.3 % of the debug bytes carry the type of all of them        |
| String interning              | `.debug_str`, `.debug_line_str`, `DW_FORM_strp`                        | **Good**                                                                |
| Dictionary encoding           | `.debug_str_offsets` + `DW_FORM_strx`, `.debug_addr` + `DW_FORM_addrx` | **Good**, and the reason split DWARF eliminates 19,100× the relocations |
| Column store + delta encoding | the `.debug_line` state machine                                        | **Good**, and described in exactly those words by the spec              |
| Foreign keys                  | `DW_FORM_ref4` / `ref_addr` / `ref_sup4` byte offsets                  | **Bad.** No integrity, no validation, offsets break on any rewrite      |
| Skip pointers                 | `DW_AT_sibling`                                                        | **Bad.** Optional; a consumer cannot rely on it                         |
| Deduplication                 | type units, `dwz` supplementary files, `debuginfod`                    | **Bad.** Three incompatible mechanisms, three key spaces                |
| Secondary index               | pubnames → `.gdb_index` → `.debug_names`                               | **Bad.** Three generations, none universally consumed                   |
| Query surface                 | —                                                                      | **Absent.** Every consumer writes its own walker                        |

The interesting part is the correlation: DWARF is _good_ at exactly the techniques that require no coordination between producer and consumer beyond the format text (interning, encoding, schema) and _bad_ at exactly the ones that require an agreement about semantics (indexes, dedup, referential integrity). `.debug_abbrev` works because a reader needs to know only "how many bytes and what shape". `.debug_names` does not work because a reader needs to know "what counts as a name" — and GDB, GCC, and LLVM never agreed. That is a general prediction, and it is testable against the other formats [comparison.md][comparison] surveys.

Two fair objections, both of which should be recorded:

- **DWARF is more self-describing than ELF, and this is the tree's best counterexample to "binary formats accrete conventions".** A DWARF consumer can skip constructs it has never heard of, correctly, without a version negotiation. ELF cannot: nothing in an ELF file explains `.gnu.hash`. On [thesis 2][concepts], DWARF sits between ELF and SQLite rather than with ELF.
- **The index churn is not incompetence; it is a schema-evolution problem with no migration mechanism.** Every generation of the index was a correct response to a real defect in the previous one. What DWARF lacked was not insight but the thing a database gives you for free: a way to change the schema of a stored view without every producer and every consumer in the world agreeing simultaneously. The augmentation string (`GDB3`, `LLVM0700`) is the format admitting this and pushing the problem to the consumer, which resolves it by rejection.

There is a third reading, and it is the one this catalog should keep. `.debug_pubnames`, `.gdb_index`, `.debug_names`, the `.gdb_index` cache, and `debuginfod` are the _same view_, materialized at five different distances from the data: inside the unit, inside the file, inside the file under a different schema, beside the file under a content hash, and on another machine behind HTTP. The further out it moved, the better its engineering became — the version on the far end is SQLite with foreign keys — and the weaker its coupling to the thing it describes. The catalog's index-anchoring axis is not a taxonomy of formats. It is a measure of how far a system has drifted from the [autological][concepts] ideal, and DWARF has traversed the whole range in one lifetime.

---

## Strengths

- **Genuinely self-describing at the encoding level.** `.debug_abbrev` lets a reader skip a construct it has never seen, which is more than ELF, `tar`, or a bare `.o` symbol table manages. Forward compatibility is structural, not conventional.
- **Extremely good compression for what it encodes.** 6.2 bytes per DIE on real C code, with the entire type-and-scope graph of a 1.2-million-DIE library described by 30 KB of schema.
- **The line-number program is a well-designed codec,** and the spec explains the design decision in the language of tables rather than leaving it to be reverse-engineered.
- **Split DWARF is a genuine engineering win on the axis it targets.** Measured here: 19,100× fewer `.rela.debug_info` bytes and a 43 % smaller object, at the cost of 29 % more total debug bytes and a second file.
- **Costs nothing at run time.** Debug sections are not in any `PT_LOAD`; they are never mapped, never paged, and never touched by the loader, so [thesis 4][concepts] is not in play. Contrast [SELF][self], where the metadata and the text share a b-tree.
- **`debuginfod` solved the distribution problem cleanly,** with a two-noun API (`build-id`, artifact kind), a source endpoint, a section endpoint for partial fetches, and a federating public server.
- **A real out-of-band index done properly exists,** and it is SQLite with foreign keys and views — proof that the constraints DWARF struggles against are the artifact's, not the domain's.

## Weaknesses

- **No query surface, at any generation.** Every consumer writes a walker. The most valuable questions (which types are unused, which inlines dominate size, what changed between two builds) require a full traversal in each of five ecosystems.
- **The index answers "which unit", never "what is in it".** Measured: `info address` on a 156-CU library costs ~1.2 s with or without `.gdb_index`. Thirty years of index work has not made a single fact readable without reconstructing its neighbourhood.
- **Three generations of index, none universally consumed.** GDB ignores `.debug_pubnames` entirely, GDB rejects LLVM's standards-conformant `.debug_names`, and LLVM does not read `.gdb_index`.
- **Indexes have no integrity relationship to the data.** `.gdb_index` records CU offsets and lengths, no checksum; a stale index is silently wrong, not detectably wrong.
- **The index is a size tax on every shipped copy.** 201,177 B of `.debug_names` (3.7 % of the binary) or 785,047 B of `.gdb_index` (6.1 % of the debug file), paid by everyone who downloads the artifact, used by whichever consumer happens to accept that dialect.
- **Split DWARF breaks closure by design,** and the pieces are joined by a filename (`DW_AT_dwo_name`) plus a 64-bit ID, with no store, no lookup path, and no recovery when the `.dwo` is lost.
- **Toolchain interoperability is fragile in observable ways** — see the `-gdwarf-5` `dwp` result above, which produced an empty index and exited 0.
- **`debuginfod` is unverified by default,** and what it delivers is input to interpreters (`DW_OP_*` location expressions, CFI programs) running in the analyst's process.
- **Deduplication happens three times, incompatibly** (type signatures, `dwz` supplementary files, build-ids), each with its own key space and its own consumer special-casing.

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                               | Trade-off                                                                                                |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| DIEs as an untagged byte stream decoded through `.debug_abbrev`             | Schema interning: the row type is stored once, not per row                              | Nothing is randomly accessible; every question starts at a unit header                                   |
| Attribute references as byte offsets (`DW_FORM_ref4`)                       | Cheapest possible foreign key; no relocation needed inside a unit                       | Any rewrite invalidates every reference; no referential integrity, ever                                  |
| The line table as a byte-coded state machine                                | The uncompressed matrix is "impractically large"; one byte per row is achievable        | Random access to a row costs re-running the program from the sequence start                              |
| `.debug_pubnames` as per-CU sets of globals                                 | Trivial for a compiler to emit while writing a CU                                       | No kind, no statics, no addresses, no global ordering → unusable; superseded twice                       |
| `.gdb_index` designed to be `mmap`able, little-endian, alignment-respecting | Zero-parse startup: map the section and probe the hash table                            | A debugger-private on-disk format that two producers implemented differently, versioned nine times       |
| Symbol kind and static-ness packed into bits 28–31 of the CU index          | Keeps the CU vector one word per entry                                                  | 24 bits of CU index (16 M units), attributes invisible to any generic reader                             |
| `.debug_names` standardized with an augmentation string                     | Lets producers add attributes without breaking the format                               | Legitimizes dialects: GDB accepts only `GDB2`/`GDB3` and ignores `LLVM0700` entirely                     |
| GDB rebuilding its own "cooked index" in worker threads                     | Correct by construction, independent of whatever the file claims                        | The reference consumer no longer needs the file's index, weakening the case for shipping one             |
| Index cached out-of-band under the build-id                                 | Keeps the artifact's bytes untouched while keeping the startup win                      | The view now lives on one developer's machine; nothing else can benefit from it                          |
| `-gsplit-dwarf`: skeleton unit + `.dwo`                                     | Removes the DIE tree from the link; addresses funnel through `.debug_addr`              | Closure broken: the artifact carries a filename and a 64-bit ID, and total debug bytes grow              |
| `.dwp` with `.debug_cu_index`/`.debug_tu_index`                             | Concatenation destroys offsets, so contributions must be tabulated per unit per section | The only place DWARF specifies a hash table and a load factor — for one file type, in an appendix        |
| `debuginfod`: build-id → HTTP                                               | Ship nothing; resolve on demand; source and sections too                                | Unverified by default; requires a build-id note, a server, and a network at the moment you are debugging |

---

## Sources

- [DWARF Debugging Information Format, Version 5][dwarf5] (2017-02-13) — §1.4 (changes from v4), §2.1 (DIEs), §3.1.2 (skeleton units), §6.1 (accelerated access), §6.1.1 (`.debug_names`), §6.2 (the line-number matrix), §7.3.5 (package files and the CU/TU index), §7.3.6 (supplementary object files), §7.5.3 (abbreviations tables)
- [DWARF Debugging Information Format, Version 4][dwarf4] (2010-06-10) — §6.1.1, the `.debug_pubnames`/`.debug_pubtypes` definition that DWARF 5 retired
- [GDB manual][gdbdoc] — "Index Files Speed Up GDB", "Extensions to `.debug_names`", and the appendix "`.gdb_index` section format" ([`gdb/doc/gdb.texinfo`][gdbtexi])
- [`gdb/dwarf2/index-write.c`][idxwrite] — `write_gdbindex_1`, the seven-field header and six regions
- [`gdb/dwarf2/read-gdb-index.c`][readgdbidx] — version gate (7 ≤ v ≤ 9), the `gold` interoperability comment, `use-deprecated-index-sections`
- [`gdb/dwarf2/read-debug-names.c`][readnames] — the augmentation-string check that rejects non-GDB `.debug_names`
- [`gdb/dwarf2/index-cache.c`][idxcache] — the build-id-keyed out-of-band index cache
- [`gdb/dwarf2/cooked-index.h`][cooked] — the parallel scan that replaces the index when there is none
- [`gdb/dwarf2/abbrev-table-cache.h`][abbrevcache] — abbrev tables memoized by `(section, offset)`, because units share schemas
- [`gdb/dwarf2/dwz.c`][dwz] — supplementary-file handling
- [`include/gdb/gdb-index.h`][gdbindexh] — `GDB_INDEX_SYMBOL_KIND_*` and the CU-index bit layout
- [`gold/gdb-index.cc`][goldidx] — the linker-side index writer, `DW_AT_GNU_pubnames`, and the pubnames fallback path
- [`gdb/contrib/test_pubnames_and_indexes.py`][pubtest] — the differential test between `gold`, `gdb`, and `gcc` index output
- [GCC 15 Debugging Options][gccdbg] — `-gsplit-dwarf`, `-gpubnames`, `-ggnu-pubnames`, `-fdebug-types-section`
- [elfutils debuginfod][debuginfod-doc] — the webapi, federation, public servers, and IMA verification mode; source read from the elfutils 0.195 tarball (`debuginfod/debuginfod.cxx` — the SQLite schema; `debuginfod/debuginfod-client.c` — caching, `debuginfod_find_section`, IMA)
- Measurements taken on NixOS x86-64 with GCC 15.3.0, binutils 2.46, GDB 16.3, Clang/LLD 20.1.8/21.1.7, elfutils 0.195, against `libpython3.12.so.1.0` (Nix `python3-3.12.11-debug`) and the [SQLite 3.50.4 amalgamation][sqliteamalg]
- Related in this tree: [concepts][concepts] · [embedded provenance][prov] · [binary inspection libraries][libs] · [range-request access][range] · [dynamic linking][ld] · [sqlelf][sqlelf] · [code as a database][codedb] · [footer-indexed formats][footer] · [content-addressed chunking][cas] · [SELF / selfdb][self] · [threat model][threat] · [measurement][measure] · [comparison][comparison]

<!-- References -->

[dwarf5]: https://dwarfstd.org/doc/DWARF5.pdf
[dwarf4]: https://dwarfstd.org/doc/DWARF4.pdf
[repo]: https://github.com/gnutools/binutils-gdb
[gdbdoc]: https://sourceware.org/gdb/current/onlinedocs/gdb.html/Index-Files.html
[gdbtexi]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/doc/gdb.texinfo
[idxwrite]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/index-write.c
[readgdbidx]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/read-gdb-index.c
[readnames]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/read-debug-names.c
[idxcache]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/index-cache.c
[cooked]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/cooked-index.h
[abbrevcache]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/abbrev-table-cache.h
[dwz]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/dwarf2/dwz.c
[gdbindexh]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/include/gdb/gdb-index.h
[goldidx]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gold/gdb-index.cc
[pubtest]: https://github.com/gnutools/binutils-gdb/blob/09a7362522ef0447210042a4f0309559edae82bb/gdb/contrib/test_pubnames_and_indexes.py
[gccdbg]: https://gcc.gnu.org/onlinedocs/gcc-15.1.0/gcc/Debugging-Options.html
[debuginfod-doc]: https://sourceware.org/elfutils/Debuginfod.html
[elfutils]: https://sourceware.org/elfutils/
[sqliteamalg]: https://sqlite.org/amalgamation.html
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[prov]: ./embedded-provenance.md
[libs]: ./binary-inspection-libraries.md
[range]: ./range-request-access.md
[ld]: ./dynamic-linking.md
[sqlelf]: ./sqlelf.md
[codedb]: ./code-as-database.md
[footer]: ./footer-indexed-formats.md
[cas]: ./content-addressed-chunking.md
[nix]: ./nix-store-closures.md
[self]: ./self-selfdb/index.md
[threat]: ./threat-model.md
[measure]: ./measurement.md
[differentials]: ./parser-differentials.md
