# The dynamic loader as a query engine (`ld.so` / glibc)

`ld.so` is the piece of infrastructure this catalog cannot avoid: an ELF executable does not carry its dependencies, it carries a _query_ for them, and every process start re-executes that query — a breadth-first graph walk, a set of ordered path probes, and a few thousand hash-indexed symbol joins — against a database that is the filesystem.

| Field           | Value                                                                                                 |
| --------------- | ----------------------------------------------------------------------------------------------------- |
| Kind            | Runtime facility (ELF program interpreter) + its out-of-band index (`ldconfig` / `/etc/ld.so.cache`)  |
| Language        | C (glibc `elf/`), with per-architecture assembly trampolines                                          |
| License         | LGPL-2.1-or-later                                                                                     |
| Repository      | [bminor/glibc][repo] (git mirror of `sourceware.org/git/glibc.git`)                                   |
| Documentation   | [`man 8 ld.so`][manldso] · [`man 7 rtld-audit`][manaudit] · [`man 8 ldconfig`][manldconfig]           |
| First release   | ELF dynamic linking in Linux: 1995 (glibc 2.0 era); `.gnu.hash` added 2006; `DT_RUNPATH` in SysV gABI |
| Axis profile    | Multiplicity 1 / Reflexivity 2 / Closure 1 / Mutability 1                                             |
| Index anchoring | Header-anchored (`PT_DYNAMIC` → `DT_*`), **plus** out-of-band (`/etc/ld.so.cache`)                    |
| Dispatch owner  | Loader                                                                                                |

> **Revision surveyed:** glibc `master` at commit `04e750e75b73957cf1c791535a3f4319534a52fc` (2026-01-20), i.e. post-2.43. **Platform:** Linux/glibc. Measurements taken on NixOS with glibc 2.42, x86-64. Where musl, FreeBSD `rtld-elf`, or the Solaris linker differ materially it is called out; they are not surveyed here.

---

## Overview

### What it solves

A dynamically linked ELF executable is radically _incomplete_. Its `PT_DYNAMIC` segment holds `DT_NEEDED` entries that are **strings, not references** — `libc.so.6`, not a path, not a hash, not a version. Resolving those strings into mapped objects, and then resolving each undefined symbol into an address inside one of them, is deferred to `ld.so`, the ELF _program interpreter_ named in `PT_INTERP`.

Two problems are being solved at once, and it is worth keeping them apart because the catalog's arguments attach to them differently:

1. **Object resolution** — turn `libfoo.so.1` into an open file descriptor. This is a _search_: an ordered list of candidate directories, probed with `openat(2)` until one hits. It is the part `RPATH`, `RUNPATH`, `LD_LIBRARY_PATH`, and `/etc/ld.so.cache` all argue about.
2. **Symbol resolution** — turn the undefined symbol `memcpy` referenced from object _A_ into a definition inside some object _B_ in _A_'s scope. This is a _join_: for each undefined symbol, scan an ordered list of link maps, probing each one's `.gnu.hash` table. It is the part `.gnu.hash`, `LD_PRELOAD`, symbol versioning, and lazy binding all argue about.

Both are re-executed, identically, on every `execve(2)` of the same binary against the same libraries. Nothing is memoized across processes. The only cache anywhere in the picture is `/etc/ld.so.cache`, and it caches only step 1 — and only the _name → path_ mapping, not the resolved closure.

### Design philosophy

The loader's own source is unusually explicit that it is walking a graph. From [`elf/dl-deps.c`][deps] (`_dl_map_object_deps`, the function that materializes an object's search list):

> _"Process each element of the search list, loading each of its auxiliary objects and immediate dependencies. Auxiliary objects will be added in the list before the object itself and dependencies will be appended to the list as we step through it. This produces a flat, ordered list that represents a breadth-first search of the dependency tree."_

That is the whole plan in one comment: a worklist BFS producing a **flat, ordered list**, where the ordering _is_ the semantics — it decides which definition of a duplicated symbol wins. The list is stored on the object as `l_searchlist.r_list` and consulted, linearly, for every symbol lookup thereafter.

The second philosophical commitment is that the query is answered late and answered fresh. `man 8 ld.so` states the object search order as a fixed rule set:

> _"Using the directories specified in the DT_RPATH dynamic section attribute of the binary if present and DT_RUNPATH attribute does not exist. … Using the environment variable LD_LIBRARY_PATH, unless the executable is being run in secure-execution mode … Using the directories specified in the DT_RUNPATH dynamic section attribute of the binary if present. … From the cache file /etc/ld.so.cache … In the default path /lib, and then /usr/lib."_

There is no provision in that rule set for "and if you already computed this yesterday, use that." The mechanism that _did_ provide it — `prelink` — is gone from glibc (see [Prelink: the materialized view that was withdrawn](#prelink-the-materialized-view-that-was-withdrawn)).

This page's argument is that the loader is best read as a **query engine with no plan cache**, that `ldconfig` is the one **materialized view** anybody bothered to build, and that the interesting open design space — occupied by `prelink`, [`shrinkwrap`][shrinkwrap-repo], and MatR — is about moving more of the plan into the artifact under a schema that says when the plan is still valid.

---

## How it works

### The plan, in execution order

| Phase | Function (glibc)                                    | What it does                                                                      | Cost driver                       |
| ----- | --------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------- |
| 1     | `handle_preload_list` ([`elf/rtld.c`][rtld])        | Load `LD_PRELOAD` / `/etc/ld.so.preload` objects first                            | preload count                     |
| 2     | `_dl_map_object_deps` ([`elf/dl-deps.c`][deps])     | BFS over `DT_NEEDED`, producing the flat search list                              | object count                      |
| 2a    | `_dl_lookup_map` ([`elf/dl-load.c`][load])          | Memo: is an object with this `SONAME`/name already in this namespace?             | O(loaded objects)                 |
| 2b    | `_dl_map_new_object` ([`elf/dl-load.c`][load])      | The path search proper: `RPATH` → `LD_LIBRARY_PATH` → `RUNPATH` → cache → default | search-path length × object count |
| 3     | `_dl_relocate_object` ([`elf/dl-reloc.c`][reloc])   | Apply relocations; for each named one, call the lookup                            | relocation count                  |
| 3a    | `_dl_lookup_symbol_x` ([`elf/dl-lookup.c`][lookup]) | Scan the scope, per object probe `.gnu.hash`                                      | objects × named relocs            |
| 4     | `_dl_fixup` ([`elf/dl-runtime.c`][runtime])         | Lazy PLT binding: the same lookup, deferred to first call                         | called-function count             |

Phases 2 and 3 are the two joins. Phase 2 joins _names_ against _the filesystem_; phase 3 joins _symbols_ against _the loaded set_.

### `DT_NEEDED` and the breadth-first walk

`_dl_map_object_deps` seeds a worklist with the main map, appends the `LD_PRELOAD` objects immediately after it, then walks:

```c
/* elf/dl-deps.c — _dl_map_object_deps (abridged) */
preload (known, &nlist, map);                    /* the executable, first */
for (i = 0; i < npreloads; ++i)
  preload (known, &nlist, preloads[i]);          /* LD_PRELOAD, next */

for (runp = known; runp; )
  for (d = l->l_ld; d->d_tag != DT_NULL; ++d)
    if (d->d_tag == DT_NEEDED)
      {
        dep = _dl_map_object (l, strtab + d->d_un.d_val, …);
        if (! dep->l_reserved)   /* l_reserved is the visited bit */
          { /* append to tail; ++nlist; dep->l_reserved = 1; */ }
      }
```

Three properties matter downstream:

- **Duplicate suppression is by `link_map` identity, not by name.** `l_reserved` is the mark bit; the comment calls it exactly that (_"We use `l_reserved` as a mark bit to detect objects we have already put in the search list"_). The _name_-level deduplication happens one level down, in `_dl_lookup_map`, which walks the namespace's loaded-object chain and matches on either a recorded name or the object's `SONAME`. This is the behaviour [`shrinkwrap`][shrinkwrap-repo]'s README calls out as the reason it only works on glibc: _"In glibc the cache is keyed by the soname value on the shared object. That allows the first found libfoo.so at /some-fixed-path/libfoo.so to be used for the one which libbar.so depends on."_
- **The list is append-ordered, so the winner of a symbol collision is the shallowest, leftmost `DT_NEEDED`.** The executable is index 0; preloads come next; then dependencies in BFS order.
- **Initialization order is a _different_ list.** The same function builds `l_initfini` and passes it through `_dl_sort_maps`, so constructors run dependency-first while _lookups_ stay in BFS order. Two orderings over the same node set, computed in the same pass.

### `RPATH` vs `RUNPATH`: the search-order difference

Both tags hold a `:`-separated directory list in `.dynstr`. The difference is entirely in _who_ they apply to and _when_ they are consulted, and it is visible as a single `if` in [`elf/dl-load.c`][load]:

```c
/* elf/dl-load.c — _dl_map_new_object (abridged) */
if (loader == NULL || loader->l_info[DT_RUNPATH] == NULL)
  {
    /* First try the DT_RPATH of the dependent object that caused NAME
       to be loaded.  Then that object's dependent, and on up.  */
    for (l = loader; l; l = l->l_loader)
      if (cache_rpath (l, &l->l_rpath_dirs, DT_RPATH, "RPATH")) …
  }
/* Try the LD_LIBRARY_PATH environment variable.  */
if (fd == -1 && __rtld_env_path_list.dirs != (void *) -1) …
/* Look at the RUNPATH information for this binary.  */
if (fd == -1 && loader != NULL
    && cache_rpath (loader, &loader->l_runpath_dirs, DT_RUNPATH, "RUNPATH")) …
```

| Property                               | `DT_RPATH`                                                    | `DT_RUNPATH`                                              |
| -------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------- |
| Position relative to `LD_LIBRARY_PATH` | **Before** — cannot be overridden by the environment          | **After** — the environment wins                          |
| Applies to                             | The loading object _and every ancestor_ (`l->l_loader` chain) | **Only the object that directly names the dependency**    |
| Disabled by                            | Presence of `DT_RUNPATH` on the loading object                | —                                                         |
| Practical status                       | Deprecated; still emitted by some toolchains                  | The modern default (`ld -z origin`, `--enable-new-dtags`) |

The inheritance asymmetry is the whole story. `DT_RPATH` is a _transitive_ scope: a library found via its parent's `RPATH` can itself find _its_ dependencies through that same `RPATH`. `DT_RUNPATH` is a _local_ scope: it resolves this object's own `DT_NEEDED` entries and nothing else. That is why store-based systems (Nix, Guix, Spack — see [`nix-store-closures.md`][nix]) can use `RUNPATH` at all: each object carries exactly the paths of _its_ inputs, and the graph is closed by construction rather than by ambient inheritance. It is also why `RUNPATH` makes the search _longer_: every object has its own path list, and every object's list is probed independently.

### The `glibc-hwcaps` multiplier

`open_path` does not probe one filename per directory. It probes `ncapstr` of them — the `glibc-hwcaps` subdirectory variants plus the plain directory:

```c
/* elf/dl-load.c — open_path (abridged) */
edp = __mempcpy (buf, this_dir->dirname, this_dir->dirnamelen);
for (cnt = 0; fd == -1 && cnt < ncapstr; ++cnt)
  {
    if (this_dir->status[cnt] == nonexisting) continue;   /* negative cache */
    buflen = __mempcpy (__mempcpy (edp, capstr[cnt].str, capstr[cnt].len),
                        name, namelen) - buf;
    fd = open_verify (buf, -1, fbp, loader, whatcode, mode, …);
  }
```

On x86-64 that is `glibc-hwcaps/x86-64-v4/`, `…/v3/`, `…/v2/`, then the bare directory: **four probes per directory per object**, minus whatever the per-directory `status[]` negative cache has already ruled out. The negative cache is per `r_search_path_elem`, i.e. per-process — it dies with the process, along with the rest of the plan.

Measured on this machine (glibc 2.42, NixOS, so `/etc/ld.so.cache` does not exist and `RUNPATH` does all the work), `weston` — 30 objects by `ldd` — costs:

| Environment                      | `openat` attempts | `ENOENT` | successes | misses per object |
| -------------------------------- | ----------------: | -------: | --------: | ----------------: |
| clean (`RUNPATH` only)           |               140 |      111 |        29 |               3.7 |
| with a 6-entry `LD_LIBRARY_PATH` |               326 |      297 |        29 |               9.9 |

Adding six directories to the environment more than doubled the total probe count and tripled the miss count, while changing nothing about the answer. This is the Guix "stat storm" that [`shrinkwrap`][shrinkwrap-repo]'s README cites as its motivation: _"the search space could effect startup as it's `O(n)` on the number of entries (potentially worse if using RPATH). This can al[s]o be expensive in stat syscalls."_

### `LD_PRELOAD` and the global scope

`LD_PRELOAD` is not a search-path mechanism; it is an **insertion into the join order**. `handle_preload_list` in [`elf/rtld.c`][rtld] loads the named objects, and `_dl_map_object_deps` splices them into position 1.._n_ of the main map's search list — after the executable, before every `DT_NEEDED`. Then:

```c
/* elf/rtld.c — after _dl_map_object_deps */
/* Mark all objects as being in the global scope.  */
for (i = main_map->l_searchlist.r_nlist; i > 0; )
  main_map->l_searchlist.r_list[--i]->l_global = 1;
```

Every object reachable from the executable is `l_global`, and the _global scope_ is the first `r_scope_elem` every object's `l_scope` points at. So a definition in a preloaded object shadows every later one, everywhere, for free — no relinking, no symbol renaming. Interposition falls out of "the scope is an ordered list and lookup returns the first `STB_GLOBAL` hit", which is visible at the bottom of `do_lookup_x`:

```c
/* elf/dl-lookup.c — do_lookup_x (abridged) */
case STB_GLOBAL:
  /* Global definition.  Just what we need.  */
  result->s = sym;
  result->m = (struct link_map *) map;
  return 1;          /* first match wins; scan stops */
```

`STB_WEAK` is the one exception: a weak definition is recorded but the scan continues, so a strong definition later in the list still wins.

In secure-execution mode (`AT_SECURE`, i.e. setuid/setgid/capability transitions) both `LD_PRELOAD` path handling and `LD_LIBRARY_PATH` are restricted — `man 8 ld.so`: _"In secure-execution mode, preload pathnames containing slashes are ignored. Furthermore, shared objects are preloaded only from the standard search directories and only if they have set-user-ID mode bit enabled."_ The cache lookup is likewise gated on `(mode & __RTLD_SECURE) == 0 || ! __libc_enable_secure`.

### `/etc/ld.so.cache`: the out-of-band index

This is the only precomputed index in the whole system, and it is the catalog's clearest example of an **out-of-band** answer to _where does the index live?_ — a materialized view over the library filesystem, maintained by a separate tool (`ldconfig`) on a schedule nobody enforces.

The on-disk schema is a fixed header, a sorted entry array, and a string table ([`sysdeps/generic/dl-cache.h`][dlcacheh]):

```c
struct cache_file_new
{
  char magic[sizeof CACHEMAGIC_NEW - 1];      /* "glibc-ld.so.cache" */
  char version[sizeof CACHE_VERSION - 1];     /* "1.1" */
  uint32_t nlibs;                             /* Number of entries.  */
  uint32_t len_strings;                       /* Size of string table. */
  uint8_t  flags;                             /* endianness marker */
  uint8_t  padding_unsed[3];
  uint32_t extension_offset;                  /* extension directory */
  uint32_t unused[3];
  struct file_entry_new libs[0];              /* Entries describing libraries.  */
  /* After this the string table of size len_strings is found.  */
};
```

Each `file_entry_new` is `{ flags, key, value, osversion_unused, hwcap }`, where `key` and `value` are **string-table offsets** — the `SONAME` and the absolute path. It is, structurally, a two-column table with an interned string dictionary and a clustered index on the key.

The reader (`_dl_load_cache_lookup`, [`elf/dl-cache.c`][dlcache]) maps the whole file once per process and then does a binary search:

```c
/* elf/dl-cache.c — search_cache (abridged) */
int left = 0, right = nlibs - 1;
while (left <= right)
  {
    int middle = (left + right) / 2;
    uint32_t key = _dl_cache_file_entry (libs, entry_size, middle)->key;
    int cmpres = _dl_cache_libcmp (name, string_table + key);
    …
  }
```

The comparator is not `strcmp`: `_dl_cache_libcmp` compares digit runs _numerically_, so `libfoo.so.9` sorts before `libfoo.so.10`. The writer maintains the exact matching order — `compare` in `elf/cache.c` calls `_dl_cache_libcmp` with arguments swapped, and the comment on the `hwcaps` tiebreak is a textbook description of an index invariant:

> _"Keep the glibc-hwcaps extension entries before the regular entries, and sort them by their names. `search_cache` in dl-cache.c stops searching once the first non-extension entry is found, so the extension entries need to come first."_

That coupling is the cost of an out-of-band index: the sort order is a contract between two programs shipped in the same source tree, and violating it does not produce an error, it produces a _different answer_.

The view is also optional. On NixOS this machine has **no `/etc/ld.so.cache` at all** — `ldconfig -p` reports `Can't open cache file` — and everything still works, because `RUNPATH` makes every query answerable without the index. The trade is exactly the one a database administrator recognizes: drop the materialized view, pay full scan cost per query, gain freedom from staleness.

### Symbol lookup: `.gnu.hash` as a bloom filter over a hash index

Per named relocation, `_dl_lookup_symbol_x` hashes the name once (`_dl_new_hash`, a djb2 variant unrolled two characters at a time in [`sysdeps/generic/dl-new-hash.h`][newhash]), then walks the scope. Per object, `do_lookup_x` runs the `.gnu.hash` probe:

```c
/* elf/dl-lookup.c — do_lookup_x (abridged) */
ElfW(Addr) bitmask_word
  = bitmask[(new_hash / __ELF_NATIVE_CLASS) & map->l_gnu_bitmask_idxbits];
unsigned int hashbit1 = new_hash & (__ELF_NATIVE_CLASS - 1);
unsigned int hashbit2 = ((new_hash >> map->l_gnu_shift) & (__ELF_NATIVE_CLASS - 1));

if ((bitmask_word >> hashbit1) & (bitmask_word >> hashbit2) & 1)
  {
    Elf32_Word bucket = map->l_gnu_buckets[new_hash % map->l_nbuckets];
    if (bucket != 0)
      {
        const Elf32_Word *hasharr = &map->l_gnu_chain_zero[bucket];
        do
          if (((*hasharr ^ new_hash) >> 1) == 0)      /* compare 31 hash bits */
            { symidx = ELF_MACHINE_HASH_SYMIDX (map, hasharr);
              sym = check_match (…); if (sym != NULL) goto found_it; }
        while ((*hasharr++ & 1u) == 0);               /* bit 0 = end of chain */
      }
  }
```

The layout is decoded once per object in [`elf/dl-setup_hash.c`][setuphash]: `nbuckets`, `symbias`, `bitmask_nwords` (asserted a power of two), `shift`, then the bloom words, the buckets, and `chain_zero = chains - symbias`.

Read as a database, `.gnu.hash` is three optimizations stacked:

1. **A 2-hash bloom filter** (`bitmask`) that answers "definitely absent" in one word load and two shifts. This is the entire point: in a scope of _n_ objects, only the one or two that actually define the symbol reach the bucket walk. Thesis 1 of the [source outline][index] — _every binary format eventually reimplements a database, badly_ — is at its most literal here: it is a hand-rolled bloom filter with hard-coded _k_ = 2, no tuning knob at runtime, and a false-positive rate the linker picks at link time.
2. **A hash-partitioned symbol table.** The linker sorts `.dynsym` so that all symbols in one bucket are contiguous, which is why a chain is walked with `hasharr++` and terminated by a low bit rather than by following `st_name` pointers. `symbias` is the index of the first hashed symbol; everything below it is undefined and unhashable.
3. **31 bits of hash stored inline** in the chain, so `strcmp` runs only after a 31-bit hash match. The full name comparison in `check_match` is the last resort, not the first.

The fallback path — SysV `DT_HASH` — has none of this: bucket, then chain, then `strcmp` per entry. `_dl_setup_hash` prefers `.gnu.hash` whenever it is present.

> [!NOTE]
> The bloom filter is a _per-object_ index. It shortens the per-object probe; it does not shorten the _scope scan_. A symbol defined in the last of 40 objects still costs 40 bloom probes. That asymmetry is the mechanical root of the fzakaria result in [Loader work is proportional to object count](#loader-work-is-proportional-to-object-count-not-bytes).

### Lazy binding, `BIND_NOW`, and `RELRO`

By default a call through the PLT is resolved on first use. The PLT stub jumps through a GOT slot that initially points back into the loader's trampoline, which calls `_dl_fixup` ([`elf/dl-runtime.c`][runtime]) with the object and a relocation index. `_dl_fixup` performs _the same_ `_dl_lookup_symbol_x` a `BIND_NOW` startup would have performed, then writes the answer into the GOT slot so the next call goes direct.

The lazy/eager decision is made in [`elf/dl-reloc.c`][reloc]:

```c
/* elf/dl-reloc.c — _dl_relocate_object (abridged) */
int lazy = reloc_mode & RTLD_LAZY;
…
/* If DT_BIND_NOW is set relocate all references in this object.  We
   do not do this if we are profiling, of course.  */
if (!consider_profiling && l->l_info[DT_BIND_NOW] != NULL)
  lazy = 0;
```

with `GLRO(dl_lazy)` cleared globally by `LD_BIND_NOW`. Three observations for this catalog:

- **Lazy binding is a query-plan choice, not a semantic one.** The join is identical; only _when_ it runs differs. Lazy amortizes cost across the process lifetime and skips symbols never called; `BIND_NOW` pays everything up front and makes the answer _complete_ at a known point.
- **`BIND_NOW` is what makes the plan snapshot-able.** With `-z now -z relro` the GOT is fully populated before `main` and then `mprotect`ed read-only. That is precisely the state a materialized view would want to restore.
- **Every distribution has already moved this way for security reasons** (full RELRO hardening), which quietly removed the main argument for laziness. On this machine `LD_BIND_NOW=1` changed nothing measurable for `ls`, because `ls` is already `-z now`: 1223 relocations either way.

### `rtld-audit`: the programmable seam

`LD_AUDIT` loads auditor objects into a _separate_ namespace and gives them hooks at each stage of the plan. Two matter here.

**`la_objsearch`** is called at each step of the path search, with a flag naming which step ([`elf/link.h`][linkh]):

```c
LA_SER_ORIG    = 0x01,  /* Original name.  */
LA_SER_LIBPATH = 0x02,  /* Directory from LD_LIBRARY_PATH.  */
LA_SER_RUNPATH = 0x04,  /* Directory from RPATH/RUNPATH.  */
LA_SER_CONFIG  = 0x08,  /* Found through ldconfig.  */
LA_SER_DEFAULT = 0x40,  /* Default directory.  */
```

The auditor returns a replacement name, or `NULL` to reject the candidate. `_dl_audit_objsearch` ([`elf/dl-audit.c`][audit]) chains every loaded auditor. This is a **rewrite hook on the object-resolution query**, and the flags are effectively the plan node type — an auditor can distinguish "you were about to take this from `LD_LIBRARY_PATH`" from "you were about to take this from the cache."

**`la_symbind`** is the corresponding hook on the symbol join: it receives the resolved `ElfW(Sym)`, the defining object, the symbol index, and a mutable value, and may substitute a different address. `_dl_audit_symbind` synthesizes a symbol record whose `st_value` is the _resolved_ address and passes it down the auditor chain, so an auditor sees each binding exactly once, at the moment it is decided.

Together they are the closest thing ELF has to a query-plan interceptor: `la_objsearch` sees the scan, `la_symbind` sees the join result, and `la_objopen`/`la_objclose` see the relation set change. `LAV_CURRENT` is 2 on most targets (3 on LoongArch); the interface version was bumped when bind-now support was added, because with `-z now` there is no PLT entry to trace and the auditor has to be told so.

> [!WARNING]
> Auditing is not free and not transparent: the audit namespace gets its own copy of libc, `consider_profiling` forces lazy binding on when PLT hooks are present (see the `_dl_relocate_object` excerpt above), and an auditor that returns a different name from `la_objsearch` changes what the program _is_. It is a debugging and instrumentation seam, not a supported extension point for production dispatch — for that, see [`binfmt-misc.md`][binfmt].

---

## Format identity and multiplicity

**Multiplicity: 1/3 — incidental.** An ELF file admits one parse. There is no suffix-tolerance (the section header table is located by an offset in the `ElfN_Ehdr`, so trailing bytes are unreachable but also harmless) and no prefix-tolerance at all (`\x7fELF` must be at offset 0, which is what makes the polyglot tricks in [`polyglot-craft.md`][polyglot] and [`cosmopolitan-ape/index.md`][ape] hard for ELF and easy for ZIP). The loader itself does not sniff: `open_verify` checks `e_ident`, class, byte order, ABI, and machine, and rejects anything else.

The one genuine multiplicity is the loader's own artifact. `ld-linux-x86-64.so.2` is simultaneously a shared object (it is what `PT_INTERP` names, mapped by the kernel) and an executable (`/lib64/ld-linux-x86-64.so.2 --list ./prog` runs it as a program that loads another program). [`shrinkwrap`][shrinkwrap-repo] exploits exactly this dual identity: its `NativeLinkStrategy` shells out to the binary's _own_ interpreter and parses the output —

```python
# shrinkwrap/elf.py — NativeLinkStrategy.explore
interpreter = Command(binary.interpreter)
resolution = interpreter("--list", filename)
```

— which is the loader used as a _query executor over its own plan_, invoked ahead of time. That is a real instance of reflexivity-by-re-execution, and it is why the tool is glibc-specific.

The honest reading of the axis: ELF's low multiplicity is the reason the _dispatch_ question is settled before `ld.so` runs. The kernel's ELF binfmt handler already decided what the file is (see [`binfmt-misc.md`][binfmt]); the loader inherits a resolved format and only argues about _content_.

## Index anchoring and random access

**Header-anchored, with an out-of-band secondary index.**

The primary index is header-anchored twice over. `e_phoff` in the ELF header locates the program headers; `PT_DYNAMIC` locates the dynamic array; and `DT_STRTAB`, `DT_SYMTAB`, `DT_GNU_HASH`, `DT_JMPREL`, `DT_NEEDED`, `DT_RUNPATH` are all offsets from there. The consequence for ranged access is direct: **a loader can answer "what does this object need?" after reading two headers and one string table.** `_dl_map_new_object` does exactly that — it reads a `filebuf` of the first bytes and only maps segments once the identity checks pass.

That property is what makes remote or partial interrogation of ELF plausible at all, and it is the same property [`footer-indexed-formats.md`][footer] contrasts with ZIP's end-of-central-directory: header-anchored formats are cheap to _begin_ reading and expensive to _append_ to; footer-anchored formats are the reverse. ELF's answer to "can I read the dependency list without the file?" is _yes, from the front, in about two reads_ — see [`range-request-access.md`][range] for what that buys over HTTP.

The secondary index — `/etc/ld.so.cache` — is out-of-band in the strict sense: a separate file, produced by a separate tool, keyed by a value (`SONAME`) that lives in the artifacts it indexes. Random access into it is a binary search over a sorted array, after one `mmap` of the whole file. It is never partially read, and it is never validated against the objects it names: `search_cache` returns a path and `open_verify` then re-checks the ELF identity of whatever is actually there. A stale cache is not detected; it is simply _wrong_, and the wrongness surfaces as a load failure or, worse, a successful load of the wrong library.

What is _not_ indexed anywhere: the transitive closure. There is no `DT_` tag for "the resolved dependency graph", no file recording it, and no per-object cache of "last time, `memcpy` came from object 3". Every process rediscovers it. That absence is the subject of the rest of this page.

## Reflexivity and query surface

**Reflexivity: 2/3 — designed-in.** The loader maintains a live, documented, machine-readable model of its own state, and exposes it through four distinct surfaces:

| Surface                         | Consumer                                 | What it answers                                                           |
| ------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------- |
| `_r_debug` / `r_debug_extended` | Debuggers (GDB, LLDB)                    | The link map chain, plus `r_next` for additional namespaces (added 2.35)  |
| `dl_iterate_phdr(3)`            | Unwinders, profilers, the process itself | Every loaded object's name, base address, and program headers             |
| `dladdr(3)` / `dladdr1(3)`      | The process itself                       | address → (object, nearest symbol)                                        |
| `LD_DEBUG=…`                    | Humans                                   | `libs`, `symbols`, `reloc`, `bindings`, `statistics` — the plan, narrated |
| `LD_AUDIT` (`rtld-audit`)       | Instrumentation                          | Every search step and every binding, with the right to rewrite both       |

This is a genuinely reflexive runtime: a program can enumerate its own loaded objects, map an arbitrary code address back to a symbol, and — via `dlinfo(RTLD_DI_SERINFO)` — ask for its own _search path list_, which `add_path`/`_dl_map_object` in [`elf/dl-load.c`][load] materializes on demand. What it cannot do is ask a _general_ question. There is no query language, no join, no projection. `dl_iterate_phdr` is a callback over a linked list; the caller writes the loop.

That gap is the entire premise of [`sqlelf.md`][sqlelf] and [`self-selfdb/index.md`][self]: take the same data the loader already models and expose it through a relational surface, at which point `ldd` becomes a recursive CTE and `LD_PRELOAD` becomes a row in an ordered table. The loader has the _model_; it lacks the _surface_. Compare [`relational-system-surfaces.md`][relsurf], where osquery makes the identical move for the OS as a whole, and [`code-as-database.md`][codedb] for why the transitive questions here (closure, resolution order, reachability) are the ones SQL handles worst.

`LD_DEBUG=statistics` deserves a note because it is the closest thing to an `EXPLAIN ANALYZE` the loader ships. Measured here:

```
runtime linker statistics:
  total startup time in dynamic loader: 634524 cycles
            time needed for relocation: 244288 cycles (38.4%)
                 number of relocations: 5042
      number of relocations from cache: 951
        number of relative relocations: 12125
           time needed to load objects: 359726 cycles (56.6%)
```

(`weston`, 30 objects.) The line _"number of relocations from cache"_ counts hits in the per-process `reloc_result` memo used for auditing and profiling — the only intra-process memoization of the join anywhere in the loader.

## Closure, dedup, and size model

**Closure: 1/3 — incidental.** This is the axis on which `ld.so` scores lowest, and deliberately so. A dynamically linked executable carries _names_ of dependencies, not dependencies. That is the entire point: it is the mechanism by which one `libc.so.6` is shared by every process on the machine, which is the dedup story dynamic linking exists to tell.

The size model, then, is inverted relative to every other subject in this catalog. Where [`cosmopolitan-ape/index.md`][ape] and the AppImage model in [`../application-packaging/`][apppkg] pay bytes to gain self-containment, dynamic linking pays _startup work_ to gain sharing. The concrete exchange rate, on this machine:

| Binary   | objects (`ldd`) | named relocs | relative relocs | loader cycles |
| -------- | --------------: | -----------: | --------------: | ------------: |
| `ls`     |               6 |         1223 |            2355 |       113 011 |
| `git`    |               6 |          504 |            5005 |       129 199 |
| `weston` |              30 |         5042 |           12125 |       634 524 |

`weston` has 5× the objects of `ls` and ~5.6× the loader cost, while `git` has the _same_ object count as `ls` and twice the relative relocations at essentially the same cost. The regression that fits is on object count, not on relocation count and certainly not on bytes.

Three tools attack the closure gap from different directions, and it is worth seeing them as points on one line:

| Tool                            | What it writes into the artifact                                   | Closure after | Survives library moves?        |
| ------------------------------- | ------------------------------------------------------------------ | ------------- | ------------------------------ |
| plain `DT_NEEDED` + `RUNPATH`   | `SONAME`s + this object's own search paths                         | names only    | yes (re-searched)              |
| [`shrinkwrap`][shrinkwrap-repo] | the _resolved absolute paths_ of the whole closure, as `DT_NEEDED` | paths         | no                             |
| `prelink`                       | paths **plus** base addresses **plus** conflict fixups             | addresses     | no (validated, then discarded) |

`shrinkwrap` is the minimal move. Its `cli.py` removes every existing `DT_NEEDED` and re-adds the closure it discovered, absolute-path-qualified:

```python
# shrinkwrap/cli.py
resolution = strategy.explore(binary, file)
needed = list(binary.libraries)
for name in needed:
    binary.remove_library(name)
for soname, lib in reversed(resolution.items()):
    binary.add_library(lib)
```

Because a `DT_NEEDED` string containing a `/` bypasses the search entirely (`if (strchr (name, '/') == NULL)` in `_dl_map_new_object`), the object-resolution query collapses to one `openat` per object. The `VERNEED` fixup in the same function — rewriting version-dependency names to the new absolute strings — is the tell that this is a schema migration, not a hint: the tool has to keep two tables consistent by hand, exactly the "foreign key maintained by hand" the outline's thesis 1 complains about.

What `shrinkwrap` does **not** do is precompute the symbol join. The closure is materialized; the addresses are not. That is the line `prelink` crossed.

## Mutability, dispatch, and trust

**Mutability: 1/3 — incidental.** The loader never writes to the file. It writes to the _image_: relocations patch `.data.rel.ro` and the GOT, lazy binding patches GOT slots at runtime, and `DT_TEXTREL` objects get their text segments temporarily `mprotect`ed writable (`_dl_relocate_object` walks `PT_LOAD` and adds `PROT_WRITE`, then restores). Nothing persists. The next process starts from the same bytes.

That is a _feature_ under this catalog's thesis 4 — `mmap` is the load-bearing constraint. Because the file is never mutated, every process `mmap`s the same inode with `MAP_PRIVATE`, and read-only and executable pages are shared across the whole machine through the page cache. Only the pages the loader actually patched become private (COW). Full RELRO exists to shrink even that set: bind everything eagerly, then `mprotect` the GOT read-only, so the writable working set after startup is as small as the linker can make it. The comparison to a format that stores segments as database rows — [`self-selfdb/index.md`][self] — is unavoidable here, and it is the sharpest cost that design pays.

**Dispatch: the loader owns it, but only in the second round.** The kernel decides the file is ELF and honours `PT_INTERP`; the loader then decides what every _name_ in the file means. Symbol interposition is the purest form of this: the same call site in the same bytes binds to a different function depending on `LD_PRELOAD`, `DT_NEEDED` order, symbol versions, and `dlopen(RTLD_GLOBAL)` history. The artifact does not determine its own behaviour; the _scope_ does.

**Trust.** Three properties are worth stating plainly, because they set the requirements for any cached-plan scheme:

1. **`ld.so` performs no cryptographic verification of anything.** `open_verify` checks structural ELF identity, not authenticity. The security boundary is entirely filesystem permissions plus the secure-execution restrictions on `LD_PRELOAD`/`LD_LIBRARY_PATH`/cache.
2. **`LD_PRELOAD` and `LD_AUDIT` are, by construction, arbitrary code execution in the target process.** They are the reason the secure-execution carve-outs exist, and they are a standing item in [`threat-model.md`][threat].
3. **The cache is trusted, unsigned, and world-readable.** `_dl_load_cache_lookup` validates only that string-table offsets are in range (`_dl_cache_verify_ptr`) — corruption checks, not integrity checks. Anything that can write `/etc/ld.so.cache` already owns the machine, so this is defensible, but it means the _materialized view has no integrity relationship to the base tables_. Any richer view — a cached relocation plan — inherits that problem and cannot inherit that excuse.

---

## Relocations are a join; the loader is a query engine with no plan cache

The catalog's [open question for cluster D][index] is whether the plan can be compiled into the artifact. Stating it precisely first:

For each object _o_ in the process, for each named relocation _r_ in _o_, the loader computes

> `bind(o, r) = first m in scope(o) such that gnu_hash_lookup(m, name(r), version(r)) is a non-hidden STB_GLOBAL or the last STB_WEAK`

`scope(o)` is `o->l_scope`, whose first element is the global search list — the flat BFS list from `_dl_map_object_deps`. The result is a `(link_map*, Elf_Sym*)` pair, converted to an address by `SYMBOL_ADDRESS`. That is a **nested-loop join with a bloom-filtered index probe on the inner relation, an ordered inner relation, and first-match semantics** — i.e. a semi-join whose result depends on the inner ordering. It runs, unchanged, every single time the program starts.

### Loader work is proportional to object count, not bytes

The measurement that most distorts naive comparisons in this catalog is fzakaria's: the dominant term is _n_, the number of shared objects, not the size of anything. From [_Speeding up ELF relocations for store-based systems_][fz-reloc] (2024-05-03):

> _"the cost of relocations is : O(R + nr log s), where R is the number of relative relocations, n is the number of shared libraries, r is the number of named relocations, and s is the number of symbols."_

and, accounting for the string comparison at the end of each chain walk, _"the cost of relocations can be O(R + n log s\*m)"_ where _m_ is symbol-name length. The `n` factor is the scope scan; the `log s` is the hash probe; the `m` is `check_match`'s `strcmp`. The blog's synthetic result — _"Relocation can take nearly **4.5 seconds** for **1 million** symbols!"_ — is the tail of that curve.

This matters for [`measurement.md`][measure] in a specific way. If you compare a conventional dynamically linked ELF program against a single-artifact alternative (an [APE binary][ape], a [SELF binary][self], a statically linked control), the ELF side's startup cost is being driven by _how many objects its distribution happened to split libc, libm, libz, libpcre and friends into_ — a packaging decision — and not by the workload. Two builds of the same program with the same source and the same total bytes can differ several-fold in loader time purely by fan-in. Any honest ELF-vs-_X_ startup comparison must therefore control for object count, or report the curve rather than a point. The `ls`/`git`/`weston` table above is the shape of that curve at _n_ = 6, 6, 30.

The corollary cuts the other way too: a self-contained artifact's apparent startup _win_ over ELF may be entirely an artifact of collapsing _n_ to 1, which is a thing static linking also does, for free, with none of the interesting properties this catalog is about. That is the line this catalog draws around "just static linking" (see the [scope notes on the umbrella page][index]), and it is worth re-drawing here: **collapsing the object count is not the same as making the artifact queryable.**

### `prelink`: the materialized view that was withdrawn

`prelink` (Jakub Jelínek, Red Hat, 2001–) is the one deployed system that cached the whole plan. Its abstract states the payoff bluntly: _"It speeds up start up of OpenOffice.org 1.1 by 1.8s from 5.5s on 651MHz Pentium III."_

Mechanically it did four things:

1. **Assigned each shared library a unique base address system-wide**, so that libraries could be mapped at their link-time address and relative relocations skipped entirely.
2. **Resolved every relocation ahead of time**, using the _real dynamic linker_ as the oracle — the same trick `shrinkwrap` later reused: _"The symbol lookup code in the dynamic linker is quite complex and big, so to avoid duplicating all this, prelink has chosen to use dynamic linker to do the symbol lookups."_
3. **Recorded the exceptions.** Symbols that resolve differently in a library's own scope than in the executable's global scope are _conflicts_, and prelink emitted a `.gnu.conflict` RELA section of fixups for them, in the executable.
4. **Recorded the validity predicate.** _"Also a list of all dependent shared libraries in the order they appear in the symbol search scope, together with their checksums and times of prelinking is stored in another special section"_ (`.gnu.liblist`), with `.gnu.prelink_undo` holding the original headers so the transformation is reversible.

The validation step is the part this catalog should study, because it is exactly the "schema that makes it safe" the open question asks for:

> _"it first looks at the library list section created by prelink (if any) and checks whether they are present in symbol search scope in the same order, none have been modified since prelinking and that there aren't any new shared libraries loaded either. If all these conditions are satisfied, prelinking can be used. In that case the dynamic linker processes the fixup section and skips all normal relocation handling. If one or more of the conditions are not met, the dynamic linker continues with normal relocation processing."_

Three predicates, checked at startup: **same set, same order, same content, nothing extra.** Fail any one and the loader falls back to the full plan. This is precisely a materialized-view freshness check, and prelink's design is _fail-safe_ — a stale view costs performance, never correctness.

So why did it lose? The paper itself names the first reason, in 2004, before it became decisive:

> _"If shared libraries are prelinked, they cannot be assigned different addresses on each run (prelinking information can be only used to speed up startup if they are mapped at the base addresses which was used during prelinking), which means prelinking might not be desirable on some edge servers."_

Fixed base addresses and ASLR are the same knob turned two ways. `prelink -R` randomized the _assignment_ rather than the per-run mapping, which the paper concedes is _"almost the same as assigning random addresses on each run for long running processes such as daemons"_ — a defensible position in 2004, an indefensible one once distributions moved to PIE-by-default and full ASLR. MatR's paper puts the modern verdict plainly: prelink _"is incompatible with current systems since its fixed virtual memory addresses do not support address space layout randomization."_

The other two reasons are operational and follow from the validity predicate being expensive to _maintain_ rather than to _check_:

- **Package churn invalidates the view globally.** Because base addresses are assigned across the whole system, updating one widely used library can force reassignment: _"the library that has been moved and re-prelinked, need to be prelinked again. If this happened during incremental prelinking, prelink will fix up only the executables given on the command line, leaving other executables untouched. The untouched executables would not be able to benefit from prelinking anymore."_ A view that silently degrades for everything you did not re-run is a maintenance liability.
- **Verification breaks.** Prelinking rewrites shipped binaries in place, so every package-manager checksum, every file-integrity monitor, and every reproducible-build guarantee sees modified files. `.gnu.prelink_undo` exists to let tools reverse the transform before hashing — an entire second mechanism whose only job is to undo the optimization for the benefit of verifiers. That interacts badly with everything in [`embedded-provenance.md`][prov].

glibc removed its side of the mechanism during the 2.36 cycle. The 2.35 release's `NEWS` carries only the deprecation (_"Support for prelink will be removed in the next release; this includes removal of the LD_TRACE_PRELINKING, and LD_USE_LOAD_BIAS, environment variables and their functionality in the dynamic loader"_); the 2.36 release's `NEWS` adds the removals themselves. At the surveyed commit the loader's only remaining trace of prelink is `ldconfig` skipping `.#prelink#` temporary files.

### Can the plan live in the artifact? What would invalidate it

Reframed as a materialized view, the design has three separable layers, and they invalidate on different events:

| Layer                      | What is cached                                      | Invalidated by                                                                                                     | Detectable how                             |
| -------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| **L1 — object resolution** | `SONAME` → absolute path, per object                | any change to `RPATH`/`RUNPATH`/`LD_LIBRARY_PATH`/cache/default dirs; the file at that path changing               | content hash of each named file            |
| **L2 — scope order**       | the flat BFS list, in order                         | any change to any `DT_NEEDED` list in the closure; `LD_PRELOAD`; `dlopen(RTLD_GLOBAL)`; `LD_AUDIT` rewriting names | hash of the ordered `(path, hash)` vector  |
| **L3 — bindings**          | `(object, reloc) → (defining object, symbol index)` | anything in L2, plus symbol-table changes in any member, plus symbol versioning changes                            | per-object `.dynsym`/`.gnu.version_r` hash |
| **L3′ — addresses**        | resolved _addresses_                                | everything in L3, **plus** ASLR, **plus** any base-address reassignment                                            | not detectable — must not be cached        |

`prelink` cached L1–L3′ and paid for L3′ with ASLR. `shrinkwrap` caches only L1, writes it into `DT_NEEDED`, and needs no validity predicate at all because a wrong path simply fails to open — the failure mode is loud. That is why `shrinkwrap` is deployable and `prelink` is not: **the cheapest correct design caches the layer whose staleness is self-announcing.**

The interesting frontier is L2–L3 without L3′, and it has a name. Zakaria, Quinn and Scogland's _Symbol Resolution MatRs: Make it Fast and Observable with Stable Linking_ ([arXiv:2501.06716][matr], 2025-01-12) makes exactly this cut. The abstract's framing is the same one this page has been building:

> _"Dynamic linking waits until runtime to calculate an application's relocation mapping, i.e., the mapping between each externally referenced symbol in the application to the dependency that provides the symbol."_

MatR's contribution is the schema that makes the cache safe: an explicit **epoch** — _"a period between management times"_ during which system dependencies cannot change — bounded by `begin_mgmt`/`end_mgmt`. The relocation mapping is computed once per epoch and reused for every execution within it. Crucially it stores _offsets_, not addresses (L3, not L3′), which is what keeps it ASLR-compatible where prelink was not. Reported results: 1.32× on Clang, 1.13× on LibreOffice, 7.03× on Pynamic, geometric mean **2.19×**.

Two details deserve emphasis for this catalog:

- **MatR stores the mapping as a table, in "JSON, CSV, and SQLite."** A relocation plan is naturally relational — it is a join result — and one of the three shipped encodings is the same engine [`self-selfdb/index.md`][self] proposes putting the _whole executable_ into. The convergence is not a coincidence: once you decide the loader's output is a query result, the artifact that stores it is a database.
- **`dlopen` is explicitly outside the epoch.** MatR _"cannot accelerate any symbol resolution that an application performs using tools such as dlopen since it may not have observed the resolutions at the end of the previous management time."_ This mirrors prelink's limitation exactly (_"The set of shared libraries loaded via dlopen(3) cannot be predicted by prelink"_) and is a structural, not incidental, boundary: `dlopen` is an unbounded, data-dependent extension of the relation set. Any cached plan is a plan for the _static_ closure only.

The assessment, then, for the outline's open question: **yes, the plan can be compiled and cached in the artifact, and the safe schema is already known.** It requires (a) content-addressed identity for every member of the closure, (b) an ordered scope vector hashed as a unit, (c) storage of _offsets_ rather than addresses, (d) an explicit fallback to the full plan when the predicate fails, and (e) an accepted boundary at `dlopen`. Prelink had (b), (d), and a weak form of (a) via checksums; it lacked (c), which killed it. Store-based systems supply (a) for free — a Nix store path _is_ a content hash of the closure input, which is why every serious attempt at this in the last five years (`shrinkwrap`, MatR, Guix's loader cache) comes out of that world. See [`nix-store-closures.md`][nix] and [`content-addressed-chunking.md`][cas].

What is still missing is not the mechanism but the _integrity_ story: the cached plan must be covered by whatever signs the artifact, and it is derived from files the artifact does not contain. That is the same shape as the signing problem in [`embedded-provenance.md`][prov], and it is unsolved in all three systems above.

---

## Strengths

- **Sharing at the page level, machine-wide.** One `libc.so.6` inode backs every process; only patched pages go private. No competing design in this catalog matches it.
- **Late binding is genuinely useful.** Security updates take effect on the next `execve` with no relink; `LD_PRELOAD` gives a zero-cost interposition mechanism that debuggers, sanitizers, and profilers all depend on.
- **The per-object index is good.** `.gnu.hash`'s bloom filter turns "is this symbol here?" into one word load for the common negative case, and 31 inline hash bits make `strcmp` a last resort.
- **Fail-safe by construction.** Every optimization in the path — the negative directory cache, the `SONAME` memo, `/etc/ld.so.cache`, the historical prelink fast path — degrades to the full search rather than to a wrong answer.
- **A real instrumentation seam.** `rtld-audit` intercepts both the scan (`la_objsearch`) and the join (`la_symbind`) with enough context (the `LA_SER_*` flags) to tell plan nodes apart.
- **Header-anchored metadata.** Dependency and symbol information is readable from the front of the file, cheaply, which is what makes offline analysis — `ldd`, `shrinkwrap`, `sqlelf`, MatR — possible at all.

## Weaknesses

- **The plan is recomputed on every process start,** with no cross-process memoization of anything but name → path.
- **Cost scales with object count.** `O(R + nr log s)`; the scope scan is linear in _n_ and the per-object bloom filter does not help it.
- **The path search is quadratic-ish in practice.** Every object probes every directory in its own list, times `ncapstr` hwcaps variants. Measured here: 111 failed `openat` calls for a 30-object program with no `LD_LIBRARY_PATH`, 297 with a six-entry one.
- **`RPATH`/`RUNPATH`/`LD_LIBRARY_PATH`/cache/default is five overlapping mechanisms** with an order that is load-bearing, largely undocumented in the artifact itself, and different between `RPATH` and `RUNPATH` in a way that changes transitive behaviour.
- **The out-of-band index has no integrity relationship to what it indexes.** `ld.so.cache` is trusted, unsigned, and never revalidated against the files it names.
- **No general query surface.** The loader models a graph and exposes iterators. Every transitive question (closure, resolution order, reachability) has to be reimplemented by each consumer.
- **`dlopen` defeats every static analysis and every cached plan,** by design.
- **Interposition makes behaviour non-local.** The meaning of a call site depends on the whole scope, which is why `LD_PRELOAD` is simultaneously the best debugging tool and a persistent item in [`threat-model.md`][threat].

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                              | Trade-off                                                                                                      |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `DT_NEEDED` stores `SONAME` strings, not paths or hashes            | Lets one library serve every consumer; security updates need no relink                 | The closure is not in the artifact; it must be rediscovered every start, and can be rediscovered _differently_ |
| Breadth-first flat search list, first match wins                    | Deterministic, cheap to build, gives interposition for free                            | Lookup cost is linear in object count; symbol shadowing is invisible at the call site                          |
| `DT_RUNPATH` is per-object; `DT_RPATH` is inherited                 | Local scoping makes each object's dependencies explicit and hermetic                   | Every object carries its own list, so total probe count grows with objects × path entries                      |
| `LD_LIBRARY_PATH` searched before `DT_RUNPATH` but after `DT_RPATH` | Preserves the older `RPATH` override semantics while letting `RUNPATH` be overridable  | Two tags with opposite override semantics; which one you get depends on the toolchain                          |
| `/etc/ld.so.cache` as an out-of-band sorted index                   | Turns _k_ directory probes into one binary search over a single `mmap`                 | A second program must maintain it; no integrity check; staleness is silent; absent entirely on Nix/Guix        |
| `.gnu.hash` bloom filter + inline 31-bit hashes                     | Makes the negative case (the common one) nearly free; defers `strcmp` to the last step | A hand-rolled index with link-time-fixed parameters and no runtime tuning; helps per object, not per scope     |
| Lazy PLT binding by default                                         | Skip resolution for functions never called; amortize the rest                          | Made obsolete by `-z now` hardening; the GOT stays writable until RELRO; timing becomes unpredictable          |
| The loader verifies structure, never authenticity                   | Keeps `ld.so` small and policy-free; trust is the filesystem's job                     | Every trust decision moves to packaging/`binfmt`/LSM layers; a cached plan has nothing to attest to            |
| `rtld-audit` as the extension point                                 | One documented seam for instrumentation instead of ad-hoc patching                     | Forces lazy binding when PLT hooks are used; auditors run with full privilege in a separate namespace          |
| Prelink removed (glibc 2.36 cycle)                                  | Fixed base addresses are incompatible with ASLR; in-place rewrites break verification  | The only shipped whole-plan cache disappeared; the work must be redone, differently, by store systems          |

---

## Sources

- [`man 8 ld.so` — search order, environment variables, secure-execution mode][manldso]
- [`man 7 rtld-audit` — the auditing interface][manaudit]
- [`man 8 ldconfig` — building `/etc/ld.so.cache`][manldconfig]
- [`elf/dl-deps.c` — `_dl_map_object_deps`, the breadth-first dependency walk][deps]
- [`elf/dl-load.c` — `_dl_map_object`, `_dl_lookup_map`, `_dl_map_new_object`, `open_path`, the search order][load]
- [`elf/dl-lookup.c` — `_dl_lookup_symbol_x`, `do_lookup_x`, the `.gnu.hash` probe, `add_dependency`][lookup]
- [`elf/dl-setup_hash.c` — decoding the `.gnu.hash` / `DT_HASH` layouts][setuphash]
- [`sysdeps/generic/dl-new-hash.h` — `_dl_new_hash`, the djb2 variant][newhash]
- [`elf/dl-cache.c` — `_dl_load_cache_lookup`, `search_cache`, `_dl_cache_libcmp`][dlcache]
- [`sysdeps/generic/dl-cache.h` — the `ld.so.cache` on-disk schema][dlcacheh]
- [`elf/cache.c` — `ldconfig`'s writer, and the sort order contract][cachec]
- [`elf/dl-reloc.c` — `_dl_relocate_object`, the lazy/`BIND_NOW` decision, `DT_TEXTREL` handling][reloc]
- [`elf/dl-runtime.c` — `_dl_fixup`, lazy PLT binding][runtime]
- [`elf/dl-audit.c` — `_dl_audit_objsearch`, `_dl_audit_symbind`][audit]
- [`elf/link.h` — the `LA_SER_*` search-stage flags][linkh]
- [`elf/rtld.c` — `handle_preload_list`, global-scope marking][rtld]
- [`NEWS` — prelink deprecation and removal][news]
- [Jakub Jelínek, _Prelink_ (Draft 0.7, 2004)][prelinkpaper]
- [Farid Zakaria, _Speeding up ELF relocations for store-based systems_ (2024-05-03)][fz-reloc]
- [Farid Zakaria, _Scaling past 1 million ELF symbol relocations_ (2024-07-21)][fz-scale]
- [Zakaria, Quinn, Scogland, _Symbol Resolution MatRs: Make it Fast and Observable with Stable Linking_, arXiv:2501.06716][matr]
- [`fzakaria/shrinkwrap` — rewriting `DT_NEEDED` to the resolved closure][shrinkwrap-repo] · [`shrinkwrap/elf.py`][shrinkwrap-elf] · [`shrinkwrap/cli.py`][shrinkwrap-cli]
- [Ludovic Courtès, _Taming the ‘stat’ storm with a loader cache_ (Guix, 2021-08-02)][guix]
- Related in this tree: [Cosmopolitan / APE][ape] · [SELF / selfdb][self] · [sqlelf][sqlelf] · [`binfmt_misc`][binfmt] · [Nix store closures][nix] · [Measurement][measure] · [Threat model][threat] · [Open questions][openq]

<!-- References -->

[repo]: https://github.com/bminor/glibc
[deps]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-deps.c
[load]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-load.c
[lookup]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-lookup.c
[setuphash]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-setup_hash.c
[newhash]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/sysdeps/generic/dl-new-hash.h
[dlcache]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-cache.c
[dlcacheh]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/sysdeps/generic/dl-cache.h
[cachec]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/cache.c
[reloc]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-reloc.c
[runtime]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-runtime.c
[audit]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/dl-audit.c
[linkh]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/link.h
[rtld]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/rtld.c
[news]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/NEWS
[manldso]: https://man7.org/linux/man-pages/man8/ld.so.8.html
[manaudit]: https://man7.org/linux/man-pages/man7/rtld-audit.7.html
[manldconfig]: https://man7.org/linux/man-pages/man8/ldconfig.8.html
[prelinkpaper]: https://people.redhat.com/jakub/prelink.pdf
[fz-reloc]: https://fzakaria.com/2024/05/03/speeding-up-elf-relocations-for-store-based-systems
[fz-scale]: https://fzakaria.com/2024/07/21/scaling-past-1-million-elf-symbol-relocations
[matr]: https://arxiv.org/abs/2501.06716
[shrinkwrap-repo]: https://github.com/fzakaria/shrinkwrap/blob/6009252271dec8c6588a4bea24bf8e09cbcddc6e/README.md
[shrinkwrap-elf]: https://github.com/fzakaria/shrinkwrap/blob/6009252271dec8c6588a4bea24bf8e09cbcddc6e/shrinkwrap/elf.py
[shrinkwrap-cli]: https://github.com/fzakaria/shrinkwrap/blob/6009252271dec8c6588a4bea24bf8e09cbcddc6e/shrinkwrap/cli.py
[guix]: http://web.archive.org/web/20250314041059/https://guix.gnu.org/blog/2021/taming-the-stat-storm-with-a-loader-cache/
[index]: ./index.md
[ape]: ./cosmopolitan-ape/index.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[binfmt]: ./binfmt-misc.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[measure]: ./measurement.md
[threat]: ./threat-model.md
[openq]: ./open-questions.md
[prov]: ./embedded-provenance.md
[polyglot]: ./polyglot-craft.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[relsurf]: ./relational-system-surfaces.md
[codedb]: ./code-as-database.md
[apppkg]: ../application-packaging/index.md
