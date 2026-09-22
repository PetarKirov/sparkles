# CPython `shutil.rmtree` and the `os` `*at` layer (Python)

A standard-library deleter that picks, at import time, between an fd-relative
implementation and a path-based one — and publishes which it picked as
`rmtree.avoids_symlink_attacks`, so the safety property is a queryable fact
rather than a platform rumour.

|                           |                                                                                                                                                                                                                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**                  | runtime API (standard library)                                                                                                                                                                                                                                                       |
| **Year**                  | Python 3.3 (2012): fd-based `rmtree`, `os.fwalk`, `dir_fd=` across `os`; `dir_fd=` on `rmtree` in 3.11; iterative rewrite in 3.14                                                                                                                                                    |
| **Authors / Maintainers** | Martin von Löwis ("Main code" for the fd-based `rmtree`, per `Misc/HISTORY`); CPython core                                                                                                                                                                                           |
| **Language**              | Python (`Lib/shutil.py`, `Lib/os.py`) over C (`Modules/posixmodule.c`)                                                                                                                                                                                                               |
| **License**               | PSF-2.0                                                                                                                                                                                                                                                                              |
| **Repository**            | [`python/cpython`][cpython-tree]                                                                                                                                                                                                                                                     |
| **Platforms**             | fd-safe on POSIX hosts exposing `openat`/`fstatat`/`unlinkat`/`fdopendir`; path-based on Windows and any host lacking one of them                                                                                                                                                    |
| **Primitive**             | `lstat` → `open(name, O_RDONLY \| O_NONBLOCK, dir_fd=…)` → `fstat` + `samestat`, then `scandir(fd)` / `unlink(name, dir_fd=fd)` / `rmdir(name, dir_fd=fd)`                                                                                                                           |
| **Source read**           | [`Lib/shutil.py`][shutil-py], [`Lib/os.py`][os-py], [`Modules/posixmodule.c`][posixmodule-c], [`Lib/test/test_shutil.py`][test-shutil-py], [`Doc/library/shutil.rst`][shutil-rst], [`Doc/library/os.rst`][os-rst], [`Misc/HISTORY`][history], [`Misc/NEWS.d/3.14.0a1.rst`][news-314] |

## Overview

### What it solves

Deleting a tree from a language runtime whose users routinely run as a more
privileged principal than the tree's owner (build servers, package managers,
`tempfile.TemporaryDirectory` cleanup). The documentation states the hazard
plainly ([`Doc/library/shutil.rst`][shutil-rst]):

> On platforms that support the necessary fd-based functions a symlink attack
> resistant version of `rmtree` is used by default. On other platforms, the
> `rmtree` implementation is susceptible to a symlink attack: given proper
> timing and circumstances, attackers can manipulate symlinks on the filesystem
> to delete files they wouldn't be able to access otherwise. Applications can
> use the `rmtree.avoids_symlink_attacks` function attribute to determine which
> case applies.

The change that introduced it ([`Misc/HISTORY`][history], Python 3.3.0):

> Issue #4489: Add a shutil.rmtree that isn't susceptible to symlink attacks.
> It is used automatically on platforms supporting the necessary os.openat()
> and os.unlinkat() functions. Main code by Martin von Löwis.

### Design philosophy

Capability by presence, decided once. `os.py` builds three sets from the
`_have_functions` list that `posixmodule.c` exports, and `shutil.py` selects an
implementation with a set comparison ([`Lib/shutil.py`][shutil-py]):

```python
_use_fd_functions = ({os.open, os.stat, os.unlink, os.rmdir} <=
                     os.supports_dir_fd and
                     os.scandir in os.supports_fd and
                     os.stat in os.supports_follow_symlinks)
_rmtree_impl = _rmtree_safe_fd if _use_fd_functions else _rmtree_unsafe
…
# Allow introspection of whether or not the hardening against symlink
# attacks is supported on the current platform
rmtree.avoids_symlink_attacks = _use_fd_functions
```

The unsafe path is not hidden behind the safe one: it is a separately named
function whose comment reads "version vulnerable to race conditions", and
`_rmtree_unsafe` raises `NotImplementedError("dir_fd unavailable on this platform")`
if handed a `dir_fd` rather than silently ignoring it.

## How it works

`_rmtree_safe_fd` is an explicit-stack loop ([`Lib/shutil.py`][shutil-py]).
Each frame is `(func, dirfd, path, orig_entry)`; `func` doubles as the
error-reporting label handed to `onexc`. The core step:

```python
# Note: To guard against symlink races, we use the standard
# lstat()/open()/fstat() trick.
assert func is os.lstat
if orig_entry is None:
    orig_st = os.lstat(name, dir_fd=dirfd)
else:
    orig_st = orig_entry.stat(follow_symlinks=False)

func = os.open  # For error reporting.
topfd = os.open(name, os.O_RDONLY | os.O_NONBLOCK, dir_fd=dirfd)

func = os.path.islink  # For error reporting.
try:
    if not os.path.samestat(orig_st, os.fstat(topfd)):
        # Symlinks to directories are forbidden, see GH-46010.
        raise OSError("Cannot call rmtree on a symbolic link")
    stack.append((os.rmdir, dirfd, path, orig_entry))
finally:
    stack.append((os.close, topfd, path, orig_entry))

func = os.scandir  # For error reporting.
with os.scandir(topfd) as scandir_it:
    entries = list(scandir_it)
for entry in entries:
    fullname = os.path.join(path, entry.name)
    try:
        if entry.is_dir(follow_symlinks=False):
            # Traverse into sub-directory.
            stack.append((os.lstat, topfd, fullname, entry))
            continue
    except FileNotFoundError:
        continue
    except OSError:
        pass
    try:
        os.unlink(entry.name, dir_fd=topfd)
    except FileNotFoundError:
        continue
    except OSError as err:
        onexc(os.unlink, fullname, err)
```

`samestat` is `st_ino == st_ino and st_dev == st_dev`
([`Lib/genericpath.py`][genericpath-py]). The `rmdir` frame is pushed _under_
the `close` frame, so a directory is removed by name relative to its parent's
fd after its own fd has been closed. `fullname` exists only for messages and
the `onexc` callback; every syscall receives `entry.name` and an fd.

The C layer decides, per function, whether `dir_fd` is accepted at all
([`Modules/posixmodule.c`][posixmodule-c]): a generated block maps each
`HAVE_*AT` macro to either `dir_fd_converter` or `dir_fd_unavailable`, the
latter raising `NotImplementedError("dir_fd unavailable on this platform")`
for any value other than `None`. `os.open` shows the runtime half — the macro
may be defined while the symbol is weak-linked (macOS 10.10 availability
checks, `HAVE_OPENAT_RUNTIME`):

```c
#ifdef HAVE_OPENAT
        if (dir_fd != DEFAULT_DIR_FD) {
            if (HAVE_OPENAT_RUNTIME) {
                fd = openat(dir_fd, path->narrow, flags, mode);
            } else {
                openat_unavailable = 1;
                fd = -1;
            }
        } else
#endif /* HAVE_OPENAT */
            fd = open(path->narrow, flags, mode);
```

The `have_functions[]` table pairs each `"HAVE_OPENAT"`-style string with a
`probe_openat` function, so `os.supports_dir_fd` reflects the running kernel
and libc, not just the build ([`Lib/os.py`][os-py] `_add("HAVE_OPENAT", "open")`,
`_add("HAVE_UNLINKAT", "rmdir")`, `_add("HAVE_FDOPENDIR", "scandir")`).

### Dimension 1 — Threat model

The symlink race on a directory component: between the walker deciding "this
is a directory" and descending into it, the entry is replaced by a symlink to
somewhere the caller can delete but the attacker cannot. The adversary is a
local user with write access somewhere inside the tree; the victim is a more
privileged process calling `rmtree`. Also handled: the root argument being a
symlink (refused up front, "see bug #1669" / "GH-46010"); entries vanishing
mid-walk (`FileNotFoundError` is swallowed at every step); Windows junctions
(`_rmtree_islink` treats `IO_REPARSE_TAG_MOUNT_POINT` as a link, and since 3.8
"will no longer delete the contents of a directory junction before removing
the junction"). Not modelled: bind mounts, hard links, mount crossing,
procfs, or a parent renamed above the walker.

### Dimension 2 — Resolution primitive

`openat(dirfd, name, O_RDONLY | O_NONBLOCK)` one component at a time, then
`fstat` on the result compared with the prior `lstat`. Atomicity claimed: per
component, with the identity check closing the window between the type
decision and the open. `O_NOFOLLOW` and `O_DIRECTORY` are **not** passed; the
`samestat` comparison is the only defence, and it also serves as the
"is this still the same directory" check. `O_NONBLOCK` guards against a FIFO
swapped in at the name.

### Dimension 3 — Symlink and `..` policy

Symlinks are never followed: the root is `lstat`ed and refused if it is a
link, children are classified with `entry.is_dir(follow_symlinks=False)`, and
anything that is not a directory is `unlink`ed by name. `..` does not arise:
names come from `scandir(fd)` (which never yields `.`/`..`), and ascent is a
stack pop, not a path operation. `os.fwalk` — the read-only sibling —
uses the identical "lstat()/open()/fstat() trick" with `follow_symlinks=False`
as its default, and the docs note that default is deliberately the opposite of
the rest of `os` ([`Doc/library/os.rst`][os-rst]).

### Dimension 4 — Boundaries

Does not apply, because nothing in `rmtree` looks at `st_dev` except through
`samestat`; there is no one-file-system option, no procfs awareness, and no
Windows reparse-tag handling beyond the junction check in `_rmtree_islink`
(which exists only on builds where `os.stat_result` has `st_file_attributes`).
The absence is a finding: a bind mount placed inside the tree is descended and
emptied.

### Dimension 5 — Portability and fallback

Fallback is the whole design. On Windows `nt._have_functions` carries
`MS_WINDOWS` for `chmod`/`stat` only, so none of `open`, `unlink`, `rmdir` are
in `supports_dir_fd`, `_use_fd_functions` is false, and `_rmtree_unsafe` runs:
an `os.walk(path, topdown=False, followlinks=os._walk_symlinks_as_files)` over
joined paths, `rmdir`/`unlink` by full name, `FileNotFoundError` swallowed.
The `_walk_symlinks_as_files` sentinel makes `walk` classify symlinks and
junctions as files (`entry.is_dir(follow_symlinks=False) and not entry.is_junction()`),
so the unsafe path at least does not _recurse_ through a link — it just cannot
prove the directory it opens is the one it classified. The test suite pins the
selection logic by re-deriving it ([`Lib/test/test_shutil.py`][test-shutil-py]
`test_rmtree_uses_safe_fd_version_if_available`): when the sets say fd-capable,
`avoids_symlink_attacks` must be true and monkey-patching `os.open` to raise
must abort the delete; otherwise it must be false. `test_rmtree_with_dir_fd`
and `test_rmtree_with_dir_fd_unsupported` cover both branches of the `dir_fd`
argument, and passing `dir_fd='invalid'` must raise `TypeError` on the safe
path but `NotImplementedError` on the unsafe one.

### Dimension 6 — Failure and partiality

Every failing syscall is routed to `onexc(func, path, exc)` (3.12+; `onerror`
with an `exc_info` triple is the deprecated form; `ignore_errors=True` installs
a no-op). Deletion continues past a failed `unlink`; a failed `open` or
`scandir` of a subdirectory skips that subtree and its `rmdir` frame is never
pushed, so the parent's `rmdir` later fails with `ENOTEMPTY` and is reported
too. The `finally` in `_rmtree_safe_fd` closes every fd still on the stack
(`test_rmtree_fails_on_close` asserts each fd is closed exactly once and that
`os.close` failures reach `onexc`). No rollback is attempted; a partial delete
is the documented outcome. The 3.14 rewrite to an explicit stack fixed
`RecursionError` on deep trees for the fd version
([`Misc/NEWS.d/3.14.0a1.rst`][news-314], gh-89727: "A recursion error is no
longer raised when `rmtree.avoids_symlink_attacks` is false" — i.e. the unsafe
path was already iterative via `os.walk`).

### Dimension 7 — Enumeration and deletion

Enumeration is `scandir(fd)` (`fdopendir` underneath), materialised with
`list()` before any deletion so the directory is not modified while its `DIR*`
is being read. Directory entries use the cached `entry.stat(follow_symlinks=False)`
as the `orig_st` for the next level's identity check — one `lstat` saved per
directory. fd usage is O(depth): each open directory holds its fd until its
`close` frame is popped, and `os.fwalk` documents the same ("This uses O(depth
of the directory tree) file descriptors … see issue #13734"). `rmtree` accepts
`dir_fd=` since 3.11 so the root itself can be named relative to a held
directory; the whole run is `sys.audit("shutil.rmtree", path, dir_fd)`ed.

## Strengths

- **The safety property is introspectable** (`rmtree.avoids_symlink_attacks`)
  and tested from both sides.
- **Capability detection is per function and at runtime** (`probe_*`, weak
  symbols on macOS), not a single build-time switch.
- **Names, never paths, reach the kernel** on the safe path; the joined
  `fullname` is purely diagnostic.
- Iterative with bounded fds; fds are closed on every exit path.
- Cached `DirEntry` stat feeds the identity check for free.

## Weaknesses

- **No `O_NOFOLLOW`/`O_DIRECTORY`**: the open itself will follow a symlink;
  correctness rests entirely on `samestat` after the fact, and a symlink to
  the _same_ directory (a hard-link-like alias) passes it.
- **No mount awareness at all** — contrast [`gnulib-fts.md`][fts]'s `FTS_XDEV`
  and [`linux-openat2.md`][openat2]'s `RESOLVE_NO_XDEV`.
- **Windows gets the unsafe implementation unconditionally**; the "junction
  as file" rule is a classification fix, not a race fix ([`windows-nt.md`][windows]).
- The `onexc` contract reports the joined path, which is exactly the string
  the safe path never trusted.
- `_use_fd_functions` is computed once at import; a seccomp policy that later
  denies `openat` produces `PermissionError`s, not a fallback.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                  | Trade-off                                                                                 |
| --------------------------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Two named implementations selected by set inclusion             | Keep the safe path pure `*at`; make the choice auditable                   | Two code paths to maintain; the unsafe one is still shipped and still the Windows default |
| Publish `avoids_symlink_attacks`                                | Let callers refuse to run privileged deletes on an unsafe platform         | An attribute on a function is easy to overlook                                            |
| `lstat` → `open` → `fstat` + `samestat` instead of `O_NOFOLLOW` | Portable to any host with `openat`; no dependence on flag semantics        | The open follows the link before the check catches it                                     |
| `scandir(fd)` materialised to a list                            | Never `unlink` while iterating the directory stream                        | O(entries) memory per directory                                                           |
| `func` rebinding as the error label                             | `onexc` learns which syscall failed without a second bookkeeping structure | Reads oddly; the label is the trick's only documentation                                  |
| Explicit stack (3.14)                                           | Deep trees must not hit the recursion limit                                | Frames carry four fields and the `close`/`rmdir` ordering is by push order                |
| `FileNotFoundError` swallowed everywhere                        | Concurrent deletion by another process is not an error                     | A race that _replaces_ rather than removes is indistinguishable from success on the entry |
| `dir_fd=` on `rmtree` (3.11)                                    | The root can be named relative to a held handle like everything below it   | `NotImplementedError` at call time on the unsafe path                                     |

## Sources

- [`Lib/shutil.py`][shutil-py] — `_rmtree_islink`, `_rmtree_unsafe`, `_rmtree_safe_fd`, `_rmtree_safe_fd_step`, `_use_fd_functions`, `rmtree`, `rmtree.avoids_symlink_attacks`
- [`Lib/os.py`][os-py] — `_have_functions` → `supports_dir_fd` / `supports_fd` / `supports_follow_symlinks`; `_walk_symlinks_as_files`; `fwalk` and `_fwalk`
- [`Lib/genericpath.py`][genericpath-py] — `samestat`
- [`Modules/posixmodule.c`][posixmodule-c] — `dir_fd_converter`, `dir_fd_unavailable`, `argument_unavailable_error`, the generated `*_DIR_FD_CONVERTER` block, `HAVE_*_RUNTIME`, `PROBE`/`have_functions[]`, `os.open`'s `openat` branch
- [`Lib/test/test_shutil.py`][test-shutil-py] — `test_rmtree_uses_safe_fd_version_if_available`, `test_rmtree_fails_on_close`, `test_rmtree_with_dir_fd`, `test_rmtree_with_dir_fd_unsupported`
- [`Doc/library/shutil.rst`][shutil-rst] — the security note, `versionchanged` 3.3/3.8/3.11/3.12, `rmtree.avoids_symlink_attacks`
- [`Doc/library/os.rst`][os-rst] — the `dir_fd` / `follow_symlinks` / fd-as-path contract; `fwalk`
- [`Misc/HISTORY`][history] — Issue #4489 entry (3.3.0)
- [`Misc/NEWS.d/3.14.0a1.rst`][news-314] — gh-89727 `RecursionError` entry

> [!NOTE]
> **Unverified.** The brief mentioned a test named after `symlink_attack`;
> no such identifier exists in `Lib/test/test_shutil.py` at the pinned SHA —
> the property is pinned by `test_rmtree_uses_safe_fd_version_if_available`
> and the `skipUnless(shutil.rmtree.avoids_symlink_attacks, …)` guards
> instead. The bug numbers cited in code comments (`#1669`, `GH-46010`,
> `#13734`) were not fetched; they are quoted as they appear in the source.

<!-- References -->

[fts]: ./gnulib-fts.md
[openat2]: ./linux-openat2.md
[windows]: ./windows-nt.md
[cpython-tree]: https://github.com/python/cpython/tree/df34a2f7122dcc6d230493b138e301675a290c49
[shutil-py]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Lib/shutil.py
[os-py]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Lib/os.py
[genericpath-py]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Lib/genericpath.py
[posixmodule-c]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Modules/posixmodule.c
[test-shutil-py]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Lib/test/test_shutil.py
[shutil-rst]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Doc/library/shutil.rst
[os-rst]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Doc/library/os.rst
[history]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Misc/HISTORY
[news-314]: https://github.com/python/cpython/blob/df34a2f7122dcc6d230493b138e301675a290c49/Misc/NEWS.d/3.14.0a1.rst
