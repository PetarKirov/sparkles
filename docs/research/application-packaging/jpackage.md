# jpackage and JVM integrations (OpenJDK / packaging backend)

OpenJDK's `jpackage` turns a Java application plus a runtime image into a self-contained
application image and, on the native host, a platform installer; Beryx, Maven plugins,
and JReleaser wrap that backend at different orchestration layers.

| Field                   | Value                                                                                                     |
| ----------------------- | --------------------------------------------------------------------------------------------------------- |
| Language                | Java plus native launchers and platform templates                                                         |
| License                 | GPL-2.0-only with Classpath Exception (OpenJDK module); Apache-2.0 wrappers reviewed below                |
| Repository              | [openjdk/jdk][jdk-repo]                                                                                   |
| Documentation           | [`jpackage(1)`][jpackage-man]                                                                             |
| Reviewed source         | OpenJDK [`d3e5304c0f70aa03a52f5449cb38645a184b23dc`][jdk-reviewed] (`jdk-28+6-19-gd3e5304c0f7`)           |
| Category                | **Format/backend primitive**; Beryx/Maven are build-tool adapters; JReleaser is a release control plane   |
| Supported hosts/targets | `app-image`; Windows `exe`/`msi`; Linux `deb`/`rpm`; macOS `dmg`/`pkg`, each built on its target platform |
| OSS/paid boundary       | All reviewed implementations are open source; no paid packaging backend                                   |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> `jpackage`, Beryx, and a Maven goal do not become release orchestration merely because
> they run during a release build. `jpackage` constructs native bytes. Beryx and the Maven
> plugin prepare inputs and invoke it. [JReleaser][jreleaser-page] can coordinate
> `jpackage` assembly with checksums, signing, forge releases, package-manager metadata,
> publication, and announcements—but native `jpackage` execution still belongs on the
> matching OS runner.

---

## Overview

### What it solves

The checked-in command manual defines both the payload and the native-host boundary:

> “The `jpackage` tool will take as input a Java application and a Java run-time image,
> and produce a Java application image that includes all the necessary dependencies. …
> Each format must be built on the platform it runs on, there is no cross-platform
> support.”
>
> — [`src/jdk.jpackage/share/man/jpackage.md`][jpackage-man]

This solves the “user should not install a matching JVM” problem. The application image
contains launchers, application files, configuration, and either a supplied runtime image
or one created by invoking `jlink`. A second pass can wrap that image in the current
platform's ordinary installer/package format.

### Design philosophy

`jpackage` is a **native packager over a self-contained image**, not a universal installer
format. Common options describe Java entry points, launchers, content, icons, identity,
and runtime creation. Platform options map to native concepts. Its source registers
platform bundlers in separate Linux, macOS, and Windows trees and invokes native tools
where required ([`src/jdk.jpackage/`][jpackage-source]).

The two-stage model is intentional: `--type app-image` produces an inspectable/runnable
application tree; `--app-image` can later use a predefined image as installer input. This
supports customization and signing boundaries without making `jpackage` a publisher.

## How it works

A non-modular application can start from a directory containing the main JAR and its
runtime dependencies:

```bash
jpackage \
  --type app-image \
  --name Acme \
  --input build/jars \
  --main-jar acme.jar \
  --main-class com.example.Acme \
  --app-version 1.2.3 \
  --dest build/package
```

The pipeline is:

```text
JARs/resources + launcher metadata
  -> supplied runtime image OR jlink-created runtime
  -> platform application image
  -> optional native installer/package on the same OS
```

`--input` includes every file in its directory. `--app-content` adds payload outside the
Java input, `--add-launcher` adds named launchers from property files, and
`--file-associations` maps extensions/MIME types. `--resource-dir` replaces built-in
icons/templates/resources; `--temp` preserves intermediates for inspection
([`jpackage(1)`][jpackage-man]).

## Analysis dimensions

### Input and staging

The primary inputs are a modular application (`--module`) or main JAR/class, all files
below `--input`, optional application content, launcher property files, associations,
icons, and license. The runtime path has two branches:

- `--runtime-image <dir>` copies a prebuilt runtime into the application image; or
- without it, `jpackage` invokes `jlink`, passing `--add-modules`, `--module-path`, and
  `--jlink-options` (defaulting to stripped native commands/debug/man/header content).

This is runtime-image construction, not dependency resolution. `jpackage` can infer a
starting module set for a main JAR, but application/library dependencies still must be in
the input/module path. The staged application image is the contract consumed by native
packagers; `--app-image` lets a later invocation consume an already prepared image.

### Outputs and target matrix

| Host    | Application image                                 | Native package types | Delegated/native requirements                                                          |
| ------- | ------------------------------------------------- | -------------------- | -------------------------------------------------------------------------------------- |
| Windows | self-contained app directory with `.exe` launcher | `exe`, `msi`         | Windows packaging tools; WiX is required for MSI/EXE paths in supported JDK lines      |
| Linux   | self-contained app directory                      | `deb`, `rpm`         | `dpkg`/Debian or RPM tooling expected by the selected bundler                          |
| macOS   | `.app` bundle                                     | `dmg`, `pkg`         | Apple `hdiutil`, `pkgbuild`/`productbuild`, `codesign`, keychain tooling as applicable |

`--type` accepts `app-image`, `exe`, `msi`, `rpm`, `deb`, `pkg`, or `dmg`, but command
help exposes only values valid for the current platform. The explicit no-cross-platform
contract means a Linux release job cannot validate Windows installer generation or macOS
signing. A foreign runtime image alone does not remove the native installer constraint.

### Metadata and dependencies

Common fields include name, application/package version, vendor, copyright, description,
icon, license, destination, main launcher, Java/launcher arguments, and file associations.
Platform fields add native semantics: Linux package name, maintainer, menu group,
dependencies, RPM license/category/release, shortcuts, and services; Windows menu/desktop
shortcuts, directory chooser, per-user install, console, help/update URLs, and
`--win-upgrade-uuid`; macOS bundle identifier, category, package name, signing prefix,
entitlements, App Store mode, and extra DMG content ([`jpackage(1)`][jpackage-man]).

Linux dependency declarations are strings for native package metadata. The Java runtime
is vendored in the image rather than expressed as a system JRE dependency. Other native
libraries/resources remain the application's responsibility.

### Installation, upgrade, and uninstall

An `app-image` has no package database; users or another distributor place/remove it.
Native package lifecycle belongs to Windows Installer/EXE installer behavior, `dpkg`, RPM,
or Apple's installer/container semantics. `--win-upgrade-uuid` supplies stable Windows
upgrade identity; Linux name/version/release and macOS bundle/package identifiers feed
their native systems.

`jpackage` does not expose one cross-platform install, repair, rollback, or uninstall API.
It generates shortcuts, file associations, services, and installer metadata through
platform flags/templates; the selected native system executes them.

### Signing and platform trust

macOS signing is integrated pass-through to native code-signing facilities. `--mac-sign`,
key user name/keychain, signing prefix, entitlements, and App Store mode feed the macOS
pipeline; `AppImageSigner` signs nested files/bundles before the outer bundle, and PKG
packaging can pass `--sign` to `productbuild` ([`AppImageSigner.java`][app-image-signer],
[`MacPkgPackager.java`][mac-pkg]).

That does **not** include notarization submission, waiting for an Apple ticket, or
stapling. Windows options in the reviewed command do not provide a general Authenticode
certificate/timestamp workflow; sign produced launchers/installers in a separate native
stage if required. Linux package/repository signing is likewise outside the common
`jpackage` operation. Checksums and attestations should cover final signed bytes.

### Publication and discovery

Not applicable. `--dest` writes local output. `jpackage` does not upload a forge release,
publish APT/RPM metadata, submit Microsoft Store/Homebrew records, or host update feeds.
A generated DEB/RPM is not a repository, and a generated MSI/DMG is not discoverable until
another system hosts and advertises it.

### Updates and release channels

There is no embedded update checker, delta protocol, feed, rollout service, or channel
model. `--win-update-url` is installer metadata, not an update implementation. Native
package managers or an application-specific updater may consume later versions after a
release system publishes them.

### Automation and CI

`@filename` option files make long invocations repeatable, and `--verbose tools,summary`
can record delegated commands/tool versions. Correct CI is a native matrix: assemble
Windows on Windows, Linux packages on Linux, and signed/notarized Apple outputs on macOS.
Secrets should be injected only into signing jobs.

Beryx's Gradle plugins add build-graph preparation:

- `org.beryx.jlink` merges non-modular dependencies where needed, creates a modular
  `jlink` image, then exposes `jpackageImage` and `jpackage` tasks for modular apps
  ([Beryx JLink README][beryx-jlink-readme], [`JlinkPlugin.groovy`][beryx-jlink-plugin]).
- `org.beryx.runtime` builds a custom JRE for non-modular apps; its `jpackageImage` depends
  on the JRE task and `jpackage` depends on the image task
  ([Beryx Runtime README][beryx-runtime-readme], [`JPackageTask.groovy`][beryx-runtime-task]).
- `jpackage-maven-plugin` maps Maven parameters/toolchains to a `jpackage` command and
  supports OS-specific executions; it remains an invocation adapter
  ([`JPackageMojo.java`][maven-mojo]).

Beryx `targetPlatforms` can create `jlink` runtime images for configured JDKs, but its
`jpackage` task still invokes one host `jpackage` executable and native installer tools.
It must not be described as general cross-OS installer production. Recent Beryx task
annotations explicitly disable Gradle caching because platform tools and mutable runtime
inputs prevent safe snapshots ([`AbstractJPackageTask.groovy`][beryx-abstract-task]).

JReleaser is the composition layer above these build adapters. Its `jpackage` assembler
selects a platform JDK/runtime image, stages JARs/artifacts/icons, constructs the command,
and returns artifacts. Assembly is a separate, preceding operation—not an item in
JReleaser's `fullRelease` workflow—so a correct CI design runs the assembler on each
native host, collects its outputs, and then applies the wider checksum, generic signing,
forge-release, package-manager, publication, and announcement workflow
([`JpackageAssemblerProcessor.java`][jreleaser-jpackage], [JReleaser deep-dive][jreleaser-page]).
Those release capabilities belong to JReleaser, not OpenJDK `jpackage`.

### Supply-chain evidence and reproducibility

`jpackage` emits neither SBOM nor provenance. Application-image contents depend on the JDK,
module selection, input mtimes/content, native tool versions, templates, and signing.
`--resource-dir`, arbitrary additional content, and native package tools are deliberate
non-hermetic inputs. Preserve the JDK/toolchain identity, option file, runtime-image hash,
and final artifact hashes in the release record.

The Beryx plugins' disabled-cache annotations are an honest signal: their convenience
should not be mistaken for deterministic, remotely cacheable packaging. JReleaser can add
checksums/catalogs around outputs, but reproducibility still belongs to the native build.

### Extensibility and UX

`jpackage` offers three escape hatches: option files, launcher property files, and
`--resource-dir` template replacement. They cover significant native customization while
keeping one CLI, but unsupported installer behavior requires post-processing or another
backend.

Beryx provides a richer Gradle DSL and dependency/module preparation; the Maven plugin
provides lifecycle/toolchain integration; JReleaser provides release-stage composition.
Using the smallest layer that owns the needed behavior keeps capability attribution and
failure boundaries clear.

## Strengths

- Ships a self-contained Java application and tailored runtime image.
- Produces native application images and mainstream installers from one JDK command model.
- Makes the native-host restriction explicit instead of implying cross-packaging.
- Supports native metadata, launchers, associations, services, and macOS signing controls.
- Composes cleanly with Gradle/Maven preparation and JReleaser orchestration.

## Weaknesses

- Requires one packaging job per target OS and additional native toolchains.
- Does not publish, notarize/staple, generate repository metadata, or manage updates.
- Windows and Linux signing need separate release stages; macOS signing is not notarization.
- Runtime inclusion can make artifacts large, and module/dependency selection remains a
  build responsibility.
- Native outputs differ enough that one configuration does not guarantee lifecycle parity.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                 | Trade-off                                                     |
| --------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------- |
| Bundle a runtime with the app           | Remove the end-user JRE prerequisite                      | Larger artifacts and runtime patch ownership                  |
| Split app image from native package     | Permit inspection/customization and reuse                 | Adds an intermediate artifact and signing-order choices       |
| Require native-host packaging           | Use authentic platform tools and formats                  | Requires a multi-OS CI matrix                                 |
| Expose platform-specific options        | Preserve native installer semantics                       | Configuration is not fully portable                           |
| Let wrappers prepare/invoke the backend | Integrate Java build graphs without duplicating packagers | Wrapper target claims must not exceed `jpackage` capabilities |
| Leave distribution to other tools       | Keep the JDK tool locally focused                         | JReleaser or another control plane is needed for a release    |

## Sources

- OpenJDK local sparse clone at `/home/petar/code/repos/packaging-research/openjdk-jdk`,
  reviewed at `d3e5304c0f70aa03a52f5449cb38645a184b23dc`.
- Beryx JLink plugin local clone at
  `/home/petar/code/repos/packaging-research/badass-jlink-plugin`, reviewed at
  `9c99b2204d04e5a331dced12cd8973a8291f958b`.
- Beryx Runtime plugin local clone at
  `/home/petar/code/repos/packaging-research/badass-runtime-plugin`, reviewed at
  `89a94a255500d5ed72a2f1f427b2f124b10d3d1d`.
- `jpackage-maven-plugin` local clone at
  `/home/petar/code/repos/packaging-research/jpackage-maven-plugin`, reviewed at
  `cabe0b356b5e36bc5435c05189c534bd820ba263`.
- JReleaser local clone at `/home/petar/code/repos/packaging-research/jreleaser`, reviewed
  at `98de563b61df6232d38dafafa8d1f1728432c207`.
- Evidence level: `[source-verified]`; no Windows or macOS artifact was host-verified.

<!-- References -->

[jdk-repo]: https://github.com/openjdk/jdk
[jdk-reviewed]: https://github.com/openjdk/jdk/tree/d3e5304c0f70aa03a52f5449cb38645a184b23dc
[jpackage-man]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/jdk.jpackage/share/man/jpackage.md
[jpackage-source]: https://github.com/openjdk/jdk/tree/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/jdk.jpackage
[app-image-signer]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/jdk.jpackage/macosx/classes/jdk/jpackage/internal/AppImageSigner.java
[mac-pkg]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/jdk.jpackage/macosx/classes/jdk/jpackage/internal/MacPkgPackager.java
[beryx-jlink-readme]: https://github.com/beryx/badass-jlink-plugin/blob/9c99b2204d04e5a331dced12cd8973a8291f958b/README.md
[beryx-jlink-plugin]: https://github.com/beryx/badass-jlink-plugin/blob/9c99b2204d04e5a331dced12cd8973a8291f958b/src/main/groovy/org/beryx/jlink/JlinkPlugin.groovy
[beryx-abstract-task]: https://github.com/beryx/badass-jlink-plugin/blob/9c99b2204d04e5a331dced12cd8973a8291f958b/src/main/groovy/org/beryx/jlink/AbstractJPackageTask.groovy
[beryx-runtime-readme]: https://github.com/beryx/badass-runtime-plugin/blob/89a94a255500d5ed72a2f1f427b2f124b10d3d1d/README.md
[beryx-runtime-task]: https://github.com/beryx/badass-runtime-plugin/blob/89a94a255500d5ed72a2f1f427b2f124b10d3d1d/src/main/groovy/org/beryx/runtime/JPackageTask.groovy
[maven-mojo]: https://github.com/petr-panteleyev/jpackage-maven-plugin/blob/cabe0b356b5e36bc5435c05189c534bd820ba263/src/main/java/org/panteleyev/jpackage/JPackageMojo.java
[jreleaser-jpackage]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/assemblers/JpackageAssemblerProcessor.java
[jreleaser-page]: ./jreleaser.md
