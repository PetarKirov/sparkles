# `binfmt_misc` (Linux kernel facility)

The kernel subsystem that turns a byte pattern in a file's first 256 bytes into a choice of interpreter — the dispatch primitive that lets a self-describing artifact be `chmod +x`'d and run like anything else.

| Field           | Value                                                                                                         |
| --------------- | ------------------------------------------------------------------------------------------------------------- |
| Kind            | Kernel facility (binary-format dispatcher) + a single-superblock pseudo-filesystem                            |
| Language        | C (`fs/binfmt_misc.c`, 1047 lines at the surveyed revision)                                                   |
| License         | `GPL-2.0-only` (SPDX header of `fs/binfmt_misc.c`)                                                            |
| Repository      | [`torvalds/linux`][linux] · `fs/binfmt_misc.c` [(pinned)][bm-src]                                             |
| Documentation   | [`Documentation/admin-guide/binfmt-misc.rst`][bm-doc]                                                         |
| First release   | Linux 2.1.43 (1997) — see the [dating caveat](#dating-caveat)                                                 |
| Axis profile    | Multiplicity 1 / Reflexivity 2 / Closure 1 / Mutability 0                                                     |
| Index anchoring | Header — a bounded prefix window of `BINPRM_BUF_SIZE` = 256 bytes; the handler registry itself is out-of-band |
| Dispatch owner  | **Kernel** (this page is the definition of that answer)                                                       |

> **Latest revision surveyed:** mainline `v7.1-rc6`, commit `e43ffb69e0438cddd72aaa30898b4dc446f664f8` (2026-05-31), plus the unmerged `vfs-7.3.binfmt` branch of [`vfs/vfs.git`][vfs-log] at `68aabd01ddd26ced458a9e5716a640eaf8e4b7a6` (2026-08-03). **Platform:** Linux only; `CONFIG_BINFMT_MISC`.

---

## Overview

### What it solves

`execve(2)` has to answer one question before it can do anything else: _what is this file?_ Linux answers it by walking a linked list of `struct linux_binfmt` handlers and offering each one the first `BINPRM_BUF_SIZE` bytes of the file until one claims it ([`fs/exec.c`][exec-src], `search_binary_handler`). Two handlers ship with fixed answers: `binfmt_elf` claims anything whose first four bytes are `\x7fELF`, `binfmt_script` claims anything starting `#!`. `binfmt_misc` is the third, and the only one whose answer is _configured at runtime by userspace_.

A registration says: **at byte offset _N_, under mask _M_, these bytes mean "run interpreter _I_ on this file"**. That is the whole idea. Everything downstream of it — Java `.class` files running by name, Wine picking up `MZ` executables, `qemu-user-static` running an aarch64 rootfs on x86-64, [APE binaries][ape] skipping their own shell-script self-extraction stub, [SELF binaries][self] executing straight out of a SQLite b-tree — is one registration string plus an interpreter.

For this catalog `binfmt_misc` is the load-bearing entry in cluster D of the source outline: it is _the_ mechanism by which a byte stream that satisfies several formats at once gets assigned exactly one behavior. A polyglot is inert until something dispatches on it. `binfmt_misc` is that something, for the case where the dispatcher is the operating system rather than a shell, a loader, or a consumer's sniffing heuristic.

### Design philosophy

The philosophy is stated in the file's own header comment, and it is deliberately thin:

> _"binfmt_misc detects binaries via a magic or filename extension and invokes a specified wrapper."_
>
> — [`fs/binfmt_misc.c`][bm-src], lines 6–7

Two things follow from that sentence and are visible everywhere in the implementation.

**The kernel does not parse the file.** It compares bytes. There is no format model, no length field, no validation of what the interpreter will find. `search_binfmt_handler` is nine lines of XOR-and-mask:

```c
/* fs/binfmt_misc.c — search_binfmt_handler() */
s = bprm->buf + e->offset;
if (e->mask) {
        for (j = 0; j < e->size; j++)
                if ((*s++ ^ e->magic[j]) & e->mask[j])
                        break;
} else {
        for (j = 0; j < e->size; j++)
                if ((*s++ ^ e->magic[j]))
                        break;
}
if (j == e->size)
        return e;
```

**Policy lives in userspace, expressed as a string.** The registration is a single `write(2)` of an ASCII record whose _field delimiter is its own first byte_ (`del = *p++` in `create_entry`). The record declares its own grammar before it declares anything else — a small autological joke inside the mechanism this catalog cares about. The entry that results is not a parsed copy: `create_entry` does one `kmalloc` of `sizeof(Node) + count + 8`, copies the user string into the tail of that allocation, and leaves `e->name`, `e->magic`, `e->mask` and `e->interpreter` as interior pointers into it, NUL-terminated in place. **The kernel's handler table _is_ the registration strings**, parsed by pointer arithmetic and never re-serialized.

---

## How it works

### The exec loop and where `binfmt_misc` sits in it

`exec_binprm` ([`fs/exec.c`][exec-src]) runs a bounded rewrite loop. Each round reads the first 256 bytes (`prepare_binprm`), calls the LSM hook `security_bprm_check`, and walks the format list. A format that wants to _delegate_ rather than _load_ sets `bprm->interpreter` and returns 0; the loop then swaps `bprm->file = bprm->interpreter` and goes round again.

```c
/* fs/exec.c — exec_binprm() */
/* This allows 4 levels of binfmt rewrites before failing hard. */
for (depth = 0;; depth++) {
        struct file *exec;
        if (depth > 5)
                return -ELOOP;

        ret = search_binary_handler(bprm);
        if (ret < 0)
                return ret;
        if (!bprm->interpreter)
                break;

        exec = bprm->file;
        bprm->file = bprm->interpreter;
        bprm->interpreter = NULL;
        ...
}
```

`binfmt_misc` registers itself with `insert_binfmt`, not `register_binfmt` — and the difference is `list_add` versus `list_add_tail` ([`fs/exec.c`][exec-src], `__register_binfmt`). **`binfmt_misc` is at the head of the format list and gets first refusal on every `execve` on the system**, ahead of both ELF and `#!`. Within `binfmt_misc`, `add_entry` also uses `list_add`, which is why the documentation warns: _"Think about the order of adding entries! Later added entries are matched first!"_

Both facts matter for a polyglot. A file that is simultaneously a valid ELF and something else will be claimed by the `binfmt_misc` entry if one matches, because ELF never gets asked. That is precisely how a SELF binary — which is not an ELF at all — and how an APE binary — which _is_ a valid ELF, and would otherwise run its own shell stub — get redirected.

### The registration string

```text
:name:type:offset:magic:mask:interpreter:flags
```

| Field         | Parsed by                                | Constraints (enforced in `create_entry`)                                                                        |
| ------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| _delimiter_   | `del = *p++`                             | Byte 0 of the write; any byte, and it may not collide with a flag letter                                        |
| `name`        | `strchr(p, del)`                         | Non-empty, not `.` or `..`, no `/` — it becomes a file in the mount                                             |
| `type`        | `switch (*p++)`                          | `M` (magic) or `E` (extension); anything else is `-EINVAL`                                                      |
| `offset`      | `kstrtoint(p, 10, &e->offset)`           | Decimal, `>= 0`; empty means 0; ignored for `E`                                                                 |
| `magic`       | `scanarg` then `string_unescape_inplace` | `\xNN` escapes; parsing halts at the first NUL; must be non-empty                                               |
| `mask`        | same                                     | Optional (empty ⇒ `NULL` ⇒ exact match); if present, must decode to exactly `e->size` bytes                     |
| `interpreter` | `strchr(p, del)`                         | Non-empty absolute path (or, for the new `B` type, a bpf handler name)                                          |
| `flags`       | `check_special_flags`                    | A run of `P`, `O`, `C`, `F`; the scan stops at the first unrecognised letter, then a trailing `\n` is permitted |

The size envelope is small and explicit:

```c
/* fs/binfmt_misc.c — create_entry() */
if ((count < 11) || (count > MAX_REGISTER_LENGTH))   /* MAX_REGISTER_LENGTH == 1920 */
        goto out;
...
e->size = string_unescape_inplace(e->magic, UNESCAPE_HEX);
if (e->mask &&
    string_unescape_inplace(e->mask, UNESCAPE_HEX) != e->size)
        goto einval;
if (e->size > BINPRM_BUF_SIZE ||
    BINPRM_BUF_SIZE - e->size < e->offset)
        goto einval;
```

> [!WARNING]
> **The documentation understates the window.** [`binfmt-misc.rst`][bm-doc] still says _"the magic must reside in the first 128 bytes of the file, i.e. offset+size(magic) has to be less than 128"_. The code checks against `BINPRM_BUF_SIZE`, which has been **256** since commit [`6eb3c3d0a52d` "exec: increase BINPRM_BUF_SIZE to 256"][c-bufsize] (Oleg Nesterov, 2019-03-07, released in `v5.1`). So `offset + size <= 256` is what is actually enforced, in both mainline and the `vfs-7.3.binfmt` branch. The doc's third restriction — _"the interpreter string may not exceed 127 characters"_ — has **no corresponding check** in `create_entry`; the only bound is `MAX_REGISTER_LENGTH` on the whole record. Both are documentation drift, and both are the kind of drift a consumer will discover the hard way.

Escaping is worth one more note: `scanarg` accepts `\xNN` but `string_unescape_inplace` "will stop at the first [NUL] it encounters" (the code's own comment). A magic that needs an embedded zero byte must therefore be written `\x00` _and_ the decoder still truncates there — the documentation's instruction to _"escape any NUL bytes"_ is about the escape form, not an exemption from the truncation.

### `M` versus `E`: content dispatch and name dispatch

The `E` (extension) path never looks at the file. It looks at the _path_:

```c
/* fs/binfmt_misc.c — search_binfmt_handler() */
char *p = strrchr(bprm->interp, '.');
...
if (!test_bit(Magic, &e->flags)) {
        if (p && !strcmp(e->magic, p + 1))
                return e;
        continue;
}
```

`bprm->interp` starts as `bprm->filename` and is rewritten by `bprm_change_interp` on each delegation round. Extension matching is therefore _name-based dispatch inside the kernel_, case-sensitive, with the same failure mode every name-based type system has: rename the file and it becomes a different kind of thing. It is the DOS answer, kept for `.com`/`.exe` compatibility, and it is the one dispatch mode in this catalog where the bytes are irrelevant. Everything interesting uses `M`.

### Magic with a mask, at an offset — and why the offset is not enough

The `M` path is a masked comparison in one contiguous window. There is exactly **one** `(offset, magic, mask)` triple per entry; you cannot express "these four bytes here _and_ those four bytes there". You can only widen the window and mask out the middle.

[SELF][self] needs exactly that: it must match SQLite's `SQLite format 3\0` at byte 0 _and_ the `application_id` at byte 68, while ignoring bytes 16–67 (page size, format versions, change counter — all of which vary between databases). The NixOS module spans both:

```nix
# selfdb — nix/module.nix
# binfmt_misc match: SQLite files ('SQLite format 3\0') whose 4-byte
# big-endian application_id at offset 68 is 'SELF' (0x53454C46). We
# match a 72-byte window from offset 0 and mask out bytes 16..67, which
# vary between databases, so ordinary SQLite files never match.
```

That is a 72-byte magic and a 72-byte mask, which is fine against the 256-byte cap but would not have been under an offset-only scheme with a short magic. It also shows the price of the single-window design: 52 of the 72 bytes carry no information and exist only to bridge two real anchors.

The reason it works at all is that SQLite put its application-format tag _near the front_. The [SQLite file format spec][sqlite-fmt] is explicit that this was for exactly this kind of consumer:

> _"The 4-byte big-endian integer at offset 68 is an 'Application ID' that can be set by the `PRAGMA application_id` command in order to identify the database as belonging to or associated with a particular application. … The application ID can be used by utilities such as `file(1)` to determine the specific file type rather than just reporting 'SQLite3 Database'."_

Substitute `binfmt_misc` for `file(1)` and the design intent transfers unchanged. **A format whose identity tag lives outside the first 256 bytes cannot be dispatched by the Linux kernel at all** — which is the whole reason [ZIP-suffix parasitism][zip] needs a _prefix_ host format (a stub, an ELF header, an `MZ`) rather than being executable on its own. See [Footer-indexed formats][footer] for the general shape of that constraint.

### The four flags

`check_special_flags` scans a run of letters and ORs bits into `e->flags`. All four affect _how the interpreter is invoked_, none affect matching.

| Flag | Bit                       | Effect in `load_misc_binary`                                                                                                                     |
| ---- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `P`  | `MISC_FMT_PRESERVE_ARGV0` | Sets `BINPRM_FLAGS_PRESERVE_ARGV0` instead of calling `remove_arg_zero(bprm)`, so the caller's `argv[0]` survives as a third string              |
| `O`  | `MISC_FMT_OPEN_BINARY`    | Sets `bprm->have_execfd = 1`; `begin_new_exec` then installs the binary as fd 0 and reports it as `AT_EXECFD`                                    |
| `C`  | `MISC_FMT_CREDENTIALS`    | Sets `bprm->execfd_creds = 1`, so `bprm_creds_from_file` derives uid/gid and the LSM token from **the binary**, not the interpreter. Implies `O` |
| `F`  | `MISC_FMT_OPEN_FILE`      | Opens the interpreter **at registration time** and stores the `struct file *`; each exec uses `file_clone_open` on it                            |

Without `P`, the kernel builds `argv` as `[interpreter, <binary path>, <caller's argv[1:]>]` — `remove_arg_zero` drops the caller's `argv[0]` and two `copy_string_kernel` calls push the binary path and then the interpreter path in front. With `P`, `argv[0]` is kept and the vector becomes `[interpreter, <binary path>, <caller's argv[0]>, …]`, which the documentation spells out per element.

#### `F` — the flag that makes containers work

`F` is the reason `binfmt_misc` is usable at all in a container, and it is worth reading its introduction verbatim. From James Bottomley's commit ([`948b701a607f`][c-fixbinary], merged for `v4.8`):

> _"This patch adds a new flag 'F' to the binfmt handlers. If you pass in 'F' the binary that runs the emulation will be opened immediately and in future, will be cloned from the open file. The net effect is that the handler survives both changeroots and mount namespace changes, making it easy to work with foreign architecture containers without contaminating the container image with the emulator."_

Mechanically it is three lines in `bm_register_write` and one branch in `load_misc_binary`:

```c
/* fs/binfmt_misc.c — bm_register_write() */
if (e->flags & MISC_FMT_OPEN_FILE) {
        scoped_with_creds(file->f_cred)
                f = open_exec(e->interpreter);
        ...
        e->interp_file = f;
}

/* fs/binfmt_misc.c — load_misc_binary() */
if (fmt->flags & MISC_FMT_OPEN_FILE) {
        interp_file = file_clone_open(fmt->interp_file);
        if (!IS_ERR(interp_file))
                deny_write_access(interp_file);
} else {
        interp_file = open_exec(fmt->interpreter);
}
```

Note the `scoped_with_creds(file->f_cred)` — the interpreter is opened with the credentials the `register` file was opened with, not the writer's current ones. That was added when unprivileged mounts landed; the code comment says so directly: _"Now that we support unprivileged binfmt_misc mounts make sure we use the credentials that the register @file was opened with to also open the interpreter."_

This is why `qemu-user-static` is _static_. `F` pins one open file — the emulator binary — across the namespace change. It does **not** pin that emulator's `DT_NEEDED` closure, which would be resolved by `ld.so` inside the container's mount namespace against paths that do not exist there. `F` closes exactly one edge of the dependency graph; static linking has to close the rest. See [Dynamic linking and the loader][dynlink] for why that edge is the expensive one.

### The procfs interface

`binfmt_misc` is its own filesystem (`FS_USERNS_MOUNT`, `BINFMTFS_MAGIC`), conventionally mounted at `/proc/sys/fs/binfmt_misc`. `bm_fill_super` populates exactly two files:

| Path                 | Mode               | Write vocabulary                                                                | Read                         |
| -------------------- | ------------------ | ------------------------------------------------------------------------------- | ---------------------------- |
| `register`           | `S_IWUSR` (0200)   | one registration string                                                         | — (write-only)               |
| `status`             | `S_IWUSR\|S_IRUGO` | `0` disable all, `1` enable all, `-1` delete all                                | `enabled\n` / `disabled\n`   |
| `<name>` (per entry) | 0644               | `0` disable, `1` enable, `-1` delete; and, on the `vfs-7.3` branch, `unlink(2)` | the verbose entry dump below |

`parse_command` accepts at most three bytes, which is the entire command language. The per-entry read is produced by `entry_status`, gated on a compile-time constant whose comment is a fair summary of the subsystem's priorities:

```c
/* fs/binfmt_misc.c */
enum {
        VERBOSE_STATUS = 1 /* make it zero to save 400 bytes kernel memory */
};
```

With it on, reading an entry yields status, interpreter, the flag letters reconstructed from the bits, and — for `M` entries — `offset`, `magic` and `mask` re-emitted as hex via `bin2hex`. That round-trip is the whole of `binfmt_misc`'s reflexivity, and it is discussed in [its own section](#reflexivity-and-query-surface).

---

## Format identity and multiplicity

`binfmt_misc` is not itself a multi-format artifact, so on the raw axis it scores **1**: the registration record admits exactly one parse. What it contributes is the _arbitration_ step that a multi-format artifact needs, and the arbitration has a precise and consequential shape.

**A file's kernel-visible identity is a function of at most 256 bytes.** `prepare_binprm` does one `kernel_read` of `BINPRM_BUF_SIZE` from offset 0 into `bprm->buf`, zero-filling first, and every handler — ELF, script, misc — decides from that buffer alone. There is no second read, no seek, no size query. This is a hard, header-anchored identity model, and it partitions the polyglot design space cleanly:

| Where the format anchors identity   | Kernel-dispatchable? | Example                                                                |
| ----------------------------------- | -------------------- | ---------------------------------------------------------------------- |
| Fixed offset `< 256`                | Yes                  | ELF (`\x7fELF` at 0), `#!` at 0, SQLite `application_id` at 68         |
| Anywhere in a scanned prefix        | No                   | `file(1)`-style multi-rule search; tar's per-member headers            |
| Footer / trailer                    | No                   | ZIP `EOCD`, Parquet/ORC footers — see [footer-indexed formats][footer] |
| Out-of-band (path, database, xattr) | Only via `E`         | `.class`, `.exe`, extension registries                                 |

This is the structural reason a suffix-parasitic format cannot be _directly_ executable. [redbean and APE][ape] resolve it by making the prefix a polyglot the kernel already recognises, and then use `binfmt_misc` to _shortcut_ the resulting shell-stub dance:

```sh
# cosmopolitan — README.md
sudo sh -c "echo ':APE:M::MZqFpD::/usr/bin/ape:' >/proc/sys/fs/binfmt_misc/register"
sudo sh -c "echo ':APE-jart:M::jartsr::/usr/bin/ape:' >/proc/sys/fs/binfmt_misc/register"
```

Both are `M` entries with a six-byte magic at offset 0, no mask, no flags. `MZqFpD` and `jartsr` are not arbitrary: they are the first six bytes of the APE prologue, chosen so the file is simultaneously a DOS `MZ` header and a shell assignment. The README claims a concrete payoff — _"APE will not only work, it'll launch executables 400µs faster now too"_ — because the interpreter replaces the self-extraction stub.

The sharpest evidence that the _content_ is chosen to steer the kernel is [`apelink`][cosmo-apelink]'s `-B` flag, documented in its own usage string as `"force bypassing of any binfmt_misc loader"`. All it does is emit a different eight-byte prologue:

```c
/* cosmopolitan — tool/build/apelink.c */
if (force_bypass_binfmt_misc) {
      p = stpcpy(p, "APEDBG='\n\n");
      ...
} else if (support_vector & _HOSTWINDOWS) {
      p = stpcpy(p, "MZqFpD='\n\n");
```

`MZqFpD='` and `APEDBG='` are both valid shell assignments and both start a valid APE file. The only difference is whether a registered magic matches. **The build system's escape hatch from kernel dispatch is to change the file's first six bytes.** Superposition is real; which member of it runs is decided by a table in kernel memory.

The adversarial reading of the same fact belongs to [parser differentials][diffs]: `binfmt_misc` is a parser, it disagrees with every other parser about what a file is, and it wins, because it runs first and its verdict is `execve`'s verdict.

## Index anchoring and random access

There are two indexes here and they anchor differently.

**The file's index — header, hard-capped, zero-cost.** 256 bytes, read once, before any handler runs. A ranged or partial read of the artifact is not merely possible, it is _mandatory_: the kernel never reads more of the candidate file than that during dispatch, regardless of file size. Cost is one `kernel_read` per rewrite round (up to six rounds before `-ELOOP`), and matching is `O(entries × magic_size)` with both factors bounded — magic ≤ 256 bytes, entries bounded in practice by `MAX_REGISTER_LENGTH`-sized allocations and, on the `vfs-7.3` branch, by an explicit `ucount` limit.

**The handler registry — out-of-band, and volatile.** It is a `list_head` in `struct binfmt_misc`, hanging off `struct user_namespace`, surfaced as files. Nothing about it is in any artifact. It does not survive a reboot, a `umount`, or (before Linux 6.7) a user-namespace boundary. This is the honest cost of kernel dispatch and it is what makes it categorically different from a self-describing artifact: **`binfmt_misc` moves the "what is this file" decision out of the file**. A SELF or APE binary carries the bytes that _invite_ a decision; the decision itself is host configuration.

That asymmetry is the crux of the deployment story. `scp` a SELF binary to a machine with no registration and you get `-ENOEXEC`. `scp` an APE binary to the same machine and it runs, because its prefix is a shell script that bootstraps its own loader. APE pays enormous format-level cleverness to avoid needing an out-of-band index; SELF accepts the out-of-band index and spends the savings elsewhere. That is [thesis 5][concepts] — portability migrating from the format to the access layer — visible as a single design choice.

## Reflexivity and query surface

Score **2**, designed-in but narrow.

`binfmt_misc` is genuinely introspectable: every registered entry can be read back, and the read is a lossless reconstruction of the semantically meaningful part of the registration. `entry_status` re-emits the flag _letters_ from the flag _bits_ and re-hexes the decoded magic and mask, so a reader recovers `offset`, `magic`, `mask`, `interpreter`, the flags, and the enabled bit. What it does not recover is the original escaping or the chosen delimiter — the entry is normalized, and the write format and the read format are deliberately different.

```text
$ cat /proc/sys/fs/binfmt_misc/self
enabled
interpreter /nix/store/…/bin/self-exec
flags:
offset 0
magic 53514c69746520666f726d61742033000000…
mask ffffffffffffffffffffffffffffffff0000…
```

Three limits are worth naming, because they are what separates this from the query surfaces in [sqlelf][sqlelf] and [relational system surfaces][relational]:

1. **Per-entry, not relational.** There is no way to ask "which entries would match this file", "which entries reference an interpreter under `/tmp`", or "which entry shadowed which". Those are exactly the questions an auditor wants, and answering them means reading every file in the directory and re-implementing `search_binfmt_handler` in userspace. [osquery-style system surfaces][relational] exist because this is the normal state of kernel introspection.
2. **The whole dump must fit in one page.** `bm_entry_read` allocates a single `__get_free_page` and `sprintf`s into it. With `VERBOSE_STATUS`, a maximal 256-byte magic plus mask hexes to 1024 characters — comfortable, but the margin is a page, not a design.
3. **No self-interrogation at runtime.** A process dispatched through `binfmt_misc` cannot ask the kernel _which entry dispatched it_. It can infer the interpreter from `argv[0]` (without `P`) or from `/proc/self/exe`, and that inference is exactly where the design breaks — see below.

### The `/proc/self/exe` problem

This is the single most consequential wart in the subsystem for this catalog.

When a handler delegates, `exec_binprm` swaps `bprm->file = bprm->interpreter` and goes round again. By the time `begin_new_exec` runs, `bprm->file` is the _interpreter_, and:

```c
/* fs/exec.c — begin_new_exec() */
retval = set_mm_exe_file(bprm->mm, bprm->file);
```

So `mm->exe_file` — the target of `/proc/self/exe`, `/proc/<pid>/exe`, and everything built on them — names the interpreter. `/proc/<pid>/cmdline` shows the spliced argument vector. `comm` follows the interpreter. The process's entire kernel-visible identity is the interpreter's.

For `qemu-user` and Wine that is correct and intended. For an artifact that wants to _read itself_ it is fatal, and it is the reason SELF's loader carries a hack. `self-exec` is registered with **no flags at all**, and [its header comment][selfdb-exec] says why:

```c
/* selfdb — loader/self-exec.c */
 * Kernel argv to the interpreter (fs/binfmt_misc.c, no P/O flags):
 *   [self-exec, <binary path>, <original argv[1:]>]
 * We open argv[1] and re-exec with argv[1:], so the target's argv[0] is the
 * binary path (basename() still satisfies multi-call binaries).
```

The NixOS module's comment ([`nix/module.nix`][selfdb-module]) records the flag that was tried and rejected, and [`DESIGN.md`][selfdb-design] repeats it in the deviations list:

> _"We deliberately do NOT set `preserveArgvZero`: it inserts the original `argv[0]` as an extra leading operand that strict programs (e.g. GNU hello) reject."_

So the artifact locates itself by `argv[1]`, then re-execs so that its own `argv[0]` becomes the path. The [self-httpd example][self] then _"opens `argv[0]` as a database and serves out of `routes`"_ — a self-querying server whose only handle on itself is a string the kernel happened to splice in. It works, and it is load-bearing, and it is a string.

`P` cannot fix it (it adds an argument rather than fixing identity). `O`/`AT_EXECFD` gives the interpreter a _descriptor_ for the binary but changes neither `argv` nor `mm->exe_file`. Nothing in mainline fixes it.

### Transparent dispatch: the fix, and its status

> [!IMPORTANT]
> **As of 2026-08-26 this work is not in Linus's tree.** Mainline's most recent tagged release is `v7.2`; no `v7.3-rc1` tag exists yet. The series is staged in Christian Brauner's [`vfs/vfs.git`][vfs-log] on branch `vfs-7.3.binfmt` (tip `68aabd01ddd26ced458a9e5716a640eaf8e4b7a6`, 2026-08-03) and tagged `vfs-7.3-rc1.binfmt` for the 7.3 merge window. `lore.kernel.org` sits behind an anti-bot gate that returns an interstitial to non-browser clients and has no `web.archive.org` snapshot for these threads, so the mailing-list postings are identified here by message-id (`20260720-work-bpf-binfmt_misc-ptinterp-v1-0-ddb76c9a508e@kernel.org`, `20260711-binfmt-misc-bpf-v2-v2-5-d6591ceaf207@gmail.com`) and cited through the `git.kernel.org` commit pages instead, which carry the `Link:` trailers.

The series adds three things, and the first two are aimed squarely at this problem.

**`T` — transparent dispatch** ([`a4bdab2be4fd`][c-transparent], [`75e536852f9a`][c-tflag]). The motivating paragraph is worth quoting in full:

> _"A binfmt_misc interpreter is visible to the binary it runs. `argv[0]` becomes the interpreter path and the binary's path is appended as an argument and `/proc/pid/cmdline` shows both. For wine or qemu-user that is the point. For a per-binary loader the interpreter is an implementation detail of running the binary that has no business in the argument vector. And a binary handed to `execveat()` as an `O_CLOEXEC` fd without a usable path cannot be run through binfmt_misc at all. The interpreter would have no path to open the binary by."_

Under `T` the binary arrives via `AT_EXECFD` (`T` implies `O`), the argument vector is untouched, and — the part that matters here — the companion patch [`f1ec2b5604a7`][c-exefile] relabels the exe link:

> _"When binfmt_misc dispatches a binary to an interpreter, the interpreter becomes `bprm->file` and `begin_new_exec()` labels `mm->exe_file` with it. For wine or qemu-user that is the point. For the transparent mode it defeats the point. The interpreter is an implementation detail and the process's identity is the binary. Relocatable programs that locate themselves via `/proc/self/exe` find the dynamic linker instead."_

The same commit is precise about what userspace could already do and why it is not enough: `PR_SET_MM_MAP`'s `exe_fd` is gated on `checkpoint_restore_ns_capable()` (that is how CRIU restores an exe link), so _"the ability to retarget `mm->exe_file` is not what this adds. What userspace cannot do is have the link be right from the first instruction."_ The kernel announces the contract to the interpreter with a new `AT_FLAGS_TRANSPARENT_INTERP` bit next to `AT_EXECFD`, and the commit records that glibc's `ld.so` is gaining matching `AT_EXECFD` support. `T` is rejected in combination with `P` — transparency preserves the whole vector, so `P` has nothing left to say.

**`L` — loader substitution** ([`83cd3989ba09`][c-lflag]) inverts the model instead of hiding it:

> _"A static entry registered with the new 'L' flag no longer runs the registered interpreter with the binary as payload. It stashes the interpreter as `bprm->loader` and declines the match with `-ENOEXEC`. The format search continues in the same round. `binfmt_elf` claims the binary as a fully native exec and substitutes the stashed file for the binary's `PT_INTERP`."_

There is no identity to reconstruct because the exec is native: the binary is the main image, credentials and `AT_SECURE` derive from it, `/proc/<pid>/maps` and core dumps have the native shape, and — per [the branch documentation][vfs-doc] — _"the identity is already complete when `PTRACE_EVENT_EXEC` stops the tracee. So launching under a debugger works, not just attaching."_ `L` is ELF-only and native-arch-only by construction; it is the answer for `$ORIGIN`-style relocatable loader selection, not for emulation. This is `binfmt_misc` reaching into the territory of [dynamic linking][dynlink] and rewriting one edge of it.

**`B` — bpf-backed handlers** ([`b4bfe2f6b011`][c-bpf], [`ceb912149e5e`][c-bpf2]) removes the 256-byte ceiling for matching, and it removes it in exactly the direction this catalog cares about. From [the branch documentation][vfs-doc]:

> _"Unlike static matching it is not limited to the prefetched first bytes of the file in `bprm->buf`: it can read the file, e.g. to parse ELF program headers whose data sits at arbitrary offsets. It only decides, though: the selection kfuncs below are rejected in it."_

A sleeping `match` program that can read the whole file is, formally, a footer-index reader. If it ships, the table in [Format identity and multiplicity](#format-identity-and-multiplicity) loses its second and third rows: a `B` handler could parse a ZIP `EOCD` and dispatch on it. That would be the first time the kernel's answer to "what is this file" is not header-anchored.

Assessing this honestly: **the recent work does not make `binfmt_misc` reflexive, it makes it _invisible_.** `T` and `L` both aim at the same target — a dispatched process that is indistinguishable from a directly-executed one — and neither gives the running program a way to ask which entry dispatched it. The remaining visible difference under `T` is stated in [the docs][vfs-doc]: _"the address space layout. The interpreter occupies the main-image position and the program lives in the mmap region."_

## Closure, dedup, and size model

Score **1**. Mostly this axis does not apply — `binfmt_misc` transports nothing, deduplicates nothing, and has no size model for artifacts. Three concrete numbers are all there is, and each is a bound rather than a footprint:

| Quantity                    | Value                        | Source                                                                  |
| --------------------------- | ---------------------------- | ----------------------------------------------------------------------- |
| Registration record         | 11 … 1920 bytes              | `create_entry`, `MAX_REGISTER_LENGTH`                                   |
| Per-entry kernel allocation | `sizeof(Node) + count + 8`   | one `kmalloc`, `GFP_KERNEL_ACCOUNT` (charged to the registrant's memcg) |
| Magic + mask decoded        | ≤ 256 bytes each, equal size | `BINPRM_BUF_SIZE` check                                                 |

The interesting part is the _one_ thing `F` does carry. An `F` entry holds an open `struct file *` for the lifetime of the entry. That is a real, deliberate closure edge — the interpreter travels with the registration rather than being re-resolved per exec — and it is the reason `binfmt_misc` works across `chroot` and mount namespaces at all. It is also a resource an unprivileged namespace can pin, which is why the `vfs-7.3` branch adds an accounting limit ([`binfmt-misc.rst` on that branch][vfs-doc]):

> _"the amount of pre-opened interpreters by `F`, or bound to a `B` entry is limited by the `/proc/sys/user/max_binfmt_misc_interpreters` sysctl. A registration past the limit is refused with `-ENOSPC`. This limits an unprivileged namespace pinning files. A nested namespace can raise only its own limit and every ancestor is charged too."_

Implemented as a `ucount` (`UCOUNT_BINFMT_MISC_INTERPRETERS`, `inc_ucount`/`dec_ucount` on `current_user_ns()`), i.e. the same mechanism that bounds namespaces, inotify watches and pending signals — charged up the ancestor chain.

The closure edge that `F` _does not_ close is the interpreter's own dependencies. Nothing pins the interpreter's `DT_NEEDED` libraries; `ld.so` resolves them at exec time in whatever mount namespace the exec happens in. This is why every real `binfmt_misc` emulator ships statically linked (`qemu-user-static` is named for it), and it is a small, sharp instance of the general point in [Nix store closures][nix]: closing one edge of a dependency graph by hand does not close the graph.

For the cost side of dispatch — how much of a SELF binary's ~5× exec latency is `binfmt_misc` versus SQLite open versus image reconstruction — see [measurement][measure]. The published decomposition ([`bench/results.md`][selfdb-bench]) is 0.42 ms for a bare ELF exec against 2.116 ms for the memfd loader, but that figure includes a _second_ full `execve` (`self-exec` reconstructs an ELF into a memfd and `execveat`s it), which the `T` mode would eliminate: an interpreter that loads from `AT_EXECFD` in-process needs no re-exec, and gets a correct `/proc/self/exe` for free. That is the concrete payoff of the unmerged work for this catalog's seed case.

## Mutability, dispatch, and trust

### Who may register

Two gates, and they are different gates.

**Mounting** requires `CAP_SYS_ADMIN` — but `binfmt_misc` sets `FS_USERNS_MOUNT`, so it is `ns_capable`, not `capable` ([`fs/super.c`][super-src]):

```c
/* fs/super.c — mount_capable() */
if (!(fc->fs_type->fs_flags & FS_USERNS_MOUNT))
        return capable(CAP_SYS_ADMIN);
else
        return ns_capable(fc->user_ns, CAP_SYS_ADMIN);
```

**Writing** requires being able to open `register`, which `bm_fill_super` creates with mode `S_IWUSR` and which `new_inode` gives uid 0 _in the superblock's user namespace_.

Together: **anyone who can create a user namespace can register `binfmt_misc` handlers** — for processes in that namespace and its descendants, not for the host. `unshare -Ur` is enough. This has been true since Linux 6.7 ([`21ca59b365c0`][c-userns], Christian Brauner). Before it, registration required `CAP_SYS_ADMIN` in the initial namespace, while _dispatch_ was already global — the commit message is blunt about the asymmetry that motivated the change:

> _"While binfmt_misc can currently only be mounted in the initial user namespace, binary types registered in this binfmt_misc instance are available to all sandboxes… So binfmt_misc binary types are already delegated to sandboxes implicitly. However, while a sandbox has access to all registered binary types in binfmt_misc a sandbox cannot currently register its own binary types."_

Lookup walks up: `load_binfmt_misc` climbs `user_ns->parent` until it finds a namespace with its own instance, falling back to `init_binfmt_misc`. A sandbox with no mount of its own inherits its ancestor's handlers — _"This mimicks the behavior of pre-namespaced binfmt_misc"_. A sandbox that mounts its own **shadows** them entirely; there is no union.

### The escalation surface

The `C` flag is the sharp edge, and the kernel documentation says so itself:

> _"This feature should be used with care as the interpreter will run with root permissions when a setuid binary owned by root is run with binfmt_misc."_

Concretely: `bprm_creds_from_file` picks `bprm->executable` (the binary) rather than `bprm->file` (the interpreter) when `execfd_creds` is set, then `bprm_fill_uid` applies the binary's setuid bits to the _new_ credentials — which the interpreter will run under. An attacker with registration rights can point an entry's magic at the first bytes of an existing root-setuid binary and name their own interpreter, producing execution as root without ever executing the setuid binary's code. This is the "Shadow SUID" technique ([SentinelOne, 2019][shadow-suid]; a compact writeup with detection guidance is at [dfir.ch][dfir-binfmt]). Note what makes it hard to see: the setuid binary never runs, so instrumentation keyed on executing it observes nothing.

Two mitigations are structural rather than added:

- `bprm_fill_uid` ignores setuid/setgid when the ids have no mapping in `bprm->cred->user_ns` (`vfsuid_has_mapping`), and when `task_no_new_privs(current)` — so the userns-mountable case cannot manufacture host root, and `PR_SET_NO_NEW_PRIVS` disarms the whole path.
- `security_bprm_check(bprm)` runs **once per rewrite round** in `search_binary_handler`, so an LSM sees the interpreter exec as its own event, not only the original one.

Everything else is policy that has to be layered on: the registry has no signature, no provenance, no ownership beyond file mode, and no persistence — which cuts both ways. A `binfmt_misc` rootkit does not survive a reboot; a legitimate registration does not either, which is why distributions ship `systemd-binfmt.service` and NixOS ships a module. See [the threat model page][threat] for how this composes with W^X, IMA/fs-verity and the sandboxing primitives these projects reach for.

### Mutability of the artifact

Score **0**, and the reason is the interesting part: `binfmt_misc` _never touches the file_. It opens it (`O`), reads 256 bytes of it, and hands a path or a descriptor to someone else. Write-denial is the only mutation-adjacent behavior, and it is about the interpreter: `deny_write_access(interp_file)` on the `F` path, `exe_file_allow_write_access(exec)` when `exec_binprm` swaps files.

That neutrality is what makes `binfmt_misc` composable with self-modifying artifacts at all. A [self-httpd][self] that `INSERT`s into the very file it is executing from is doing something the dispatcher has no opinion about — because by the time the process is running, the dispatcher is gone. Contrast `binfmt_elf`, which `mmap`s the file's pages into the address space and thereby _does_ have an opinion (`ETXTBSY`, page-cache coherence, W^X). Under the unmerged `T` mode this changes slightly and deliberately: [`f1ec2b5604a7`][c-exefile] notes that a transparent dispatch gets _"exact parity with a direct execution: a concurrently written binary fails `execve()` with `-ETXTBSY` at open and a running one cannot be opened for writing."_ Transparency reinstates the guarantees that classic dispatch quietly dropped.

---

## The other dispatchers, for contrast

### `binfmt_script` — the shell's answer, in the kernel

[`fs/binfmt_script.c`][script-src] is 159 lines and its entire matcher is:

```c
/* fs/binfmt_script.c — load_script() */
/* Not ours to exec if we don't start with "#!". */
if ((bprm->buf[0] != '#') || (bprm->buf[1] != '!'))
        return -ENOEXEC;
```

Everything after that is argument splicing, and it is subject to the same 256-byte window — `bprm->buf` is all there is. The consequences of that limit are the best-documented dispatch-layer breakage in the kernel's history, and they are worth the detour because they are the exact hazard a self-describing artifact inherits.

The shebang line is silently truncated at `BINPRM_BUF_SIZE`. In January 2019 Oleg Nesterov made that an error ([`8099b047ecc4`][c-trunc]):

> _"`load_script()` simply truncates `bprm->buf` and this is very wrong if the length of shebang string exceeds `BINPRM_BUF_SIZE-2`. This can silently truncate `i_arg` or (worse) we can execute the wrong binary if `buf[2:126]` happens to be the valid executable path."_

Five weeks later Linus reverted it ([`cb5b020a8d38`][c-revert]):

> _"It turns out that people do actually depend on the shebang string being truncated, and on the fact that an interpreter (like perl) will often just re-interpret it entirely to get the full argument list."_

The reverting commit credits Samuel Dionne-Riel — a NixOS developer, and not by coincidence: `/nix/store/<hash>-<name>/bin/<prog>` paths are long, and the 128-byte limit of the day was routinely exceeded. The eventual compromise ([`b5372fe5dc84`][c-trunc2], Kees Cook, co-developed with Torvalds) is the code in the tree today: refuse to exec a _truncated interpreter path_, but allow truncated _arguments_, on the reasoning stated in the source — _"Truncating the arguments is fine: the interpreter can re-read the script to parse them on its own."_ Separately, `BINPRM_BUF_SIZE` went 128 → 256 ([`6eb3c3d0a52d`][c-bufsize]) for the same class of complaint from a different direction: long paths on networked filesystems.

Three lessons transfer directly to any artifact that hides its identity behind a dispatcher: the window is fixed and small; userspace will come to depend on the exact truncation semantics; and the interpreter re-reading the file is the escape hatch that makes the truncation survivable. SELF's `self-exec` is that pattern exactly — the kernel hands it a path, and it opens the file itself.

### `binfmt_elf` — magic as a four-byte prefix

[`fs/binfmt_elf.c`][elf-src] is 2147 lines, of which the identity check is one:

```c
/* fs/binfmt_elf.c — load_elf_binary() */
struct elfhdr *elf_ex = (struct elfhdr *)bprm->buf;
...
if (memcmp(elf_ex->e_ident, ELFMAG, SELFMAG) != 0)
        goto out;
if (elf_ex->e_type != ET_EXEC && elf_ex->e_type != ET_DYN)
        goto out;
if (!elf_check_arch(elf_ex))
        goto out;
```

`ELFMAG` is `"\177ELF"` and `SELFMAG` is `4`. The rest of the header is _validated_ rather than _matched_, and the program headers are read separately by `load_elf_phdrs`. That split — a four-byte identity claim at offset 0, an index (`e_phoff`) elsewhere in the header, and the actual table read on demand — is the canonical header-anchored layout. It is also what makes ELF prefix-hostile and suffix-tolerant: bytes after the last program-header-covered offset are unexamined, which is the property [ZIP parasitism][zip] and [boot hybrids][boot] both exploit.

The magic-with-mask design of `binfmt_misc` is, in effect, a userspace-programmable generalisation of these four bytes — and the documentation's canonical example is precisely an over-long ELF magic that masks out `e_ident` padding to pin `e_machine`:

```text
:i386:M::\x7fELF\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03
      :\xff\xff\xff\xff\xff\xfe\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfb\xff\xff
      :/bin/em86:
```

### Consumer-side sniffing — the same problem without an arbiter

Outside the kernel, the same decision is made by whoever happens to open the file, using whatever heuristic they carry: `file(1)`/libmagic's rule database, `mimetype` lookups, and — the one case with a written standard — the WHATWG [MIME Sniffing][mimesniff] algorithm, which exists because browsers disagreeing about what a byte stream is turned into a security boundary. The structural difference is authority: `binfmt_misc` yields a _single_ verdict that the whole system then acts on, whereas consumer sniffing yields as many verdicts as there are consumers. That is the generator of [parser differentials][diffs]; GIFAR and its descendants are the difference between two sniffers, weaponised.

### The general principle

Stated plainly, and it is the reason this page exists in the catalog:

> **A byte stream can satisfy _n_ grammars simultaneously; it can only _do_ one thing. Dispatch is the function from the superposition to the behavior, and it is always somewhere — kernel table, shebang line, `PT_INTERP` string, MIME sniffer, file extension. Where it lives determines who can change the answer, how fast, and whether the artifact travels with it.**

Ranked by how much authority the artifact retains:

| Dispatcher                               | Decides from                     | Configurable by      | Travels with the artifact? |
| ---------------------------------------- | -------------------------------- | -------------------- | -------------------------- |
| `binfmt_elf` magic                       | 4 bytes at offset 0              | nobody (compiled in) | yes                        |
| `#!` line (`binfmt_script`)              | ≤ 254 bytes at offset 2          | the artifact         | yes, but names a host path |
| `PT_INTERP` ([dynamic linking][dynlink]) | a string in the ELF header table | the artifact         | yes, but names a host path |
| `binfmt_misc`                            | ≤ 256 bytes at a chosen offset   | userns-root          | **no**                     |
| Consumer sniffing                        | anything, inconsistently         | each consumer        | no                         |
| Namespace binding ([Plan 9][plan9])      | the path, per-process            | the process          | no                         |

The `binfmt_misc` row is the only one where the artifact contributes the _claim_ and the host owns the _decision_. That split is what makes a new executable format cheap to try — SELF needed no kernel patch — and what makes it expensive to ship.

---

## Strengths

- **Zero-cost to define a new executable format.** A magic, a mask, an offset and a path. No kernel patch, no format registry, no cooperation from any existing loader. [SELF][self] became runnable with a NixOS module and no C in the kernel at all.
- **Masking is expressive enough for real formats.** Arbitrary-length magic with a byte-wise mask at a chosen offset covers ELF-with-`e_machine`-pinning, two-anchor formats like SQLite-with-`application_id`, and DOS `MZ` — all with one comparison loop.
- **`F` genuinely solves the container problem.** Pre-opening the interpreter at registration makes an emulator survive `chroot` and mount-namespace changes; this is the whole reason cross-architecture containers work.
- **Namespaced since Linux 6.7.** A sandbox can register its own handlers without touching the host, and lookup falls back through ancestors so nothing breaks for sandboxes that do not.
- **Fully introspectable registry, in text.** Every entry reads back with its interpreter, flags, offset, magic and mask; the flag _letters_ are reconstructed from bits, so what you read is what you registered.
- **Composable with self-modifying artifacts.** The dispatcher never maps or writes the file, so it imposes no `mmap`/W^X constraints of its own.
- **First in line.** `insert_binfmt` puts it ahead of ELF and `#!`, so a registration can override a format the kernel already understands — which is what APE's `MZqFpD` entry does.

## Weaknesses

- **The identity window is 256 bytes and header-anchored.** Footer-indexed formats are undispatchable in principle. This single constant shapes the whole polyglot design space above.
- **One `(offset, magic, mask)` triple per entry.** Two-anchor formats must span the gap and mask it out — SELF spends 52 don't-care bytes to bridge offsets 16–67.
- **`/proc/self/exe`, `cmdline` and `comm` all name the interpreter.** A relocatable program that locates itself finds the emulator. The mainline mitigations are `argv` conventions, i.e. strings. The real fix (`T`) is unmerged.
- **The registry is out-of-band and volatile.** It does not travel with the artifact and does not survive a reboot; deployment needs `systemd-binfmt` or an equivalent. An artifact that depends on a registration is not self-contained, whatever else it contains.
- **`C` is a privilege-escalation primitive.** Credentials from the binary plus an attacker-chosen interpreter is "Shadow SUID"; the kernel documentation warns about it and offers no narrower tool.
- **Documentation drift.** The 128-byte magic limit has been wrong since Linux 5.1 and the 127-character interpreter limit has no code behind it at all.
- **No relational view of the registry.** "Which entry would claim this file" is not answerable without re-implementing the matcher.
- **Extension (`E`) matching is name-based dispatch in the kernel** — case-sensitive, path-derived, and defeated by `mv`.

---

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                        | Trade-off                                                                                                       |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Match on a fixed prefix window (`BINPRM_BUF_SIZE`)             | One read, no seeks, bounded work per `execve`; identical buffer serves every handler             | Footer-anchored and scan-anchored formats are undispatchable; two-anchor formats waste magic on don't-cares     |
| Magic + byte-wise mask at one offset                           | Covers architecture-discriminating ELF matches with a single comparison loop and no format model | No disjunction, no alternation, no second window                                                                |
| Registration as a self-delimiting ASCII record                 | Any byte can be the delimiter, so no magic can be unexpressible; parseable with `strchr`         | Normalized on read-back — the write format and the read format differ; escaping halts at the first NUL          |
| Entry allocated as `Node` + the raw string, parsed in place    | One allocation, no copies, pointers into the registration itself                                 | The 1920-byte record cap is also the entry cap; interpreter paths compete with magic for the same budget        |
| `insert_binfmt` (head of the list)                             | A registration can override a format the kernel already claims — the point of the facility       | Any matching entry silently pre-empts ELF and `#!` for every `execve` on the system                             |
| Interpreter path resolved lazily by default                    | Follows the exec'ing task's namespace and root, which is right for a host-local interpreter      | Breaks under `chroot`/mount namespaces — the problem `F` exists to solve                                        |
| `F`: open the interpreter at registration                      | The handler survives namespace changes without contaminating the container image                 | Pins a file indefinitely (hence the new `max_binfmt_misc_interpreters` ucount); closes only one dependency edge |
| `C`: derive credentials from the binary                        | Lets `setuid` binaries work through an emulator at all                                           | Turns registration rights into root; the documented warning is the only guard                                   |
| Interpreter becomes `bprm->file`, so it owns the exec identity | Correct and desirable for emulation (`qemu-user`, Wine)                                          | `/proc/self/exe` names the interpreter; self-locating programs break; fixed only by the unmerged `T` mode       |
| Registry keyed by user namespace, mountable with `ns_capable`  | Sandboxes can register their own handlers without host cooperation                               | Anyone who can `unshare -U` can register handlers; shadowing is total, with no union across namespaces          |
| Volatile registry, no persistence, no signature                | Keeps the kernel out of policy entirely                                                          | Deployment needs userspace glue; provenance and audit are entirely out of scope                                 |

---

## Sources

- [`fs/binfmt_misc.c` at `e43ffb69e043` — the matcher, parser, flags, and procfs interface][bm-src]
- [`fs/exec.c` at `e43ffb69e043` — `search_binary_handler`, `exec_binprm`, `begin_new_exec`, `bprm_creds_from_file`][exec-src]
- [`fs/binfmt_script.c` at `e43ffb69e043` — the `#!` path and its truncation rules][script-src]
- [`fs/binfmt_elf.c` at `e43ffb69e043` — the four-byte ELF identity check][elf-src]
- [`include/linux/binfmts.h` / `include/uapi/linux/binfmts.h` — `struct linux_binprm`, `BINPRM_BUF_SIZE`][binfmts-h]
- [`fs/super.c` — `mount_capable()` and `FS_USERNS_MOUNT`][super-src]
- [`Documentation/admin-guide/binfmt-misc.rst` — the registration format, flags, and restrictions][bm-doc]
- Kernel history: [`6eb3c3d0a52d` `BINPRM_BUF_SIZE` 128→256][c-bufsize] · [`8099b047ecc4` shebang truncation][c-trunc] · [`cb5b020a8d38` the revert][c-revert] · [`b5372fe5dc84` the compromise][c-trunc2] · [`948b701a607f` the `F` flag][c-fixbinary] · [`21ca59b365c0` unprivileged mounts][c-userns]
- Unmerged, staged for Linux 7.3 in [`vfs/vfs.git`, branch `vfs-7.3.binfmt`][vfs-log]: [`a4bdab2be4fd` transparent dispatch][c-transparent] · [`f1ec2b5604a7` `mm->exe_file` labelling][c-exefile] · [`75e536852f9a` the `T` flag][c-tflag] · [`83cd3989ba09` the `L` flag][c-lflag] · [`b4bfe2f6b011` `binfmt_misc_ops` bpf struct_ops][c-bpf] · [`ceb912149e5e` `B` entries][c-bpf2] · [the branch's `binfmt-misc.rst`][vfs-doc]
- [SQLite file format — the `application_id` at offset 68][sqlite-fmt]
- [`fzakaria/selfdb` — `nix/module.nix` registration][selfdb-module] · [`loader/self-exec.c`][selfdb-exec] · [`DESIGN.md`][selfdb-design] · [`bench/results.md`][selfdb-bench]
- [`jart/cosmopolitan` — the APE `binfmt_misc` registrations (`README.md`)][cosmo-readme] · [`tool/build/apelink.c` — `-B`][cosmo-apelink]
- [WHATWG MIME Sniffing Standard][mimesniff] · [`execve(2)` — man7.org][execve]
- ["Shadow SUID" for privilege persistence (SentinelOne, 2019)][shadow-suid] · [Today I learned: `binfmt_misc` (dfir.ch)][dfir-binfmt]
- In this catalog: [redbean / Cosmopolitan / APE][ape] · [SELF / selfdb][self] · [ZIP parasitism][zip] · [Footer-indexed formats][footer] · [Dynamic linking][dynlink] · [Parser differentials][diffs] · [Threat model][threat] · [Measurement][measure] · [Plan 9 namespaces][plan9] · [Nix store closures][nix] · [sqlelf][sqlelf] · [Relational system surfaces][relational] · [Boot hybrids][boot] · [Concepts and axes][concepts]

### Dating caveat

The `Copyright (C) 1997 Richard Günther` header in `fs/binfmt_misc.c` is primary evidence for the year. The commonly cited introduction in **Linux 2.1.43** predates the git history (which begins at 2.6.12-rc2), could not be verified against a primary changelog from the clone, and should be treated as secondary.

<!-- References -->

[linux]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/
[bm-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/binfmt_misc.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[exec-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/exec.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[script-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/binfmt_script.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[elf-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/binfmt_elf.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[binfmts-h]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/binfmts.h?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[super-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/super.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[bm-doc]: https://docs.kernel.org/admin-guide/binfmt-misc.html
[c-bufsize]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=6eb3c3d0a52dca337e327ae8868ca1f44a712e02
[c-trunc]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=8099b047ecc431518b9bb6bdbba3549bbecdc343
[c-revert]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=cb5b020a8d38f77209d0472a0fea755299a8ec78
[c-trunc2]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=b5372fe5dc84235dbe04998efdede3c4daa866a9
[c-fixbinary]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=948b701a607f123df92ed29084413e5dd8cda2ed
[c-userns]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=21ca59b365c091d583f36ac753eaa8baf947be6f
[vfs-log]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/log/?h=vfs-7.3.binfmt
[vfs-doc]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/tree/Documentation/admin-guide/binfmt-misc.rst?id=68aabd01ddd26ced458a9e5716a640eaf8e4b7a6
[c-transparent]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=a4bdab2be4fdaf5f90a7fc445452167cb624cdf2
[c-exefile]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=f1ec2b5604a7c5f239baf2acf894fef67b1dcc90
[c-tflag]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=75e536852f9a5f1880091d58f46cdf2fce2101b4
[c-lflag]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=83cd3989ba0971693461088d35142ad52d862135
[c-bpf]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=b4bfe2f6b0117f3d8de6430bdaee10094383e97a
[c-bpf2]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=ceb912149e5e60fbb1c762603f8c4ce257b97501
[sqlite-fmt]: https://www.sqlite.org/fileformat2.html
[selfdb-module]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/nix/module.nix
[selfdb-bench]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/results.md
[cosmo-readme]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/README.md
[cosmo-apelink]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/build/apelink.c
[selfdb-exec]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/self-exec.c
[selfdb-design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[mimesniff]: https://mimesniff.spec.whatwg.org/
[execve]: https://man7.org/linux/man-pages/man2/execve.2.html
[shadow-suid]: https://www.sentinelone.com/blog/shadow-suid-for-privilege-persistence-part-1/
[dfir-binfmt]: https://dfir.ch/posts/today_i_learned_binfmt_misc/
[ape]: ./cosmopolitan-ape/index.md
[self]: ./self-selfdb/index.md
[zip]: ./zip-parasitism.md
[footer]: ./footer-indexed-formats.md
[dynlink]: ./dynamic-linking.md
[diffs]: ./parser-differentials.md
[threat]: ./threat-model.md
[measure]: ./measurement.md
[plan9]: ./plan9-namespaces.md
[nix]: ./nix-store-closures.md
[sqlelf]: ./sqlelf.md
[relational]: ./relational-system-surfaces.md
[boot]: ./boot-hybrids.md
[concepts]: ./concepts.md
