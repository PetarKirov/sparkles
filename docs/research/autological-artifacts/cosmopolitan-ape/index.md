# Cosmopolitan / APE / redbean (format + libc + application)

One byte stream that is simultaneously a Windows PE, a FreeBSD-tagged ELF, a Mach-O, a POSIX shell script, an MBR boot sector, and a PKZIP archive — and, in redbean's case, a web server that serves its own archive over HTTP and can append new records to itself while running.

| Field           | Value                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------ |
| Kind            | Executable file format (APE) + freestanding libc (Cosmopolitan) + application (redbean)                            |
| Language        | C, GNU assembler, GNU `ld` linker scripts; redbean embeds Lua 5.4, SQLite, MbedTLS                                 |
| License         | ISC (APE), mixed permissive across the monorepo                                                                    |
| Repository      | [jart/cosmopolitan][repo]                                                                                          |
| Documentation   | [APE specification v0.1][spec] · [`redbean.dev`][redbean-dev] · [`justine.lol/ape.html`][ape-html]                 |
| First release   | APE announced 2020-08-24 ([`ape.html`][ape-html]); redbean 3.0.0 released 2024-08-17                               |
| Axis profile    | Multiplicity 3 / Reflexivity 2 / Closure 3 / Mutability 2                                                          |
| Index anchoring | Footer (ZIP `EOCD`, scanned backwards from EOF) layered over header-anchored executable headers                    |
| Dispatch owner  | Shell by default; kernel via `binfmt_misc` when registered; the ELF/Mach-O/PE loader after the header is rewritten |

> **Latest revision surveyed:** `jart/cosmopolitan` at commit `3293fad0` (2026-07-19); APE specification v0.1; APE magic version 1.10 (`ape/ape.h`). **Platform:** AMD64 and ARM64 across Linux, macOS, Windows, FreeBSD, OpenBSD, NetBSD, plus BIOS bare metal.

---

## Overview

### What it solves

The problem APE attacks is not packaging but _dispatch_. A native program is only runnable where some loader recognises its first bytes: Windows wants `MZ`, System V wants `\177ELF`, XNU wants `0xfeedfacf`. Every cross-platform native-distribution scheme before APE resolved this by shipping N artifacts (one per loader) or by shipping one artifact plus an installed runtime. APE resolves it by making the _same_ bytes satisfy every loader at once, so a single file copied by `scp` runs on six operating systems and two architectures with nothing installed.

The second half of the problem is assets. A statically linked binary carries its code but not its data, and the moment a program needs templates, certificates, timezone tables, or Lua sources, single-file distribution decays back into a directory. Cosmopolitan's answer is to append a PKZIP archive to the executable and expose it through the libc's own `open()` under a synthetic `/zip/` prefix — so the program reads its own tail as a read-only filesystem. redbean is the maximal expression of that: a web server whose document root _is_ the archive inside the file that is executing, which it will also serve, list, and (opt-in) append to.

This is a different resolution of the closure problem from anything in [`docs/research/application-packaging/`][pkg] — AppImage, Flatpak and Snap all keep the _distribution_ format separate from the _execution_ format, and all require a host-side runtime or a loop mount. APE collapses the two, and pays for it in a way this page is at pains to quantify.

### Design philosophy

The origin story is stated verbatim by the author on the canonical announcement page ([`justine.lol/ape.html`][ape-html], dated 2020-08-24):

> _"One day, while studying old code, I found out that it's possible to encode Windows Portable Executable files as a UNIX Sixth Edition shell script, due to the fact that the Thompson Shell didn't use a shebang line. Once I realized it's possible to create a synthesis of the binary formats being used by Unix, Windows, and MacOS, I couldn't resist the temptation of making it a reality, since it means that high-performance native code can be almost as pain-free as web apps."_

The archive half is justified on the same page in one sentence that is the whole thesis of [footer-indexed formats][footer]:

> _"As it turns out, PKZIP was designed to place its magic marker at the end of file, rather than the beginning, so we can synthesize ELF/PE/MachO binaries with ZIP too!"_

And the linker script itself states the operative principle for assets ([`ape/ape.lds`][lds]):

> _"we recommend doing it with a CLI web server instead and embedding files in your αcτµαlly pδrταblε εxεcµταblε as it's isomorphic to zip."_

Two consequences shape everything below. First, the design is _loader-facing_, not consumer-facing: APE spends its cleverness convincing six pieces of pre-existing, unmodifiable system software that the file is what each of them expects. Second, APE is honest that this is a compatibility shim rather than a new equilibrium — the [specification][spec] says the Linux kernel _"can be patched to have `execve()` recognize the APE format,"_ and the shipped installer registers the format with [`binfmt_misc`][binfmt] precisely so that the shell-script path is never taken.

---

## How it works

### The prologue: eight bytes with four readers

The file begins with an eight-byte magic that must be simultaneously valid x86 machine code (in 16-, 32-, and 64-bit modes), a valid `MZ` DOS header, and a valid POSIX shell statement. The [specification][spec] defines three such magics; the canonical one is `MZqFpD='`:

| Reader               | What it sees in `MZqFpD='`                                                               |
| -------------------- | ---------------------------------------------------------------------------------------- |
| Windows / DOS        | `MZ` — the DOS `MZ` signature; the rest is DOS-header fields                             |
| `/bin/sh`            | `MZqFpD='` — an assignment of an unterminated single-quoted string to an unused variable |
| x86 real mode (BIOS) | `dec %bp` ; `pop %dx` ; `jno 0x4a` ; `jo 0x4a` — an unconditional two-instruction jump   |
| x86-64               | `rex.WRB` ; `pop %r10` ; `jno 0x4a` ; `jo 0x4a`                                          |

The `jno`/`jo` pair is the trick: whichever way the overflow flag points, one of them is taken, so the pair is an unconditional jump encoded entirely in letters that are also a plausible shell variable name. The [specification][spec] spells out why the letters were chosen: _"The letters were carefully chosen so as to be valid x86 instructions in all operating modes. This makes it possible to store a BIOS bootloader disk image inside an APE binary."_

The shell quote opened by `='` is closed a few dozen bytes later in [`ape/ape.S`][apeS], which follows the DOS header fields with `' <<'@'` — closing the string and opening a here-document so the shell skips the binary payload. The modern linker, `apelink`, randomises that terminator ([`tool/build/apelink.c`][apelink]):

```c
// tool/build/apelink.c — FinishGeneratingDosHeader (abridged)
char *q = ape_heredoc;
q = stpcpy(q, "justine");
uint8_t digest[32];
Hacl_Hash_Blake2b_digest(hasher, digest);
uint64_t w = READ64LE(digest);
for (int i = 0; i < 6; ++i) {
  *q++ = "0123456789abcdefghijklmnopqrstuvwxyz"[w % 36];
  w /= 36;
}
p = stpcpy(p, "' <<'");
p = stpcpy(p, ape_heredoc);
```

The comment above it states the reason exactly: _"the big concern with shell script quoting, is that binary content might get generated in the dos stub which has an ascii value that is the same as the end of quote. using a longer terminator reduces it to a very low order of probability."_ A content-derived here-doc terminator is a defence against an accidental parser differential inside one's own file — the polyglot author's version of an escaping bug (see [polyglot craft][polyglot] and [parser differentials][differentials]).

There is a second magic, `jartsr='`, defined for binaries that never target Windows. Its stated rationale is not technical but reputational: _"APE programs that use the MZ magic above can attract attention from Windows AV software"_ ([`ape/specification.md`][spec]).

### Satisfying each loader in turn

Reading a real APE binary confirms the layering. `build/bootstrap/cocmd` in the clone is 656,048 bytes; `file(1)` classifies it as `DOS/MBR boot sector`, and the raw bytes contain:

| Offset    | Structure                                                                                       |
| --------- | ----------------------------------------------------------------------------------------------- |
| `0x000`   | `MZqFpD='` — MZ signature / shell assignment / x86 jump                                         |
| `0x040`   | DOS stub → real-mode BIOS bootloader (`pc:` in [`ape/ape.S`][apeS])                             |
| `0x1fe`   | `55 aa` — the MBR boot signature                                                                |
| `0x200`   | the here-doc terminator, then `#'"`, then the shell script proper at `0x214`                    |
| `0xc98`   | `cf fa ed fe` — a 64-bit little-endian Mach-O header                                            |
| `0x10cc8` | `PE\0\0` — the PE signature reached via `e_lfanew` at offset `0x3c`                             |
| `0x60000` | a complete second `Elf64_Ehdr` with `e_machine = EM_AARCH64` — the ARM64 half of the fat binary |
| tail      | `.zip.file`, `.zip.cdir`, `.zip.eocd` (present when assets are linked in)                       |

The ELF header is the interesting omission: **it is not stored at offset 0.** Nothing can be, because offset 0 is occupied by `MZ`. The [specification][spec] instead requires the header to be _"encoded as octal escape codes in a shell script `printf` statement"_ that must appear within the first 8192 bytes. The shell script writes it over the file's own first 64 bytes:

```sh
# from build/bootstrap/cocmd, the amd64 branch
exec 7<> "$o" || exit 121
printf '\177ELF\2\1\1\11\0\0\0\0\0\0\0\0\2\0>\0\1\0\0\0…' >&7
exec 7<&-
```

This is the "assimilation" step, and it is why the shell path exists at all: the shell is being used as a _format converter_ that runs once, in-place, before handing the file back to the kernel. `exec "$0" "$@"` then re-invokes the now-ELF file and the kernel loads it natively.

Mach-O on x86-64 cannot be produced this way — its header is far larger than 64 bytes of `printf` — so the script uses `dd` to copy a pre-built Mach-O header _backwards_ from an interior offset to offset 0. The [specification][spec] pins the exact textual form of that command and even supplies the regular expression third-party tools should use to parse it, because three encodings shipped over APE's history (`bs="  9293"`, `bs=$((  9293))`, `bs=9293  `).

The ELF `e_ident[EI_OSABI]` is set to `ELFOSABI_FREEBSD` for a reason worth recording: _"it's the only UNIX OS APE supports that actually checks the field"_ ([`ape/specification.md`][spec]). Every other kernel ignores it, so FreeBSD's strictness is the binding constraint and the field is set to satisfy the one reader that looks.

### The APE loader: the alternative to self-modification

Rewriting one's own first 64 bytes is a one-time cost but a permanent mutation, and it fails on a read-only filesystem, inside a container image, or when the binary is signed. The alternative is `ape/loader.c` — a ~9 KB freestanding ELF (the clone's prebuilt `build/bootstrap/ape.elf` is 9,249 bytes; `ape.aarch64` is 8,728) that reads the first 8192 bytes of an APE file, scans for `printf '` statements, octal-decodes them into an `Elf64_Ehdr`, and `mmap`s the segments itself:

```c
/* ape/loader.c — ape intended behavior
   1. if ape, will scan shell script for elf printf statements
   2. shell script may have multiple lines producing elf headers
   3. all elf printf lines must exist in the first 8192 bytes of file
   4. elf program headers may appear anywhere in the binary */
if (READ64(ebuf->buf) == READ64("MZqFpD='") ||
    READ64(ebuf->buf) == READ64("jartsr='") ||
    READ64(ebuf->buf) == READ64("APEDBG='")) { … }
```

The 8192-byte bound is the format's concession to bounded parsing: an interpreter never has to read more than one or two pages to decide what the file is and where its segments live. That is the same budget discipline a [range-request consumer][ranges] needs, arrived at for a different reason.

The loader header comment states the preference order plainly ([`ape/loader.c`][loader]): _"We recommend using the normal APE design, where binaries assimilate themselves once by self-modifying the first 64 bytes. If that can't meet your requirements then we provide an excellent alternative."_

### The `$TMPDIR/.ape` dance

When a binary is linked with `$(APE_NO_MODIFY_SELF)` ([`ape/BUILD.mk`][buildmk]), the loader is embedded in a `.ape.loader` section and the shell prologue extracts it before executing anything:

```sh
# ape/ape.S — the APE_LOADER branch, generalised
t="${TMPDIR:-${HOME:-.}}/.ape-1.10"
[ -x "$t" ] || {
  mkdir -p "${t%/*}" &&
  dd if="$o" of="$t.$$" skip=<off> count=<n> bs=64 2>/dev/null
  chmod 755 "$t.$$"
  mv -f "$t.$$" "$t"
}
exec "$t" "$o" "$@"
```

The `1.10` suffix is `APE_VERSION_STR` from [`ape/ape.h`][apeh], so loader upgrades do not collide. The `mv -f` gives atomic publication under concurrency. In a real `apelink`-produced binary the payload is gzip-compressed and the extraction is `dd … | gzip -dc`.

On Apple Silicon the cost is higher still. The prologue extracts a gzipped **C source file** and compiles it:

```sh
# from build/bootstrap/cocmd, the arm64 Darwin branch
if ! type cc >/dev/null 2>&1; then
  echo "$0: please run: xcode-select --install" >&2
  exit 1
fi
dd if="$o" skip=645458 count=10590 bs=1 2>/dev/null | gzip -dc >"$t.c.$$"
mv -f "$t.c.$$" "$t.c"
cc -w -O -o "$t.$$" "$t.c"
```

That file is [`ape/ape-m1.c`][apem1], which links against `dispatch`, `pthread`, and `dlfcn` and passes XNU-specific function pointers into the loaded program through a `struct Syslib`. So on the platform where APE is most needed, "build once, run anywhere" requires Xcode Command Line Tools on the target machine, on first run. `redbean.dev` states this as an installation prerequisite: _"On macOS with Apple Silicon you need to have Xcode Command Line Tools installed for redbean to be able to bootstrap itself."_

### `binfmt_misc`: taking dispatch back from the shell

The preferred deployment removes the shell entirely. `ape/apeinstall.sh` registers the magics with the kernel:

```sh
# ape/apeinstall.sh
uname_r="$(uname -r)"
if printf '%s\n%s\n' 5.12 "$uname_r" | sort -CV; then FLAGS=FP; else FLAGS=F; fi
echo ":APE:M::MZqFpD::/usr/bin/ape:$FLAGS"    >/proc/sys/fs/binfmt_misc/register
echo ":APE-jart:M::jartsr::/usr/bin/ape:$FLAGS" >/proc/sys/fs/binfmt_misc/register
```

Both flags matter. `F` ("fix binary") makes the kernel open the interpreter at registration time, so the mapping survives a `chroot` or mount-namespace change. `P` ("preserve argv[0]") makes the kernel pass `AT_FLAGS_PRESERVE_ARGV0` in the auxiliary vector and keep the original `argv[0]`; the loader reads exactly that bit ([`ape/loader.c`][loader]):

```c
} else if (SupportsLinux() && ap[0] == AT_FLAGS) {
  arg0 = !!(ap[1] & AT_FLAGS_PRESERVE_ARGV0);
}
```

`MISC_FMT_PRESERVE_ARGV0` and the auxv passing landed in Linux commit [`2347961b11d4`][kcommit] (authored 2020-01-28), first released in **v5.12** — which is exactly the version `apeinstall.sh` gates on. This is the same kernel facility that [SELF/selfdb][self] leans on, and the same `argv[0]` problem; see [`binfmt-misc.md`][binfmt] for the mechanism in full.

`README.md` quantifies the payoff: registering the format means _"APE will not only work, it'll launch executables 400µs faster now too."_

### `/zip/`: the archive as a filesystem

Cosmopolitan's libc intercepts path lookups beginning with `/zip` before they reach a syscall. The predicate is a hand-unrolled four-byte compare ([`libc/runtime/zipos-parseuri.c`][parseuri]):

```c
if ((uri[0] == '/' && uri[1] == 'z' && uri[2] == 'i' && uri[3] == 'p' &&
     (!uri[4] || uri[4] == '/')) && __zipos_get() && …)
```

`__zipos_get()` lazily initialises the singleton by opening and mapping _the running executable itself_ ([`libc/runtime/zipos-get.c`][ziposget]):

```c
if (!progpath) progpath = GetProgramExecutableName();
fd = open(progpath, O_RDONLY);
…
if (!fstat(fd, &st) &&
    (map = mmap(0, st.st_size, PROT_READ, MAP_SHARED, fd, 0)) != MAP_FAILED) {
  if ((cdir = GetZipEocd(map, st.st_size, &err))) {
    __zipos_dismiss(map, cdir, pagesz);
    __zipos.map = map; __zipos.cdir = cdir; __zipos.dev = st.st_ino;
    __zipos_generate_index(&__zipos);
```

Three details in that block carry the whole design.

1. **`MAP_SHARED`, not `MAP_PRIVATE`.** The archive is mapped shared and read-only, so every process running the same binary shares those page-cache pages.
2. **`__zipos_dismiss` immediately unmaps the executable half.** It walks the central directory to find the lowest local-file-header offset, rounds down to allocation granularity, and `munmap`s everything beneath it — so the mapping covers the ZIP records and not a second copy of the program's text.
3. **The index is built at startup, not read from the file.** `__zipos_generate_index` materialises an array of central-directory offsets and `qsort_r`s it by filename, so lookups are a binary search over names rather than a linear scan ([`libc/runtime/zipos-find.c`][ziposfind]). ZIP's central directory is unordered; the runtime pays an _O(n log n)_ startup cost to give itself the index ZIP declined to specify.

Point 3 is the first, smallest piece of evidence for the catalog's thesis that every binary format eventually reimplements a database badly: ZIP's "index" is an unsorted catalog with no ordering guarantee, so the consumer builds a real one in memory on every process start.

The filesystem is strictly read-only. `__zipos_open` rejects anything but `O_RDONLY` with `EROFS` ([`libc/runtime/zipos-open.c`][ziposopen]):

```c
if ((flags & O_CREAT) || (flags & O_TRUNC) || (flags & O_APPEND) ||
    (flags & O_ACCMODE) != O_RDONLY)
  return erofs();
```

and `ftruncate` on a zipos descriptor likewise returns `EROFS`. Writes to the archive therefore cannot go through the `/zip/` namespace at all — which is why redbean's `StoreAsset` writes to a raw file descriptor instead (below).

---

## Format identity and multiplicity

**Multiplicity: 3 / 3 — defining.** APE is the catalog's high-water mark on this axis and the reason the catalog exists. A single `redbean.com` is advertised by its own author as _"PE+ELF+MachO+ZIP+SH for AMD64 and ARM64"_ ([`redbean.dev`][redbean-dev]), and the byte-level survey above adds a sixth reader (MBR/BIOS) and a seventh (flat `.COM`-style execution from offset 0, which the [specification][spec] explicitly preserves).

What makes it work is that the participating formats disagree about _where identity lives_:

| Format        | Identity anchor               | Tolerance                                                            |
| ------------- | ----------------------------- | -------------------------------------------------------------------- |
| PE            | `MZ` at 0, `e_lfanew` at 0x3c | Prefix-anchored but **indirect** — the real header can be anywhere   |
| ELF           | `\177ELF` at 0                | Prefix-anchored and rigid — hence the `printf`/assimilate workaround |
| Mach-O        | magic at 0                    | Prefix-anchored and rigid — hence the `dd`-copy-backwards workaround |
| MBR           | `55 aa` at 0x1fe              | Offset-anchored; indifferent to everything else                      |
| Thompson `sh` | no magic at all               | Fully prefix-tolerant; the _absence_ of a shebang is the affordance  |
| PKZIP         | `EOCD` in the last 64 KiB     | Suffix-anchored; tolerates arbitrary prefix bytes                    |

Only two of the six are genuinely rigid, and both are handled not by coexistence but by _deferred rewriting_ — the file becomes a real ELF or Mach-O at first run. This is the honest reading of APE's multiplicity: it is a **superposition that collapses**. Before `--assimilate` the file is all of these at once; afterwards it is one of them (plus, still, the shell script and the ZIP, which survive because neither cares about the first 64 bytes).

That the shell's contribution is the _lack_ of a magic number is the deepest structural fact here. The [specification][spec] is describing an accident of 1975 Unix, and the `#'"` sequence emitted by `apelink` after the here-doc terminator exists purely so _"programs wanting a simple way for scanning over the actually portable executable mz stub"_ have a stable marker. The taxonomy question the catalog poses — which formats compose, derivable from where each anchors its index — is answered here in miniature: **prefix-tolerant × suffix-tolerant composes for free; prefix-rigid × prefix-rigid requires a rewrite.** See [polyglot craft][polyglot] for the general theory and [ZIP parasitism][zipparasite] for the suffix-tolerant family.

The cost is paid in alignment. The [specification][spec] is blunt about it: ELF requires file/virtual congruence modulo page size; PE requires 512-byte file alignment and 64 KiB virtual granularity; _"Apple's Mach-O format is the strictest of them all… XNU will simply refuse to [load] an executable that does anything creative with alignment."_ An APE binary must satisfy the intersection, meaning it must _"conform to the Apple way of doing things"_ — the strictest participant sets the layout for everyone. The specification also concedes that GNU `ld` was never really up to this (_"There are so many ways things can go wrong"_), which is why `apelink` exists.

The multiplicity does not extend to shared libraries, and the specification says why: _"While it was possible to polyglot PE+ELF+MachO to create multi-OS executables, it simply isn't possible to do that same thing for DLL+DYLIB+SO."_ APE is static-only by construction; `dlopen()` works only by loading a _platform-specific_ helper executable and delegating. See [dynamic linking][dynlink] for what that forecloses.

---

## Index anchoring and random access

**Anchoring: footer, over header-anchored executable headers.** The ZIP central directory is the only index in the file, and it lives at the end. `GetZipEocd` scans backwards from EOF for the ZIP64 locator magic, then for the classic `PK\5\6`, bounded to the last 64 KiB + 4 KiB ([`libc/str/getzipeocd.c`][eocd]):

```c
while (magic = ZIP_READ32(p + i),
       magic != kZipCdir64LocatorMagic && magic != kZipCdirHdrMagic &&
       i + 0x10000 + 0x1000 >= n && i > 0) { --i; }
```

with an SSE2 fast path that skips 13 bytes at a time when no `PK` byte pair occurs in a 16-byte window. The doc comment states the constraint the whole design rests on: _"The ZIP spec says this header can be anywhere in the last 64kb."_

Suffix-anchoring is what makes APE possible, and it is also what makes APE's random access _bad in one specific way_. Locating the index requires reading the tail; locating any given record requires the index. A consumer that has the whole file mapped — which is the only mode Cosmopolitan supports — pays nothing. A consumer holding a URL pays two round trips minimum, exactly as with any [footer-indexed format][footer]. Cosmopolitan never exercises that path: `__zipos_init` `mmap`s the entire file, so partial consumption is not a supported mode. The interesting counterfactual belongs to [range-request access][ranges]: nothing in the format prevents `GET Range: bytes=-65536` → parse `EOCD` → `GET` one local file header + its deflate stream, and redbean's `ServeAssetRange` already implements the server half of that for uncompressed assets.

Within the process, access is genuinely random and cheap:

- **Path lookup** is a binary search over the sorted offset array (`__zipos_scan`), _O(log n)_ in record count.
- **A stored (uncompressed) record needs no copy at all.** `__zipos_load` sets `h->mem = ZIP_LFILE_CONTENT(zipos->map + lf)` — a pointer straight into the shared read-only mapping ([`libc/runtime/zipos-open.c`][ziposopen]).
- **A deflated record is inflated once, eagerly, into a private anonymous mapping** sized to the uncompressed length. There is no streaming and no partial inflate; `open()` of a compressed asset costs a full decompression.

That asymmetry is a real design lever, and redbean's documentation exposes it to the user as a tuning knob ([`tool/net/help.txt`][helptxt]): _"Audio video content should not be compressed in your ZIP files. Uncompressed assets enable browsers to send Range HTTP request. On the other hand compressed assets are best for gzip encoding."_ The archive's compression method is simultaneously a storage decision, a latency decision, and an HTTP-semantics decision — the container is not a neutral wrapper.

redbean maintains a _second_ index over the same central directory: an open-addressed hash table keyed by a cheap additive hash of the path (`GetAssetZip`), rebuilt by `IndexAssets()` whenever `OpenZip` observes an inode or size change. So a running redbean holds one index for the libc's `/zip/` namespace and a different one for HTTP routing, over identical bytes. That duplication is the clearest local instance of the "binary formats reimplement a database, badly" thesis: two hand-rolled indexes with different structures, different invalidation rules, and no shared query surface, over one catalog.

---

## Reflexivity and query surface

**Reflexivity: 2 / 3 — designed-in, but as a namespace, not a query language.**

The self-inspection half of the axis scores high. The artifact interrogates itself at runtime by construction: `__zipos_get()` opens `GetProgramExecutableName()` and maps it, so the running program's asset store _is_ the file it is executing from. redbean goes further and exposes that reflection to its own scripting layer and to the network:

| Surface                     | What it answers                                                                                |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| `/zip/…` via POSIX `open()` | "give me the bytes of this asset" — the whole libc I/O surface, read-only                      |
| `GetZipPaths()` (Lua)       | _"Returns paths of all assets in the zip central directory"_ ([`help.txt`][helptxt])           |
| `GetAssetMode/Size/Comment` | per-record metadata from the central directory, without extracting the record                  |
| Directory listing over HTTP | redbean _"will generate a zip central directory listing"_ for `/` when no `index` asset exists |
| `/statusz`                  | live process counters (requests, deflates, precompressed responses) as `text/plain`            |
| `unzip -vl ./prog.com`      | the _external_ view — any ZIP tool can enumerate the artifact's contents                       |

The last row is the most interesting one, and [`ape.html`][ape-html] highlights it: _"It's possible to run `unzip -vl executable.com` to view its contents. It's also possible on Windows 10 to change the file extension to `.zip` and then open it in Microsoft's bundled ZIP GUI."_ The artifact is inspectable by tools that know nothing about it, because it deliberately conforms to a format those tools already speak. That is a real reflexivity property and it is why the ZIP tax buys something.

But the axis also asks for a _general query surface_, and here APE scores low, honestly. What you get is a hierarchical namespace with `open`/`stat`/`access`/`mmap` — the Plan 9 answer to reflection rather than the relational one (see [Plan 9 namespaces][plan9] and [relational system surfaces][relational]). You cannot ask "which assets are larger than 1 MiB and stored uncompressed" without writing a loop, and you cannot ask anything at all about the _executable_ half: the symbol table, the relocations, the segment layout, and the `DT_NEEDED`-equivalent are not exposed through `/zip/` or anywhere else. Precisely half the artifact is queryable. That asymmetry is the gap [sqlelf][sqlelf] and [SELF][self] step into, and it is the cleanest way to state what separates the two seeds of this catalog: **redbean makes its data self-describing and leaves its code opaque; SELF makes its code self-describing by making it data.**

One further limit is worth recording because it bounds any "query the artifact over the network" ambition: `__zipos_notat` refuses `*at()` calls with a zipos directory descriptor, so there is no `openat` traversal and no `getdents` over the archive; directories exist only as the synthetic `ZIPOS_SYNTHETIC_DIRECTORY` sentinel produced by prefix matching in `__zipos_match`.

---

## Closure, dedup, and size model

**Closure: 3 / 3 — defining.** Nothing travels beside the file. Cosmopolitan is a freestanding libc with its own syscall layer per OS; redbean statically links Lua 5.4, SQLite, MbedTLS, and zlib into the same artifact. The [specification][spec] makes staticness normative: _"Actually Portable Executables are always statically linked."_

Concrete numbers, all from primary sources:

| Artifact                           | Size          | Source                                          |
| ---------------------------------- | ------------- | ----------------------------------------------- |
| `redbean-3.0.0.com` (2024-08-17)   | 5.5 MB        | [`redbean.dev`][redbean-dev] download table     |
| `redbean-demo-3.0.0.com`           | 5.5 MB        | ibid.                                           |
| `build/bootstrap/cocmd` (in-clone) | 656,048 bytes | measured in the clone at `3293fad0`             |
| `build/bootstrap/ape.elf` (loader) | 9,249 bytes   | measured in the clone                           |
| `build/bootstrap/ape.aarch64`      | 8,728 bytes   | measured in the clone                           |
| `hello.com` (2020, single-arch)    | 16 KB         | [`ape.html`][ape-html]                          |
| `life.com` (2020, single-arch)     | 12 KB         | [`ape.html`][ape-html]                          |
| GPL source-embedding build         | ~10× larger   | [`ape.html`][ape-html] (`hello2.com` at 256 KB) |

The 2020 numbers are the sharp end of the argument — [`ape.html`][ape-html] claims exes end up _"roughly 100x smaller than Go Hello World"_ — and the 2024 numbers are the honest end: 5.5 MB for a fat two-architecture binary carrying an interpreter, a database engine, and a TLS stack.

**Deduplication: none, by construction, and this is the central trade.** Every APE binary carries its own libc; a directory of 50 cosmo tools carries 50 copies. The fat-binary story compounds it: `apelink` concatenates a complete per-architecture image, so an AMD64+ARM64 binary is roughly the sum of two builds, and the surveyed `cocmd` shows the second `Elf64_Ehdr` at file offset `0x60000` with its own program headers. A machine running such a binary maps one half and never touches the other. This is precisely the axis on which [Nix store closures][nix] and [content-addressed chunking][chunking] win and APE loses, and the axis on which [SELF's 611.9 MiB vs 5.53 GiB comparison][self] is a measurement of the same trade in a different regime.

Two mitigations exist in the design and both are partial:

1. **Shared page cache across processes of the same binary.** Because `__zipos_init` uses `MAP_SHARED` on a read-only mapping, and because the OS loader maps the text segment the usual way once the header is native, `N` concurrent redbean workers share one copy of code and of stored assets. `help.txt` names this as a design goal: _"redbean goes fast is that it's a tiny static binary, which makes fork memory paging nearly free."_
2. **`__zipos_dismiss`.** Without it the process would hold two mappings of the same executable bytes — the loader's and zipos's. Dismissing everything below the first local file header removes the duplicate.

The mitigations do not survive contact with compression or with `mmap` on an asset, and that is discussed under mutability below.

There is also a closure the format explicitly does _not_ achieve: extension modules. The [specification][spec] states that _"a Lua interpreter compiled as an Actually Portable Executable would have no way of linking extension libraries downloaded from the Lua Rocks package manager,"_ because the DSO formats do not polyglot. APE's closure is total within the artifact and empty outside it — there is no partial closure, no "carries its dependencies but can acquire more."

---

## Mutability, dispatch, and trust

**Mutability: 2 / 3 — designed-in, opt-in, append-only, and not transactional.**

### Three distinct self-modifications

APE binaries modify themselves at three different layers, and conflating them is the usual error:

| Layer             | What is written                                    | When                         | Reversible                        |
| ----------------- | -------------------------------------------------- | ---------------------------- | --------------------------------- |
| Assimilation      | the first 64 bytes (ELF) or a Mach-O header block  | first run, or `--assimilate` | Yes — `assimilate` keeps a `.bak` |
| Loader extraction | `$TMPDIR/.ape-<ver>` (a _different_ file)          | first run, when `APE_LOADER` | n/a                               |
| `StoreAsset`      | appended ZIP records + rewritten central directory | at runtime, under `-*`       | No                                |

`tool/build/assimilate.c` shows the first is genuinely a 64-byte write and nothing more:

```c
// tool/build/assimilate.c — WriteOutput (abridged)
} else if (g_clobber) {
  if (Pwrite(infd, hdr, hdrsize, 0) == -1) DieSys(path);
} else {
  /* … write a full copy to "<path>.bak" first … */
  if (Pwrite(infd, hdr, hdrsize, 0) == -1) DieSys(path);
}
```

Everything after byte 64 — the shell script, the PE headers, the Mach-O headers, the second architecture, the ZIP — is untouched. So an assimilated binary is _still_ a valid ZIP archive and still a valid shell script; only the polyglot's executable identity has collapsed to one. The tool also normalises `EI_OSABI` from `ELFOSABI_FREEBSD` back to `ELFOSABI_SYSV` on assimilation, with a comment explaining that the FreeBSD tag _"does whine"_ under `gdb` elsewhere.

### `StoreAsset`: an append-only log with a rewritten footer

redbean's writable path bypasses `/zip/` entirely — it must, since zipos returns `EROFS`. `StoreAsset` ([`tool/net/redbean.c`][redbeanc]) takes an `F_SETLKW` write lock on the executable's own descriptor, then issues a single 13-element `writev` at the old `EOCD` offset containing:

1. a new local file header + name + optional ZIP64 extra + the (possibly deflated) data;
2. **the entire old central directory, copied forward**, minus the record being replaced;
3. the new central-directory record;
4. a fresh ZIP64 `EOCD` + locator and a classic `EOCD`.

```c
// tool/net/redbean.c — StoreAsset (tail)
CHECK_NE(-1, lseek(zfd, zmap + zsize - zmap, SEEK_SET));
CHECK_NE(-1, WritevAll(zfd, v, 13));
CHECK_NE(-1, fcntl(zfd, F_SETLK, &(struct flock){F_UNLCK}));
```

Three consequences follow directly from that shape:

- **The file only grows.** The previous central directory and every superseded record remain in the file as unreferenced bytes. Deleting an asset removes its central-directory record, not its data. `help.txt` concedes the state of the art: _"This currently happens in an append-only fashion and is still largely in the proof-of-concept stages."_
- **Atomicity is `writev`-shaped, not transactional.** A crash mid-`writev` leaves the old `EOCD` overwritten and the new one incomplete — the archive is unreadable, and since the archive is the executable, the _program_ is damaged. There is no journal, no double-write, no `application_id` version counter. This is exactly the gap that makes [SQLite as an application file format][sqlitefmt] the obvious comparison, and it is the mechanical reason the catalog's fourth seed ([self-httpd][self]) reads as a strictly stronger position on this axis.
- **The write is a full central-directory rewrite,** so cost is _O(records)_ per store, not _O(1)_.

The compression choice is made per record at store time: below 100 bytes it is stored uncompressed; otherwise it is deflated and the deflate is kept only if it is actually smaller.

### `-*`: self-modification as an explicit capability

`StoreAsset` is unreachable unless the operator passes `-*`, documented as _"permit self-modification of executable."_ The flag sets `selfmodifiable`, which calls `MakeExecutableModifiable()` before `LuaInit()` — so Lua code cannot enable it at runtime.

`MakeExecutableModifiable` closes the read-only descriptor and calls `__open_executable()`, which historically performed a remarkable dance to defeat `ETXTBSY`. At commit [`38112aeb`][oldsha] it is hand-written assembly whose own comment states the problem ([`libc/runtime/openexecutable.S`][openexecS]):

> _"To avoid ETXTBSY we need to unmap the running executable first, then open the file, and finally load the code back into memory."_

The routine copies its own code into a fresh anonymous page, `mprotect`s it `PROT_READ|PROT_EXEC`, jumps into it (the source labels the region `<LIMBO>`), `munmap`s the program's `.text` and data segments out from under itself, `open`s the file `O_RDWR` — falling back to `O_RDONLY` on failure — and re-`mmap`s the segments. The program is, for a few instructions, a process with no executable image.

> [!IMPORTANT]
> **At the surveyed revision this capability is disabled.** `libc/runtime/openexecutable.c` at `3293fad0` is a stub that prints _"error: redbean StoreAsset() support is currently unavailable because `__open_executable()` in a regressed state, due to the work we're doing on Arm64 support"_ and calls `exit(1)`. `StoreAsset` additionally `FATALF`s on Windows, NetBSD, and OpenBSD in all versions. The most-cited example of a self-mutating autological artifact is, today, a proof of concept that does not build on its own trunk.

That is not a minor asterisk. It is the honest measure of how hard the mutability axis is when the state store and the executable image are the same bytes — and it is direct evidence for the catalog's claim that **`mmap` is the load-bearing constraint**. The obstacle is not ZIP and not the writer; it is that a Unix kernel will not let you open your own text for writing while it is mapped, and unmapping your own text is architecture-specific enough to have regressed on the ARM64 port.

### Page sharing, and where it is lost

APE preserves demand paging and cross-process text sharing _for the executable_, because after assimilation the file is loaded by the platform's own loader in the ordinary way. That is a genuine advantage over any "the executable is a database" design and the axis on which [SELF][self] currently loses.

But APE loses sharing in two places of its own:

1. **Compressed assets.** Each process inflates each compressed asset it opens into its own `MAP_PRIVATE|MAP_ANONYMOUS` region. Ten workers opening the same 4 MiB compressed asset hold ten copies. Uncompressed assets are shared; compressed ones are not. The `-0` advice in `help.txt` is therefore also a memory-residency knob.
2. **`mmap()` on a `/zip/` file never shares.** `__zipos_mmap` rejects `MAP_SHARED` outright and the doc comment gives the reason ([`libc/runtime/zipos-mmap.c`][ziposmmap]): _"`MAP_SHARED` could be simulated for non-writable mappings, but that would require tracking zipos mappings to prevent making it `PROT_WRITE`."_ It allocates anonymous private memory, reads the record into it, and re-`mprotect`s. So mapping an asset always costs a private copy, even for a stored record already resident in the shared mapping.

The second point is worth dwelling on because it _reverses_ the naive intuition. A stored asset read with `read()` is zero-copy (the handle points into the shared map), while the same asset `mmap`'d is a full private copy. The archive layer's cheapest access path is the one that looks most expensive.

### Trust

The threat surface is unusually broad and the project is unusually explicit about it. See [threat model][threat] for the general treatment; the APE-specific facts are:

- **Registering `binfmt_misc` requires root** and installs a persistent, system-wide rule mapping a two-word magic to an interpreter path. `apeinstall.sh` does this with `sudo`/`doas` and the `F` flag pins the interpreter inode at registration.
- **Existing `binfmt_misc` rules are the primary failure mode.** `README.md`: _"Some Linux systems are configured to launch MZ executables under WINE. Other distros configure their stock installs so that APE programs will print `run-detectors: unable to find an interpreter`."_ On WSL the situation is worse: _"It's normally unsafe to use APE in a WSL environment, because it tries to run MZ executables as WIN32 binaries within the WSL environment,"_ with the documented fix being `echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop` — i.e. disabling the host's Windows interop entirely. Dispatch by magic number is a _global namespace with no owner_, and APE's magic collides with the most contested prefix in it.
- **A non-assimilated APE needs `PROT_EXEC` mmap.** `redbean.dev`'s pledge documentation lists `prot_exec` as needed _"to launch non-static non-native executables, such as non-assimilated APE binaries."_ The loader path is strictly more privileged than the assimilated path.
- **`$TMPDIR/.ape-<ver>` is an executable dropped into a world-writable directory** and then `exec`'d. `mv -f` gives atomic publication, but the file is trusted on subsequent runs purely because it exists and is executable (`[ -x "$t" ] || { … }`). There is no digest check.
- **Sandboxing composes unusually well with the autological design.** redbean's `-SSS` level calls `unix.pledge("stdio")` on workers after `fork()`, and `help.txt` observes: _"Redbean should only be able to serve from its own zip file in this mode."_ Because the archive was `mmap`ed before the sandbox was entered, a fully filesystem-denied worker can still serve every asset. Self-containment turns out to be a _security_ property, not only a distribution one — the least-privilege decomposition the catalog asks about falls out for free on the read path.
- **Conversely, zipos initialisation itself needs `rpath`**: `__zipos_init` only opens the executable if `PLEDGED(RPATH)`, unless the caller supplies `COSMOPOLITAN_INIT_ZIPOS` as a pre-opened file descriptor number. The escape hatch exists precisely because the sandbox and the self-open are in tension at startup.
- **Signing is unaddressed.** An assimilated binary has had its first 64 bytes rewritten, so any signature over the distributed bytes is invalid afterwards; a `StoreAsset`-ing redbean rewrites its own tail continuously. Neither Authenticode, nor Apple notarisation, nor a detached signature survives the design as shipped. See [embedded provenance][provenance] for the general problem and [`docs/research/application-packaging/`][pkg] for how the distribution-side ecosystems handle it.

### Dispatch, summarised

Who decides what the file is, in priority order, is written into the shell prologue itself:

1. **A system-wide `ape` on `PATH`** — `type ape >/dev/null 2>&1 && exec ape "$o" "$@"`.
2. **A previously extracted `$TMPDIR/.ape-1.10`** — `[ -x "$t" ] && exec "$t" "$o" "$@"`.
3. **Extract the embedded loader** (`dd | gzip -dc`), or on Apple Silicon compile `ape-m1.c`.
4. **Assimilate**: `printf` the ELF header over the first 64 bytes and `exec "$0" "$@"`.
5. Failing all of that: `echo "$0: this ape program lacks $m support" >&2; exit 127`.

Ahead of all five sits `binfmt_misc`, if registered, which bypasses the shell entirely. The file therefore contains its own dispatch policy, written in the one language every Unix already has an interpreter for — which is the most autological thing about it, and the point where the catalog's dispatch cluster ([`binfmt-misc.md`][binfmt]) and its polyglot cluster meet.

---

## Strengths

- **Unmatched multiplicity.** Six-plus simultaneous readers of one byte stream — verifiable with `file(1)` (which reports `DOS/MBR boot sector` on the surveyed `cocmd`), `unzip -vl`, a Windows Explorer ZIP view, and a BIOS. Nothing else in this catalog is close.
- **Genuine zero-install portability** across six operating systems and two architectures, with a documented, narrow support floor (Linux 2.6.18 / 2007, Windows 8 / 2012, FreeBSD 13, macOS 23.1.0).
- **Preserves demand paging and cross-process text sharing**, because after assimilation the platform's own loader does the work. The "the executable is X" designs generally do not.
- **The container earns its keep.** ZIP's deflate is gzip's deflate, so `ServeAssetPrecompressed` synthesises a gzip header and footer and writes the archive's stored bytes straight to the socket — no inflate, no recompress. `help.txt` reports _"1 million+ gzip encoded responses per second on a cheap personal computer… thanks to zip and gzip using the same compression format, which enables kernelspace copies,"_ and `redbean.dev` reports 5.3 million qps on a Threadripper. The archive _is_ the HTTP cache.
- **Externally inspectable.** Any ZIP tool can enumerate and edit the artifact's assets; `zip prog.com index.html` is the documented deployment step.
- **Self-containment as a security property.** A `pledge("stdio")` worker with no filesystem access can still serve every asset, because the archive is already mapped.
- **The format is specified**, versioned, and written down ([`ape/specification.md`][spec]) — including the backward-compatibility regex for three historical `dd` encodings. That is more rigour than most polyglot work receives.
- **An escape hatch exists**: `--assimilate` converts to a plain native binary in a 64-byte write, so the cleverness can be discarded at any point without rebuilding.

## Weaknesses

- **The superposition collapses on first run.** Absent `binfmt_misc` or a system `ape`, the "portable" file either rewrites itself or drops an executable in `$TMPDIR`. The steady state is a native binary or a native loader — the polyglot is a delivery mechanism, not a runtime property.
- **On Apple Silicon, first run invokes a C compiler.** `cc -w -O -o "$t.$$" "$t.c"` on a gzipped-in `ape-m1.c`, requiring Xcode Command Line Tools on the target.
- **`binfmt_misc` collisions are the dominant real-world failure**: WINE, `run-detectors`, and WSL's `WSLInterop` all claim `MZ` first, and the documented remedies require root and disable host functionality.
- **Self-modification is regressed and always was narrow.** `__open_executable()` is a `exit(1)` stub at the surveyed revision; `StoreAsset` never supported Windows, NetBSD, or OpenBSD; the writes are append-only with no reclamation and no crash atomicity.
- **No deduplication whatsoever.** Every binary carries a full libc; a fat binary carries two complete images, one of which is dead weight on any given machine.
- **No dynamic linking, ever.** The specification rules out polyglot DSOs, so no language extension ecosystem (LuaRocks, Python wheels with native code) is reachable.
- **`mmap` of an asset always copies**, and compressed assets are inflated per process — so the page-sharing win applies only to code and stored records.
- **Signing is incompatible with the design as shipped**, in both the assimilation and the `StoreAsset` directions.
- **Half the artifact is opaque.** The queryable surface covers assets only; symbols, relocations, and segments are not exposed through any interface the artifact provides.
- **Alignment is dictated by the strictest participant** (XNU), inflating files and constraining the linker to the point that a bespoke linker (`apelink`) had to be written.
- **Ecosystem hostility is a standing cost**: the `jartsr='` magic exists solely because `MZqFpD='` attracts antivirus attention, and macOS Gatekeeper requires documented `spctl` workarounds.

---

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                                               | Trade-off                                                                                                                    |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Lead with `MZ`, use the Thompson-shell no-shebang rule              | The one prefix that PE requires and `sh` tolerates; lets the file carry its own dispatch policy in a universal language | Collides with WINE / `run-detectors` / WSL interop; attracts AV heuristics; needs the alternate `jartsr='` magic             |
| `printf` the ELF header instead of storing it at offset 0           | Offset 0 belongs to `MZ`; ELF is prefix-rigid and cannot share it                                                       | Requires a write to the executable (or an out-of-line loader); breaks any signature over the distributed bytes               |
| Cap header discovery at the first 8192 bytes                        | Bounded parse: an interpreter reads one or two pages to identify the file                                               | Constrains how much shell logic and how many architectures fit in the prologue                                               |
| Content-derived here-doc terminator (`justine` + 6 base-36 BLAKE2b) | The binary DOS/MBR stub must never accidentally contain the terminator                                                  | Non-reproducible-looking output; tools must scan for the stable `#'"` marker instead                                         |
| Append PKZIP rather than invent an asset container                  | Suffix-anchored index composes with prefix-anchored executables for free; every ZIP tool becomes an authoring tool      | Index costs a backwards scan; no ordering guarantee, so the runtime must build and sort its own index at every startup       |
| Expose the archive as read-only `/zip/` in libc                     | Existing C code that calls `open()` works unmodified against embedded assets                                            | `EROFS` on any write, so a writer must bypass the abstraction and touch the raw fd; no `openat` traversal, no `getdents`     |
| `MAP_SHARED` the executable, then `munmap` the code half            | Stored assets are served straight out of the page cache and shared across `fork`ed workers                              | Compressed assets and any `mmap`'d asset are private per-process copies                                                      |
| Ship an embedded loader as an alternative to assimilation           | Works on read-only filesystems and preserves the distributed bytes                                                      | Drops an unverified executable in `$TMPDIR`; needs `prot_exec`; on Apple Silicon needs a C compiler at runtime               |
| Static linking only; no polyglot DSO format                         | `DLL`+`DYLIB`+`SO` cannot be superposed; a parallel extension ecosystem was out of scope                                | No native extension modules for any embedded language; total closure or nothing                                              |
| Gate self-modification behind `-*`                                  | Writable text-adjacent bytes is a W^X question; the operator, not the script, should decide                             | The catalog's headline mutable-artifact example is opt-in, platform-limited, and currently regressed to a stub               |
| Append-only `StoreAsset` with a full central-directory rewrite      | Simplest correct ZIP mutation; readers see a consistent footer or none                                                  | Monotonic growth, no reclamation, _O(records)_ per write, and no crash atomicity for a file that is also the running program |
| Prefer `binfmt_misc` (`F`+`P`) over the shell path                  | Removes the shell, the rewrite, and the temp file; ~400 µs faster per launch                                            | Needs root, a persistent global registration, and a kernel ≥ 5.12 for `P`                                                    |

---

## Where this sits in the catalog

APE is the strongest available datum for **thesis 5 — portability has migrated from the format to the access layer.** APE achieves reach by satisfying every loader's parse simultaneously: an 8-byte magic that is four different programs, a here-doc terminator derived from a hash to avoid self-collision, a `dd` command whose textual form is normative, a bespoke linker because GNU `ld` could not hold the invariants, and a per-OS TLS rewriting pass (`tlscc`, plus 32 `__get_tls_*`/`__add_tls_*` thunks) because AMD64 operating systems cannot agree on `%fs` versus `%gs`. That is an extraordinary quantity of cleverness spent at the format level, and the specification's own roadmap — patch the Linux kernel; register `binfmt_misc`; assimilate on first run — describes a strategy trying to stop being a format trick. The contrast with holding one format fixed and swapping the substrate beneath it is stark; see [SELF/selfdb][self] and the [comparison][comparison].

It is also the strongest evidence _against_ **thesis 3 — the container is a tax.** ZIP is not overhead here: it is the reason `unzip` and Explorer can edit the artifact, the reason `zip prog.com asset.html` is the deployment step, and — via the deflate/gzip identity — the reason redbean can answer a compressed HTTP request without touching a compressor. The tax framing holds when the container is a pure wrapper; it fails when the container's format is shared with a consumer protocol. That is a refinement the catalog should carry forward.

On **thesis 1 — every binary format eventually reimplements a database, badly** — APE supplies a small but clean instance: ZIP's central directory is an unordered catalog, so Cosmopolitan sorts its own index at startup and redbean builds a _second_, differently-structured hash index over the same records, with independent invalidation.

On **thesis 4 — `mmap` is the load-bearing constraint** — APE both confirms and complicates it. It confirms it in the negative: the single feature that most defines APE as a _mutable_ artifact is disabled at the surveyed revision because unmapping your own text to reopen it `O_RDWR` is architecture-specific and regressed on ARM64. It complicates it because APE demonstrates that preserving demand paging for _code_ does not automatically preserve sharing for _data_ — `__zipos_mmap`'s refusal of `MAP_SHARED` costs a private copy on the very path that looks cheapest.

---

## Sources

- [`jart/cosmopolitan` — GitHub repository][repo] (surveyed at `3293fad0`, 2026-07-19)
- [`ape/specification.md` — Actually Portable Executable Specification v0.1][spec]
- [`ape/ape.S` — the MZ/ELF prologue, the DOS/BIOS stub, and the shell script][apeS]
- [`ape/ape.lds` — the linker script, including the `.zip.file`/`.zip.cdir`/`.zip.eocd` output section][lds]
- [`ape/loader.c` — the embeddable APE interpreter, `printf`-header scanning, `AT_FLAGS_PRESERVE_ARGV0`][loader]
- [`ape/ape-m1.c` — the Apple Silicon loader compiled on the target at first run][apem1]
- [`ape/apeinstall.sh` — `binfmt_misc` registration with the `F`/`P` flags][apeinstall]
- [`ape/BUILD.mk` — `APE_NO_MODIFY_SELF` / `APE_COPY_SELF` / `APE_LOADER`][buildmk]
- [`ape/ape.h` — `APE_VERSION_STR`, the `$TMPDIR/.ape-<ver>` suffix][apeh]
- [`tool/build/apelink.c` — fat-binary linking and the BLAKE2b-derived here-doc terminator][apelink]
- [`tool/build/assimilate.c` — the 64-byte collapse, the `dd` back-compat regex][assimilate]
- [`tool/net/redbean.c` — `OpenZip`, `GetAssetZip`, `StoreAsset`, `MakeExecutableModifiable`, `ServeAssetPrecompressed`][redbeanc]
- [`tool/net/help.txt` — redbean's manual: flags, `-*`, `StoreAsset`, `-S` pledge levels][helptxt]
- [`libc/runtime/zipos-parseuri.c` — the `/zip` prefix test][parseuri]
- [`libc/runtime/zipos-get.c` — self-`mmap`, `__zipos_dismiss`, `__zipos_generate_index`][ziposget]
- [`libc/runtime/zipos-open.c` — `EROFS` on write, zero-copy stored records, eager inflate][ziposopen]
- [`libc/runtime/zipos-find.c` — binary search over the sorted central directory][ziposfind]
- [`libc/runtime/zipos-mmap.c` — why `MAP_SHARED` is refused][ziposmmap]
- [`libc/str/getzipeocd.c` — the backwards `EOCD` scan and its 64 KiB bound][eocd]
- [`libc/runtime/openexecutable.c` — the regressed stub at the surveyed revision][openexecC]
- [`libc/runtime/openexecutable.S` at `38112aeb` — the historical `ETXTBSY` unmap-and-reopen routine][openexecS]
- [`README.md` — platform notes: WINE, `run-detectors`, WSL, the support-vector table][readme]
- [Justine Tunney, "Actually Portable Executable", 2020-08-24][ape-html] (archived; `justine.lol` currently serves an expired certificate)
- [`redbean.dev` — downloads, sizes, benchmarks, platform installation notes][redbean-dev] (archived)
- [Linux `binfmt_misc` administrator documentation][binfmt-kdoc]
- [Linux commit `2347961b11d4`, "binfmt_misc: pass binfmt_misc flags to the interpreter" (first in v5.12)][kcommit]
- [PKWARE `APPNOTE.TXT` — the ZIP format specification][appnote]
- Related in this catalog: [ZIP parasitism][zipparasite] · [polyglot craft][polyglot] · [boot hybrids][boothybrids] · [`binfmt_misc`][binfmt] · [footer-indexed formats][footer] · [range-request access][ranges] · [SELF/selfdb][self] · [sqlelf][sqlelf] · [threat model][threat] · [dynamic linking][dynlink] · [parser differentials][differentials] · [measurement][measurement] · [comparison][comparison]

<!-- References -->

[repo]: https://github.com/jart/cosmopolitan
[spec]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/specification.md
[apeS]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/ape.S
[lds]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/ape.lds
[loader]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/loader.c
[apem1]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/ape-m1.c
[apeinstall]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/apeinstall.sh
[buildmk]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/BUILD.mk
[apeh]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/ape.h
[apelink]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/build/apelink.c
[assimilate]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/build/assimilate.c
[redbeanc]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/net/redbean.c
[helptxt]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/net/help.txt
[parseuri]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/zipos-parseuri.c
[ziposget]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/zipos-get.c
[ziposopen]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/zipos-open.c
[ziposfind]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/zipos-find.c
[ziposmmap]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/zipos-mmap.c
[eocd]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/str/getzipeocd.c
[openexecC]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/openexecutable.c
[openexecS]: https://github.com/jart/cosmopolitan/blob/38112aeb206cc95ef615c268ca809cad693ecb9e/libc/runtime/openexecutable.S
[oldsha]: https://github.com/jart/cosmopolitan/commit/38112aeb206cc95ef615c268ca809cad693ecb9e
[readme]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/README.md
[ape-html]: https://web.archive.org/web/20241231023508/https://justine.lol/ape.html
[redbean-dev]: https://web.archive.org/web/20241228051038/https://redbean.dev/
[binfmt-kdoc]: https://docs.kernel.org/admin-guide/binfmt-misc.html
[kcommit]: https://github.com/torvalds/linux/commit/2347961b11d4079deace3c81dceed460c08a8fc1
[appnote]: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
[pkg]: ../../application-packaging/index.md
[zipparasite]: ../zip-parasitism.md
[polyglot]: ../polyglot-craft.md
[boothybrids]: ../boot-hybrids.md
[binfmt]: ../binfmt-misc.md
[footer]: ../footer-indexed-formats.md
[ranges]: ../range-request-access.md
[self]: ../self-selfdb/index.md
[sqlelf]: ../sqlelf.md
[threat]: ../threat-model.md
[dynlink]: ../dynamic-linking.md
[differentials]: ../parser-differentials.md
[measurement]: ../measurement.md
[comparison]: ../comparison.md
[nix]: ../nix-store-closures.md
[chunking]: ../content-addressed-chunking.md
[sqlitefmt]: ../sqlite-application-file-format.md
[plan9]: ../plan9-namespaces.md
[relational]: ../relational-system-surfaces.md
[provenance]: ../embedded-provenance.md
