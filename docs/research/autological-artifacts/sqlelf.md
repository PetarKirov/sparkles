# sqlelf (ELF tooling / SQL query layer)

A read-only SQL query surface over unmodified ELF objects, built from [LIEF][lief] parses fed through [SQLite's virtual-table mechanism][vtab] — the precursor experiment to [SELF][self], and its exact design opposite: bolt a query layer onto the format instead of replacing the format with a query engine.

| Field           | Value                                                                                                |
| --------------- | ---------------------------------------------------------------------------------------------------- |
| Kind            | Tool (CLI + Python library) — a query layer, not a format                                            |
| Language        | Python (`>=3.10,<4.0`), over C/C++ parsers (`lief`, `capstone`, `apsw`)                              |
| License         | MIT                                                                                                  |
| Repository      | [fzakaria/sqlelf][repo]                                                                              |
| Documentation   | [README][readme] · [PyPI][pypi] · paper: [arXiv:2405.03883][paper]                                   |
| First release   | First commit 2023-03-09; PyPI `0.1` 2023-09-23; paper submitted 2024-05-06                           |
| Axis profile    | Multiplicity 0 / Reflexivity 2 / Closure 1 / Mutability 0                                            |
| Index anchoring | Out-of-band (a separate in-memory SQLite database; the ELF's own header-anchored index is discarded) |
| Dispatch owner  | Kernel, unchanged — `binfmt_elf` still owns the file; sqlelf is never a dispatch participant         |

> **Latest release / revision surveyed:** PyPI `0.5` (2024-07-19); repository read at commit `a87e97c1` (2024-08-03, the tip at time of writing). **Platform:** Linux/ELF; the disassembly and relocation paths handle only `x86_64` and RISC-V (see [Weaknesses](#weaknesses)).

---

## Overview

### What it solves

Every fact in an ELF file is already relational — a symbol has a name, a section index, a size, a binding; a `.dynamic` entry has a tag and a value; a relocation names a symbol and a section. The classical tools (`readelf`, `nm`, `objdump`) render those relations as **formatted text, one file at a time**, so any question that spans two relations or two files becomes a shell pipeline plus a regex plus a scratch data structure. sqlelf's claim is that the pipeline is an accident of the output format, not of the data.

Concretely, the questions sqlelf makes trivial are the ones `binutils` makes hardest:

| Question                                                              | Classical answer                                              | sqlelf answer                                                                                |
| --------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Which library exports the symbol this binary imports?                 | `nm -D` both files, sort, `comm`, or a script                 | self-join of `elf_symbols` on `name` with `imported = TRUE` / `exported = TRUE`              |
| Is any symbol exported by two objects in this closure?                | ad-hoc distro scripts over the cross-product of libraries     | `GROUP BY name, version HAVING count(*) >= 2`                                                |
| What are the `DT_NEEDED` entries, as strings?                         | `readelf -d`, which resolves `d_val` into `.dynstr` for you   | `JOIN elf_strings ON elf_dynamic_entries.value = elf_strings.offset` — the join done by hand |
| Which instructions belong to symbol `read_builtin`?                   | `objdump -d`, then find the label, then eyeball               | `JOIN` of `elf_instructions` and `elf_symbols` on an address-range predicate                 |
| What is the distribution of symbol counts over 1,600 installed files? | a script that shells out 1,600 times and parses 1,600 outputs | one query against a database built from a directory argument                                 |

The paper frames this as a systems-administration problem rather than a reverse-engineering one: administrators "lack the tools necessary to analyze" their systems, and therefore "rely on their own manually written, ad-hoc scripts … These scripts, while critical, are easy to get wrong" ([§1][paper]). The One Definition Rule violation that a distribution discovers only at runtime is the canonical example, and it is exactly a `GROUP BY … HAVING count(*) >= 2`.

### Design philosophy

The repository states the thesis in one line ([`README.md`][readme]):

> _"`SQL` is the \_lingua franca_ for asking questions in a declarative manner. Let's enhance our ability to introspect binaries!"\_

The paper's version is sharper, and it is the sentence this catalog cares about ([§3, Data Model][paper]):

> _"The usefulness of a declarative language is bounded by the data model upon which it's exercised. A key insight is that there exists a data-model that is isomorphic to the current-day binary formats. The simplest way in which to demonstrate this equivalence is to imitate this domain model when building the corresponding relational data model."_

Two commitments follow from "isomorphic," and they are what separate sqlelf from [SELF][self]:

1. **The mapping is a projection, not a representation change.** The bytes on disk stay ELF; the relational model is derived at query time and thrown away at process exit. The paper is explicit that a "nearly identical analogue of the schema could be used to match the underlying file format," and that augmentations "are only paid for at query time."
2. **Where the isomorphism is inconvenient, the model diverges.** The data model "largely mirrors the structure of ELF, diverging only in instances where the existing ELF structure hampers analysis" — `exported` and `imported` become plain boolean columns rather than the multi-clause predicate over `st_shndx`, `st_info` and `st_value` that the ELF gABI actually specifies, and `elf_strings` exists purely so that `DT_RUNPATH`'s offset-into-`.dynstr` can be resolved by a `JOIN` instead of by `SUBSTR`/`INSTR` byte surgery over a `BLOB`.

The author later described sqlelf as a way-station: SELF began as "an end result of that exploration," and "I knew however that there is still something much bigger to be done" ([_Your executable is a SQLite database_][blog-self]). That is the design axis this page exists to sharpen — see [Query surface bolted on vs. query surface as storage](#query-surface-bolted-on-vs-query-surface-as-storage).

---

## How it works

The whole tool is roughly 1,100 lines of Python across four modules plus a vendored copy of `pyelftools`. The pipeline is: **LIEF parses each file eagerly → a Python generator per table → `apsw` turns each generator into an eponymous virtual table → optionally, `CREATE TABLE … AS SELECT` materializes it and `CREATE INDEX` indexes it.**

### 1. Eager parse, one `Binary` per file

`sqlelf.lief_ext.Binary` is a proxy that pairs a `lief.ELF.Binary` with the path it came from, because LIEF removed the `name` attribute ([`lief_ext.py`][lief_ext]):

```python
# sqlelf/lief_ext.py
class Binary(base):
    def __init__(self, path: str):
        self.path = path
        self.__binary: Optional[lief.ELF.Binary] = lief.ELF.parse(path)
```

`make_sql_engine` constructs one of these per input file, filtered by `lief.is_elf`, **before any query runs** ([`sql.py`][sql]). There is no lazy open, no partial read, and no memory-mapped access path: the parse is the price of admission.

### 2. A generator per table

Each table is a closure over the binary list that `yield`s dictionaries, wrapped in a `Generator` dataclass carrying the column names and an `apsw.ext.VTColumnAccess` ([`elf.py`][elf]):

```python
# sqlelf/elf.py — the .dynamic table, in full
def dynamic_entries_generator() -> Iterator[dict[str, Any]]:
    for binary in binaries:
        binary_name = binary.path
        for entry in binary.dynamic_entries:
            yield {"path": binary_name,
                   "tag": entry.tag.__name__,
                   "value": entry.value}
```

`path` is the first column of **every** table and is the de facto foreign key joining them all; there is no object identifier, no interning, and no per-object row.

### 3. `apsw.ext.make_virtual_module` — the seam

`register_generator` hands the generator to [`apsw.ext.make_virtual_module`][apsw-ext], which "[r]egisters a **read-only** virtual table module … based on `callable`." Two properties of that seam determine everything downstream:

- **It is read-only.** No `xUpdate`; there is no path from SQL back to the file. sqlelf can never be `patchelf`.
- **It has no query-plan participation beyond hidden parameters.** The generator is re-run from the top for every scan. SQLite's own documentation is explicit that "[o]ne cannot create additional indices on a virtual table … Indices cannot be added separately using `CREATE INDEX` statements" ([The Virtual Table Mechanism Of SQLite][vtab]).

### 4. Memoization: `CacheFlag`, CTAS, and hand-built indexes

Because a virtual table cannot be indexed, sqlelf's answer is to copy it into a real one. `register_generator` renames the virtual table to `raw_<name>` and materializes the real name from it ([`elf.py:89`][elf-register]):

```python
# sqlelf/elf.py — register_generator
apsw.ext.make_virtual_module(connection, table_name, generator)
if generator_flag in cache_flags:
    connection.execute(f"""CREATE TABLE {original_table_name}
        AS SELECT * FROM {table_name};""")
```

and then adds exactly the indexes the intended queries need:

```python
# sqlelf/elf.py — after materializing elf_symbols / elf_strings
CREATE INDEX elf_symbols_path_idx ON elf_symbols (path);
CREATE INDEX elf_symbols_name_idx ON elf_symbols (name);
CREATE INDEX elf_strings_offset_idx ON elf_strings (offset);
CREATE INDEX dwarf_debug_lines_cu_offset_idx ON dwarf_debug_lines (cu_offset);
```

Which tables get this treatment is a CLI-visible knob: `--cache-flag` takes a comma-separated list of `CacheFlag` members (`SYMBOLS`, `INSTRUCTIONS`, `DWARF_DIE`, …) and defaults to `ALL`. The paper calls the trade explicitly: it "allows them to balance startup time with the runtime of their repeated queries." An un-memoized table is still queryable — it stays reachable as an _eponymous_ virtual table, so nothing disappears from the SQL surface, only from `sqlite_schema`.

> [!NOTE]
> This is directly observable. With `--cache-flag SYMBOLS,HEADERS,DYNAMIC_ENTRIES,STRINGS`, `SELECT name FROM sqlite_schema WHERE type='table'` returns exactly those four tables, yet `SELECT count(*) FROM elf_sections` still answers (32, for the surveyed `git`) — the eponymous module is not in the schema table but is in the name resolver.

### 5. The schema

Twelve generators are registered unconditionally ([`elf.py:810`][elf-register-all]); the columns below are read off the generator definitions, not from documentation:

| Table                      | Columns                                                                                                 | Source                                               |
| -------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `elf_headers`              | `path`, `type`, `machine`, `version`, `entry`, `is_pie`                                                 | LIEF `binary.header`                                 |
| `elf_sections`             | `path`, `name`, `offset`, `size`, `type`, `content` (`BLOB`)                                            | LIEF sections; parse failures are logged and skipped |
| `elf_symbols`              | `path`, `name`, `demangled_name`, `imported`, `exported`, `section`, `size`, `version`, `type`, `value` | merged `.dynsym` + `.symtab`, see below              |
| `elf_dynamic_entries`      | `path`, `tag`, `value`                                                                                  | LIEF `binary.dynamic_entries`                        |
| `elf_relocations`          | `path`, `addend`, `info`, `is_rela`, `purpose`, `section`, `symbol`, `symbol_table`, `type`             | LIEF relocations                                     |
| `elf_strings`              | `path`, `section`, `value`, `offset`                                                                    | every `SHT_STRTAB`, split on `NUL`                   |
| `elf_instructions`         | `path`, `section`, `mnemonic`, `address`, `operands`, `size`                                            | `capstone.disasm_lite` over `SHF_EXECINSTR` sections |
| `elf_version_requirements` | `path`, `file`, `name`                                                                                  | `.gnu.version_r`                                     |
| `elf_version_definitions`  | `path`, `name`, `flags`                                                                                 | `.gnu.version_d`                                     |
| `dwarf_dies`               | `path`, `tag`, `name`, `low_pc`, `high_pc`, `offset`, `size`, `cu_offset`                               | vendored `pyelftools`, file re-opened                |
| `dwarf_dies_graph`         | `path`, `parent_offset`, `child_offset`                                                                 | DIE parent/child edges                               |
| `dwarf_debug_lines`        | `path`, `filename`, `address`, `line`, `column`, `cu_offset`                                            | line program entries                                 |

Two modelling decisions in that table are load-bearing and easy to miss.

**`elf_symbols` is a union, not a table.** `symbols()` concatenates the dynamic symbol table with the static one, dropping any static symbol whose _name_ already appears in `.dynsym`, "because the static symbol table will not include version information" ([`elf.py:791`][elf-symbols]). The row count is therefore not the number of symbol-table entries: for the surveyed `git`, `readelf -sW` yields 9,616 entries (9,351 `.symtab` + 265 `.dynsym`) while `SELECT count(*) FROM elf_symbols` returns 9,593 — the 23-row gap is the name-based dedup. Nothing is wrong; the table is simply a _derived view over two tables_, presented as one, and a query that counts it is not counting ELF.

**There is no segments table.** Grep the source: the string `segment` does not occur in any module. sqlelf models ELF's **linking view** (sections, symbols, relocations, strings) and ignores its **execution view** entirely, even though the paper devotes §2.1 to the duality and concludes that "[s]egments need no further lifting as they remain identically unstructured within the ELF file and serve only to be a region of contiguous memory which can easily be `mmap` into process address space." That sentence is the fork in the road: for sqlelf, segments are uninteresting because nothing is going to load this file. For [SELF][self], the `segments` table _is_ the executable.

### 6. `--recursive`: the closure comes from outside SQL

The one genuinely transitive operation sqlelf offers is not a query. `find_libraries` runs the binary's own `PT_INTERP` with `--list` and scrapes the output ([`sql.py:55`][sql-find]):

```python
# sqlelf/sql.py
interpreter_cmd = sh.Command(interpreter)
resolution = interpreter_cmd("--list", binary.path)
...
m = re.match(r"\s*([^ ]+) => ([^ ]+)", line)
```

The results are then `realpath`'d and pushed through `set()` before becoming more `Binary` objects. Running `sqlelf --recursive` over the surveyed `git` logs the shell-out verbatim:

```text
INFO [sh.py:579] <Command '…/ld-linux-x86-64.so.2 --list …/bin/git', pid 3363107>: process started
```

Two consequences. First, the dependency **closure** is computed by the dynamic loader, in another process, by a regex over its stdout — the very "ad-hoc script" the paper's introduction indicts. Second, `set()` **destroys load order**, which is the only thing that determines which of two duplicate symbols actually wins. sqlelf can prove that an interposition _exists_; it structurally cannot say who _loses_. See [Reflexivity and query surface](#the-transitive-queries-are-the-valuable-ones-and-sql-is-where-they-go-to-die).

### 7. Persistence and aggregation

`SQLEngine.dump` uses SQLite's [backup API][backup] to write the in-memory database to a file, at which point every SQLite tool in the world applies — the paper ships a whole Debian 12.0 snapshot as one `.sqlite` and browses it with [Datasette][datasette]. `sqlelf-merge` then `ATTACH`es N such files and rebuilds each `elf_*`/`dwarf_*` table as a `UNION ALL` ([`merge.py`][merge]). There is no dedup, no content addressing, and no conflict handling: rows from two snapshots of the same path simply coexist.

---

## Format identity and multiplicity

**Multiplicity: 0 — and that is the finding, not an omission.** sqlelf writes nothing. The input remains an ordinary ELF object satisfying exactly one parse, dispatched by exactly one loader. Every other subject in this catalog earns its multiplicity score by making one byte stream answer to several parsers; sqlelf deliberately declines to touch the stream at all. It is included here as the **control case**: it demonstrates that the reflexivity thesis — "a binary should be interrogable through a general query surface" — is fully separable from format superposition. You can have the query surface with zero polyglot cleverness, at the cost enumerated below.

Where multiplicity does appear, it appears in the _derived_ artifact. `sqlelf … --sql ".dump /tmp/nix.sqlite"` produces a second file that is an ordinary SQLite database, and `file(1)` identifies it as such. That file has none of the original's executability and all of its metadata: the pair (ELF, SQLite) is a **two-file split of one artifact's identity**, and the whole of [SELF][self] is the observation that the split is unnecessary because SQLite's own header reserves an `application_id` field at byte offset 68 precisely so a database can also declare itself something else ([SQLite file format §1.3][fileformat]).

The ELF side does carry a multiplicity of its own, and sqlelf takes only half of it. ELF is a genuinely dual format — the section table for linkers, the program header table for loaders, with a many-to-one mapping between them. sqlelf's schema is the linking view; `readelf -l` has no SQL analogue here. The catalog's [prefix-/suffix-tolerance taxonomy][polyglot] is therefore untestable against sqlelf: it never asks what unknown bytes mean, because it never writes any.

## Index anchoring and random access

ELF is **header-anchored**: `e_shoff`/`e_phoff` at fixed offsets in the first 64 bytes locate both tables, and `DT_HASH`/`DT_GNU_HASH` provide the loader with O(1) symbol lookup — an on-disk hash table and Bloom filter maintained by the linker, which the paper correctly identifies as ELF "embedding additional data structures within the file format itself, purely by convention."

sqlelf **throws all of that away and rebuilds it.** No sqlelf code path consults `.gnu.hash`; symbol lookup goes through LIEF's flat sequence, into Python dicts, into SQLite rows, and then into `CREATE INDEX elf_symbols_name_idx` — a b-tree built at startup that answers exactly the question the Bloom filter in the file already answers. The index therefore lives **out-of-band**, in a second data structure in a second process's heap, with a lifetime shorter than the query session unless the user explicitly dumps it.

This is the cleanest available evidence for the catalog's thesis 1 (_every binary format eventually reimplements a database, badly_) and simultaneously its most awkward counter-example: sqlelf does not replace ELF's hand-rolled database with a real one, it **stacks a real one on top**, so the system now pays for both. SELF's move — delete `.gnu.hash`, let the b-tree be the index — is what thesis 1 actually implies. sqlelf is thesis 1 diagnosed but not treated.

Random access is correspondingly absent:

| Property                     | sqlelf                                                                                                                                                                                          |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Partial read                 | None. `lief.ELF.parse(path)` runs on every input file before any query.                                                                                                                         |
| Ranged / remote consumption  | None. Compare [range-request access][range] — SQLite's page-oriented reads make this natural for a SELF file and impossible for sqlelf's pipeline, which needs the whole ELF in a parser first. |
| Cost of the first query      | Whole-file parse + generator run + CTAS + index build.                                                                                                                                          |
| Cost of the thousandth query | An indexed b-tree probe, if memoized; a full generator re-run, if not.                                                                                                                          |

**Measured** (single x86-64 host, the `sqlelf` executable built from `a87e97c1` and invoked directly — not through a `nix run` wrapper — best of three runs; target `git` 2.51.2, 4,543,256 bytes, 9.6k symbols, 743,675 instructions):

| Invocation                                                        | Wall time | Max RSS |
| ----------------------------------------------------------------- | --------: | ------: |
| `--cache-flag NONE --sql "SELECT 1;"` (parse + register)          |    0.17 s |  ~52 MB |
| `--cache-flag SYMBOLS --sql "SELECT count(*) FROM elf_symbols;"`  |    0.24 s |  ~58 MB |
| `--cache-flag ALL --sql "SELECT count(*) FROM elf_instructions;"` |    1.92 s | ~322 MB |
| `readelf -sW` piped to `grep -c` (the classical pipeline)         |   ~0.01 s |   small |

Two numbers deserve to be stated plainly. The fixed floor is **~0.17 s before any question is asked** — more than an order of magnitude above the entire `readelf` pipeline, which answers the whole question in ~0.01 s. And full memoization costs **~322 MB of RSS for a 4.5 MB input** — a ~70× blowup, because 743,675 disassembled instructions become 743,675 SQLite rows with six columns each. The paper's own evaluation reaches the same conclusion from the other direction: sub-second up to ~10<sup>4</sup> symbols, "the latency drastically increases" beyond ~10<sup>5</sup>, and the mitigation is to dump the database and let the C SQLite client query it instead of Python.

## Reflexivity and query surface

**Reflexivity: 2 (designed-in, but external and one-directional).** sqlelf gives ELF the general query surface the catalog is about — this is its entire reason to exist, which is why the score is not 1. It falls short of 3 on two counts that are structural, not incidental:

- **The artifact cannot interrogate itself.** The query surface lives in a separate Python process holding a private in-memory database. A running program cannot `SELECT` from its own image; there is no analogue of SELF's `sqlite3_open(argv[0], &db)` ([_Actually Queryable Executables_][blog-aqe]). Self-inspection at runtime is not merely unimplemented, it is precluded by the architecture: the database does not exist unless someone starts sqlelf.
- **The surface is read-only by construction**, per [`make_virtual_module`][apsw-ext]. Reflexivity here means _observation_, never _actuation_.

What the surface buys, concretely, is composition. Every one of these is a single statement in sqlelf and a script anywhere else:

```sql
-- symbol resolution: every (importer, exporter) pair across a loaded set
SELECT caller.path, callee.path, caller.name
FROM elf_symbols caller
INNER JOIN elf_symbols callee ON caller.name = callee.name
WHERE caller.path != callee.path
  AND caller.imported = TRUE AND callee.exported = TRUE;

-- duplicate/shadowed symbols: the One Definition Rule audit
SELECT name, version, count(*) AS symbol_count,
       GROUP_CONCAT(path, ':') AS libraries
FROM elf_symbols
WHERE exported = TRUE AND section != '.bss'
GROUP BY name, version
HAVING count(*) >= 2;
```

The second query is the paper's headline case study (§5.1.3) and is the thing distributions currently do with "one-off custom written scripts." The first is the loader's job expressed as a join — which is exactly the observation the catalog's [dynamic-linking][dynlink] page turns into a question about query planning.

Nothing about the surface is ELF-specific once the rows exist, which is why the paper's `auditwheel`, `elf_diff`, and musl-`count_syms` case studies all reduce to replacing imperative traversals with one query each; the `elf_diff` symbol extractor goes "from 59 lines to 28 lines," and the musl rewrite "expos[ed] a known bug in the GCC (compiler) toolchain that musl failed to account for" — the original `count_syms` counted `.dynsym` entries where the intent was _imported symbols_, a distinction the SQL states and the C did not. That last result is the strongest evidence in the paper that a declarative surface is not merely more convenient: it made a latent semantic error visible by forcing the intent into the text.

For the wider family of "expose a system as tables," see [relational system surfaces][relsurf] (osquery, Steampipe, Datasette); for the "expose _code_ as a database" tradition sqlelf sits beside, see [code as a database][codedb].

### The transitive queries are the valuable ones, and SQL is where they go to die

This is the catalog's open question — _SQL or Datalog?_ — and sqlelf is its best empirical exhibit, because it is a SQL system that **routes around SQL for every transitive problem it has**.

The evidence is in the source, not in an opinion:

1. **The dependency closure is not a query.** `--recursive` shells out to `ld.so --list` and regexes stdout ([`sql.py:55`][sql-find]). A `DT_NEEDED` closure is the textbook two-rule Datalog program; in sqlelf it is a subprocess.
2. **Load order, which the closure implies, is discarded.** `set()` on the resolved library paths ([`sql.py:113`][sql-set]) makes the fixed point unordered. Symbol resolution order — the actual question behind "which definition wins" — is therefore not merely hard to express; the model no longer contains the input.
3. **The only `WITH RECURSIVE` in the entire documented corpus splits a string.** The README's recursive CTE walks a colon-separated `DT_RUNPATH` value one character-index at a time, reproduced here against the surveyed binary:

   ```sql
   WITH RECURSIVE split(rpath, str) AS (
       SELECT '', elf_strings.value || ':'
       FROM elf_dynamic_entries
       INNER JOIN elf_strings ON elf_dynamic_entries.value = elf_strings.offset
       WHERE elf_dynamic_entries.tag = 'RUNPATH'
       UNION ALL
       SELECT substr(str, 0, instr(str, ':')), substr(str, instr(str, ':') + 1)
       FROM split WHERE str != ''
   ) SELECT rpath FROM split WHERE rpath != '';
   ```

   SQLite's recursion is being spent on **lexing**, because `DT_RUNPATH` is one un-normalized string, not a relation. The graph traversal that recursion exists for is nowhere in the file.

The ergonomic hostility is specific and citable, not a matter of taste. SQLite's recursive CTEs impose that the body "must be a compound select"; that a recursive `SELECT` must reference the CTE "exactly once" in its `FROM` and "must not appear anywhere else … including subqueries"; that all non-recursive selects must precede all recursive ones; and that recursive selects "may not use aggregate functions or window functions" ([Recursive CTEs][cte]). Cycle safety is the author's problem too — the documentation's own graph example notes that "`UNION` is used instead of `UNION ALL` to prevent the recursion from entering an infinite loop if the graph contains cycles," i.e. termination is achieved by a hand-chosen set operator rather than by the evaluator.

Datalog inverts every one of those constraints: transitive closure is two rules, the fixed point is the semantics rather than a queue you steer, cycles terminate by construction under set semantics, and stratified negation and aggregation are language features rather than prohibitions inside the recursive clause. It is not an accident that binary analysis reaches for it — [`ddisasm`][souffle] expresses disassembly itself as a Soufflé program (see [code as a database][codedb]).

The honest conclusion for this catalog: **sqlelf's value is concentrated in its non-recursive queries** — joins, aggregates, and cross-file `GROUP BY` — and its gaps are concentrated exactly where the recursion is. A Datalog front-end over the _same_ materialized tables is therefore a small experiment with a high expected yield, because the expensive half (parse → rows) is already built and already dumpable to a file any engine can read. That is the shape the [open questions][open] page should hold it in.

### One more leak: the untyped join

`d_val` in a `.dynamic` entry is a foreign key into `.dynstr` — untyped, maintained by convention, with the tag deciding whether the value is an offset at all. sqlelf's model reproduces the untypedness faithfully. The documented `DT_NEEDED` idiom joins on `elf_dynamic_entries.value = elf_strings.offset` **without constraining `elf_strings.section`**, but `elf_strings` contains every `SHT_STRTAB` in the file. Measured on the surveyed `git`: `.dynstr` holds 267 strings, `.strtab` 7,946, `.shstrtab` 28, and **17 offsets occur in more than one section**. The four `NEEDED` rows happen not to collide there, so the query returns the right answer — by luck, not by construction. A correct version must add `AND elf_strings.section = '.dynstr'`. The relational model inherited the hand-maintained foreign key instead of typing it; thesis 1 again, one layer up.

## Closure, dedup, and size model

**Closure: 1 (incidental).** sqlelf's artifact is the ELF file, which carries nothing: its dependencies are `DT_NEEDED` _names_, resolved at runtime against `DT_RUNPATH`, `ld.so.cache` and the default search path. sqlelf does not change that, and cannot. What it offers is closure **discovery** — `--recursive` materializes the resolved closure _into the database_, so a query can range over a program and everything it will actually load. That is a real capability (it is what makes the interposition audit meaningful at all) but it is a property of the session, not of the artifact.

The interesting closure story is one level up, at distribution scale:

- A directory argument (or `os.walk` over one) turns "every ELF in `/usr/bin`" into rows; the paper snapshots a **complete Debian 12.0 installation** into a single SQLite file and publishes it through [Datasette][datasette].
- `sqlelf-merge` composes such snapshots with `UNION ALL` per table ([`merge.py`][merge]) — **no dedup at all**. `path` is the only identity, so the same library present in two snapshots contributes two full sets of rows. There is no content addressing anywhere in the tool; contrast the [Nix store closure][nix] and [content-addressed chunking][cac] pages, where identity _is_ the hash and sharing falls out of it.
- Size in the database is dominated by whichever tables are memoized, and `elf_instructions` dwarfs the rest. The measured ~322 MB RSS for a 4.5 MB binary at `--cache-flag ALL` is the practical ceiling on "snapshot the whole distro with disassembly."

The comparison that matters for the catalog's size axis is with SELF, whose own numbers are ~2× ELF unstripped (15.5 → 56.0 KiB for `hello`, 41.1 → 95.9 MiB for `gdb`) and within 1% once the optional tables are `DELETE`d and `VACUUM`ed ([_Your executable is a SQLite database_][blog-self]). sqlelf's overhead is not comparable in kind: SELF pays ~2× **on disk, permanently, for a file you can still run**; sqlelf pays ~70× **in RAM, transiently, for a file that has not changed at all.** Whether one prefers a permanent doubling to a transient 70× is precisely the design choice this page is about.

## Mutability, dispatch, and trust

**Mutability: 0.** There is no write path. `make_virtual_module` produces read-only tables, no module implements `xUpdate`, and the file is opened by LIEF for parsing only. This is the cleanest single contrast with SELF, where "any tool that modifies an ELF file, like `strip`, can operate on the database within a transaction rather than performing fragile offset surgery: `strip` is a `DELETE` and `VACUUM`. `patchelf` is an `UPDATE`" ([_Your executable is a SQLite database_][blog-self]). sqlelf can _find_ what `patchelf` should change and cannot change it; the round trip goes back out to `patchelf`.

**Dispatch: unchanged.** No one dispatches on a sqlelf artifact, because there is no sqlelf artifact. The ELF is still claimed by the kernel's `binfmt_elf` handler at `execve` time; the dumped `.sqlite` is claimed by nothing and merely opened by tools that were told to. This is worth stating because it is the _other_ half of what SELF buys with its `application_id` + [`binfmt_misc`][binfmt] registration: not just a query surface, but a **new dispatch identity** for the same bytes. sqlelf demonstrates that the query surface is separable from the dispatch change; SELF demonstrates that fusing them is what turns `ldd` into a `JOIN` _inside the running process_.

Trust properties, honestly enumerated:

| Surface                    | Exposure                                                                                                                                                                                |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Parsing untrusted binaries | Three parsers in-process — LIEF (C++), Capstone (C), vendored `pyelftools` — over attacker-controlled bytes. Standard binary-analysis exposure; see [binary inspection libraries][bil]. |
| `--recursive`              | **Executes** the target's own `PT_INTERP` (`ld.so --list`) as a subprocess and parses its stdout. Analysing a hostile binary this way runs code chosen by that binary.                  |
| Failure mode               | Unsupported architectures raise `RuntimeError` and abort the whole session rather than degrading; see below.                                                                            |
| Integrity                  | None. No signature, no measurement, no reproducibility claim over the derived database. Nothing binds a dumped `.sqlite` to the ELF it came from — not even a build-id column.          |

That last row is a real gap for the catalog's [provenance][prov] and [threat model][threat] concerns. A whole-distribution snapshot published as a browsable database is, structurally, an _unattested_ claim about a filesystem; a `build-id` column joining `elf_headers` to `.note.gnu.build-id` would at least make the claim checkable. sqlelf has no notes table.

---

## Query surface bolted on vs. query surface as storage

This is the axis the catalog needs sqlelf for. Both systems have the same author and the same thesis; they differ in exactly one decision, and every other difference is downstream of it.

| Dimension                         | sqlelf (query layer over ELF)                                                                 | [SELF][self] (SQLite _is_ the format)                                                    |
| --------------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Adoption cost                     | `pip install`. Zero toolchain, loader, or kernel change.                                      | New format; `elf2self`; `binfmt_misc` registration; a `self-exec` interpreter.           |
| Ecosystem compatibility           | Total — the file is still ELF for every existing tool.                                        | Nil, until every consumer learns the format (though a SELF file _is_ a SQLite database). |
| Query availability                | Only when someone runs sqlelf, in another process.                                            | Always; a process can `sqlite3_open(argv[0])` and query itself.                          |
| Fixed cost per query session      | Full parse of every input (~0.17 s floor; ~1.9 s and ~322 MB fully memoized, measured above). | Zero — the rows already exist on disk; SQLite opens pages on demand.                     |
| Mutation                          | Impossible. Read-only virtual tables.                                                         | `strip` = `DELETE`+`VACUUM`; `patchelf` = `UPDATE`; transactional.                       |
| Where the index lives             | Out-of-band, rebuilt every session, alongside ELF's own unused `.gnu.hash`.                   | In the file; the b-tree _is_ the index. One index, not two.                              |
| Steady-state size                 | ELF size (unchanged) + a transient ~70× in RAM.                                               | ~2× ELF on disk, ~1% after stripping.                                                    |
| `mmap` / page sharing             | Unaffected — the file is never loaded from the database.                                      | The open problem: segment bytes are copied out of b-tree pages, so text is not shared.   |
| Dispatch identity                 | Unchanged (`binfmt_elf`).                                                                     | New (`binfmt_misc` on `application_id` = `SELF` at byte 68).                             |
| Failure mode of the query surface | The query is unavailable; the program still runs.                                             | If the query surface is broken, the program does not run.                                |

**What each buys.** sqlelf buys the _analytical_ half of reflexivity at essentially zero systemic risk: nothing can break, because nothing changed. That is why it produced publishable results — a Debian-wide snapshot, four case studies, a real musl bug — while a format change would still have been arguing for adoption. SELF buys the _operational_ half: mutation as transaction, self-inspection at runtime, and a single index instead of two. It pays for that by putting the query engine on the critical path of `execve`, and by surrendering demand-paged sharing, which is the catalog's thesis 4 and by common consent the harder of SELF's two open problems.

**What this says about thesis 3 (_the container is a tax_).** The author's framing is that "[w]hereas, redbean needs to include an archive format (ZIP), the database itself is the container" ([_Actually Queryable Executables_][blog-aqe]). sqlelf sharpens the claim by showing the tax is _bidirectional_: keeping ELF as the container means the query layer must be rebuilt from scratch on every session, and the file ends up carrying two indexes — its own hand-rolled hash tables, which sqlelf ignores, and SQLite's, which sqlelf builds. Both [redbean's ZIP][ape] and sqlelf's ephemeral b-trees are the same tax paid in different currencies. That is the strongest form of the thesis available from this subject, and it is evidence _for_ it.

---

## Strengths

- **Zero adoption risk.** No format change, no loader change, no kernel change, no build-system change. The file under analysis is untouched, so nothing downstream can break — the reason this design shipped, got packaged, and produced results while the more radical one was still an idea.
- **Genuinely better at the questions that span relations or files.** Symbol resolution as a self-join, One Definition Rule audits as `GROUP BY … HAVING`, address-range joins between `elf_symbols` and `elf_instructions`, whole-distribution aggregates — each replaces a script.
- **Declarative code exposes intent, and intent exposes bugs.** The musl `count_syms` rewrite surfaced a real discrepancy between what the C did (`count .dynsym`) and what it meant (`count imported symbols`).
- **The output is a first-class SQLite database.** `.dump` yields a file every SQLite tool can read — `sqlite3`, [Datasette][datasette], BI tools — and `sqlelf-merge` composes snapshots. Analysis products outlive the analysis session.
- **Explicit, measurable cost control.** `--cache-flag` is an honest startup-vs-repeat-query dial with observable effects (0.17 s / 0.24 s / 1.92 s across `NONE` / `SYMBOLS` / `ALL` on the surveyed binary).
- **The augmentations are well chosen.** `imported`/`exported` as booleans and `elf_strings` as a table remove exactly the two places where naive ELF modelling forces users into byte surgery.

## Weaknesses

- **A fixed per-session parse floor.** ~0.17 s before the first question, against ~0.01 s for a `readelf` pipeline that answers the simple question outright. The tool is built for repeated, exploratory querying and is a poor substitute for `readelf` in a script.
- **Memory blowup under memoization.** ~322 MB RSS for a 4.5 MB input at `--cache-flag ALL`, dominated by 743,675 instruction rows.
- **Transitive queries are outside SQL.** The closure is a subprocess (`ld.so --list` + regex), and `set()` discards load order, so symbol _resolution order_ is unanswerable. See [above](#the-transitive-queries-are-the-valuable-ones-and-sql-is-where-they-go-to-die).
- **No execution view.** No segments/program-header table at all, so nothing about loading, memory protection, or `PT_LOAD` layout is queryable.
- **Untyped joins are documented as idioms.** The `DT_NEEDED` recipe joins `elf_dynamic_entries.value` against _all_ string tables; 17 offsets are ambiguous in the single surveyed binary.
- **Architecture coverage is narrow and fails hard.** `arch()`/`mode()` support only `x86_64` and RISC-V; `relocation_type()` supports **only** `x86_64` — a RISC-V binary with `--cache-flag ALL` will raise on relocations. Verified: `--cache-flag ALL` on an i386 shared object aborts the session with `RuntimeError: Unknown machine type`, rather than leaving that one table empty.
- **Read-only.** Every mutation must leave the tool.
- **Python is the ceiling.** The paper's own remedy for large binaries is to dump the database and query it from C, which concedes the point; the author notes that at Google-scale statically-linked binaries (>10<sup>6</sup> symbols) even building the memoized database is prohibitive.
- **Maintenance has stalled.** Last release `0.5` (2024-07-19), last commit 2024-08-03, `lief` pinned to `==0.14.1` "[because] lief has proven to change API a lot." The README still links `./tools/docker2sqlelf`, a path that does not exist at the surveyed commit.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                  | Trade-off                                                                                                    |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Query layer over the format, not a new format                      | Zero adoption cost; every existing tool still works; ships today                           | The query surface is never available to the artifact itself, and must be rebuilt per session                 |
| SQLite virtual tables via `apsw.ext.make_virtual_module`           | Turns a Python generator into a table in three lines; pay only for tables you query        | Read-only; no `xBestIndex` participation, so every scan re-runs the generator from the top                   |
| Optional CTAS memoization + hand-built `CREATE INDEX`              | Virtual tables cannot be indexed ([SQLite docs][vtab]); materializing enables real b-trees | Startup cost and large RSS; the index duplicates work `.gnu.hash` already did in the file                    |
| `--cache-flag` as a user-facing dial                               | The right point on the startup/repeat-query curve is workload-specific                     | Another knob; the default `ALL` is the slowest and most memory-hungry setting                                |
| LIEF for ELF, vendored `pyelftools` for DWARF, Capstone for disasm | Each library is best-in-class at its own job                                               | Files are opened twice (LIEF, then `ELFFile` for DWARF); three parser attack surfaces; `lief` pinned exactly |
| `path` as the universal key                                        | Simple, human-meaningful, joins everything                                                 | No content addressing, no object identity, no dedup across merged snapshots                                  |
| Merge dynamic and static symbol tables into one `elf_symbols`      | Dynamic symbols carry version info the static table lacks; one table is easier to query    | Row count ≠ ELF symbol count (9,593 vs 9,616 measured); the provenance of a row is not a column              |
| `elf_strings` as a table, joined by offset                         | Turns `DT_RUNPATH` byte surgery into a `JOIN`                                              | Reproduces ELF's untyped foreign key: the join is under-determined across multiple string tables             |
| Elevate `imported`/`exported` into boolean columns                 | The gABI predicate is multi-clause and users get it wrong                                  | The model diverges from the format; the definition is now sqlelf's, not the spec's                           |
| No segments/program-header table                                   | Segments are "identically unstructured" and nothing here is going to load the file         | The entire execution view is unqueryable — precisely the half SELF needs                                     |
| Closure via `ld.so --list` rather than a recursive query           | The loader is the ground truth for resolution and search paths                             | Runs code from the analysed binary's interpreter; `set()` discards load order; the closure is not in SQL     |
| Read-only by construction                                          | An analysis tool that cannot corrupt its input is much easier to trust                     | Every mutation round-trips through `patchelf`/`strip`/`objcopy`; no transactional editing                    |

---

## Sources

- [fzakaria/sqlelf — GitHub repository][repo] (read at `a87e97c17550a0415a961fde0164352f171e7f52`, 2024-08-03)
- [`README.md` — thesis, ER schema, worked query catalogue][readme]
- [`sqlelf/elf.py` — the twelve generators, `CacheFlag`, memoization, index creation][elf]
- [`sqlelf/sql.py` — `SQLEngine`, `find_libraries`, `--recursive` closure][sql]
- [`sqlelf/lief_ext.py` — the LIEF `Binary` proxy][lief_ext]
- [`sqlelf/tools/merge.py` — `UNION ALL` snapshot merging][merge]
- [`pyproject.toml` — dependency pins (`lief==0.14.1`, `apsw`, `capstone`, `sh`)][pyproject]
- Farid Zakaria, Zheyuan Chen, Andrew Quinn, Thomas R. W. Scogland. **"sqlelf: a SQL-centric Approach to ELF Analysis."** arXiv:2405.03883 [cs.SE], submitted 2024-05-06. [Abstract and PDF][paper]
- [The Virtual Table Mechanism Of SQLite][vtab] — read-only modules, no `CREATE INDEX` on virtual tables
- [SQLite: WITH clause / recursive CTEs][cte] — the restriction list quoted above
- [SQLite Database File Format §1.3 — the `application_id` header field][fileformat]
- [`apsw.ext.make_virtual_module` documentation][apsw-ext]
- [LIEF documentation][lief] · [Capstone][capstone] · [Datasette][datasette]
- Farid Zakaria, ["Your executable is a SQLite database"][blog-self] (2026-08-23) and ["Actually Queryable Executables"][blog-aqe] (2026-08-24)
- [ELF gABI — the dynamic section][gabi] · [`ld.so(8)`][ldso]
- Related in this catalog: [SELF / selfdb][self] · [code as a database][codedb] · [relational system surfaces][relsurf] · [binary inspection libraries][bil] · [dynamic linking][dynlink] · [debug info and indexes][debug] · [Cosmopolitan / APE][ape] · [SQLite as an application file format][sqlitefmt] · [measurement][meas] · [open questions][open] · [catalog index][index]

<!-- References -->

[repo]: https://github.com/fzakaria/sqlelf
[readme]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/README.md
[elf]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/elf.py
[elf-register]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/elf.py#L89
[elf-register-all]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/elf.py#L810
[elf-symbols]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/elf.py#L791
[sql]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/sql.py
[sql-find]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/sql.py#L55
[sql-set]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/sql.py#L113
[lief_ext]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/lief_ext.py
[merge]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/sqlelf/tools/merge.py
[pyproject]: https://github.com/fzakaria/sqlelf/blob/a87e97c17550a0415a961fde0164352f171e7f52/pyproject.toml
[pypi]: https://pypi.org/project/sqlelf/
[paper]: https://arxiv.org/abs/2405.03883
[vtab]: https://www.sqlite.org/vtab.html
[cte]: https://www.sqlite.org/lang_with.html
[fileformat]: https://www.sqlite.org/fileformat2.html
[backup]: https://www.sqlite.org/backup.html
[apsw-ext]: https://rogerbinns.github.io/apsw/ext.html
[lief]: https://lief.re/doc/stable/index.html
[capstone]: https://www.capstone-engine.org/
[datasette]: https://datasette.io/
[souffle]: https://souffle-lang.github.io/
[gabi]: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.dynamic.html
[ldso]: https://man7.org/linux/man-pages/man8/ld.so.8.html
[blog-self]: https://fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database
[blog-aqe]: https://fzakaria.com/2026/08/24/actually-queryable-executables
[self]: ./self-selfdb/index.md
[codedb]: ./code-as-database.md
[relsurf]: ./relational-system-surfaces.md
[bil]: ./binary-inspection-libraries.md
[dynlink]: ./dynamic-linking.md
[debug]: ./debug-info-and-indexes.md
[ape]: ./cosmopolitan-ape/index.md
[sqlitefmt]: ./sqlite-application-file-format.md
[binfmt]: ./binfmt-misc.md
[polyglot]: ./polyglot-craft.md
[range]: ./range-request-access.md
[nix]: ./nix-store-closures.md
[cac]: ./content-addressed-chunking.md
[prov]: ./embedded-provenance.md
[threat]: ./threat-model.md
[meas]: ./measurement.md
[open]: ./open-questions.md
[index]: ./index.md
