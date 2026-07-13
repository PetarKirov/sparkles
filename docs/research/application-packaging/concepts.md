# Application-Packaging Concepts

The shared vocabulary for the survey. Packaging discussions become ambiguous when
“build,” “package,” “installer,” and “release” are used as synonyms; this page assigns
each operation a narrow meaning and connects it to concrete platform contracts.

**Last reviewed:** July 12, 2026

## The verbs

### Build

**Build** transforms source and declared inputs into target binaries/resources. It is
compiler/linker work, not packaging: the output may still depend on paths or shared
libraries unavailable on an end-user machine. Cross-platform orchestrators such as
[cargo-dist][cargo-dist], [GoReleaser][goreleaser], and [JReleaser][jreleaser] can drive
or consume builds; [CPack][cpack] ordinarily consumes an install tree produced by the
build system.

### Stage

**Stage** materializes the exact filesystem tree a later package will consume, normally
under a disposable root: executable, libraries, resources, license, completions, icons,
and metadata at their final relative paths. Staging is where permissions and symlink
targets become reviewable without yet invoking an installer database. An AppImage
`AppDir` ([linuxdeploy/appimagetool][linuxdeploy]), a macOS `.app` directory
([macOS bundles][macos-bundles]), and CMake's component install tree ([CPack][cpack])
are concrete stage trees.

### Package and bundle

**Package** serializes a staged payload plus install metadata into a defined artifact
format. A `.deb`, `.rpm`, MSI, MSIX, or PKG carries package-manager semantics, not only
compression ([Linux native packages][linux-native], [WiX/MSI][wix], [MSIX][msix],
[macOS containers][macos-containers]).

**Bundle** collects an application and selected runtime dependencies into a layout meant
to execute together. Bundling answers “what travels with the program?”; packaging answers
“what format and install contract contains it?” A `.app` is a bundle directory that may
then be transported in a DMG or installed by a PKG ([macOS bundles][macos-bundles],
[macOS containers][macos-containers]). AppImage, Python freezers, Electron tools, and
`jpackage` combine both operations ([AppImage][appimage], [Briefcase][briefcase],
[cx_Freeze][cx-freeze], [electron-builder][electron-builder], [jpackage][jpackage]).

### Sign

**Sign** computes a cryptographic signature over designated bytes and binds them to a
publisher identity recognized by the verifier. Signing is format-specific and layered:
Authenticode signs Windows executables/MSI/MSIX; Apple Code Signing seals nested code and
the outer bundle/container; Linux repositories sign metadata and may also sign package
files. Signing is not equivalent to transport encryption, malware review, or
notarization ([WiX/MSI][wix], [MSIX][msix], [macOS signing][macos-signing],
[Linux repositories][linux-repositories]). Because signatures cover bytes, signing must
follow every byte-changing transformation it is meant to authenticate.

### Notarize and staple

On macOS, **notarize** means submit a signed artifact to Apple's notary service for
asynchronous automated checks and receive a ticket associated with its digest. It does
not replace Developer ID signing. **Staple** means attach that ticket to a supported
artifact so Gatekeeper can validate without reaching the service. The order is therefore
bundle nested code → sign inside-out → package the submission → notarize → staple the
accepted ticket; exact supported containers and commands belong to
[macOS signing/notarization][macos-signing]. Stapling changes the outer artifact and must
precede final checksums.

### Publish and promote

**Publish** copies an immutable artifact and its metadata to a release host, repository,
store, or catalog endpoint. Uploading a GitHub asset, pushing repository objects, and
submitting a winget manifest are different publication operations
([cargo-dist][cargo-dist], [Linux repositories][linux-repositories], [winget][winget]).

**Promote** changes channel/index reachability without rebuilding the payload—for example,
advancing an already-verified digest from `candidate` to `stable`. Promotion preserves
the “same bytes, more users” invariant; rebuilding for each channel destroys that
property. Repository-native systems and updater feeds make this distinction explicit
([Flatpak][flatpak], [Snap][snap], [Velopack][velopack], [Conveyor][conveyor]).

## Payload and manifest

A **payload** is the content delivered to the target: executables, dynamic libraries,
resources, notices, and sometimes a runtime. A **manifest** is structured control data:
identity, version, architecture, dependencies, install destinations, capabilities,
entry points, checksums, and URLs. Formats vary in where they store it—Debian control
members, RPM headers, AppImage desktop metadata, Flatpak manifests, MSI tables, MSIX
`AppxManifest.xml`, macOS `Info.plist`, winget YAML—but payload and manifest remain
separate conceptual layers ([Linux native][linux-native], [AppImage][appimage],
[Flatpak][flatpak], [WiX/MSI][wix], [MSIX][msix], [macOS bundles][macos-bundles],
[winget][winget]). A catalog manifest may contain no payload at all; winget, Scoop, and
Homebrew casks commonly reference upstream artifacts ([winget][winget], [scoop][scoop],
[homebrew][homebrew]).

## Four delivery models

| Model                  | Payload location                                    | Installation ownership                                | Exemplars                                                                                                                 |
| ---------------------- | --------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Portable**           | archive/directory travels whole                     | user or app; little/no system registration            | [Windows portable][windows-portable], archive releases from [cargo-dist][cargo-dist] and [GoReleaser][goreleaser]         |
| **Bundling**           | app carries selected runtime/deps                   | bundle may run directly or sit inside an installer    | [AppImage][appimage], [macOS `.app`][macos-bundles], [Briefcase][briefcase], [cx_Freeze][cx-freeze], [jpackage][jpackage] |
| **Native package**     | package payload installed into OS-defined locations | package database owns files, repair/uninstall/upgrade | [`.deb`/`.rpm`/Arch][linux-native], [MSI][wix], [MSIX][msix], [PKG][macos-containers]                                     |
| **Fetching installer** | bootstrap resolves payload at install/update time   | installer/feed jointly own acquisition and state      | [Conveyor][conveyor], updater systems in [Velopack][velopack]                                                             |

These models are not quality levels. Portable artifacts minimize installation side
effects but cannot automatically supply a system package database's dependency,
transaction, or policy semantics; native packages gain those semantics by accepting
platform-specific metadata and review ([artifact formats][formats]).

## Identity, version, and upgrades

An artifact's filename is not its identity. Package managers compare a stable identifier
and a format-specific version; installers also retain upgrade lineage:

- Debian/RPM/Arch have distinct package names, epochs/releases, dependency grammars, and
  version comparators ([Linux native][linux-native]).
- MSI distinguishes `ProductCode`, `PackageCode`, component GUIDs, and `UpgradeCode`;
  changing the wrong identity can turn an upgrade into a side-by-side install or break
  servicing ([WiX/MSI][wix]).
- MSIX uses manifest identity and package-family semantics; signatures and publisher
  identity participate in trust and update compatibility ([MSIX][msix]).
- macOS bundles use a reverse-DNS `CFBundleIdentifier` and version keys; the signing
  designated requirement identifies code independently of the DMG filename
  ([macOS bundles][macos-bundles], [macOS signing][macos-signing]).

An **upgrade** replaces an installed identity according to that system's ordering and
compatibility rules. An **update channel** is a named stream such as `nightly`, `beta`,
or `stable`; it controls which signed metadata and versions a client sees. A **rollback**
is an explicit move to an older known artifact, not merely “install a lower version,”
which some systems reject. Repository/store clients own this most naturally; portable
archives need a separate updater or manual replacement ([Flatpak][flatpak], [Snap][snap],
[Velopack][velopack], [Conveyor][conveyor]).

## Signing layers and trust boundaries

A release may need several independent signatures:

1. **Code/object signature** — executable, library, `.app`, MSI/MSIX, or installer EXE.
2. **Container signature** — the outer package/image where the format supports it.
3. **Repository metadata signature** — authenticates the index that maps identity/version
   to payload digest and URL ([Linux repositories][linux-repositories]).
4. **Transparency/provenance signature** — authenticates a build statement or
   attestation, not installability itself ([release pipeline][pipeline]).

Each answers a different question. A signed executable downloaded through an unsigned
mutable index is still vulnerable to substitution unless the client verifies the object
signature; a signed repository does not prove who compiled the binary; notarization is
an external service verdict layered over Apple signing ([macOS signing][macos-signing]).

Key custody is part of the architecture: CI secrets, hardware/cloud signing services,
short-lived identity, and platform credentials have different blast radii. The survey's
orchestrators vary in whether they merely call platform signers or model the whole trust
stage ([cargo-dist][cargo-dist], [electron-builder][electron-builder],
[JReleaser][jreleaser], [Conveyor][conveyor]).

## Target triples, host triples, and universal binaries

A **target triple** identifies the machine/OS/ABI for generated code—commonly
`architecture-vendor-os-environment`, though ecosystems normalize spellings differently.
A **host** is the system running the build/package command. Cross-compilation answers
whether host and target may differ; packaging adds a second constraint because native
installer builders, SDKs, signers, and validators may require the target OS even when the
compiler does not ([comparison][comparison], [platform gotchas][gotchas]).

A **universal binary** contains multiple architecture slices in one Mach-O file, commonly
`arm64` and `x86_64`; every nested executable/library must have compatible slices before
an application is signed. A universal `.app` is not made by putting two unrelated app
directories beside one another ([macOS bundles][macos-bundles], [macOS signing][macos-signing]).
Windows multi-architecture delivery normally uses separate payloads or an MSIX bundle
([MSIX][msix]); Linux repositories index architecture-specific packages
([Linux repositories][linux-repositories]).

## Checksums, SBOM, provenance, and reproducibility

A **checksum** detects byte changes and gives indexes a stable content identifier; it
does not identify the producer unless delivered through an authenticated channel. An
**SBOM** inventories components in a format such as SPDX or CycloneDX. **Provenance**
records how an artifact was produced—source/material digests, builder identity, command
or workflow context—often using an in-toto/SLSA statement. They are complementary:
checksums bind bytes, SBOMs describe contents, provenance describes production
([release pipeline][pipeline], [cargo-dist][cargo-dist], [GoReleaser][goreleaser],
[JReleaser][jreleaser]).

A **reproducible build** yields bit-identical output for the same declared inputs.
Determinism is format-sensitive: timestamps, file ordering, compression metadata,
absolute paths, code signatures, notarization tickets, and installer database fields can
all vary. “Built in Nix” means inputs are unusually well pinned; it does not by itself
prove that a signed MSI, DMG, or AppImage is bit-reproducible. Reproducibility must be
measured per final artifact ([Sparkles baseline][baseline], [platform gotchas][gotchas]).

## Sources

- [Semantic Versioning 2.0.0][semver]
- [SLSA provenance model][slsa]
- [in-toto Attestation Framework][in-toto]
- [SPDX specification][spdx] and [CycloneDX specification][cyclonedx]
- [Apple Code Signing Guide][apple-code-signing] and [Notarizing macOS software][apple-notary]
- [Microsoft MSIX package requirements][msix-docs] and [Windows Installer documentation][msi-docs]
- [Debian binary package format][deb-spec], [RPM package format][rpm-format], and
  [Arch package format][arch-format]
- Tool- and format-specific primary sources are pinned in each linked sibling deep-dive.

<!-- References -->

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
[winget]: ./winget.md
[scoop]: ./scoop.md
[homebrew]: ./homebrew.md
[macos-bundles]: ./macos-app-bundles.md
[macos-containers]: ./macos-dmg-pkg-xip.md
[macos-signing]: ./macos-signing-notarization.md
[cargo-dist]: ./cargo-dist.md
[cargo-packager]: ./cargo-packager.md
[goreleaser]: ./goreleaser.md
[jreleaser]: ./jreleaser.md
[velopack]: ./velopack.md
[conveyor]: ./conveyor.md
[briefcase]: ./briefcase.md
[cx-freeze]: ./cx-freeze.md
[electron-builder]: ./electron-builder.md
[cpack]: ./cpack.md
[jpackage]: ./jpackage.md
[semver]: https://semver.org/spec/v2.0.0.html
[slsa]: https://slsa.dev/spec/v1.2/provenance
[in-toto]: https://github.com/in-toto/attestation/blob/main/spec/README.md
[spdx]: https://spdx.github.io/spdx-spec/v3.0.1/
[cyclonedx]: https://cyclonedx.org/specification/overview/
[apple-code-signing]: https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Introduction/Introduction.html
[apple-notary]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
[msix-docs]: https://learn.microsoft.com/windows/msix/package/packaging-uwp-apps
[msi-docs]: https://learn.microsoft.com/windows/win32/msi/windows-installer-portal
[deb-spec]: https://www.debian.org/doc/debian-policy/ch-binary.html
[rpm-format]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/manual/format_v6.md
[arch-format]: https://man.archlinux.org/man/PKGBUILD.5
