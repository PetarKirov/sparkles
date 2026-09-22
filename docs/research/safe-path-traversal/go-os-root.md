# Go `os.Root`

The standard-library answer to path traversal, shipped in Go 1.24 (February
2025): a directory handle whose methods refuse to leave it — built on plain
`openat` + `O_NOFOLLOW` + `readlinkat`, not on `openat2`, and deliberately
called "traversal-resistant" rather than a sandbox.

|                           |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | runtime API (standard library)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Year**                  | proposed 2024-04-23, accepted 2024-11-06, shipped Go 1.24 (2025-02); completed in Go 1.25                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **Authors / Maintainers** | Damien Neil (`neild`), with review by Russ Cox, Austin Clements, Ian Lance Taylor; Aleksa Sarai (`cyphar`) as the principal dissenting voice                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Language**              | Go                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **License**               | BSD-3-Clause                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Repository**            | [`golang/go`][go-repo], `src/os/root*.go`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **Platforms**             | Unix (all Go ports), Windows, WASI preview 1; degraded on `GOOS=js` and Plan 9                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Primitive**             | per-component `openat(dirfd, name, O_NOFOLLOW\|O_CLOEXEC)` with user-space symlink re-resolution and restart-from-root on `..`                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Source read**           | [`src/os/root.go`][root-go], [`root_openat.go`][root-openat], [`root_unix.go`][root-unix], [`root_windows.go`][root-windows], [`root_js.go`][root-js], [`root_plan9.go`][root-plan9], [`root_noopenat.go`][root-noopenat], [`removeall_at.go`][removeall-at], [`root_test.go`][root-test], [`root_unix_test.go`][root-unix-test], [`root_windows_test.go`][root-windows-test], [`internal/syscall/windows/at_windows.go`][at-windows], [`internal/syscall/unix/nofollow_posix.go`][nofollow-posix]; the proposal thread [golang/go#67002][issue]; the Go blog post [Traversal-resistant file APIs][blog] |

## Overview

### What it solves

The proposal opens with the threat it is answering ([#67002][issue], opening
post):

> Directory traversal vulnerabilities are a common class of vulnerability, in
> which an attacker tricks a program into opening a file that it did not
> intend. These attacks often take the form of providing a relative pathname
> such as `"../../../etc/passwd"`, which results in access outside an intended
> location. […] A related, but less commonly exploited, class of vulnerability
> involves unintended symlink traversal, in which an attacker creates a
> symbolic link in the filesystem and manipulates the target into following it.

Go already had lexical defences — `filepath.IsLocal` (Go 1.20) and
`filepath.Localize` (Go 1.23) — and the blog post is explicit that they are
not enough once the adversary controls part of the filesystem: "If the program
defends against symlink traversal by first verifying that the intended file
does not contain any symlinks, it may still be vulnerable to
time-of-check/time-of-use (TOCTOU) races" ([blog][blog]). The canonical
consumer is named directly: "An unarchiving utility that extracts a tar or
zip file may be induced to extract a symbolic link and then extract a file
name that traverses that link."

### Design philosophy

Three decisions define the subject, all argued out on the thread.

**Scope is symlinks and `..`, not privilege boundaries.** When `cyphar` asked
whether the API would cover bind mounts, `/proc` magic links and device files
as container runtimes need, Neil drew the line at what an unprivileged
attacker can create ([#67002, 2024-08-12][c-scope]):

> Symbolic links differ from these other constructs in that creating a symlink
> is generally not a privileged operation. Anyone can make a link pointing to
> /etc, or /sbin, or any other location. To the best of my knowledge, creating
> a bind mount, mounting a procfs filesystem, or creating a device special file
> requires root permissions on Unix systems. The functions in this proposal are
> not trying to defend against an attacker who already has root access.

The resulting doc comment carries that boundary verbatim: "Methods on Root do
not prohibit traversal of filesystem boundaries, Linux bind mounts, /proc
special files, or access to Unix device files" ([`root.go`][root-go]). The
same comment thread also rejected the word "secure": "there is no such thing
as a 'secure path' in the sense of a path which does not escape a directory
root. A join operation that resolves symlinks is fundamentally vulnerable to
TOCTOU races" — which is why the blog post's title says
_traversal-resistant_.

**Paths mean what the platform says they mean.** Neil refused to lexically
clean input, because on Unix `a/../b` is not `b` when `a` is a symlink
([#67002, 2024-09-06][c-design]): "Methods of os.Root should interpret paths
in exactly the same way as the local platform does." Sarai confirmed the
trap from the other side — "Doing a `filepath.Clean` at any point where the
path may contain symlink components will result in incorrect behaviour. I
spent a few months fixing this exact bug in several Go projects." — and
`~40% of symlinks on modern Unix systems contain ".." components`. Windows,
which cleans paths itself before every open, gets the opposite treatment and
`Root` follows it (see Dimension 3).

**One type holds the policy.** Neil's first draft was a family of `OpenIn`
functions, `File.OpenIn` methods and an `O_NOFOLLOW_ANY` flag. Cox cut it
down ([#67002, 2024-07-24][c-rsc-dir]): "The motivation is to put all the
'safety' stuff on one type instead of intermixing it with 'non-safety'
stuff. […] Want two different kinds of restrictions? Configure two Dir
structs." The name went `Dir` → `Root` (2024-07-31) with `OpenInRoot(dir,
name)` as the one convenience function; `O_NOFOLLOW_ANY` was dropped, and
`Root.Truncate` was accepted but never implemented
([#67002, 2025-03-20][c-truncate]).

## How it works

`Root` wraps an `fd` (or a `HANDLE`) plus a refcount, so `Close` can race with
in-flight operations ([`root_openat.go`][root-openat]):

```go
type root struct {
    name string
    // refs is incremented while an operation is using fd.
    // closed is set when Close is called.
    // fd is closed when closed is true and refs is 0.
    mu     sync.Mutex
    fd     sysfdType
    refs   int  // number of active operations
    closed bool // set when closed
}
```

Every method is a call to one generic walker, `doInRoot`, which "calls f with
the FD or handle for the directory containing the last path element, and the
name of the last path element" ([`root_openat.go`][root-openat]). The walk:

1. `splitPathInRoot` splits the name; an absolute path (leading separator)
   is `errPathEscapes` up front; `.` components are dropped except at the
   end; trailing separators are remembered as `suffixSep` so `link/` and
   `link` differ ([`root.go`][root-go]).
2. Each intermediate component is opened with
   `openat(dirfd, part, O_NOFOLLOW|O_CLOEXEC|O_DIRECTORY)`
   (`rootOpenDir`, [`root_unix.go`][root-unix]); the previous `dirfd` is
   closed as soon as the next one opens.
3. If that open fails with the platform's `O_NOFOLLOW` errno (`ELOOP`;
   `EMLINK` on FreeBSD/DragonFly; `EFTYPE` on NetBSD —
   [`nofollow_posix.go`][nofollow-posix] and siblings) or `ENOTDIR`,
   `checkSymlink` runs `readlinkat` on the same `(dirfd, name)` pair and
   returns the link text as the sentinel error `errSymlink`.
4. The walker splices the link text into the component list at position `i`
   (`splitPathInRoot(link, parts[:i], parts[i+1:])`), bumps a counter capped
   at `rootMaxSymlinks = 8` ("`__POSIX_SYMLOOP_MAX`", [`root.go`][root-go]),
   and continues from the same `dirfd` — unless the prefix changed, in which
   case it restarts from the root fd.
5. A `..` component is never opened. Instead the walker deletes it and the
   component before it, resets `dirfd` to the root, and starts over
   ([`root_openat.go`][root-openat]):

```go
// When resolving .. path components, we restart path resolution from the root.
// (We can't openat(dir, "..") to move up to the parent directory,
// because dir may have moved since we opened it.)
// To limit how many opens a malicious path can cause us to perform, we set
// a limit on the total number of path steps and the total number of restarts
// caused by .. components. If *both* limits are exceeded, we halt the operation.
const maxSteps = 255
const maxRestarts = 8
```

`count > i` — more `..` than components before them — is `errPathEscapes`;
exceeding both caps is `ENAMETOOLONG`.

6. The last component goes to the caller's `f`, which for `OpenFile` is
   `openat(parent, name, O_NOFOLLOW|O_CLOEXEC|flag, perm)` with the same
   `errSymlink` handling — except that with `O_CREATE|O_EXCL` a symlink is
   never followed "no matter what error the OS returns"
   ([`root_unix.go`][root-unix]). So `f` "can result in f being called
   multiple times with different names".

The `rootTestCases` table in [`root_test.go`][root-test] is the attack
catalogue every method runs against: `symlink dotdot slash`, `symlink chain`
(six hops through `..`), `dotdot after symlink`, `dotdot before symlink`,
`symlink cycle`, `path escapes`, `long path escapes`, `absolute symlink`,
`relative symlink`, `symlink chain escapes`; plus `TestRootRaceRenameDir`,
`TestRootSymlinkToRoot` (`d/d => ..` lands on the root itself and is allowed),
`TestRootConcurrentClose`, and a `TestRootConsistency*` family asserting each
method returns what its top-level `os` twin does.

### Dimension 1 — Threat model

In scope, per Neil's three-class statement ([#67002, 2024-10-04][c-three]):
"1. Path name traversal […] 2. Static symlink traversal […] an attacker might
provide a tar archive containing a symlink […] 3. Dynamic attacks, where an
attacker is actively modifying the filesystem to exploit TOCTOU races." The two
races named are a component swapped for a symlink between check and use
(closed by `O_NOFOLLOW` per component), and a directory renamed after it was
opened so that a later `..` climbs out (closed by restart-from-root;
`TestRootRaceRenameDir` renames `base/a/a` to `base/b` mid-walk 100 times and
asserts the read is either `"public"` or an error, never the `"secret"` file
above). The adversary is an unprivileged local user or an archive author.

Out of scope, by the `root.go` doc comment: mounts, bind mounts, `/proc`
magic links, device files. Windows reserved device names _are_ in scope. Hard
links are never mentioned; a pre-existing hard link to an outside inode is
not a traversal. Sarai's `chroot`-style objection to `Root.OpenRoot` —
"**by design** `Root.OpenRoot` is creating a file descriptor that an attacker
can `rename`" ([#67002, 2024-10-16][c-openroot]) — was left as recorded
dissent and the method shipped.

### Dimension 2 — Resolution primitive

Per-component `openat` with `O_NOFOLLOW`, user-space symlink resolution,
`AT_SYMLINK_NOFOLLOW` `fstatat` for `Stat`/`Lstat`. Atomicity is claimed
per component only: each `openat` cannot follow a link, and the fd it returns
pins the directory it found. **There is no `openat2` fast path at the pinned
SHA.** `grep -rn Openat2 src/os src/internal/syscall/unix` finds nothing; the
only `openat2` in the tree is the syscall-number constant `openat2Trap = 437`
in `sysnum_linux_*.go` and the vendored `x/sys/unix`. Neil said in the
proposal that Linux "can use `openat2`, which does all the hard work for us"
and the 1.24 plan deferred "`RESOLVE_BENEATH` and Darwin's `O_NOFOLLOW_ANY`"
to 1.25 ([#67002, 2024-11-20][c-124-plan]); at
`015343854b5d9e2829481df30dbcae2ca6682d25` (2026-05-27, post-1.25) neither has
landed. Darwin's `O_NOFOLLOW_ANY` appears nowhere under `src/os` or
`src/internal/syscall/unix`. The one `O_NOFOLLOW_ANY` in the tree is a Go
invention for Windows (below).

Windows realizes the same shape with `NtCreateFile` and
`OBJECT_ATTRIBUTES.RootDirectory = dirfd` ([`at_windows.go`][at-windows]):
`O_NOFOLLOW_ANY` (an invented flag, `0x200000000`) sets `OBJ_DONT_REPARSE`,
`O_DIRECTORY` sets `FILE_DIRECTORY_FILE`, and `O_CREAT|O_EXCL` adds
`FILE_OPEN_REPARSE_POINT` ("don't follow symlinks"). `STATUS_REPARSE_POINT_ENCOUNTERED`
maps to `ELOOP`, which `root_windows.go`'s `openat` turns into `errSymlink`
by re-opening with `FILE_OPEN_REPARSE_POINT` and reading the reparse buffer
(`readReparseLinkAt`). WASI preview 1 shares the Unix walker (`//go:build
unix || windows || wasip1`), with `path_filestat_get` for `Fstatat`.

### Dimension 3 — Symlink and `..` policy

Symlinks are **followed** if they stay inside the root, refused otherwise;
"Symbolic links must not be absolute" ([`root.go`][root-go]) — an absolute
target hits the leading-separator check in `splitPathInRoot`. There is no
`O_NOFOLLOW_ANY` for callers, but `Root.OpenFile` accepts `syscall.O_NOFOLLOW`
for the last component. Windows treats both `IO_REPARSE_TAG_SYMLINK` and
`IO_REPARSE_TAG_MOUNT_POINT` (junctions) as links via
`isReparseTagNameSurrogate` ([`types_windows.go`][types-windows]), so a
junction pointing outside is refused just like a symlink.

`..` is resolved in user space by deleting components and restarting from the
root fd; never by `openat(dirfd, "..")`. On Unix the deletion happens at the
moment the `..` is reached, after preceding symlinks have already been
expanded, so `s/../f` with `s => a/b` opens `a/f` as the kernel would. On
Windows the whole path is cleaned first through `GetFullPathName` with a
`\\?\?\` prefix ([`root_windows.go`][root-windows]) — "on Windows the path
`a\..\b` is exactly equivalent to `b` alone, even if `a` does not exist" — and
escape is detected by checking the cleaned result still carries the prefix;
`?` is rejected in input to close the `..\?\` corner case. The
`dotdot after symlink` test encodes the divergence: `a => b/c`, open
`a/../target` → `b/target` on Unix, `target` on Windows.

Symlinks that _end_ in `/` or `.` keep their trailing separator only when they
replace the final component ("intermediate components must always be
directories").

### Dimension 4 — Boundaries

None enforced. No `st_dev` comparison, no `RESOLVE_NO_XDEV`, no `/proc`
detection; the doc comment says so. Windows: reserved device names are
rejected as a consequence of `NtCreateFile` with a `RootDirectory` not
resolving `NUL` (`TestRootWindowsDeviceNames`); case-insensitivity is preserved
via `OBJ_CASE_INSENSITIVE` (`TestRootWindowsCaseInsensitivity`); alternate
data streams are not mentioned in code or thread. Unix domain sockets in a path
are covered by consistency tests (`unix domain socket target`, `unix domain
socket in path`), i.e. they behave as `os.Open` does, not as a boundary.

### Dimension 5 — Portability and fallback

Three tiers ([#67002, 2024-09-06][c-design]): "1. Ones with openat 2. Windows 3. Everything else, which is Plan 9 (which has no symlinks), and GOOS=js
(which has no openat or equivalent)." The first two share `doInRoot`; the
third is [`root_noopenat.go`][root-noopenat], where a `Root` is a directory
_name_ plus an `atomic.Bool closed`, and every method is
`checkPathEscapes` + the ordinary `os` function on `joinPath(r.name, name)`.
`checkPathEscapes` on js ([`root_js.go`][root-js]) is a `Lstat`/`Readlink`
walk over the same component/`..`/symlink-splice logic, "subject to TOCTOU
races when symlinks change during the resolution process"; on Plan 9
([`root_plan9.go`][root-plan9]) it is just `filepathlite.IsLocal`, since
there are no symlinks. What is lost on those two ports is stated in the doc
comment: no rename tracking ("a Root references a directory name, not a file
descriptor") and, on js, no TOCTOU defence. The original proposal wanted
`ErrUnsupported` there; Neil reversed after `magical` argued it "is just
creating more work for developers for no tangible benefit", concluding "Not
supporting os.Root on some platforms will give users a reason not to use it
at all."

There is no runtime-detected fallback on Linux because there is no fast path
to fall back from. Platform quirks are absorbed per errno (AIX `ELOOP` →
`EEXIST` under `O_CREATE|O_EXCL`; DragonFly `EINVAL` in `eloop_other.go`;
`ENOTSUP` → `ENOTDIR`). On Unix, `Chmod`/`Chown`/`Chtimes` are documented as
racy: `fchmodat` cannot say "only if not a symlink", so the code
`checkSymlink`s first, and "If the target is replaced between the check and
the fchmodat, we will chmod the symlink rather than following it. This race
condition is unfortunate, but does not permit escaping a root"
([`root_unix.go`][root-unix]).

### Dimension 6 — Failure and partiality

Errors are `*PathError` with `Op` set to the `at`-syscall name (`"openat"`,
`"mkdirat"`, `"statat"`, `"removeat"`) and `Path` rewritten by `doInRoot` to
the prefix actually traversed (`parts[0..i]`), so a failure names where the
walk stopped rather than the caller's string. `errPathEscapes` is a distinct
sentinel (`"path escapes from parent"`, [`file.go`][file-go]); `ELOOP` for
more than 8 links; `ENAMETOOLONG` when both step and restart caps are hit;
`ErrClosed` if `Close` won the refcount race.

A rename mid-walk is not detected — it is made harmless: every `..` throws the
walked prefix away and re-walks from the root fd, so a component moved after
it was opened can only be re-found at its _new_ position or not at all. The
cost, acknowledged in the proposal, is that `0/1/…/9/x/../target` walks ten
components twice; Sarai's suggestion to cap restarts rather than components
became the two-cap `&&` rule. Nothing like `openat2`'s `EAGAIN`-on-rename is
surfaced to callers. `MkdirAll` handles the `mkdirat` → `EEXIST` race by
retrying the `rootOpenDir` once ("the directory may have been created by
another process or thread between the rootOpenDir and mkdirat calls",
[`root_openat.go`][root-openat]); a failed `MkdirAll` leaves whatever
directories it created.

### Dimension 7 — Enumeration and deletion

`Root.RemoveAll` and `os.RemoveAll` share `removeAllFrom(parentFd, base)`
([`removeall_at.go`][removeall-at]), which the thread promised would "fix
#52745 (except for GOOS=js)" — the Windows symlink race in `os.RemoveAll`.
Shape: `unlinkat(parent, base, 0)`; on `EISDIR`/`EPERM`/`EACCES` open the
child with the same `O_NOFOLLOW|O_DIRECTORY` `rootOpenDir` the walker uses
(an `errSymlink` here is turned back into the original unlink error, so a
symlink to a directory is unlinked, never descended), `Readdirnames(1024)` in
batches, recurse fd-relative, then `unlinkat(parent, base, AT_REMOVEDIR)`.
The directory is closed and reopened between batches because "Removing files
from the directory may have caused the OS to reshuffle it" (issue 20841).
There is no `fstat` re-verification after `openat` — the `O_NOFOLLOW` open
_is_ the verification — and no fd-depth limit beyond recursion. On Windows,
`Deleteat` is `NtOpenFile` with `FILE_OPEN_REPARSE_POINT` then
`FILE_DISPOSITION_INFORMATION_EX` with `FILE_DISPOSITION_POSIX_SEMANTICS`,
falling back to `FileDispositionInfo` where unsupported
([`at_windows.go`][at-windows]).

Enumeration has no dedicated method: `Root.FS().ReadDir` opens a `*File` and
calls `ReadDir(-1)` ("This isn't efficient […] This suffices for the moment",
[`root.go`][root-go]); `fs.WalkDir(root.FS(), …)` is the recommended walk
([#67002, 2025-05-06][c-walk]). A `*File` opened in a root sets `inRoot`, which
makes `ReadDir` `lstatat` each entry through the parent fd instead of lazily
`lstat`-ing a joined path ([`file_unix.go`][file-unix]).

## Strengths

- **Portable by construction**: one walker on every `openat` platform and
  Windows, preserving each platform's own `..`/symlink semantics.
- **The threat model is written down** — in the doc comment and on the thread —
  including what is _not_ defended; "sandbox" and "secure" were rejected on
  purpose.
- **The test table is a reusable attack corpus**, and every method is checked
  for parity with its `os` twin.
- **`..` is safe without `/proc`**: restart-from-root defeats the rename race
  that keeps `filepath-securejoin` and `libpathrs` Linux-only.
- **Handle-based**: a `Root` follows its directory across renames and ignores
  `Chdir`, unlike `os.DirFS`.

## Weaknesses

- **No `openat2`/`RESOLVE_BENEATH`, no `O_NOFOLLOW_ANY`** at the pinned SHA
  despite both being promised for 1.25 — every Linux open is N + 1 syscalls
  with user-space symlink resolution.
- **No mount, `/proc`, device or hard-link boundary** — by design.
- **`Chmod`/`Chown`/`Chtimes` are racy on Unix** (documented); no `O_PATH` +
  `/proc/self/fd` fallback.
- **`..` re-walk is O(depth × restarts)**, and the cap trips only when _both_
  limits are exceeded.
- **`GOOS=js` is silently weaker**: same API, TOCTOU-vulnerable; Sarai's
  "slightly different security semantics on different platforms is something
  that is going to bite people" went unanswered.
- **`Root.OpenRoot` on attacker-controlled subdirectories** shipped over an
  unwithdrawn objection.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                                                    | Trade-off                                                                             |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Follow in-root symlinks; refuse absolute or escaping ones | Archives and real trees contain symlinks; `RESOLVE_NO_SYMLINKS` "is not actually usable […] for most people" | User-space resolution: `readlinkat` + splice + 8-hop cap on every platform            |
| Resolve `..` by restart-from-root, never `openat("..")`   | A renamed ancestor cannot be climbed out of; needs no `/proc`                                                | Re-walks prefixes; `maxSteps=255 && maxRestarts=8` DoS bound                          |
| Platform-native path semantics (no `Clean` on Unix)       | `a/../b` ≠ `b` when `a` is a symlink; "interpret paths in exactly the same way as the local platform does"   | Unix and Windows give different answers for `dotdot after symlink`                    |
| Symlinks and `..` only; mounts, `/proc`, devices excluded | Those need root to create; "not trying to defend against an attacker who already has root access"            | Not a container-runtime primitive; `libpathrs` still needed there                     |
| One `Root` type, options on the type                      | "put all the 'safety' stuff on one type"; two policies = two `Root`s                                         | No per-call `RESOLVE_*`; `O_NOFOLLOW_ANY` and `RESOLVE_IN_ROOT` deferred indefinitely |
| Degraded but present on js/Plan 9                         | "Not supporting os.Root on some platforms will give users a reason not to use it at all"                     | Same API, weaker guarantee; documented, not enforced                                  |
| `RemoveAll` shares `removeAllFrom` with `os.RemoveAll`    | Fix #52745 once; `O_NOFOLLOW                                                                                 | O_DIRECTORY` open is the only check needed                                            | No inode re-verification; reopen-per-batch cost from issue 20841 |
| Ship 1.24 on plain `openat`, defer `openat2`              | "Linux is the only platform with openat2, so we need an openat-based implementation anyway"                  | Still deferred at the pinned SHA (2026-05); Linux pays the emulated walk              |

## Sources

- [golang/go#67002][issue] — the proposal thread: scope, naming, the `..`/`Clean` argument, the js/Plan 9 reversal, the `Root.OpenRoot` dissent, the 1.24/1.25 split
- [Traversal-resistant file APIs][blog] (Damien Neil, 2025-03-12) — public framing, `IsLocal`/`Localize` history, bind-mount and TOCTOU caveats
- [`src/os/root.go`][root-go] — the `Root` doc comment, `rootMaxSymlinks`, `splitPathInRoot`, `Root.FS`
- [`src/os/root_openat.go`][root-openat] — `doInRoot`: the walker, `..` restart, `maxSteps`/`maxRestarts`; `rootMkdirAll`, `rootRemoveAll`
- [`src/os/root_unix.go`][root-unix] — `rootOpenDir`, `checkSymlink`/`readlinkat`, the documented `chmodat` race
- [`src/os/root_windows.go`][root-windows], [`at_windows.go`][at-windows] — `rootCleanPath`, `readReparseLinkAt`; `Openat` over `NtCreateFile`, `Deleteat`
- [`src/os/root_noopenat.go`][root-noopenat], [`root_js.go`][root-js], [`root_plan9.go`][root-plan9] — the name-based tier
- [`src/os/removeall_at.go`][removeall-at] — `removeAllFrom`, shared by `os.RemoveAll` and `Root.RemoveAll`
- [`src/os/root_test.go`][root-test], [`root_unix_test.go`][root-unix-test], [`root_windows_test.go`][root-windows-test] — the attack table, `TestRootRaceRenameDir`, consistency suite, Windows tests
- [`nofollow_posix.go`][nofollow-posix] — per-OS `O_NOFOLLOW` errno table; [`api/go1.24.txt`][api-124], [`api/go1.25.txt`][api-125] — which methods landed in which release

> [!NOTE]
> **Unverified.** The Go clone is a single-commit checkout, so per-method landing
> dates come from `api/go1.2x.txt` and the thread's CL announcements rather than
> `git log -S`. The blog post was read through a summarizing fetch; the quotes
> above are the sentences it returned verbatim, and its Windows/WASI section was
> not read in full. `O_NOFOLLOW_ANY` on Darwin and `openat2` on Linux are stated
> as _absent from `src/os` at the pinned SHA_ on the strength of `grep`; a later
> commit may have added them.

<!-- References -->

[go-repo]: https://github.com/golang/go/tree/015343854b5d9e2829481df30dbcae2ca6682d25
[root-go]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root.go
[root-openat]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_openat.go
[root-unix]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_unix.go
[root-windows]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_windows.go
[root-js]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_js.go
[root-plan9]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_plan9.go
[root-noopenat]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_noopenat.go
[removeall-at]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/removeall_at.go
[root-test]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_test.go
[root-unix-test]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_unix_test.go
[root-windows-test]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_windows_test.go
[at-windows]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/syscall/windows/at_windows.go
[types-windows]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/types_windows.go
[file-go]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/file.go
[file-unix]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/file_unix.go
[nofollow-posix]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/syscall/unix/nofollow_posix.go
[api-124]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/api/go1.24.txt
[api-125]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/api/go1.25.txt
[issue]: https://github.com/golang/go/issues/67002
[c-scope]: https://github.com/golang/go/issues/67002#issuecomment-2284659595
[c-design]: https://github.com/golang/go/issues/67002#issuecomment-2332942163
[c-rsc-dir]: https://github.com/golang/go/issues/67002#issuecomment-2248341515
[c-three]: https://github.com/golang/go/issues/67002#issuecomment-2393970008
[c-openroot]: https://github.com/golang/go/issues/67002#issuecomment-2416866011
[c-124-plan]: https://github.com/golang/go/issues/67002#issuecomment-2489224813
[c-truncate]: https://github.com/golang/go/issues/67002#issuecomment-2741670199
[c-walk]: https://github.com/golang/go/issues/67002#issuecomment-2855176421
[blog]: https://go.dev/blog/osroot
