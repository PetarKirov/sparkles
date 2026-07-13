# Briefcase (Python application packaging)

An open-source, template-driven Python application packager that assembles a Python
runtime, application code, dependencies, and resources into native projects, bundles,
and installers, with native signing and a small publication-plugin layer.

| Field             | Value                                                                                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Python                                                                                                                                                        |
| License           | BSD-3-Clause                                                                                                                                                  |
| Repository        | [beeware/briefcase][repo]                                                                                                                                     |
| Documentation     | [Briefcase documentation][docs]                                                                                                                               |
| Reviewed revision | [`389be4fe5d4c890a1c7b558164f867d16e295bf0`][revision] (after `0.4.4`)                                                                                        |
| Category          | **Application packager** with build/run/publish adapters; not an end-user updater or general release control plane                                            |
| Desktop outputs   | macOS `.app`, `.dmg`, `.pkg`, `.zip`; Windows `.msi`, `.zip`; Linux `.deb`, `.rpm`, `.pkg.tar.zst`, `.flatpak`, `.AppImage`                                   |
| Native hosts      | macOS targets require macOS; Windows targets require Windows; Linux native/Flatpak require Linux, while selected Linux builds can use Docker from Linux/macOS |
| OSS/paid boundary | Entire reviewed implementation is OSS; no paid packaging capability is required                                                                               |

**Last reviewed:** July 12, 2026

> [!NOTE]
> Claims are `[source-verified]` at the pinned revision unless explicitly marked
> otherwise. This Linux review inspected source, docs, templates, tests, and workflows;
> it did not produce or install Windows/macOS artifacts, so none of those behaviors is
> `[host-verified]`.

## Overview

### What it solves

Briefcase turns a Python project into a platform-native application and then invokes the
native backend that builds its distribution artifact. The repository states the scope
plainly ([`README.md`][readme]):

> “Briefcase is a tool for converting a Python project into a standalone native application.”

Its pipeline spans more than a conventional freezer: `create` renders a target template,
installs a Python support package, app dependencies, source, resources, and launch stub;
`build` invokes the target build tool; `package` signs and constructs a distributable;
and `publish` dispatches to a platform/format publication channel. It can also accept an
`external_package_path` and sign/package a bundle another tool created
([`commands/base.py`][base-command], [`commands/package.py`][package-command]).

Briefcase is **not** a desktop end-user updater. Its `update` command refreshes the
locally generated project from source/dependencies/resources before another build; it
does not install update logic into released desktop apps. It is also not a full release
control plane: tagging, release planning, multi-host fan-out/fan-in, changelogs,
artifact promotion, and general hosted-release policy remain external.

### Design philosophy

Briefcase separates common lifecycle commands from target adapters:

1. Project metadata lives under `[tool.briefcase]` and
   `[tool.briefcase.app.<name>]` in `pyproject.toml`.
2. Platform/output entry points select `CreateCommand`, `UpdateCommand`,
   `BuildCommand`, `RunCommand`, `PackageCommand`, and `PublishCommand` subclasses
   ([`platforms/__init__.py`][platform-registry]).
3. Cookiecutter templates define native project layouts and a `briefcase.toml` contract;
   support archives supply a relocatable Python runtime; common create logic populates
   those layouts ([`commands/create.py`][create-command]). Default templates live in
   separate `briefcase-<platform>-<format>-template` repositories and are selected by a
   Briefcase-version branch, so their implementation is not in the reviewed clone.
4. Native tools retain authority: WiX/MSI, Xcode and Apple tools, `dpkg-deb`,
   `rpmbuild`, `makepkg`, Flatpak, and linuxdeploy do the final format-specific work.

The architecture deliberately favors real native projects over a universal opaque
container. This makes output inspectable and native-tool-friendly, but templates,
support packages, host tools, and Python wheel availability all become compatibility
inputs.

## How it works

A desktop application is declared once and can override metadata per platform/format:

```toml
[tool.briefcase]
project_name = "Example"
bundle = "com.example"
version = "1.2.3"

[tool.briefcase.app.example]
formal_name = "Example"
description = "Example application"
sources = ["src/example"]
requires = ["httpx==0.28.1"]
```

The normal state machine is:

```bash
briefcase create macOS app
briefcase update macOS app
briefcase build macOS app
briefcase package macOS app -p dmg
briefcase publish macOS app
```

`BaseCommand` computes `build/<app>/<platform>/<format>` paths and validates host,
template target epoch, Python requirement, tools, and per-app configuration
([`commands/base.py`][base-command]). `CreateCommand.create_app()` renders the template,
unpacks the support package, installs the launcher stub, `pip --target` dependencies,
source, distribution metadata, and images. `BuildCommand` optionally calls `update`
before invoking its backend. `PackageCommand` can update/build first, cleans or resumes
the distribution path, and delegates final packaging ([`commands/build.py`][build-command],
[`commands/package.py`][package-command]).

## Packaging analysis

### Input and staging

The primary input is Python source plus PEP 621/Briefcase metadata, application
requirements, resources, icons, permissions, and platform overrides. `create` renders a
platform template into `build/`, downloads a matching Python support archive, and
installs requirements into the template's app-packages location with `pip --target`
([`commands/create.py`][create-command]). Template and support revisions are recorded in
`briefcase.toml`; update can selectively replace code, resources, requirements, support,
or launcher stub.

Briefcase **bundles rather than freezes into one executable**. Desktop layouts retain:

- a complete, target-specific Python support runtime;
- a small native launcher/stub;
- copied application source and installed Python packages in separate app directories;
- native extension modules and framework resources as files in the bundle.

Normal staging removes stale `__pycache__` content, and launcher-based bundles disable
`.pyc` generation to avoid source-path leakage and signature mutation. Briefcase is not
a Python bytecode freezer ([`commands/create.py`][create-command]).

There is no cx_Freeze/PyInstaller-style static import graph and no single-file extraction
runtime. Dynamic imports continue to work when their packages were installed into the
bundle. The cost is a relatively large runtime tree and dependence on target-compatible
wheels. macOS, iOS, and other non-host targets reject source distributions in cases
where they cannot build them; compatible wheels must already exist
([`macOS platform docs`][macos-docs]).

`external_package_path` bypasses creation/build and lets Briefcase package an existing
macOS, Windows, or Linux bundle. The code explicitly prevents build/update/run for such
external apps while retaining packaging/signing support ([`commands/base.py`][base-command],
[`commands/package.py`][package-command]).

### Outputs and target matrix

For the desktop scope of this survey:

| Target/backend              | Distribution artifact                                                 | Build authority                                                               |
| --------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| macOS `app`/Xcode           | `.dmg` (GUI default), `.pkg` (console required), signed `.app` `.zip` | Apple `codesign`, `productbuild`, `hdiutil`/archive and notarization services |
| Windows `app`/Visual Studio | `.msi` (default) or portable `.zip`                                   | WiX plus Windows SDK signing tools                                            |
| Linux `system`              | `.deb`, `.rpm`, or `.pkg.tar.zst` selected by target distribution     | `dpkg-deb`, `rpmbuild`, or `makepkg`                                          |
| Linux `flatpak`             | Single `.flatpak` bundle                                              | `flatpak-builder`/`flatpak build-bundle`                                      |
| Linux `appimage`            | `.AppImage`                                                           | linuxdeploy/AppImage tooling                                                  |

Briefcase also supports Android, iOS, web, tvOS/watchOS, and Wear OS paths, but those are
outside this catalog's desktop focus. AppImage is retained but explicitly discouraged:
the checked-in docs say unit coverage remains while the core team does not build it in
its release process ([`linux/appimage.md`][appimage-docs]).

Host boundaries are explicit in classes: macOS mixins accept only `Darwin`; Windows only
`Windows`; Flatpak only `Linux` ([`platforms/macOS/__init__.py`][macos-source],
[`platforms/windows/__init__.py`][windows-source],
[`platforms/linux/flatpak.py`][flatpak-source]). Linux system/AppImage setup can use
Docker from macOS or Linux, but execution and some native operations still require
Linux. Briefcase is therefore a native-host matrix tool, not a general cross-packager.

### Metadata and dependencies

`FinalizedAppConfig` normalizes name/formal name, bundle ID, version, description,
author, license, sources, requirements, resources, icons, permissions, document types,
URLs, and nested platform/format overrides ([`config.py`][config]). Backends map these to
`Info.plist`, WiX/MSI metadata, desktop files, Flatpak manifests, and Debian/RPM/Arch
control data.

Python dependencies are **vendored application payload**, installed by pip into the
bundle. `requires` can be supplemented by platform-specific requirements and installer
arguments. Binary wheels must match the target Python/ABI/platform. Linux system
packages are the important exception: they use the distribution's system Python and can
declare `system_requires` and `system_runtime_requires`; this makes the result smaller
and package-manager-integrated but ties it to the distribution Python
([`linux/system.md`][system-docs]). Flatpak declares a runtime/SDK/base; AppImage tries to
vendor shared libraries through linuxdeploy.

Identity and version semantics remain native. Bundle ID drives Apple identity; WiX uses
MSI identities and converts PEP 440 versions to a strict integer triple; Linux metadata
uses distribution conventions. Briefcase exposes `version_triple` when automatic MSI
conversion is unsuitable ([`windows/index.md`][windows-docs]).

### Installation, upgrade, and uninstall

Briefcase generates artifacts but does not implement one universal installer:

- MSI delegates transactional file/registry ownership, repair, upgrade, and uninstall to
  Windows Installer. Briefcase can add post-install/pre-uninstall scripts and per-user or
  per-machine selection; its docs warn those scripts must preserve MSI's clean database
  model ([`windows/index.md`][windows-docs]).
- PKG delegates receipts and install scripts to macOS Installer. DMG/ZIP carry an app
  bundle whose install/upgrade is copy/replace and whose uninstall is deletion.
- DEB/RPM/Arch and Flatpak delegate upgrade/removal to their package managers.
- AppImage is a portable file: execution and replacement are user-owned.
- Windows/macOS ZIPs are portable/bundle transports with no package transaction.

The local `briefcase update` command is often misread here. `UpdateCommand` refreshes the
**build staging project**; it is not an installed-app updater, update feed, rollback
engine, or release channel ([`commands/update.py`][update-command]). Released desktop
apps receive no Briefcase runtime component that checks for a later version.

### Signing and platform trust

macOS packaging signs nested content and the bundle, signs PKG installers with a distinct
installer identity, submits notarization, waits or persists a submission ID for later
resume, and staples accepted results. Ad-hoc signing is local-development only
([`platforms/macOS/__init__.py`][macos-source], [`macOS docs`][macos-docs]). These paths
require macOS and Apple credentials.

Windows packaging discovers certificate identity/stores, signs app files and MSI using
Windows SDK tools, supports SHA-256 file/timestamp digests and a timestamp-authority URL,
and can leave output unsigned via the misleadingly cross-platform `--adhoc-sign` option
([`platforms/windows/__init__.py`][windows-source], [`windows docs`][windows-docs]). It
requires a Windows host.

Android/iOS signing exists but is outside desktop scope. Linux native package/repository
signing is not a unified Briefcase feature; Flatpak repository signing and distro repo
trust belong to downstream publication. Briefcase does not generate a signed checksum
manifest or cross-platform update signature.

### Publication and discovery

Briefcase `0.4` has a real but narrow publication abstraction. `PublishCommand` discovers
`briefcase.channels.<platform>.<format>` entry points, ensures a distribution exists,
and invokes `BasePublicationChannel.publish_app()` ([`commands/publish.py`][publish-command],
[`channels/__init__.py`][channels]). The reviewed package registers only App Store for iOS Xcode and Play Store for Android
Gradle in `pyproject.toml` ([`pyproject.toml`][pyproject]), but both first-party
`publish_app()` implementations raise “not yet implemented”
([`channels/appstore.py`][appstore-channel], [`channels/playstore.py`][playstore-channel]).
Third parties can register working channels.

No built-in desktop channel uploads DMGs/PKGs/MSIs/ZIPs to GitHub Releases, S3, Homebrew,
WinGet, Flathub, or Linux repositories. The Flatpak docs explicitly state that Briefcase
can produce a publishable app but does not automate Flathub/repository publication
([`linux/flatpak.md`][flatpak-docs]). Desktop artifact hosting and package-manager catalog
registration are downstream release-pipeline steps.

This makes `publish` an extensible adapter boundary, not proof that Briefcase is a
release orchestrator. It neither fans in artifacts from separate hosts nor applies
cross-platform promotion/announcement policy.

### Updates and release channels

There is no desktop update-feed protocol, delta package, stable/beta channel model,
cohort rollout, mandatory-version policy, or rollback controller in Briefcase. MSI,
Linux packages, and Flatpak can participate in their native managers **after a downstream
publisher registers them**; DMG/ZIP/AppImage outputs need another updater or user-driven
replacement.

The command named `upgrade` updates Briefcase-managed **toolchains** such as WiX or Java;
`update` refreshes the generated project. Neither updates an installed end-user app
([`commands/upgrade.py`][upgrade-command], [`commands/update.py`][update-command]). An
application needing self-update must integrate a separate framework and publication
feed.

### Automation and CI

The CLI's uniform command shape and non-interactive options suit CI, but a serious desktop
release needs native runner fan-out: macOS for Apple bundles/signing/notarization,
Windows for MSI/signing, and Linux for Flatpak/native formats. Docker helps create
specific Linux distro/AppImage environments from Linux/macOS; Flatpak cannot itself be
built inside Docker because its builder needs low-level sandbox operations
([`linux/flatpak.md`][flatpak-docs]).

Upstream CI reflects this boundary: unit tests run on Intel/Apple Silicon macOS, Windows,
and Ubuntu over supported Python versions; package construction and documentation checks
are separate jobs ([`.github/workflows/ci.yml`][ci]). Tests heavily mock platform tools
and verify command sequencing, paths, signing arguments, templates, and resumable
notarization. They are implementation confidence, not a consumer release control plane.

### Supply-chain evidence and reproducibility

Positive controls include pinned template/support revisions in generated metadata,
template compatibility epochs, Python requirement validation, isolated caches, native
signing/notarization, unit tests for tool invocation, and host-specific CI. The upstream
workflow can request a GitHub provenance attestation for the **Briefcase Python package**;
that does not mean applications produced by Briefcase receive provenance
([`.github/workflows/ci.yml`][ci]).

Generated apps have no built-in SBOM, application provenance, signed checksum file, or
reproducibility manifest. Templates may come from Git URLs; support archives and pip
requirements are downloaded; unless users pin URLs, revisions, requirements, wheels,
Docker images, and native toolchains, the same config need not resolve to the same bytes.
Native signatures, timestamps, notarization, archive metadata, and backend build tools
also prevent straightforward byte identity. Download caching is URL/filename-based and
does not verify an expected artifact digest; generated requirements files can include the
current time. Downstream CI should lock inputs, use hash-checked wheelhouses, retain an
artifact inventory, generate SBOM/provenance, and sign that evidence separately
([`integrations/file.py`][file-integration], [`commands/create.py`][create-command]).

### Extensibility and UX

Briefcase exposes two plugin axes:

- platform packages register output modules and command subclasses through
  `briefcase.platforms` entry points;
- publication channels register per-platform/per-format implementations through
  `briefcase.channels.*` entry points ([`plugins.md`][plugins]).

Custom Cookiecutter templates, `briefcase.toml` path indexes, support packages,
platform-format config inheritance, raw tool arguments, Dockerfile/Flatpak manifest
content, and external app paths provide escape hatches. The generated native project can
also be opened and edited with `briefcase open`.

The UX benefit is one `create → build → package` vocabulary across many targets and a
clear separation between source refresh and native packaging. The costs are a large
configuration surface, template/support version coupling, native-host CI, wheel
availability constraints, and semantic asymmetry: “package” can mean MSI transaction,
app-bundle transport, distro package, sandbox bundle, or portable file.

## Strengths

- Fully OSS, broad desktop and mobile/web target coverage.
- Bundles a real Python runtime and dependencies without requiring end users to install
  Python.
- Generates inspectable native projects and delegates to mature native format tools.
- Strong Apple signing/notarization workflow, including resumable submissions.
- Supports packaging externally built bundles as well as Briefcase-generated projects.
- Plugin interfaces cover both new platform backends and publication channels.
- Extensive cross-host unit-test matrix and explicit host validation.

## Weaknesses

- Requires a native Windows/macOS/Linux CI matrix for trustworthy desktop releases.
- It bundles a runtime tree rather than producing a compact single executable.
- Target-compatible wheel availability, support packages, and templates are hard
  prerequisites; arbitrary source distributions cannot always be built.
- No desktop updater, update feed, release channels, deltas, or rollback service.
- Built-in publication is mobile-store-focused; desktop hosting/catalog publication is
  external.
- No generated application SBOM, provenance, checksum manifest, or reproducibility claim.
- AppImage support is explicitly low priority and discouraged upstream.
- Native lifecycle semantics cannot be normalized across MSI, bundles, packages, and
  portable files.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                               | Trade-off                                                          |
| ----------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------ |
| Bundle a Python support runtime                             | End users need no system Python                         | Larger file tree; target support archives and wheels are required  |
| Keep app code/packages separate instead of static freezing  | Preserve normal Python import/package behavior          | No single-file executable and less dead-code elimination           |
| Generate native projects from templates                     | Reuse native build systems and keep output inspectable  | Template epochs and native tools become compatibility dependencies |
| Split `create`, `update`, `build`, `package`, and `publish` | Make staging boundaries explicit and repeatable         | Users may confuse build-project `update` with end-user updates     |
| Require target-native hosts                                 | Use supported platform SDKs and signing contracts       | Multi-host CI is mandatory                                         |
| Delegate lifecycle to native formats                        | Preserve MSI/package-manager/bundle conventions         | Upgrade, rollback, and uninstall differ by target                  |
| Allow `external_package_path`                               | Reuse signing/packaging for other build systems         | External apps cannot use Briefcase create/update/build/run         |
| Add publication channels as entry points                    | Permit store/provider integrations without core changes | Only mobile channels are built in at the reviewed revision         |
| Keep format-specific configuration                          | Expose native capabilities faithfully                   | Cross-platform metadata is not a complete abstraction              |
| Leave SBOM/provenance downstream                            | Keep core focused on application construction           | Every release pipeline must add supply-chain evidence itself       |

## Sources

- [Repository and exact reviewed tree][revision]
- [`README.md` — positioning, targets, and license badge][readme]
- [`src/briefcase/commands/create.py` — template/runtime/dependency staging][create-command]
- [`src/briefcase/commands/base.py` — host, paths, external bundles, and validation][base-command]
- [`src/briefcase/commands/package.py` — package orchestration and resume boundary][package-command]
- [`src/briefcase/commands/publish.py` and `channels/` — publication plugin layer][publish-command]
- [macOS platform source — signing, notarization, DMG/PKG/ZIP][macos-source]
- [Windows platform source — MSI/ZIP and signing][windows-source]
- [Linux platform source — native packages, Flatpak, and AppImage][linux-tree]
- [Checked-in platform documentation][platform-docs]
- [Tests and upstream CI matrix][tests]

<!-- References -->

[repo]: https://github.com/beeware/briefcase
[docs]: https://briefcase.beeware.org/
[revision]: https://github.com/beeware/briefcase/tree/389be4fe5d4c890a1c7b558164f867d16e295bf0
[readme]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/README.md
[pyproject]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/pyproject.toml
[config]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/config.py
[base-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/base.py
[create-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/create.py
[update-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/update.py
[upgrade-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/upgrade.py
[build-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/build.py
[package-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/package.py
[publish-command]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/commands/publish.py
[channels]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/channels/__init__.py
[appstore-channel]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/channels/appstore.py
[playstore-channel]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/channels/playstore.py
[file-integration]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/integrations/file.py
[platform-registry]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/platforms/__init__.py
[macos-source]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/platforms/macOS/__init__.py
[windows-source]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/platforms/windows/__init__.py
[flatpak-source]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/platforms/linux/flatpak.py
[linux-tree]: https://github.com/beeware/briefcase/tree/389be4fe5d4c890a1c7b558164f867d16e295bf0/src/briefcase/platforms/linux
[macos-docs]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/platforms/macOS/index.md
[windows-docs]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/platforms/windows/index.md
[system-docs]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/platforms/linux/system.md
[flatpak-docs]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/platforms/linux/flatpak.md
[appimage-docs]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/platforms/linux/appimage.md
[plugins]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/plugins.md
[platform-docs]: https://github.com/beeware/briefcase/tree/389be4fe5d4c890a1c7b558164f867d16e295bf0/docs/en/reference/platforms
[ci]: https://github.com/beeware/briefcase/blob/389be4fe5d4c890a1c7b558164f867d16e295bf0/.github/workflows/ci.yml
[tests]: https://github.com/beeware/briefcase/tree/389be4fe5d4c890a1c7b558164f867d16e295bf0/tests
