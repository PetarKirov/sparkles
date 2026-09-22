# cap-std

A capability-based `std::fs` for Rust: every path is resolved relative to an
open `Dir`, `..` is allowed only while it stays beneath that `Dir`, symlinks
are followed only while they stay beneath it, and an absolute path — typed or
found inside a symlink — is an error, not a re-root.

|                           |                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | library (crate family: `cap-std`, `cap-primitives`, `cap-fs-ext`, `cap-tempfile`, …)                                                                                                                                                                                                                                                                          |
| **Year**                  | 2020 (first commit 2020-05-29); read at `cap-std` 4.0.3, commit of 2026-08-20                                                                                                                                                                                                                                                                                 |
| **Authors / Maintainers** | Dan Gohman (sunfishcode), Jakub Konka; a Bytecode Alliance project                                                                                                                                                                                                                                                                                            |
| **Language**              | Rust (`#![deny(unsafe_code)]` in `cap-primitives`, with `#![allow(unsafe_code)]` on the Windows FFI modules)                                                                                                                                                                                                                                                  |
| **License**               | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT`                                                                                                                                                                                                                                                                                                         |
| **Repository**            | [`bytecodealliance/cap-std`][repo]                                                                                                                                                                                                                                                                                                                            |
| **Platforms**             | Linux, Android, macOS, FreeBSD, Windows; WASI "in development" ([`cap-primitives/README.md`][prim-readme])                                                                                                                                                                                                                                                    |
| **Primitive**             | `openat2(RESOLVE_BENEATH \| RESOLVE_NO_MAGICLINKS)` on Linux ≥ 5.6, `openat(O_RESOLVE_BENEATH)` on FreeBSD ≥ 14, otherwise a user-space component walk with a `..` stack                                                                                                                                                                                      |
| **Source read**           | [`README.md`][readme], [`cap-primitives/src/fs/open.rs`][open-rs], [`manually/open.rs`][manual-open], [`rustix/linux/fs/open_impl.rs`][linux-open], [`rustix/freebsd/fs/`][freebsd-dir], [`windows/fs/`][windows-dir], [`fs/via_parent/`][via-parent], [`rustix/fs/remove_dir_all_impl.rs`][rm-all], [`rustix/fs/remove_open_dir_by_searching.rs`][rm-search] |

## Overview

### What it solves

The crate names its target directly ([`README.md`][readme]):

> Cap-std features protection against [CWE-22], "Improper Limitation of a
> Pathname to a Restricted Directory ('Path Traversal')", which is #8 in the
> [2021 CWE Top 25 Most Dangerous Software Weaknesses]. It can also be used to
> prevent untrusted input from inducing programs to open "/proc/self/mem" on
> Linux.

The concrete consumer is Wasmtime: "cap-std is a foundation for the `WASI`
implementation in `Wasmtime`, providing sandboxing and support for Linux,
macOS, Windows, and more", and "in WASI, `cap-std` becomes a very thin layer,
thinner than `libstd`'s filesystem APIs because it doesn't need extra code to
handle absolute paths" ([`README.md`][readme]). A guest that is handed a
preopened directory gets a `Dir`; the host must be unable to lose that
containment however the guest spells its paths.

The README is also careful about what it is _not_: "`cap-std` is not a sandbox
for untrusted Rust code. Among other things, untrusted Rust code could use
`unsafe` or the unsandboxed APIs in `std::fs`."

### Design philosophy

Ambient authority is the thing being removed. There is no way to open a file
by bare path except through a function that takes an `AmbientAuthority` value
— `Dir::open_ambient_dir(path, ambient_authority())`, `open_parent_dir`,
`create_ambient_dir_all` — each carrying the same doc section: "This function
is not sandboxed and may access any path that the host process has access to"
([`cap-std/src/fs/dir.rs`][dir-rs]). The token does nothing at run time; it
exists so that a grep for `ambient_authority` finds every escape hatch.

The second decision, and the one that distinguishes it from [libpathrs][pathrs]
and [`filepath-securejoin`][securejoin], is _beneath_ rather than _in root_
([`README.md`][readme] § "Why use `RESOLVE_BENEATH`?"):

> Capability-based security is all about _granularity_. We want to encourage
> applications and users to think about having separate handles for
> directories they need, so that they're isolated from each other, rather than
> in terms of having "root directories" containing multiple unrelated
> resources.
>
> Also, some applications have "well known" absolute path strings present,
> such as "/etc/resolv.conf", and could accidentally use them within `Dir`
> methods. `RESOLVE_BENEATH` catches such errors early […]
>
> And, `RESOLVE_BENEATH` handles symlinks within a `Dir` consistently.
> Accessing a symlink to an absolute path within a `Dir` is always an error.
> With `RESOLVE_IN_ROOT`, a symlink to an absolute path in a `Dir` may succeed,
> and potentially resolve to something different than it would when resolved
> through the process filesystem namespace.

## How it works

`cap_primitives::fs::open(start, path, options)` dispatches to a per-platform
`open_impl` ([`fs/open.rs`][open-rs]). Three implementations exist.

### Linux: `openat2`, then fall back

[`rustix/linux/fs/open_impl.rs`][linux-open] tries `openat2` with
`RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS`, in a bounded retry loop:

```rust
// `openat2` fails with `EAGAIN` if a rename happens anywhere on the host
// while it's running, so use a loop to retry it a few times. But not too many
// times, because there's no limit on how often this can happen. The actual
// number here is currently an arbitrarily chosen guess.
for _ in 0..4 {
    match openat2(start, path_c_str, oflags, mode,
                  ResolveFlags::BENEATH | ResolveFlags::NO_MAGICLINKS) {
        Ok(file) => { … return Ok(file); }
        Err(err) => match err {
            rustix::io::Errno::AGAIN => continue,
            rustix::io::Errno::PERM => break,   // some seccomp sandboxes
            rustix::io::Errno::NOSYS => { INVALID.store(true, Relaxed); break; }
            _ => return Err(err),
        },
    }
}
Err(rustix::io::Errno::NOSYS)
```

`ENOSYS` is latched in a `static AtomicBool` so later calls skip the probe;
`EPERM` is treated as "unimplemented" for this call only because "`EPERM` may
also indicate a failed `O_NOATIME` or a file seal prevented the operation, and
it's complex to detect those cases". Whatever exhausted the loop is reported as
`ENOSYS`, and the caller (`open_impl`) then runs `manually::open`. `EXDEV` from
the kernel is mapped to `errors::escape_attempt()` — an `io::Error` of kind
`PermissionDenied` with the message "a path led outside of the filesystem"
([`fs/errors.rs`][errors-rs]). On Android the `openat2` attempt is compiled
out entirely: "the seccomp policy prevents us from even detecting whether
`openat2` is supported, so don't even try."

`stat` uses the same call with `O_PATH` and then `fstat`, short-circuiting a
single non-following normal component straight to `fstatat`
([`rustix/linux/fs/stat_impl.rs`][stat-impl]). `set_permissions` opens the
target with `O_PATH` and then `chmodat`s `/proc/self/fd/N`, because Linux's
`fchmodat` "doesn't support `AT_NOFOLLOW_SYMLINK`, so we can't trust that it
won't follow a symlink outside the sandbox" ([`rustix/linux/fs/procfs.rs`][procfs]).
That module "does a considerable amount of work to determine whether `/proc`
is mounted, with actual `procfs`, and without any additional mount points on
top of the paths we open".

### FreeBSD: `O_RESOLVE_BENEATH`, gated on a probe

[`rustix/freebsd/fs/open_impl.rs`][freebsd-open] ORs `O_RESOLVE_BENEATH` into
the flags and maps `ENOTCAPABLE` to `escape_attempt()`. It is used only if
[`check.rs`][freebsd-check] passes: "`RESOLVE_BENEATH` was introduced in
FreeBSD 13, but opening `..` within the root directory re-opened the root
directory. In FreeBSD 14, it fails as cap-std expects." The probe does
`statat(root, "..", AT_RESOLVE_BENEATH)` on `/` and accepts the primitive only
if that returns `ENOTCAPABLE`. `unlinkat`, `utimensat`, `fchmodat` and
`fstatat` all take `AT_RESOLVE_BENEATH` on this platform.

### Everywhere else: `manually::open`

[`fs/manually/open.rs`][manual-open] is the portable resolver. A `Context`
holds `base` (the current directory handle), `dirs: Vec<MaybeOwnedFile>` (every
ancestor handle opened so far), a worklist `components` (reversed so `pop`
yields the next), and bookkeeping for a trailing `/`, `.` or `..`. The loop:

```rust
while let Some(c) = ctx.components.pop() {
    match c {
        CowComponent::PrefixOrRootDir => return Err(errors::escape_attempt()),
        CowComponent::CurDir => ctx.cur_dir()?,
        CowComponent::ParentDir => ctx.parent_dir()?,
        CowComponent::Normal(one) => ctx.normal(&one, options, symlink_count)?,
    }
}
```

- **`Normal`** opens the component with `open_unchecked(base, one,
dir_options().follow(No))` — `O_NOFOLLOW`, plus `O_DIRECTORY | O_PATH` when
  more components follow (`compute_oflags` in [`rustix/fs/oflags.rs`][oflags]).
  On success the old `base` is pushed on `dirs` and the new handle becomes
  `base`. On `ELOOP` (the symlink case; `EMLINK` on FreeBSD, `EFTYPE` on
  NetBSD, per [`open_unchecked.rs`][open-unchecked]) it reads the link and
  **pushes the target's components onto the worklist** — the link is never
  passed to the kernel for resolution.
- **`ParentDir`** pops `dirs`; an empty stack is `escape_attempt()`:

  ```rust
  // We hold onto all the parent directory descriptors so that we
  // don't have to re-open anything when we encounter a `..`. This
  // way, even if the directory is concurrently moved, we don't have
  // to worry about `..` leaving the sandbox.
  match self.dirs.pop() {
      Some(dir) => { self.check_dot_access()?; self.base = dir; }
      None => return Err(errors::escape_attempt()),
  }
  ```

  Because `..` is a stack pop and not a kernel lookup, a rename of an ancestor
  mid-walk cannot make `..` land outside `start`. `check_dot_access` is an
  `faccessat(base, ".", X_OK, AT_EACCESS)` so search permission is still
  enforced even though the kernel never saw `..`.

- **`PrefixOrRootDir`** — an absolute path, whether typed or produced by a
  symlink — is refused outright.
- **Symlink depth** is a `u8` incremented in [`read_link_one.rs`][read-link-one]
  and checked against `MAX_SYMLINK_EXPANSIONS`: 40 on Unix ("On Linux, there
  is a limit of 40 symlink expansions", [`rustix/fs/mod.rs`][rustix-mod]) and
  63 on Windows ("there is a limit of 63 reparse points on any given path",
  [`windows/fs/mod.rs`][windows-mod]).
- A path ending in `.`, `..` or `/` triggers `follow_with_dot`: the final
  handle is re-opened as `open_unchecked(base, ".", options)` so an `O_PATH`
  ancestor handle becomes a real one with the caller's flags.

Under `--cfg racy_asserts` the crate cross-checks itself: `descend_to` asserts
the new handle's `/proc`-derived path `starts_with` the old one
([`fs/maybe_owned_file.rs`][maybe-owned]), and `open` asserts the result is
the same inode an unsandboxed `openat` would have produced, or that the
sandboxed error is `PermissionDenied`/`InvalidInput` ([`fs/open.rs`][open-rs]).

### Windows

[`windows/fs/open_impl.rs`][windows-open] first rejects the reserved device
stems (`CON`, `PRN`, `AUX`, `NUL`, `COM0`–`COM9`, `LPT0`–`LPT9`, the
superscript variants) as `ERROR_FILE_NOT_FOUND`, then calls the same
`manually::open`. The Windows branch of `Context::new` pre-collapses `..`
against the preceding normal component because "Windows resolves `..` before
doing filesystem lookups". Each `open_unchecked` goes through a hand-written
`CreateFileAtW` over `NtCreateFile` with a `RootDirectory` handle
([`windows/fs/create_file_at_w.rs`][create-file-at]); symlinks are detected
_after_ the open by `metadata().file_type().is_symlink()` and reported as
`ERROR_STOPPED_ON_SYMLINK` with a `SymlinkKind::{Dir,File}` tag, because
"Windows doesn't have a way to return errors like `O_NOFOLLOW`"
([`windows/fs/open_unchecked.rs`][windows-unchecked]). Directory handles are
opened without `FILE_SHARE_DELETE` "so that directories can't be renamed or
deleted underneath us, since we use paths to implement many directory
operations" ([`windows/fs/dir_utils.rs`][windows-dirutils]).

### `via_parent`

Operations whose last component must _not_ be followed — `create_dir`,
`remove_dir`, `remove_file`, `rename`, `symlink`, `hard_link`, `read_link`,
`access`, `set_times_nofollow` — share one shape ([`via_parent/mod.rs`][via-parent]):
`open_parent` runs the sandboxed `open_dir` on everything but the basename,
returns `(dir, basename)`, and the operation calls the `*_unchecked` `*at`
syscall with that pair. `split_parent` guarantees the basename "will not be
`..`, though it may be `.` or a symbolic link to anywhere (possibly including
`..` or an absolute path)" ([`via_parent/open_parent.rs`][open-parent]) — safe
because the `*at` calls it feeds do not follow the final component.

## Dimension 1 — Threat model

The adversary is whoever controls path strings and directory contents beneath
the `Dir`: a WASI guest, a user upload, a tarball. In scope: `..` climbs,
absolute paths, symlinks (relative, absolute, looping) placed inside the tree,
and — with `RESOLVE_NO_MAGICLINKS` — procfs magic links reached through a
symlink. `symlink_loop_from_rename` in [`tests/cap-basics.rs`][cap-basics]
covers a link whose target is renamed away and back. Out of scope: the host
process's own code (`std::fs` is still there), and bind mounts placed under the
`Dir` by a privileged party (nothing checks `st_dev`; see Dimension 4).

## Dimension 2 — Resolution primitive

Whole-path atomicity with `openat2` on Linux and `O_RESOLVE_BENEATH` on FreeBSD
14; **per-component** in `manually::open`, with the containment argument
resting on the handle stack rather than on any re-check. Each intermediate is
opened `O_NOFOLLOW | O_DIRECTORY | O_PATH` (Linux/FreeBSD), so a component that
is a symlink surfaces as `ELOOP` and is resolved in user space. The
`racy_asserts` build proves the two paths agree (`check_open` in
[`linux/fs/open_impl.rs`][linux-open] runs `manually::open` after every
successful `openat2` and asserts `is_same_file`).

## Dimension 3 — Symlink and `..` policy

- `..` is **allowed while it stays beneath**: `dir/../file` resolves; `../x`
  from the root is `escape_attempt()`. The README's example — "This fails,
  since `..` leads outside of `dir`" for `dir.open("../hidden.txt")`
  ([`cap-std/README.md`][std-readme]).
- Symlinks are **followed while they stay beneath**; the target's components
  are spliced into the worklist and subjected to the same rules, so a relative
  link that climbs too far fails at the `..` pop, and an absolute link fails at
  `PrefixOrRootDir`. The README: "cap-std supports symlinks as long as they
  remain within the sandbox".
- A symlink whose target leaves the root is an **error**, never a re-root.
  This is the deliberate contrast with `RESOLVE_IN_ROOT`.
- Creating a symlink to an absolute path is refused too: "This isn't strictly
  necessary to preserve the sandbox, since `open` will refuse to follow
  absolute symlinks in any case. However, it is useful to enforce this
  restriction so that a WASI program can't trick some other non-WASI program
  into following an absolute path" ([`fs/symlink.rs`][symlink-rs]).
  `read_link` likewise refuses to _return_ an absolute target, "to avoid
  leaking information about the host filesystem outside the sandbox"
  ([`fs/read_link.rs`][read-link-rs]).
- `FollowSymlinks::No` on the final component maps to `O_NOFOLLOW`; on Windows
  it is emulated by a post-open metadata check.

## Dimension 4 — Boundaries

- **Mounts:** not a boundary. No `RESOLVE_NO_XDEV`, no `st_dev` comparison
  (the only `st_dev` use in `cap-primitives` is `MetadataExt::dev()`). A bind
  mount beneath the `Dir` is traversed like any directory.
- **procfs / magic links:** `RESOLVE_NO_MAGICLINKS` on the `openat2` path. The
  manual walk gets the same property structurally — a magic link is a symlink
  to the kernel, `O_NOFOLLOW` stops on it, and `readlinkat` of
  `/proc/self/fd/N` yields an absolute path, which is then refused. The
  crate's _own_ use of `/proc/self/fd` (for `set_permissions`, `set_times`,
  `file_path`) is guarded by the procfs verification in
  [`linux/fs/procfs.rs`][procfs].
- **Windows:** reserved device names are rejected by stem; reparse points are
  detected post-open; directory handles deny `FILE_SHARE_DELETE`. Alternate
  data streams are not mentioned anywhere in the tree.

## Dimension 5 — Portability and fallback

The fallback is the primary implementation on macOS, Android, FreeBSD ≤ 13,
Linux < 5.6, Windows, and under seccomp filters that return `ENOSYS` or `EPERM`.
Detection is a live probe: Linux latches `ENOSYS` in a static; FreeBSD runs
`check_beneath_supported` once. What is lost is whole-path atomicity — the
`..` stack keeps containment across a concurrent rename, but the _identity_ of
what was opened can differ from what an atomic lookup would have produced.
The README quantifies the cost: "opening `red/green/blue` performs just 5
system calls — it opens `red`, `green`, and then `blue`, and closes the handles
for `red` and `green`."

## Dimension 6 — Failure and partiality

Errors are `std::io::Error`; sandbox violations are `PermissionDenied` with the
fixed message from [`fs/errors.rs`][errors-rs], and the crate's own tests
match on that. `EAGAIN` from `openat2` is retried at most four times and then
_silently degrades to the manual walk_ — a rename storm therefore changes
which resolver ran, not whether the call succeeded. `ENOENT` mid-walk is
returned as-is. `internal_open` promises that a requested canonical path is
"stored in the provided `&mut PathBuf`, even if the actual open fails" once
all components were processed, and cleared otherwise.

## Dimension 7 — Enumeration and deletion

`read_dir` is fd-based: `ReadDirInner::new` opens the directory through the
sandboxed `open_dir_for_reading`, wraps the fd in `rustix::fs::Dir`, and every
entry method (`open`, `metadata`, `remove_file`, `remove_dir`, `read_dir`) is
`*at` relative to that fd with `FollowSymlinks::No`
([`rustix/fs/read_dir_inner.rs`][read-dir-inner]). Entry opens go through
`open_entry_impl` — `openat2` on a single name, or `open_unchecked` +
manual symlink expansion ([`manually/open_entry.rs`][open-entry]).

`remove_dir_all` is "adapted from `remove_dir_all` in Rust's
`library/std/src/sys_common/fs.rs`" at a 2020 revision ([`rm-all`][rm-all]):
`lstat` the target, unlink if symlink, otherwise recurse over
`read_dir_nofollow` and `remove_dir` at the end. The recursion descends via
`child.inner.read_dir(FollowSymlinks::No)` — fd-relative, and each child is
classified by `child.file_type()` before descent. There is no
re-verification of the child against the entry after opening it, and no
depth or fd cap.

Two extra entry points exist for callers that already hold the handle:
`remove_open_dir(dir: fs::File)` and `remove_open_dir_all(dir)`
([`fs/remove_open_dir.rs`][rm-open]). On Unix the former is
[`remove_open_dir_by_searching`][rm-search]: read `..` through the handle,
find the child whose `is_same_file` matches, and `unlinkat` it by that name —
so deletion of a handle never needs a path. On Windows the handle must be
dropped first and a path-based `remove_dir` used; the comment is explicit
that "there doesn't seem to be a race-free way of removing opened
directories" because keeping the handle open would require granting
`FILE_SHARE_DELETE` to everyone ([`windows/fs/remove_open_dir_impl.rs`][windows-rm-open]).

## Strengths

- **The beneath/in-root choice is written down with reasons**, and the reasons
  are about the API's users (accidental `/etc/…`, consistency of absolute
  symlinks), not about the kernel.
- **`..` never reaches the kernel in the fallback** — the handle stack makes
  containment a local property, immune to ancestor renames.
- **Three platforms behind one resolver**; the Windows port reuses the same
  `Context` with two `cfg` branches (pre-collapsed `..`, post-open symlink
  detection), and the reserved-name and `FILE_SHARE_DELETE` details are
  handled in the Windows-only layer.
- **`racy_asserts`** — a self-oracle that compares sandboxed against
  unsandboxed resolution on every operation, catching resolver drift.
- **Handle-based deletion** (`remove_open_dir_by_searching`) shows how to
  unlink something you only have an fd for.

## Weaknesses

- **No mount boundary** at all — a bind mount beneath the `Dir` is invisible.
- **`EAGAIN` exhaustion degrades silently** to the non-atomic resolver.
- **`remove_dir_all` is the 2020 `std` algorithm**, predating the
  [CVE-2022-21658][rust-std] hardening of `std`'s own implementation; entries
  are not re-verified after open.
- **Windows open-directory removal is admittedly racy**, and the manual
  `..` collapse on Windows is textual (done before any lookup), matching the
  OS but diverging from the Unix stack semantics.
- **Beneath-only** means a symlink farm under the `Dir` whose links are
  absolute — common in real container roots — is unusable; that use case
  belongs to [libpathrs][pathrs].

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                                       | Trade-off                                                                                        |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `RESOLVE_BENEATH`, not `RESOLVE_IN_ROOT`              | Granular capabilities; absolute paths are bugs; absolute symlinks behave the same everywhere    | Cannot serve chroot-style trees with absolute symlinks                                           |
| `..` allowed while beneath, via a handle stack        | `dir/../x` is ordinary; the stack keeps `..` safe across renames without re-checking            | One open fd per ancestor for the walk's duration; `faccessat` per `..` to keep permission checks |
| Symlink targets spliced into the worklist             | Same rules apply to link contents as to typed input; no kernel resolution of untrusted links    | `MAX_SYMLINK_EXPANSIONS` hand-enforced; a `u8` counter                                           |
| `openat2` retried 4× on `EAGAIN`, then fall back      | Renames anywhere on the host can starve `openat2`; unbounded retry is a DoS                     | The fallback resolver runs without the caller knowing                                            |
| `ENOSYS` latched in a static; `EPERM` not latched     | Kernel support does not change at run time; seccomp `EPERM` is ambiguous with `O_NOATIME`/seals | Every call under an `EPERM`-seccomp policy pays one failed syscall                               |
| Explicit `AmbientAuthority` token                     | Every escape hatch is greppable                                                                 | Zero run-time enforcement; a `Dir` from `std::fs::File` is one `from_std_file` away              |
| Refuse to _create_ or _read_ absolute symlinks        | A WASI guest must not plant traps for host tools; do not leak host paths                        | Legitimate absolute links inside the tree are opaque to guests                                   |
| Windows directory handles without `FILE_SHARE_DELETE` | Path-based Windows operations need the directory to stay put                                    | Removing an open directory requires dropping the handle first — racy by admission                |

## Sources

- [`README.md`][readme] — CWE-22 framing, Wasmtime/WASI role, the "Why use `RESOLVE_BENEATH`?" section, the 5-syscall cost claim, comparison with `openat`/`pathrs`/`obnth`
- [`cap-std/README.md`][std-readme] — the four-line semantic contract (`../hidden.txt` fails, absolute-symlink creation fails, following one fails)
- [`cap-primitives/src/fs/manually/open.rs`][manual-open] — the component walk, `dirs` stack, `parent_dir`, `check_dot_access`, `push_symlink_destination`, Windows `..` pre-collapse
- [`cap-primitives/src/fs/manually/read_link_one.rs`][read-link-one] + [`rustix/fs/mod.rs`][rustix-mod] + [`windows/fs/mod.rs`][windows-mod] — `MAX_SYMLINK_EXPANSIONS` 40 / 63
- [`cap-primitives/src/rustix/linux/fs/open_impl.rs`][linux-open] — `openat2` flags, `EAGAIN` loop, `ENOSYS`/`EPERM` handling, Android exclusion, `EXDEV → escape_attempt`
- [`cap-primitives/src/rustix/freebsd/fs/open_impl.rs`][freebsd-open] + [`check.rs`][freebsd-check] — `O_RESOLVE_BENEATH`, the FreeBSD 13 vs 14 `..` probe
- [`cap-primitives/src/rustix/linux/fs/procfs.rs`][procfs] — procfs verification, `chmodat` via `/proc/self/fd`
- [`cap-primitives/src/windows/fs/open_impl.rs`][windows-open], [`open_unchecked.rs`][windows-unchecked], [`dir_utils.rs`][windows-dirutils], [`create_file_at_w.rs`][create-file-at], [`remove_open_dir_impl.rs`][windows-rm-open] — reserved names, post-open symlink detection, share mode, `NtCreateFile`, the admitted race
- [`cap-primitives/src/fs/via_parent/mod.rs`][via-parent] + [`open_parent.rs`][open-parent] — the parent-handle + basename shape
- [`cap-primitives/src/rustix/fs/remove_dir_all_impl.rs`][rm-all], [`remove_open_dir_by_searching.rs`][rm-search], [`read_dir_inner.rs`][read-dir-inner], [`fs/manually/open_entry.rs`][open-entry] — enumeration and deletion
- [`cap-primitives/src/fs/symlink.rs`][symlink-rs], [`read_link.rs`][read-link-rs], [`errors.rs`][errors-rs] — absolute-symlink refusal, `escape_attempt`
- [`cap-std/src/fs/dir.rs`][dir-rs] — the `AmbientAuthority`-gated constructors
- [`tests/cap-basics.rs`][cap-basics] — `symlink_loop`, `symlink_loop_from_rename`

<!-- References -->

[pathrs]: ./libpathrs.md
[securejoin]: ./filepath-securejoin.md
[rust-std]: ./rust-std.md
[repo]: https://github.com/bytecodealliance/cap-std/tree/b7acf8e8807fe3fab991884d2208b7e03d35a409
[readme]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/README.md
[std-readme]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-std/README.md
[prim-readme]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/README.md
[open-rs]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/open.rs
[manual-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/manually/open.rs
[open-entry]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/manually/open_entry.rs
[read-link-one]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/manually/read_link_one.rs
[maybe-owned]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/maybe_owned_file.rs
[errors-rs]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/errors.rs
[symlink-rs]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/symlink.rs
[read-link-rs]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/read_link.rs
[rm-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/remove_open_dir.rs
[via-parent]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/via_parent/mod.rs
[open-parent]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/via_parent/open_parent.rs
[linux-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/linux/fs/open_impl.rs
[stat-impl]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/linux/fs/stat_impl.rs
[procfs]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/linux/fs/procfs.rs
[freebsd-dir]: https://github.com/bytecodealliance/cap-std/tree/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs
[freebsd-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs/open_impl.rs
[freebsd-check]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs/check.rs
[rustix-mod]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/mod.rs
[oflags]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/oflags.rs
[open-unchecked]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/open_unchecked.rs
[rm-all]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/remove_dir_all_impl.rs
[rm-search]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/remove_open_dir_by_searching.rs
[read-dir-inner]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/read_dir_inner.rs
[windows-dir]: https://github.com/bytecodealliance/cap-std/tree/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs
[windows-mod]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/mod.rs
[windows-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/open_impl.rs
[windows-unchecked]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/open_unchecked.rs
[windows-dirutils]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/dir_utils.rs
[create-file-at]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/create_file_at_w.rs
[windows-rm-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/remove_open_dir_impl.rs
[dir-rs]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-std/src/fs/dir.rs
[cap-basics]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/tests/cap-basics.rs
