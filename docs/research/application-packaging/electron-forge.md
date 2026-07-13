# Electron Forge (Electron build and packaging toolkit)

An MIT-licensed Electron toolkit that scaffolds, develops, assembles, makes, and publishes
applications through a small core and replaceable maker, publisher, and plugin packages.

| Field               | Value                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| Language            | TypeScript                                                                                     |
| License             | MIT                                                                                            |
| Repository          | [electron/forge][repo]                                                                         |
| Documentation       | [Repository README][readme] · [package-level maker and publisher docs][packages]               |
| Reviewed source     | [`fc5fb4d4269cbce909fc59f570b8aa1e1add4090`][revision] (`@electron-forge/core` `7.11.2`)       |
| Category            | **Electron application packager toolkit** with publishers; not a general release control plane |
| Hosts and targets   | Linux, macOS, Windows; each maker declares host support and may require external tools         |
| OSS / paid boundary | Core, official makers, plugins, and publishers in the reviewed repository are MIT-licensed OSS |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Layer boundary:** Forge's `package` phase delegates Electron app assembly and signing
> to `@electron/packager`. Its `make` phase passes that assembled application to independent
> **maker backends**. Its `publish` phase passes maker-returned paths to independent
> **publisher backends**. Auto-update protocols belong to particular makers or external
> application libraries; Forge has no universal updater or release service.

## Overview

### What it solves

Forge standardizes an Electron project's path from template through local development to
release artifacts. Its top-level positioning is explicit:

> “Electron Forge unifies the existing (and well maintained) build tools for Electron
> development into a simple, easy to use package”

— [`README.md`][readme]. The same README names `@electron/rebuild` for native modules and
`@electron/packager` for application assembly. Forge coordinates those projects rather
than claiming their format internals.

### Design philosophy

The core is deliberately compositional:

1. templates initialize application source;
2. plugins integrate Vite/Webpack builds, Electron fuses, local runtimes, or native-module
   unpacking;
3. `package()` wraps `@electron/packager` and rebuilds production native dependencies;
4. makers transform an assembled app directory into one or more distributables;
5. publishers upload the `ForgeMakeResult` paths.

The README's goal is that “Everything from creating the project to packaging the project
for release should be handled by one core dependency” while retaining “maximum choice and
freedom” ([`README.md`][readme]). The abstract `Maker` and `Publisher` contracts make that
choice concrete rather than encoding all formats in the core.

## How it works

A typical source-controlled configuration makes each layer visible:

```javascript
module.exports = {
  packagerConfig: {
    asar: true,
    osxSign: {},
    osxNotarize: {},
  },
  makers: [
    { name: '@electron-forge/maker-zip', platforms: ['darwin'] },
    { name: '@electron-forge/maker-squirrel', platforms: ['win32'] },
    { name: '@electron-forge/maker-deb', platforms: ['linux'] },
  ],
  publishers: [{ name: '@electron-forge/publisher-github', config: {} }],
};
```

The core graph is:

```text
source + Forge config
  -> build plugin hooks
  -> @electron/packager application directory
  -> production dependency prune + @electron/rebuild
  -> maker.make(packaged directory)
  -> ForgeMakeResult { platform, arch, artifacts }
  -> publisher.publish(make results)
```

`make()` validates configured makers, checks each maker's current-host support and external
binaries, invokes `package()` unless explicitly skipped, and runs makers concurrently per
platform/architecture ([`make.ts`][make]). `publish()` normally invokes `make()` first,
then gives the complete results to configured publishers; dry-run state can separate those
steps ([`publish.ts`][publish]).

## Analysis dimensions

### Input and staging

`package()` consumes application source, `package.json`, `packagerConfig`, rebuild options,
plugins, and lifecycle hooks. It wraps `@electron/packager` with Forge defaults, arranges
copy/prune/rebuild signals, removes Forge configuration and `.bin` shims from the copied
application, and rejects unsupported `packagerConfig.all` and `prebuiltAsar`
([`package.ts`][package]). `@electron/packager` owns runtime download, platform bundle
layout, metadata injection, ASAR, and macOS signing/notarization options; Forge owns the
coordination around it.

The output directory convention is `<name>-<platform>-<arch>`. Makers receive this
complete directory through `MakerOptions.dir`; they do not receive application source.
The `make` layer is therefore artifact construction from a staged Electron application,
not a second application assembler.

### Outputs and target matrix

Official makers observed in the pinned source are:

| Maker            | Output                                                   | Backend and host boundary                                                                   |
| ---------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| ZIP              | `.zip`; optional macOS `RELEASES.json`                   | `cross-zip`; maker reports all hosts supported                                              |
| Squirrel.Windows | Setup EXE, full `.nupkg`, `RELEASES`, optional delta/MSI | delegates `electron-winstaller`                                                             |
| WiX              | `.msi`                                                   | delegates `electron-wix-msi`; Windows host                                                  |
| AppX             | `.appx`                                                  | delegates `electron-windows-store`; Windows host                                            |
| MSIX             | `.msix`                                                  | delegates `electron-windows-msix`; Windows host                                             |
| DMG              | `.dmg`                                                   | delegates `electron-installer-dmg`; macOS host                                              |
| PKG              | `.pkg`                                                   | delegates `@electron/osx-sign` flat-package helper; macOS host                              |
| Debian/RPM       | native Linux package                                     | delegates `electron-installer-debian` / `electron-installer-redhat`; external package tools |
| Flatpak          | `.flatpak`                                               | delegates `@malept/electron-installer-flatpak`; `flatpak-builder` and `eu-strip`            |
| Snap             | `.snap`                                                  | delegates `electron-installer-snap`; Linux and `snapcraft`                                  |

These are separate npm packages and can be enabled per target platform. There is no core
switch statement that pretends all maker capabilities are Forge's own. `Maker.make()`
returns absolute artifact paths, allowing one maker to emit a set such as Squirrel's
installer, package, and feed index ([`Maker.ts`][maker-base],
[`MakerSquirrel.ts`][maker-squirrel]).

### Metadata and dependencies

`package.json` and `packagerConfig` supply app identity/version; each maker accepts its
backend's own typed configuration. Forge maps only small conveniences such as the app
name, architecture, platform, and normalized four-part Windows version. Backend libraries
own package metadata details. There is no repository-wide JSON Schema for a complete Forge
configuration: configuration may be JavaScript/TypeScript, asynchronous, and include
class instances or per-architecture config functions ([`forge-config.ts`][forge-config]).

Forge prunes development dependencies and invokes `@electron/rebuild` against Electron.
Thus JavaScript/native Node dependencies are bundled into the staged app. Debian, RPM,
Flatpak, and Snap dependency declarations belong to their maker libraries/configuration;
ZIP, DMG, Windows installers, and app bundles carry the staged closure. Forge does not
resolve a cross-platform system-dependency graph.

### Installation, upgrade, and uninstall

Forge itself has no install, upgrade, rollback, or uninstall engine. Those semantics are
produced by makers and their delegated backends:

- Squirrel.Windows emits Setup, NuGet packages, a `RELEASES` index, and optionally deltas;
- MSI/AppX/MSIX and Linux native packages delegate lifecycle ownership to their platform
  installer/package database;
- DMG and ZIP transport an application whose ordinary lifecycle is copy/replace/delete;
- Flatpak and Snap delegate lifecycle to their deployment systems.

`make --skip-package` can reuse an existing staged app but warns it may be stale. The core
does not validate that an artifact set supports upgrades or shares identity across makers.

### Signing and platform trust

Application signing is primarily an assembly concern: Forge passes `osxSign` and
`osxNotarize` through `packagerConfig` to `@electron/packager`. The fuses plugin explicitly
interacts with `osxSign` so fuse mutation occurs before final trust is established
([`FusesPlugin.ts`][fuses]). Application authors provide Apple credentials and select the
native macOS host.

Maker-level outer-container signing remains backend-specific. PKG accepts installer
identity options; DMG exposes its backend's code-sign options; AppX and MSIX expose Windows
signing options; Squirrel and WiX expose their respective backend controls
([`MakerPKG.ts`][maker-pkg], [`MakerAppX.ts`][maker-appx]). Forge neither supplies one
cross-platform signing envelope nor manages a signing service. It also does not sign
publisher metadata or maker result inventories.

### Publication and discovery

`publish()` resolves publisher classes, runs `make()` by default, and calls each
publisher with all `ForgeMakeResult` objects ([`publish.ts`][publish]). Official publishers
cover GitHub Releases, Bitbucket downloads, S3, Google Cloud Storage, Snapcraft,
Electron Release Server, and Nucleus ([`publisher packages`][publishers]). GitHub groups
artifacts by `package.json` version and creates or reuses a `v<version>` release;
S3/GCS treat results as static objects.

Publisher support is upload/distribution plumbing, not universal discovery. Forge does
not generate WinGet, Homebrew, APT, or RPM-repository catalog entries. Server-specific
publishers may interpret channels or feeds, but there is no Forge-owned release database
or promotion API.

### Updates and release channels

There is no universal Forge updater metadata model. Update behavior is maker-specific:

- Squirrel.Windows returns `RELEASES`, a full `.nupkg`, and optional delta package;
- ZIP can fetch and rewrite a macOS `RELEASES.json` when
  `macUpdateManifestBaseUrl` is configured, embedding an ISO timestamp and release URL
  ([`MakerZIP.ts`][maker-zip]);
- Electron Release Server derives stable/RC/beta/alpha from the application version;
- other makers return only their artifact unless their delegated backend emits more.

Applications must select and integrate a compatible updater, hosting layout, and channel
policy. A publisher uploads whatever maker paths it receives; that alone does not make an
arbitrary artifact auto-update capable.

### Automation and CI

Forge exposes scriptable `package`, `make`, and `publish` APIs/CLI commands, hooks, dry-run
publication, platform and architecture selection, and environment-friendly publisher
credentials. It does not emit a reusable end-user release workflow. Consumers author the
matrix, secrets, signing permissions, fan-in, and publish conditions.

Every maker answers `isSupportedOnCurrentPlatform()` and can declare
`requiredExternalBinaries`; core fails before packaging if either check fails
([`Maker.ts`][maker-base], [`make.ts`][make]). Official constraints are concrete: DMG/PKG
require macOS; AppX/MSIX/WiX require Windows; Snap requires Linux; Debian requires `dpkg`
and `fakeroot`; RPM requires `rpmbuild`; Flatpak requires `flatpak-builder` and `eu-strip`.
Squirrel's check is dependency-based and its backend may support more than one host, but
that does not make Windows signing native-host-independent.

Upstream CI itself runs fast and slow tests on Ubuntu, Windows, and macOS, with host setup
for native rebuilds and Linux desktop libraries ([`ci.yml`][workflow]). The template
implementation is explicit when asked for CI files: “Copying CI files is currently not
supported” ([`BaseTemplate.ts`][base-template]). This is evidence for Forge's own test
matrix, not a generated consumer release matrix.

### Supply-chain evidence and reproducibility

The repository pins Yarn dependencies, uses immutable installs, pins GitHub Actions by
commit, separates build/test jobs, and tests makers and publishers. The plugin model can
apply Electron fuses, and native platform signatures can authenticate assembled apps.

Forge emits no SBOM, SLSA provenance, signed checksum manifest, or cross-maker inventory.
It does not promise byte-identical artifacts: Electron/runtime downloads, native rebuilds,
backend versions, source mtimes, ZIP timestamps, `new Date()` in `RELEASES.json`, signing,
notarization, and arbitrary hooks/plugins can vary. The ZIP manifest is fetched and then
rewritten, so concurrent publication requires user coordination. Supply-chain hardening
belongs in consumer CI: pin Forge and maker dependencies, lock runtime/tool versions,
isolate secrets, hash outputs, and attest the collected artifact set. `[source-verified]`

### Extensibility and UX

`Maker<C>`, `Publisher<C>`, and plugin base classes are first-class extension points.
Makers declare default target platforms, host support, required binaries, per-architecture
configuration, and return paths. Publishers receive the whole result set. Hooks cover
package and make phases, while Vite/Webpack plugins own source bundling.

This modularity is Forge's defining strength: applications can replace one maker without
forking core. The cost is distributed behavior and documentation. Configuration schemas,
trust policy, update metadata, reproducibility, and host requirements vary with each
backend package; users must inspect more than `forge.config` to understand a release.

## Strengths

- Clear `package` → `make` → `publish` layering with explicit result paths.
- Excellent Electron ergonomics from templates through native-module rebuild and assembly.
- Makers and publishers are real extension contracts, not only lifecycle shell hooks.
- Broad official artifact and hosting coverage through maintained ecosystem backends.
- Host-support and required-binary checks make native constraints visible before execution.
- Application authors retain backend choice instead of adopting one installer protocol.

## Weaknesses

- Not a release control plane: no generated CI, cross-host fan-in, release manifest, promotion, or announcement.
- No universal updater, channel model, update signature, or lifecycle contract.
- Capabilities and security properties depend heavily on delegated maker libraries.
- Native macOS/Windows/Linux runners and tools remain necessary for important outputs.
- No complete static configuration schema because executable configuration is intentionally flexible.
- No built-in SBOM, provenance, reproducibility guarantee, or artifact checksum inventory.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                     | Trade-off                                                                  |
| ------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Delegate assembly to `@electron/packager`   | Reuse Electron runtime, metadata, ASAR, and signing expertise | Forge behavior follows another package's contracts                         |
| Separate makers from package assembly       | Let many formats consume one staged application               | Makers can diverge in identity, trust, and lifecycle semantics             |
| Make makers independent npm packages        | Permit replacement and focused maintenance                    | Versions and backend dependencies form a distributed compatibility surface |
| Require makers to report host support/tools | Fail early with actionable native requirements                | Cross-packaging remains backend-specific rather than centrally planned     |
| Return artifact path arrays                 | Keep core/publishers format-agnostic                          | Paths carry little semantic or trust metadata                              |
| Run `make()` from `publish()` by default    | Provide a convenient end-to-end command                       | Multi-host fan-in requires an external workflow/dry-run strategy           |
| Keep updater metadata maker-specific        | Avoid forcing one update protocol on all formats              | Applications cannot ask Forge for a uniform update channel                 |
| Use executable JavaScript/TypeScript config | Enable dynamic config, class instances, and hooks             | Static schema validation and hermetic configuration are limited            |
| Put signing in assembly and makers          | Respect nested-code and outer-container boundaries            | Credentials/options are split across layers                                |

## Sources

- [Local clone `$REPOS/js/electron-forge` at the exact reviewed revision][revision]
- [`README.md` — positioning, goals, and delegated Electron tooling][readme]
- [`package.ts` — app assembly, prune, rebuild, and packager integration][package]
- [`make.ts` and `Maker.ts` — maker resolution, support checks, and result contract][make]
- [`publish.ts` and publisher implementations — upload orchestration][publish]
- [Official maker sources — backend delegation, output sets, tests, and host checks][makers]
- [`ci.yml` — upstream Linux/macOS/Windows test matrix][workflow]

<!-- References -->

[repo]: https://github.com/electron/forge
[revision]: https://github.com/electron/forge/tree/fc5fb4d4269cbce909fc59f570b8aa1e1add4090
[readme]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/README.md
[packages]: https://github.com/electron/forge/tree/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages
[package]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/api/core/src/api/package.ts
[make]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/api/core/src/api/make.ts
[publish]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/api/core/src/api/publish.ts
[forge-config]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/api/core/src/util/forge-config.ts
[maker-base]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/maker/base/src/Maker.ts
[makers]: https://github.com/electron/forge/tree/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/maker
[maker-zip]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/maker/zip/src/MakerZIP.ts
[maker-squirrel]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/maker/squirrel/src/MakerSquirrel.ts
[maker-pkg]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/maker/pkg/src/MakerPKG.ts
[maker-appx]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/maker/appx/src/MakerAppX.ts
[fuses]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/plugin/fuses/src/FusesPlugin.ts
[publishers]: https://github.com/electron/forge/tree/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/publisher
[workflow]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/.github/workflows/ci.yml
[base-template]: https://github.com/electron/forge/blob/fc5fb4d4269cbce909fc59f570b8aa1e1add4090/packages/template/base/src/BaseTemplate.ts
