# Generic format-to-query layers (LIEF, goblin, pyelftools, Kaitai Struct, DFDL)

The layer that turns a binary format into structured data — and the split that runs through it: **[Kaitai Struct][ks-site] and [DFDL][dfdl-ogf] are declarative format grammars**, where the description of the format is itself data and the parsers are generated; **[LIEF][lief-repo], [goblin][goblin-repo] and [pyelftools][pyelftools-repo] are hand-written per-format libraries**, where the description of the format is the code.

| Field           | Value                                                                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Tooling layer — five libraries/languages that sit between a binary artifact and a consumer that wants rows                                                                                |
| Language        | C++17 (LIEF) · Rust 2024 (goblin) · Python (pyelftools) · Scala compiler + 13 target-language backends (Kaitai) · XSD + XPath 2.0 subset (DFDL)                                           |
| License         | Apache-2.0 (LIEF) · MIT (goblin) · public domain (pyelftools) · GPLv3+ compiler, MIT runtimes (Kaitai) · OGF Recommendation, Apache-2.0 (Daffodil)                                        |
| Repository      | [lief-project/LIEF][lief-repo] · [m4b/goblin][goblin-repo] · [eliben/pyelftools][pyelftools-repo] · [kaitai-io/kaitai_struct][ks-repo] · [apache/daffodil][daffodil-repo]                 |
| Documentation   | [lief.re][lief-docs] · [docs.rs/goblin][goblin-docs] · [pyelftools user guide][pyelftools-guide] · [doc.kaitai.io][ks-docs] · [GFD.240 (DFDL v1.0)][dfdl-ogf]                             |
| First release   | pyelftools `0.20`, 2012-01-30 (PyPI) · LIEF `0.8.0`, 2017-11-21 (PyPI) · goblin `0.0.9`, 2017-04-05 · `kaitai-struct-compiler` `0.2`, 2016-04-06 · DFDL v1.0 as GFD-P-R.174, January 2011 |
| Axis profile    | Multiplicity **1** / Reflexivity **3** / Closure **0** / Mutability **2**                                                                                                                 |
| Index anchoring | **Out-of-band** — the description of the artifact is never inside the artifact                                                                                                            |
| Dispatch owner  | **Consumer** (content sniffing: goblin's `Hint`, `lief.is_elf`, a `.ksy` `contents:` magic check)                                                                                         |

> **Revisions surveyed:** LIEF at [`4c9c42c4`][lief-repo] (release `1.0.0`, 2026-07-12; `2.0.0` unreleased) · goblin at [`dca2e753`][goblin-repo] (`0.10.6`, 2026-05-25) · pyelftools at [`e5fa2a4f`][pyelftools-repo] · `kaitai_struct_formats` at [`ccad5db7`][ksf-repo] · `kaitai_struct_compiler` at [`fd259425`][ksc-repo] (`0.12-SNAPSHOT`; last release `0.11`, 2025-09-07) · Apache Daffodil at [`d902f944`][daffodil-repo] (`4.3.0-SNAPSHOT`). **Platform:** all cross-platform; LIEF's `LIEF_RUNTIME` module is gated to `linux`/`windows`/`android`/`osx` × `x86_64`/`arm64`/`riscv64`.

---

## Overview

### What it solves

A binary artifact is a graph of offsets. Nothing in ELF, PE or Mach-O will hand you a row set; every consumer that wants one — a linker, a packager, a security scanner, a [`sqlelf`][sqlelf] virtual table — has to walk the graph itself. The five subjects here are the five recurring answers to "who walks it":

| Answer                      | Subjects           | The format description is…                             |
| --------------------------- | ------------------ | ------------------------------------------------------ |
| A library per format        | pyelftools, goblin | source code, one implementation per language           |
| A library across formats    | LIEF               | source code, plus an abstract cross-format facade      |
| A grammar, compiled to code | Kaitai Struct      | a `.ksy` YAML document, compiled to 13 languages       |
| A grammar, interpreted      | DFDL / Daffodil    | an annotated XML Schema, interpreted into an _infoset_ |

That split is [thesis 2][concepts] one level up. Thesis 2 says self-description is what makes a _format_ survivable; formats without it accrete conventions. These tools are what "accreting conventions" looks like when you write it down: the conventions get externalized into a description that lives somewhere else, and then that description has to be maintained, versioned, and kept in sync with a format that does not know it exists. Kaitai and DFDL make the description a first-class artifact and generate the readers. LIEF, goblin and pyelftools keep the description implicit in hand-written code — and, as the evidence below shows, each of the three then independently re-derives the _same_ missing facts about ELF, because ELF does not record them.

### Design philosophy

The declarative camp states its position most explicitly in the DFDL specification, and the wording matters because it is the exact inverse of what this catalog's seed cases do:

> _"It is an important observation that both XML format and standardized binary formats are prescriptive in that they specify or prescribe a representation of the data. To use them applications must be written to conform to their encodings and mechanisms of expression. DFDL suggests an entirely different scheme. The approach is descriptive in that one chooses an appropriate data representation for an application based on its needs and one then describes the format using DFDL so that multiple programs can directly interchange the described data. […] That is, DFDL is not a format for data; it is a way of describing any data format."_
> — [DFDL v1.0 Specification, GFD-R-P.240, §1][dfdl-ogf], p. 9

[SELF/selfdb][self] takes the prescriptive road: change the format to SQLite, get schema-carrying for free. DFDL takes the descriptive road: leave every format alone, and carry the schema beside it. Both are answers to thesis 2; they differ only on where the schema lives, which is exactly the **index anchoring** sub-question applied to metadata rather than to content.

Kaitai's framing is narrower and operational:

> _"Kaitai Struct tries to isolate the developer from all these details and allow them to focus on the things that matter: the data structure itself, not particular ways to read or write it."_
> — [Kaitai Struct User Guide, §1][ks-guide]

And LIEF's is narrower still — it is the only one of the five whose stated purpose includes writing:

> _"The purpose of this project is to provide a cross-platform library to parse, modify, and abstract the ELF, PE, and Mach-O formats."_
> — [`doc/sphinx/intro.md`][lief-intro]

---

## How it works

### The hand-written libraries

**pyelftools** is the readable reference implementation, and it is a hybrid: it vendors a fork of the `construct` declarative binary-parsing library and uses it for the _layout_ layer, while the _semantic_ layer is hand-written Python. The vendoring rationale is recorded in the tree:

```text
# elftools/construct/README
construct is a Python library for declarative parsing and building of binary
data. This is my fork of construct 2, with some modifications for Python 3
and bug fixes. …
pyelftools carries construct around because construct has been abandoned for
a long time and didn't get bugfixes; it also didn't work with Python 3.
```

Structures are declared, not coded — `elftools/elf/structs.py` builds `Elf_Sym`, `Elf_Shdr`, `Gnu_Hash` and friends out of `construct` combinators. Everything _above_ a struct — resolving `sh_link`, decoding a `st_name`, counting symbols — is ordinary Python. That seam is where the argument of this page lives.

**goblin** is `#![cfg_attr(not(feature = "std"), no_std)]` and borrows rather than copies: `Elf<'a>`, `Strtab<'a>`, `Symtab<'a>` all carry the lifetime of the input `&[u8]`. Its README advertises _"zero-copy, cross-platform, endian-aware, ELF64/32 implementation"_ and lists among its use cases _"Write a [semi-functioning dynamic linker]"_ and _"Write a [kernel] and load binaries using `no_std` cfg"_ ([`README.md`][goblin-readme]). Its `Elf::parse` is eager and denormalizing: by the time it returns, `soname`, `libraries`, `rpaths`, `runpaths`, `interpreter` and `is_lib` are already materialized as plain fields on the struct, joined out of `.dynstr` ([`src/elf/mod.rs`][goblin-elf]). `Elf::lazy_parse` exists for callers who want the header only.

**LIEF** is the largest and the only writer. It parses ELF, PE, Mach-O, COFF, OAT, DEX, VDEX and ART into a mutable object graph, exposes a format-agnostic `LIEF::Binary` facade over them, and rebuilds a valid file with `Builder::build()`. It also ships DWARF/PDB readers, an LLVM-backed disassembler and assembler, and — since `1.0.0` — a runtime module that inspects the _current_ process ([`doc/sphinx/runtime/intro.md`][lief-runtime]). At the surveyed revision the ELF sources and headers alone are ~32.5 kLOC of the ~124 kLOC C++ tree.

### The declarative grammars

A `.ksy` file is YAML with three load-bearing keys: `seq` (fields read in order), `instances` (fields read on demand, at a computed `pos`, possibly in another `io`), and `types` (named sub-structures). Instances are the interesting half:

```yaml
# kaitai_struct_formats/executable/elf.ksy — dynsym_section_entry
seq:
  - id: ofs_name # -orig-id: st_name
    type: u4
instances:
  name:
    io: _parent._parent.linked_section.body.as<strings_struct>._io
    pos: ofs_name
    type: strz
    encoding: UTF-8
    if: ofs_name != 0 and _parent.is_string_table_linked
```

That is `st_name` — the foreign key thesis 1 names — resolved declaratively: switch to the stream of the section named by `sh_link`, seek to `ofs_name`, read a NUL-terminated string. The join target itself is a `value` instance, a pure expression over already-parsed data:

```yaml
# kaitai_struct_formats/executable/elf.ksy — section_header
instances:
  linked_section:
    value: _root.header.section_headers[linked_section_idx]
    if: |
      linked_section_idx != section_header_idx_special::undefined.to_i
      and linked_section_idx < _root.header.num_section_headers
    doc: may reference a later section header, so don't try to access too early (use only lazy `instances`)
```

The compiler (`kaitai-struct-compiler`, Scala, GPLv3+) transpiles the expression language into each target: C++, C#, Go, Java, JavaScript, Lua, Nim, Perl, PHP, Python, Ruby, Rust, Zig at the surveyed revision. The [`kaitai_struct_formats`][ksf-repo] repository ships 186 `.ksy` specs totalling ~49 k lines; each carries its own `meta/license` (`elf.ksy` is `CC0-1.0`).

**DFDL** is architecturally different in one decisive way: it is an _annotation layer on XML Schema_, and the result of parsing is not objects but a **DFDL Infoset**.

> _"A DFDL description enables parsing, that is, it allows data to be read from its native format and presented as a data structure called the DFDL Information Set or DFDL Infoset. […] DFDL implementations MAY provide API access to the Infoset as well as conversion of the Infoset into concrete representations such as XML text, binary XML [EXI], or JSON [JSON]."_
> — [GFD-R-P.240 §1.2][dfdl-ogf], p. 10

[Apache Daffodil][daffodil-site], the reference-grade open implementation, states the payoff plainly: the infoset _"is commonly converted into XML or JSON to enable the use of well-established XML or JSON technologies and libraries to consume, inspect, and manipulate fixed format data in existing solutions"_ ([`README.md`][daffodil-readme]). DFDL's own expression language is an XPath 2.0 subset, so the query surface a DFDL description hands you is the standardized one you already had.

---

## Format identity and multiplicity

**Score: 1 — incidental.** These tools do not create multiplicity; they _collapse_ it, and how they collapse it is the finding.

goblin's entry point sniffs a 16-byte prefix and returns exactly one answer:

```rust
// goblin/src/lib.rs — peek_bytes (abridged)
if &bytes[0..elf::header::SELFMAG] == elf::header::ELFMAG { … Ok(Hint::Elf(…)) }
else if &bytes[0..archive::SIZEOF_MAGIC] == archive::MAGIC { Ok(Hint::Archive) }
else {
    match *&bytes[0..2].pread_with::<u16>(0, LE)? {
        pe::header::DOS_MAGIC => Ok(Hint::PE),
        pe::header::TE_MAGIC  => Ok(Hint::TE),
        …
        _ => mach::peek_bytes(bytes)
    }
}
```

`Object::parse` then dispatches on that single `Hint` and returns a single `Object` variant ([`src/lib.rs`][goblin-lib]). Hand a goblin-based tool an [APE binary][ape] and it will report `Object::PE`, because APE's first two bytes are `MZ` — true, and also two-thirds of a lie: the same bytes are a shell script and a ZIP archive. The prefix sniff is _ordered first-match_, which is precisely the shape that makes [parser differentials][differentials] possible: two consumers with different orderings disagree about what the file is, with neither of them wrong about its own answer.

LIEF is one degree less committal — `lief.is_elf(path)` is a predicate, and a caller may legitimately ask several predicates of the same bytes — but its object model still forces a choice: you get a `LIEF::ELF::Binary` _or_ a `LIEF::PE::Binary`, never both views of one stream. pyelftools does not even offer a sniffer; `ELFFile` asserts the magic and stops.

Kaitai is the only one of the five that structurally admits multiplicity, and only because nothing in it is exclusive: a `.ksy` is a _view_, so N grammars can be compiled and each applied to the same bytes independently. `elf.ksy` and `dos_mz.ksy` and `zip.ksy` are separate objects with separate streams; running all three over one APE file is legal and cheap. Nothing coordinates them — there is no cross-grammar conflict detection — but nothing forbids the superposition either. That makes Kaitai the natural tooling for the [polyglot craft][polyglot] end of this catalog and goblin the natural tooling for the "decide and move on" end.

DFDL, by contrast, cannot express multiplicity at all in the sense this catalog means, and for a reason worth naming: a DFDL schema describes one document, parsed strictly left to right (see the next section). Two overlapping interpretations of one byte range is not a thing the DFDL processing model has a vocabulary for.

> [!NOTE]
> The multiplicity score is a property of the _layer_, not of the artifacts it reads. A tool that reads polyglots does not thereby become one. What earns the `1` rather than a `0` is that Kaitai's view-not-owner model permits the superposed reading, and that goblin's `Hint` ordering is itself an observable input to a differential.

---

## Index anchoring and random access

**Anchoring: out-of-band.** For all five, the description of the artifact lives outside the artifact — in a `.ksy` file, a `.dfdl.xsd` file, or a compiled library. This is the defining structural fact about the whole layer and the reason its Closure score is `0`.

Random access _within_ the artifact splits the five sharply.

**Kaitai: lazy instances, memoized.** `instances` are lazy by default and cached after first evaluation:

> _"Another very important difference between the `seq` attribute and the `instances` attribute is that instances are lazy by default. […] Unless someone would call that `body` getter method programmatically, no actual parsing of `body` would be done. This is super useful for parsing larger files, such as images of filesystems."_
> — [Kaitai Struct User Guide, §Instances][ks-guide]

Combined with `io:` (parse this field out of _that_ substream) and `pos:` (seek), this is a genuine random-access model over a seekable source. `elf.ksy` uses it exactly as ELF demands: the section header table is reached by an instance at `_root.header.section_headers`, section bodies by `pos: ofs_body`, symbol names by a seek into another section's stream.

**DFDL: no absolute positioning at all.** The v1.0 property set gives `dfdl:lengthKind` the values `explicit`, `delimited`, `implicit`, `prefixed`, `pattern`, `endOfParent` — all _relative_ — plus `dfdl:leadingSkip` and `dfdl:trailingSkip`, both specified as _"A non-negative number of bytes or bits […] to skip"_ ([GFD-R-P.240 §12][dfdl-ogf], p. 87). There is no seek, no `pos`, no VA-to-offset construct. The spec's own claim that _"The DFDL language is designed to permit implementations that use lazy evaluation of formats and to support seekable, random access to data"_ ([§1][dfdl-ogf], p. 9) is a statement about _implementation freedom_ — an implementation may skip work for infoset items nobody asked for — not about a schema's ability to name a byte offset. Add the two other v1.0 restrictions the spec states outright — _"This version of DFDL does not support `xs:redefine`"_ and no _"Recursively defined types and elements"_ (§5.2, p. 26) — and the conclusion is unavoidable:

> [!IMPORTANT]
> **DFDL v1.0 cannot describe ELF.** ELF is an offset graph: the header points forward to `e_shoff`, section headers point sideways at each other through `sh_link`, and symbol entries point into a string table located by that link. A strictly forward, non-recursive, relative-only grammar has no way to express any of those three edges. This is not an oversight — DFDL's design centre is record-oriented commercial and scientific data (fixed-width records, delimited text, dense binary arrays), where the data _is_ a stream. It is, however, a sharp boundary on the "declarative grammars can replace hand-written parsers" claim, and it falls exactly along the header-anchored/stream-scanned line this catalog uses for [index anchoring][concepts].

**The hand-written libraries** are as random-access as their host language allows, and they differ mainly in eagerness. pyelftools is lazy per section (`get_section(n)` seeks and parses one header) with one eager exception: a `@cached_property` builds `_section_name_map`, a `dict[str, int]` from section name to index, the first time anyone calls `get_section_by_name` ([`elftools/elf/elffile.py`][pyelftools-elffile]). ELF has no name index; pyelftools builds one in memory, on demand, and throws it away at close. goblin's default `Elf::parse` is eager over headers and denormalizes the dynamic-linking joins immediately; `Elf::lazy_parse` is the opt-out. LIEF is eagerly, comprehensively eager: `ParserConfig::all()` parses everything, and the config exists mostly so you can turn parts _off_.

None of the five can consume an artifact over a byte-range interface without extra machinery — none defines a pluggable access layer the way SQLite's VFS does. This is where the layer differs most sharply from the [substrate-first strategy][ranges] that [thesis 5][concepts] describes: these tools hold the _access_ fixed (a file, a `&[u8]`, a stream) and vary the _format_, which is exactly the old strategy.

---

## Reflexivity and query surface

**Score: 3 — defining.** This is the one axis on which the layer is the point.

The query surfaces on offer, ranked by how _general_ they are:

| Subject    | Query surface                                                             | Generality                                                    |
| ---------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| DFDL       | An XML/JSON infoset → XPath, XQuery, XSLT, JSONPath, any XML tool         | Highest — the query language is standardized and pre-existing |
| Kaitai     | Generated classes in 13 languages + a `.ksy`-internal expression language | High for navigation, nil for set operations                   |
| LIEF       | An object graph with iterators, plus JSON export, in C++/Python/Rust      | Medium — imperative traversal                                 |
| pyelftools | Python objects and generators                                             | Medium — imperative traversal                                 |
| goblin     | Rust structs with borrowed slices                                         | Medium — imperative traversal, zero allocation                |

DFDL's answer is the strongest one anybody in this catalog has: parse once, get a document, and inherit thirty years of XML tooling. It is the same move [`sqlelf`][sqlelf] makes with SQL, one query language over. That both exist, independently, is evidence for the catalog's central claim that the interesting operation on a binary is _relational_, not procedural.

But the declarative grammars' _internal_ expression languages are much weaker than their output formats, and the gap is where the hand-written libraries earn their keep. Kaitai's expression language has arithmetic, comparison, bitwise, boolean and ternary operators; array methods are exactly `first`, `last`, `size`, `min`, `max`; stream methods are `eof`, `size`, `pos` ([User Guide §18][ks-guide]). There is no filter, no predicate lookup, no grouping, no transitive closure. A join is expressible only as an explicit index (`section_headers[linked_section_idx]`) — never as "the section whose name is `.dynstr`". `elf.ksy` documents where that runs out, in its own words:

```yaml
# kaitai_struct_formats/executable/elf.ksy — ph_dynamic_section, doc:
#   There is another way to find the string table referenced by the
#   dynamic section entries that does not rely on `linked_section`, but is
#   a bit more complex (and is therefore considered out of scope of this
#   .ksy spec): the mandatory dynamic tag `dynamic_array_tags::strtab`
#   (`DT_STRTAB`) specifies the virtual address of the string table, and
#   `dynamic_array_tags::strsz` (`DT_STRSZ`) specifies its size in bytes.
#   The virtual address can be converted to a file offset by reading the
#   program headers - see the source code for the `readelf` command…
```

A virtual address is a foreign key into the program header table under a range predicate ("the `PT_LOAD` whose `[p_vaddr, p_vaddr + p_memsz)` contains this address"). Kaitai has index-by-position but not select-by-predicate, so the grammar declares the join out of scope and the `ph_dynamic_section_entry` type simply has no `value_str`. The same file then has to define `sh_dynamic_section` and `ph_dynamic_section` as **two nearly identical types** whose only difference is whether `_parent.linked_section` is reachable — the grammar duplicates a structure because the join is available in one context and not the other. In SQL that is one table and two views.

LIEF's reflexivity extends past the artifact to the _process_: the runtime module _"provides facilities to inspect and interact with the current process in which the API is used. You can, for instance, list modules loaded in memory or read the content at a specific memory address"_ ([`doc/sphinx/runtime/intro.md`][lief-runtime]). That is the "interrogate itself while running" half of the reflexivity axis, obtained by linking a library rather than by changing the format — a much cheaper path to the same capability than [SELF][self] takes, and a much shallower one, because the process cannot ask _transactional_ questions of itself.

The clearest demonstration that this layer _is_ the query surface for everything above it is [`sqlelf`][sqlelf], whose SQLite virtual tables are generated straight from LIEF objects: `sqlelf/lief_ext.py` proxies `lief.ELF.Binary`, and `pyproject.toml` pins `lief ==0.14.1` with the comment _"lief has proven to change API a lot / pin it to a specific version"_ ([`pyproject.toml`][sqlelf-pyproject]). SQL over ELF is, in practice, SQL over LIEF's object model — which means the schema of the "database" is whatever a C++ library's headers happened to expose that release.

---

## Closure, dedup, and size model

**Score: 0 — absent.** Nothing here carries anything. A `.ksy` file, a `.dfdl.xsd` schema, and a linked copy of `liblief` are all strictly external to the artifact they describe. If the artifact moves and the description does not, the description is gone; if the format changes and the description does not, the description is wrong and nothing detects it. That is precisely the failure mode [thesis 2][concepts] predicts for formats that do not carry their own schema, relocated one level up: the convention becomes a file that rots on its own schedule.

The size numbers worth recording are about _description cost_, not artifact size. At the surveyed revisions, for ELF alone:

| Description of ELF                                    | Size             | Yields                            |
| ----------------------------------------------------- | ---------------- | --------------------------------- |
| [`kaitai_struct_formats/executable/elf.ksy`][ksf-elf] | 3 585 lines YAML | readers in 13 languages           |
| [`pyelftools/elftools/elf/*.py`][pyelftools-repo]     | 6 869 lines      | one Python reader                 |
| [`goblin/src/elf/*.rs`][goblin-elf]                   | 9 110 lines Rust | one `no_std`-capable Rust reader  |
| [`LIEF/src/ELF` + `include/LIEF/ELF`][lief-repo]      | 32 564 lines C++ | one C++/Python/Rust reader-writer |

The declarative description is roughly half the size of the smallest hand-written reader and generates thirteen of them. That is the honest case for grammars, and it is a strong one — but see the next section for what those 3 585 lines _cannot_ do that the 9 110 can, and note the asymmetry: LIEF's 32.5 kLOC buys the ability to write, which no line count of `.ksy` currently buys for ELF.

Deduplication across formats is only attempted by LIEF, through `LIEF::Binary` — a facade exposing `sections`, `symbols`, `relocations`, `entrypoint`, `patch_address`, `get_content_from_virtual_address` and `disassemble` for ELF, PE and Mach-O alike ([`include/LIEF/Abstract/Binary.hpp`][lief-abstract]). The abstraction is real but lossy in the usual direction: everything format-specific — `DT_RUNPATH`, PE resource directories, Mach-O load commands — lives only on the concrete subclass, so the shared vocabulary is the intersection, not the union.

---

## Mutability, dispatch, and trust

**Score: 2 — designed-in, not transactional.** Three of the five can write. None of them can write _safely_ in the sense a database means, and the reason is uniform: a binary format's derived structures have no owner.

### LIEF: index maintenance as a checkbox

`LIEF::ELF::Builder::config_t` is a list of booleans, one per derived structure, each documented as "Rebuild X":

```cpp
// include/LIEF/ELF/Builder.hpp — config_t (abridged)
bool dt_hash        = true;   /// Rebuild DT_HASH
bool dyn_str        = true;   /// Rebuild DT_STRTAB
bool gnu_hash       = true;   /// Rebuild DT_GNU_HASH
bool jmprel         = true;   /// Rebuild DT_JMPREL
bool relr           = true;   /// Rebuild DT_RELR
bool static_symtab  = true;   /// Rebuild `.symtab`
bool sym_verdef     = true;   /// Rebuild DT_VERDEF
bool sym_verneed    = true;   /// Rebuild DT_VERNEED
bool sym_versym     = true;   /// Rebuild DT_VERSYM
bool symtab         = true;   /// Rebuild DT_SYMTAB
bool notes          = false;  /// Disable note building since it can break the default layout
```

Read that list next to a database's `REINDEX`. It is the same operation — recompute every index over a mutated base table — with two differences that matter. First, it is _opt-out per index_, and one of the defaults is already `false` because rebuilding notes _"can break the default layout"_. Second, nothing verifies the result: there is no transaction, no constraint, no `PRAGMA integrity_check`. `GnuHash.hpp` states the ownership rule the C++ type system cannot: _"Most of the fields are read-only since the values are re-computed by the LIEF::ELF::Builder"_ ([`include/LIEF/ELF/GnuHash.hpp`][lief-gnuhash]).

The failure mode is documented in LIEF's own changelog, and it is a broken foreign key:

> _"Fix the modification of binaries that have already been modified by LIEF. The segment table was relocated a second time which, for the non-PIE binaries, shifted the sections without shifting the segments nor the dynamic entries. It resulted in a `DT_STRTAB` that was no longer pointing to `.dynstr` (i.e. garbage `DT_NEEDED`/`DT_RUNPATH` names) and in a `PT_PHDR` that was not wrapped by a `PT_LOAD` segment."_
> — [`doc/sphinx/changelog.md`, 2.0.0 (unreleased)][lief-changelog]

A write that is not idempotent, whose second application silently produces garbage `DT_NEEDED` strings, is the exact hazard a foreign-key constraint exists to prevent. LIEF's answer is `check_layout()`, an after-the-fact verifier — the same shape as `PRAGMA integrity_check`, and the same admission that the writer cannot maintain the invariant by construction.

### Kaitai: writing without derived-value maintenance

Serialization landed in Kaitai `0.11` (2025-09-07), for Java and Python, funded by NLnet ([Serialization Guide][ks-serialization]). It gives generated classes `_read()`, `_check()` and `_write()`. `_check()` is a hand-invoked integrity check — it verifies what the `.ksy` states, e.g. that a `repeat-expr: 2` array really has two elements, and raises `ConsistencyError` otherwise. But it does not _maintain_ anything, and the guide is explicit about the consequences:

> _"Current serialization support relies on fixed-length streams, meaning that once you create a stream, it's not possible to resize it later. Therefore, you'll often need to calculate sizes 'manually' in your application along with setting the object properties."_
>
> _"After creating a new KS object, you must also set fields with `contents` or `valid` on them, even if there's only one valid value they can have. Kaitai Struct doesn't set them automatically at the moment."_
> — [Kaitai Struct Serialization Guide][ks-serialization]

So the grammar knows a field is a magic constant and still will not fill it in; knows a field is a length and still will not compute it. `_check()` will tell you afterwards that you got it wrong. That is a CHECK constraint without a generated column.

### DFDL: the one that does maintain derived values

DFDL is alone among the five in expressing derived-field maintenance declaratively, through `dfdl:outputValueCalc`:

> _"If the element declaration has a `dfdl:outputValueCalc` property, then the expression which is the `dfdl:outputValueCalc` property value is evaluated, and the resulting value becomes the value of the element item in the augmented Infoset. Any pre-existing value for the Infoset item is superseded by this new value."_
> — [GFD-R-P.240 §9 (unparsing algorithm)][dfdl-ogf]

A length prefix declared with `dfdl:outputValueCalc` is recomputed by the unparser from the thing it measures. That is a generated column, in a format grammar, standardized in 2011 and re-issued as GFD-R-P.240 in February 2021 (updated June 2023). It is the single strongest counterexample in this survey to the idea that binary-format tooling _cannot_ express database-grade write semantics — and it is available only in the one language that, as shown above, cannot describe ELF.

### Dispatch and trust

Dispatch owner for all five is the **consumer**. Nobody here registers with `binfmt_misc`, nobody teaches `ld.so` anything; a tool decides for itself what a byte string is and can be wrong. The trust consequences are mostly the standard ones for parsers of adversarial input, and the projects treat them as such: goblin advertises _"fuzzed — 'I am happy to report that goblin withstood 100 million fuzzing runs'"_ ([`README.md`][goblin-readme]), LIEF runs ASan in CI ([`doc/sphinx/intro.md`][lief-intro]).

Two trust-relevant details are specific to this layer:

1. **Bounded-by-magic-number, not by structure.** LIEF hard-codes `NB_MAX_SYMBOLS = 1000000`, `DELTA_NB_SYMBOLS = 3000`, `NB_MAX_SEGMENTS = 10000` ([`include/LIEF/ELF/Parser.hpp`][lief-parserh]) because ELF supplies no authoritative bound. Every such constant is a place where two implementations can disagree about whether a file is valid — the raw material of a [parser differential][differentials].
2. **`Strtab`'s indexing operator panics.** goblin's `Index<usize> for Strtab<'a>` is documented _"**NB**: this will panic if the underlying bytes are not valid utf8, or the offset is invalid"_ ([`src/strtab.rs`][goblin-strtab]) — and `GnuHash::lookup` uses exactly that operator (`&dynstrtab[symb.st_name as usize]`). A dangling `st_name` in a hostile ELF reaches a `panic!` rather than an error. The safe accessor `get_at` exists; the ergonomic one does not use it.

Page sharing and `mmap` — [thesis 4][concepts] — do not apply here, and the absence is itself a finding: because these tools never change the artifact's format, an ELF read by pyelftools is still an ELF the kernel demand-pages normally. The entire cost of this layer is paid at analysis time, in the analyst's address space, and none of it is paid at load time by every process on the machine. That is the asymmetry that makes "keep the format, add a library" the overwhelmingly popular answer and "change the format" the rare one.

---

## Could a declarative grammar have generated ELF's derived structures?

This is [thesis 1][concepts] — _"every binary format eventually reimplements a database, badly"_ — tested from the tooling side. The test: take the three structures thesis 1 names (`.gnu.hash` as a hand-rolled bloom filter, `.strtab` as string interning, `st_name` as a hand-maintained foreign key) and ask, for each, whether a declarative grammar could have generated it rather than every consumer hand-maintaining it.

**`st_name` and `.strtab`: yes, and Kaitai does.** The `name` instance shown above _is_ the dereference, declared once and compiled into thirteen languages. String interning falls out for free: `strings_struct` is `type: strz, repeat: eos`, and a `pos:` into its `_io` reads the interned string at any offset. This half of thesis 1 is not merely reimplementable declaratively — it has been reimplemented declaratively, in a 3 585-line file, and the result is correct enough to be the reference `.ksy` for ELF.

**`.gnu.hash`: no — and the way it fails is the finding.** `elf.ksy` defines `sh_type::gnu_hash` as an _enum constant_ and stops. The `body` switch on `section_header` has cases for `dynamic`, `strtab`, `dynsym`, `symtab`, `note`, `rel`, `rela`, `gnu_versym`, `gnu_verdef`, `gnu_verneed` — and no case for `hash` or `gnu_hash`. Grepping the whole 3 585-line spec for `sh_type::gnu_hash` returns nothing outside the enum definition. The most database-shaped structure in ELF is the one structure the declarative grammar declines to describe.

The reason is precise and general. `.gnu.hash`'s layout is `[nbuckets, symoffset, bloom_size, bloom_shift]`, then `bloom_size` words, then `nbuckets` words, then a chain array whose length is `count(.dynsym) − symoffset`. Every field but the last has a length recorded in the header; the chain array's length is a **derived aggregate over another table** — and ELF never records `count(.dynsym)` anywhere. So the only way to size the chain array is to walk it. All three hand-written libraries independently implement that walk:

| Library    | Function                                                            | What it does                                                      |
| ---------- | ------------------------------------------------------------------- | ----------------------------------------------------------------- |
| pyelftools | `GNUHashTable.get_number_of_symbols` ([`hash.py`][pyelftools-hash]) | max over `buckets`, then walk that chain until the low bit is set |
| goblin     | `gnu_hash_len` ([`src/elf/mod.rs`][goblin-elf])                     | same algorithm, `#[cold]`-adjacent, inline in `Elf::parse`        |
| LIEF       | `Parser::nb_dynsym_gnu_hash` ([`Parser.tcc`][lief-parser])          | same algorithm, one of _three_ alternative counting methods       |

pyelftools' docstring states the problem in one line: _"Get the number of symbols in the hash table by finding the bucket with the highest symbol index and walking to the end of its chain."_ And pyelftools' `construct` declaration of the structure stops in exactly the same place `elf.ksy` does:

```python
# elftools/elf/structs.py
self.Gnu_Hash = Struct('Gnu_Hash',
                       self.Elf_word('nbuckets'),
                       self.Elf_word('symoffset'),
                       self.Elf_word('bloom_size'),
                       self.Elf_word('bloom_shift'),
                       Array(lambda ctx: ctx['bloom_size'], self.Elf_xword('bloom')),
                       Array(lambda ctx: ctx['nbuckets'], self.Elf_word('buckets')))
```

Four scalars, two arrays sized by header fields — and no `chains` member, because `construct` cannot size it either. The chain walk lives in hand-written Python thirty lines away. Two independent declarative systems, `construct` and Kaitai, draw the boundary at the same byte.

LIEF's version of the problem is the most damning single artifact in this survey. Because there are three ways to count `.dynsym` rows and they disagree, LIEF exposes the choice to the user as an enum:

```cpp
// include/LIEF/ELF/ParserConfig.hpp
enum class DYNSYM_COUNT {
  AUTO = 0,      /// Automatic detection
  SECTION,       /// Count based on sections (not very reliable)
  HASH,          /// Count based on hash table (reliable)
  RELOCATIONS,   /// Count based on PLT/GOT relocations (very reliable but not accurate)
};
```

`SELECT count(*) FROM dynsym` is a configuration option with three mutually inconsistent implementations, one of which the library's own documentation calls _"not very reliable"_ and another _"very reliable but not accurate"_. The `AUTO` branch computes all three and votes, using the hard-coded `DELTA_NB_SYMBOLS = 3000` tolerance to decide when two answers are close enough to prefer the larger ([`src/ELF/Parser.tcc`][lief-parser]). goblin performs the same reconciliation at a smaller scale: it takes `gnu_hash_len`, then raises it to `max(r_sym) + 1` over all relocation tables if the relocations reference a higher index ([`src/elf/mod.rs`][goblin-elf]).

**Verdict.** A declarative grammar _could_ have generated `st_name` resolution and `.strtab` interning — Kaitai proves it, at roughly half the source size of the smallest hand-written reader, for thirteen languages. It could not have generated `.gnu.hash`, and no plausible extension to a _layout_ grammar would, because `.gnu.hash` is not a layout: it is a bloom filter plus a hash index plus a chain-terminated run whose cardinality is an aggregate ELF forgot to store. The missing ingredients — a declared cardinality, a `UNIQUE` constraint on symbol names, an index declared over a base table rather than laid out beside it — are database features, not grammar features. Thesis 1 survives this test, sharpened: **the parts of ELF a format grammar handles well are the parts that are merely a schema; the parts it cannot handle are exactly the parts that are an index.** DFDL is the only one of the five with anything resembling index maintenance (`dfdl:outputValueCalc`), and DFDL cannot describe ELF for unrelated structural reasons.

The counterfactual is worth stating plainly, because it is the argument [SELF][self] makes: had `.dynsym` been a table with a recorded row count and `.gnu.hash` a declared index over it, none of the code in the table above would exist, `DYNSYM_COUNT` would not be a user-facing enum, and LIEF's `Builder::config_t` would be `REINDEX`.

---

## Strengths

- **Kaitai's economics are real.** 3 585 lines of YAML → readers in 13 languages, versus 6 869–32 564 lines per hand-written implementation _per language_. For the layout-shaped ~90 % of a format, the grammar is unambiguously the better engineering.
- **DFDL inherits a standardized query surface.** Parse once into an infoset, then use XPath/XQuery/XSLT/JSON tooling. No other subject here gets a query language for free.
- **DFDL is the only one that maintains derived values declaratively** (`dfdl:outputValueCalc`), i.e. the only one whose writer is not required to hand-compute length prefixes.
- **LIEF writes, abstracts, and inspects the live process** — the only subject that spans read, modify, cross-format facade, and runtime self-inspection, and the reason it is the row source under [`sqlelf`][sqlelf].
- **goblin is `no_std` and zero-copy**, so the same parser runs in a kernel, a bootloader, or a linker; `Elf<'a>` borrows the input rather than copying it.
- **pyelftools is the readable oracle.** Public domain, no dependencies, and the implementation everyone else reads when a spec is ambiguous — including its explicit `_get_linked_strtab_section` / `_get_linked_symtab_section` helpers that type-check a `sh_link` target before dereferencing it.
- **Lazy `instances` give Kaitai genuine random access** over large artifacts without a full parse.

## Weaknesses

- **DFDL v1.0 cannot express absolute positioning, recursion, or `xs:redefine`**, which rules out every offset-graph format this catalog studies — ELF, PE, Mach-O, ZIP, SQLite.
- **Kaitai's expression language has no predicate lookup**, so a VA→offset resolution is _"considered out of scope of this .ksy spec"_ ([`elf.ksy`][ksf-elf]) and structurally identical types are duplicated (`sh_dynamic_section` vs `ph_dynamic_section`) because a join is reachable in one context and not the other.
- **Kaitai serialization does not maintain derived fields**; lengths and magic constants must be set by hand, with `_check()` reporting mistakes after the fact.
- **LIEF's write path is not idempotent** — modifying an already-LIEF-modified non-PIE binary produced a `DT_STRTAB` no longer pointing at `.dynstr` ([changelog][lief-changelog]).
- **LIEF's API churn is a documented downstream cost.** `sqlelf` pins `lief ==0.14.1` with the comment _"lief has proven to change API a lot"_.
- **Row counts are heuristics.** `DYNSYM_COUNT::AUTO` votes between three methods with a hard-coded 3 000-symbol tolerance; goblin reconciles the hash-derived count against `max(r_sym)`. Two correct-looking tools can report different symbol counts for the same file.
- **`Strtab`'s `Index` impl panics on an invalid offset or invalid UTF-8** — the ergonomic accessor is the unsafe-for-hostile-input one.
- **Zero closure.** The description is never in the artifact, so a `.ksy`/`.dfdl.xsd`/library and the format it describes drift independently, with nothing detecting the drift.
- **The abstraction layer is an intersection, not a union.** `LIEF::Binary` gives you what ELF, PE and Mach-O share; everything interesting is on the concrete subclass.

---

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                     | Trade-off                                                                                                  |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Kaitai: format description as data (`.ksy`), compiled to N languages     | One description, thirteen readers; the description is reviewable, diffable, licensable        | Expression language is deliberately small; anything algorithmic (`.gnu.hash`) falls out of scope entirely  |
| Kaitai: `instances` lazy and memoized by default                         | Random access to large artifacts without a full parse                                         | Evaluation order becomes a correctness concern (`linked_section` _"may reference a later section header"_) |
| DFDL: annotate XML Schema rather than invent a syntax                    | Inherits XSD tooling and an XPath-based query surface; the infoset is a document, not objects | Inherits XSD's restrictions too — no recursion, no `xs:redefine`, no seek; record-oriented data only       |
| DFDL: `dfdl:outputValueCalc` for derived fields                          | The unparser maintains length prefixes and checksums; writes stay consistent by construction  | Only meaningful for formats DFDL can describe at all, which excludes offset-graph binaries                 |
| LIEF: one mutable object graph + `Builder` rebuild                       | Makes `patchelf`-class edits expressible in three languages across three formats              | Every derived index must be rebuilt by hand-written code; rebuild is per-index opt-out and not idempotent  |
| LIEF: `DYNSYM_COUNT` as user-facing configuration                        | Honest about ELF not recording the count; lets the caller trade accuracy for reliability      | `SELECT count(*)` becomes an application decision, and two tools can legitimately disagree                 |
| goblin: borrow the input (`Elf<'a>`), `no_std` by feature                | Zero allocation, usable in kernels/bootloaders; a parse costs a header walk                   | Lifetimes propagate into every consumer; `Strtab`'s `Index` panics rather than erring                      |
| goblin: eager denormalization in `Elf::parse` (`libraries`, `soname`, …) | The common query is answered before the caller asks; `lazy_parse` exists for the rest         | Pays every join up front even for callers that only wanted `e_entry`                                       |
| goblin: 16-byte ordered prefix sniff (`Hint`)                            | Cheap, allocation-free format detection                                                       | Collapses polyglots to one answer; the ordering itself is a differential surface                           |
| pyelftools: vendored `construct` for layout, hand-written semantics      | Declarative where declarative works, Python where it does not                                 | Carries an abandoned dependency fork; the seam between the two halves is invisible to users                |
| pyelftools: `@cached_property _section_name_map`                         | ELF has no name index; build one lazily in memory, once                                       | The index is per-process and discarded at close — rebuilt by every tool, every run                         |

---

## Where this sits in the catalog

- It is the **read side** of [`sqlelf`][sqlelf] and, transitively, of the argument [SELF/selfdb][self] makes: everything `sqlelf` exposes as a virtual table is something LIEF already computed imperatively.
- It supplies the concrete evidence for [thesis 1][concepts] — see the section above — and is the clearest statement of [thesis 2][concepts]'s negative case: when a format does not carry its schema, the schema becomes somebody else's repository.
- It is the tooling that reads what [dynamic linking][linking] writes: `DT_NEEDED`, `DT_RUNPATH`, `.gnu.hash` and `.dynstr` are the four structures every subject here spends most of its ELF code on.
- Its sniff-then-commit dispatch is one of the mechanisms [parser differentials][differentials] exploit, and its inability to represent superposition is why [polyglot craft][polyglot] is a hand tool rather than a library call.
- [Code-as-database systems][code-db] (CodeQL, Glean, Kythe) are the same move applied to source rather than to binaries — ingest once, query relationally — and reach the same conclusion about the value of a general query surface.
- [Debug info and indexes][debug] is the adjacent case where the _artifact itself_ carries the index (`.debug_names`, `.gdb_index`), which is what these libraries would prefer ELF did everywhere.
- The [Wasm component model][wasm] is the counterexample from the future: a binary interface designed as a typed graph from the start, where the format-to-query layer has much less to reconstruct.

---

## Sources

- [lief-project/LIEF — repository at `4c9c42c4`][lief-repo]; [`include/LIEF/ELF/ParserConfig.hpp` — `DYNSYM_COUNT`][lief-parsercfg]; [`src/ELF/Parser.tcc` — the three counting methods and the `AUTO` vote][lief-parser]; [`include/LIEF/ELF/Parser.hpp` — `NB_MAX_SYMBOLS` / `DELTA_NB_SYMBOLS`][lief-parserh]; [`include/LIEF/ELF/Builder.hpp` — `config_t` rebuild flags][lief-builder]; [`include/LIEF/ELF/GnuHash.hpp` — "re-computed by the Builder"][lief-gnuhash]; [`include/LIEF/Abstract/Binary.hpp` — the cross-format facade][lief-abstract]; [`doc/sphinx/intro.md`][lief-intro]; [`doc/sphinx/runtime/intro.md`][lief-runtime]; [`doc/sphinx/changelog.md`][lief-changelog]
- [m4b/goblin — repository at `dca2e753`][goblin-repo]; [`src/lib.rs` — `Hint`, `peek_bytes`, `Object::parse`][goblin-lib]; [`src/elf/mod.rs` — `Elf::parse`, `gnu_hash_len`, denormalized fields][goblin-elf]; [`src/elf/gnu_hash.rs` — bloom filter and chain walk][goblin-gnuhash]; [`src/strtab.rs` — borrowed string table, panicking `Index`][goblin-strtab]; [`README.md`][goblin-readme]; [docs.rs/goblin][goblin-docs]
- [eliben/pyelftools — repository at `e5fa2a4f`][pyelftools-repo]; [`elftools/elf/hash.py` — `GNUHashTable`][pyelftools-hash]; [`elftools/elf/structs.py` — the `construct` declarations][pyelftools-structs]; [`elftools/elf/elffile.py` — `num_sections`, `_section_name_map`, linked-section helpers][pyelftools-elffile]; [`elftools/elf/sections.py` — `StringTableSection`][pyelftools-sections]; [`elftools/construct/README` — why the fork is vendored][pyelftools-construct]; [user guide][pyelftools-guide]
- [kaitai-io/kaitai_struct — umbrella repository at `95983d00`][ks-repo]; [`kaitai_struct_formats/executable/elf.ksy` at `ccad5db7`][ksf-elf]; [`kaitai_struct_compiler` at `fd259425` — `build.sbt` (`0.12-SNAPSHOT`), `RELEASE_NOTES.md` (`0.11`, 2025-09-07), GPLv3 `LICENSE`][ksc-repo]; [Kaitai Struct User Guide][ks-guide]; [Kaitai Struct Serialization Guide][ks-serialization]; [kaitai.io — licensing][ks-site]
- [Data Format Description Language (DFDL) v1.0 Specification, OGF GFD-R-P.240, February 2021 (updated June 2023)][dfdl-ogf]
- [Apache Daffodil][daffodil-site]; [apache/daffodil at `d902f944` — `README.md`][daffodil-readme]
- [fzakaria/sqlelf at `a87e97c1` — `pyproject.toml` (LIEF pin) and `sqlelf/lief_ext.py`][sqlelf-pyproject]
- [System V gABI, §4 Sections — `sh_link` semantics][gabi-shdr]
- Related in this tree: [sqlelf][sqlelf] · [SELF / selfdb][self] · [Dynamic linking][linking] · [Parser differentials][differentials] · [Polyglot craft][polyglot] · [Code as a database][code-db] · [Debug info and indexes][debug] · [Wasm component model][wasm] · [Concepts and theses][concepts] · [Comparison][comparison] · [Catalog index][index]

<!-- References -->

[lief-repo]: https://github.com/lief-project/LIEF/tree/4c9c42c483096bd3d6d8b36758671f2dc52c524b
[lief-parsercfg]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/include/LIEF/ELF/ParserConfig.hpp
[lief-parser]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/src/ELF/Parser.tcc
[lief-parserh]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/include/LIEF/ELF/Parser.hpp
[lief-builder]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/include/LIEF/ELF/Builder.hpp
[lief-gnuhash]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/include/LIEF/ELF/GnuHash.hpp
[lief-abstract]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/include/LIEF/Abstract/Binary.hpp
[lief-intro]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/doc/sphinx/intro.md
[lief-runtime]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/doc/sphinx/runtime/intro.md
[lief-changelog]: https://github.com/lief-project/LIEF/blob/4c9c42c483096bd3d6d8b36758671f2dc52c524b/doc/sphinx/changelog.md
[lief-docs]: https://lief.re/doc/latest/index.html
[goblin-repo]: https://github.com/m4b/goblin/tree/dca2e753b2abb66a38f42bcb245cf7232049e69e
[goblin-lib]: https://github.com/m4b/goblin/blob/dca2e753b2abb66a38f42bcb245cf7232049e69e/src/lib.rs
[goblin-elf]: https://github.com/m4b/goblin/blob/dca2e753b2abb66a38f42bcb245cf7232049e69e/src/elf/mod.rs
[goblin-gnuhash]: https://github.com/m4b/goblin/blob/dca2e753b2abb66a38f42bcb245cf7232049e69e/src/elf/gnu_hash.rs
[goblin-strtab]: https://github.com/m4b/goblin/blob/dca2e753b2abb66a38f42bcb245cf7232049e69e/src/strtab.rs
[goblin-readme]: https://github.com/m4b/goblin/blob/dca2e753b2abb66a38f42bcb245cf7232049e69e/README.md
[goblin-docs]: https://docs.rs/goblin/
[pyelftools-repo]: https://github.com/eliben/pyelftools/tree/e5fa2a4f3e665d082cfc453fd0877f5516200926
[pyelftools-hash]: https://github.com/eliben/pyelftools/blob/e5fa2a4f3e665d082cfc453fd0877f5516200926/elftools/elf/hash.py
[pyelftools-structs]: https://github.com/eliben/pyelftools/blob/e5fa2a4f3e665d082cfc453fd0877f5516200926/elftools/elf/structs.py
[pyelftools-elffile]: https://github.com/eliben/pyelftools/blob/e5fa2a4f3e665d082cfc453fd0877f5516200926/elftools/elf/elffile.py
[pyelftools-sections]: https://github.com/eliben/pyelftools/blob/e5fa2a4f3e665d082cfc453fd0877f5516200926/elftools/elf/sections.py
[pyelftools-construct]: https://github.com/eliben/pyelftools/blob/e5fa2a4f3e665d082cfc453fd0877f5516200926/elftools/construct/README
[pyelftools-guide]: https://github.com/eliben/pyelftools/blob/e5fa2a4f3e665d082cfc453fd0877f5516200926/README.md
[ks-repo]: https://github.com/kaitai-io/kaitai_struct/tree/95983d00dce9e526c4951c4d15c2a5a6d28e0941
[ksf-repo]: https://github.com/kaitai-io/kaitai_struct_formats/tree/ccad5db7b39174e6857b8cea61c4c39f8ea39af3
[ksf-elf]: https://github.com/kaitai-io/kaitai_struct_formats/blob/ccad5db7b39174e6857b8cea61c4c39f8ea39af3/executable/elf.ksy
[ksc-repo]: https://github.com/kaitai-io/kaitai_struct_compiler/tree/fd2594257834241455f27121ae1adf296bcf09b9
[ks-site]: https://kaitai.io/
[ks-docs]: https://doc.kaitai.io/
[ks-guide]: https://doc.kaitai.io/user_guide.html
[ks-serialization]: https://doc.kaitai.io/serialization.html
[dfdl-ogf]: https://www.ogf.org/documents/GFD.240.pdf
[daffodil-repo]: https://github.com/apache/daffodil/tree/d902f94427ac45796b501586e33ef71134f4ca0b
[daffodil-readme]: https://github.com/apache/daffodil/blob/d902f94427ac45796b501586e33ef71134f4ca0b/README.md
[daffodil-site]: https://daffodil.apache.org/
[sqlelf-pyproject]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/pyproject.toml
[gabi-shdr]: https://refspecs.linuxfoundation.org/elf/gabi4+/ch4.sheader.html
[sqlelf]: ./sqlelf.md
[self]: ./self-selfdb/index.md
[linking]: ./dynamic-linking.md
[differentials]: ./parser-differentials.md
[polyglot]: ./polyglot-craft.md
[code-db]: ./code-as-database.md
[debug]: ./debug-info-and-indexes.md
[wasm]: ./wasm-component-model.md
[ape]: ./cosmopolitan-ape/index.md
[ranges]: ./range-request-access.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
