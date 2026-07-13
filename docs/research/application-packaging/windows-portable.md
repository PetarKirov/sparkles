# Windows portable applications (artifact model)

A portable Windows release is a directory or archive whose publisher deliberately leaves
installation, integration, updates, and removal outside an operating-system package
database.

| Field                   | Value                                                                                                                                   |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Platform                | Windows                                                                                                                                 |
| Language                | N/A — artifact convention; Scoop and WinGet implementations use PowerShell and C++                                                      |
| License                 | N/A for the convention; reviewed Scoop and WinGet implementations retain their own licenses                                             |
| Documentation           | [Microsoft SignTool][signtool] · [Authenticode][authenticode] · [known-folder guidance][known-folders]                                  |
| Inputs                  | Architecture-specific executable, adjacent DLLs/runtime, resources, license, and notices                                                |
| Outputs                 | Versioned `.zip` or unpacked directory; optionally checksums and detached attestations                                                  |
| Repository evidence     | [Scoop][scoop-repo] and [WinGet CLI][winget-repo]                                                                                       |
| Reviewed revisions      | Scoop [`b588a06e41d920d2123ec70aee682bae14935939`][scoop-sha]; WinGet CLI [`22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1`][winget-sha]      |
| Category                | Portable payload container; not an installer database                                                                                   |
| Supported hosts/targets | Constructible on any host with a capable ZIP implementation; execution and Authenticode verification require Windows-compatible tooling |
| OSS/paid boundary       | ZIP construction is commodity OSS functionality; trusted code-signing certificates or managed signing services may cost money           |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Portable delivery gives users and package-manager clients transparent application files
without requiring elevation or an opaque setup program. It is especially effective for
CLI programs, self-contained desktop applications, removable media, and restricted
accounts. The archive is only a transport boundary: whether the result is genuinely
portable depends on its runtime dependencies and where it writes state.

Scoop's checked-in definition captures the intended payload boundary:

> “These apps are compressed files which can run standalone after being extracted. This
> type of apps does not produce side effects like changing the Windows Registry or
> placing files outside the app directory.” — [`README.md`][scoop-readme]

That is an application-behavior goal, not a claim that a package manager changes
nothing. Scoop adds extraction, shims, optional shortcuts, persistence, and
manifest-driven upgrades around upstream archives. WinGet's portable handler adds
managed placement, command aliases/PATH state, a file index, and Apps & Features
registration. Those are **client semantics**, not properties of the ZIP itself.

### Design philosophy

A good portable release is explicit and disposable: extract into a writable directory,
run it without global registration, keep mutable data outside immutable program files,
and remove it by deleting the directory. Any PATH edit, shortcut, file association,
service, scheduled task, registry entry, updater, or shared runtime creates lifecycle
state that must have an equally explicit owner.

## How it works

A conventional release layout keeps one top-level directory so extraction does not
scatter files:

```text
sparkles-1.2.3-windows-x86_64/
├── sparkles.exe
├── *.dll
├── resources/
├── LICENSE
└── THIRD-PARTY-NOTICES.txt
```

Publish immutable, architecture-labelled assets such as
`sparkles-1.2.3-windows-x86_64.zip`, then publish a SHA-256 digest over the final ZIP.
Sign PE files before archiving: changing an executable after Authenticode signing
invalidates its signature, while signing the ZIP itself does not cause Windows to trust
the executable extracted from it. Use `Get-AuthenticodeSignature` or `signtool verify`
on Windows and verify the published hash before extraction.

A direct-download user can place the directory under `%LOCALAPPDATA%\Programs` for a
per-user application, another user-owned tools directory, or a removable/workspace
location. `%ProgramFiles%` normally implies machine administration and should not be
the default for a no-elevation portable flow. PATH changes and shortcuts should be
opt-in instructions or performed by a package manager that records and reverses them.

Manager overlays make ownership concrete. WinGet defaults to managed per-user or
per-machine package roots, exposes commands through a central Links directory, records
portable state and ARP metadata, verifies indexed files before update/removal, and
preserves unknown remaining files unless purge is requested
([portable flow][winget-portable-flow], [uninstall][winget-portable-uninstall]). No
Start-menu shortcut creation appears in that reviewed portable path. Scoop installs
version directories, switches a `current` junction, creates shims and manifest-declared
shortcuts, and moves declared `persist` state outside the version tree; normal uninstall
retains persisted state while `--purge` removes it ([install][scoop-install],
[uninstall][scoop-uninstall]).

## Analysis spine

### Input and staging

Stage the complete runtime closure for one Windows architecture: the `.exe`, required
private DLLs, data files, licenses, and symbol policy. Do not copy ambient DLLs from a
developer machine. Decide whether configuration and caches are relative to the
executable, under known folders such as `%APPDATA%`/`%LOCALAPPDATA%`, or selected by an
explicit `--portable` mode. The choice determines whether deleting the directory is a
complete uninstall.

Normalize the top-level directory name, path separators, file modes where consumers
preserve them, and ZIP timestamps when reproducibility matters. Avoid filenames that
are illegal or ambiguous on Windows and test extraction with the Windows clients users
will actually employ.

### Outputs and targets

Publish separate assets for `x86`, `x64`, and `arm64` unless one executable genuinely
supports multiple architectures. A ZIP is a compressed directory, not a fat-binary
format. An optional uncompressed directory is useful for internal testing but is a poor
web artifact because atomic download and checksumming become harder.

Portable does not mean statically linked. MSVC/UCRT, WebView2, GPU, or other runtime
requirements must be vendored where licensing and deployment rules allow it or stated
as prerequisites. A launcher that downloads prerequisites turns the artifact into a
fetching installer and changes its failure/trust model.

### Metadata and dependencies

ZIP has no application identity, dependency table, minimum-Windows field, upgrade code,
or uninstall metadata. Put human-readable version/architecture information in the
filename and expose machine-readable version output from the executable. Release
metadata should record size, SHA-256, target, and content type.

Catalogs add a second metadata layer. Scoop manifests name URLs, hashes, binaries,
shortcuts, persistence, and update rules; WinGet portable manifests describe the
installer type and commands/aliases. Those manifests refer to immutable upstream bytes
and do not retrofit an installer transaction into the ZIP.

### Installation, upgrade, and uninstall

For direct use, installation is extraction or copying. Upgrade is replacement of the
program directory after stopping running processes; uninstall is deletion. Windows has
no receipt to discover missed files, repair damage, restore a previous version, or
remove state written elsewhere.

The publisher must define collision and migration policy. Replacing in place is simple
but can leave removed files behind; extract-new-and-rename is safer and allows rollback
if the old directory is retained. Never place mutable configuration inside a directory
that an updater atomically replaces unless it is explicitly preserved. If instructions
edit PATH, they must identify whether the user or machine PATH is changed and how to
remove exactly the inserted entry.

### Signing and platform trust

Authenticode-sign every shipped PE executable and DLL that should carry publisher
identity, then timestamp each signature with an RFC 3161 timestamp server. Microsoft's
SignTool documentation distinguishes `/tr` (RFC 3161 timestamp URL) and `/td` (timestamp
digest); current guidance also requires explicit digest algorithms. A valid timestamp
lets Windows validate that the signature was made while the certificate was valid,
rather than making releases fail merely because the certificate later expires.

A SHA-256 file beside the archive detects corruption only when obtained through a
separately trusted channel. Authenticode authenticates signed code under Windows trust
policy; a checksum binds bytes; neither substitutes for protected HTTPS publication,
SBOM/provenance, or malware review. ZIP itself has no standard Windows code-signing
envelope.

### Publication and discovery

Portable ZIPs fit HTTPS download pages, immutable forge release assets, internal file
shares, Scoop buckets, and WinGet portable entries. Direct hosting provides an artifact,
not discovery or lifecycle automation. Catalog submission should happen only after the
asset URL and hash are final; replacing bytes under one version breaks every downstream
manifest.

### Updates and release channels

ZIP defines no feed, channel, delta, or automatic updater. Users may download and
replace manually; a package manager may compare manifest versions; or the application
may ship its own updater. These owners must not race each other. Stable, beta, and
nightly assets need distinct immutable names/URLs and clear downgrade policy.

A self-updater assumes responsibility for process shutdown, atomic replacement,
rollback, signature/hash verification, retained user data, and updater replacement.
Without those mechanics, “check for updates” is merely discovery.

### Automation and CI

Archive construction and SHA-256 generation are cross-host operations and should consume
one manifest-defined staged tree per target. Native Windows CI should still execute the
binary, inspect dependencies, verify Authenticode and timestamps, test extraction under
long/non-ASCII paths, and exercise upgrade/removal instructions. This page is
`[source-verified]` and `[spec-verified]`; no install behavior was
`[host-verified: windows]` in this worktree.

Sign in an isolated Windows signing job after unsigned payload validation, then archive,
hash, and publish. If a signing service can sign digest requests remotely, keep private
keys out of general builders and record certificate/thumbprint plus timestamp evidence.

### Supply-chain evidence and reproducibility

Preserve a manifest of staged paths and SHA-256 values, compiler/toolchain versions,
archive-tool version/options, final archive hash, executable signature identities, SBOM,
and provenance. Deterministic path ordering, timestamps, permissions, and compression
can make the unsigned ZIP reproducible. Authenticode signatures and trusted timestamps
normally make the final signed bytes time-dependent, so compare the unsigned payload
and audit the later signing transformation separately.

### Extensibility and UX

The format is maximally inspectable and minimally opinionated. A small launcher or
PowerShell helper can create shortcuts or PATH entries, but every helper moves the
release toward installer semantics and needs silent behavior, logging, exit codes,
idempotency, rollback, and uninstall design. Prefer package-manager-owned shims over
asking users to mutate PATH manually. Always provide `--version` and a console-safe
entry point for CLI packages.

## Strengths

- Transparent payload that users and scanners can inspect before running.
- No elevation or platform installer database required.
- Cross-host construction and straightforward immutable hashing.
- Excellent fit for self-contained CLI applications and package-manager ingestion.
- Side-by-side versions and rollback are easy when directories remain separate.

## Weaknesses

- No intrinsic identity, dependencies, repair, rollback, uninstall receipt, or updates.
- PATH, shortcuts, file associations, and state cleanup are external responsibilities.
- Runtime closure errors surface only on target Windows systems.
- ZIP has no native Authenticode envelope; individual executable files need signing.
- In-place extraction can mix versions and leave obsolete files behind.

## Key design decisions and trade-offs

| Decision                          | Rationale                                              | Trade-off                                                   |
| --------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------- |
| One top-level versioned directory | Avoid scattered extraction and enable side-by-side use | Users/package managers must select the active version       |
| Per-user writable location        | Avoid elevation and keep ownership clear               | No automatic machine-wide discovery                         |
| State outside replaceable payload | Permit atomic upgrades                                 | Deleting the program directory may not remove all user data |
| Sign PE files before ZIP creation | Preserve Windows publisher trust after extraction      | More signing operations; ZIP itself remains unsigned        |
| Immutable URL plus SHA-256        | Make catalog references and caches stable              | Every rebuild requires a new versioned asset                |
| Let one owner manage updates      | Avoid races between app, user, and catalog client      | Publisher must choose and document that owner               |

## Sources

- [Scoop repository at pinned revision][scoop-sha], locally read from
  `$REPOS/scoop` (`README.md` and manifest/install implementation)
- [WinGet CLI repository at pinned revision][winget-sha], locally read from
  `$REPOS/winget-cli` (portable installer implementation and schemas)
- [Microsoft SignTool command reference][signtool]
- [Microsoft Authenticode introduction][authenticode]
- [Microsoft known-folder guidance][known-folders]
- Related: [packaging concepts][concepts] · [WinGet][winget] · [Scoop][scoop]

<!-- References -->

[scoop-repo]: https://github.com/ScoopInstaller/Scoop
[winget-repo]: https://github.com/microsoft/winget-cli
[scoop-sha]: https://github.com/ScoopInstaller/Scoop/tree/b588a06e41d920d2123ec70aee682bae14935939
[winget-sha]: https://github.com/microsoft/winget-cli/tree/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1
[scoop-readme]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/README.md#L101-L105
[winget-portable-flow]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/src/AppInstallerCLICore/Workflows/PortableFlow.cpp#L110-L327
[winget-portable-uninstall]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/src/AppInstallerCLICore/PortableInstaller.cpp#L325-L520
[scoop-install]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/lib/install.ps1#L174-L280
[scoop-uninstall]: https://github.com/ScoopInstaller/Scoop/blob/b588a06e41d920d2123ec70aee682bae14935939/libexec/scoop-uninstall.ps1#L1-L145
[signtool]: https://learn.microsoft.com/windows/win32/seccrypto/signtool
[authenticode]: https://learn.microsoft.com/windows-hardware/drivers/install/authenticode
[known-folders]: https://learn.microsoft.com/windows/win32/shell/knownfolderid
[concepts]: ./concepts.md
[winget]: ./winget.md
[scoop]: ./scoop.md
