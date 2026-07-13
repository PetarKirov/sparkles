# macOS application bundles (macOS platform contract)

A macOS application bundle is a directory with a conventional `.app` suffix and a
well-known internal layout: Finder presents one application while Launch Services,
Core Foundation, the dynamic loader, and code signing consume the files within it.

| Field                           | Value                                                                                   |
| ------------------------------- | --------------------------------------------------------------------------------------- |
| Platform                        | macOS                                                                                   |
| Language                        | N/A — filesystem and metadata platform contract                                         |
| License                         | N/A — platform contract; implementations retain their own licenses                      |
| Repository                      | [electron-builder implementation][electron-sha]                                         |
| Documentation                   | [Bundle Programming Guide][bundle-guide] · [Information Property List keys][plist-keys] |
| Primary input                   | Built executable, resources, private frameworks, plug-ins, metadata                     |
| Primary output                  | Relocatable `.app` directory bundle                                                     |
| System consumers                | Finder, Launch Services, `NSBundle`/`CFBundle`, `dyld`, `codesign`                      |
| Canonical metadata              | `Contents/Info.plist`                                                                   |
| Architecture model              | Thin Mach-O or universal Mach-O containing `arm64` and `x86_64` slices                  |
| Open-source implementation read | electron-builder [`39df92fd14d9a3788add09a3963028a48eed176e`][electron-sha]             |
| Category                        | Native application container and deployment unit                                        |

**Last reviewed:** July 12, 2026

> [!NOTE]
> A bundle is a filesystem convention, not a transport archive or installer. A release
> commonly puts the signed bundle in a [DMG, ZIP, or product package][containers].

## Overview

### What it solves

A bundle gives one application a stable root and separates executable code from
resources, localizations, private libraries, plug-ins, and metadata. Apple states in
its archived primary documentation:

> “The application bundle stores everything that the application requires for
> successful operation.” — [Bundle Programming Guide][bundle-structure]

The system can discover an app without launching it, select localized resources,
associate document and URL types, and relocate the entire app by moving one directory.
The convention also defines the boundary sealed by a code signature.

### Design philosophy

The bundle is **self-describing and relocatable**. `Info.plist` names the executable
and identity; code uses bundle-relative lookup rather than assuming an installation
path; architecture slices and private dependencies travel with the app. User data,
caches, and mutable configuration do not belong inside the signed bundle.

## How it works

A conventional bundle has this anatomy:

```text
Example.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo                    # legacy/optional
    ├── MacOS/Example              # CFBundleExecutable
    ├── Resources/                 # icons, assets, *.lproj localizations
    ├── Frameworks/                # private frameworks and dylibs
    ├── PlugIns/                   # app extensions and loadable bundles
    ├── XPCServices/               # embedded XPC services
    ├── Helpers/                   # helper executables, when appropriate
    ├── Library/                   # app-specific support content
    └── SharedSupport/             # auxiliary data not loaded as a resource
```

`CFBundleExecutable` identifies the file under `Contents/MacOS`;
`CFBundleIdentifier` supplies the reverse-DNS identity used by Launch Services and
many signing policies; `CFBundleShortVersionString` is the marketing version and
`CFBundleVersion` the monotonically ordered build version. `CFBundlePackageType`
is normally `APPL`. `LSMinimumSystemVersion`, document-type declarations,
`CFBundleURLTypes`, icons, and privacy usage descriptions extend discovery and policy.

A universal executable is a fat Mach-O container whose architecture table points to
independent Mach-O slices. `lipo -create arm64-binary x86_64-binary -output Example`
can combine compatible outputs, while `lipo -info` inspects them. Every executable,
dylib, framework binary, helper, and native plug-in must support the architectures on
which it can be loaded; a universal main executable does not repair a thin nested
library. `dyld` references should normally be bundle-relative (`@executable_path`,
`@loader_path`, or `@rpath`) rather than absolute build-machine paths.

The open-source electron-builder implementation illustrates a production universal
pipeline: [`macPackager.ts`][electron-universal] builds both slices, invokes
`@electron/universal`, reconciles explicitly single-architecture files, runs a final
hook on the merged app, and only then signs it.

## Analysis spine

### Input and staging

Stage a release build, an `Info.plist`, `.icns` icon and localized resources into a
fresh bundle root. Copy only runtime dependencies. Strip or split debug information
into `.dSYM` bundles as policy requires, normalize permissions, remove VCS metadata,
and finish all mutation before signing. Xcode's Copy Bundle Resources, Embed
Frameworks, extension, and XPC build phases are the reference orchestration; custom
builds can create the same directories directly.

### Outputs and targets

The output is a directory bundle, not a single file. It can target Intel, Apple
Silicon, or both. Separate thin app downloads reduce size; a universal app gives one
artifact and native execution on both architectures at the cost of duplicated native
code and stricter nested-dependency checks. Mac App Store and Developer ID distribution
use the same broad anatomy but differ in profiles, entitlements, signing identities,
and outer submission containers.

### Metadata and dependencies

`Info.plist` is both launch metadata and part of the sealed resource set. Bundle and
build versions should be generated from one release source of truth. Private dynamic
libraries belong under `Contents/Frameworks`; plug-ins, app extensions, XPC services,
and helpers occupy their standard nested-code locations. Check each Mach-O with
`otool -L`, `otool -l`, or equivalent tooling so no dependency resolves into a build
prefix. Avoid duplicate code in nonstandard resource directories: signing tools treat
nested code correctly only in recognized locations.

### Install, upgrade, and uninstall

A self-contained app installs by copying it to `/Applications` or
`~/Applications`; no receipt database is inherently involved. Upgrade is usually an
atomic replacement of the old bundle, preserving user state because preferences,
caches, Application Support data, and containers live outside it. Dragging the app to
Trash uninstalls the executable bundle but intentionally does not discover or erase
that state, privileged helpers, login items, or system extensions. Those require an
app-defined uninstaller or a package manager's explicit cleanup model.

### Signing and trust

Sign nested code from the inside out, then the outer app. The signature seals Mach-O
code, entitlements, requirements, and resources, so post-sign editing invalidates it.
A Developer ID release normally enables hardened runtime and is notarized; see the
[signing and notarization deep dive][signing]. `codesign --verify --deep --strict`
is useful for verification, but recursive `--deep` signing hides ownership and
entitlement mistakes and is not a substitute for an explicit signing graph.

### Publication and discovery

Finder and Launch Services discover `.app` bundles and read their metadata. Outside
the Mac App Store, projects publish an archive on a website, GitHub release, package
manager tap, or update feed. Inside the store, App Store Connect becomes the catalog
and policy boundary. A bare directory is poor for HTTP transport because servers and
clients do not preserve all macOS metadata reliably; wrap it first.

### Updates and channels

The bundle format has no update protocol. Apps can ship a native updater, use Sparkle,
rely on the Mac App Store, or delegate to Homebrew Cask. Stable/beta/nightly channels
must coordinate bundle version ordering, feed identity, signing identity, and downgrade
policy. Replacing the bundle rather than patching files keeps the signature boundary
comprehensible.

### Automation and CI

Build each architecture on macOS, merge if universal, inspect Mach-O dependencies,
run the app's tests, sign, verify, archive, notarize, and assess the final downloaded
shape. `xcodebuild archive` and `-exportArchive` provide the Apple-native path;
CMake, Meson, and language packagers can construct the same layout. CI must use a
macOS runner for Apple signing and notarization tools and should import signing keys
into a temporary keychain rather than the login keychain.

### Supply chain and reproducibility

Pin source dependencies and toolchains, checksum downloaded inputs, and make staging
from an empty directory. Universal merging must pair outputs from the same source
revision. Exact byte reproducibility is complicated by Mach-O UUIDs, archive metadata,
resource ordering, code signatures, secure timestamps, and notarization tickets;
separate an unsigned reproducible-build comparison from verification of the signed
release. Preserve `.dSYM` files and a manifest mapping versions, architectures, hashes,
and signing/notary records.

### Extensibility and UX

Bundles make extensions and helpers discoverable without exposing internal paths to
users. The same extensibility increases the signing surface: each plug-in, framework,
XPC service, and helper is independently executable nested code. The best user
experience is one movable app with no first-run installer; components that truly need
privileged or fixed-location installation may justify a product package instead.

## Strengths

- One visible app can contain code, localizations, assets, and private dependencies.
- Relocatable structure enables drag installation and whole-bundle replacement.
- Standard nested-code locations integrate with Launch Services, `dyld`, and signing.
- Universal Mach-O permits one download for Intel and Apple Silicon.
- Metadata enables discovery without executing untrusted code.

## Weaknesses

- The bundle alone has no transport, dependency solver, receipt, uninstall manifest,
  update protocol, or channel model.
- A universal release is larger and every native nested component must be audited.
- Mutable state inside the bundle conflicts with signatures and read-only deployment.
- Nonstandard nesting can produce ambiguous signing or loader behavior.
- Drag uninstall leaves external state and privileged components behind.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                      | Trade-off                                            |
| ------------------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------- |
| Directory bundle instead of monolithic executable | Keep resources, metadata, and nested code discoverable         | Needs an outer archive for reliable transport        |
| Standard `Contents/*` locations                   | System tools can classify files without launching the app      | Layout is platform-specific and convention-sensitive |
| Bundle-relative dynamic linking                   | Preserve relocatability                                        | Requires install-name and `rpath` auditing           |
| Universal app                                     | One artifact runs natively on two CPU families                 | Larger output; merge and dependency complexity       |
| User state outside the app                        | Upgrades can replace a sealed bundle safely                    | Trash uninstall is not complete cleanup              |
| Explicit inside-out signing                       | Every nested code owner gets correct identity and entitlements | More orchestration than recursive signing            |

## Sources

- [Apple Bundle Programming Guide — Bundle Structures][bundle-structure]
- [Apple Core Foundation keys reference][plist-keys]
- [Apple Launch Services keys reference][launch-keys]
- [Apple Universal Binary Programming Guidelines, “Building Universal Binaries”][universal-guide]
- [electron-builder `macPackager.ts` at pinned SHA][electron-universal]
- [electron-builder repository at pinned SHA][electron-sha]
- Related: [DMG, PKG, and XIP][containers] · [signing and notarization][signing] ·
  [Homebrew][homebrew]

<!-- References -->

[bundle-guide]: https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/Introduction/Introduction.html
[bundle-structure]: https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html
[plist-keys]: https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html
[launch-keys]: https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html
[universal-guide]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/universal_binary/universal_binary_intro/universal_binary_intro.html
[electron-sha]: https://github.com/electron-userland/electron-builder/tree/39df92fd14d9a3788add09a3963028a48eed176e
[electron-universal]: https://github.com/electron-userland/electron-builder/blob/39df92fd14d9a3788add09a3963028a48eed176e/packages/app-builder-lib/src/macPackager.ts
[containers]: ./macos-dmg-pkg-xip.md
[signing]: ./macos-signing-notarization.md
[homebrew]: ./homebrew.md
