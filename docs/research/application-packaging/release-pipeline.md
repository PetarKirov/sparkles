# Release Pipeline

A platform-neutral dataflow for producing installable application releases without
flattening platform-specific trust and repository rules. The central invariant is:
**build each target from an immutable source identity, transform it in an auditable
order, then promote the same verified bytes**.

**Last reviewed:** July 12, 2026

## The model

```text
source tag
    ↓
target-matrix binaries
    ↓
per-target stage trees
    ↓
archives / bundles / native packages
    ↓
sign → notarize where required → staple where supported
    ↓
final checksums + SBOM + provenance
    ↓
immutable release host
    ↓
repository/store/community-index metadata
    ↓
channel promotion (candidate → stable), never rebuild
```

Each arrow is a provenance boundary. Cross-platform orchestrators automate different
subsets: [cargo-dist][cargo-dist], [GoReleaser][goreleaser], [JReleaser][jreleaser],
[dotnet-releaser][dotnet-releaser], and [electron-builder][electron-builder] span matrix
builds through publication; [CPack][cpack], [fpm/nfpm][fpm-nfpm],
[cargo-packager][cargo-packager], [Briefcase][briefcase], [cx_Freeze][cx-freeze],
[`jpackage`][jpackage], and [swift-bundler][swift-bundler] concentrate on stage/package
construction; [Velopack][velopack] and [Conveyor][conveyor] extend identity into updater
feeds. None makes the target platform's signing or repository policy disappear.

## 1. Source tag: the immutable intent

The release begins from a signed or otherwise protected source identity, normally a
SemVer tag. The tag selects source, version, and release notes; workflow inputs may select
a channel but must not silently change payload contents. The release job should reject a
dirty tree, unexpected branch, missing tag, duplicate version, or tag/version mismatch
before consuming signing credentials ([Sparkles baseline][baseline],
[cargo-dist][cargo-dist], [GoReleaser][goreleaser]).

For Sparkles today, annotated `vX.Y.Z` tags are the sole package version; pushing a tag
can make it visible to code.dlang.org independently of GitHub Release publication. That
irreversibility is a current fact, not a recommendation ([Sparkles baseline][baseline]).

## 2. Target-matrix binaries

Compile one binary set per supported target tuple, recording at least:

- source tag and commit digest;
- compiler/linker and SDK identity;
- target architecture, OS, ABI, minimum OS/libc baseline;
- feature/configuration flags and dependency lock digest;
- test results associated with the same commit.

A matrix row is not yet a distributable artifact. A Linux binary may bind to too-new
`glibc`; a Windows executable may need adjacent DLLs and Authenticode; a macOS binary may
need universal slices, rewritten load commands, entitlements, and nested signatures
([platform gotchas][gotchas], [Linux native][linux-native], [WiX/MSI][wix],
[macOS bundles][macos-bundles], [macOS signing][macos-signing]).

Cross-compilation is valid only where the compiler, packager, verifier, and signer support
it. Prefer native hosted runners for final Windows and macOS artifacts until an explicit
reproducible cross-host path is demonstrated ([comparison][comparison]).

## 3. Per-target stage trees

Normalize binaries into a declared stage-tree schema before generating formats. A CLI
stage might contain `bin/`, license/notices, completions, and man pages; GUI stages add
icons, desktop metadata, frameworks, resources, and launchers. Make the stage tree an
inspectable CI artifact and validate:

- only expected files are present;
- executable modes and symlinks are correct;
- runtime library resolution closes over the intended bundle/system boundary;
- licenses/notices accompany redistributed dependencies;
- metadata identity/version/architecture match the source tag;
- smoke tests run from the stage, outside the build directory.

This separates payload correctness from format generators. `AppDir`, `.app`, CMake
install trees, and Electron/Python application directories instantiate the same concept
([linuxdeploy/appimagetool][linuxdeploy], [macOS bundles][macos-bundles], [CPack][cpack],
[electron-builder][electron-builder], [Briefcase][briefcase], [cx_Freeze][cx-freeze]).

## 4. Packages and bundles

Fan each validated stage into only the formats justified by a user/channel need:

- archives for direct CLI downloads ([Windows portable][windows-portable],
  [cargo-dist][cargo-dist]);
- `.deb`/RPM/Arch packages plus repositories for Linux-native administration
  ([Linux native][linux-native], [repositories][linux-repositories],
  [fpm/nfpm][fpm-nfpm]);
- AppImage, Flatpak, or Snap for distinct Linux portable/sandboxed delivery models
  ([AppImage][appimage], [Flatpak][flatpak], [Snap][snap]);
- MSI/MSIX or setup EXE on Windows ([WiX/MSI][wix], [MSIX][msix],
  [Inno/NSIS][inno-nsis]);
- `.app` inside DMG, or PKG where privileged installation is genuinely required
  ([macOS bundles][macos-bundles], [macOS containers][macos-containers]).

Run format-native inspection before signing (`dpkg-deb`, RPM query/verify tools, MSI
validation, MSIX tooling, `codesign` structure inspection). Installation tests must use
clean disposable VMs/containers and cover install, launch, upgrade, and uninstall where
the format promises them. This survey does not claim those tests have been run for
Sparkles ([Sparkles baseline][baseline]).

## 5. Sign, notarize, staple

Trust operations are ordered from inner code to outer delivery object:

1. sign leaf executables/libraries/helpers where the platform requires;
2. sign the enclosing bundle/package/installer;
3. submit supported Apple artifacts for notarization;
4. staple the accepted ticket to supported objects;
5. verify signatures and policy from a fresh target host.

Windows Authenticode/MSIX and Apple Developer ID are separate credential systems; Linux
repository metadata uses repository keys and should not be conflated with executable code
signing ([WiX/MSI][wix], [MSIX][msix], [macOS signing][macos-signing],
[Linux repositories][linux-repositories]). Signing secrets should be unavailable to pull
requests and untrusted build steps. Where practical, isolate signing from compilation and
accept only digest-addressed inputs.

Because signing and stapling can change bytes, any checksum or SBOM tied to the final
artifact must be emitted after them. An SBOM describing the unsigned stage may still be
useful, but its relationship to the signed container must be recorded explicitly
([concepts][concepts]).

## 6. Final checksums, SBOM, and provenance

For every final artifact, emit a manifest containing filename, media/format, target,
size, cryptographic digest, source tag/commit, and signing status. Add:

- an SPDX or CycloneDX SBOM for shipped components;
- provenance identifying builder/workflow and source/material digests;
- detached signatures or attestations where the delivery client understands them;
- a machine-readable release manifest used by downstream index generation.

The release manifest should be generated from actual bytes, not duplicated handwritten
configuration. [cargo-dist][cargo-dist], [GoReleaser][goreleaser], and
[JReleaser][jreleaser] illustrate orchestrators growing from archive production toward
checksums, attestations/SBOMs, and publisher integrations; exact support and defaults
belong to their deep-dives.

> [!IMPORTANT]
> A checksum posted next to an artifact on the same compromised origin is an integrity
> aid, not independent publisher authentication. Repository signatures, code signatures,
> and provenance answer different trust questions ([concepts § signing
> layers][concepts-signing]).

## 7. Immutable release host

Upload by digest/version and reject replacement. The host is the canonical origin for
community catalogs that reference URLs and hashes: winget, Scoop, Homebrew casks/formulae,
and Chocolatey packaging all become fragile if an asset at a stable URL mutates
([winget][winget], [scoop][scoop], [homebrew][homebrew], [chocolatey][chocolatey]).

Publication should be idempotent: rerunning may verify or fill a missing asset but must
not overwrite a different digest for the same version. GitHub Release, object storage,
and package repositories require different APIs; orchestrators can coordinate them but
cannot supply immutability if the host allows destructive replacement
([GoReleaser][goreleaser], [JReleaser][jreleaser]).

## 8. Package indexes and repositories

Generate channel metadata from the immutable release manifest:

- APT/RPM/pacman repositories index package identity, architecture, version,
  dependencies, path, size, and hashes, then sign repository metadata
  ([Linux repositories][linux-repositories]);
- Flatpak/Snap publish repository/store-native refs, assertions, and channels
  ([Flatpak][flatpak], [Snap][snap]);
- winget, Chocolatey, Scoop, and Homebrew add ecosystem-specific manifests/recipes that
  reference or rebuild from upstream artifacts ([winget][winget], [chocolatey][chocolatey],
  [scoop][scoop], [homebrew][homebrew]);
- Velopack/Conveyor produce updater metadata whose identity, channel, signature, and
  rollout semantics become part of the application contract ([Velopack][velopack],
  [Conveyor][conveyor]).

Treat index publication as a separate, reviewable job with least-privilege credentials.
A package index should consume final artifact digests rather than trigger a second build.

## 9. Promotion and rollback

A candidate release passes installation/upgrade smoke tests before its existing digest is
made visible in `stable`. Promotion should update signed metadata or channel pointers,
not recompile or repackage. Record the prior channel state so metadata can be rolled back
when the client model permits; never “fix” a published version by replacing its bytes.
Flatpak refs, Snap channels, package-repository suites, and updater feeds provide concrete
channel mechanisms ([Flatpak][flatpak], [Snap][snap], [Linux repositories][linux-repositories],
[Velopack][velopack]).

## Pipeline acceptance matrix

| Gate         | Evidence required                                              | Failure stops         |
| ------------ | -------------------------------------------------------------- | --------------------- |
| Source       | protected tag/commit, clean version mapping                    | all downstream work   |
| Binary       | target metadata, tests, dependency/load audit                  | stage creation        |
| Stage        | inventory, launch smoke test, notices                          | packaging             |
| Package      | native inspection + clean-host install/upgrade/uninstall       | signing/publication   |
| Trust        | signature verification; Apple acceptance + staple verification | checksums/publication |
| Supply chain | final digest manifest, SBOM, provenance                        | stable publication    |
| Host         | immutable upload confirmed by read-back digest                 | index generation      |
| Index        | schema/policy validation + signature                           | promotion             |
| Promotion    | candidate smoke results and explicit approval                  | stable channel        |

This is a recommended validation model derived from the surveyed systems, not current
Sparkles behavior. The incremental adoption path is in [recommendations].

## Sources

- Shared definitions and primary specifications: [concepts][concepts].
- Format mechanics: [artifact formats][formats] and the linked format deep-dives.
- Current repository behavior: [Sparkles baseline][baseline].
- Tool-specific automation claims: the linked deep-dives, pinned to local source commits.

<!-- References -->

[concepts]: ./concepts.md
[concepts-signing]: ./concepts.md#signing-layers-and-trust-boundaries
[formats]: ./artifact-formats.md
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
[cpack]: ./cpack.md
[fpm-nfpm]: ./fpm-nfpm.md
[jpackage]: ./jpackage.md
[swift-bundler]: ./swift-bundler.md
