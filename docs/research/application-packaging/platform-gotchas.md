# Platform Gotchas

The non-portable constraints a shared release pipeline must expose rather than hide.
These are design and validation hazards grounded in platform contracts; they are not
claims that Sparkles has exercised the corresponding package formats.

**Last reviewed:** July 12, 2026

## Cross-platform hazards

### Compilation success is not package portability

A cross-compiled executable can still fail on the oldest supported target because of
libc/SDK baseline, loader paths, dynamically loaded plug-ins, CPU features, or an absent
runtime. Package construction adds format validators and signers that may be target-host
only. Record the minimum platform and audit the staged runtime closure on each target
([Linux native packages][linux-native], [Windows portable][windows-portable],
[macOS bundles][macos-bundles], [comparison § host matrix][comparison]).

### Version syntax and ordering differ

SemVer is a source-release policy, not a universal native comparator. Debian epochs and
revisions, RPM epoch/version/release, Arch `pkgver`/`pkgrel`, MSI's product-version
constraints, MSIX manifest versions, and Apple bundle version keys accept/order different
strings. Derive every native version from one SemVer tag through explicit, tested
mapping; never assume the raw tag is valid everywhere ([Linux native][linux-native],
[WiX/MSI][wix], [MSIX][msix], [macOS bundles][macos-bundles]).

### Identity must predate the first public package

Renaming a filename is cheap; changing package IDs, MSI upgrade/component GUIDs, MSIX
publisher identity, macOS bundle identifiers/designated requirements, or updater feed
IDs may fork upgrade lineage. Reserve stable identifiers and document their migration
policy before publishing version 1 of each format ([WiX/MSI][wix], [MSIX][msix],
[macOS bundles][macos-bundles], [Velopack][velopack], [Conveyor][conveyor]).

### Byte order matters

Compression, signing, notarization tickets, stapling, and repository generation can
change bytes or metadata. Final checksums must follow all byte-changing steps. Do not
unpack/repack a signed artifact unless the signature model explicitly permits it, and do
not replace a published URL with new bytes under the same version
([macOS signing][macos-signing], [winget][winget], [Scoop][scoop],
[release pipeline][pipeline]).

## Linux

### The oldest build environment sets the `glibc` floor

A dynamically linked Linux binary built on a new distribution may require newer symbol
versions than an older target provides. Containers do not fix this if their base is too
new. Choose and record a baseline builder, inspect versioned symbols/interpreter paths,
and smoke-test on the oldest supported distributions. AppImage's bundle does not
normally replace the kernel or every base-system library, so it inherits this problem
([AppImage][appimage], [linuxdeploy/appimagetool][linuxdeploy]).

### Bundling every `.so` is wrong

ELF dependency closure includes libraries that should travel and base-system/driver
interfaces that should not. `dlopen` plug-ins, NSS, OpenGL/Vulkan drivers, Wayland/X11,
GTK/Qt plug-ins, locale data, and licenses complicate automated copying. Treat
`linuxdeploy`'s result as inspectable staging output, not proof of compatibility
([linuxdeploy/appimagetool][linuxdeploy], [AppImage][appimage]).

### AppImage depends on execution environment details

The one-file model may rely on FUSE for mounting, while extraction is a distinct fallback.
Sandboxed/containerized hosts and distributions vary in FUSE availability and policy.
Desktop integration and updates are not guaranteed merely by producing an `.AppImage`;
metadata and companion tools determine those paths ([AppImage][appimage]).

### Native package formats are distro policy, not converters

A mechanically converted `.deb`/RPM/Arch package can be structurally valid yet violate
filesystem layout, dependency naming, maintainer-script, service, license, or repository
policy. Package names and dependency capabilities differ by distribution. Use
[fpm/nfpm][fpm-nfpm] and [CPack][cpack] as constructors, then validate against each
intended ecosystem ([Linux native][linux-native], [Linux repositories][linux-repositories]).

### Repository signing is the acquisition root

Signing an individual package does not replace signed repository metadata. APT and
RPM-family clients authenticate indexes/metadata that bind package identity to digests;
key rotation, expiration, suite/channel layout, and metadata atomicity are operational
requirements. Publish indexes from immutable package bytes and test client refresh paths
([Linux repositories][linux-repositories]).

### Flatpak and Snap change runtime assumptions

Flatpak permissions (`finish-args`), portals, runtime branches, and filesystem visibility
are part of app behavior. Snap interfaces, confinement, bases, and daemon/store behavior
are likewise not a wrapper around a normal `/usr` install. Test the confined application,
not only the unsandboxed binary ([Flatpak][flatpak], [Snap][snap]).

## Windows

### MSI component rules are servicing invariants

MSI components are the unit of install/repair; component GUIDs, key paths, feature trees,
and upgrade codes must remain stable according to Windows Installer rules. Harvesting a
directory anew without a deliberate GUID strategy can break repair or upgrades. Avoid
custom actions for work expressible in standard tables; custom actions complicate
privilege, rollback, and silent enterprise deployment ([WiX/MSI][wix]).

### Installer scope changes privilege and paths

Per-user and per-machine installs differ in destination roots, elevation, registry views,
Start-menu scope, and uninstall registration. Architecture affects `Program Files`,
registry redirection, and package metadata. Test each declared scope and architecture on
a clean VM; do not infer one from the other ([WiX/MSI][wix], [Inno/NSIS][inno-nsis]).

### MSI version and upgrade rules are not arbitrary SemVer

Windows Installer's product-version and major-upgrade semantics do not map every SemVer
shape directly. Prerelease labels and a fourth numeric component require an explicit
mapping policy. Product/package/upgrade identity changes have different meanings
([WiX/MSI][wix], [concepts § identity][concepts-identity]).

### MSIX requires identity and signatures

MSIX package identity includes publisher information, and ordinary deployment requires a
trusted signature whose subject matches the manifest publisher. Store identity, sideload
certificates, package family names, architecture bundles, capabilities, and update URI
choices affect whether upgrades are recognized. Traditional filesystem/registry writes
and services may not fit the MSIX application model without changes ([MSIX][msix]).

### Authenticode must cover the final objects

Sign executable/DLL payloads and the final installer/package according to the chosen
trust policy, timestamp signatures, then verify on a machine without the build agent's
ambient certificate state. Rebuilding or editing resources invalidates signatures. MSI,
MSIX, and setup EXEs expose different signing surfaces ([WiX/MSI][wix], [MSIX][msix],
[Inno/NSIS][inno-nsis]).

### Catalog manifests do not repair installers

winget records installer type, switches, scope, architecture, URLs, and hashes; inaccurate
silent switches or return codes make automation fail even if interactive setup works.
Chocolatey executes package scripts and Scoop creates shims/persisted paths around
portable artifacts—three distinct install contracts. Validate each community manifest
against immutable upstream assets ([winget][winget], [Chocolatey][chocolatey],
[Scoop][scoop]).

## macOS

### `.app` layout and loader paths are one contract

Finder presentation does not make an arbitrary directory a correct bundle. `Info.plist`
keys, executable name/location, resources, frameworks, helpers, plug-ins, and
`@rpath`/`@loader_path` relationships must agree. Audit every nested Mach-O and prohibit
unexpected build-machine paths before signing ([macOS bundles][macos-bundles]).

### Universal means every code slice closes

Combining the main executable with `lipo` is insufficient if nested libraries/helpers
lack `arm64` or `x86_64`. Build and audit each architecture, merge corresponding code
objects, then sign the final universal hierarchy. Signing separate slices and merging
afterward invalidates the signature ([macOS bundles][macos-bundles],
[macOS signing][macos-signing]).

### Sign nested code inside-out

Frameworks, XPC services, plug-ins, helper apps, and executables are independently signed
code. Sign inner objects before their enclosing bundle, preserve intended entitlements,
and avoid `--deep` as a substitute for understanding the nesting. Hardened runtime and
entitlements must match actual application needs ([macOS signing][macos-signing]).

### Notarization is asynchronous and distinct from signing

Developer ID signing establishes publisher identity; Apple's notary service evaluates a
submitted artifact and issues a ticket; stapling attaches the accepted ticket where
supported. Submit a supported outer format, wait for and inspect the result/log, staple,
then run `codesign`/Gatekeeper/notary verification against the final artifact. Network or
service failure is an operational release failure, not evidence of rejection
([macOS signing][macos-signing]).

### DMG and PKG serve different installation needs

A DMG normally transports a copy-install `.app`; a PKG can write privileged/shared
locations and run scripts, leaving receipts. Choosing PKG for cosmetic familiarity adds
installer privilege and lifecycle surface. Conversely, a DMG cannot provide package
receipt/service installation semantics ([macOS containers][macos-containers]).

### App Translocation and quarantine affect direct downloads

Downloaded apps receive quarantine metadata, and Gatekeeper may run a quarantined app
from a translocated randomized path. Applications must not assume writable resources
beside the executable or rely on the mounted DMG path. Test the actual browser-download
and first-launch path, not only a locally copied unsigned bundle
([macOS signing][macos-signing], [macOS bundles][macos-bundles]).

### Homebrew formulae and casks have different contracts

A formula normally builds or installs into a versioned Cellar prefix and exposes files
through Homebrew's linking model; a cask describes a prebuilt macOS artifact and its
artifacts/zap metadata. Upstream checksums must remain immutable, and architecture/version
selection must match the published assets. A cask is a downstream index entry, not a
replacement for signing/notarizing the app ([Homebrew][homebrew]).

## Clean-host test matrix

Before promotion, each supported artifact should pass the applicable rows:

| Test                                        |  Portable  |  Native package  |  Sandboxed/store  |  Updater feed   |
| ------------------------------------------- | :--------: | :--------------: | :---------------: | :-------------: |
| install/extract without build tools         |     ✓      |        ✓         |         ✓         |        ✓        |
| launch from intended location and shell/GUI |     ✓      |        ✓         |         ✓         |        ✓        |
| runtime dependency/load audit               |     ✓      |        ✓         |         ✓         |        ✓        |
| signature/trust verification                | if signed  |        ✓         |         ✓         |        ✓        |
| upgrade from previous stable                | manual/app |        ✓         |         ✓         |        ✓        |
| uninstall preserves user data policy        |   manual   |        ✓         |         ✓         |   app-defined   |
| rollback/revert                             | app/manual | manager-specific | channel-specific  |  feed-specific  |
| offline behavior                            |     ✓      |        ✓         | runtime-dependent | explicitly test |

This matrix is a recommendation. The [Sparkles baseline][baseline] has not yet run these
installer lifecycle tests.

## Sources

Primary platform documentation is linked from [concepts] and
[artifact formats][formats]. Deep-dives own format/tool specifics; the shared
[comparison] records host and install-model trade-offs. No behavior in this page is
presented as a Sparkles test result.

<!-- References -->

[concepts]: ./concepts.md
[concepts-identity]: ./concepts.md#identity-version-and-upgrades
[formats]: ./artifact-formats.md
[pipeline]: ./release-pipeline.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
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
[velopack]: ./velopack.md
[conveyor]: ./conveyor.md
[cpack]: ./cpack.md
[fpm-nfpm]: ./fpm-nfpm.md
