# Concepts

The vocabulary the deep-dives share. Each term is defined once here and
grounded in the subject where it is most precisely stated; the deep-dives link
back rather than redefine.

## The race

### TOCTTOU

_Time of check to time of use_: a program inspects a filesystem object by
name, decides something, then acts on the name again — and the binding of name
to object changed in between. Named and formalized by [Bishop & Dilger
(1996)][bishop], who distinguish the **check** (`access`, `stat`, `lstat`) from
the **use** (`open`, `chmod`, `unlink`) and observe that a name is not an
object. [Wei & Pu (2005)][wei] enumerate every check/use syscall pair; the
count is 224.

### Binding versus use

A path is a sequence of _bindings_ (name → inode) walked left to right. A
check establishes facts about the object at the end of one walk; a use starts
a fresh walk. Nothing ties the two walks together, which is why every fix in
this catalog is some way of walking **once** — in the kernel
([`openat2`][openat2]), or in user space one handle at a time
([component walk](#component-walk)).

### Race window

The interval between check and use. [Dean & Hu (2004)][dean-hu] tried to make
it statistically unwinnable (the [k-race](#k-race-and-hardness-amplification));
[Borisov et al. (2005)][dean-hu] and [Cai et al. (2009)][cai] showed the
attacker can stretch it arbitrarily with a [maze](#filesystem-maze), so its
length is the attacker's to choose, not the defender's.

### k-race and hardness amplification

Repeating a check/use pair `k` times and requiring every repetition to agree,
so the attacker must win `2k+1` consecutive races ([Dean & Hu][dean-hu]).
[Tsafrir et al. (2008)][tsafrir] "amplify" this by walking the path one atom
at a time so the defender's cache keeps each window tiny. Both are
**probabilistic** defenses; both were broken by making the kernel's own lookup
slow ([Cai et al.][cai]). The field's conclusion — recorded by the
[systematic review][raducu] — is that a defense must be race-_free_, not
race-_unlikely_.

### Filesystem maze

A chain of directories and symlinks, up to the kernel's symlink-expansion
limit, arranged so that resolving one path takes a long, attacker-controlled
time ([Borisov et al.][dean-hu]). Combined with `atime` polling or a name-cache
hash-collision attack ([Cai et al.][cai]) it lets an unprivileged process
single-step a victim through its race window.

## The fix

### Directory handle (`dirfd`)

An open file descriptor (or NT `HANDLE`) on a directory, used as the origin of
a relative lookup: `openat(dirfd, "name", …)`. The handle names an inode, not
a path, so a rename above it changes nothing and a symlink swap below it is
visible as a symlink. Every library in the catalog is a wrapper around one
([libpathrs][libpathrs], [cap-std][cap-std], [Go `os.Root`][go], the
[openat crates][crates], [gnulib `fts`][fts]). On Windows the same object is
`OBJECT_ATTRIBUTES.RootDirectory` ([Windows NT][windows]).

### Component walk

Resolving a relative path in user space one name at a time, each step an
`openat` relative to the previous handle with `O_NOFOLLOW | O_DIRECTORY`
(or the NT `FILE_OPEN_REPARSE_POINT` equivalent), so no step can follow a
link and every step is atomic with respect to the handle before it. It is the
fallback every library keeps for kernels without a scoped lookup
([libpathrs's `opath` resolver][libpathrs], [cap-std's `manually`
module][cap-std], [Go's `root_openat.go`][go]). The demonstration is
[`examples/component-walk.d`][ex-walk]. Two costs: `O(depth)` syscalls, and a
`..` that must be handled in user space — see [dot-dot](#dot-dot).

### Scoped lookup

A single in-kernel path resolution that refuses to leave a root:
[`openat2`][openat2] with `RESOLVE_BENEATH` or `RESOLVE_IN_ROOT` on Linux
5.6+, `O_RESOLVE_BENEATH` on [FreeBSD][bsd]. The kernel holds the locks a
component walk cannot, so a `..` can be checked against the root
_during_ the walk; when even the kernel cannot prove it (a concurrent rename),
it fails closed with `EAGAIN` rather than guessing. [Darwin][darwin]'s headers
declare `O_RESOLVE_BENEATH` siblings that no surveyed consumer uses, and
[Windows][windows] has none; in practice both offer only a _no-follow-any_ mode.

### Beneath versus no-symlinks

Two different guarantees that are easy to conflate. **Beneath** (`RESOLVE_BENEATH`,
`O_RESOLVE_BENEATH`): the result lies under the root, symlinks that stay under
it are followed. **No symlinks** (`RESOLVE_NO_SYMLINKS`, Darwin
`O_NOFOLLOW_ANY`, NT `OBJ_DONT_REPARSE`): no component may be a link at all,
which is stronger and cheaper to emulate but refuses legitimate links. The
[flag matrix][ex-flags] shows the two disagreeing on the same path. A
portable API must pick one and say which; the catalog's
[comparison][comparison] argues for _no symlinks_ as the portable floor.

### Dot-dot

`..` is the component the kernel and user space disagree about. In-kernel
scoped lookup allows a `..` that stays beneath (and detects one that does
not); a component walk cannot see whether `..` escaped without re-checking the
root, so every user-space resolver either rejects it lexically before the
first syscall ([Go][go], this catalog's [examples][ex-walk]) or tracks a
component stack and re-verifies ([cap-std][cap-std], [libpathrs][libpathrs]).
Rejecting it up front is the only choice whose behaviour is identical on
every platform.

### Magic link

A procfs symlink whose target is not a path but a kernel object:
`/proc/<pid>/fd/N`, `/proc/<pid>/root`, `/proc/self/exe`. Following one can
jump out of any root and re-open a file with different permissions — the runc
CVE-2019-5736 mechanism. Refused by `RESOLVE_NO_MAGICLINKS` (implied by
`RESOLVE_NO_SYMLINKS` and, in practice, by `RESOLVE_BENEATH`); the full
account is [procfs magic links][procfs].

### `O_PATH` handle

A Linux descriptor that references an inode without opening it for I/O —
"a location, not a file". Resolvers produce one, then re-open it through
`/proc/self/fd/N` with the real flags, which is how [libpathrs][libpathrs]
separates _where_ from _how_. The re-open is itself a path lookup through
procfs, which is why procfs must be trusted first.

### Reparse point

The NTFS generalization of a symlink: a directory or file carrying a
_reparse tag_ (symbolic link, mount point / junction, AppExecLink, cloud
placeholder…) that the object manager acts on during a parse.
`FILE_OPEN_REPARSE_POINT` opens the point itself (final component only);
`OBJ_DONT_REPARSE` refuses to parse through any. [Forshaw's
tools][forshaw] enumerate what an attacker can plant; [Windows NT][windows]
records what a defender must check.

### Mount boundary

A bind mount or a mounted filesystem placed beneath a root changes what a
path means without any symlink. `RESOLVE_NO_XDEV` refuses to cross one;
elsewhere the only check is comparing `st_dev` (or NT `FileIdInfo` volume
serial) before and after, which races.

### fd-relative deletion

Removing a tree by opening each directory relative to its parent handle,
listing it from the handle (`fdopendir`, `NtQueryDirectoryFile`) and unlinking
each entry relative to it (`unlinkat`, `FileDispositionInformationEx`) — so a
symlink planted mid-deletion is unlinked as a name, never descended. The shape
of [Rust's CVE-2022-21658 fix][rust], [CPython's `rmtree`][cpython] and
[gnulib's `fts`][fts]; demonstrated by [`examples/fd-remove-tree.d`][ex-rm].

### Trust model

[Chari, Halevi & Venema (2010)][chari] make explicit what every other design
leaves implicit: a path is only as safe as the set of users who can modify
each directory on it. Their `safe_open` tracks a per-component safe/unsafe
bit, and once a component is writable by someone other than root and the
caller, no later symlink, `..` or multiply-linked file is accepted.

## The systems, by what they are

| Term in this catalog | Meaning                                                                                                                     |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Resolver**         | The code that turns a relative path plus a root handle into a handle ([libpathrs][libpathrs], [cap-std][cap-std], [Go][go]) |
| **Binding layer**    | Exposes the syscalls without choosing a policy ([rustix][rustix], the [openat crates][crates])                              |
| **Walker**           | Enumerates a tree from handles ([gnulib `fts`][fts], [CPython `fwalk`][cpython])                                            |
| **Mechanism**        | What a kernel offers ([Linux][openat2], [BSD][bsd], [Darwin][darwin], [Windows][windows])                                   |

<!-- References -->

[bishop]: ./bishop-dilger-1996.md
[wei]: ./wei-pu-2005.md
[dean-hu]: ./dean-hu-2004-borisov-2005.md
[tsafrir]: ./tsafrir-2008.md
[cai]: ./cai-2009.md
[chari]: ./chari-2010.md
[raducu]: ./raducu-2022.md
[openat2]: ./linux-openat2.md
[procfs]: ./linux-procfs-magic-links.md
[bsd]: ./freebsd-openbsd.md
[darwin]: ./darwin.md
[windows]: ./windows-nt.md
[libpathrs]: ./libpathrs.md
[go]: ./go-os-root.md
[rust]: ./rust-std.md
[rustix]: ./rustix.md
[cap-std]: ./cap-std.md
[crates]: ./openat-crates.md
[fts]: ./gnulib-fts.md
[cpython]: ./cpython-shutil.md
[forshaw]: ./forshaw-windows-symlinks.md
[comparison]: ./comparison.md
[ex-flags]: ./examples/openat2-resolve-flags.d
[ex-walk]: ./examples/component-walk.d
[ex-rm]: ./examples/fd-remove-tree.d
