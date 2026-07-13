# Chocolatey (Windows package automation and NuGet-compatible feeds)

Chocolatey packages Windows software as `.nupkg` archives containing NuGet metadata and
optional payloads plus PowerShell lifecycle automation; the OSS client can consume and
publish to the public Community Repository or ordinary internal package sources.

| Field             | Value                                                                                                                                                                                     |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Languages         | C# client and PowerShell package helpers/scripts                                                                                                                                          |
| License           | Apache-2.0 for the reviewed Chocolatey CLI repository                                                                                                                                     |
| Repository        | [chocolatey/choco][repo]                                                                                                                                                                  |
| Documentation     | [Chocolatey documentation][docs]                                                                                                                                                          |
| Reviewed revision | [`d43496ec679960a0df6e0a19738ac62587fd20ee`][revision] (`2.7.3-19-gd43496ec`)                                                                                                             |
| Category          | Windows package manager, package automation runtime, and NuGet-compatible repository client                                                                                               |
| Supported hosts   | Windows for application installation; portions of the CLI build/test under Mono on Linux/macOS                                                                                            |
| Payload model     | Embedded/bundled files or PowerShell-fetched vendor payloads                                                                                                                              |
| OSS/paid boundary | OSS CLI covers package lifecycle, sources, pack/push, checksums, and shims; licensed editions add management, internalization/cache, synchronization, and enhanced uninstall capabilities |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Chocolatey makes irregular Windows application installation scriptable and versioned.
A package is a NuGet-compatible `.nupkg` containing a `.nuspec`, conventionally a
`tools/` directory, and optional `chocolateyInstall.ps1`,
`chocolateyBeforeModify.ps1`, and `chocolateyUninstall.ps1`. The package may embed the
software itself or be a small automation wrapper that downloads a vendor MSI/EXE/ZIP,
verifies it, and invokes unattended switches.

The client source's uninstall help makes the package/payload distinction explicit:

> “These packages may or may not contain the software (applications/tools) that each
> package represents.” — [`ChocolateyUninstallCommand.cs`][uninstall-command]

Consequently, a `.nupkg` is always the repository and automation unit, but not always
the application payload. The Community Repository can host a tiny package whose script
fetches a much larger, independently signed installer from the publisher.

### Design philosophy

Chocolatey favors a convention-backed escape hatch. NuGet metadata supplies identity,
version, dependencies, and source transport; PowerShell supplies enough expressiveness
to drive nearly any Windows installer or filesystem layout. Built-in helpers normalize
common download, extraction, native install, PATH, environment, and checksum operations,
but a package script can still perform arbitrary privileged work.

The OSS client and repository service are separate products. The client can `pack`,
`push`, install from a folder/file share or HTTP NuGet/OData feed, and authenticate with
credentials or a client certificate. The public Community Repository adds its own
submission, moderation, malware review, and policy lifecycle; those server mechanics are
not implemented in the reviewed `choco` repository. Chocolatey for Business adds
capabilities around managed deployments, internalization/caching, package creation, and
state synchronization and must not be credited to the OSS core.

## How it works

A remote-payload package combines `.nuspec` metadata with an install script:

```xml
<package>
  <metadata>
    <id>example</id>
    <version>1.2.3</version>
    <authors>Example Publisher</authors>
    <description>Example command</description>
  </metadata>
</package>
```

```powershell
$packageArgs = @{
    packageName    = $env:ChocolateyPackageName
    fileType       = 'exe'
    url64bit       = 'https://example.invalid/example-1.2.3-x64.exe'
    checksum64     = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    checksumType64 = 'sha256'
    silentArgs     = '/S'
    validExitCodes = @(0, 3010)
}
Install-ChocolateyPackage @packageArgs
```

`choco pack` turns the `.nuspec`, scripts, and files into a compiled `.nupkg`; `choco
push` sends it to one configured source using an API key. During install, the NuGet
layer resolves package dependencies and extracts the package under
`$env:ChocolateyInstall\lib\<package>`. [`PowershellService.cs`][powershell-service]
selects the lifecycle script and runs it with Chocolatey's helper module and environment.

For a self-contained package, files beneath the extracted package directory can be the
application. [`ShimGenerationService.cs`][shim-service] recursively finds `.exe` files,
skips siblings marked `.exe.ignore`, treats `.exe.gui` as GUI applications, and creates
launchers in Chocolatey's shared `bin` directory. For a fetching package,
`Get-ChocolateyWebFile`/`Install-ChocolateyPackage` download and execute upstream bytes;
[`Get-ChecksumValid.ps1`][checksum-helper] verifies package-script checksums and throws on
mismatch.

## Analysis spine

### Input and staging

Inputs are a `.nuspec`, PowerShell lifecycle scripts, and optionally embedded payload
files. A producer may bundle a portable tree or installer into the `.nupkg`, or declare
URLs and checksums in `chocolateyInstall.ps1`. The former gives the repository custody of
the exact payload; the latter keeps packages small and preserves publisher hosting but
adds a second availability boundary.

The client downloads the `.nupkg` from its source, can validate the source-provided
package hash, extracts it into Chocolatey's package root, prepares package environment
variables, and runs the scripts. PowerShell decides any further staging location. This
is not a sandbox: scripts can write Program Files, registry, services, shortcuts, or any
other accessible location.

### Outputs and targets

For a self-contained portable package, the managed output can remain under
`$env:ChocolateyInstall\lib\<package>\tools` with shims in Chocolatey's PATH directory.
For native installers, output is the MSI/EXE-defined filesystem and registry state;
Chocolatey tracks the package and snapshots Programs and Features changes. Packages may
also install PowerShell modules, Windows features, services, archives, and arbitrary
scripted resources.

The target is primarily Windows applications across x86/x64/ARM variants selected by
package logic and helper parameters. The `.nupkg` itself is architecture-neutral
automation metadata unless it embeds architecture-specific files. Chocolatey does not
turn a vendor EXE into MSI/MSIX transaction semantics.

### Metadata and dependencies

The `.nuspec` provides NuGet package ID, version, title, authors/owners, description,
license/project URLs, tags, and dependency version ranges. Package scripts receive
normalized identity/version and user `--package-parameters`; native installer arguments
can be extended or overridden separately. This cleanly distinguishes package-manager
parameters from switches passed to the vendor installer.

Dependencies are other packages resolved by the NuGet layer. They express install order
and acceptable package versions, not every runtime DLL or OS prerequisite. PowerShell
can inspect architecture and environment or install Windows features, but those custom
preconditions are not uniformly queryable catalog metadata.

### Installation, upgrade, and uninstall

Install extracts the selected package, executes `chocolateyInstall.ps1`, records package
state, and creates shims for eligible embedded/downloaded executables. Upgrade resolves a
newer package, runs `chocolateyBeforeModify.ps1`, replaces package content, and executes
the new install script. It may therefore rerun a vendor installer or custom idempotent
logic rather than apply a universal transaction.

Uninstall runs `chocolateyUninstall.ps1` when present. The automatic uninstaller can use
Programs and Features registry changes captured around a native install to infer the
upstream uninstall command. With that feature disabled and no uninstall script, removing
the Chocolatey package may leave externally installed software behind. Portable files
inside the package directory and generated shims are simpler to remove; user data outside
that directory has no Scoop-like declarative persistence map and must be handled by
script/policy.

Pins suppress upgrades; `--allow-downgrade` makes an older package eligible when
explicitly requested. Native installer rollback and repair remain installer-specific.

### Signing and platform trust

Chocolatey has several distinct integrity layers:

- A package source can provide the `.nupkg` hash; the client's package-hash validation
  checks it when enabled.
- Package scripts should provide checksums for every remotely downloaded payload.
  `Get-ChecksumValid` supports MD5, SHA-1, SHA-256, and SHA-512, recommends at least
  SHA-256, and normally throws when a secure or insecure download lacks the required
  checksum unless an explicit weakening option/feature is used.
- Authenticode on the vendor MSI/EXE and on Chocolatey's own distributed scripts is a
  platform code-signing layer separate from those hashes.
- Feed TLS, API keys, credentials, or client certificates authenticate repository
  transport/access, not the upstream application's build provenance.

A checksum says the downloaded bytes match what the package author/moderator selected;
it does not prove publisher identity if an attacker controlled the URL before the hash
was authored. PowerShell package scripts are executable code and therefore require trust
in the feed and package review process.

### Publication and discovery

`choco pack` creates the `.nupkg`; `choco push <file> --source <url> --api-key <key>`
publishes it to one feed. Search/install/list operations query configured sources. The
source command accepts local folders/file shares or HTTP endpoints returning NuGet/OData
package data; it also supports basic credentials and a client certificate. This makes an
internal repository possible with ordinary NuGet-compatible servers or a shared folder.

Community publication is not immediate catalog registration. Maintainers push to the
Community Repository, where package policy, automated checks and human moderation decide
approval; packages can remain pending, rejected, or require fixes. The client repository
explicitly redirects website/repository issues to a separate project, so moderation must
not be inferred from `choco push` implementation. Internal feeds can define different
review/promotion policy and can embed/internalize payloads to remove Internet dependency.

### Updates and release channels

Chocolatey compares NuGet versions available from configured sources. `choco outdated`
reports newer versions and `choco upgrade` installs them; pins opt packages out.
Prerelease versions are excluded unless `--pre` is supplied, and an installed prerelease
can continue along newer prereleases. Exact versions and separate package IDs can model
major or beta streams, but there is no typed stable/beta/nightly channel field or staged
rollout percentage in a package.

“Automatic packages” are producer automation, not a client-side mutable manifest. The
checked-in new-package template recommends automatic packaging updates, but detection of
an upstream release, editing URLs/checksums/version, packing, pushing, and responding to
moderation are external CI tasks (commonly AU or custom scripts). A native application's
self-updater can conflict with Chocolatey's installed version record unless the package
maintainer accounts for it.

### Automation and CI

A package publication job can detect an upstream version, download/verify release assets,
update `.nuspec` and scripts, run package validation/tests in a disposable Windows host,
execute `choco pack`, and `choco push` with a protected API key. For fetching packages,
CI should establish the payload checksum before publication; for embedded packages it
should produce the `.nupkg` only after the payload is immutable.

The reviewed CLI's own GitHub Actions build on Ubuntu, Windows, macOS/Mono, and Docker,
run tests, build NuGet/Chocolatey packages, and upload CI artifacts; the Windows job also
builds an MSI. Those workflows validate Chocolatey itself, not Community Repository
moderation or publication of third-party packages. Repository promotion, moderation,
and enterprise deployment remain separate control planes.

### Supply-chain evidence and reproducibility

Useful evidence includes Git source for package recipes, `.nupkg` hashes supplied by the
feed, remote payload checksums in scripts, vendor code signatures, source access control,
and disposable-host install/uninstall tests. An embedded package reduces dependence on a
mutable external URL; a remote package reduces repository size and licensing exposure.
Neither choice automatically yields an SBOM or provenance attestation.

PowerShell scripts, unpinned helper behavior, mutable upstream URLs, repository
credentials, and moderator/automation accounts are high-value trust seams. Chocolatey
does not promise byte-reproducible `.nupkg` creation, reproducible vendor installers, a
transparency log, or a universal signed provenance format. Checksums can be explicitly
ignored, so organizational policy must prevent insecure flags in automation.

### Extensibility and UX

The helper module covers downloads, archive extraction, native package execution,
environment variables, PATH, services, shortcuts, and other Windows operations; arbitrary
PowerShell handles the rest. Templates, hook scripts, package parameters, multiple
sources, and NuGet dependencies make the model broadly extensible. Automatic shim
generation gives self-contained CLI tools a simple portable path.

The same `install`/`upgrade`/`uninstall` vocabulary can hide three contracts: files owned
inside the `.nupkg`, remotely fetched payloads owned by package automation, and native
installers owned by Windows/vendor uninstall metadata. Chocolatey's flexibility is its
central strength, but release tooling must retain that distinction when reasoning about
hosting, checksums, rollback, or cleanup.

## Strengths

- `.nupkg` can bundle payloads or remain a small recipe around vendor-hosted installers.
- PowerShell helpers and escape hatches cover unusually diverse Windows software.
- NuGet-compatible feeds and file shares make internal repositories straightforward.
- Package and remote-payload checksum layers can bind repository selection to bytes.
- Automatic shims make self-contained command-line packages easy to expose on PATH.
- `pack` and `push` are simple primitives for CI-driven publication.

## Weaknesses

- Package scripts are arbitrary executable code, often elevated.
- Fetching packages depend on external URL availability and disciplined checksum updates.
- Native install, rollback, upgrade, and uninstall semantics remain heterogeneous.
- Community moderation is an external service workflow, not locally reproducible from the client tree.
- No first-class release channels, staged rollout, SBOM, provenance, or reproducibility guarantee exists.
- OSS and licensed capabilities are easy to conflate, especially internalization and enhanced synchronization/uninstall.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                             | Trade-off                                              |
| ------------------------------------------ | ----------------------------------------------------- | ------------------------------------------------------ |
| Use NuGet `.nupkg` as package unit         | Reuse identity, versions, dependencies, and feeds     | Application payload may live outside the package       |
| Allow embedded or remote payloads          | Balance custody, size, licensing, and vendor signing  | Two substantially different availability/trust models  |
| PowerShell lifecycle scripts               | Drive almost any Windows installer                    | Package review becomes privileged code review          |
| Helpers plus native installer switches     | Normalize common unattended operations                | Irregular installers still need custom logic           |
| Automatic shim discovery                   | Put self-contained executables on PATH                | Every unignored executable becomes exposed state       |
| NuGet-compatible internal sources          | Avoid a mandatory central repository                  | Organizations own feed security and promotion policy   |
| External community moderation              | Apply public policy without coupling it to the client | `push` success does not imply immediate availability   |
| Prerelease versions and pins, not channels | Reuse NuGet version semantics                         | Promotion/staged rollout require naming or feed policy |

## Sources

- [chocolatey/choco at the exact reviewed revision][revision]
- [`ChocolateyUninstallCommand.cs` — package versus installed software and auto-uninstaller boundary][uninstall-command]
- [`ChocolateyReadMeTemplate.cs` — embedded packages, automation scripts, and shim conventions][package-template]
- [`PowershellService.cs` — install/before-modify/uninstall script execution][powershell-service]
- [`ShimGenerationService.cs` — automatic executable discovery and shims][shim-service]
- [`Get-ChecksumValid.ps1` — remote payload integrity and weakening controls][checksum-helper]
- [`NugetService.cs` — dependency resolution, package download/hash, upgrade, and push][nuget-service]
- [`ChocolateySourceCommand.cs`][source-command], [`ChocolateyPackCommand.cs`][pack-command], and [`ChocolateyPushCommand.cs`][push-command]
- [Chocolatey CLI GitHub Actions build/test workflow][ci]
- [Official Community Repository moderation documentation][moderation-docs]

Local provenance: `$REPOS/chocolatey` at
`d43496ec679960a0df6e0a19738ac62587fd20ee`; inspected package templates, PowerShell
helpers, NuGet/source/package services, command help, Pester/NUnit tests, fixture
packages, and GitHub workflows. Client mechanics are `[source-verified]`; community
policy is `[spec-verified]` from official documentation. Windows package behavior was
not executed and is not host-verified.

<!-- References -->

[repo]: https://github.com/chocolatey/choco
[docs]: https://docs.chocolatey.org/en-us/
[revision]: https://github.com/chocolatey/choco/tree/d43496ec679960a0df6e0a19738ac62587fd20ee
[uninstall-command]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/commands/ChocolateyUninstallCommand.cs
[package-template]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/templates/ChocolateyReadMeTemplate.cs
[powershell-service]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/services/PowershellService.cs
[shim-service]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/services/ShimGenerationService.cs
[checksum-helper]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey.resources/helpers/functions/Get-CheckSumValid.ps1
[nuget-service]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/services/NugetService.cs
[source-command]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/commands/ChocolateySourceCommand.cs
[pack-command]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/commands/ChocolateyPackCommand.cs
[push-command]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/src/chocolatey/infrastructure.app/commands/ChocolateyPushCommand.cs
[ci]: https://github.com/chocolatey/choco/blob/d43496ec679960a0df6e0a19738ac62587fd20ee/.github/workflows/build.yml
[moderation-docs]: https://docs.chocolatey.org/en-us/community-repository/moderation/
