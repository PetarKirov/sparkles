# James Forshaw on Windows symbolic-link attack surface

Why "check the path, then open it" is even harder on Windows than on POSIX:
there is not one symlink but a zoo — object-manager symlinks, NTFS symlinks,
mount-point junctions, registry-key links, per-user DosDevices — an unprivileged
user can plant several of them, and an oplock turns any check-then-use into a
race the attacker wins deterministically.

|                 |                                                                                                                                                                                                                                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | Talk + tools + blog posts (attack research)                                                                                                                                                                                                                                                                             |
| **Years**       | 2015 (SyScan talk + tools) → 2016 (path-conversion guide) → 2018 (exploitation tricks); mitigations to 2025                                                                                                                                                                                                             |
| **Author**      | James Forshaw (`@tiraniddo`, Google Project Zero)                                                                                                                                                                                                                                                                       |
| **License**     | Apache-2.0 ([`symboliclink-testing-tools/LICENSE.txt`][stt-license])                                                                                                                                                                                                                                                    |
| **Repository**  | [`googleprojectzero/symboliclink-testing-tools`][stt-repo] at `00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb`                                                                                                                                                                                                                |
| **Platforms**   | Windows (NT object manager, NTFS, Win32 path layer)                                                                                                                                                                                                                                                                     |
| **Primitive**   | Attack: an unprivileged reparse point / object-manager symlink swapped under a privileged open, the race widened with an NTFS oplock. Defense: `NtCreateFile` `RootDirectory`-relative opens with `FILE_OPEN_REPARSE_POINT` / `OBJ_DONT_REPARSE`, per-component reparse-tag checks                                      |
| **Source read** | [`README.txt`][stt-readme] + each tool's source and `*_ReadMe.txt`; the [SyScan 2015 slides][syscan-pdf] (93pp.); Project Zero [2015][pz-2015] / [2016][pz-2016] / [2018][pz-2018] posts; [`NtCreateFile`][ntcreatefile] and [`OBJECT_ATTRIBUTES`][objattr] on Microsoft Learn; the [RedirectionGuard][redir] MSRC post |

## Overview

### What it solves

Nothing — this is offensive research, and its subject is a class of privileged
Windows services that build a path, check it, and re-open it. Forshaw's SyScan
2015 taxonomy is three attack shapes ([slides 6–8][syscan-pdf]): "Resource
Creation or Overwrite" (redirect a privileged write to `\sensitive\path`),
"Information Disclosure" (redirect a privileged read), and "Time of Check/Time
of Use" — a privileged application checks a symlink pointing at `\valid\file`,
then "Use Symbolic Link" now resolves to `\malicious\file`. The corpus of tools
exists to build every link type the taxonomy needs; the `README.txt`
enumerates them ([`README.txt`][stt-readme]):

> BaitAndSwitch : Creates a symbolic link and uses an OPLOCK to win a TOCTOU
> CreateDosDeviceSymlink: Creates a object manager symbolic link using csrss
> CreateMountPoint: Create an arbitrary file mount point
> CreateNtfsSymlink: Create an NTFS symbolic link
> CreateObjectDirectory: Create a new object manager directory
> CreateRegSymlink: Create a registry key symbolic link
> DeleteMountPoint: Delete a mount point
> DumpReparsePoint: Delete the reparse point data
> NativeSymlink: Create an object manager symbolic link
> SetOpLock: Tool to create oplocks on arbitrary files or directories

### Design philosophy

The load-bearing observation, from the 2016 path-conversion post
([pz-2016][pz-2016]): the Win32 layer canonicalizes a path (collapsing `..`,
trimming trailing dots and spaces, expanding `\\?\` and `\\.\` prefixes)
**before** it becomes an NT object-manager path, so "if you ever encounter an
application trying to validate a Win32 path, be very skeptical" — the string the
validator inspected and the string `CreateFile` opens are two different
canonical forms. On top of that, the object manager resolves symbolic links
during name parsing via `STATUS_REPARSE` reprocessing ([slides 15–21][syscan-pdf]),
and an unprivileged user can create most of the link types without any
privilege at all — which is exactly why the defensive primitives this catalog
cares about ([`windows-nt.md`][windows]) are `NtCreateFile` with a
`RootDirectory` handle and `FILE_OPEN_REPARSE_POINT`, checked one component at a
time.

## How it works

### The link zoo

The tools are a catalogue of Windows' redirection primitives, each built from a
different API:

- **Object-manager symlinks** (`NativeSymlink`, `CommonUtils/NativeSymlink.cpp`)
  — `NtCreateSymbolicLinkObject` creates a `\??`-namespace link. No privilege
  needed to create one in a writable object directory; but "The object manager
  symbolic links only last until all referencing handles have been closed …
  it's not possible to specify OBJ_PERMANENT … without admin privileges"
  ([`CreateSymlink_readme.txt`][stt-createsymlink]).
- **NTFS symlinks** (`CreateNtfsSymlink`, `CommonUtils/ReparsePoint.cpp`) —
  an `IO_REPARSE_TAG_SYMLINK` (`0xA000000C`) reparse buffer set via
  `FSCTL_SET_REPARSE_POINT`. Requires `SeCreateSymbolicLinkPrivilege` (the
  `0x400` context flag on slide 68–70) — normally admin-only.
- **Mount points / junctions** (`CreateMountPoint`) — an
  `IO_REPARSE_TAG_MOUNT_POINT` (`0xA0000003`) reparse buffer. Crucially **no
  privilege required**, only a writable empty directory, and the target need
  not be a directory: "it's possible to point a directory junction at a file
  and it can be opened as a file as long as the caller specifies
  FILE_FLAG_BACKUP_SEMANTICS" ([`CreateSymlink_readme.txt`][stt-createsymlink]).
- **Registry-key symlinks** (`CreateRegSymlink`,
  `CommonUtils/RegistrySymlink.cpp`) — `NtCreateKey` with
  `REG_OPTION_CREATE_LINK` and a `SymbolicLinkValue` of type `REG_LINK`.
- **Per-user DosDevices symlinks** (`CreateDosDeviceSymlink`) —
  `DefineDosDevice` with `DDD_RAW_TARGET_PATH`, which asks CSRSS to create the
  link so it survives without `SeCreatePermanentPrivilege`.

The keystone trick that makes an unprivileged **file** symlink out of the
privileged NTFS one is `FileSymlink::CreateSymlink`
(`CommonUtils/FileSymlink.cpp`): create an empty directory, junction it to
`\RPC Control` (a writable object directory), and place an object-manager
symlink named after the file _inside_ `\RPC Control`. The 2018 slides call this
"Let Our Powers Combine" ([syscan slides 86–88][syscan-pdf]): a file open of
`\??\C:\temp\mylink\file` reparses through the mount point into `\RPC Control`,
then through the object-manager symlink to `\??\C:\hello.txt`. No privilege at
any step.

### Winning the race: oplocks

`SetOpLock` and `BaitAndSwitch` widen the check-to-use window to arbitrary
length. `FileOpLock::BeginLock` (`CommonUtils/FileOpLock.cpp`) requests
`FSCTL_REQUEST_OPLOCK` with `OPLOCK_LEVEL_CACHE_READ | OPLOCK_LEVEL_CACHE_HANDLE`;
when a victim opens the file, the kernel signals the oplock, the callback fires
(swapping the symlink), and only then is the oplock released so the victim's
open proceeds — against the new target. The `BaitAndSwitch` main loop is the
whole attack in fifteen lines: `sl->CreateSymlink(link, target1)`, then
`FileOpLock::CreateLock(target1, share_mode, SwitchSymlink)` where
`SwitchSymlink` calls `sl->ChangeSymlink(target2)`
(`BaitAndSwitch/BaitAndSwitch.cpp`). The SyScan Task-Scheduler exploit
(slides 53–62) is the canonical target: the service hashes
`C:\Dummy\MyTask`, an oplock fires, the user re-points the `MyTaskFolder`
junction from `C:\dummy` to `C:\windows`, releases the oplock, and the service
"Rewrite Task File" now writes to `C:\Windows\MyTask`.

The `*_ReadMe.txt` files record the oplock's precise limits — the same ones a
defender can lean on ([`SetOpLock_ReadMe.txt`][stt-setoplock]):

> OpLocks only work on file streams … FILE_APPEND_DATA will trigger a write
> request, however READ_CONTROL or WRITE_DACL will not trigger the oplock … In
> certain circumstances it might be possible to oplock on higher directories
> (querying a directory for it's contents is a read request) especially if code
> is using something like GetLongPathName API.

### The defensive primitives

Two flags close specific holes. `FILE_OPEN_REPARSE_POINT` on `NtCreateFile`
opens the reparse point itself rather than following it — the docs are explicit
([`NtCreateFile`][ntcreatefile]):

> If … the FILE*OPEN_REPARSE_POINT flag is specified, normal reparse processing
> does \_not* occur and NtCreateFile attempts to directly open the reparse point
> file. In either case, if the open operation was successful, NtCreateFile
> returns STATUS_SUCCESS … NtCreateFile never returns STATUS_REPARSE.

`OBJ_DONT_REPARSE` in `OBJECT_ATTRIBUTES.Attributes` is the stronger, all-or-
nothing form ([`OBJECT_ATTRIBUTES`][objattr]):

> If this flag is set, no reparse points will be followed when parsing the name
> of the associated object. If any reparses are encountered the attempt will
> fail and return an STATUS_REPARSE_POINT_ENCOUNTERED result. This can be used
> to determine if there are any reparse points in the object's path, in
> security scenarios.

The tools already use the checking form themselves: `OpenReparsePoint`
(`CommonUtils/ReparsePoint.cpp`) opens with
`FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT` and then inspects the
tag via `FSCTL_GET_REPARSE_POINT`, which is exactly the per-component check a
defender performs — read the tag, refuse a `MOUNT_POINT` or `SYMLINK` you did
not expect.

### Dimension 1 — Threat model

An unprivileged local user racing a more-privileged service (SYSTEM, or a
higher-integrity broker) that opens a path in a location the user can write.
The adversary's toolkit is precisely the tool list: a mount-point junction (no
privilege), an object-manager symlink (no privilege, in a writable object
directory), a `\RPC Control`-based file symlink combining the two, a registry
link, a DosDevices link — any of them swappable mid-open via an oplock. The
2018 post generalises the payoff beyond redirection: an arbitrary file _write_
becomes privilege escalation through a hardlink whose inherited ACEs are
re-applied by a service ([pz-2018][pz-2018]): "Create a hard link to a target
file in SYSTEM32 that we want to overwrite" — a hardlink needs no write access
to the target, only to its own name.

### Dimension 2 — Resolution primitive

There is no scoped-lookup syscall as on Linux; the object manager resolves the
whole path with `STATUS_REPARSE` reprocessing at each link, so the atomicity is
**none across the path** and the check must be imposed by the caller. The
defensive primitive is `NtCreateFile` with a `RootDirectory` handle
(`OBJECT_ATTRIBUTES.RootDirectory`, "an object name relative to the
RootDirectory directory", [`OBJECT_ATTRIBUTES`][objattr]) — the Windows
`openat` — plus `FILE_OPEN_REPARSE_POINT` so each component is opened without
following, its reparse tag examined, and the next component opened relative to
the returned handle. `OBJ_DONT_REPARSE` collapses that to a single "fail if any
reparse anywhere" call, at the cost of also refusing legitimate reparse points.

### Dimension 3 — Symlink and `..` policy

Symlinks here are the whole subject and are refused per component, not followed:
a defender opens with `FILE_OPEN_REPARSE_POINT` and rejects any component whose
`FSCTL_GET_REPARSE_POINT` tag is `IO_REPARSE_TAG_MOUNT_POINT` or
`IO_REPARSE_TAG_SYMLINK` (the tag constants are in
`CommonUtils/ReparsePoint.cpp`). `..` is a Win32-layer concern, not a lookup
one: `RtlDosPathNameToRelativeNtPathName_U` "Resolves parent directory (`..`)
references" during canonicalization ([pz-2016][pz-2016]), and the escape is
that a validator sees the collapsed form while `\\?\` paths reach the object
manager with "relative path components (`..`) unexpanded". The 2015 Flash-broker
bug (slides 34–40) is exactly this: `IsSafePath` canonicalized
`\\?\GLOBALROOT\RPC Control\../../C:/valid/path` to `C:\valid\path`, but
`CreateFile` saw an object-directory reparse followed by a symlink.

### Dimension 4 — Boundaries

Not mounts and `st_dev` but Windows' own boundary vocabulary:

- **Reparse tags** are the classification a defender keys on; the constant list
  (`IO_REPARSE_TAG_MOUNT_POINT`, `IO_REPARSE_TAG_SYMLINK`, and a dozen others)
  is in `CommonUtils/ReparsePoint.cpp`. `IopParseDevice` already restricts a
  mount point's target device type ("FILE_DEVICE_DISK, FILE_DEVICE_CD_ROM …
  Limited Device Subset", slide 52).
- **Device names / DosDevices** — the `\\.\` and `\\?\` prefixes escape into
  `\??\` DosDevices, and `\\.\GLOBALROOT\...` re-roots at the object-manager
  root through an empty symlink ([slides 29–33][syscan-pdf]).
- **Reserved DOS names** — `X:\COM1.blah` is reinterpreted as `\??\COM1`
  because "The conversion process actively tries to convert any path with the
  device name last" ([pz-2016][pz-2016]), so a filename check can open a device.
- **Alternate data streams** — the `$INDEX_ALLOCATION` stream "will bypass
  initial directory failure" (slide 85), opening a file as if it were a
  directory.

### Dimension 5 — Portability and fallback

Windows-specific throughout; nothing transfers to POSIX. The relevant "fallback"
is the platform's own version skew: a defender that wants the strongest guard
probes for `OBJ_DONT_REPARSE` and downgrades to per-component
`FILE_OPEN_REPARSE_POINT` checks where it is unavailable ([`windows-nt.md`][windows]).
On the mitigation side, Microsoft's answers arrived late and piecemeal:
the Windows 10 (2015) symlink mitigations gated _creation_ on a sandbox check
via `RtlIsSandboxToken` ([pz-2015][pz-2015]) — registry links blocked outright
from sandboxes (CVE-2015-2429), object-manager links marked with their creator's
sandbox status (CVE-2015-2428), mount-point creation requiring write access to
the target (CVE-2015-2430) — and 2025's RedirectionGuard finally addresses
_traversal_: "Junction traversal is only blocked when … a process that has
opted in … AND The junction was created by a non-admin user account", opt-in via
`SetProcessMitigationPolicy` with `ProcessRedirectionTrustPolicy`
([redir][redir]). RedirectionGuard "explicitly excludes hard links, object
manager symlinks, and symbolic links" — so the `\RPC Control` object-manager
trick and the hardlink-ACE trick are out of its scope.

### Dimension 6 — Failure and partiality

The distinguishing status codes are what make per-component checking possible:
`FILE_OPEN_REPARSE_POINT` guarantees `NtCreateFile` "never returns
STATUS_REPARSE" ([ntcreatefile][ntcreatefile]) — a successful open is a genuine
open of the reparse point, not a silently-followed link — and
`OBJ_DONT_REPARSE` returns `STATUS_REPARSE_POINT_ENCOUNTERED` the instant any
reparse is met, which the docs explicitly bless "in security scenarios"
([objattr][objattr]). The attacker's corresponding lever is
`FILE_OPEN_REQUIRING_OPLOCK` / `FILE_COMPLETE_IF_OPLOCKED` and the oplock
FSCTLs, whose one-shot nature is the defender's only mid-race signal: "One-shot,
need to be quick to reestablish if opened multiple times"
([`BaitAndSwitch_ReadMe.txt`][stt-bait]).

### Dimension 7 — Enumeration and deletion

Not the tools' subject, but the same principle appears from the attacker's
side: `BaitAndSwitch`'s notes warn that "calls to FindFirstFile on the object
directory … will fail" and that `GetLongPathName` triggers a `FindFirstFile`
that a defender's directory read can be oplocked on — i.e. even _enumerating_
a directory to validate it is a use that can be raced. A safe Windows tree walk
or delete must therefore open each directory `RootDirectory`-relative with
`FILE_OPEN_REPARSE_POINT`, verify the tag, and enumerate from the handle, the
NT analogue of the POSIX `fd`-relative `readdir` the rest of the catalog
converges on ([`comparison.md`][comparison]).

## Strengths

- **Every primitive is a runnable tool**, so the threat model is not folklore:
  the exact API call that builds each link type is in the repository at a pinned
  SHA.
- The `*_ReadMe.txt` files double as a defender's cheat sheet — the oplock
  limitations (which access rights trigger it, the one-shot behaviour, the
  8.3-name `FindFirstFile` avoidance) are stated precisely.
- The 2016 path-conversion post is the definitive account of the Win32↔NT
  canonicalization gap that makes string validation unsafe.
- The mitigations timeline (2015 creation-gating → 2025 traversal-gating) shows
  which holes are closed by default and which still require opt-in.

## Weaknesses

- **All Windows.** None of the mechanics port to a POSIX `dir_handle`; the value
  is the _shape_ of the check (per-component, tag-verified, handle-relative).
- The tools target Windows 7/8-era behaviour; several holes (registry links,
  mount-point creation) were narrowed by later mitigations the tools predate.
- RedirectionGuard, the strongest current answer, is opt-in and covers only
  junctions — object-manager symlinks, NTFS symlinks and hard links remain the
  caller's problem.
- The SyScan slides are image-heavy; the argument must be reconstructed from
  code snippets and diagrams (the SyScan PDF extracted with an xref-reconstruct
  warning).

## Key design decisions and trade-offs

| Decision (defensive)                                             | Rationale                                                                                        | Trade-off                                                                                     |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| `NtCreateFile` + `RootDirectory` handle, one component at a time | The only way to bound a walk on Windows; there is no `openat2`-style scoped lookup               | `O(depth)` syscalls, and the caller must classify each reparse tag itself                     |
| `FILE_OPEN_REPARSE_POINT` on every component                     | Opens the link itself; "never returns STATUS_REPARSE" so a follow can't hide                     | The caller must then read and judge the tag — no policy is applied for you                    |
| `OBJ_DONT_REPARSE` as the strict form                            | One call fails with `STATUS_REPARSE_POINT_ENCOUNTERED` on _any_ reparse                          | Refuses legitimate reparse points too; availability is version-gated, needs a probe/downgrade |
| Classify by reparse tag, not by name                             | `MOUNT_POINT` vs `SYMLINK` vs the dozen others are distinguishable via `FSCTL_GET_REPARSE_POINT` | Tag list must be kept current; unknown vendor tags are a judgement call                       |
| Treat Win32 validation as untrusted; work in NT paths            | Canonicalization (`..`, trailing dots, `\\?\`, reserved names) diverges from what opens          | Must reimplement path handling at the NT layer; `\\?\` and `GLOBALROOT` are easy to miss      |
| Rely on RedirectionGuard where opted in                          | Blocks non-admin junction traversal by default for enrolled services                             | Junctions only — object-manager symlinks, NTFS symlinks and hard links stay in scope          |

## Sources

- [`symboliclink-testing-tools`][stt-repo] — [`README.txt`][stt-readme] (the tool list); `CommonUtils/ReparsePoint.cpp` (reparse-buffer build/read, tag constants, `OpenReparsePoint` with `FILE_FLAG_OPEN_REPARSE_POINT`); `CommonUtils/FileSymlink.cpp` (the `\RPC Control` junction + object-symlink combination); `CommonUtils/FileOpLock.cpp` (`FSCTL_REQUEST_OPLOCK`); `BaitAndSwitch/BaitAndSwitch.cpp` (oplock-driven swap); [`CreateSymlink_readme.txt`][stt-createsymlink], [`BaitAndSwitch_ReadMe.txt`][stt-bait], [`SetOpLock_ReadMe.txt`][stt-setoplock]
- [SyScan 2015, "A Link to the Past: Abusing Symbolic Links on Windows"][syscan-pdf] — the link-type history, object-manager reparsing, the Win32-path and `GLOBALROOT` tricks, the Task-Scheduler oplock exploit, `SeCreateSymbolicLinkPrivilege` and the `0x400` context flag, `$INDEX_ALLOCATION`
- Project Zero, ["Windows 10^H^H Symbolic Link Mitigations"][pz-2015] (2015-08-25) — the creation-time mitigations keyed on `RtlIsSandboxToken`, CVE-2015-2428/2429/2430
- Project Zero, ["The Definitive Guide on Win32 to NT Path Conversion"][pz-2016] (2016-02-29) — the seven path types, canonicalization steps, reserved-name and `\\?\` bypasses
- Project Zero, ["Windows Exploitation Tricks: Exploiting Arbitrary File Writes for Local Elevation of Privilege"][pz-2018] (2018-04-18) — hardlink + inherited-ACE escalation, DiagHub DLL load, the RS4 mount-point remediation note
- [`NtCreateFile`][ntcreatefile], [`OBJECT_ATTRIBUTES`][objattr] — `FILE_OPEN_REPARSE_POINT`, `OBJ_DONT_REPARSE`, `OBJ_OPENLINK`, `RootDirectory` semantics
- [RedirectionGuard: Mitigating unsafe junction traversal in Windows][redir] (MSRC, 2025-06-25) — `ProcessRedirectionTrustPolicy`, what it covers and excludes
- Sibling deep-dive: [`windows-nt.md`][windows] (the defensive kernel API in detail); the catalog synthesis in [`comparison.md`][comparison]

> [!NOTE]
> **Unverified.** The SyScan 2015 recording (Vimeo/YouTube) was not watched;
> everything attributed to the talk comes from the slide PDF, downloaded from
> `infocon.org` and text-extracted (with an xref-reconstruct warning), not from
> `cyphar/talks`. The three Project Zero URLs 301-redirect from
> `googleprojectzero.blogspot.com` to `projectzero.google`; they were read
> through a summarising fetch at the redirect target, and CVE numbers, dates and
> quotes are as that fetch returned them — the 2015 post's specific CVE-to-
> mitigation mapping (CVE-2015-2428/2429/2430) and the 2018 post's Issue #1428 /
> DiagHub details were not cross-checked against a second source. RedirectionGuard
> details (the alternate-data-stream metadata, the enrolled services) come from
> the single MSRC post. The `SeCreateSymbolicLinkPrivilege` `0x400` context flag
> and `IopParseDevice` device-type list are read from slide images (68–70, 52)
> and are Forshaw's reverse-engineering, not vendor documentation.

<!-- References -->

[stt-repo]: https://github.com/googleprojectzero/symboliclink-testing-tools/tree/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb
[stt-license]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/LICENSE.txt
[stt-readme]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/README.txt
[stt-createsymlink]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/CreateSymlink/CreateSymlink_readme.txt
[stt-bait]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/BaitAndSwitch/BaitAndSwitch_ReadMe.txt
[stt-setoplock]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/SetOpLock/SetOpLock_ReadMe.txt
[syscan-pdf]: https://infocon.org/cons/SyScan/SyScan%202015%20Singapore/SyScan%202015%20Singapore%20presentations/SyScan15%20James%20Forshaw%20-%20A%20Link%20to%20the%20Past.pdf
[pz-2015]: https://googleprojectzero.blogspot.com/2015/08/windows-10hh-symbolic-link-mitigations.html
[pz-2016]: https://googleprojectzero.blogspot.com/2016/02/the-definitive-guide-on-win32-to-nt.html
[pz-2018]: https://googleprojectzero.blogspot.com/2018/04/windows-exploitation-tricks-exploiting.html
[ntcreatefile]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntcreatefile
[objattr]: https://learn.microsoft.com/en-us/windows/win32/api/ntdef/ns-ntdef-_object_attributes
[redir]: https://www.microsoft.com/en-us/msrc/blog/2025/06/redirectionguard-mitigating-unsafe-junction-traversal-in-windows
[windows]: ./windows-nt.md
[comparison]: ./comparison.md
