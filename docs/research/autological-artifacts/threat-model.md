# Threat model (security analysis / OS enforcement facilities)

What breaks, security-wise, when the artifact is simultaneously its own text, its own state store, and the thing a dispatcher decides about — and which of the kernel's existing enforcement primitives can express the decomposition that would fix it.

| Field           | Value                                                                                                                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Analytical lens over a set of kernel/OS facilities (not a tool or a format)                                                                                                                                                           |
| Language        | C — `fs/verity/`, `security/integrity/{ima,evm}/`, `security/landlock/`, `security/selinux/hooks.c`, `mm/memfd.c`, plus `libc/calls/{pledge,unveil}.c` and `loader/*.c` in the seed cases                                             |
| License         | Kernel sources `GPL-2.0`; Cosmopolitan ISC; `selfdb` MIT; OpenBSD manual pages under the OpenBSD documentation licence                                                                                                                |
| Repository      | No single upstream; the corpus read for this page is listed under [Sources](#sources)                                                                                                                                                 |
| Documentation   | [`fsverity`][fsv-doc] · [`landlock`][ll-doc] · [`seccomp_filter`][sec-doc] · [`ima_policy`][ima-abi] · [`pledge(2)`][pledge] · [`unveil(2)`][unveil]                                                                                  |
| First release   | The primitives span 1978–2024: `ETXTBSY` (V7 Unix) → SELinux `execmem` (2001) → seccomp-BPF (Linux 3.5, 2012) → `pledge` (OpenBSD 5.9, 2016) → fs-verity (Linux 5.4, 2019) → Landlock (Linux 5.13, 2021) → `mseal` (Linux 6.10, 2024) |
| Axis profile    | Multiplicity 0 / Reflexivity 1 / Closure 0 / Mutability 3                                                                                                                                                                             |
| Index anchoring | **Out-of-band, in every case.** The measurement, the ruleset, the policy and the `binfmt_misc` registration all live outside the artifact they govern — see [Index anchoring](#index-anchoring-and-random-access)                     |
| Dispatch owner  | **Kernel.** Every enforcement point that counts is a kernel one; the application-level levers ([`sqlite3_set_authorizer`][authorizer], `PRAGMA query_only`) are exactly the ones that do not                                          |

> **Revisions surveyed:** Linux mainline `v7.1-rc6`, commit `e43ffb69e0438cddd72aaa30898b4dc446f664f8` (2026-05-31) — `fs/verity/`, `security/integrity/`, `security/landlock/`, `security/selinux/`, `mm/memfd.c`, `fs/exec.c`, `fs/binfmt_misc.c`. `jart/cosmopolitan` at `3293fad0a9eac7865c019be98fb993eeb933405e` (2026-07-19). `fzakaria/selfdb` at `e63f7c470302f089a677ec87679a7df60b628547` (2026-08-24). OpenBSD manual pages as published at [man.openbsd.org][pledge] (7.7). **Platform:** Linux, OpenBSD and macOS are each treated separately, because on this axis they do not agree about anything.

---

## Overview

### What it solves

Nothing, in the same sense as [parser differentials][diffs]: this page is the entry that explains what the rest of the catalog costs.

Every other subject celebrates a collapse. [redbean][ape] collapses archive into program; [SELF][self] collapses schema into executable; [self-httpd][self] collapses state store into image. Each collapse deletes a boundary, and every boundary this catalog deletes was, somewhere, a security boundary that an operating system was already enforcing for free. The four that matter:

| Boundary deleted                           | What was enforcing it                                                      | What replaces it                                                |
| ------------------------------------------ | -------------------------------------------------------------------------- | --------------------------------------------------------------- |
| text is not writable                       | `W^X`; `deny_write_access` on `mm->exe_file` (`ETXTBSY`); page permissions | an opt-in flag, or nothing                                      |
| the file's identity is fixed at build time | `binfmt_elf`'s four-byte magic, compiled in                                | a userspace registration string, writable from a user namespace |
| a program's reachable files are a set      | `unveil`, Landlock, `chroot` — all path-granular                           | one path, containing everything                                 |
| a measured file does not change            | IMA appraisal, fs-verity, dm-verity — all assume immutability              | nothing; the design forbids it                                  |

The catalog's question is stated at the end of cluster H of the [source outline][outline]: _can the process hold a read-only handle to its own text tables and a writable handle to its state tables, enforced below the application?_ This page works through the four areas that bear on it and then answers it, in [the open question](#the-open-question-the-least-privilege-decomposition).

### Design philosophy

There is no single project here to quote, so take the philosophy from the strictest of the enforcers. OpenBSD's `mount(8)` describes the default policy that a self-modifying artifact must argue with:

> _"Processes that ask for memory to be made writeable plus executable using the `mmap(2)` and `mprotect(2)` system calls are killed by default. This option allows those processes to continue operation. It is typically used on the `/usr/local` filesystem."_
>
> — [`mount(8)`][mount8], the `wxallowed` option

Two things follow, and both structure this page.

**The default is death, and the exemption is a property of the filesystem, not of the program.** `wxallowed` is a mount option. A program cannot ask for it; an administrator grants it to a whole subtree, and the program additionally has to be link-time tagged `wxneeded` for the exemption to apply to it ([`mmap(2)`][mmap2]). That is the shape every honest answer in this page takes: **the enforcement lives below the application and is granted at a granularity coarser than the application would like.**

**The counterpart on Linux is not a policy but an absence.** Linux ships no equivalent default. `mmap(PROT_WRITE|PROT_EXEC)` succeeds on a stock Linux system, and the closest thing to a global rule is an LSM policy decision — SELinux's `execmem` — which most desktop distributions leave permissive for unconfined domains. The asymmetry is why redbean's self-modification is gated by a redbean flag and not by the kernel, and why SELF needs no gate at all.

---

## How it works

### 1. `W^X` versus a format whose text lives in writable rows

#### What `W^X` actually enforces, per platform

`W^X` is one name for three different mechanisms with three different scopes.

| Platform    | Enforced by                                                                                                                                                                                | Scope                                                    | Escape hatch                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Linux**   | Nothing by default. `security_file_mprotect`/`security_mmap_file` LSM hooks; SELinux `process:execmem`, `process:execstack`, `process:execheap`, `file:execmod` ([`hooks.c`][selinux-src]) | Per-domain, per-policy; absent under a permissive policy | Write a policy rule, or run unconfined                                                              |
| **OpenBSD** | The kernel, unconditionally, since 6.0                                                                                                                                                     | System-wide                                              | `wxallowed` mount option **and** a `wxneeded` link-time tag ([`mmap(2)`][mmap2])                    |
| **macOS**   | The Hardened Runtime (code signing) plus, on Apple silicon, per-thread APRR state                                                                                                          | Per-binary, by entitlement                               | `com.apple.security.cs.allow-jit` + `MAP_JIT` + `pthread_jit_write_protect_np` ([Apple][apple-jit]) |

The Linux row is the surprising one. There is no kernel-wide `W^X`, and the primitives that exist are _narrower_ than `W^X` and were added for adjacent reasons:

- **`mseal(2)`** (Linux 6.10) seals a VMA against later `mprotect`, `munmap` and `mremap`. Its documentation names its ancestors explicitly: _"A similar feature already exists in the XNU kernel with the `VM_FLAGS_PERMANENT` flag and on OpenBSD with the `mimmutable` syscall"_ ([`mseal.rst`][mseal-doc]). It protects a mapping that is _already_ correct; it cannot make a wrong one right.
- **`MFD_NOEXEC_SEAL`** (Linux 6.3) makes an anonymous `memfd` permanently non-executable, and `vm.memfd_noexec` makes that the per-PID-namespace default ([`mm/memfd.c`][memfd-src]). This one has teeth for this catalog: see [below](#the-memfd-loader-is-what-a-hardened-host-blocks-first).
- **`deny_write_access`** on the executed file, the oldest of them all. `do_open_execat` calls `exe_file_deny_write_access(file)` before returning ([`fs/exec.c`][exec-src]), and the reference is held for the life of `mm->exe_file`. This is what makes `open("/proc/self/exe", O_WRONLY)` return `ETXTBSY`.

Only the last is relevant to a self-modifying _file_, and it is the one the catalog's seed cases interact with most directly.

The macOS row is the one with the most machinery. Apple silicon's answer is not a permission on a mapping but a _per-thread_ toggle: a `MAP_JIT` region is writable or executable depending on the calling thread's APRR state, flipped by `pthread_jit_write_protect_np`. Cosmopolitan wraps the pair as `__jit_begin`/`__jit_end` ([`libc/runtime/jit.c`][cosmo-jit]):

```c
/* libc/runtime/jit.c */
__privileged void __jit_begin(void) {
  if (IsXnuSilicon())
    if (__syslib->__pthread_jit_write_protect_supported_np())
      __syslib->__pthread_jit_write_protect_np(false);
}
```

and the APE loader for Apple silicon replaces the library call entirely with a hand-written `msr`/`mrs` loop against `_COMM_PAGE_APRR_WRITE_ENABLE`, re-reading the system register to confirm the write landed and retrying up to 8192 times before giving up with `"failed to set jit write protection"` ([`ape/ape-m1.c`][cosmo-apem1], `pthread_jit_write_protect_np_workaround`). Cosmopolitan's own `mmap` documentation states the portability consequence in two sentences: _"Some OSes (i.e. OpenBSD) will raise an error if both `PROT_WRITE` and `PROT_EXEC` are requested. … On some OSes like MacOS ARM64, you need to pass the `MAP_JIT` flag to get RWX memory, which is considered zero on other OSes"_ ([`libc/intrin/mmap.c`][cosmo-mmap]). Three platforms, three incompatible models, and a portable artifact has to satisfy all of them — which is [thesis 5][concepts] appearing where it is least welcome.

#### What SELF and redbean actually do

**redbean** is the case where the tension is visible in the source. `StoreAsset` is unreachable unless the operator passes `-*`, documented in one line as _"permit self-modification of executable"_ ([`help.txt`][cosmo-help], line 54). The flag sets `selfmodifiable`, which calls `MakeExecutableModifiable()` **before** `LuaInit()` ([`redbean.c`][redbean-src], line 7234), so a Lua handler cannot enable it at runtime — an ordering that is itself the security design. `MakeExecutableModifiable` then declines on three whole platforms:

```c
/* tool/net/redbean.c — MakeExecutableModifiable() */
if (IsWindows()) return;  // TODO
if (IsOpenbsd())  return;  // TODO
if (IsNetbsd())   return;  // TODO
```

and at the surveyed revision the x86-64 path is a stub that exits with an error, because `__open_executable()` regressed during ARM64 work. The most-cited self-mutating artifact in the catalog does not currently self-mutate — the [APE deep-dive][ape] develops that, and the reason is `ETXTBSY`: the routine has to unmap its own text before it can open its own file read-write.

**SELF never has that problem, and the reason is a defect in the dispatch layer rather than a virtue of the format.** A `.self` file is not `mm->exe_file` for the process running it. Under `binfmt_misc`, the kernel swaps `bprm->file` to the interpreter (`self-exec`), so `deny_write_access` lands on the _interpreter_, not on the artifact; under the `memfd` loader the process's `exe_file` is the memfd. Either way the `.self` file is an ordinary data file with nobody holding a write-denial on it, and `sqlite3_open(argv[0])` — which defaults to `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE` — succeeds ([`examples/server/server.c`][server-c], `db_open`).

> [!IMPORTANT]
> **`binfmt_misc` dispatch silently deletes Unix's oldest anti-self-modification guarantee.** It is not that SELF defeated `ETXTBSY`; it is that `ETXTBSY` was never applied to the artifact, because the kernel considers the interpreter to be the program. The unmerged transparent-dispatch work reinstates it — its commit message promises _"exact parity with a direct execution: a concurrently written binary fails `execve()` with `-ETXTBSY` at open and a running one cannot be opened for writing"_ ([`f1ec2b5604a7`][c-exefile], quoted in [`binfmt_misc`][binfmt]). Transparency is a security fix, and it is a security fix that _breaks_ `self-httpd`.

#### The `W^X` claim inside the loader, and where it fails

`DESIGN.md` §5 asserts the property: _"W^X: content is written before `mprotect(PROT_EXEC)`; no WX window."_ ([`DESIGN.md`][selfdb-design], line 303.) That is true of `native.c`, whose `map_segment` maps `PROT_READ|PROT_WRITE`, `memcpy`s, then narrows:

```c
/* loader/native.c — map_segment() */
void *p = mmap((void *)start, end - start, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
if (filesz && src) memcpy((void *)(load_bias + vaddr), src, filesz);
if (mprotect((void *)start, end - start, prot) != 0) die(...);
```

It is **not** true of `selfld.c`, the freestanding SQL-native binder (milestone M3b), which leaves every segment writable _and_ executable across relocation and never narrows it again:

```c
/* loader/selfld.c — load_object() */
/* leave writable until after relocation; hardened later */
int prot = (r ? PROT_READ : 0) | PROT_WRITE | (x ? PROT_EXEC : 0);
mprotect((void *)start, end - start, prot);
```

`mprotect` appears exactly once in that file. "Hardened later" is a promise, not a call. So one of the three shipped loaders runs the program's entire life with RWX text — which on OpenBSD would be fatal at `mmap` time, on macOS would require the JIT entitlement, and on SELinux-confined Linux requires `process:execmem`.

That last point generalises past the bug, and it is the durable one:

> [!WARNING]
> **Any loader that copies text out of rows needs `execmem`, permanently.** SELinux distinguishes _executing a file_ (`file:execute`, granted to programs) from _executing anonymous memory_ (`process:execmem`, granted to JITs and interpreters). A conventional ELF gets the first. A `.self` binary's text arrives as `MAP_PRIVATE|MAP_ANONYMOUS` pages filled by `memcpy` from a b-tree, so it needs the second — the permission a policy author uses to mark a domain as _"this thing runs code it made up"_. The [lost page sharing][self] and this are the same fact seen from two directions: text that is not a file mapping is neither shared nor attributable.

#### The `memfd` loader is what a hardened host blocks first

`self-exec` reconstructs an ELF into an anonymous file and `execveat`s it:

```c
/* loader/self-exec.c */
int fd = memfd_create("self", MFD_CLOEXEC);
...
syscall(SYS_execveat, fd, "", argv, envp, AT_EMPTY_PATH);
```

Neither `MFD_EXEC` nor `MFD_NOEXEC_SEAL` is passed. `check_sysctl_memfd_noexec` then decides on the caller's behalf, per PID namespace ([`mm/memfd.c`][memfd-src]):

```c
if (!(*flags & (MFD_EXEC | MFD_NOEXEC_SEAL))) {
        if (sysctl >= MEMFD_NOEXEC_SCOPE_NOEXEC_SEAL)
                *flags |= MFD_NOEXEC_SEAL;
        else
                *flags |= MFD_EXEC;
}
```

and `MFD_NOEXEC_SEAL` clears the inode's execute bits outright (`inode->i_mode &= ~0111`) and sets `F_SEAL_EXEC`. On a host with `vm.memfd_noexec=1` — the setting deployed precisely to stop fileless-execution malware — SELF's default loader stops working, with `EACCES` from `execveat` and no diagnostic connecting it to a sysctl. The technique the format depends on is the technique the hardening exists to block. Mainline's `MFD_EXEC` is the fix, and it is a one-word source change nobody has made.

### 2. `binfmt_misc` registration as a persistence and privilege surface

The mechanism is covered in full by [the `binfmt_misc` deep-dive][binfmt]; what belongs here is what registration means _for an artifact whose identity is a magic number_.

**The capability required is smaller than it looks.** `binfmt_misc` sets `FS_USERNS_MOUNT` ([`fs/binfmt_misc.c`][bm-src], line 1025), so `mount_capable` takes the `ns_capable(fc->user_ns, CAP_SYS_ADMIN)` branch rather than `capable(CAP_SYS_ADMIN)`. Since Linux 6.7 an unprivileged user who can `unshare -Ur` can mount their own instance and register handlers for themselves and their descendants; `load_binfmt_misc` walks `user_ns->parent` until it finds one, falling back to `init_binfmt_misc`. Registration is therefore _not_ a root-only act — but a registration that affects the **host** still is, and that distinction is the whole of the risk analysis.

**It is a documented persistence technique with a documented detection gap.** From dfir.ch's writeup:

> _"binfmt_misc provides a nifty way (once the attacker has gained root rights on the machine) to create a little backdoor to regain root access when the original access no longer works,"_ and _"neither MITRE ATT&CK nor the five-part Elastic Security 'Linux Persistence Detection Engineering' series mentioned it."_
>
> — [dfir.ch, _Today I learned: `binfmt_misc`_][dfir-binfmt]

The escalation primitive is the `C` flag, which makes `bprm_creds_from_file` derive credentials from **the binary** rather than the interpreter. Point an entry's magic at the first bytes of an existing root-setuid binary, name your own interpreter, and you execute as root without the setuid binary's code ever running — SentinelOne's "Shadow SUID" ([2019][shadow-suid]). The kernel documentation warns about exactly this and offers no narrower tool. Detection keyed on _executing_ the setuid binary observes nothing, because, in the words of the same writeup, it is _"a proxy execution."_

**The `F` flag changes the risk in both directions and it is worth being precise about which.** `F` opens the interpreter at registration time and stores the `struct file *`, cloning it per exec. Its author's stated purpose is containers:

> _"The net effect is that the handler survives both changeroots and mount namespace changes, making it easy to work with foreign architecture containers without contaminating the container image with the emulator."_
>
> — James Bottomley, [`948b701a607f`][c-fixbinary]

Read as a defence, `F` **removes** a class of attack: without it the interpreter path is resolved lazily, in the exec'ing task's namespace and root, so anyone who can arrange for a different file to appear at that path — a bind mount, a `chroot`, a mount namespace, a race on a writable directory — substitutes the interpreter for every matching `execve` on the system. `F` pins the inode at registration and closes that hole. Read as an attack, `F` **strengthens** persistence: the backdoor no longer depends on its path continuing to resolve, survives the file being unlinked or its directory being remounted, and pins the inode against reclamation until the entry is removed. It does not survive a reboot — the registry is volatile, which is the single best property this facility has for defenders and the single most annoying for deployers.

**The catalog-specific point is not about escalation at all.** It is that dispatch is _out-of-band_. A `.self` file carries its own schema, its own segments, its own symbol table and its own dependency closure — and does not carry the one fact that decides what happens when you `chmod +x` and run it. Whoever controls `/proc/sys/fs/binfmt_misc` controls the meaning of every artifact whose identity lives in a magic number, and no property of the bytes can contest it. An autological artifact is self-describing about everything except its own interpretation.

### 3. The sandboxing primitives these projects already reach for

Four primitives, and the interesting question is a narrow one: **can any of them express "read-only on these bytes of this file, read-write on those"?**

| Primitive   | Enforces                                        | Granularity                            | Revocable on an already-open `fd`?             | Byte ranges? |
| ----------- | ----------------------------------------------- | -------------------------------------- | ---------------------------------------------- | ------------ |
| `pledge(2)` | Syscall _subsystems_ ("promises")               | The whole process                      | n/a — it is not about files                    | **No**       |
| `unveil(2)` | A path prefix + `rwxc` permission string        | Filesystem object / subtree            | No (existing descriptors keep working)         | **No**       |
| Landlock    | `LANDLOCK_ACCESS_FS_*` bits on a path hierarchy | Filesystem object, evaluated at `open` | No — rights are latched onto the `struct file` | **No**       |
| seccomp-BPF | Syscall number + scalar register arguments      | The syscall                            | n/a                                            | **No**       |

**`pledge`** partitions POSIX into subsystems and is monotonic: _"Subsequent calls to `pledge`() can reduce the subsystems which still work, but previously revoked subsystems cannot be re-activated"_ ([`pledge(2)`][pledge]). A violation is _"the process being killed with an uncatchable `SIGABRT`."_ It is deliberately not path-aware; the manual defers path questions to `unveil(2)`. So `pledge` can say _this worker may not open files at all_ — which is [exactly what redbean's `-SSS` does][ape] — but it cannot say anything about _which_ bytes of a file that is already open.

**`unveil`** is path-aware and coarse: _"The first call to `unveil()` removes visibility of the entire filesystem from all other filesystem-related system calls … except for the specified path and permissions"_ ([`unveil(2)`][unveil]). Permissions are four characters, `r w x c`, applied to a path or a subtree. The unit is a filesystem object.

**Landlock** is the Linux analogue and its granularity is stated by its implementation, not just its documentation. `hook_file_open` computes the allowed access bits once and stores them on the file:

```c
/* security/landlock/fs.c — hook_file_open() */
/*
 * For operations on already opened files (i.e. ftruncate()), it is the
 * access rights at the time of open() which decide whether the
 * operation is permitted. Therefore, we record the relevant subset of
 * file access rights in the opened struct file.
 */
landlock_file(file)->allowed_access = allowed_access;
```

Two consequences. First, Landlock's world model is _inodes and hierarchies_: the fifteen `LANDLOCK_ACCESS_FS_*` bits are `EXECUTE`, `READ_FILE`, `WRITE_FILE`, `TRUNCATE`, the `MAKE_*` family, and so on ([`landlock.h`][ll-uapi]). None of them takes an offset. Second, a descriptor opened before the ruleset is enforced is not affected — the documentation says the same thing about IOCTLs (_"it only applies to newly opened device files. This means specifically that pre-existing file descriptors like stdin, stdout and stderr are unaffected"_, [`landlock.rst`][ll-doc]), and this is precisely the property redbean's SQLite recipe exploits deliberately.

**seccomp-BPF** is the one where the answer is _nearly_ yes, and the near-miss is instructive. A filter sees `struct seccomp_data`: the syscall number and the six argument registers. `pwrite64(fd, buf, count, offset)` puts `offset` in a register, so a filter _can_ reject writes past a boundary. It cannot do the job anyway, for three independent reasons:

1. `fd` is a small integer with no filterable meaning — the filter cannot tell the artifact's descriptor from a log file's.
2. `write(2)` after `lseek(2)` carries no offset at all, and SQLite's unix VFS uses `pwrite` but is under no obligation to.
3. A `MAP_SHARED` mapping bypasses the syscall layer entirely; there is no syscall per store instruction.

And the reason it can never be fixed by making filters smarter is stated in the kernel's own design rationale:

> _"BPF makes it impossible for users of seccomp to fall prey to time-of-check-time-of-use (TOCTOU) attacks that are common in system call interposition frameworks. BPF programs may not dereference pointers which constrains all filters to solely evaluating the system call arguments directly."_
>
> — [`Documentation/userspace-api/seccomp_filter.rst`][sec-doc]

The inability to follow a pointer is not an oversight; it is the property that makes seccomp sound. A filter that could resolve `fd` to a path, or read a buffer, would reintroduce the race it was designed to eliminate. `SECCOMP_RET_USER_NOTIF` moves the decision to a supervisor process that _can_ read the tracee's memory, and the documentation immediately hangs the caveat back on: _"care should be taken to avoid the TOCTOU mentioned above … all arguments being read from the tracee's memory should be read into the tracer's memory before any policy decisions are made."_

**These primitives compose, and Cosmopolitan is the proof.** `unveil()` on Linux is implemented as a Landlock ruleset plus a seccomp-BPF filter that plugs the syscalls the ruleset could not reach ([`libc/calls/unveil.c`][cosmo-unveil]):

```c
/* libc/calls/unveil.c — unveil_final() */
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
if ((rc = landlock_restrict_self(State.fd, 0)) != -1 &&
    (rc = sys_close(State.fd)) != -1 &&
    (rc = prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &sandbox)) != -1)
```

with the BPF program a two-syscall blacklist — `setxattr` always, and `truncate` too when the Landlock ABI is below 3 and therefore lacks `LANDLOCK_ACCESS_FS_TRUNCATE`. `pledge()` on Linux is seccomp-BPF alone, which is why redbean's help text can promise it _"will work on all Linux kernels since RHEL6 … On the other hand, `unveil()` requires Landlock LSM which was only introduced in 2021"_ ([`help.txt`][cosmo-help]). Two OpenBSD primitives, four Linux mechanisms, one emulation layer — and still no byte ranges anywhere in it.

### 4. Signed measurement of a legitimately-mutating file

Three Linux facilities measure file content cryptographically. They differ in _what_ they measure, _when_, and what they assume about change.

| Facility                | Measures                                                             | When                                                                              | Assumes immutability                         | Granularity                         |
| ----------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------------------- |
| **IMA**                 | Whole-file hash → measurement log + TPM PCR                          | At `execve`, `mmap`, `open` (`ima_bprm_check`, `ima_file_mmap`, `ima_file_check`) | Per-open, not per-file                       | Whole file                          |
| **IMA appraisal + EVM** | Hash or signature in `security.ima`, with EVM HMAC over the metadata | Same hooks, as a gate                                                             | **Yes**, for signed files                    | Whole file / metadata               |
| **dm-verity**           | Merkle tree over a block device                                      | On block read                                                                     | **Yes** — _"This target is read-only"_       | Block device                        |
| **fs-verity**           | Merkle tree over one file                                            | On every read, **including page faults**                                          | **Yes** — file becomes permanently read-only | Merkle-tree block (typically 4 KiB) |

#### IMA: an autological artifact is, by construction, an integrity violation

IMA hashes a file at open and appends a record to the measurement log, extending a TPM PCR. Its cache is invalidated when the file changes — `ima_detect_file_change` compares `STATX_CHANGE_COOKIE` or `i_version` against the recorded value, and `ima_check_last_writer` clears `IMA_DONE_MASK` when the last writer closes ([`ima_main.c`][ima-main]). For a `self-httpd` that commits on every request, that means a fresh measurement per open, forever: the log grows without bound and the PCR never quiesces, so a remote-attestation quote of that PCR is meaningless after the first request.

That is the mild version. The sharp version is that IMA has a _name_ for this situation and treats it as a violation, not a re-measurement. `ima_rdwr_violation_check` fires in two directions:

```c
/*
 * ima_rdwr_violation_check
 *
 * Only invalidate the PCR for measured files:
 *	- Opening a file for write when already open for read,
 *	  results in a time of measure, time of use (ToMToU) error.
 *	- Opening a file for read when already open for write,
 *	  could result in a file measurement error.
 */
```

A `self-httpd` process hits both. The kernel measured the artifact at `bprm_check` (read side, so `IMA_MAY_EMIT_TOMTOU` is set), and the process then opens the same inode read-write — `ToMToU`. Meanwhile every subsequent read of a file with `inode_is_open_for_write()` true emits `open_writers`. And a violation does not merely log:

```c
/* security/integrity/ima/ima_queue.c — ima_add_template_entry() */
if (violation)		/* invalidate pcr */
        digests_arg = digests;
```

where `digests` is the static array initialised with `memset(digests[i].digest, 0xff, digest_size)`. **A violation extends the PCR with all-ones, permanently poisoning it for the rest of the boot.** IMA's design position is that a file being read while it is being written is not a measurable object, and the autological artifact is that condition made into an architecture.

Under _appraisal_ with a signature it is worse in a cleaner way: `ima_update_xattr` opens with

```c
/* do not collect and update hash for digital signatures */
if (test_bit(IMA_DIGSIG, &iint->atomic_flags))
        return;
```

so a signed file's `security.ima` is never refreshed on write; the next appraisal compares the signed digest against changed content and fails `invalid-signature`. **EVM does not help**, because EVM is not a content mechanism at all: it HMACs the _metadata_ — the xattr set (`security.selinux`, `security.ima`, `security.capability`, …) plus inode identity (`i_ino`, `i_generation`, `i_uid`, `i_gid`, `i_mode`) via `hmac_add_misc` ([`evm_crypto.c`][evm-src]). EVM protects the statement "this is the IMA digest for this inode" from tampering. It has nothing to say about whether the digest is still true.

#### dm-verity: right shape, wrong unit

dm-verity is a device-mapper target whose documentation opens with the constraint: _"Device-Mapper's 'verity' target provides transparent integrity checking of block devices using a cryptographic digest provided by the kernel crypto API. This target is read-only."_ ([`verity.rst`][dmv-doc]). The root hash is supplied out of band — kernel command line, signed initrd, or a signature verified against a kernel keyring. It is the correct model for an immutable system image and structurally incapable of hosting a file that writes to itself, since the _device_ is read-only.

#### fs-verity: the closest existing fit, and why it still cannot help

fs-verity is the one worth dwelling on, because on three of four properties it is exactly what an autological artifact needs.

1. **It is per-file, not per-device.** Its own documentation states the split: _"fs-verity does not replace or obsolete dm-verity. dm-verity should still be used on read-only filesystems. fs-verity is for files that may live on a read-write filesystem"_ ([`fsverity.rst`][fsv-doc]).
2. **Verification is at read time, lazily, at Merkle-block granularity.** `fsverity_verify_blocks` is called from `->read_folio()`/`->readahead()` before a folio is marked uptodate; the tree is ascended only until an already-verified hash block is cached. This is demand paging with integrity, which is _precisely_ the property a demand-paged executable needs.
3. **It covers `mmap`.** The documentation is explicit that hooking `->read_iter()` would not be enough _"since `->read_iter()` is not used for memory maps"_, and that failures surface as _"EIO (for `read()`) or SIGBUS (for `mmap()` reads)"_. A running program's text is verified page by page as it faults in, for the whole life of the process — which is strictly stronger than IMA's measure-once-at-`execve`.

That third property is the one this catalog should care most about, and it is worth stating plainly: **fs-verity is the only shipping Linux facility that keeps verifying an artifact while it is being executed.** Everything else measures at a moment and trusts thereafter.

And then the fourth property kills it. `FS_IOC_ENABLE_VERITY` calls `deny_write_access(filp)` before building the tree, and the resulting state is one-way:

> _"Verity files are readonly. They cannot be opened for writing or `truncate()`d, even if the file mode bits allow it. Attempts to do one of these things will fail with `EPERM`."_ … _"ext4 sets the `EXT4_VERITY_FL` on-disk inode flag on verity files. It can only be set by `FS_IOC_ENABLE_VERITY`, and it cannot be cleared."_

Both ext4 and f2fs additionally store the Merkle tree _past `i_size`_, an approach the documentation justifies with _"(a) verity files are readonly"_ — so the immutability is baked into the on-disk layout, not merely into the permission check. A verity-enabled `.self` file cannot be `INSERT`ed into, cannot be `VACUUM`ed, and cannot be `patchelf`'d-as-`UPDATE`. Everything the format exists to demonstrate is exactly the set of operations `EPERM` now covers.

The best available compromise is IMA-over-fs-verity: `digest_type=verity` in an IMA policy makes IMA use the fs-verity file digest instead of its own hash, and `appraise_type=sigv3` verifies a signature over it ([`ima_policy` ABI][ima-abi], and `IMA_VERITY_DIGSIG` in [`ima_appraise.c`][ima-appr]). This composes measurement, appraisal and continuous read-time verification into one mechanism — for immutable files. It does not move the boundary at all; it just makes the immutable side of it much better defended.

---

## Format identity and multiplicity

Not applicable in the usual sense — this page has no bytes of its own — but the _absence_ is a finding, and it is the one that makes every enforcement mechanism above awkward.

Every facility surveyed here identifies its subject by something other than content. IMA identifies by inode plus policy rule (`func=BPRM_CHECK`, `fowner=`, `fsuuid=`). fs-verity identifies by an on-disk inode flag. Landlock identifies by inode reachability through a path hierarchy. dm-verity identifies by device. `binfmt_misc` is the sole exception — it identifies by content, in a 256-byte window — and it is also the only one of them that makes no security decision.

That division is not accidental. **Content-based identity is not stable enough to hang a permission on**, because content is what the artifact mutates. The moment SELF's premise is granted — segments are rows, and rows change — the file's hash stops being an identity and becomes a timestamp. Every mechanism in area 4 above is downstream of that.

The multiplicity score is 0 and the reason is worth stating: security enforcement is the one domain in this catalog where _nobody_ wants a byte stream to admit two parses. [Parser differentials][diffs] is that argument in full; this page is what happens after you have won it and are left with a single, agreed, mutating parse.

## Index anchoring and random access

Also not applicable directly, and again the absence is the finding: **every policy that governs an autological artifact is an out-of-band index over it**, in exactly the sense [concepts][concepts] gives the term — a materialized view, with a materialized view's invalidation problem.

| Policy artefact                 | Lives in                                | Invalidated by                             |
| ------------------------------- | --------------------------------------- | ------------------------------------------ |
| `binfmt_misc` registration      | A pseudo-filesystem, per user namespace | Reboot; a shadowing namespace mount        |
| IMA measurement log + PCR       | Kernel memory + TPM                     | Any write to the file; a violation record  |
| `security.ima` / `security.evm` | Extended attributes on the inode        | Any content change (signature case: fatal) |
| fs-verity Merkle tree           | Past `i_size` on ext4/f2fs              | Nothing — writes are refused instead       |
| Landlock ruleset                | A kernel object referenced by an `fd`   | Nothing; it is monotonic per thread        |
| SELinux policy                  | A separate binary policy loaded at boot | Policy reload                              |

Only fs-verity solves the invalidation problem, and it solves it by forbidding the change. Everything else stores an assertion about bytes somewhere the bytes cannot reach, which is the same structural failure as a stale `ldconfig` cache and has the same fix (recompute) and the same cost (recomputation is `O(file)` and the file is being written).

The random-access question has one genuinely positive answer, from fs-verity: verification cost is `O(log n)` per block read, not `O(file)`, because the tree is ascended only to the first cached hash block. An artifact could in principle be _partially_ verified — the pages you actually execute, and only those. That is the right cost model for [range-request access][range] and for a [footer-indexed][footer] artifact read over HTTP. It is available today, for files that never change.

## Reflexivity and query surface

The enforcement layer's introspection surface is thin, textual, and mostly one-way.

- **`/proc/sys/fs/binfmt_misc/<name>`** reads back a registration in full — interpreter, flags, offset, magic, mask — with the flag letters reconstructed from bits. What it cannot answer is the question a defender actually has: _which entry would claim this file?_ Answering it means re-implementing the matcher in userspace.
- **IMA's measurement log** (`/sys/kernel/security/ima/ascii_runtime_measurements`) is append-only and queryable, and is the closest thing in this page to a relational surface: a table of `(pcr, template-hash, template-name, file-digest, path)` rows. [Relational system surfaces][relational] argues that osquery-style projections of exactly this kind are where the reflexivity axis actually pays off; IMA is a ready-made table nobody in this catalog is joining against.
- **Landlock is deliberately opaque.** A sandboxed thread cannot enumerate its own ruleset, and until the audit support added in recent kernels it could not learn _why_ an access was denied either. Least privilege and self-inspection are in tension: a process that can read its own policy can plan around it.
- **`pledge` inverts that**, slightly: Cosmopolitan exposes the promise set as a `__promises` global so tools can consult it and `unveil()` a matching subset of files ([`pledge.c`][cosmo-pledge], the `vminfo` promise). That is reflexivity-by-convention inside one libc, not a kernel surface.

Score 1: an artifact can ask _whether_ it is confined (redbean's documented `unix.pledge(nil, nil)` feature check), but nothing here lets it ask _how_, and none of it is a general query language.

## Closure, dedup, and size model

Applies in one direction only, and it is a direction the catalog has not made enough of: **self-containment is a security property, not only a distribution one.**

The demonstration is redbean's `-SSS` mode. Workers call `unix.pledge("stdio")` after `fork()`, and the help text draws the conclusion: _"Redbean should only be able to serve from its own zip file in this mode"_ ([`help.txt`][cosmo-help]). A worker with no filesystem access at all still serves every asset, because the archive was `mmap`ed before the sandbox was entered. **An artifact that carries its closure needs a smaller sandbox**, because the set of files it must be allowed to open is empty. The [closure axis][concepts] and the least-privilege axis point the same way, which is not obvious in advance and is one of the few unambiguously good findings on this page.

The same document supplies the general recipe, for the case where the state store is a separate file:

> _"What makes this technique interesting is redbean doesn't have file system access to the database file, and instead uses an inherited file descriptor that was opened beforehand."_
>
> — [`help.txt`][cosmo-help], the SQLite sandboxing example

Open first, then drop. It is the oldest privilege-separation idiom on Unix and it works because descriptors survive a sandbox that paths do not. Hold that thought for [the open question](#the-open-question-the-least-privilege-decomposition), where it turns out to be the _only_ mechanism on the list that survives contact with the problem.

The cost side is real too. The size numbers [SELF reports][measure] — 611.9 MiB of closure database against 5.53 GiB under an AppImage-style model — are a deduplication win, and deduplication is _shared mutable state_: one `libc` row serving 723 executables is one row an attacker needs to `UPDATE`. Nix answers this with a read-only store and content addressing ([nix-store closures][nix]); a SELF closure database has neither by default. That is not an argument against the design, but it is the entry the ledger is missing.

## Mutability, dispatch, and trust

This is the section the rest of the page has been assembling, so it is short and it is a summary.

**Mutability score 3, and it is the axis that makes every other mechanism inapplicable.** Stated as a chain:

1. The artifact's state store is the artifact. Therefore its bytes change while it runs.
2. Therefore no whole-file digest is a stable identity, so IMA appraisal, dm-verity and fs-verity are all excluded — the first fails, the second cannot host it, and the third refuses the write.
3. Therefore the only signature design available is over a _subset_ — per-table Merkle roots over a canonical row encoding, signing the immutable tables only. `DESIGN.md` §12 names the shape (_minisign over a canonical serialization_) and calls "signing rows, not bytes" a novel-feeling win, which is another way of saying nobody has built it. [Embedded provenance][provenance] carries that argument.
4. And a subset signature is unenforceable at the kernel, because no kernel mechanism can tell which bytes are in the subset. `VACUUM` moves rows between pages; a b-tree page's contents are not a function of the table it holds.

**Dispatch is out-of-band and forgeable by anyone with `CAP_SYS_ADMIN` in the relevant user namespace.** The artifact carries everything about itself except what it _is_.

**`mmap` and page sharing appear here as a security fact and not only as a performance one.** A conventional ELF's text is a shared, read-only, file-backed mapping — which is why it is attributable (SELinux `file:execute` against a labelled inode), why it is verifiable (fs-verity checks it at fault time), and why it is shared. SELF's text is anonymous memory filled from a b-tree, which is none of those things. [Thesis 4][concepts] says `mmap` is the load-bearing constraint; this page adds that it is load-bearing for _three_ properties, and the catalog has so far only counted one of them.

---

## The open question: the least-privilege decomposition

> **Can the process hold a read-only handle to its own text tables and a writable handle to its state tables, enforced below the application?**

Six candidate answers. Two are real, one is real but expensive, and three are not answers.

### Not an answer: two file descriptors with different open modes

The mechanism works — `open(path, O_RDONLY)` and `open(path, O_RDWR)` on the same inode give two descriptors the kernel enforces differently, and the enforcement is genuinely below the application. It does not solve _this_ problem because both descriptors address **all** of the file. SQLite's b-tree gives no stable mapping from table to byte range: page allocation is dynamic, `VACUUM` rewrites the whole file, and a row's blob may be spilled across overflow pages anywhere in it. A descriptor cannot be told "these bytes only", so the read-only handle is not a handle to the text tables; it is a second handle to everything, which is useless. And SQLite will only write through a connection whose descriptor is writable, so the writable one has to reach the `segments` table as well.

### Not an answer: the SQLite authorizer callback

`sqlite3_set_authorizer` is the obvious in-process lever and SELF does not use it. It is also disqualified by construction — it is _application-level_, running in the same address space as the code it constrains, so a memory-safety bug in the request handler removes it. The documentation is precise about a second limitation that matters more than it looks:

> _"The authorizer callback is invoked only during `sqlite3_prepare()` or its variants. Authorization is not performed during statement evaluation in `sqlite3_step()`."_
>
> — [`sqlite3_set_authorizer`][authorizer]

So the check is at _compile_ time, once per statement, and the intended use is stated as narrowly: _"An authorizer is used when preparing SQL statements from an untrusted source."_ It is a lever against untrusted **SQL**, not against untrusted **code**. `PRAGMA query_only` is in the same category — a per-connection flag any code in the process can clear.

This is not an argument against using it. A `self-httpd` that installed an authorizer denying `SQLITE_UPDATE`/`SQLITE_DELETE`/`SQLITE_DROP_TABLE` on `segments`, `symbols` and `relocations` would be strictly better than one that does not, and it costs about twenty lines. It is defence in depth, and it does not answer the question, which asked for enforcement _below_ the application.

### Not an answer: splitting into two database files

Two files — an immutable one holding `segments`/`symbols`/`relocations`, `ATTACH`ed read-only, and a mutable one holding `visits`/`routes` — makes the decomposition trivially enforceable. Open the first `O_RDONLY` with `SQLITE_OPEN_READONLY`, fs-verity-enable it, sign it, IMA-appraise it; open the second read-write and never measure it. Every mechanism in area 4 becomes applicable at once.

And it forfeits the single property the catalog exists to study. A `.self` file that needs a second file beside it is not an autological artifact; it is a program with a data file, which is what we already had. The [one-file property is a property of the access layer][self], not the format, and this is the cleanest illustration in the catalog: the security answer and the autology are in direct opposition, and the trade is total rather than gradual. Note that `self-httpd` already pays a weaker version of this tax — WAL mode puts `server-wal` and `server-shm` next to the executable for as long as a connection is open, which is why the example makes the journal mode a flag.

### Real, and partial: a Landlock ruleset (or `unveil`)

Landlock can express _"this process may open the artifact for reading and nothing else"_, and enforce it below the application, for any descriptor opened after `landlock_restrict_self`. That is a genuine, deployable hardening for the **read-only** half of the split: a query-only `self` tool, a worker that serves `routes` but never logs a visit, an `sqlelf`-style inspector.

It cannot do the split. Its access bits are per-filesystem-object, its rights are latched at `open`, and there is no offset anywhere in the ABI. It also cannot revoke: the descriptor `sqlite3_open` obtained before the ruleset was applied keeps every right it was opened with, which is the same property redbean's SQLite recipe uses on purpose. Landlock is the right tool for _"reduce the set of files"_ and has nothing to say about _"reduce the set of bytes"_.

### Real, and the honest answer: a helper process

Split the privilege across an address-space boundary. The server holds the artifact `O_RDONLY`, `pledge("stdio")`/Landlock-confines itself, and reads `routes` and `segments` freely. A small writer process — spawned before the sandbox, holding the only read-write descriptor — receives state mutations over a socket and executes them. The server has no way to reach `segments`, because it has no writable descriptor and cannot obtain one.

This is classic OpenBSD-style privilege separation, and it is a real answer. Its costs are real too, and they are structural rather than incidental:

- **The transaction boundary now crosses a process boundary.** `self-httpd`'s most attractive property is that editing the live site is an `UPDATE` and rolling it back is a `ROLLBACK`. Split across two processes, a transaction spanning "serve this and record that" is a distributed transaction.
- **SQLite is not designed for it.** Two connections to one file coordinate through file locks and, in WAL mode, through a shared-memory `-shm` file the reader must also be able to map — so the "read-only" side needs write access to something after all, unless it uses `PRAGMA locking_mode=EXCLUSIVE` on a rollback-journal database or the read-only WAL mode with `SQLITE_FCNTL_PERSIST_WAL`. The one-file property degrades again.
- **The writer is now the trusted component,** and it is the component reachable from request handling. The decomposition moves the attack surface; it does not shrink it, unless the writer's accepted vocabulary is much smaller than SQL — which means designing an application-specific protocol, i.e. giving up on "the state store is a general query surface".

### What a kernel would have to offer

The clean answer does not exist, and it is possible to say precisely what is missing: **a per-descriptor, kernel-enforced, byte-range restriction — a descriptor that is read-write on `[a,b)` and read-only everywhere else.**

Nothing in Linux provides it, and one thing that came close was deliberately removed. Mandatory file locking — `-o mand` plus the setgid-without-group-execute mode bit — could make `fcntl` record locks _enforced by the kernel_ rather than advisory, over byte ranges. It was ripped out in Linux 5.15:

> _"This patch rips out mandatory locking support wholesale from the kernel, along with the Kconfig option and the Documentation file. It also changes the mount code to ignore the `mand` mount option instead of erroring out, and to throw a big, ugly warning."_
>
> — Jeff Layton, [`f7e33bdbd6d1` "fs: remove mandatory file locking support"][c-mand] (2021-08-19)

The commit message's justification — one reported problem in six years — is a fair summary of how much anyone wanted it. It would not have sufficed anyway (record locks are per-`(pid, inode)` and say nothing about `mmap`), but its removal is the clearest evidence available that the kernel is moving _away_ from byte-range access control, not toward it.

The nearest surviving primitive is `memfd` sealing. `F_SEAL_WRITE` makes a memfd permanently unwritable; `F_SEAL_FUTURE_WRITE` blocks future writes while leaving existing writable mappings alone; `F_SEAL_EXEC` freezes the execute bits ([`fcntl.h`][fcntl-uapi]). Seals are the right _shape_ — irreversible, enforced in `check_write_seal` below every caller, attached to the object rather than to a path — and the wrong _scope_ in two ways: they are whole-file, and they only exist on `shmem`/`hugetlbfs`, never on the ext4 file a `.self` binary actually lives in.

So the specification for the missing primitive is short:

1. **Extent-granular seals on a regular file**, or equivalently an `openat2` flag that returns a descriptor whose write permission is restricted to a byte range, checked in the same place `deny_write_access` is checked and honoured by `mmap` (`MAP_SHARED|PROT_WRITE` outside the range must fail).
2. **A stable mapping from the application's units to those extents.** This is the harder half and it is not the kernel's problem: SQLite would have to guarantee that a named table's pages stay inside a declared extent across `VACUUM`, which is a reserved-region or per-table-file design and a substantial change to the b-tree.

Requirement 2 is why the answer is "no" today rather than "not yet". Even given a perfect kernel primitive, the b-tree does not offer a byte range to point it at — which is the same fact that defeats the [aligned-blob `mmap` proposals][self] for page sharing. The two open questions the catalog considers hardest, _"how does a SELF binary share text"_ and _"how does a SELF binary protect its text"_, turn out to have one shared prerequisite: **a stable, page-aligned, per-table extent in the file.** Whoever produces that answers both, and nobody has.

---

## Strengths

As a lens over the catalog, not as a thing to build:

- **It converts an aesthetic objection into checkable claims.** "Self-modifying executables are scary" becomes four specific propositions — `execmem` is required, `ETXTBSY` does not apply, IMA records a `ToMToU` violation, fs-verity refuses the write — each verifiable from source in minutes.
- **It finds a real bug rather than a general worry.** `selfld.c` leaves RWX text with a comment promising hardening that no line performs. That is a `git blame`-able defect, not a design critique.
- **It names a coincidence the catalog can act on.** `mmap`-shared, verifiable, and attributable are the same property of file-backed text. Solving page sharing solves measurement and SELinux labelling for free; the reverse is also true.
- **It supplies a positive result.** Carrying the closure shrinks the sandbox — a worker with `pledge("stdio")` and no filesystem access still serves. Self-containment is a security property.
- **The negative answers are stated with their mechanisms.** "Landlock cannot do this" is not an impression; it is `landlock_file(file)->allowed_access` being computed once, at `open`, from a bit set with no offset field.

## Weaknesses

- **Nothing here is measured.** Every claim is from source reading. The obvious experiment — run `self-httpd` under an IMA policy with `func=BPRM_CHECK` and count violations per request — was not performed, and [measurement][measure] is where it belongs.
- **The macOS treatment is thinner than the Linux one,** because Apple's authoritative descriptions of the Hardened Runtime and `MAP_JIT` are on documentation pages that are not fetchable as text; the primary evidence used here is Cosmopolitan's implementation of the dance rather than Apple's specification of it.
- **The Windows story is missing entirely.** Authenticode over a mutating file, CI/CD signing, and the `MZ` `binfmt_misc` collision on WSL are all in scope and are not covered.
- **The threat actors are unmodelled.** This page enumerates broken guarantees; it does not say who breaks them, with what access, for what gain. A real threat model would have an attacker table, and this is an analysis of mechanisms instead.
- **"Below the application" is doing a lot of work and is never defined precisely.** A SQLite VFS shim is below the application in the layering sense and inside it in the address-space sense; the page treats the address-space sense as decisive without arguing for it.
- **It stops at the file.** Everything above concerns one artifact. A SELF _closure database_ shared by 723 executables is shared mutable state with a completely different threat model, and that analysis is not here.

---

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                          | Trade-off                                                                                                       |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| redbean gates self-modification behind `-*`, applied before `LuaInit()` | Makes a `W^X` violation an operator decision, not a script's; ordering prevents runtime escalation | An unused capability that has bit-rotted into a stub — the gate outlived the feature                            |
| SELF has no equivalent gate                                             | The file must be writable for the state story to work at all; a gate would gate the whole design   | No opt-in, no audit point, and one connection with DDL rights over `segments`                                   |
| Loaders copy text into anonymous memory                                 | The only way to run bytes that live in b-tree pages                                                | Requires SELinux `execmem`; forfeits page sharing, fs-verity verification, and file-based attribution at once   |
| Dispatch by `binfmt_misc` rather than a native header                   | No kernel patch, no format registry — the artifact runs today                                      | `deny_write_access` lands on the interpreter, so `ETXTBSY` never protects the artifact; identity is out-of-band |
| `binfmt_misc` mountable with `ns_capable`                               | Sandboxes register their own handlers without host cooperation                                     | Anyone who can `unshare -U` redefines what an artifact _is_ inside their namespace                              |
| fs-verity makes a file permanently read-only on enable                  | Lets verification be lazy, per-block, and correct under `mmap` with no revalidation                | Excludes by construction every artifact this catalog studies                                                    |
| IMA treats read-while-written as a violation, not a re-measurement      | A file changing under a reader has no well-defined measurement                                     | Extends the PCR with all-ones — one self-storing server poisons attestation for the boot                        |
| seccomp-BPF forbids pointer dereference                                 | Eliminates TOCTOU in syscall interposition, by construction                                        | No filter can ever be path-aware or content-aware; path policy must come from an LSM instead                    |
| Landlock latches rights onto `struct file` at `open`                    | One lookup per open; later operations are cheap and race-free                                      | Pre-existing descriptors are unaffected — which is a sandbox escape and a deliberate feature at the same time   |
| Mandatory locking removed (Linux 5.15)                                  | Six years of near-zero use against real maintenance cost                                           | Deletes the only kernel facility that was even shaped like byte-range access control                            |
| Two database files would make the split enforceable                     | Every measurement and appraisal mechanism becomes applicable immediately                           | Forfeits the one-file property, i.e. the entire subject of this catalog                                         |

---

## Sources

- Linux `v7.1-rc6` (`e43ffb69e043`): [`fs/verity/verify.c`][fsv-verify] · [`fs/verity/enable.c`][fsv-enable] · [`security/integrity/ima/ima_main.c`][ima-main] · [`ima_queue.c`][ima-queue] · [`ima_appraise.c`][ima-appr] · [`security/integrity/evm/evm_crypto.c`][evm-src] · [`security/landlock/fs.c`][ll-src] · [`security/selinux/hooks.c`][selinux-src] · [`mm/memfd.c`][memfd-src] · [`fs/exec.c`][exec-src] · [`fs/binfmt_misc.c`][bm-src] · [`include/uapi/linux/landlock.h`][ll-uapi] · [`include/uapi/linux/fcntl.h`][fcntl-uapi]
- Kernel documentation: [fs-verity][fsv-doc] · [dm-verity][dmv-doc] · [Landlock][ll-doc] · [seccomp BPF filtering][sec-doc] · [`mseal`][mseal-doc] · [the `ima_policy` ABI][ima-abi]
- Kernel history: [`f7e33bdbd6d1` "fs: remove mandatory file locking support"][c-mand] · [`948b701a607f` the `binfmt_misc` `F` flag][c-fixbinary] · [`f1ec2b5604a7` `mm->exe_file` labelling under transparent dispatch][c-exefile]
- OpenBSD manual pages: [`pledge(2)`][pledge] · [`unveil(2)`][unveil] · [`mmap(2)`][mmap2] · [`mount(8)`][mount8] · [`mimmutable(2)`][mimmutable]
- Apple: [Porting just-in-time compilers to Apple silicon][apple-jit] · [Hardened Runtime][apple-hr] — cited as documentation, not quoted; see [Weaknesses](#weaknesses)
- SQLite: [`sqlite3_set_authorizer`][authorizer] · [`PRAGMA query_only`][pragma-qo] · [the file format][sqlite-fmt]
- [`jart/cosmopolitan`][cosmo] at `3293fad0`: [`tool/net/redbean.c`][redbean-src] · [`tool/net/help.txt`][cosmo-help] · [`libc/calls/unveil.c`][cosmo-unveil] · [`libc/calls/pledge.c`][cosmo-pledge] · [`libc/runtime/jit.c`][cosmo-jit] · [`ape/ape-m1.c`][cosmo-apem1] · [`libc/intrin/mmap.c`][cosmo-mmap]
- [`fzakaria/selfdb`][selfdb] at `e63f7c47`: [`DESIGN.md`][selfdb-design] · [`loader/native.c`][selfdb-native] · [`loader/selfld.c`][selfdb-selfld] · [`loader/self-exec.c`][selfdb-exec] · [`examples/server/server.c`][server-c]
- Security writeups: ["Shadow SUID" for privilege persistence (SentinelOne, 2019)][shadow-suid] · [Today I learned: `binfmt_misc` (dfir.ch)][dfir-binfmt]
- In this catalog: [Concepts and axes][concepts] · [redbean / Cosmopolitan / APE][ape] · [SELF / selfdb][self] · [`binfmt_misc`][binfmt] · [Parser differentials][diffs] · [Embedded provenance][provenance] · [Dynamic linking][dynlink] · [Relational system surfaces][relational] · [Nix store closures][nix] · [Measurement][measure] · [Range-request access][range] · [Footer-indexed formats][footer] · [Open questions][open]
- Distribution-side signing, notarization and SBOM publication are [`docs/research/application-packaging/`][packaging]'s subject, not this page's

<!-- References -->

[fsv-doc]: https://docs.kernel.org/filesystems/fsverity.html
[dmv-doc]: https://docs.kernel.org/admin-guide/device-mapper/verity.html
[ll-doc]: https://docs.kernel.org/userspace-api/landlock.html
[sec-doc]: https://docs.kernel.org/userspace-api/seccomp_filter.html
[mseal-doc]: https://docs.kernel.org/userspace-api/mseal.html
[ima-abi]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/ABI/testing/ima_policy?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[fsv-verify]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/verity/verify.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[fsv-enable]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/verity/enable.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[ima-main]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/integrity/ima/ima_main.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[ima-queue]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/integrity/ima/ima_queue.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[ima-appr]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/integrity/ima/ima_appraise.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[evm-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/integrity/evm/evm_crypto.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[ll-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/landlock/fs.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[ll-uapi]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/landlock.h?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[fcntl-uapi]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/fcntl.h?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[selinux-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/selinux/hooks.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[memfd-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/mm/memfd.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[exec-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/exec.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[bm-src]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/binfmt_misc.c?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[c-mand]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f7e33bdbd6d1bdf9c3df8bba5abcf3399f957ac3
[c-fixbinary]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=948b701a607f123df92ed29084413e5dd8cda2ed
[c-exefile]: https://git.kernel.org/pub/scm/linux/kernel/git/vfs/vfs.git/commit/?id=f1ec2b5604a7c5f239baf2acf894fef67b1dcc90
[pledge]: https://man.openbsd.org/pledge.2
[unveil]: https://man.openbsd.org/unveil.2
[mmap2]: https://man.openbsd.org/mmap.2
[mount8]: https://man.openbsd.org/mount.8
[mimmutable]: https://man.openbsd.org/mimmutable.2
[apple-jit]: https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon
[apple-hr]: https://developer.apple.com/documentation/security/hardened-runtime
[authorizer]: https://www.sqlite.org/c3ref/set_authorizer.html
[pragma-qo]: https://www.sqlite.org/pragma.html#pragma_query_only
[sqlite-fmt]: https://www.sqlite.org/fileformat2.html
[cosmo]: https://github.com/jart/cosmopolitan
[redbean-src]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/net/redbean.c
[cosmo-help]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/tool/net/help.txt
[cosmo-unveil]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/calls/unveil.c
[cosmo-pledge]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/calls/pledge.c
[cosmo-jit]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/jit.c
[cosmo-apem1]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/ape/ape-m1.c
[cosmo-mmap]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/intrin/mmap.c
[selfdb]: https://github.com/fzakaria/selfdb
[selfdb-design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[selfdb-native]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/native.c
[selfdb-selfld]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/selfld.c
[selfdb-exec]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/self-exec.c
[server-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/server.c
[shadow-suid]: https://www.sentinelone.com/blog/shadow-suid-for-privilege-persistence-part-1/
[dfir-binfmt]: https://dfir.ch/posts/today_i_learned_binfmt_misc/
[outline]: ./index.md
[concepts]: ./concepts.md
[ape]: ./cosmopolitan-ape/index.md
[self]: ./self-selfdb/index.md
[binfmt]: ./binfmt-misc.md
[diffs]: ./parser-differentials.md
[provenance]: ./embedded-provenance.md
[dynlink]: ./dynamic-linking.md
[relational]: ./relational-system-surfaces.md
[nix]: ./nix-store-closures.md
[measure]: ./measurement.md
[range]: ./range-request-access.md
[footer]: ./footer-indexed-formats.md
[open]: ./open-questions.md
[packaging]: ../application-packaging/index.md
