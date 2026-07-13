# Recommendations for Sparkles Application Packaging

An evidence-backed, staged roadmap from Sparkles' current tag/Nix release pipeline to
installable, signed, indexed application artifacts. This page proposes direction only;
it does not specify committed product support or implement code.

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> These are **recommendations**, not current capabilities. Current facts are confined to
> the [Sparkles baseline][baseline]. Every milestone should ship only after its acceptance
> tests run on the declared target hosts.

## Decision principles

1. **Start with a product and users, not a format count.** Sparkles is a monorepo of
   libraries plus applications. Packaging `apps/terminal` has GUI bundle/runtime needs;
   packaging `ci` or `release` as CLIs has a simpler archive/`PATH` contract. One format
   matrix should not be assumed to fit all three ([artifact formats][formats],
   [Sparkles baseline][baseline]).
2. **Keep the tag as version source of truth.** Derive native versions from the existing
   annotated `vX.Y.Z` tag through explicit per-format mappings; do not add competing
   manifest versions ([baseline][baseline], [platform gotchas][gotchas]).
3. **Make the stage tree the stable seam.** Nix/Dub build logic should produce a reviewed
   target tree; format tools consume it. This permits replacing an orchestrator without
   rewriting payload assembly ([release pipeline][pipeline], [CPack][cpack],
   [linuxdeploy/appimagetool][linuxdeploy]).
4. **Use native hosts for trust-critical finalization first.** Cross-build where proven,
   but package/sign Windows on Windows and Apple artifacts on macOS until an equivalent
   cross-host process is demonstrated ([comparison][comparison],
   [macOS signing][macos-signing], [MSIX][msix]).
5. **Publish immutable bytes once; generate indexes from their digests.** Promotion moves
   channel metadata, never rebuilds ([release pipeline][pipeline],
   [Linux repositories][linux-repositories], [winget][winget], [Homebrew][homebrew]).
6. **Prefer the smallest justified format set.** Every new installer adds identity,
   signing, upgrade, test, and support obligations ([platform gotchas][gotchas]).
7. **Adopt an orchestrator only after a proof against the ten dimensions.** Language
   affinity is secondary to consuming arbitrary D-built stage trees, native-host matrix,
   signing hooks, artifact manifest, and publisher/index outputs
   ([comparison][comparison]).

## Milestone 0 — Define the release contract

**Recommendation:** write a product-level packaging specification before selecting a
packager.

For each application, declare:

- stable product/package/bundle IDs and display names;
- source SemVer → Debian/RPM/Arch/MSI/MSIX/Apple version mappings;
- supported OS, architecture, minimum OS/libc, CPU, and installation scope;
- payload/runtime boundary and redistributed-license inventory;
- initial artifact/channel set and whether updates are package-manager, app-managed, or
  manual;
- signing identities, key custody, and pull-request isolation;
- previous-stable upgrade/uninstall/user-data policy.

**Evidence:** identity mistakes become servicing breaks in MSI/MSIX, macOS signing, native
packages, and updater feeds ([WiX/MSI][wix], [MSIX][msix],
[macOS bundles][macos-bundles], [Velopack][velopack], [Conveyor][conveyor]).

**Acceptance:** the spec names no unowned credential, no ambiguous version mapping, and no
format without a user/channel rationale.

## Resolved target artifact matrix

The initial target is deliberately narrow. This table resolves the product × host ×
artifact × channel decisions that later milestones implement; alternatives discussed
below are evaluation evidence, not undecided outputs.

| Product                | Target                               | Required first artifact                                    | Discovery/channel                                                               | Explicitly deferred                                              |
| ---------------------- | ------------------------------------ | ---------------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `ci`, `release` CLIs   | `x86_64-linux-gnu`                   | deterministic `.tar.xz` with SHA-256, SBOM, and provenance | immutable GitHub Release asset                                                  | `.deb`/RPM repositories, AppImage, Flatpak, Snap                 |
| `ci`, `release` CLIs   | `x86_64-pc-windows-msvc`             | signed portable `.zip`                                     | GitHub Release, then WinGet and Scoop manifests generated from the final digest | MSI, MSIX, Chocolatey, embedded updater                          |
| `ci`, `release` CLIs   | universal macOS (`arm64` + `x86_64`) | signed binaries in a notarization-tested `.zip`            | GitHub Release, then a Homebrew tap Formula                                     | PKG, XIP, embedded updater                                       |
| `terminal` desktop app | `x86_64-linux-gnu`                   | AppImage built with pinned runtime/tool inputs             | GitHub Release                                                                  | Flatpak and Snap until sandbox/portal/store ownership is staffed |
| `terminal` desktop app | `x86_64-pc-windows-msvc`             | signed Inno Setup installer `.exe`                         | GitHub Release, then WinGet                                                     | MSI and MSIX until enterprise/store servicing is a requirement   |
| `terminal` desktop app | universal macOS (`arm64` + `x86_64`) | signed/notarized/stapled `.app` in a DMG                   | GitHub Release, then a Homebrew Cask                                            | PKG and XIP                                                      |

`aarch64-linux` and Windows `arm64` remain future targets until the application and its
native dependency closure are continuously built and smoke-tested there. Native Linux
`.deb`/RPM packages are the first optional expansion after the matrix above, but they are
not part of the initial release contract. Package-manager entries always reference the
same immutable artifacts; they never trigger a second hidden compilation.

## Milestone 1 — Versioned portable archives and a release manifest

**Recommendation:** package both `ci` and `release` as the CLI products in the resolved
matrix. Begin on the already tested Linux/macOS hosts; add the required Windows ZIP once
the full application build is continuously green there.

Pipeline:

1. build from the release tag;
2. create normalized stage trees (`bin/`, license/notices, completions/docs if shipped);
3. smoke-run outside the build tree;
4. create deterministic archives where feasible;
5. emit one machine-readable release manifest with target, size, SHA-256, tag/commit, and
   toolchain identity;
6. attach immutable assets to the GitHub Release.

[cargo-dist][cargo-dist] and [GoReleaser][goreleaser] are strong reference designs for
archive naming, checksums, CI matrices, and release-host publication; neither should be
adopted blindly for D. A small repository-owned stage/archive layer may initially have
less integration risk, while [JReleaser][jreleaser] is worth evaluating if its publisher
breadth outweighs introducing a JVM control plane.

**Acceptance:** fresh-host extract→launch tests; digest read-back after upload; rerun is
idempotent and rejects changed bytes; no signing keys yet required.

## Milestone 2 — SBOM, provenance, and reproducibility measurement

**Recommendation:** enrich the manifest before multiplying formats.

- generate SPDX or CycloneDX SBOMs from the actual staged/shipped dependency closure;
- emit provenance binding source/material digests, workflow identity, and each final
  artifact digest;
- normalize archive timestamps/order/modes and run a two-build reproducibility check;
- record rather than hide unavoidable non-determinism.

Nix already pins much of Sparkles' build closure, which is a useful substrate but not
proof for final archives or signed packages ([baseline][baseline], [concepts § supply
chain][concepts-supply]). [GoReleaser][goreleaser], [JReleaser][jreleaser], and
[cargo-dist][cargo-dist] provide prior art for release-time checksums/SBOM/provenance.

**Acceptance:** SBOM and provenance resolve to the uploaded digest; a second isolated
build either matches or produces a documented diff classification.

## Milestone 3 — Native host coverage and signing foundations

**Recommendation:** make full application builds first-class on Windows and preserve the
current Linux/macOS matrix, then introduce signing as isolated jobs.

- Windows: build/smoke the selected CLIs/apps on `windows-latest`; establish Authenticode
  identity/timestamp service before installer work ([Windows portable][windows-portable],
  [WiX/MSI][wix]).
- macOS: reserve bundle IDs, create correct `.app` stages for GUI products, audit universal
  versus architecture-specific policy, sign nested code inside-out, enable hardened
  runtime/necessary entitlements, notarize and staple ([macOS bundles][macos-bundles],
  [macOS signing][macos-signing]).
- Linux: establish the oldest-supported builder and runtime dependency audit before
  claiming portable binaries ([AppImage][appimage], [platform gotchas][gotchas]).

Signing jobs should accept digest-addressed unsigned stages/artifacts, expose credentials
only on protected release events, and produce verification records. Final checksums must
be regenerated after signing/stapling ([release pipeline][pipeline]).

**Acceptance:** trust verification on fresh targets with no build-agent certificate/key
state; quarantined macOS download first launch; Windows signature verification; Linux
oldest-baseline launch.

## Milestone 4 — One native path per platform, chosen by product

**Recommendation:** add a narrow native matrix rather than every surveyed format.

### Linux

For a CLI, begin with `.tar.xz`/`.tar.gz`; add `.deb` and RPM only when native package
management is a stated need. Use [fpm/nfpm][fpm-nfpm] or [CPack][cpack] as generator
candidates, but maintain format-native metadata and validate in Debian/Ubuntu and
RPM-family clean roots. Publish through signed repositories only after package lifecycle
tests pass ([Linux native][linux-native], [Linux repositories][linux-repositories]).

For the `terminal` desktop application, ship AppImage as the selected direct-download
format ([AppImage][appimage], [linuxdeploy/appimagetool][linuxdeploy]). Flatpak and Snap
remain explicit future alternatives if sandbox/portal/runtime or Snap Store/channel
integration becomes a staffed product requirement ([Flatpak][flatpak], [Snap][snap]). Do
not present them as equivalent outputs.

### Windows

For `ci` and `release`, keep the selected signed portable ZIP and submit it to
Scoop/winget only after URLs and hashes are immutable ([Windows
portable][windows-portable], [Scoop][scoop], [winget][winget]). For `terminal`, ship an
Inno Setup installer as the selected conventional setup EXE
([Inno/NSIS][inno-nsis]). MSI remains the future enterprise-administration option
([WiX/MSI][wix]); MSIX remains the future Store/managed-identity option
([MSIX][msix]). Do not ship all three initially: each needs independent upgrade lineage.

### macOS

For a GUI application, ship a signed/notarized `.app` in a DMG. Add PKG only if the
payload truly requires privileged/shared-location installation; XIP is not recommended as
a routine third-party app format ([macOS bundles][macos-bundles],
[macOS containers][macos-containers], [macOS signing][macos-signing]). For `ci` and
`release`, ship the selected archive first, then publish the required Homebrew tap Formula
only after immutable assets/source recipes are stable ([Homebrew][homebrew]).

**Acceptance:** per-format clean-host install→launch→upgrade-from-previous-stable→uninstall;
identity remains recognized; user data follows documented policy; no stale files.

## Milestone 5 — Package indexes and community catalogs

**Recommendation:** generate downstream metadata from the release manifest; never
hand-copy hashes when automation can select final artifacts.

- vendor APT/RPM repositories only if Sparkles will operate signing keys, metadata
  refresh, retention, and key rotation ([Linux repositories][linux-repositories]);
- winget and Scoop manifests for stable Windows assets ([winget][winget], [Scoop][scoop]);
- Homebrew formula/cask according to whether the product is built from source/bottled or
  distributed as a macOS app ([Homebrew][homebrew]);
- Chocolatey only when its package-script/repository model provides distinct value over
  winget/Scoop ([Chocolatey][chocolatey]);
- Flatpak/Snap publication only alongside the corresponding runtime/confinement support
  commitment ([Flatpak][flatpak], [Snap][snap]).

Use separate least-privilege publication jobs and preserve review boundaries for
community repositories.

**Acceptance:** indexes validate with native tooling, install the expected digest, reject
a mutated upstream URL, and can be regenerated from release metadata alone.

## Milestone 6 — Candidate/stable promotion and updater decision

**Recommendation:** add channels only after immutable versioned artifacts and upgrade
tests are routine.

The initial channel model can be repository metadata (`candidate` and `stable`) with
explicit approval; promote the same digest. For package-manager-installed CLIs, prefer
package-manager updates over embedding an updater. For a desktop application needing
in-app phased/delta updates, evaluate [Velopack][velopack] and [Conveyor][conveyor]
against the ten-dimension spine—especially D/native payload input, code-signing custody,
feed identity, offline/full-package fallback, rollback, and self-update failure recovery.
Electron-specific update machinery is relevant only if the product adopts Electron
([electron-builder][electron-builder], [Electron Forge][electron-forge]).

**Acceptance:** previous stable updates to candidate and stable; interrupted update
recovers; signature/feed substitution fails closed; rollback policy is exercised; old
clients remain supported for the declared window.

## Orchestrator shortlist and proof task

No surveyed orchestrator is an obvious default for a D monorepo. Run the same bounded
proof with finalists:

| Candidate                        | Why evaluate                                                                   | Principal caution                                                           |
| -------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| [cargo-dist][cargo-dist]         | polished native CLI release pipeline and CI model                              | Cargo-centric discovery/build assumptions                                   |
| [GoReleaser][goreleaser]         | mature matrix, archives, Linux packages, publishers, supply-chain integrations | Go-centric build model; D stage ingestion must stay first-class             |
| [JReleaser][jreleaser]           | broad assembler/packager/releaser integrations                                 | JVM operational/configuration footprint                                     |
| [CPack][cpack]                   | consumes an install tree; many format generators                               | generator behavior/metadata differs; publishing and updates mostly external |
| [fpm/nfpm][fpm-nfpm]             | focused Linux native package construction                                      | not a complete cross-platform release pipeline                              |
| [cargo-packager][cargo-packager] | desktop-native artifact breadth                                                | Rust/Cargo assumptions and host/signing matrix                              |

The proof input is one prebuilt D stage tree; required outputs are Linux archive + one
native package, macOS archive/DMG on macOS, Windows ZIP/one installer on Windows, final
manifest/checksums, dry-run publication, and no second compilation hidden inside the
packager. Score all ten dimensions from [comparison]. Keep format-specific source files
where native semantics demand them; do not force one lowest-common-denominator manifest.

Language/runtime-specific systems—[Briefcase][briefcase], [cx_Freeze][cx-freeze],
[`jpackage`][jpackage], [dotnet-releaser][dotnet-releaser],
[electron-builder][electron-builder], [Electron Forge][electron-forge], and
[swift-bundler][swift-bundler]—are prior art, not recommended foundations for D unless
the packaged product actually adopts their ecosystem.

## Explicit non-goals for the first release

- every Linux format and community repository;
- simultaneous MSI, MSIX, Inno, and NSIS outputs;
- privileged macOS PKG without a payload requirement;
- an in-app updater for package-manager-installed CLIs;
- claiming reproducibility solely because Nix built the unsigned binary;
- cross-host Apple/Windows signing without a verified equivalence test;
- replacing already-published bytes to correct a release.

These exclusions follow directly from the maintenance and identity costs in
[comparison], [artifact formats][formats], and [platform gotchas][gotchas].

## Sources

The recommendations synthesize the [Sparkles baseline][baseline], the uniform
[comparison], the format contracts in [artifact formats][formats], the ordering model in
[release pipeline][pipeline], and the linked sibling deep-dives. They intentionally do
not claim a packager has been integrated or an installer tested in this checkout.

<!-- References -->

[concepts-supply]: ./concepts.md#checksums-sbom-provenance-and-reproducibility
[formats]: ./artifact-formats.md
[pipeline]: ./release-pipeline.md
[baseline]: ./sparkles-baseline.md
[comparison]: ./comparison.md
[gotchas]: ./platform-gotchas.md
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
