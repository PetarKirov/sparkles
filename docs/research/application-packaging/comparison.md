# Packaging-System Comparison

The capstone synthesis: every surveyed tool family synthesized from the catalog's fixed
ten-dimension spine, followed by the field's consensus architecture, genuine trade-offs,
and the explicit delta from the [Sparkles baseline][baseline].

**Last reviewed:** July 12, 2026

## The canonical ten-dimension spine

1. **Input and staging** — binaries, install tree, ecosystem project, or full source build.
2. **Outputs and target matrix** — emitted formats, architectures, and native-host limits.
3. **Metadata and dependencies** — identity fields, system dependencies, selected
   bundling, or a complete runtime.
4. **Installation, upgrade, and uninstall** — portable, bundled, native-database,
   sandbox/store, or fetching behavior plus servicing lineage.
5. **Signing and platform trust** — which trust layers the subject owns or delegates.
6. **Publication and discovery** — release hosts, stores, repositories, and community
   indexes.
7. **Updates and release channels** — update ownership, channels, rollback, or absence.
8. **Automation and CI** — orchestration, host runners, secret isolation, and retry model.
9. **Supply-chain evidence and reproducibility** — checksums, SBOM, provenance, and
   deterministic controls.
10. **Extensibility and UX** — configuration, hooks, diagnostics, and dry-run/plan support.

The definitions are in [concepts]; “delegated” is a finding, not a failure. A format
builder should not be scored as though it were a store, and a community index should not
be credited with building the referenced payload.

## At-a-glance decision matrix

The wide tables below are a **re-cut**, not another fixed page spine: they pull role and
host/identity constraints out as quick-selection columns and compress automation plus
extensibility into the detailed prose that follows. Every cell remains derived from the
canonical sections above. Compact vocabulary: `P` portable; `B` bundled; `N` native
package database; `S` sandbox/store; `F` fetching installer; `native` means final
construction normally needs the target OS/toolchain; `deleg.` means deliberately
delegated. Exact supported targets, flags, and defaults belong to each linked deep-dive.

### Platform formats, constructors, and channels

| Subject                                  | 1 Role                   | 2 Input/stage                       | 3 Install         | 4 Deps/runtime                  | 5 Host                                 | 6 Identity/upgrade                    | 7 Trust                                | 8 Channel                          | 9 Update/rollback                | 10 Supply chain                      |
| ---------------------------------------- | ------------------------ | ----------------------------------- | ----------------- | ------------------------------- | -------------------------------------- | ------------------------------------- | -------------------------------------- | ---------------------------------- | -------------------------------- | ------------------------------------ |
| [Linux native][linux-native]             | formats                  | root tree + metadata                | N                 | solver + system deps            | Linux/distro tooling                   | package/version/release               | pkg + repo                             | [repos][linux-repositories]        | client-owned                     | format/tool dependent                |
| [Linux repositories][linux-repositories] | channel                  | final packages + index metadata     | N                 | publishes dependency graph      | Linux/server                           | suite/channel versions                | signed metadata                        | APT/RPM/pacman                     | client snapshots vary            | digests + signed indexes             |
| [AppImage][appimage]                     | portable bundle          | `AppDir`                            | P/B               | selected bundling               | Linux; cross limits                    | filename/update info, no universal DB | optional/deleg.                        | direct host                        | optional external mechanism      | checksum/signing tool dependent      |
| [Flatpak][flatpak]                       | build+repo+runtime       | manifest/modules                    | S/B               | named runtime + bundled modules | Linux builders                         | app ID + branch/ref                   | repo signatures                        | remotes/stores                     | native update/rollback           | OSTree content addressing            |
| [Snap][snap]                             | build+store              | `snapcraft.yaml` stage/prime        | S/B               | base/content snaps + bundle     | Linux builders                         | snap name/revision/channel            | assertions/store                       | Snap Store                         | refresh/revert                   | store/assertion model                |
| [linuxdeploy/appimagetool][linuxdeploy]  | bundler+image builder    | ELF app → `AppDir`                  | P/B               | deploy selected ELF deps        | Linux                                  | delegates                             | delegates/sign option                  | delegates                          | embeds optional info             | image/checksum delegated             |
| [Windows portable][windows-portable]     | artifact model           | directory                           | P                 | adjacent DLLs/runtime           | broad                                  | app-defined                           | code-sign optional                     | direct/catalog                     | app/manual                       | checksums delegated                  |
| [WiX/MSI][wix]                           | native compiler          | files + WiX source                  | N                 | carried files/prereqs           | Windows-native toolchain most reliable | product/component/upgrade codes       | Authenticode deleg.                    | direct/enterprise/[winget][winget] | MSI servicing/rollback           | deterministic controls tool-specific |
| [MSIX][msix]                             | native format/tooling    | package layout + manifest           | N/S               | framework packages + payload    | Windows SDK/native common              | manifest identity/family              | package signature                      | Store/direct/enterprise            | managed deployment               | block map + signature                |
| [Inno/NSIS][inno-nsis]                   | setup compilers          | files + scripts                     | custom N          | script/bundle                   | Windows compiler (some cross paths)    | script-defined                        | Authenticode deleg.                    | direct/[winget][winget]            | custom                           | delegated                            |
| [winget][winget]                         | community catalog/client | YAML + immutable installer URL/hash | references N/P    | installer-defined               | manifest validation                    | package ID/version                    | installer signature + catalog controls | winget source                      | installer/client                 | SHA-256 manifests                    |
| [Chocolatey][chocolatey]                 | repo/client              | NuGet package + scripts/assets      | F/N               | PowerShell/NuGet policy         | Windows                                | package version                       | signatures/moderation vary             | Chocolatey repos                   | scripts/client                   | checksums expected by package        |
| [Scoop][scoop]                           | portable catalog/client  | JSON URL/hash                       | P                 | archive/executable deps         | Windows                                | manifest version                      | hash; code signature external          | buckets                            | persist/shims, rollback patterns | SHA-256 manifest                     |
| [macOS bundles][macos-bundles]           | bundle contract          | staged `Contents/` tree             | B/copy            | nested frameworks/resources     | macOS tooling                          | bundle ID/version                     | code signing                           | direct/cask/store wrapper          | app/updater                      | signing affects bytes                |
| [DMG/PKG/XIP][macos-containers]          | containers/installers    | `.app`/component payload            | B or N            | payload-defined                 | macOS-native                           | bundle/pkg receipts                   | Developer ID/notary                    | direct/[Homebrew][homebrew]        | copy/pkg semantics               | checksum after staple                |
| [macOS trust][macos-signing]             | trust service/pipeline   | nested code + outer artifact        | —                 | validates closure               | macOS + Apple service                  | team/designated requirement           | signs/notarizes/staples                | gates direct delivery              | delegated                        | signatures/tickets nontrivial        |
| [Homebrew][homebrew]                     | community channel/client | source recipe or asset cask         | P/B/N-like cellar | formula deps/bottles            | macOS/Linux builders                   | token/version/revision                | hashes; upstream signatures            | taps/core/cask                     | upgrade/pin                      | bottles + checksums                  |

### Cross-platform and ecosystem tools

| Subject                              | 1 Role                 | 2 Input/stage                   | 3 Install                | 4 Deps/runtime                    | 5 Host                                   | 6 Identity/upgrade      | 7 Trust                                      | 8 Channel                     | 9 Update/rollback                 | 10 Supply chain                             |
| ------------------------------------ | ---------------------- | ------------------------------- | ------------------------ | --------------------------------- | ---------------------------------------- | ----------------------- | -------------------------------------------- | ----------------------------- | --------------------------------- | ------------------------------------------- |
| [cargo-dist][cargo-dist]             | control plane+packager | Cargo, npm, or generic binaries | P + installers           | artifacts + declared extras       | CI matrix/native where needed            | release/tag config      | calls signers; platform-dependent            | GitHub + installers           | installer/channel dependent       | checksums + CI/provenance features          |
| [cargo-packager][cargo-packager]     | desktop packager       | binary/resources config         | B/N                      | configured resources/deps         | target-native formats vary               | package IDs/version     | delegates platform signers                   | delegates                     | format-dependent                  | delegated/tool controls                     |
| [GoReleaser][goreleaser]             | orchestrator           | Go builds + config              | P + Linux N + publishers | static/bundled extras             | cross-compiles many; native exceptions   | tag/project/version     | signing integrations                         | release hosts/repos           | delegated                         | checksums/SBOM/sign/provenance integrations |
| [JReleaser][jreleaser]               | orchestrator           | distributions/assemblies        | P/N + publishers         | Java/runtime assemblers           | matrix/tool dependent                    | project/version/channel | broad signer delegation                      | many releasers/packagers      | delegated                         | checksums, SBOM, provenance integrations    |
| [dotnet-releaser][dotnet-releaser]   | .NET orchestrator      | .NET project publish outputs    | P/N                      | .NET publish/runtime modes        | platform matrix                          | NuGet/app version       | delegates                                    | NuGet/GitHub/etc.             | tool/format dependent             | release manifest features                   |
| [Velopack][velopack]                 | installer+updater      | packaged desktop app            | F/N                      | bundled app/runtime               | native targets vary                      | package/channel/version | platform signing hooks                       | release feeds/providers       | core feature; delta/full packages | signed feed/artifact controls               |
| [Conveyor][conveyor]                 | installer+repo system  | JVM/native app config           | F/N/B                    | downloads/bundles by plan         | cross-platform service/tool model        | app ID/site/channel     | integrated signing claims; verify per target | generated repos/download site | core feature                      | reproducible/fetch model focus              |
| [Briefcase][briefcase]               | Python app bundler     | Python project/template         | B/N                      | Python runtime + packages         | target support/native SDKs               | bundle/package IDs      | delegates native signers                     | delegates                     | format-dependent                  | template/build dependent                    |
| [cx_Freeze][cx-freeze]               | freezer+packager       | Python program                  | B + native outputs       | Python runtime/modules            | target-native freeze generally           | config/format-specific  | delegates                                    | delegates                     | format-dependent                  | delegated                                   |
| [electron-builder][electron-builder] | packager+publisher     | Electron app                    | P/B/N/S/F                | Electron runtime + native modules | broad matrix, native signing constraints | app/package ID/version  | signer/notary integrations                   | many providers                | updater metadata integrations     | checksums/blockmaps, reproducibility varies |
| [Electron Forge][electron-forge]     | lifecycle facade       | Electron project                | B/N                      | Electron runtime                  | maker-dependent                          | config/maker-specific   | plugins/delegates                            | publisher plugins             | delegated                         | maker/plugin-dependent                      |
| [CPack][cpack]                       | generator facade       | CMake install tree              | P/N/B                    | install rules/components          | generator-dependent                      | CPACK variables/format  | mostly delegates                             | delegates                     | format-dependent                  | generator-dependent                         |
| [fpm/nfpm][fpm-nfpm]                 | package builders       | directory/package metadata      | N                        | declared deps/payload             | often Linux/cross-friendly               | native fields           | signing support varies                       | delegates                     | native manager                    | reproducibility controls vary               |
| [jpackage][jpackage]                 | JDK packager           | Java app + runtime image        | B/N                      | custom JLink runtime              | target OS required                       | app/version/vendor      | native signing options vary                  | delegates                     | format-dependent                  | toolchain-dependent                         |
| [swift-bundler][swift-bundler]       | Swift bundler          | Swift package + config          | B                        | Swift/platform resources          | Apple/Linux target tooling               | bundle ID/version       | delegates Apple pipeline                     | delegates                     | delegated                         | build-system dependent                      |

## Findings by dimension

### 1–3: role, stage, and install model

The strongest tools make their boundary explicit. [CPack][cpack], [fpm/nfpm][fpm-nfpm],
[cargo-packager][cargo-packager], and platform compilers consume a stage and emit formats;
[cargo-dist][cargo-dist], [GoReleaser][goreleaser], and [JReleaser][jreleaser] coordinate
builds plus publishers; [winget][winget], [Scoop][scoop], and [Homebrew][homebrew] index
artifacts built elsewhere; [Velopack][velopack] and [Conveyor][conveyor] extend the
contract into updates. Selecting one “packaging tool” without first choosing these roles
produces overlap or missing stages ([release pipeline][pipeline]).

The field does **not** converge on one install model. Archives and AppImage favor direct
ownership; distro packages/MSI/PKG favor native databases; Flatpak/Snap/MSIX bind package
identity to constrained deployment; fetching installers trade small initial downloads
for a live repository dependency ([artifact formats][formats], [AppImage][appimage],
[Flatpak][flatpak], [Snap][snap], [MSIX][msix], [Conveyor][conveyor]).

### 4–5: dependency boundary and host matrix

Portable output is only as portable as its runtime boundary. Go's static-friendly model
helps [GoReleaser][goreleaser]; Python, Java, and Electron tools deliberately ship a
runtime ([Briefcase][briefcase], [cx_Freeze][cx-freeze], [jpackage][jpackage],
[electron-builder][electron-builder]); AppImage selects Linux libraries around a base
system ([AppImage][appimage]). D applications can be simple binaries or carry dynamic
C libraries, so Sparkles needs a product-specific dependency audit rather than borrowing
an ecosystem assumption ([baseline][baseline], [platform gotchas][gotchas]).

Compilation and packaging are separate portability questions. Archives and some Linux
packages can be made cross-host, while SDK validation, Authenticode/MSIX, and Apple
signing/notarization often make native runners the least-surprising finalization path
([WiX/MSI][wix], [MSIX][msix], [macOS signing][macos-signing],
[cargo-packager][cargo-packager], [electron-builder][electron-builder]).

### 6–9: identity, trust, publication, and updates

Stable identity is the seam connecting every later release. MSI component/product GUIDs,
MSIX publisher identity, macOS bundle IDs/designated requirements, Linux package names,
and updater feed IDs cannot safely be regenerated from filenames on every run
([WiX/MSI][wix], [MSIX][msix], [macOS bundles][macos-bundles],
[Linux native][linux-native], [Velopack][velopack]).

Trust remains layered and platform-native. Cross-platform tools mostly invoke external
signers; repository metadata signatures and Apple notarization remain distinct from code
signatures. The most integrated systems reduce configuration, but they do not erase key
custody, native policy, or post-sign verification ([macOS signing][macos-signing],
[Linux repositories][linux-repositories], [Conveyor][conveyor],
[JReleaser][jreleaser]).

Channels live most naturally in repositories/stores/updater feeds, not archive filenames.
Flatpak, Snap, package repos, Velopack, and Conveyor can promote metadata around immutable
bytes; direct archives require another mechanism ([Flatpak][flatpak], [Snap][snap],
[Linux repositories][linux-repositories], [Velopack][velopack], [Conveyor][conveyor]).
Community catalogs add discoverability but create a second review/publication lifecycle
([winget][winget], [Chocolatey][chocolatey], [Scoop][scoop], [Homebrew][homebrew]).

### 10: supply-chain evidence and reproducibility

Checksums are now baseline output for release orchestrators, while SBOM and provenance
support is uneven and evolving ([cargo-dist][cargo-dist], [GoReleaser][goreleaser],
[JReleaser][jreleaser]). No tool's checkbox proves final signed-artifact reproducibility:
format timestamps, compression, native databases, signatures, and notarization can vary.
The defensible pipeline records final digests, emits SBOM/provenance, pins build inputs,
and measures reproducibility per artifact ([concepts][concepts], [release
pipeline][pipeline]).

## Consensus architecture

Across the catalog, the defensible common architecture is a **layered pipeline**, not a
universal package format:

1. one immutable source tag and stable cross-platform product version;
2. explicit target/host matrix, with native finalization where platform trust requires;
3. a reviewed stage tree as the contract between build and format generators;
4. several user-justified artifact models, not every available suffix;
5. stable platform identities and upgrade tests established before first publication;
6. byte-changing transforms completed before final checksums;
7. platform code signatures, repository signatures, and provenance treated as separate
   layers;
8. immutable release-host assets as the source for downstream indexes;
9. package indexes/updater feeds generated from actual final digests;
10. promotion by metadata/channel movement, never rebuild.

This consensus is supported across [cargo-dist][cargo-dist], [GoReleaser][goreleaser],
[JReleaser][jreleaser], [CPack][cpack], platform-native formats, and repository/update
systems; [release pipeline] expresses it as gates.

## Architectural trade-offs

| Decision            | One pole                     | Other pole                                                                                          |
| ------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------- |
| Format breadth      | one archive: low maintenance | native matrix: policy/admin integration ([artifact formats][formats])                               |
| Dependency policy   | rely on target system        | bundle runtime: larger but controlled ([AppImage][appimage], [jpackage][jpackage])                  |
| Installer semantics | portable/copy: transparent   | database-managed: repair/upgrade/policy ([WiX/MSI][wix], [Linux native][linux-native])              |
| Linux desktop       | direct AppImage              | runtime/confinement/store via Flatpak/Snap ([AppImage][appimage], [Flatpak][flatpak], [Snap][snap]) |
| Windows             | MSI compatibility/admin      | MSIX identity/clean deployment constraints ([WiX/MSI][wix], [MSIX][msix])                           |
| macOS               | DMG copy-install             | PKG privileged install ([macOS containers][macos-containers])                                       |
| Orchestration       | ecosystem-native automation  | general generator/facade ([cargo-dist][cargo-dist], [GoReleaser][goreleaser], [CPack][cpack])       |
| Updates             | manual/package-manager       | app-specific signed feed ([Velopack][velopack], [Conveyor][conveyor])                               |
| Build location      | project CI with owned keys   | repository/store build/review ([Flatpak][flatpak], [Snap][snap], [Homebrew][homebrew])              |

## The Sparkles delta

| Capability                 | Consensus exemplar                                                        | Sparkles today ([baseline][baseline])           | Delta                                              |
| -------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------- |
| Product/target manifest    | [cargo-dist][cargo-dist], [GoReleaser][goreleaser]                        | tag policy + Nix outputs, no application matrix | declare product, targets, artifact/channel policy  |
| Inspectable stage tree     | [CPack][cpack], [linuxdeploy][linuxdeploy], [macOS bundle][macos-bundles] | derivation-specific install phases              | define and validate per-product stages             |
| Portable archives          | [cargo-dist][cargo-dist], [GoReleaser][goreleaser]                        | no versioned release assets                     | produce target-named archives + checksums          |
| Native packages/bundles    | platform deep-dives                                                       | none                                            | add only formats justified by users                |
| Stable native identities   | [WiX][wix], [MSIX][msix], [macOS bundles][macos-bundles]                  | repo/Dub package identity only                  | reserve IDs/GUID policy before publication         |
| Native-host release matrix | [electron-builder][electron-builder], [jpackage][jpackage]                | full Linux/macOS CI; narrow Windows example     | add full Windows build; separate package/sign jobs |
| Code signing/notarization  | [MSIX][msix], [macOS signing][macos-signing]                              | none                                            | key custody, signing, notary, verification         |
| Installer lifecycle tests  | native formats                                                            | source/tests/examples only                      | clean-host install→launch→upgrade→uninstall        |
| Immutable release manifest | orchestrators                                                             | GitHub Release + Cachix pins, no asset manifest | final hashes/size/target/sign status               |
| SBOM/provenance            | [GoReleaser][goreleaser], [JReleaser][jreleaser]                          | pinned Nix inputs, no emitted statements        | generate final-artifact SBOM + provenance          |
| Package indexes            | [Linux repos][linux-repositories], [winget][winget], [Homebrew][homebrew] | code.dlang.org source registry only             | derive indexes from immutable release assets       |
| Update channels/promotion  | [Velopack][velopack], [Conveyor][conveyor], [Snap][snap]                  | highest-tag Cachix `latest-*` guard             | candidate/stable metadata and rollback policy      |

The delta does not imply Sparkles should implement every row immediately. The staged,
evidence-backed recommendation is in [recommendations].

## Pinned local source set

The synthesis was checked against local clones at these commits; sibling deep-dives own
the line-level findings and version context:

- [`cargo-dist@25b2af88`][src-cargo-dist] · [`cargo-packager@37a538e7`][src-cargo-packager]
- [`goreleaser@7630cd16`][src-goreleaser] · [`jreleaser@98de563b`][src-jreleaser]
- [`dotnet-releaser@a7f1a62d`][src-dotnet] · [`velopack@9ba46833`][src-velopack]
- [`conveyor@9e90ce7c`][src-conveyor] · [`briefcase@389be4fe`][src-briefcase] ·
  [`cx_Freeze@ecd80b36`][src-cx-freeze]
- [`electron-builder@39df92fd`][src-electron-builder] ·
  [`electron-forge@fc5fb4d4`][src-electron-forge]
- [`CMake/CPack@22fd26b6`][src-cmake] · [`fpm@f51ba16f`][src-fpm] ·
  [`nfpm@65958414`][src-nfpm] · [`swift-bundler@4ad3f14f`][src-swift-bundler]
- [`linuxdeploy@a9f929ff`][src-linuxdeploy] · [`appimagetool@8c8c91f7`][src-appimagetool]
- [`msix-packaging@efeb9dad`][src-msix] · [`WiX@c5b1c40c`][src-wix] ·
  [`winget-cli@22d5c7d8`][src-winget]
- [`Chocolatey@d43496ec`][src-chocolatey] · [`Scoop@b588a06e`][src-scoop] ·
  [`homebrew-core@2d16a4b6`][src-homebrew]

## Sources

Primary platform specifications are collected in [concepts] and
[artifact formats][formats]. Tool-specific claims resolve through the sibling deep-dives;
the pinned repositories above make the implementation snapshot explicit. Sparkles facts
come only from the audited [baseline].

<!-- References -->

[concepts]: ./concepts.md
[formats]: ./artifact-formats.md
[pipeline]: ./release-pipeline.md
[baseline]: ./sparkles-baseline.md
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
[src-cargo-dist]: https://github.com/axodotdev/cargo-dist/tree/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8
[src-cargo-packager]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9
[src-goreleaser]: https://github.com/goreleaser/goreleaser/tree/7630cd166fb4dbad0a29ea23cf5e941b66f72b09
[src-jreleaser]: https://github.com/jreleaser/jreleaser/tree/98de563b61df6232d38dafafa8d1f1728432c207
[src-dotnet]: https://github.com/xoofx/dotnet-releaser/tree/a7f1a62decd89e97297d55e6563fc246cac23d71
[src-velopack]: https://github.com/velopack/velopack/tree/9ba468337e367c59db339828b59c8a20a0f6ea90
[src-conveyor]: https://github.com/hydraulic-software/conveyor/tree/9e90ce7c2a4356c99d68c63f41e4bc497da279c8
[src-briefcase]: https://github.com/beeware/briefcase/tree/389be4fe5d4c890a1c7b558164f867d16e295bf0
[src-cx-freeze]: https://github.com/marcelotduarte/cx_Freeze/tree/ecd80b36d241ce67d648ede65bd2cd5ac10436c4
[src-electron-builder]: https://github.com/electron-userland/electron-builder/tree/39df92fd14d9a3788add09a3963028a48eed176e
[src-electron-forge]: https://github.com/electron/forge/tree/fc5fb4d4269cbce909fc59f570b8aa1e1add4090
[src-cmake]: https://github.com/Kitware/CMake/tree/22fd26b6c44ef5ae36eb6a70324c30776005b239/Source/CPack
[src-fpm]: https://github.com/jordansissel/fpm/tree/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99
[src-nfpm]: https://github.com/goreleaser/nfpm/tree/6595841499a18755f03356b69511f32a8cec2761
[src-swift-bundler]: https://github.com/stackotter/swift-bundler/tree/4ad3f14f0b4c292f5bb57105b834be7f321c4f05
[src-linuxdeploy]: https://github.com/linuxdeploy/linuxdeploy/tree/a9f929ff0e32d5c4bcb7b5c380adff4802f918ba
[src-appimagetool]: https://github.com/AppImage/appimagetool/tree/8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81
[src-msix]: https://github.com/microsoft/msix-packaging/tree/efeb9dad695a200c2beaddcba54a52c8320bd135
[src-wix]: https://github.com/wixtoolset/wix/tree/c5b1c40cd44145a24cb82349d988e7abdd0b94d5
[src-winget]: https://github.com/microsoft/winget-cli/tree/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1
[src-chocolatey]: https://github.com/chocolatey/choco/tree/d43496ec679960a0df6e0a19738ac62587fd20ee
[src-scoop]: https://github.com/ScoopInstaller/Scoop/tree/b588a06e41d920d2123ec70aee682bae14935939
[src-homebrew]: https://github.com/Homebrew/homebrew-core/tree/2d16a4b686030251a4b801338d28948b1ba690b5
