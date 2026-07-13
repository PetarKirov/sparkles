# Velopack (cross-platform desktop applications)

A fully open-source application packager, installer, and in-app updater that turns prebuilt application files into platform-specific installers/portable bundles plus channel feeds and delta packages.

| Field             | Value                                                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Languages         | Rust core/updater; C# CLI and packaging; C#, C++, Node.js, Python, and Rust bindings                                                        |
| License           | MIT                                                                                                                                         |
| Repository        | [velopack/velopack][repo]                                                                                                                   |
| Documentation     | [docs.velopack.io][docs]                                                                                                                    |
| Reviewed revision | [`9ba468337e367c59db339828b59c8a20a0f6ea90`][revision] (source baseline `1.2`)                                                              |
| Category          | **Application packager + installer/updater**; not a general release control plane and not merely a format primitive                         |
| Product model     | Core repository and SDKs are OSS; optional `Velopack Flow` client integration is present, but the core pack/update path does not require it |
| Target platforms  | Windows, macOS, and Linux                                                                                                                   |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Velopack starts after compilation. Given a directory containing an application's executable and resources, `vpk pack` creates a complete release set: portable output, an installer where the platform has one, a full update package, an optional delta from the prior version, and per-channel feed metadata. Applications embed a small SDK that checks, downloads, verifies, and applies those packages.

The repository states its intended experience directly ([`README.md`][readme]):

> “Velopack is an installation and auto-update framework for cross-platform applications. It's opinionated, extremely easy to use with zero config needed.”

That makes Velopack categorically different from a release orchestrator. It does not build arbitrary source projects, run test suites, infer release notes from Git history, or coordinate a full release train. It packages build output and owns the installed application's update protocol.

### Design philosophy

Velopack combines three ideas:

1. **A uniform release model.** Every platform has a NuGet-shaped full package containing a `.nuspec` manifest and `lib/app` payload, feed entries, and optional deltas.
2. **Native outer UX.** Windows gets a setup executable and optional MSI; macOS gets an app bundle/installer flow; Linux gets a self-updating AppImage.
3. **Language-neutral updater semantics.** The Rust implementation is exposed through native bindings so C#, C++, Node.js, Python, and Rust applications can use the same `check → download → apply/restart` lifecycle. The [samples tree][samples] exercises these languages and UI frameworks.

Classification and licensing are precise:

- **Control plane:** no. `vpk` can upload/download releases, but does not own compilation, tests, changelog policy, or a repository-wide release DAG.
- **App packager/updater:** yes; this is its core identity.
- **Format primitive:** more than one. NuGet-compatible zip packages, JSON feeds, and deltas are implementation primitives behind a complete installer/updater product.
- **OSS versus paid:** the reviewed repository is MIT-licensed. Hidden CLI commands and clients integrate with the optional `Velopack Flow` service ([`Program.cs`][program]), but the local packager, feeds, SDKs, and generic deployment backends are in the OSS tree and do not require that service. Commercial terms for Flow are outside the evidence in this repository.

## How it works

The smallest packaging call identifies the application, version, input directory, and entry executable:

```bash
vpk pack \
    --packId MyApp \
    --packVersion 2.1.0 \
    --packDir ./publish \
    --mainExe MyApp.exe \
    --channel stable
```

`PackageBuilder.RunCoreAsync` validates SemVer and target RID, selects a default channel, locates the entry executable, and loads the prior full release from the output directory ([`PackageBuilder.cs`][package-builder]). It then runs a staged graph:

1. Preprocess the input tree into the platform's application layout.
2. Code-sign application files on Windows/macOS when configured.
3. Build portable output.
4. Write a full `.nupkg`-style release containing `.nuspec`, `lib/app`, updater metadata, and ZIP relationship/content-type files.
5. Build the platform installer when applicable.
6. Compare against the previous full package and emit a delta.
7. Atomically move staged assets to the release directory and regenerate channel feeds.

At runtime, `UpdateManager` auto-locates the installed manifest, chooses either the embedded channel or `ExplicitChannel`, fetches a `VelopackAssetFeed`, selects the greatest full SemVer, and plans either a full or delta path ([`manager.rs`][manager]). Downloads go to `.partial`, are checksum-verified, then renamed. Delta chains are applied by the updater executable; any delta error falls back to the full package.

## Packaging analysis

### Input and staging

The input is an already-built application directory, not source code. `--packDir` supplies the file tree and `--mainExe` identifies the binary that calls the early startup hook. Regex exclusions default to PDBs plus built-in patterns such as nested `.nupkg`, `createdump`, and `.vshost` files ([`PackCommand.cs`][pack-command]). Platform preprocessors add launchers, manifests, icons, updater binaries, and native layouts.

Each packaging run uses a temporary staging directory and a `BuildAssets` bag. Artifacts are moved into the release directory only during post-processing. The existing release directory is also an input: the previous full release drives delta creation, and a same-or-greater version prompts before overwrite. This makes release-history retention part of correct packaging behavior.

### Outputs and targets

| Platform | User-facing output                                           | Update artifacts                                         |
| -------- | ------------------------------------------------------------ | -------------------------------------------------------- |
| Windows  | `*-Setup.exe`, portable `.zip`, optional machine-wide `.msi` | Full `.nupkg`, delta `.nupkg`, `releases.<channel>.json` |
| macOS    | `.app`-based portable zip and installer package              | Full package, delta package, channel feed                |
| Linux    | Portable/self-updating `.AppImage`                           | Full package, delta package, channel feed                |

Architectures and minimum OS versions are represented by RIDs. Output naming includes non-default channels. Linux intentionally has no separate installer—the AppImage is the portable application and updates by replacing itself, a behavior exercised in [`LinuxPackTests.cs`][linux-tests].

The full package's common structure is a useful format primitive, but consumers should treat it as Velopack's protocol rather than a generic ecosystem package. The `.nuspec` carries application/update metadata and `lib/app` carries the payload ([`PackageBuilder.GenerateNuspecContent`][package-builder]).

### Metadata and dependencies

Required metadata is deliberately small: package ID, SemVer, input directory, and main executable. Optional fields include title, authors, icon, Markdown release notes, channel, RID/minimum OS, installer text, shortcuts, Windows runtime prerequisites, Linux desktop categories, signing identities, and notarization profile. Release-note Markdown is stored verbatim and rendered to HTML at pack time.

Velopack packages the supplied dependency closure; it is not a system dependency solver. On Windows, `--framework` can tell Setup to install known prerequisites such as .NET Desktop or VC++ redistributables ([`WindowsPackCommand.cs`][windows-command]). On macOS/Linux, the producer is responsible for making the staged application runnable. There is no Debian/RPM dependency metadata because those are not Velopack targets.

### Install, upgrade, and uninstall

Windows Setup installs versioned app files under an application root, maintains a `current` path, creates configured shortcuts and uninstall metadata, invokes application hooks, and ships `Update.exe`. End-to-end tests install silently, update, verify callbacks and versions, then invoke `Update.exe --uninstall` ([`WindowsE2ETests.cs`][windows-e2e]). Optional MSI is a bootstrap/deployment option, not the update payload.

On macOS the packaged app integrates updater hooks and replacement/restart behavior. On Linux the AppImage remains portable: “installation” is moving/copying one file, upgrade replaces that AppImage, and uninstall is deleting it. The test suite verifies check/download/apply and `--autoupdate` across macOS, Linux, and Windows.

Application code controls user experience through startup hooks and `UpdateManager`: check now, download with progress, apply and restart, or wait for a process to exit before applying. Windows also exposes fast install/update/uninstall callbacks through `VelopackApp.Build().Run()`.

### Signing and trust

The update feed records both SHA-1 and SHA-256; runtime download logic verifies the package checksum before the `.partial` file becomes eligible for application ([`manager.rs`][manager]). Integrity therefore binds the downloaded package to feed metadata, while transport/source authentication still matters for protecting the feed itself.

Windows packaging can use embedded `signtool.exe` arguments, Azure Trusted Signing metadata, or a custom `--signTemplate`; trusted existing signatures are skipped and failures are fatal ([`CodeSign.cs`][code-sign]). macOS supports application and installer signing identities, entitlements, keychain selection, and a `notarytool` profile ([`OsxPackCommand.cs`][osx-command]). Linux AppImages are not given an equivalent integrated trust-policy layer in the reviewed commands.

Velopack does not claim a repository-level provenance or transparency system. A compromised feed publisher could replace feed hashes and packages together unless publication credentials, HTTPS, platform code signing, and hosting controls prevent it.

### Publication and discovery

The OSS `vpk` CLI has upload/download backends for:

- local directories;
- generic HTTP downloads;
- S3-compatible object stores;
- Azure Blob Storage;
- GitHub Releases;
- Gitea releases;
- GitLab through update-source support in the SDK/tests.

Object stores upload package files and regenerate/retain `releases.<channel>.json`; GitHub/Gitea clients create draft releases, upload assets, and publish them ([`GitHub.cs`][github-deploy], [`S3.cs`][s3-deploy]). `KeepMaxReleases` prunes hosted history for object-store backends. Velopack is not an app store or discovery catalog: users find the installer through the publisher's site/release page, and installed apps discover updates through their configured source.

### Updates and channels

A channel is embedded in each package manifest. Unless `ExplicitChannel` overrides it, an installed beta build continues reading beta; switching channels can permit a same-version or lower-version move when downgrade policy allows ([`UpdateOptions`][manager]). Feed selection chooses the newest full SemVer.

Delta planning is sequential. The manager finds a local full base, gathers all later delta assets through the target version, and uses them if the chain is present and within `MaximumDeltasBeforeFallback` (default 10). It verifies every delta, reconstructs a full target, and falls back to downloading the target full package on failure. This favors reliability over preserving bandwidth at all costs.

No server-side staged percentage algorithm exists in the generic feed itself. The feed API carries a staged user ID, and optional Flow integration can add service-side policy, but generic channels are publisher-controlled streams rather than a rollout control plane.

### Automation and CI

`vpk` is scriptable and available as a .NET tool/CLI; MSBuild integration (`Velopack.Build`) maps project properties into packaging options. CI normally builds each application's platform output, runs the matching platform packaging command, then uses an upload backend. Packaging constraints remain platform-sensitive: embedded Windows `signtool.exe`, MSI creation, Apple signing/notarization, and native bundle tooling require suitable hosts or custom signing commands.

The repository's own automation spans Cargo, .NET, Node, Python, and end-to-end install/update tests. Deployment tests fabricate installed layouts and assert that local, HTTP, S3, GitHub/Gitea/GitLab-style sources return the same update and SHA-256 ([`SourceTests.cs`][source-tests]).

### Supply chain and reproducibility

Strong integrity mechanics include SHA-256 in JSON assets, verification before rename/application, `.partial` downloads, exclusive update locks, atomic-ish staging/move boundaries, full-package fallback, platform code signing, and extensive end-to-end lifecycle tests. `Cargo.lock`, `package-lock.json`, and test fixtures pin much of Velopack's own build graph.

Packaging is not documented as byte-for-byte reproducible. ZIP metadata, native tool versions, signing timestamps/notarization, compression choices, and input directory metadata can differ. Feed metadata retains SHA-1 for compatibility alongside SHA-256. There is no generated SBOM, SLSA provenance, transparency log, or signed checksum manifest in the generic release flow. Producers should pin tool versions, preserve immutable release assets, sign platform binaries, and protect feed publication credentials.

### Extensibility and UX

Extensibility exists at several layers:

- `IUpdateSource`/Rust `UpdateSource` lets SDK consumers supply release feeds and downloads.
- C#, C++, Node.js, Python, and Rust bindings expose the same updater model.
- Custom HTTP headers support authenticated/private feeds.
- `--signTemplate` integrates external Windows signing systems.
- Platform hooks let application code react to install, update, obsolete-version, and uninstall events.
- Generic object stores and forge backends separate hosting from the update protocol.

The UX target is “one packaging command, a few startup/update calls.” Defaults derive platform channel names, create portable and installer outputs, and generate deltas when prior releases are retained. The cost of that simplicity is an opinionated layout/protocol and application integration requirement: the entry executable must run Velopack startup handling early.

## Strengths

- Complete pack/install/update lifecycle rather than installer generation alone.
- Shared updater semantics and bindings across several application languages.
- Full-package fallback makes delta failures recoverable.
- Explicit stable/beta-style channels and controlled channel switching.
- Multiple self-hosted publication backends; no required hosted service.
- Platform signing hooks and broad end-to-end lifecycle coverage.
- MIT-licensed core with no proprietary package format lock-in.

## Weaknesses

- Not a full release control plane: source builds, tests, changelogs, and release policy remain external.
- Uses its own NuGet-shaped update protocol rather than OS package managers on Linux/macOS.
- Linux distribution is AppImage-only; no `deb`, `rpm`, Flatpak, or native uninstall entry.
- Platform-sensitive packaging/signing complicates a single-host cross-platform CI pipeline.
- Feed hashes do not by themselves defend against compromise of feed publication.
- No built-in SBOM, signed provenance, transparency, or byte-reproducibility guarantee.
- Generic feeds provide channels, not sophisticated staged-rollout governance.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                | Trade-off                                                        |
| ----------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------- |
| Package prebuilt directories                    | Remain language/framework agnostic                       | Compilation and dependency closure are external responsibilities |
| Use a common full-package/feed protocol         | Share updater logic across platforms and bindings        | Introduces a Velopack-specific deployment protocol               |
| Generate delta from retained prior full release | Reduce bandwidth with simple sequential history          | Release history must be available; long chains can be costly     |
| Fall back from delta to full package            | Prefer a successful update over bandwidth savings        | Requires hosting and downloading full packages too               |
| Embed channel in installed manifest             | Keep users on the stream they installed                  | Switching channels needs explicit downgrade/lateral-move policy  |
| Use platform-native outer installers/bundles    | Deliver familiar installation UX                         | Packaging and signing remain platform-specific                   |
| Keep hosting pluggable/self-hosted              | Avoid mandatory service lock-in                          | Publishers operate feed availability and credential security     |
| Expose early startup hooks                      | Make atomic replacement and lifecycle callbacks reliable | Every application must integrate bootstrap code correctly        |

## Sources

- [Repository and exact reviewed tree][revision]
- [`README.md` — positioning, license badge, and feature claims][readme]
- [`PackageBuilder.cs` — staging, full package, installer, delta, and feed mechanics][package-builder]
- [`PackCommand.cs` — common CLI input and output controls][pack-command]
- [`WindowsPackCommand.cs` — prerequisites, setup, MSI, and signing options][windows-command]
- [`OsxPackCommand.cs` — installer, signing, entitlements, and notarization options][osx-command]
- [`manager.rs` — feed selection, channels, deltas, checksums, and apply lifecycle][manager]
- [`CodeSign.cs` — Windows trust/signing execution][code-sign]
- [`GitHub.cs` and `S3.cs` — publication adapters][github-deploy]
- [`WindowsE2ETests.cs`, `LinuxPackTests.cs`, and `SourceTests.cs` — lifecycle and source tests][windows-e2e]
- [Samples tree — supported language/framework integrations][samples]

<!-- References -->

[repo]: https://github.com/velopack/velopack
[docs]: https://docs.velopack.io/
[revision]: https://github.com/velopack/velopack/tree/9ba468337e367c59db339828b59c8a20a0f6ea90
[readme]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/README.md
[program]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Vpk/Program.cs
[package-builder]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Packaging/PackageBuilder.cs
[pack-command]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Vpk/Commands/Packaging/PackCommand.cs
[windows-command]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Vpk/Commands/Packaging/WindowsPackCommand.cs
[osx-command]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Vpk/Commands/Packaging/OsxPackCommand.cs
[manager]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/lib-rust/src/manager.rs
[code-sign]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Packaging.Windows/CodeSign.cs
[github-deploy]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Deployment/GitHub.cs
[s3-deploy]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/src/vpk/Velopack.Deployment/S3.cs
[windows-e2e]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/test/Velopack.Pack.Tests/WindowsE2ETests.cs
[linux-tests]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/test/Velopack.Pack.Tests/LinuxPackTests.cs
[source-tests]: https://github.com/velopack/velopack/blob/9ba468337e367c59db339828b59c8a20a0f6ea90/test/Velopack.Deployment.Tests/SourceTests.cs
[samples]: https://github.com/velopack/velopack/tree/9ba468337e367c59db339828b59c8a20a0f6ea90/samples
