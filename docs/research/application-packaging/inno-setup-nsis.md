# Inno Setup and NSIS (scriptable Windows installer EXEs)

Inno Setup and NSIS compile staged files plus installation logic into self-contained
setup programs; their EXEs execute author-defined lifecycle code rather than submitting
an MSI product/component database to Windows Installer.

| Field                   | Inno Setup                                                                           | NSIS                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Languages               | Pascal/Delphi implementation; declarative `.iss` sections and Pascal Script          | C/C++ implementation; `.nsi` installer language, preprocessor, plug-ins                      |
| License                 | Inno Setup License (permissive redistribution terms)                                 | zlib/libpng license                                                                          |
| Repository              | [jrsoftware/issrc][inno-repo]                                                        | [kichik/nsis][nsis-repo]                                                                     |
| Documentation           | Checked-in `ISHelp/isetup.xml`                                                       | Checked-in `Docs/src/*.but`                                                                  |
| Reviewed revision       | [`eafc69c06f3b23bdccbf22d3fde83b499ddc4901`][inno-revision] (`is-7_0_2-9-geafc69c0`) | [`edc38ffe33ec5d3a201edd4a9070863c18d6fe18`][nsis-revision] (`v312-14-gedc38ffe`)            |
| Category                | Scriptable bundling installer compiler                                               | Scriptable bundling installer compiler/VM                                                    |
| Supported hosts/targets | Normal compiler/build path is Windows; generated installers target Windows           | `makensis` can run on Windows/POSIX with matching stubs; generated installers target Windows |
| OSS/paid boundary       | OSS compiler; Authenticode certificate/service separate                              | OSS compiler; Authenticode certificate/service separate                                      |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Both tools turn a staged application into one downloadable setup `.exe` that can prompt
for scope/options, decompress payloads, copy files, edit the registry, create shortcuts,
run helpers, and emit an uninstaller. Inno Setup supplies higher-level declarative
sections and an uninstall log; NSIS exposes a compact imperative VM whose script owns
nearly every mutation.

NSIS states the model directly:

> “Unlike other systems that can only generate installers based on a list of files and
> registry keys, NSIS has a powerful scripting language.” — [`Docs/src/intro.but`][nsis-intro]

And Inno's source separates compiler from runtime: `ISCC` drives `ISCmplr`, while
`Setup` “performs all (un)installation-related tasks” ([`README.md`][inno-readme]). The
resulting program is not an MSI in disguise: it has no MSI `ProductCode`, `PackageCode`,
`UpgradeCode`, component GUID/key path, feature state, advertised repair, standard
action sequence, or Windows Installer transaction.

### Design philosophy

Inno Setup favors conventional declarations—`[Files]`, `[Registry]`, `[Icons]`,
`[Run]`, and uninstall counterparts—with Pascal Script `[Code]` for exceptions. NSIS
makes installer behavior a program composed of sections, functions, callbacks, and
instructions. Flexibility is the benefit and the servicing cost: upgrade detection,
recovery, ownership, silent safety, and cleanup are only as correct as the compiled
script.

## How it works

A small Inno Setup script identifies one stable application lineage and declarative
resources:

```ini
[Setup]
AppId={{PUT-STABLE-GUID-HERE}
AppName=Sparkles
AppVersion=1.2.3
DefaultDirName={autopf}\Sparkles
PrivilegesRequired=lowest
Compression=lzma2
SolidCompression=yes

[Files]
Source: "stage\sparkles.exe"; DestDir: "{app}"

[Icons]
Name: "{autoprograms}\Sparkles"; Filename: "{app}\sparkles.exe"
```

An NSIS script emits equivalent behavior as explicit instructions:

```nsis
Name "Sparkles"
OutFile "sparkles-setup.exe"
RequestExecutionLevel user
InstallDir "$LocalAppData\Programs\Sparkles"

Section
  SetOutPath "$INSTDIR"
  File "stage\sparkles.exe"
  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\sparkles.exe"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
```

Inno's `SetupLdr` self-extracts the compiled Setup runtime and data; NSIS compiles script
instructions and compressed data into an executable containing its VM/stub. Both can
run external programs or native plug-ins, so review must cover executed logic—not only
the visible payload list.

## Analysis spine

### Input and staging

Both consume a complete, architecture-appropriate staged application tree plus scripts,
icons, license text, localization, and optional prerequisites. Inno `[Files]` entries
control source/destination, overwrite/version behavior, registration, external/download
files, and uninstall flags. NSIS `File` embeds/extracts files; `SetOutPath`, registry,
shortcut, service/helper, and cleanup instructions establish meaning.

Inno supports `zip`, `bzip`, `lzma`, `lzma2`, and no compression; `SolidCompression`
compresses files together for ratio at the cost of extraction locality. NSIS supports
zlib, bzip2, and LZMA plus `/SOLID`; `ReserveFile` moves early-needed data ahead of a
solid block. Compression is transport, not lifecycle ownership.

### Outputs and targets

The principal output is a setup `.exe`, usually containing compressed payload and
runtime. Both can generate an uninstaller executable during compilation/installation.
Publish separate x86/x64/Arm64 payloads when runtime closures differ, even if one setup
stub can branch by architecture.

Inno's supported compiler workflow and upstream CI are Windows-based. NSIS documents
POSIX compilation with precompiled matching stubs or a Windows cross-compiler and tests
Ubuntu, macOS, and Windows. Cross-building an EXE does not verify its UAC, registry-view,
locked-file, reboot, upgrade, or uninstall behavior; those need Windows VMs.

### Metadata and dependencies

Inno's stable `AppId` names the uninstall registration/log lineage. The documentation
is precise: “Setup will only append to an uninstall log if the `AppId` of the existing
uninstall log is the same as the current installation's `AppId`”
([`AppId`][inno-appid]). `AppVersion` and PE version fields are display/version metadata,
not MSI identities. `AppUpdatesURL` adds a URL to uninstall metadata; it is not an
update protocol.

NSIS has no built-in product/upgrade identity. The author chooses a stable Add/Remove
Programs registry subkey—upstream suggests product name or GUID—writes
`DisplayName`, `DisplayVersion`, `UninstallString`, and related values, then scripts
old-version detection. `VIProductVersion` labels the PE file only.

Neither resolves dependencies. Payloads can bundle prerequisites or scripts can detect,
download, and execute them. Every fetching installer must authenticate the downloaded
bytes, handle offline/proxy/reboot/failure states, and define whether uninstall removes
shared prerequisites.

### Installation, upgrade, and uninstall

Inno executes declarative sections in a documented order, logs handled changes in
`unins???.dat`, installs `unins???.exe`, and registers uninstall metadata.
`[UninstallRun]`, `[UninstallDelete]`, and Pascal Script add cleanup. Its documentation
says uninstall parses the log from end to beginning so changes are undone in reverse
order ([installation order][inno-order]); that describes **later uninstall**, not an
atomic failed-install rollback guarantee.

NSIS executes selected section instructions in order. `WriteUninstaller` writes the
script's `un.` functions/sections; the author must create ARP registration and pair every
file, registry, shortcut, and external effect with safe uninstall logic. Upstream warns
that recursive removal of `$INSTDIR` can erase unrelated files ([`RMDir`][nsis-rmdir]).

The normal upgrade for either is running a newer signed setup:

- Inno keeps `AppId` stable to reuse the destination/settings and append to the same
  uninstall-log lineage. Script/check logic owns downgrade blocking, migration,
  side-by-side IDs, and removal of obsolete files.
- NSIS scripts compare chosen registry/file versions and optionally run the old
  uninstaller. There is no implicit relationship between two setup EXEs.

Neither provides MSI automatic repair or component inventory. Inno offers orderly
replacement/uninstall logging and NSIS exposes error flags/branches, but failed-install
rollback, backup/restore, idempotent retry, and a repair UI are explicit script work.
Effects of arbitrary child processes, network calls, or custom code are not reversible
by the compiler.

### Signing and platform trust

Both delegate Authenticode to an external signer. Inno's `SignTool` integration signs
Setup and the generated uninstaller, supports multiple signing commands, and provides
retry/delay controls for timestamp services. Its separate `.issig` mechanism verifies
external downloads but explicitly does not replace Authenticode publisher trust
([Inno signature distinction][inno-signature]).

NSIS `!finalize` can run a signer after installer generation and `!uninstfinalize` after
generated-uninstaller construction. Sign **both** setup and uninstaller with SHA-256 and
RFC 3161 timestamps; signing only the outer EXE does not authenticate an extracted
uninstaller. Build deterministic unsigned bytes first, then sign/timestamp, verify, and
hash final artifacts. Any resource editing after signing invalidates the signature.

### Publication and discovery

Setup EXEs fit direct HTTPS/release assets, enterprise tools, Chocolatey packages, and
WinGet manifests. The file has no public catalog. WinGet/Chocolatey must record the
correct scope, silent switches, install location behavior, product/ARP identity, return
codes, and immutable hash; those values are properties of the authored installer, not
reliably inferable from `.exe` or generator brand.

### Updates and release channels

Neither compiler supplies a complete update service. Inno explicitly assigns update
detection, location/download, and launching a new `Setup.exe` to the application
([auto-update guidance][inno-update]). NSIS supplies enough scripting/network plug-ins
to build a downloader, but no standard feed/channel/rollout protocol.

Stable/beta/nightly streams need deliberate distinct `AppId`/ARP keys when they should
coexist, or one stable key when they should replace each other. Define downgrade and
same-version reinstall behavior. Do not let an application updater and a package manager
simultaneously own replacement.

### Automation and CI

`ISCC.exe` is Inno's command-line compiler: exit `0` succeeds, `1` is bad
parameters/internal error, and `2` is compilation failure. Setup automation uses
case-insensitive `/SILENT` or `/VERYSILENT`; `/SUPPRESSMSGBOXES`, `/NORESTART`, scope
switches, and restart exit-code control complete unattended policy. Script code can
still display UI, so test the exact build.

`makensis` accepts command-line definitions and preprocessing. Generated NSIS installers
use case-sensitive `/S`; the script can still display UI and custom options require
custom parsing. Default process results are `0` normal, `1` user abort, and `2` script
abort, but `SetErrorLevel` can replace them. NSIS uninstall's self-copy behavior can
prevent the initial process from returning the final uninstaller result, so automation
must test the real invocation.

Test clean install, same-version reinstall, every supported upgrade, downgrade,
per-user/per-machine scope, x86/x64 registry views, locked files/reboots, cancellation
and injected failures, silent install, silent uninstall, and signature verification on
Windows. Findings here are `[source-verified]`; no result is
`[host-verified: windows]`.

### Supply-chain evidence and reproducibility

Retain scripts/includes/plug-ins, compiler version, staged-file manifest/hashes,
unsigned setup hash, signer certificate/thumbprint, timestamp evidence, final setup and
uninstaller hashes, SBOM, and provenance. External downloads need pinned cryptographic
hashes and HTTPS; signing only the fetching stub does not authenticate bytes it later
retrieves.

Inno offers a `notimestamp` file flag; NSIS documents `SOURCE_DATE_EPOCH` for building
its toolchain. Input ordering, compression library/tool version, embedded PE metadata,
generated uninstallers, and Authenticode timestamps can still vary. Treat unsigned
payload reproducibility and signed-release auditability as separate claims.

### Extensibility and UX

Inno extends conventional sections with preprocessor/includes, components/tasks,
checks, parameters, custom wizard pages, Pascal Script, native helpers, and download
signature support. NSIS exposes macros/includes, compile-time commands, callbacks,
functions, custom pages/resources, and native plug-ins. NSIS notes plug-ins may be
written in C, C++, Delphi, or other languages and are compressed only when used
([`intro.but`][nsis-intro]).

More flexibility means more privileged code and state space. Preserve predictable
scope selection, logs, noninteractive behavior, restart signaling, accessible defaults,
and stable uninstall registration. A conventional setup should not surprise users by
installing unrelated software or retaining an updater/service without explicit consent.

## Strengths

- One familiar self-contained setup executable with strong compression.
- Rich Windows integration without MSI component authoring overhead.
- Inno offers concise declarations and systematic uninstall logging.
- NSIS offers very small, deeply programmable installers and practical cross-host compilation.
- Both integrate external Authenticode signing and unattended execution.
- Broad extension points accommodate legacy or unusual application requirements.

## Weaknesses

- No MSI product/component repair, transaction, policy, or standardized upgrade model.
- Script errors can leave partial state or erase resources the installer does not own.
- Identity, downgrade, migration, rollback, and channels are publisher conventions.
- Generator name does not guarantee silent switches are truly unattended.
- Native plug-ins and child processes expand privileged supply-chain surface.
- Every installer needs real Windows lifecycle tests despite successful cross-compilation.

## Key design decisions and trade-offs

| Decision                                 | Rationale                                           | Trade-off                                                |
| ---------------------------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| Stable Inno `AppId` / NSIS ARP GUID      | Relate future setup runs and uninstall registration | Identity convention lacks MSI's enforced servicing rules |
| Declarative Inno sections where possible | Gain ordering and uninstall-log support             | Exceptional behavior still needs Pascal Script           |
| Explicit NSIS install/uninstall pairs    | Keep behavior transparent in script                 | Author owns every cleanup and error path                 |
| Per-user default for nonprivileged apps  | Avoid UAC and machine-wide mutation                 | Each user gets separate registration/state               |
| Sign setup and generated uninstaller     | Preserve publisher trust across lifecycle           | Requires two correctly ordered signing surfaces          |
| Windows lifecycle matrix                 | Validate real UAC/registry/reboot/silent behavior   | More CI cost than compilation alone                      |

## Sources

- [Inno Setup repository at exact reviewed revision][inno-revision], locally read from
  `$REPOS/inno-setup` (`README.md`, `ISHelp/isetup.xml`, compiler/runtime source, CI)
- [NSIS repository at exact reviewed revision][nsis-revision], locally read from
  `$REPOS/nsis` (`Docs/src`, `Examples`, `Contrib/MultiUser`, compiler/runtime source, CI)
- [Inno `AppId` and uninstall-log contract][inno-appid]
- [Inno setup/uninstall command-line behavior][inno-cli]
- [Inno signing integration][inno-signing]
- [NSIS tutorial and program model][nsis-tutorial]
- [NSIS silent-install contract][nsis-silent]
- [NSIS signing finalizers][nsis-finalize]
- [Microsoft SignTool command reference][signtool]
- Related: [packaging concepts][concepts] · [WiX/MSI][wix] · [Windows portable][portable]

<!-- References -->

[inno-repo]: https://github.com/jrsoftware/issrc
[nsis-repo]: https://github.com/kichik/nsis
[inno-revision]: https://github.com/jrsoftware/issrc/tree/eafc69c06f3b23bdccbf22d3fde83b499ddc4901
[nsis-revision]: https://github.com/kichik/nsis/tree/edc38ffe33ec5d3a201edd4a9070863c18d6fe18
[inno-readme]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/README.md
[inno-appid]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/ISHelp/isetup.xml#L4960-L4968
[inno-order]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/ISHelp/isetup.xml#L3216-L3267
[inno-signature]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/ISHelp/isetup.xml#L4073-L4081
[inno-update]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/ISHelp/isetup.xml#L3519-L3528
[inno-cli]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/ISHelp/isetup.xml#L4301-L4435
[inno-signing]: https://github.com/jrsoftware/issrc/blob/eafc69c06f3b23bdccbf22d3fde83b499ddc4901/ISHelp/isetup.xml#L6947-L6991
[nsis-intro]: https://github.com/kichik/nsis/blob/edc38ffe33ec5d3a201edd4a9070863c18d6fe18/Docs/src/intro.but#L32-L52
[nsis-tutorial]: https://github.com/kichik/nsis/blob/edc38ffe33ec5d3a201edd4a9070863c18d6fe18/Docs/src/tutorial.but#L9-L13
[nsis-rmdir]: https://github.com/kichik/nsis/blob/edc38ffe33ec5d3a201edd4a9070863c18d6fe18/Docs/src/basic.but#L144-L163
[nsis-silent]: https://github.com/kichik/nsis/blob/edc38ffe33ec5d3a201edd4a9070863c18d6fe18/Docs/src/silent.but#L1-L23
[nsis-finalize]: https://github.com/kichik/nsis/blob/edc38ffe33ec5d3a201edd4a9070863c18d6fe18/Docs/src/compiler.but#L127-L141
[signtool]: https://learn.microsoft.com/windows/win32/seccrypto/signtool
[concepts]: ./concepts.md
[wix]: ./wix-msi.md
[portable]: ./windows-portable.md
