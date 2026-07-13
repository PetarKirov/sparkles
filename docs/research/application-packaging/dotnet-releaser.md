# dotnet-releaser (.NET)

An open-source release control plane that wraps the .NET SDK, MSBuild packaging targets, GitHub, NuGet, Homebrew, and Scoop; it can create application archives and Linux packages, but it is not an application updater or a new package-format primitive.

| Field             | Value                                                                                                     |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| Language          | C# / .NET                                                                                                 |
| License           | BSD-2-Clause                                                                                              |
| Repository        | [xoofx/dotnet-releaser][repo]                                                                             |
| Documentation     | [User guide][guide]                                                                                       |
| Reviewed revision | [`a7f1a62decd89e97297d55e6563fc246cac23d71`][revision] (`0.22.0`)                                         |
| Category          | **Release control plane**, with an app-packaging stage; **not** an updater and **not** a format primitive |
| Product model     | Fully OSS; no paid edition or hosted service is identified in the repository                              |
| Primary ecosystem | .NET libraries, .NET global tools, and self-contained .NET applications                                   |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

`dotnet-releaser` turns a solution or project plus a small `dotnet-releaser.toml` file into one release pipeline: restore, build, test, coverage, NuGet packing, runtime-specific `dotnet publish`, application packaging, release-note generation, and publication. Its own summary is explicit ([`readme.md`][readme]):

> “`dotnet-releaser` is an all-in-one command line tool that fully automates the release cycle of your .NET libraries and applications to NuGet and GitHub by **building**, **testing**, **running coverage**, **cross-compiling**, **packaging**, **creating release notes from PR/commits** and **publishing**.”

This breadth determines the classification. The tool orchestrates existing compilers, package targets, registries, and package managers. Its `PackPlatform` method selects MSBuild targets for `deb`, `rpm`, `zip`, and `tar`, while the imported [`Packaging.Targets` package][targets] implements the native Linux package creation. It therefore has a real app-packaging stage, but its architectural center is the release control plane rather than an installer runtime.

### Design philosophy

The project favors opinionated defaults that can be disabled or overridden. With the default profile it adds Windows `zip`, Linux `rpm`/`deb`/`tar`, and macOS `tar` jobs for two architectures each ([`ReleaserConfiguration.Initialize`][configuration]). The same config and command graph run locally or in GitHub Actions. Publication is tag-aware: package version and optional `github.version_prefix` select the GitHub release, while the `run` command decides whether the current event should build or publish.

The boundary is important:

- **Control plane:** yes—build, test, coverage, changelog, package, and publication policy are coordinated together.
- **App packager/updater:** package creator, yes; installer/updater runtime, no. `deb`/`rpm` delegate lifecycle behavior to the OS package manager; archives have no managed lifecycle.
- **Format primitive:** no—it consumes .NET/MSBuild and `Packaging.Targets` rather than defining a reusable archive or update protocol.
- **OSS versus paid:** the code and tool are BSD-2-Clause. There is no paid feature gate in the reviewed tree.

## How it works

A typical project points at one or more `.sln`, `.slnx`, `.csproj`, `.fsproj`, or `.vbproj` files:

```toml
[msbuild]
project = "src/MyApp.slnx"

[github]
user = "example"
repo = "my-app"
version_prefix = "v"

[[pack]]
rid = ["linux-x64", "linux-arm64"]
kinds = ["deb", "rpm", "tar"]

[nuget]
trusted_publishing = true
user = "example"
```

`ReleaserConfiguration.From` deserializes TOML with snake-case property names, resolves config-relative project and artifact paths, and then injects the default packaging profile where a custom `rid` has not already claimed a target ([`ReleaserConfiguration.cs`][configuration]). Project evaluation gathers MSBuild package metadata and identifies packable libraries and executables. The app then restores and invokes dedicated injected targets:

1. Libraries and tools run `Pack`; executable projects are marked `PackAsTool=true` for NuGet.
2. Every application `rid` is explicitly restored before packaging.
3. `deb`/`rpm` invoke `CreateDeb`/`CreateRpm` through `DotNetReleaserPublishAndCreate*`; `zip`/`tar` invoke `Publish`, then the process creates the archive itself.
4. The resulting artifact is copied into `artifacts-dotnet-releaser`, optionally renamed by regex rules, and hashed with SHA-256 ([`ReleaserApp.AppPackaging.cs`][app-packaging]).
5. GitHub publication creates or updates a release, uploads assets, and optionally writes Homebrew formulae and Scoop manifests to separate repositories. NuGet publication executes `dotnet nuget push`.

## Packaging analysis

### Input and staging

The primary inputs are evaluated .NET solutions/projects, their transitive NuGet restore graph, Git history/tags, and TOML policy. Packaging does not ingest an arbitrary ready-to-ship directory. Instead it calls `dotnet publish` for each runtime identifier and packages the resulting publish directory. For multi-targeted projects it deliberately chooses the highest target framework ([`PackPlatform`][app-packaging]).

The artifact directory is treated as owned output: without `--force`, an existing directory aborts the build; with `--force`, it is deleted and recreated. This avoids silently mixing releases but makes it unsuitable as an incremental staging cache.

### Outputs and targets

The default matrix is:

| Target                     | Default outputs                                        |
| -------------------------- | ------------------------------------------------------ |
| `win-x64`, `win-arm64`     | `.zip`                                                 |
| `linux-x64`, `linux-arm64` | `.deb`, `.rpm`, `.tar.gz`                              |
| `osx-x64`, `osx-arm64`     | `.tar.gz`                                              |
| Packable library           | `.nupkg` and, when produced, `.snupkg`                 |
| Packable executable        | NuGet global-tool package plus configured app packages |

Custom `[[pack]]` entries select arbitrary .NET runtime identifiers and any supported kind. `setup` exists in the enum/switch but is marked “not yet supported” in `PackPlatform`; it should not be counted as a current Windows installer. This is cross-compilation in the .NET publish sense, not a claim that every native dependency can be built on every host.

### Metadata and dependencies

Project metadata—package ID/name, version, description, project URL, license expression, output type, assembly name, and target frameworks—is read from MSBuild rather than duplicated in TOML ([`dotnet-releaser.targets`][targets]). Release notes link back to the configured GitHub version. TOML supplies release/publishing policy, runtime matrices, regex renamers, changelog templates, and service settings.

Native package dependencies are explicit and limited to `deb` and `rpm`. `[[deb.depends]]` and `[[rpm.depends]]` become the dependency properties consumed by `Packaging.Targets`; there is no ELF scanning or automatic mapping from shared libraries to distribution packages. NuGet dependencies remain the responsibility of the project and its restore/pack graph.

### Install, upgrade, and uninstall

`dotnet-releaser` does not install its application outputs and embeds no updater client:

- `deb` and `rpm` lifecycle behavior comes from the distribution package manager and the generated package metadata/scripts.
- Optional systemd packaging can create a unit, request a service user, and ask `Packaging.Targets` to install the service, but only for `deb`/`rpm` ([`PackPlatform`][app-packaging]).
- Homebrew and Scoop manifests hand installation and subsequent upgrades to those package managers.
- `zip` and `tar.gz` are portable archives with no standardized uninstall or update state.
- NuGet packages and global tools use NuGet/.NET tooling lifecycle commands.

Consequently, there is no first-party staged rollout, delta update, rollback, or in-app update API.

### Signing and trust

The reviewed source has no integrated application code-signing, macOS notarization, package-signing, or provenance-attestation stage. Trust is instead delegated to downstream mechanisms: HTTPS and GitHub for release assets, NuGet authentication, distribution packaging conventions, and whatever signing the project performs before or around `dotnet-releaser`.

Authentication is stronger than a permanently configured NuGet key when `nuget.trusted_publishing=true`: GitHub Actions OIDC is exchanged for a short-lived NuGet API key, and the key is passed to `dotnet nuget push` via environment variables rather than command-line arguments ([`ReleaserApp.NuGet.cs`][nuget]). A classic `--nuget-token` still takes precedence. GitHub/Homebrew/Scoop publication may require separate tokens with broader repository permissions.

### Publication and discovery

The publication surface is unusually broad:

- GitHub Releases receive generated notes and selected app artifacts.
- NuGet receives `.nupkg`/`.snupkg` packages.
- Homebrew gets a generated tap repository and `Formula/<app>.rb` when tar outputs exist.
- Scoop gets a generated bucket and manifest when a Windows zip exists.
- Coverage badges may be written to a GitHub Gist.

The GitHub implementation refuses to replace an existing asset unless `--force-upload` is given and retries failed uploads ([`GitHubDevHosting.cs`][github-hosting]). Discovery is therefore delegated to GitHub release pages, NuGet search, Homebrew taps, and Scoop buckets; no proprietary catalog is introduced.

### Updates and channels

There is no shared updater protocol or channel abstraction. Version tags and Git branches control release automation; NuGet can publish draft packages from configured main branches; GitHub can hold draft releases. Homebrew/Scoop and Linux repositories may provide package-manager upgrades after publication, but `dotnet-releaser` itself neither polls nor applies them. Prerelease semantics follow NuGet versions and repository conventions rather than a dedicated stable/beta channel model.

### Automation and CI

The CLI separates `build`, `publish`, `run`, `changelog`, and `new`. `run` is explicitly GitHub-Actions-oriented: it inspects event/branch/tag state and publishes only when policy permits. The documented workflow uses a full checkout (`fetch-depth: 0`), installs the .NET SDK and global tool, grants `contents: write` for GitHub publication and `id-token: write` for NuGet trusted publishing, then executes one command ([`readme.md`][readme]).

Because local and CI execution share the same TOML and command graph, failures can be reproduced locally without translating a CI-only action. The trade-off is concentration: build, tests, coverage, packaging, changelog API calls, and publishing all share one process and configuration.

### Supply chain and reproducibility

Positive controls include centrally pinned tool dependencies in the project source, explicit restore per RID, SHA-256 calculation for every app artifact, avoidance of duplicate NuGet pushes, OIDC-backed short-lived NuGet credentials, and refusal to mix an old artifacts directory into a new run. Tests inspect archive names, executable modes, package metadata, systemd units, and declared Debian dependencies ([`BasicTests.cs`][basic-tests]).

The SHA-256 is retained in `AppPackageInfo` and used by generated Homebrew/Scoop metadata; the GitHub release path itself uploads bytes without a separate signed checksum manifest. Reproducibility is not an end-to-end promise: NuGet restore can resolve external content, archive timestamps and native package tooling can vary, release notes depend on mutable GitHub API state, and signing/attestation are out of scope. Coverage has an optional `deterministic_report` setting, but that does not make application packages reproducible.

### Extensibility and UX

Extensibility is configuration-led: custom MSBuild properties, arbitrary RIDs, per-pack output kinds, artifact renamers, changelog filters/templates, alternate GitHub Enterprise and NuGet endpoints, systemd sections, and opt-out switches for most stages. The `IDevHosting` seam abstracts hosting internally, but the shipped implementation is GitHub; there is no documented plugin loader for third-party publishers or formats.

UX is optimized for the common .NET/GitHub path: `dotnet releaser new` discovers the solution and Git remote, defaults fill in the matrix, grouped terminal output exposes stages, and a single CI command covers the release. The same opinionation is a boundary for non-GitHub forges, bespoke installers, signing, and update protocols.

## Strengths

- One config and CLI span build, test, coverage, NuGet, native app packages, changelog, and publication.
- Reads canonical metadata from MSBuild instead of duplicating it.
- Sensible multi-architecture defaults with targeted overrides.
- First-class GitHub Release, NuGet trusted publishing, Homebrew, and Scoop flows.
- Generates SHA-256 values and exercises native package contents in tests.
- Fully OSS with no hosted-control-plane dependency.

## Weaknesses

- Strongly coupled to .NET, MSBuild, GitHub, and the external `Packaging.Targets` implementation.
- No first-party app installer/updater runtime, channels, deltas, rollback, or staged rollout.
- No integrated Windows/macOS/Linux signing, notarization, SBOM, or provenance attestation.
- Linux dependency metadata is manual; archives have no lifecycle semantics.
- `setup` is present but unsupported, so Windows output is a zip unless another tool is added.
- No public plugin protocol for adding package formats or hosting providers.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                          | Trade-off                                                                      |
| ----------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Wrap the complete .NET release cycle                  | One local/CI workflow and one source of release policy             | Broad coupling and a larger failure domain                                     |
| Reuse MSBuild and `Packaging.Targets`                 | Preserve project metadata and avoid reimplementing native packages | Package behavior depends on an external target package                         |
| Default to self-contained, single-file app publishing | Produce portable executables for many RIDs                         | Larger artifacts; trimming/ReadyToRun can affect compatibility and determinism |
| Publish by package-version tag                        | Align source, NuGet, notes, and GitHub assets                      | Retagging or mismatched version metadata blocks the intended flow              |
| Generate package-manager manifests                    | Gain Homebrew/Scoop discovery and upgrades cheaply                 | Requires broader cross-repository tokens and does not unify update behavior    |
| Keep app updating out of scope                        | Remain a release-time tool with no app runtime dependency          | Applications need package managers or a separate updater                       |
| Offer OIDC NuGet trusted publishing                   | Reduce long-lived secret exposure                                  | Primarily benefits GitHub Actions/NuGet.org policy-compatible workflows        |

## Sources

- [Repository and exact reviewed tree][revision]
- [`readme.md` — positioning, defaults, workflow, and license][readme]
- [`doc/readme.md` — complete configuration and CLI guide][guide]
- [`ReleaserConfiguration.cs` — TOML loading and default target matrix][configuration]
- [`ReleaserApp.AppPackaging.cs` — restore, package dispatch, staging, and SHA-256][app-packaging]
- [`dotnet-releaser.targets` — MSBuild metadata and packaging-target integration][targets]
- [`ReleaserApp.Publishing.cs` — publication orchestration][publishing]
- [`ReleaserApp.NuGet.cs` — NuGet packing, OIDC, and push][nuget]
- [`GitHubDevHosting.cs` — releases, assets, Homebrew, and Scoop][github-hosting]
- [`BasicTests.cs` — package-content integration tests][basic-tests]

<!-- References -->

[repo]: https://github.com/xoofx/dotnet-releaser
[revision]: https://github.com/xoofx/dotnet-releaser/tree/a7f1a62decd89e97297d55e6563fc246cac23d71
[readme]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/readme.md
[guide]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/doc/readme.md
[configuration]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/dotnet-releaser/Configuration/ReleaserConfiguration.cs
[app-packaging]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/dotnet-releaser/ReleaserApp.AppPackaging.cs
[targets]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/dotnet-releaser/dotnet-releaser.targets
[publishing]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/dotnet-releaser/ReleaserApp.Publishing.cs
[nuget]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/dotnet-releaser/ReleaserApp.NuGet.cs
[github-hosting]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/dotnet-releaser/DevHosting/GitHubDevHosting.cs
[basic-tests]: https://github.com/xoofx/dotnet-releaser/blob/a7f1a62decd89e97297d55e6563fc246cac23d71/src/DotNetReleaser.Tests/BasicTests.cs
