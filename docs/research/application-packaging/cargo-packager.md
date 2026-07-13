# cargo-packager (Rust / Node.js)

A cross-platform, framework-neutral application packager that turns already-built
executables into native desktop bundles and installers, with a separate embedded
updater and resource resolver.

| Field                    | Value                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Language                 | Rust core; Node.js bindings and plugin layer in TypeScript                                                    |
| License                  | Apache-2.0 OR MIT                                                                                             |
| Repository               | [crabnebula-dev/cargo-packager][repo]                                                                         |
| Documentation            | [Rust crate documentation][docs] · [configuration schema][schema]                                             |
| Version at reviewed HEAD | `cargo-packager` `0.11.8`; updater `0.2.3`                                                                    |
| Reviewed source          | [`37a538e76608b33eaa3f36f7c57b30b284dfa5a9`][head] (March 21, 2026)                                           |
| Category                 | **Application packager and updater**; not a control plane and not merely a format primitive                   |
| Commercial model         | **Open source**; the repository and these components are not paid products                                    |
| Interfaces               | `cargo packager`, Rust library, N-API Node.js library/CLI                                                     |
| Host/targets             | macOS: `.app`, `.dmg`; Linux/BSD hosts: `.deb`, `.AppImage`, Pacman payload; Windows: NSIS `.exe`, WiX `.msi` |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Classification:** cargo-packager is an **OSS app packager plus an optional
> in-application updater**. It is **not a release control plane**: it has no hosted
> build fleet, artifact registry, rollout dashboard, account model, or release
> database. It is also **not a format primitive** like `tar`, `ar`, WiX, NSIS, or
> `hdiutil`; it orchestrates those primitives and generates their metadata. The
> CrabNebula company offers other services, but no paid service is required by the
> source reviewed here.

---

## Overview

### What it solves

cargo-packager gives desktop applications a shared configuration and API over seven
otherwise unrelated packaging paths. Its scope begins with compiled executables and
resources and ends with local package files. It deliberately does not own compilation:

> “By default, the packager doesn't build your application”

— [`README.md`][readme]. A `beforePackagingCommand` hook can invoke any build system,
but the separation is architectural, not just a default. This lets the examples package
Rust, Deno, Electron, Wails, Slint, Dioxus, egui, and Wry applications through the same
backend ([`examples/`][examples]).

The companion updater closes part of the post-install lifecycle. An application embeds
`cargo-packager-updater`, queries developer-controlled HTTP endpoints, compares SemVer,
downloads an artifact, verifies a Minisign signature, and replaces or invokes the
installed application according to the platform ([`crates/updater/src/lib.rs`][updater]).
The packager itself neither hosts those endpoints nor publishes artifacts.

### Design philosophy

The design is a **thin common model with format-specific escape hatches**:

1. `Config` describes shared identity, binaries, resources, icons, associations,
   protocols, hooks, and output location, then embeds `macos`, `windows`, `deb`,
   `appimage`, `pacman`, `nsis`, `wix`, and `dmg` sub-configurations
   ([`config/mod.rs`][config]).
2. `package()` normalizes `default`/`all`, sorts formats by dependency priority, runs
   hooks, creates one clean intermediate context, and dispatches each target to a
   dedicated backend ([`package/mod.rs`][package]).
3. Backends either write the format directly (`.deb`, Pacman staging, `.app`) or render
   templates and invoke established platform tooling (`linuxdeploy`, NSIS, WiX,
   `create-dmg`) ([`package/` source tree][package-tree]).
4. The Rust API exposes the same `Config`, `package`, `package_and_sign`, and
   `PackageOutput` abstractions as the CLI; Node.js wraps that API and adds a plugin
   merge step ([`lib.rs`][lib], [`src-ts/index.ts`][node-index]).

This is intentionally local-first tooling. The developer selects where CI runs, where
artifacts are stored, how updates are segmented, and what release page or repository
advertises them.

## How it works

The high-level execution graph is:

```text
config discovery
    -> Cargo metadata/default enrichment
    -> CLI overrides
    -> beforePackagingCommand
    -> clean <outDir>/.cargo-packager staging context
    -> [beforeEachPackageCommand -> target backend]...
    -> native code signing/notarization where configured
    -> optional Minisign sidecar signatures
    -> PackageOutput { format, paths }
```

`detect_configs()` accepts a raw JSON object/array, an explicit TOML/JSON path, all
case-insensitive `**/packager.{toml,json}` files, and every Cargo workspace package
with `[package.metadata.packager]` ([`cli/config.rs`][cli-config]). Cargo-backed
configuration is enriched from `cargo metadata`: package name, product name, version,
authors, description, license file, target directory/profile, identifier, and binary
targets are filled when absent. Standalone config is not merged with Cargo metadata;
it must be complete itself.

`package()` expands platform defaults, sorts `Dmg` after `App`, executes the one-shot
hook with `CARGO_PACKAGER_FORMATS`, then executes the per-format hook with both
`CARGO_PACKAGER_FORMATS` and `CARGO_PACKAGER_FORMAT` ([`package/mod.rs`][package]). A
DMG implicitly builds an `.app`, consumes it, and removes the temporary app if `app`
was not explicitly requested. All selected formats share one `Context`; its
`<outDir>/.cargo-packager` intermediates directory is deleted and recreated, while
external tools persist under the user cache directory's `.cargo-packager`
([`context.rs`][context]).

`PackageOutput` preserves one format and one-or-more paths—for example, WiX can emit
one MSI per configured locale—until the CLI flattens and prints paths. Library users
retain the format association and can split packaging from signing
([`package/mod.rs`][package], [`lib.rs`][lib]).

---

## Analysis dimensions

### Input / staging

The primary inputs are prebuilt main/additional executables, target-qualified sidecar
binaries, resource files or globs, icons, framework-specific files, and declarative
metadata. `Binary.path` resolves under `binariesDir` (falling back to `outDir`), while
absolute paths remain absolute. Each app must identify one `main` binary
([`config/mod.rs`][config]). In Cargo mode, binary targets are auto-detected and the
only target—or the one matching the package name—is marked main
([`cli/config.rs`][cli-config]).

Resources have two forms:

- a string path/glob, retaining its basename or recursively retaining a directory
  subtree; or
- `{ src, target }`, allowing controlled relocation inside the target's resource root.

Mapped targets are sanitized to normal path components before joining, preventing
absolute or parent components from escaping the package resource root. Source
traversal uses `walkdir`, and copies are materialized rather than linked
([`config/mod.rs`][config]). External binaries use a convention rather than a
manifest: configure `sqlite3`, provide `sqlite3-<target-triple>[.exe]`, and the staged
name becomes `sqlite3[.exe]`.

Staging is backend-specific beneath `<outDir>/.cargo-packager`:

| Backend  | Staging mechanics                                                                                                                                           |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.app`   | Constructs `Contents/{MacOS,Resources,Frameworks}`, generates/merges `Info.plist`, and preserves copied framework symlinks ([`app/mod.rs`][app])            |
| `.deb`   | Builds `data/` and `control/`, writes desktop/icon trees, `control`, and `md5sums`, then emits the three-member `ar` archive ([`deb/mod.rs`][deb])          |
| AppImage | Reuses Debian filesystem staging, constructs an `AppDir`, renders a shell script, and runs downloaded `linuxdeploy` tooling ([`appimage/mod.rs`][appimage]) |
| Pacman   | Reuses Debian filesystem staging, creates a payload `.tar.gz`, and writes a sibling `PKGBUILD` with SHA-512 ([`pacman/mod.rs`][pacman])                     |
| NSIS     | Renders UTF-16LE NSIS scripts plus resources/languages, then runs `makensis` ([`nsis/mod.rs`][nsis])                                                        |
| WiX      | Renders `.wxs`/`.wxl`, compiles with Candle, links with Light, and repeats linking per locale ([`wix/mod.rs`][wix])                                         |
| DMG      | Starts from the generated `.app`, downloads `create-dmg`, renders support files, and invokes the script ([`dmg/mod.rs`][dmg])                               |

There is no sandbox: hooks and backend tools inherit filesystem/network access, and
hooks are arbitrary shell commands. Config-relative execution is convenient—the CLI
changes to the config file's parent—but also means multiple configs run serially while
mutating the process working directory ([`cli/mod.rs`][cli]).

### Outputs / targets

`PackageFormat::platform_default()` selects `.app` + `.dmg` on macOS, NSIS on
Windows, and `.deb` + AppImage + Pacman on Linux/BSD-family compile targets. `all`
adds WiX on Windows; explicit formats can narrow the set
([`utils/src/lib.rs`][utils]). Backends are compile-time host-gated except NSIS, which
can use host `makensis` away from Windows. Cross-target metadata uses
`targetTriple`, but this is not general cross-packaging: AppImage explicitly depends
on same-platform `linuxdeploy`, WiX is Windows-gated, and macOS signing/notarization
requires Apple tools.

| Logical target   | Output naming / contents                           | Installation authority                                     |
| ---------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| macOS app        | `<Product Name>.app`                               | Finder copy or other distributor; no installer transaction |
| macOS disk image | `<binary>_<version>_<arch>.dmg`                    | User drags app from mounted DMG                            |
| Debian           | `<binary>_<version>_<deb-arch>.deb`                | `dpkg`/APT owns files and removal                          |
| AppImage         | `<binary>_<version>_<arch>.AppImage`               | Portable executable; user chooses location                 |
| Pacman path      | `<binary>_<version>_<arch>.tar.gz` plus `PKGBUILD` | `makepkg`/pacman only after downstream package build       |
| NSIS             | `<binary>_<version>_<arch>-setup.exe`              | Generated NSIS installer/uninstaller                       |
| WiX              | `<binary>_<version>_<arch>_<locale>.msi`           | Windows Installer                                          |

The Pacman `.tar.gz` is a staged source payload, not a finished `.pkg.tar.zst`; the
sibling `PKGBUILD` copies it into `${pkgdir}` and declares dependencies, conflicts,
provides, replaces, source, and SHA-512 ([`pacman/mod.rs`][pacman]). That distinction
makes cargo-packager a generator feeding the Arch format primitive rather than a
complete repository-ready Pacman build.

### Metadata / dependencies

Common metadata fans out into native fields: identifier, product name, SemVer,
description, long description, homepage, authors, publisher, license, copyright,
category, icons, file associations, and deep-link schemes
([`config/mod.rs`][config]). Examples include:

- `.app`: `CFBundleIdentifier`, display/executable names, version, category, document
  types, URL schemes, minimum OS, background-app flag, and optional custom plist merge
  ([`app/mod.rs`][app]);
- Debian: package/version/architecture/installed size, maintainer, section, priority,
  homepage, `Depends`, and folded descriptions ([`deb/mod.rs`][deb]);
- WiX/NSIS: manufacturer, identity, installer version, shortcuts, associations,
  protocols, languages, license UI, downgrade policy, and generated upgrade identity
  ([`wix/mod.rs`][wix], [`nsis/mod.rs`][nsis]);
- Pacman: `depends`, `provides`, `conflicts`, and `replaces`
  ([`pacman/mod.rs`][pacman]).

Dependency declaration is deliberately format-local. Debian and Pacman accept either
a list or a newline-delimited file. AppImage instead bundles selected host libraries
and binaries through `linuxdeploy`; macOS copies named/path frameworks but explicitly
leaves link flags and `rpath` correctness to the application
([`config/mod.rs`][config]). NSIS/WiX contain files but do not model a package-manager
dependency solver. There is no cross-platform dependency graph, lockfile for bundled
runtime libraries, license inventory, SBOM, or automatic runtime dependency inference
shared by all targets.

The checked-in JSON Schema is generated from Rust types and supports editor validation,
while `deny_unknown_fields` rejects misspelled keys in most structures
([`schema.json`][schema], [`config/mod.rs`][config]). The CLI also accepts kebab-case
and snake_case aliases for many fields, although serialization is camelCase.

### Install / upgrade / uninstall

cargo-packager **generates** lifecycle behavior but does not provide a universal
`install`, `upgrade`, or `uninstall` command. Native artifacts delegate those actions:

- Debian package metadata and file ownership let `dpkg`/APT install, replace, and
  remove the application. No maintainer scripts are generated by this backend
  ([`deb/mod.rs`][deb]).
- WiX emits a stable upgrade code and Windows Installer product; NSIS supports
  current-user, per-machine, or chooser modes. Both can reject downgrades when
  `windows.allowDowngrades` is false ([`wix/mod.rs`][wix],
  [`config/mod.rs`][config]).
- The NSIS template registers uninstall metadata and creates an uninstaller. Optional
  `nsis.appdataPaths` makes uninstall offer a **disabled-by-default** checkbox for
  deleting application data ([`installer.nsi`][nsis-template],
  [`config/mod.rs`][config]).
- `.app`, DMG, and AppImage have no package database in cargo-packager. Their ordinary
  uninstall is deletion; upgrades are replacement or the companion updater.
- Pacman lifecycle semantics apply only after `PKGBUILD` is built and installed by
  standard Arch tooling.

The updater supports only `.app`, AppImage, NSIS, and WiX—not DMG, Debian, or Pacman.
On Windows it writes a temporary `.exe`/`.msi`, starts NSIS or `msiexec`, and exits;
WiX attempts to relaunch the current app. On Linux it requires an existing AppImage,
chooses a temporary directory on the same device, renames the old image to a backup,
writes the verified new bytes with old permissions, and restores the backup if writing
fails. On macOS it extracts a tar-gzipped app into a temporary directory, moves the
old bundle aside, then renames the replacement or asks for authorization through
AppleScript ([`updater/src/lib.rs`][updater]). These are replacement strategies, not a
transactional cross-platform package manager; Windows success is delegated to a
spawned installer, and rollback guarantees differ by OS.

### Signing / trust

There are **three distinct trust layers**:

1. **Native platform signing.** macOS finds nested Mach-O/framework targets, signs
   inside-out with hardened runtime and timestamping, signs the app, submits it with
   `xcrun notarytool`, and staples an accepted ticket. CI can import a base64 PKCS#12
   into a temporary keychain. Windows signs binaries/installers with SDK
   `signtool.exe` by certificate thumbprint, digest, and optional timestamp URL, or
   runs a custom `%1` command such as `osslsigncode`
   ([`codesign/macos.rs`][macos-sign], [`codesign/windows.rs`][windows-sign]).
2. **Updater artifact signing.** `sign_outputs()` creates Minisign `.sig` sidecars.
   Directory outputs such as `.app` are first archived as `.tar.gz`. The CLI reads the
   private key from `CARGO_PACKAGER_SIGN_PRIVATE_KEY`, a file, or an inline value, and
   the password from `CARGO_PACKAGER_SIGN_PRIVATE_KEY_PASSWORD`
   ([`lib.rs`][lib], [`sign.rs`][sign], [`cli/mod.rs`][cli]).
3. **Update verification.** The app embeds a base64-encoded Minisign public key. Every
   downloaded byte sequence is fully buffered and verified before installation;
   signature failure aborts the update ([`updater/src/lib.rs`][updater]).

Minisign authenticates the artifact but not the release manifest: endpoint JSON is
accepted over whatever URL the application configured, and the code does not require
HTTPS. An attacker who cannot sign an artifact cannot pass verification, but endpoint
metadata still controls availability, notes, version, URL, and format. Key rotation is
not modeled; applications must ship new updater configuration/public keys themselves.
The native and updater signatures are independent—platform trust does not replace the
embedded Minisign policy, nor vice versa.

### Publication / discovery

The tool itself is discoverable as the `cargo-packager` crate/cargo subcommand and as
`@crabnebula/packager` on npm ([`README.md`][readme],
[`bindings/packager/nodejs/README.md`][node-readme]). Generated applications are not
published anywhere automatically. There is no GitHub Releases uploader, package
repository client, App Store submission, Microsoft Store submission, Homebrew formula,
APT repository metadata, Arch repository database, CDN, release index, or artifact
retention policy in the packager API.

Publication is therefore an explicit downstream CI step: upload `PackageOutput.paths`
and `.sig` files, construct the updater JSON, and expose discovery through a website,
store, OS repository, or update endpoint. This is the clearest boundary between
cargo-packager and a release control plane.

### Updates / channels

`Updater::check()` substitutes <span v-pre>`{{target}}`, `{{arch}}`, and
`{{current_version}}`</span> in each configured endpoint, trying endpoints sequentially. A
`204` means no update; a successful JSON response can describe one dynamic target or a
static `platforms["<os>-<arch>"]` map. Default selection is strictly
`remote.version > current_version`, with a caller-supplied comparator available for
custom policy ([`updater/src/lib.rs`][updater], [`updater README`][updater-readme]).

Channels are **not first-class objects**. Stable/beta/nightly segmentation must be
encoded in endpoint URLs, headers, manifests, or the custom comparator. The library
has no staged rollout percentage, cohort assignment, mandatory update, minimum
supported version, delta update, background scheduler, resumable download, or server
component. It does support multiple fallback endpoints, custom request headers,
timeouts, release notes/dates, progress callbacks, and installer arguments.

The manifest signature is the complete base64 `.sig` content, not merely a checksum;
a signature may change each build and publication must keep artifact and manifest in
sync ([`updater README`][updater-readme]). The updater downloads into memory before
verification and installation, so update size contributes directly to application
memory use.

### Automation / CI

The CLI is automation-friendly: config files are source-controlled, output paths are
predictable, `--formats`, `--packages`, `--out-dir`, `--binaries-dir`, `--profile`,
`--target`, and environment-backed signing inputs make a CI matrix straightforward
([`cli/mod.rs`][cli]). `beforePackagingCommand` builds once; the per-format hook is
better when format-sensitive compile-time resource resolution is required. Hook
environment variables bridge the build and package phases
([`package/mod.rs`][package], [`resource resolver`][resolver]).

Upstream CI demonstrates the intended matrix:

- Rust and Node integration tests run on Ubuntu, macOS, and Windows
  ([`integration-tests.yml`][integration-ci]);
- example packaging runs the same three hosts, installs language/framework tools,
  generates a Minisign key, then requests `--formats all`
  ([`build-examples.yml`][examples-ci]);
- formatting, Clippy, unit tests with all features, and `cargo-deny` are separate
  checks ([`check.yml`][check-ci]).

This is test automation, not turnkey consumer release automation. The repository has
no reusable GitHub Action for package/sign/upload/update-manifest orchestration.
Consumers must provision native SDKs and secrets, and typically need one job per host.

### Supply chain / reproducibility

The project checks in `Cargo.lock`, and installation guidance uses
`cargo install cargo-packager --locked`, which pins the packager's Rust dependency
resolution ([`README.md`][readme], [`Cargo.lock`][cargo-lock]). Upstream runs
`cargo-deny`, and source/tool downloads use TLS by default. Several backend tools are
cached outside the output tree, reducing repeat downloads.

Artifact reproducibility is nevertheless **not a stated or achieved invariant**:

- `.app` writes `CFBundleVersion` from the current UTC timestamp
  ([`app/mod.rs`][app]);
- WiX assigns random v4 UUIDs to resource/additional-binary components, while only
  selected package identities use deterministic v5 UUIDs ([`wix/mod.rs`][wix]);
- Minisign's trusted comment includes the current Unix timestamp
  ([`sign.rs`][sign]);
- Debian tar headers use source file mtimes, despite deterministic tar header mode
  ([`deb/mod.rs`][deb]);
- code signing and notarization introduce external timestamps/services;
- hooks can perform arbitrary nondeterministic builds.

Downloaded-tool integrity is uneven. WiX is pinned to a release URL and SHA-256;
NSIS and one plugin use SHA-1, but the NSIS ApplicationID archive is downloaded without
an expected hash. AppImage downloads `AppRun`, `linuxdeploy`, and a plugin from URLs
without hash verification, including a mutable `continuous` release URL. User-supplied
`linuxdeployPlugins` are also fetched and executed without a configured checksum
([`wix/mod.rs`][wix], [`nsis/mod.rs`][nsis], [`appimage/mod.rs`][appimage]). The tool
cache persists those bytes until absent or backend-specific validation triggers.

No SBOM, provenance statement, SLSA attestation, package content manifest, dependency
license report, or reproducible-build metadata is emitted. Debian's `md5sums` and
Pacman's generated SHA-512 protect/identify package contents in their native workflows;
they are not build provenance. For a hardened pipeline, downstream CI should pre-pin or
mirror tools, isolate hooks, hash all fetched inputs, generate SBOM/provenance, and sign
those attestations alongside packages.

### Extensibility / UX

The Rust crate can be embedded with default features disabled, and its builder/types
provide programmatic configuration. The Node N-API binding exposes `packageApp`,
`packageAndSignApp`, and CLI invocation. Its TypeScript layer runs plugins, deep-merges
their config with caller config, then passes JSON into Rust
([`Cargo.toml`][packager-cargo], [`src-ts/index.ts`][node-index]). The bundled Electron
plugin prunes development dependencies before packaging
([`plugins/electron`][electron-plugin]).

Format customization is deliberately asymmetric:

- WiX accepts a complete template, inline/path fragments, references, merge modules,
  localization, FIPS mode, and UI art;
- NSIS accepts a complete template, pre-install sections, custom language files,
  compression, modes, and UI art;
- Debian accepts a desktop template and arbitrary source-to-package file mappings;
- DMG exposes layout/background controls;
- AppImage exposes bundled libs/binaries/files, excluded libraries, and arbitrary
  downloaded `linuxdeploy` plugins;
- macOS accepts frameworks, entitlements, custom `Info.plist`, provisioning profile,
  and embedded apps ([`config/mod.rs`][config]).

There is no stable backend plugin trait in Rust: `PackageFormat` and dispatch are a
closed internal match, so adding Flatpak, RPM, Snap, PKG, or a custom format requires a
fork/upstream change. Hooks can prepare inputs but cannot register a new output type.
The Node plugin layer composes configuration rather than implementing package formats.

UX strengths include one schema across ecosystems, auto-detection from Cargo metadata,
multi-app arrays/workspaces, glob resources, human-readable tracing, and format-specific
escape hatches. UX sharp edges include the typoed `--quite` flag in the reviewed CLI,
network downloads during packaging, host-tool requirements, no dry-run/package-plan
output, no manifest describing all emitted files, and configuration whose portable
surface obscures substantial host/format asymmetry ([`cli/mod.rs`][cli]).

---

## Strengths

- **Broad native output coverage behind one model:** seven output paths across the
  three desktop OS families, without tying packaging to a GUI framework.
- **Real native semantics:** desktop integration, associations, protocols, native
  dependencies, installer modes, localization, code signing, notarization, and
  uninstall metadata are delegated to or rendered for standard platform tooling.
- **Library-first reuse:** Rust and Node.js callers can integrate packaging without
  shell-output scraping; `PackageOutput` retains format/path relationships.
- **Useful separation of concerns:** compilation is an explicit hook, publication is
  downstream, and updates are an optional application dependency rather than hidden
  behavior in every installer.
- **Layered trust support:** Apple/Windows platform signing plus Minisign artifacts and
  mandatory updater verification cover both OS reputation and app-controlled updates.
- **Escape hatches where formats demand them:** full WiX/NSIS templates, WiX fragments,
  custom signing, Debian files/templates, and AppImage plugins prevent the common model
  from becoming a hard ceiling.
- **Good ecosystem portability:** examples prove the packager is useful beyond Rust
  applications.

## Weaknesses

- **Not a release control plane:** no publication, stores/repositories, hosted update
  service, channels/rollouts, artifact inventory, or release state machine.
- **Host-dependent and only partly cross-compilable:** serious releases still require
  macOS, Windows, and Linux jobs plus native tools and credentials.
- **Weak reproducibility:** wall-clock values, random UUIDs, source mtimes, signatures,
  arbitrary hooks, and external services make byte-identical rebuilds unlikely.
- **Inconsistent tool-download verification:** mutable/unhashed executable downloads in
  AppImage and NSIS paths are a material supply-chain risk.
- **Updater is intentionally narrow:** only four formats, full in-memory downloads, no
  deltas/resume/key rotation/manifest authentication/rollout model, and OS-specific
  rollback behavior.
- **No backend extension API:** adding formats requires changing internals; Node plugins
  only generate/merge configuration.
- **Metadata/dependency abstraction is shallow:** no shared dependency discovery, SBOM,
  provenance, package-content inventory, or license closure.
- **Lifecycle semantics vary sharply:** `.deb`/MSI/NSIS have package-manager or installer
  ownership, while `.app`/AppImage are replacement-by-file and Pacman output still
  needs `makepkg`.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                 | Trade-off                                                                               |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Package prebuilt binaries rather than own compilation            | Supports any language/framework and keeps build policy external           | Hooks are unsandboxed; binary/resource completeness is the caller's responsibility      |
| One common `Config` with nested backend configs                  | Makes multi-target metadata approachable without hiding native controls   | The apparent uniformity masks target-specific meaning and requirements                  |
| Use native generators/tools where practical                      | Reuses mature installer semantics, UI, signing, and OS integration        | Requires host-specific CI and introduces downloaded-tool supply-chain risk              |
| Directly implement `.deb`, app bundle, and Pacman staging        | Reduces external dependencies and gives precise layout control            | Must track evolving format policy; Pacman output is not a final installable package     |
| Clean intermediate output but persist tool cache                 | Avoids stale staging while accelerating subsequent builds                 | Cache provenance is not recorded, and not every cached executable is hash-verified      |
| Treat publishing as downstream                                   | Keeps the project local, OSS, and provider-neutral                        | Every consumer must assemble upload, discovery, retention, and manifest generation      |
| Separate native signing from Minisign update signing             | Meets platform trust requirements while supporting app-controlled updates | Two key systems and publication paths must be operated correctly                        |
| Require signature verification before updater installation       | Prevents unsigned update payload execution even if hosting is compromised | Public-key rotation and signed manifests are not built in; downloads are fully buffered |
| Model channels through endpoints/custom comparison               | Keeps updater protocol small and server-agnostic                          | No explicit channels, cohorts, phased rollout, mandatory versions, or downgrade policy  |
| Expose templates/fragments/hooks instead of a backend plugin ABI | Provides practical customization without stabilizing internal traits      | New package formats still require source changes or an external wrapper                 |
| Auto-enrich Cargo metadata but accept standalone TOML/JSON       | Excellent Rust ergonomics while remaining language-neutral                | Behavior differs by configuration source; standalone users supply more metadata         |
| Generate per-format native lifecycle behavior                    | Preserves standard OS installation and uninstall expectations             | Upgrade/rollback guarantees cannot be uniform across formats                            |

---

## Sources

- [crabnebula-dev/cargo-packager repository at reviewed HEAD][head]
- [`README.md` — scope, targets, configuration, installation, examples][readme]
- [`crates/packager/src/lib.rs` — public packaging/signing API][lib]
- [`crates/packager/src/config/mod.rs` — shared and backend configuration][config]
- [`crates/packager/src/cli/config.rs` — config discovery and Cargo enrichment][cli-config]
- [`crates/packager/src/package/mod.rs` — orchestration and hook ordering][package]
- [`crates/packager/src/package/` — target implementations][package-tree]
- [`crates/packager/src/sign.rs` — Minisign key and artifact signatures][sign]
- [`crates/packager/src/codesign/` — Apple and Windows platform trust][codesign-tree]
- [`crates/updater/src/lib.rs` — endpoint, verification, and install mechanics][updater]
- [`crates/updater/README.md` — update protocol and manifest forms][updater-readme]
- [`crates/resource-resolver/src/lib.rs` — runtime resource locations][resolver]
- [`bindings/packager/nodejs/` — Node.js API and plugin layer][node-tree]
- [Upstream workflows — checks, integration matrix, and packaged examples][workflows]

<!-- References -->

[repo]: https://github.com/crabnebula-dev/cargo-packager
[head]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9
[docs]: https://docs.rs/cargo-packager/0.11.8/cargo_packager/
[schema]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/schema.json
[readme]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/README.md
[examples]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/examples
[lib]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/lib.rs
[config]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/config/mod.rs
[cli]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/cli/mod.rs
[cli-config]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/cli/config.rs
[package]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/mod.rs
[package-tree]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package
[context]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/context.rs
[app]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/app/mod.rs
[deb]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/deb/mod.rs
[appimage]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/appimage/mod.rs
[pacman]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/pacman/mod.rs
[nsis]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/nsis/mod.rs
[nsis-template]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/nsis/installer.nsi
[wix]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/wix/mod.rs
[dmg]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/package/dmg/mod.rs
[sign]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/sign.rs
[codesign-tree]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/codesign
[macos-sign]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/codesign/macos.rs
[windows-sign]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/src/codesign/windows.rs
[updater]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/updater/src/lib.rs
[updater-readme]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/updater/README.md
[resolver]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/resource-resolver/src/lib.rs
[utils]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/utils/src/lib.rs
[node-readme]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/bindings/packager/nodejs/README.md
[node-index]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/bindings/packager/nodejs/src-ts/index.ts
[node-tree]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/bindings/packager/nodejs
[electron-plugin]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/bindings/packager/nodejs/src-ts/plugins/electron
[packager-cargo]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/crates/packager/Cargo.toml
[cargo-lock]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/Cargo.lock
[integration-ci]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/.github/workflows/integration-tests.yml
[examples-ci]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/.github/workflows/build-examples.yml
[check-ci]: https://github.com/crabnebula-dev/cargo-packager/blob/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/.github/workflows/check.yml
[workflows]: https://github.com/crabnebula-dev/cargo-packager/tree/37a538e76608b33eaa3f36f7c57b30b284dfa5a9/.github/workflows
