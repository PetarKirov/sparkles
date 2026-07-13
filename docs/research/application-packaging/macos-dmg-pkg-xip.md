# macOS DMG, PKG, and XIP containers (macOS platform formats)

DMG, PKG, and XIP are three superficially similar download suffixes with different
semantics: a DMG mounts a disk, a PKG asks Installer to mutate a target system, and
XIP is an Apple-trusted signed archive whose third-party use is deprecated.

| Field                           | Value                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------ |
| Platform                        | macOS                                                                                |
| Language                        | N/A — platform formats and command-line tools                                        |
| License                         | N/A — Apple platform contracts; implementations retain their own licenses            |
| Repository                      | [create-dmg implementation][create-dmg-sha]                                          |
| Documentation                   | Local `hdiutil(1)`, `pkgbuild(1)`, `productbuild(1)`, and `xip(1)` primary manuals   |
| Inputs                          | Staged files or `.app`; destination root; component packages and Distribution XML    |
| Outputs                         | UDIF `.dmg`; component/product `.pkg`; signed `.xip`                                 |
| System tools                    | `hdiutil`, `pkgbuild`, `productbuild`, `productsign`, `installer`, `pkgutil`, `xip`  |
| Open-source implementation read | create-dmg [`a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f`][create-dmg-sha]              |
| Local verification              | macOS 26.3.1 `hdiutil(1)`, `pkgbuild(1)`, `productbuild(1)`, `xip(1)`, and tool help |
| Category                        | Transport image, system installer, and Apple archive                                 |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

A signed `.app` is a directory and cannot by itself describe a privileged installation
or travel through every download channel intact. These outer formats answer different
questions:

- **DMG:** preserve a curated read-only volume containing an app, documentation, and
  often an `/Applications` symlink for drag installation.
- **component PKG:** carry a payload, scripts, ownership/mode data, and a package
  identifier/version for macOS Installer.
- **product PKG:** compose component packages with a Distribution XML choice graph,
  requirements, localization, and resources.
- **XIP:** expand only after verifying an archive signature; today this is principally
  Apple's channel for Xcode and similarly controlled downloads.

The current `xip(1)` manual is unusually explicit:

> “As of macOS Sierra, only archives that are signed by Apple are trusted, and the
> format is deprecated for third party use.” — `xip(1)`, observed on macOS 26.3.1 at
> the primary-source path `/usr/share/man/man1/xip.1`

### Design philosophy

DMG separates **presentation and transport** from installation; PKG makes installation
an **authorized transaction**; XIP couples extraction to an Apple trust decision. A
packager should choose based on required system mutation, not visual preference.

## How it works

### DMG mechanics

`hdiutil create` builds a disk-image container around a filesystem, `attach` exposes
its device and mount point, and `convert` produces a compressed read-only release
image such as `UDZO`. The local `hdiutil(1)` manual describes the key distinction:
“Disk images are data containers that emulate disks. Like disks, they can be
partitioned and formatted.” A typical pipeline creates a read-write temporary image,
mounts it, adds a background and `/Applications` symlink, detaches it, and converts it.
The pinned create-dmg script implements exactly that sequence at
[`create-dmg:453-724`][create-dmg-script], then can code-sign, submit with
`notarytool --wait`, and staple the image.

### PKG mechanics

`pkgbuild` creates a **component package** from a destination root or one component.
Its payload archive, Bill of Materials, `PackageInfo`, optional scripts, identifier,
and version tell Installer what to place. Scripts conventionally include `preinstall`
or `postinstall`; they execute with Installer privileges and make the operation less
declarative.

`productbuild` creates a flat **product archive**. It can wrap a component directly,
synthesize a Distribution XML, or combine multiple component packages and localized
resources under a hand-authored Distribution. The product layer drives Installer UI,
choices, host requirements, and component ordering. A Developer ID Installer identity
signs the flat package; executable payloads retain their own code signatures.

### XIP mechanics

`xip --sign identity inputs output.xip` creates a signed archive and `xip --expand`
verifies then extracts it. The archive is not a general installer: it has no package
receipt, destination-root mapping, or uninstall model. Because modern macOS trusts only
Apple-signed XIP archives, third-party release tooling should not offer XIP as a target.

## Analysis spine

### Input and staging

A DMG starts from a clean presentation directory, usually a signed `.app` plus an
`Applications` symlink. A component package starts from a destination-root tree or a
bundle supplied with `--component`, plus scripts and optional component properties.
A product package starts from components, Distribution XML, and resources. XIP starts
from arbitrary files but is practically Apple-only. Normalize modes and ownership;
do not let a DMG staging mount or PKG root inherit developer-machine debris.

### Outputs and targets

| Target        | What the user receives                                   | Best fit                                                           |
| ------------- | -------------------------------------------------------- | ------------------------------------------------------------------ |
| DMG           | Mountable disk image; usually compressed, read-only UDIF | Self-contained GUI app, branded drag-install experience            |
| Component PKG | Installable payload unit                                 | One destination-root payload; often an input to product PKG        |
| Product PKG   | Flat Installer archive with distribution choices         | Privileged files, daemons, multiple components, managed deployment |
| XIP           | Signature-checked extraction archive                     | Apple-distributed developer assets; not a third-party target       |

A DMG can contain a PKG, but doing so adds a mount step without changing PKG semantics.
A ZIP is often preferable when no mounted-volume presentation is needed.

### Metadata and dependencies

DMG metadata describes the volume, filesystem, compression, background, icon layout,
and optional license resources; it does not declare software dependencies. Component
PKG metadata includes identifier, version, install location, payload ownership, and
scripts. Product Distribution XML expresses package references, choices, installation
checks, and localization. Dependencies between components are installer-choice logic,
not a repository solver: the author must ship or verify prerequisites.

### Install, upgrade, and uninstall

DMG install is copy-and-eject; Finder performs the copy, and there is no receipt.
Replacing the app upgrades it. A PKG invokes Installer, which writes payloads and
records receipts queryable with `pkgutil`. Later packages with the same stable package
identifier and newer version can upgrade that component, but scripts and payload
layout determine the real migration behavior. `pkgutil --forget` removes a receipt,
not installed files. macOS provides no general reverse transaction for arbitrary
package scripts, so products needing uninstall must ship and test explicit cleanup.
XIP merely extracts.

### Signing and trust

Sign code before placing it in any container. Developer ID Installer signs PKG
products; Developer ID Application signs apps and other code. DMGs can themselves be
signed and are directly notarizable/stapleable. Product PKGs are notarizable and can
carry a stapled ticket. The local `stapler` help lists supported formats as “UDIF disk
images, code-signed executable bundles, and signed ‘flat’ installer packages.” XIP has
its own archive signature but is not a substitute for nested code signing.

### Publication and discovery

All three are files suitable for HTTPS or a release host, but only DMG and PKG are
normal third-party channels. Browsers and quarantine-aware download agents mark them
for Gatekeeper assessment. Enterprise management systems commonly ingest signed flat
PKGs; consumer websites commonly offer DMGs. Mac App Store submission uses Apple's
product/archive workflows rather than a consumer drag-install DMG.

### Updates and channels

DMG carries no update metadata; the app, feed, or package manager owns updates. PKG
version and identifier support replacement decisions but do not provide a discovery
feed. Publish separate stable/beta artifacts and never reuse a versioned URL with new
bytes. XIP provides no channel protocol.

### Automation and CI

A robust order is: build → sign nested code and app → assemble DMG or PKG → sign outer
installer/container where applicable → notarize → staple → verify → hash → publish.
create-dmg demonstrates retries around `hdiutil`'s transient `EBUSY` detach/create
failures and uses a temporary writable image before conversion. Packaging and signing
must run on macOS because the canonical frameworks and tools are platform-local.

### Supply chain and reproducibility

Hash every published artifact and preserve package manifests, Distribution XML,
notarization IDs, and signing-certificate fingerprints. PKG scripts are privileged
supply-chain code and deserve the same review as executables. DMG filesystem metadata,
window layout files, compression, timestamps, signatures, and staples can defeat byte
reproducibility. Build an unsigned deterministic payload first, compare its manifest,
then treat signing/notarization as an auditable release transformation.

### Extensibility and UX

DMG offers rich Finder presentation but accessibility and automation suffer when the
layout is treated as mandatory instruction. PKG offers localized choices and scripts,
but every choice multiplies test cases and scripts can make installs non-idempotent.
The simplest safe UX is a DMG for one relocatable app and a minimal product PKG only
when privileged or multi-location installation is genuinely required. XIP should be
shown as scoped historical/Apple infrastructure, not as a selectable third-party
format.

## Strengths

- DMG preserves macOS metadata and provides a familiar, low-privilege drag workflow.
- Product PKG handles privileged, multi-component, localized installation and receipts.
- Components separate payload construction from product-level choice presentation.
- DMG and flat PKG integrate with Developer ID notarization and stapling.
- Canonical command-line tools make the pipeline automatable on macOS.

## Weaknesses

- DMG has no receipt, dependency model, complete uninstall, or update discovery.
- PKG scripts run with broad authority and can make rollback or uninstall impossible.
- Receipts record installation; they do not guarantee a reversible transaction.
- Product Distribution XML and signing layers add substantial CI complexity.
- XIP is deprecated for third-party use and modern trust is limited to Apple signatures.

## Key design decisions and trade-offs

| Decision                               | Rationale                                               | Trade-off                                         |
| -------------------------------------- | ------------------------------------------------------- | ------------------------------------------------- |
| DMG for relocatable apps               | Preserve bundle metadata and familiar drag installation | No transactional install or receipt               |
| Component/package split                | Reuse payload units under product-level choices         | Two metadata layers and identifiers to coordinate |
| Stable PKG identifiers                 | Let Installer relate versions of one component          | Renaming or collisions break upgrade semantics    |
| Minimal/no installer scripts           | Keep payload auditable and closer to declarative        | Some migrations and privileged setup need scripts |
| Sign inner code before outer container | Preserve every trust boundary                           | Any late mutation forces re-signing outward       |
| Exclude XIP as third-party output      | Match current macOS trust policy                        | Cannot imitate Apple's Xcode distribution channel |

## Sources

- macOS 26.3.1 local `hdiutil(1)`, `pkgbuild(1)`, `productbuild(1)`,
  `/usr/share/man/man1/xip.1` (`xip(1)`), `notarytool help`, and `stapler help`
  transcripts (July 12, 2026)
- [Apple Distribution XML schema reference][distribution-xml]
- [Apple Installer JS reference][installer-js]
- [create-dmg repository at pinned SHA][create-dmg-sha]
- [create-dmg release pipeline at pinned SHA][create-dmg-script]
- [Apple notarization workflow][notarization]
- Related: [application bundles][bundles] · [signing and notarization][signing] ·
  [Homebrew][homebrew]

<!-- References -->

[create-dmg-sha]: https://github.com/create-dmg/create-dmg/tree/a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f
[create-dmg-script]: https://github.com/create-dmg/create-dmg/blob/a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f/create-dmg#L453-L724
[distribution-xml]: https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Introduction.html
[installer-js]: https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/InstallerJavaScriptRef/Introduction/Introduction.html
[notarization]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
[bundles]: ./macos-app-bundles.md
[signing]: ./macos-signing-notarization.md
[homebrew]: ./homebrew.md
