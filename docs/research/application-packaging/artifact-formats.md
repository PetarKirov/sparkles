# Artifact Formats

A format-level comparison of the artifacts this survey's tools produce. This page
compares install contracts, not packager brands: a generator can emit several formats,
but each resulting artifact still obeys its platform's identity, dependency, signing,
and upgrade rules.

**Last reviewed:** July 12, 2026

## At a glance

| Format                     | Structure / payload                                                | Install model                                         | Dependency model                           | Trust / update center                                             | Primary deep-dive                                                                        |
| -------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------- | ------------------------------------------ | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Archive (`.zip`, `.tar.*`) | generic file tree                                                  | extract and run/copy                                  | bundle or document prerequisites           | checksum/object signature; manual or separate updater             | [Windows portable][windows-portable], [cargo-dist][cargo-dist], [GoReleaser][goreleaser] |
| Debian `.deb`              | `ar` members: control + data tar archives                          | `dpkg` database; normally APT                         | Debian control relationships               | repository metadata + package policy                              | [Linux native packages][linux-native], [repositories][linux-repositories]                |
| RPM                        | lead/signature/header/payload format                               | RPM database; DNF/Zypper/etc.                         | RPM capabilities/dependencies              | package/repository signatures                                     | [Linux native packages][linux-native], [repositories][linux-repositories]                |
| Arch package               | compressed tar payload + `.PKGINFO`                                | pacman database                                       | Arch dependency strings                    | repository database + package signatures                          | [Linux native packages][linux-native], [repositories][linux-repositories]                |
| AppImage                   | executable filesystem image + runtime                              | mount/extract and run                                 | mostly bundled; base-system exclusions     | direct-download signature/checksum; optional update info          | [AppImage][appimage], [linuxdeploy/appimagetool][linuxdeploy]                            |
| Flatpak                    | OSTree content + metadata; optional single-file bundle             | per-user/system installation from remote              | runtimes + declared permissions            | signed remote/repository; managed updates                         | [Flatpak][flatpak]                                                                       |
| Snap                       | SquashFS image + snap metadata/assertions                          | snapd mount + confinement                             | base/content snaps + bundled payload       | assertion chain / Snap Store; channels                            | [Snap][snap]                                                                             |
| MSI                        | relational installer database in structured storage                | Windows Installer transaction                         | features/components/custom actions         | Authenticode + MSI servicing identity                             | [WiX/MSI][wix]                                                                           |
| MSIX                       | ZIP-derived Open Packaging Convention package + manifest/block map | registered package deployment                         | framework packages / declared dependencies | mandatory package signature in normal deployment; managed updates | [MSIX][msix]                                                                             |
| macOS `.app`               | directory bundle (`Contents/…`)                                    | run in place or copy                                  | bundled frameworks/resources               | nested code signatures + bundle identity                          | [macOS bundles][macos-bundles], [signing][macos-signing]                                 |
| DMG                        | mountable disk image                                               | drag/copy or carry other artifacts                    | whatever enclosed app/PKG uses             | signed/notarized outer delivery as applicable                     | [macOS containers][macos-containers], [signing][macos-signing]                           |
| PKG                        | XAR product/component installer archive                            | Installer writes receipts/system paths                | installer distribution/components          | Developer ID Installer signing + notarization                     | [macOS containers][macos-containers], [signing][macos-signing]                           |
| XIP                        | signed XAR-like archive expanded by Archive Utility                | authenticated expansion, not general app installation | payload-defined                            | Apple signing verification                                        | [macOS containers][macos-containers]                                                     |

## Portable archives

An archive preserves a staged file tree with almost no installation semantics. That is
its strength: transparent contents, straightforward cross-host creation, and a clean fit
for command-line applications whose contract is “put this executable on `PATH`.” It is
also its limit: no OS package database, file ownership, repair, dependency solver,
capability declaration, Start-menu registration, Gatekeeper bundle layout, or native
rollback. Those must be handled by instructions, scripts, a package index, or an updater
([Windows portable][windows-portable], [cargo-dist][cargo-dist], [GoReleaser][goreleaser],
[Velopack][velopack]).

Archive determinism depends on normalized entry order, timestamps, uid/gid, modes,
symlink encoding, and compressor settings. A checksum belongs after archive creation and
any signing/notarization that changes the distributed bytes ([release pipeline][pipeline]).

## Linux database-managed packages

### Debian `.deb`

A binary `.deb` is an `ar` archive whose required members include `debian-binary`, a
compressed control archive, and a compressed data archive. The control metadata names
the package, architecture, version, dependencies, maintainer scripts, and conffile
behavior. `dpkg` owns installation state; APT adds repository indexes, dependency
resolution, and authenticated acquisition ([Debian Policy][deb-policy],
[Linux native packages][linux-native], [repositories][linux-repositories]).

### RPM

RPM stores package metadata in headers and the installed payload in a cpio-based archive
(compression varies). Capability dependencies, scriptlets, file metadata, and package
signatures are native concepts; DNF/Zypper-family clients add repository metadata and
resolution. RPM's epoch/version/release ordering and distro policy are not interchangeable
with Debian's even when the payload tree is identical ([RPM format][rpm-format],
[Linux native packages][linux-native], [repositories][linux-repositories]).

### Arch packages

An Arch package is a compressed tar archive with metadata files such as `.PKGINFO`; pacman
owns installation and repository databases. Arch's rolling-release policy, dependency
syntax, package naming, and `pkgver`/`pkgrel` semantics remain Arch-specific. “Can emit a
`.pkg.tar.zst`” is therefore weaker than “meets Arch packaging policy” ([PKGBUILD][pkgbuild],
[Linux native packages][linux-native], [fpm/nfpm][fpm-nfpm]).

Across all three, native packages should normally be produced per distribution family
and architecture, tested in representative roots, and published through a signed
repository rather than treated as differently suffixed archives
([Linux repositories][linux-repositories], [platform gotchas][gotchas]).

## Linux self-contained and sandboxed artifacts

### AppImage

An AppImage combines a small runtime with a filesystem image containing an `AppDir`-style
application tree. The user marks it executable and runs it; the image is mounted or
extracted rather than registered in a universal system package database. Portability is
a deliberate dependency-selection exercise, not “copy every shared object”: core system
libraries and kernel/filesystem/FUSE realities define the compatibility boundary
([AppImage specification][appimage-spec], [AppImage][appimage],
[linuxdeploy/appimagetool][linuxdeploy]).

### Flatpak

Flatpak packages applications against named runtimes and distributes content through
OSTree repositories. The manifest declares runtime/SDK, finish arguments (permissions),
and build modules. Installation may be per-user or system-wide; remotes, refs, and OSTree
content make deduplication, updates, and rollback repository-native. A `.flatpak` bundle
is a transport form, not the whole Flatpak model ([Flatpak docs][flatpak-docs],
[Flatpak][flatpak]).

### Snap

A snap is a read-only SquashFS filesystem with metadata consumed by `snapd`; bases,
interfaces, confinement levels, assertions, and store channels are part of the system.
The installed artifact is mounted rather than expanded into normal filesystem ownership.
Store/channel semantics and the daemon are therefore inseparable from the user experience
([Snap format][snap-format], [Snap][snap]).

AppImage optimizes direct portable execution; Flatpak and Snap optimize managed,
constrained installation and updates. They are not interchangeable Linux “bundle
formats” ([comparison][comparison]).

## Windows installer formats

### MSI

MSI is a relational installation database interpreted by Windows Installer. Products
contain features and components; components are the unit of installation and servicing,
and GUID stability is a correctness constraint. Standard actions, conditions, rollback,
repair, advertised entry points, and major/minor/small update rules form a deployment
language. WiX compiles declarative source into that database; it does not change MSI's
servicing model ([Windows Installer][msi-docs], [WiX/MSI][wix]).

Custom actions are an escape hatch with sequencing, privilege, rollback, and reliability
costs. A portable ZIP or Inno/NSIS setup may be better when MSI enterprise deployment is
not a requirement ([Windows portable][windows-portable], [Inno/NSIS][inno-nsis]).

### MSIX

MSIX is ZIP/OPC-based and carries `AppxManifest.xml`, a block map, payload, and signature.
It emphasizes declarative install behavior, package identity, clean deployment, and
containerized/managed capabilities. Its identity/publisher and signing contracts are
stricter than MSI's, and filesystem/registry virtualization can conflict with assumptions
made by traditional desktop apps ([MSIX packaging][msix-docs], [MSIX][msix]). An
`.msixbundle` groups architecture/resource packages under one distributable unit.

MSI and MSIX are separate product decisions: MSI maximizes compatibility with traditional
Windows Installer administration; MSIX offers a more constrained modern deployment
contract ([comparison][comparison], [platform gotchas][gotchas]).

## macOS bundles and containers

### `.app`

A `.app` is a directory bundle, not an archive: `Contents/Info.plist`,
`Contents/MacOS/<executable>`, resources, frameworks, plug-ins, and helpers occupy defined
locations. Finder presents it as one object, while the code-signing system seals nested
code and resources. The executable's runtime library paths and the bundle's metadata must
agree with the staged layout ([Bundle Programming Guide][bundle-guide],
[macOS bundles][macos-bundles]).

### DMG

A DMG is a mountable disk image, commonly presenting a signed `.app` and an alias to
`/Applications`. It is a delivery container, not an installer database: dragging the app
copies the bundle. Filesystem format, window cosmetics, and mount behavior affect UX but
not application identity ([macOS containers][macos-containers]).

### PKG

A flat/distribution PKG is an installer archive that can place files in privileged
locations, run installer scripts, and leave receipts. It is appropriate when copying one
self-contained `.app` is insufficient; those same powers enlarge its security and
rollback surface. Developer ID **Installer** identity differs from Developer ID
**Application** identity used to sign app code ([macOS containers][macos-containers],
[macOS signing][macos-signing]).

### XIP

XIP is a signed archive used prominently by Apple for trusted distribution of large
bundles such as Xcode. It is not the normal third-party application format and should not
be selected merely because it appears beside DMG/PKG in tooling ([macOS containers][macos-containers]).

## Selection implications

| Need                                             | First format to evaluate       | Why / caveat                                                                                 |
| ------------------------------------------------ | ------------------------------ | -------------------------------------------------------------------------------------------- |
| Lowest-friction CLI download                     | archive                        | transparent and portable; add checksums and install instructions ([cargo-dist][cargo-dist])  |
| Linux distro-native dependency/admin integration | `.deb` + RPM, possibly Arch    | repository and policy work are part of delivery ([Linux repositories][linux-repositories])   |
| One-file Linux GUI/CLI download                  | AppImage                       | direct-run model; validate glibc/base-system compatibility ([AppImage][appimage])            |
| Sandboxed Linux desktop + managed updates        | Flatpak or Snap                | permissions/runtime/store are core, not optional wrappers ([Flatpak][flatpak], [Snap][snap]) |
| Windows enterprise deployment/repair             | MSI                            | component/GUID discipline required ([WiX/MSI][wix])                                          |
| Modern identity-based Windows deployment         | MSIX                           | signing and app-compat constraints required ([MSIX][msix])                                   |
| macOS drag-install                               | signed/notarized `.app` in DMG | bundle remains the code object; DMG is transport ([macOS signing][macos-signing])            |
| macOS privileged/system install                  | PKG                            | use only where copy-install is insufficient ([macOS containers][macos-containers])           |

This table is a decision aid, not a Sparkles commitment; the staged recommendation is in
[recommendations].

## Sources

- [Debian Policy: binary packages][deb-policy]
- [RPM package format][rpm-format]
- [Arch `PKGBUILD(5)`][pkgbuild]
- [AppImage specification][appimage-spec]
- [Flatpak documentation][flatpak-docs]
- [Snap format documentation][snap-format]
- [Windows Installer documentation][msi-docs]
- [MSIX packaging documentation][msix-docs]
- [Apple Bundle Programming Guide][bundle-guide]
- Per-format deep-dives carry pinned implementation repositories and additional primary
  specifications.

<!-- References -->

[pipeline]: ./release-pipeline.md
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
[macos-bundles]: ./macos-app-bundles.md
[macos-containers]: ./macos-dmg-pkg-xip.md
[macos-signing]: ./macos-signing-notarization.md
[cargo-dist]: ./cargo-dist.md
[goreleaser]: ./goreleaser.md
[velopack]: ./velopack.md
[fpm-nfpm]: ./fpm-nfpm.md
[deb-policy]: https://www.debian.org/doc/debian-policy/ch-binary.html
[rpm-format]: https://github.com/rpm-software-management/rpm/blob/375bdcdca7652755cdfdd1035f9d34250af48eff/docs/manual/format_v6.md
[pkgbuild]: https://man.archlinux.org/man/PKGBUILD.5
[appimage-spec]: https://docs.appimage.org/reference/specification.html
[flatpak-docs]: https://docs.flatpak.org/en/latest/
[snap-format]: https://snapcraft.io/docs/the-snap-format
[msi-docs]: https://learn.microsoft.com/windows/win32/msi/windows-installer-portal
[msix-docs]: https://learn.microsoft.com/windows/msix/package/packaging-uwp-apps
[bundle-guide]: https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html
