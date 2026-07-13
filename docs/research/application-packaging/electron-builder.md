# electron-builder (Electron application packager and publisher)

An MIT-licensed Electron-specific pipeline that assembles application bundles, drives
native package backends, emits updater metadata, and can publish artifacts, while
leaving source compilation and the release CI graph to the application author.

| Field               | Value                                                                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Language            | TypeScript, plus downloaded native helper toolsets                                                                                      |
| License             | MIT                                                                                                                                     |
| Repository          | [electron-userland/electron-builder][repo]                                                                                              |
| Documentation       | [Checked-in documentation][docs] · [generated configuration schema][schema]                                                             |
| Reviewed source     | [`39df92fd14d9a3788add09a3963028a48eed176e`][revision] (`electron-builder` `27.0.0-alpha.5`)                                            |
| Category            | **Electron application packager/publisher** with updater metadata; not a general release control plane                                  |
| Hosts and targets   | Linux, macOS, Windows; target and trust operations have different native-host requirements                                              |
| OSS / paid boundary | Core code is MIT with no paid electron-builder tier; integrations include source-available Keygen and credentialed Azure/Apple services |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Layer boundary:** electron-builder performs both Electron **application assembly**
> and **artifact construction**. Format targets remain distinct backends: FPM, Snapcraft,
> Flatpak tooling, NSIS, MSI/MSIX/AppX helpers, `hdiutil`, and `productbuild` own important
> native mechanics. `electron-updater` is a separate runtime library, publishing is an
> optional final phase, and users still author the CI matrix that builds and collects all
> operating-system outputs.

## Overview

### What it solves

The project begins with an Electron application and its production dependency tree. It
rebuilds native Node modules for Electron, downloads the Electron runtime, copies and
optionally archives application files, applies metadata and fuses, signs the assembled
application, and passes that staged application to selected targets. Its README describes
this scope as:

> “Pack in a distributable format (already packaged app).”

— [`README.md`][readme]. The same source lists native dependency compilation, code
signing, auto-update-ready packaging, target formats, and artifact publishing, but these
are separate pipeline layers rather than one indistinguishable installer operation.

### Design philosophy

`Configuration` is a broad shared model with `mac`, `mas`, `win`, `linux`, target-specific
options, publish providers, and lifecycle hooks ([`configuration.ts`][configuration]).
The generated `scheme.json` exposes that model to editors and validators. `Packager`
normalizes project metadata, selects a `PlatformPackager`, assembles one application per
platform/architecture, and lets target implementations consume the shared staged tree
([`packager.ts`][packager]).

The design favors batteries-included automation over hermeticity. Helper executables are
downloaded on demand; native backends and platform services are invoked where needed;
hooks may run arbitrary user code; and publication can happen as artifacts are emitted.
That produces a compact application configuration, but does not erase platform or CI
boundaries.

## How it works

A representative configuration separates files, artifact targets, updater discovery, and
publication policy:

```yaml
appId: com.example.demo
files:
  - dist/**
extraResources:
  - assets/**
mac:
  target: [dmg, zip]
win:
  target: [nsis]
linux:
  target: [AppImage, deb]
publish:
  provider: github
  releaseType: draft
```

The source-level execution graph is:

```text
project/package metadata + Configuration
  -> install/rebuild production native dependencies
  -> prepare Electron runtime application directory
  -> files / ASAR / extraResources / extraFiles
  -> metadata, fuses, hooks, sanity checks
  -> sign assembled application
  -> target backends build artifacts
  -> blockmaps + channel YAML
  -> optional provider publishers
```

`PlatformPackager.doPack()` creates the runtime stage before target construction: it
prepares the framework directory, copies app files and extra resources, emits hooks,
checks the package, flips Electron fuses, and signs immediately before targets consume it
([`platformPackager.ts`][platform-packager]). `Packager.doBuild()` then schedules target
instances by platform and architecture and finalizes them after shared stage readers have
finished ([`packager.ts`][packager]).

## Analysis dimensions

### Input and staging

Inputs are an Electron runtime version, application `package.json`, production Node
modules, `files`, `extraResources`, `extraFiles`, icons, metadata, and target options.
`files` enters the application resource tree or `app.asar`; `extraResources` enters the
runtime resources directory; `extraFiles` enters the platform bundle/content root
([`PlatformSpecificBuildOptions.ts`][platform-options]). Native dependencies can be
rebuilt, built from source, or rebuilt through `node-gyp`; hooks such as `beforeBuild`,
`beforePack`, `afterPack`, and `afterSign` can alter the process
([`configuration.ts`][configuration]).

Assembly is not a maker backend. The Electron framework implementation creates the
platform application layout first; target classes then archive or install that result.
ASAR integrity data and Electron fuse settings can bind Electron to the staged
`app.asar`, but only when configured coherently ([`ElectronFramework.ts`][electron-framework],
[`FuseOptionsV1.ts`][fuse-options]).

### Outputs and target matrix

| Platform | Assembled application       | Artifact targets observed at the reviewed revision                                                       |
| -------- | --------------------------- | -------------------------------------------------------------------------------------------------------- |
| Linux    | unpacked Electron directory | AppImage, Snap, Flatpak, `deb`, `rpm`, `pacman`, `apk`, FreeBSD, `p5p`, shell package, archives          |
| Windows  | unpacked Electron directory | NSIS installer/web installer/portable, MSI, wrapped MSI, MSIX, AppX, optional Squirrel.Windows, archives |
| macOS    | `.app` or MAS application   | DMG, PKG, MAS/MAS development application, ZIP and other archives                                        |

Linux defaults to Snap plus AppImage, Windows defaults to NSIS, and macOS defaults come
from the selected Electron framework ([`linuxPackager.ts`][linux-packager],
[`winPackager.ts`][win-packager], [`macPackager.ts`][mac-packager]). Archives are common
targets; native packages retain their own lifecycle semantics. A DMG is transport for an
app bundle, while NSIS/MSI are installers and Flatpak/Snap are sandbox/repository-oriented
formats. electron-builder does not make them equivalent.

### Metadata and dependencies

Shared identity includes `appId`, product/executable names, application/build versions,
author, description, copyright, icons, file associations, protocols, categories, and
artifact-name patterns. Backends translate these into `Info.plist`, Windows resources and
installer identities, desktop entries, or Linux package fields. `scheme.json` is generated
from TypeScript option declarations and schema validation has dedicated tests
([`scheme.json`][schema], [`schemaValidatorTest.ts`][schema-test]).

Production Node dependencies are vendored into the Electron application; development
dependencies are excluded. Native modules are rebuilt against Electron. Linux native
packages additionally model system dependencies through FPM/Snap/Flatpak configuration;
archives, DMG, NSIS, and portable applications instead carry the supplied dependency
closure. There is no one cross-platform system-dependency solver.

### Installation, upgrade, and uninstall

Lifecycle ownership belongs to each output. NSIS emits installer/uninstaller behavior;
MSI delegates transactions to Windows Installer; `deb`/`rpm`/`pacman` delegate file
ownership to native package managers; Snap and Flatpak delegate deployment to their
systems; AppImage and archives remain replaceable files; a DMG normally carries a
copy-installed `.app`.

The optional `electron-updater` adds an application-controlled upgrade path. It has
platform implementations for NSIS, macOS, AppImage, and Linux packages. It downloads and
verifies the artifact described by channel metadata, can use blockmap-based differential
downloads, and delegates final replacement/installer execution to the platform updater
([`AppUpdater.ts`][app-updater], [`NsisUpdater.ts`][nsis-updater]). This runtime is not
the same thing as building an installer, and applications must integrate it.

### Signing and platform trust

macOS assembly delegates code signing to `@electron/osx-sign`; notarization delegates to
`@electron/notarize` after credentials are derived from Apple ID, API-key, or keychain
profile environment variables ([`macPackager.ts` notarization path][mac-notary],
[`MacTargetHelper.ts` credential path][mac-helper]). PKG and application artifacts are notarized at their
appropriate stages ([`pkg.ts` PKG path][pkg-notary]). Apple signing/notarization
requires macOS and Apple services.

Windows supports `signtool.exe`, `osslsigncode`, Azure Trusted Signing, HSM, and PKCS#11
paths depending on host and configuration ([`windowsCodeSign.ts`][win-sign]). The NSIS
updater can additionally verify that a downloaded installer's publisher matches the
installed application's publisher. Update YAML uses SHA-512; hashes bind artifacts to
metadata but do not replace platform signatures or protect a compromised metadata
publisher.

### Publication and discovery

`PublishManager` receives artifact events, resolves publish configuration, generates
runtime `app-update.yml`, builds update-info files, and schedules uploads
([`PublishManager.ts`][publish-manager]). Concrete upload publishers cover GitHub,
GitLab, Bitbucket, S3-compatible storage/Spaces, Keygen, and Snap Store
([`electron-publish`][publisher-tree]). Their adapters are OSS, but the destinations are
external integrations rather than an electron-builder paid tier: the project describes
Keygen as source-available, while Azure Trusted Signing and Apple notarization accept
external account/profile credentials ([project README][keygen-readme], [Azure
configuration schema][azure-schema], [`MacTargetHelper.ts`][mac-helper]). This page does
not classify the pricing or terms of other stores and hosted providers. A `generic`
provider describes updater hosting but
is deliberately not uploaded by the built-in manager; custom providers require a loaded
publisher extension.

Publishing means uploading release assets or store submissions; it does not register
Homebrew, WinGet, APT, or other community-catalog manifests. Nor does it build source,
coordinate tests, fan artifacts into a release manifest, or announce a release.

### Updates and release channels

For eligible artifacts, `createUpdateInfoTasks()` writes channel YAML files whose names
include platform and architecture suffixes where required. They contain version, files,
SHA-512, release notes/date, and backend-specific blockmap
information ([`updateInfoBuilder.ts`][update-info]). With
`generateUpdatesFilesForAllChannels`, stable metadata may also populate beta and alpha;
otherwise only the configured channel is written. `publishAutoUpdate: false` suppresses
publishing that metadata.

`electron-updater` resolves channel files from provider implementations, compares SemVer,
supports explicit channel changes/downgrades, staged percentages, cached downloads, and
full-download fallback when differential download fails ([`AppUpdater.ts`][app-updater]).
This is client-side update policy over publisher-controlled metadata, not a hosted rollout
control plane.

### Automation and CI

The CLI supports target/architecture selection and publish policies (`onTag`,
`onTagOrDraft`, `always`, `never`). Credentials come from environment variables and
provider configuration. Pull-request publishing is skipped by default, with an explicit
warning when forced ([`PublishManager.ts`][publish-manager]).

Upstream's own workflow uses separate Ubuntu, Windows, and macOS test jobs and runs Linux
tests inside a Wine/Mono builder image ([`test.yaml`][workflow]). That demonstrates the
actual boundary: electron-builder supplies commands and Docker images, not a consumer
release workflow. Application authors decide native runners, secrets, artifact fan-in,
tag policy, and publication ordering. macOS builds are rejected on Windows
([`packager.ts` host guard][mac-host-guard]), while Apple signing/notarization needs macOS;
some Windows and Linux paths can cross-package through Wine, bundled tools, VMs, or
containers, but AppX/MSIX and trust paths retain specific host/tool restrictions
([AppX/MSIX schema][appx-schema], [`MacTargetHelper.ts`][mac-helper]).

### Supply-chain evidence and reproducibility

The repository pins JavaScript dependencies in `pnpm-lock.yaml`, pins GitHub Actions by
commit in its workflows, validates configuration, and tests packaging across all three
hosts. Artifacts carry SHA-512 update hashes and differential blockmaps. Signing and
notarization add platform trust.

It does not emit an SBOM, SLSA provenance, or a signed release manifest. Packaging is not
claimed byte-reproducible: downloaded Electron/helper toolsets, source mtimes, archive and
installer generators, signing timestamps, notarization, release dates, hooks, and native
rebuilds can vary. Consumers must pin electron-builder/Electron, cache or mirror helper
inputs, constrain hooks, and generate attestations in their own CI
([`ElectronFramework.ts`][electron-framework], [`PublishManager.ts`][publish-manager],
[upstream workflow][workflow]).

### Extensibility and UX

Users can extend lifecycle hooks, file transforms, artifact naming, target templates and
options, custom signing, publish providers, and programmatic APIs. Targets implement a
common `Target` contract, while publishers implement `Publisher`; adding a first-class
backend still normally means code/package integration rather than a declarative unknown
target.

The UX strength is one configuration spanning assembly, native artifacts, update
metadata, and upload. Its sharp edge is the same breadth: keys that appear adjacent belong
to different trust and lifecycle layers, and successful cross-platform release still
requires understanding each backend's native tools.

## Strengths

- Broad Electron-specific assembly and artifact coverage across all desktop platforms.
- Native-module rebuild, ASAR, Electron fuses, metadata, and packaging are integrated.
- Platform code signing/notarization and updater metadata are built into the pipeline.
- `electron-updater` provides checksummed and differential application updates.
- Multiple OSS publishers support common release hosts and object stores.
- Schema, tests, hooks, and programmatic APIs make a large option surface usable.

## Weaknesses

- Not a general release control plane; consumer CI, testing, fan-in, and catalogs remain external.
- Platform uniformity is partial: native hosts, VMs, Wine, containers, SDKs, and credentials differ.
- Broad downloaded-tool use and arbitrary hooks weaken hermeticity and reproducibility.
- No built-in SBOM, signed provenance, transparency log, or cross-target release manifest.
- Updater checksums depend on trustworthy publication of the channel metadata.
- Format-specific lifecycle and dependency semantics cannot be normalized by the shared config.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                          | Trade-off                                                  |
| --------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| Assemble Electron apps before invoking targets      | Reuse one prepared runtime tree across artifacts   | A target may still require native mutation and tools       |
| One generated configuration schema                  | Centralize identity and editor validation          | Large surface can obscure backend-specific meaning         |
| Download helper toolsets on demand                  | Reduce host setup and enable some cross-packaging  | Network/cache provenance becomes part of the build         |
| Rebuild production native modules                   | Make packaged modules ABI-compatible with Electron | Requires compiler toolchains and can be nondeterministic   |
| Sign the app before outer artifact construction     | Preserve nested-code trust ordering                | Signing and packaging cannot be host-neutral               |
| Generate updater metadata from artifact events      | Keep names, hashes, blockmaps, and uploads aligned | Metadata is coupled to supported targets/providers         |
| Keep `electron-updater` as a separate runtime       | Let applications choose update UX and policy       | Application code must integrate and operate the feed       |
| Publish opportunistically through provider adapters | Offer a short build-to-release path                | This is not transactional multi-host release orchestration |
| Expose hooks and custom signing                     | Accommodate uncommon build/trust systems           | Hooks escape schema guarantees and hermetic execution      |

## Sources

- [Local clone `$REPOS/js/electron-builder` at the exact reviewed revision][revision]
- [`README.md` — stated scope, targets, signing, publishing, and requirements][readme]
- [`configuration.ts` and `scheme.json` — option model and schema][configuration]
- [`packager.ts` and `platformPackager.ts` — assembly and target orchestration][packager]
- [`linuxPackager.ts`, `winPackager.ts`, and `macPackager.ts` — target dispatch][linux-packager]
- [`PublishManager.ts` and `updateInfoBuilder.ts` — publication and updater metadata][publish-manager]
- [`electron-updater` sources — client update, hash, channel, and differential behavior][app-updater]
- [Tests and GitHub Actions workflow — schema and native-host matrix][workflow]

<!-- References -->

[repo]: https://github.com/electron-userland/electron-builder
[revision]: https://github.com/electron-userland/electron-builder/tree/39df92fd14d9a3788add09a3963028a48eed176e
[docs]: https://github.com/electron-userland/electron-builder/tree/39df92fd14d9a3788add09a3963028a48eed176e/website/docs
[readme]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/README.md
[configuration]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/configuration.ts
[schema]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/scheme.json
[schema-test]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/test/src/schemaValidatorTest.ts
[packager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/packager.ts
[platform-packager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/platformPackager.ts
[platform-options]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/options/PlatformSpecificBuildOptions.ts
[linux-packager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/linuxPackager.ts
[win-packager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/winPackager.ts
[mac-packager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/macPackager.ts
[mac-sign]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/codeSign/mac/macCodeSign.ts
[mac-helper]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/targets/mac/MacTargetHelper.ts#L282-L335
[mac-notary]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/macPackager.ts#L441-L462
[pkg-notary]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/targets/mac/pkg.ts#L100-L112
[win-sign]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/codeSign/win/windowsCodeSign.ts
[publish-manager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/publish/PublishManager.ts
[update-info]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/publish/updateInfoBuilder.ts
[publisher-tree]: https://github.com/electron-userland/electron-builder/tree/39df92fd14d9a3788add09a3963028a48eed176e/packages/electron-publish/src
[app-updater]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/electron-updater/src/AppUpdater.ts
[nsis-updater]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/electron-updater/src/NsisUpdater.ts
[workflow]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/.github/workflows/test.yaml
[electron-framework]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/electron/ElectronFramework.ts#L45-L54
[fuse-options]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/options/FuseOptionsV1.ts#L3-L15
[mac-host-guard]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/packager.ts#L469-L472
[appx-schema]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/scheme.json#L8550-L8610
[keygen-readme]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/README.md#L33-L38
[win-sign-manager]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/codeSign/win/signManager.ts#L20-L30
[azure-schema]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/scheme.json#L8190-L8210
