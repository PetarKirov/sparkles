# Application Packaging and Distribution

A source-grounded survey of how a tagged native application becomes installable,
identifiable, trusted, published, upgraded, and eventually promoted across Linux,
Windows, and macOS. The catalog separates **artifact formats**, **distribution
channels**, **platform-native tools**, and **cross-platform release orchestrators**;
that distinction is essential because no single tool owns the whole path from compiler
output to a user's machine.

**Last reviewed:** July 12, 2026

This survey answers ten questions:

1. What do **stage**, **package**, **bundle**, **sign**, **notarize**, **staple**, and
   **publish** mean, and which operation changes bytes? → [Concepts][concepts]
2. How do archives, native packages, self-mounting images, sandboxed bundles, and
   Apple containers differ? → [Artifact formats][formats]
3. What is the complete release dataflow from source tag to promoted package indexes?
   → [Release pipeline][pipeline]
4. What does Sparkles actually build and publish today? → [Sparkles baseline][baseline]
5. Which tool owns which part of the process, and what ten dimensions make unlike
   tools comparable? → [Comparison][comparison]
6. Which platform rules cannot be abstracted away safely? → [Platform gotchas][gotchas]
7. How do Linux native repositories differ from AppImage, Flatpak, and Snap? →
   [Linux native packages][linux-native], [repositories][linux-repositories],
   [AppImage][appimage], [Flatpak][flatpak], [Snap][snap]
8. How do Windows portable archives, MSI, MSIX, installer EXEs, and community catalogs
   differ? → [Windows portable][windows-portable], [WiX/MSI][wix], [MSIX][msix],
   [Inno Setup/NSIS][inno-nsis], [winget][winget], [Chocolatey][chocolatey],
   [Scoop][scoop]
9. How do `.app`, DMG/PKG/XIP, Developer ID signing, notarization, stapling, and
   Homebrew compose? → [macOS bundles][macos-bundles], [containers][macos-containers],
   [signing/notarization][macos-signing], [Homebrew][homebrew]
10. What staged, evidence-backed path fits Sparkles without pretending one universal
    packager exists? → [Recommendations][recommendations]

> [!NOTE]
> This directory is the shared synthesis layer. The linked sibling deep-dives are the
> evidence owners for tool-specific behavior. A recommendation is labelled as such;
> otherwise prose describes current formats, upstream contracts, or the audited
> Sparkles baseline.

## The ten-dimension analysis spine

Every subject deep-dive follows the same spine: **(1) input and staging, (2) outputs
and target matrix, (3) metadata and dependencies, (4) installation, upgrade, and
uninstall, (5) signing and platform trust, (6) publication and discovery, (7) updates
and release channels, (8) automation and CI, (9) supply-chain evidence and
reproducibility, and (10) extensibility and UX**. Role, host requirements, identity,
and rollback remain mandatory findings inside those sections and are re-cut as compact
columns in [comparison]; they are not a second subject-page spine.

## Master catalog

| Subject                      | Category / primary role                | Principal outputs or channel             | Link                            |
| ---------------------------- | -------------------------------------- | ---------------------------------------- | ------------------------------- |
| Linux native packages        | format family                          | `.deb`, `.rpm`, Arch package             | [deep-dive][linux-native]       |
| Linux repositories           | distribution channel                   | APT, RPM-family, pacman indexes          | [deep-dive][linux-repositories] |
| AppImage                     | portable artifact                      | self-mounting `.AppImage`                | [deep-dive][appimage]           |
| Flatpak                      | sandbox + repository                   | OSTree objects / `.flatpak`              | [deep-dive][flatpak]            |
| Snap                         | sandbox + store                        | `.snap` / Snap Store                     | [deep-dive][snap]               |
| linuxdeploy + appimagetool   | Linux bundler / image builder          | `AppDir` → `.AppImage`                   | [deep-dive][linuxdeploy]        |
| Windows portable             | portable artifact                      | `.zip`/directory                         | [deep-dive][windows-portable]   |
| WiX / MSI                    | native installer toolchain             | `.msi`, bundle `.exe`                    | [deep-dive][wix]                |
| MSIX                         | signed package format                  | `.msix`, `.msixbundle`                   | [deep-dive][msix]               |
| Inno Setup / NSIS            | installer compilers                    | setup `.exe`                             | [deep-dive][inno-nsis]          |
| winget                       | catalog + client                       | manifests pointing to installers         | [deep-dive][winget]             |
| Chocolatey                   | package repository + client            | `.nupkg` + PowerShell install            | [deep-dive][chocolatey]         |
| Scoop                        | manifest catalog + client              | JSON manifests → portable installs       | [deep-dive][scoop]              |
| macOS app bundles            | native bundle model                    | `.app` directory                         | [deep-dive][macos-bundles]      |
| macOS DMG / PKG / XIP        | transport / installer containers       | `.dmg`, `.pkg`, `.xip`                   | [deep-dive][macos-containers]   |
| macOS signing / notarization | trust pipeline                         | signed ticketed/stapled artifacts        | [deep-dive][macos-signing]      |
| Homebrew                     | formula/cask channel                   | bottles, formulae, casks                 | [deep-dive][homebrew]           |
| cargo-dist                   | release orchestrator                   | archives, installers, checksums, CI      | [deep-dive][cargo-dist]         |
| cargo-packager               | desktop packager                       | platform-native packages                 | [deep-dive][cargo-packager]     |
| GoReleaser                   | release orchestrator                   | archives, Linux packages, publishers     | [deep-dive][goreleaser]         |
| JReleaser                    | release orchestrator                   | assemblers, packagers, publishers        | [deep-dive][jreleaser]          |
| dotnet-releaser              | ecosystem orchestrator                 | NuGet, archives, installers/releases     | [deep-dive][dotnet-releaser]    |
| Velopack                     | installer + updater framework          | installers, release feeds, delta updates | [deep-dive][velopack]           |
| Conveyor                     | fetching installer / repository system | signed native installers/repos           | [deep-dive][conveyor]           |
| Briefcase                    | Python app bundler                     | native app projects/packages             | [deep-dive][briefcase]          |
| cx_Freeze                    | Python freezer + packager              | frozen app, MSI/DMG/AppImage etc.        | [deep-dive][cx-freeze]          |
| electron-builder             | Electron packager/publisher            | broad desktop artifact matrix            | [deep-dive][electron-builder]   |
| Electron Forge               | Electron lifecycle facade              | packages, makers, publishers             | [deep-dive][electron-forge]     |
| CPack                        | build-system packager                  | generator-selected native packages       | [deep-dive][cpack]              |
| fpm / nfpm                   | native-package converters/builders     | `.deb`, `.rpm`, Arch and peers           | [deep-dive][fpm-nfpm]           |
| jpackage                     | JDK application packager               | app images + native installers           | [deep-dive][jpackage]           |
| swift-bundler                | Swift application bundler              | `.app` and platform bundles              | [deep-dive][swift-bundler]      |

## Taxonomies

### By tool role

| Role                           | Subjects                                                                                                                                                                                                                                                  |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Format / platform contract     | [Linux native packages][linux-native], [Windows portable][windows-portable], [MSIX][msix], [macOS bundles][macos-bundles], [macOS containers][macos-containers], [macOS trust][macos-signing]                                                             |
| Package / bundle constructor   | [linuxdeploy/appimagetool][linuxdeploy], [WiX][wix], [Inno/NSIS][inno-nsis], [cargo-packager][cargo-packager], [Briefcase][briefcase], [cx_Freeze][cx-freeze], [CPack][cpack], [fpm/nfpm][fpm-nfpm], [jpackage][jpackage], [swift-bundler][swift-bundler] |
| Release orchestrator           | [cargo-dist][cargo-dist], [GoReleaser][goreleaser], [JReleaser][jreleaser], [dotnet-releaser][dotnet-releaser]                                                                                                                                            |
| Application packager/publisher | [electron-builder][electron-builder], [Electron Forge][electron-forge]                                                                                                                                                                                    |
| Installer + updater system     | [Velopack][velopack], [Conveyor][conveyor]                                                                                                                                                                                                                |
| Distribution channel / client  | [Linux repositories][linux-repositories], [Flatpak][flatpak], [Snap][snap], [winget][winget], [Chocolatey][chocolatey], [Scoop][scoop], [Homebrew][homebrew]                                                                                              |

### By artifact / install model

| Model                       | Meaning                                                        | Subjects                                                                                                                                                         |
| --------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Portable                    | unpack/run; no privileged registration required                | [Windows portable][windows-portable], archive outputs from [cargo-dist][cargo-dist] / [GoReleaser][goreleaser]                                                   |
| Bundling                    | producer ships runtime/dependencies beside the app             | [AppImage][appimage], [macOS bundles][macos-bundles], [Briefcase][briefcase], [cx_Freeze][cx-freeze], [jpackage][jpackage], [electron-builder][electron-builder] |
| Native package              | OS installer database owns files, identity, uninstall, upgrade | [Linux native][linux-native], [WiX/MSI][wix], [MSIX][msix], [macOS PKG][macos-containers], [CPack][cpack], [fpm/nfpm][fpm-nfpm]                                  |
| Fetching installer          | small/bootstrap artifact resolves payload during install       | [Conveyor][conveyor]; some maker-specific flows in [Electron Forge][electron-forge]                                                                              |
| Sandboxed/repository-native | package and channel jointly define permissions and updates     | [Flatpak][flatpak], [Snap][snap], [MSIX][msix]                                                                                                                   |

### By host requirement

| Requirement                                                                        | Typical cases                                                           | Relevant deep-dives                                                                                                                                    |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Target OS required for final packaging/signing                                     | MSI/MSIX, Apple signing/notarization, many desktop makers               | [WiX][wix], [MSIX][msix], [macOS signing][macos-signing], [cargo-packager][cargo-packager], [electron-builder][electron-builder], [jpackage][jpackage] |
| Cross-host construction possible but final trust step remains native/service-bound | archive, some Linux packages, some app images                           | [cargo-dist][cargo-dist], [GoReleaser][goreleaser], [CPack][cpack], [fpm/nfpm][fpm-nfpm], [AppImage][appimage]                                         |
| Hosted repository builds are part of the trust model                               | Flatpak remotes, Snap Store, Homebrew bottles/casks, community catalogs | [Flatpak][flatpak], [Snap][snap], [Homebrew][homebrew], [winget][winget], [Chocolatey][chocolatey], [Scoop][scoop]                                     |

### By distribution channel

| Channel                                     | Subjects                                                                                                                                             |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Immutable release-host asset                | [cargo-dist][cargo-dist], [GoReleaser][goreleaser], [JReleaser][jreleaser], [dotnet-releaser][dotnet-releaser], [electron-builder][electron-builder] |
| Vendor-maintained package repository/feed   | [Linux repositories][linux-repositories], [Velopack][velopack], [Conveyor][conveyor]                                                                 |
| Platform/operator store                     | [Flatpak][flatpak], [Snap][snap], [MSIX][msix]                                                                                                       |
| Community index referencing upstream assets | [winget][winget], [Scoop][scoop], [Homebrew][homebrew] casks/formulae, [Chocolatey][chocolatey]                                                      |
| Direct download / portable                  | [AppImage][appimage], [Windows portable][windows-portable], [macOS DMG][macos-containers]                                                            |

## Milestones

| Date      | Packaging milestone                                                                                                                                                                                                                 |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1988      | Apple System 6 introduces application bundles as directories; modern bundle metadata later consolidates around `Info.plist` ([macOS bundles][macos-bundles]).                                                                       |
| 1993–1996 | Debian's `dpkg`/`.deb` and Red Hat's RPM establish database-managed native packages ([Linux native][linux-native]).                                                                                                                 |
| 1999      | Windows Installer 1.0 establishes MSI product/component identity and transactional installation ([WiX/MSI][wix]).                                                                                                                   |
| 2002      | Inno Setup and NSIS popularize script-compiled setup executables ([Inno/NSIS][inno-nsis]).                                                                                                                                          |
| 2009      | Homebrew starts the formula/cellar model on macOS ([Homebrew][homebrew]).                                                                                                                                                           |
| 2013–2016 | AppImage's portable lineage, Docker-era bundling, Flatpak, and Snap make self-contained/sandboxed Linux delivery mainstream ([AppImage][appimage], [Flatpak][flatpak], [Snap][snap]).                                               |
| 2015–2018 | Windows 10's AppX/MSIX line and Apple's Developer ID notarization pipeline make cryptographic identity a normal desktop-release concern ([MSIX][msix], [macOS signing][macos-signing]).                                             |
| 2019–2021 | `jpackage`, winget, and modern release automation normalize matrix-produced native installers plus catalog publication ([jpackage][jpackage], [winget][winget], [GoReleaser][goreleaser]).                                          |
| 2022–2026 | Release orchestrators increasingly emit checksums, SBOMs, attestations, updater feeds, and CI definitions rather than only archives ([cargo-dist][cargo-dist], [JReleaser][jreleaser], [Velopack][velopack], [Conveyor][conveyor]). |

Dates identify broad public milestones; exact version-by-version histories belong to the
linked deep-dives.

## Quick navigation

- **Designing Sparkles delivery:** [Sparkles baseline][baseline] →
  [concepts][concepts] → [release pipeline][pipeline] → [comparison][comparison] →
  [platform gotchas][gotchas] → [recommendations][recommendations].
- **Choosing user-facing artifacts:** [artifact formats][formats] → the relevant
  Linux, Windows, or macOS format deep-dives → [comparison][comparison].
- **Choosing an orchestrator:** [comparison][comparison] → [cargo-dist][cargo-dist],
  [GoReleaser][goreleaser], [JReleaser][jreleaser], [CPack][cpack], and the
  language/runtime-specific candidates.
- **Trust and update design:** [concepts § identity][concepts-identity] →
  [macOS signing][macos-signing] / [MSIX][msix] / [Linux repositories][linux-repositories]
  → [release pipeline][pipeline].

## Sources

Format definitions are grounded in the platform specifications linked from
[concepts][concepts] and [artifact formats][formats]. Tool behavior belongs to each
sibling deep-dive and is read from locally cloned repositories pinned there by commit.
The synthesis also uses the in-repository evidence audited in
[Sparkles baseline][baseline]. No artifact matrix in this shared layer is presented as
locally tested behavior.

<!-- References -->

[concepts]: ./concepts.md
[concepts-identity]: ./concepts.md#identity-version-and-upgrades
[formats]: ./artifact-formats.md
[pipeline]: ./release-pipeline.md
[baseline]: ./sparkles-baseline.md
[comparison]: ./comparison.md
[gotchas]: ./platform-gotchas.md
[recommendations]: ./recommendations.md
[linux-native]: ./linux-native-packages.md
[linux-repositories]: ./linux-repositories.md
[appimage]: ./appimage.md
[flatpak]: ./flatpak.md
[snap]: ./snap.md
[linuxdeploy]: ./linuxdeploy-appimagetool.md
[windows-portable]: ./windows-portable.md
[wix]: ./wix-msi.md
[msix]: ./msix.md
[inno-nsis]: ./inno-setup-nsis.md
[winget]: ./winget.md
[chocolatey]: ./chocolatey.md
[scoop]: ./scoop.md
[macos-bundles]: ./macos-app-bundles.md
[macos-containers]: ./macos-dmg-pkg-xip.md
[macos-signing]: ./macos-signing-notarization.md
[homebrew]: ./homebrew.md
[cargo-dist]: ./cargo-dist.md
[cargo-packager]: ./cargo-packager.md
[goreleaser]: ./goreleaser.md
[jreleaser]: ./jreleaser.md
[dotnet-releaser]: ./dotnet-releaser.md
[velopack]: ./velopack.md
[conveyor]: ./conveyor.md
[briefcase]: ./briefcase.md
[cx-freeze]: ./cx-freeze.md
[electron-builder]: ./electron-builder.md
[electron-forge]: ./electron-forge.md
[cpack]: ./cpack.md
[fpm-nfpm]: ./fpm-nfpm.md
[jpackage]: ./jpackage.md
[swift-bundler]: ./swift-bundler.md
