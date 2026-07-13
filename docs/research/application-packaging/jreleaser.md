# JReleaser (JVM / polyglot release automation)

JReleaser is an open-source release control plane that takes already-built artifacts, optionally assembles further distributions, and coordinates checksums, catalogs, signatures, forge releases, package-manager metadata, publication, and announcements.

| Field              | Value                                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Implementation     | Java; CLI plus Gradle, Maven, Ant, and Java tool-provider integrations                                                                            |
| License            | Apache-2.0                                                                                                                                        |
| Repository         | [jreleaser/jreleaser][repo]                                                                                                                       |
| Documentation      | [JReleaser guide][guide]                                                                                                                          |
| Version at review  | `1.25.0` in the inspected `README.adoc`                                                                                                           |
| Inspected revision | [`98de563b61df6232d38dafafa8d1f1728432c207`][reviewed-tree]                                                                                       |
| Primary category   | **Release and packaging control plane**                                                                                                           |
| Product role       | Control plane: **yes** · app packager: **partly** · app updater: **no** · format primitive: **no**                                                |
| Commercial model   | **OSS, not paid**: the inspected implementation is Apache-2.0 and solicits Open Collective sponsorship; no paid edition or gated engine was found |
| Project scope      | Java and non-Java artifacts; desktop, CLI, container, language-package, and package-manager release paths                                         |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> JReleaser is not one universal package format and does not install an update agent in
> the application. Its center of gravity is orchestration. It can directly assemble
> archives, Debian packages, Java runtime images, native images, and `jpackage`
> installers, but many “packagers” generate ecosystem manifests, invoke an external
> builder, or update another Git repository.

---

## Overview

### What it solves

JReleaser separates compilation from release distribution. Build tools or earlier
workflow jobs produce JARs, archives, native binaries, runtime images, installers, or
arbitrary files. JReleaser then applies one model to artifact selection, forge release
creation, package-manager metadata, checksums and signatures, uploads, repository
updates, and announcements. Its own README states the scope verbatim:

> “JReleaser is a release automation tool for Java and non-Java projects (Go, Rust,
> Elixir, C#, etc). Its goal is to simplify creating releases and publishing artifacts
> to multiple package managers while providing customizable options.”
>
> — [`README.adoc`][readme]

This is broader than an application packager but intentionally downstream of most
compilers and build graphs. The model's artifact is fundamentally a path, optional
transform, platform selector, and hashes; the release engine does not require the
payload to have been built by Java tooling ([`Artifact`][artifact-api]).

### Design philosophy and classification

The architecture is a **declarative, stage-oriented control plane**:

- **Control plane — primary role.** [`Workflows.fullRelease`][workflows] fixes the
  order from `changelog`, `checksum`, `catalog`, and `sign` through `deploy`, `upload`,
  `release`, `prepare`, `package`, `publish`, and `announce`. Smaller commands select
  prefixes or subsets of that graph.
- **App packager — partial role.** Six built-in assemblers create archives, `.deb`
  files, Java archives, `jlink` images, `jpackage` outputs, and GraalVM native-image
  archives ([`JReleaserSupport`][support]). `jpackage` is invoked from a selected JDK
  and can emit native platform package types ([`JpackageAssemblerProcessor`][jpackage]).
- **App updater — not its role.** No JReleaser runtime is embedded into the shipped
  application. Upgrade discovery and replacement are delegated to Homebrew, Scoop,
  Winget, Chocolatey, Flatpak, Snap, SDKMAN!, and similar clients.
- **Format primitive — not its role.** It consumes and emits formats but is not a
  reusable archive/package specification or low-level encoder. For example, the
  Debian assembler composes `control.tar.zst`, `data.tar.zst`, and an `ar` container
  as one orchestration backend ([`DebAssemblerProcessor`][deb-assembler]).
- **OSS versus paid.** The inspected tree is licensed Apache-2.0 ([`LICENSE`][license])
  and its banner asks users to sponsor the project via Open Collective
  ([`Banner.properties`][banner]). There is no paid feature gate in the reviewed
  source; sponsorship is funding, not a separate paid distribution.

## How it works

A typical configuration declares project metadata, a forge releaser, distributions
whose artifacts already exist, and packagers attached to those distributions:

```yaml
project:
  name: acme
  version: 1.2.3
  description: Acme CLI
  license: Apache-2.0
release:
  github:
    owner: acme
distributions:
  acme:
    type: BINARY
    artifacts:
      - path: build/acme-{{projectVersion}}-linux-x86_64.tar.gz
        platform: linux-x86_64
    brew:
      active: RELEASE
      repository:
        active: RELEASE
```

The YAML, TOML, and JSON parser modules test equivalent model inputs; the checked-in
YAML fixture demonstrates project fields, forge ownership, artifact paths, and
Mustache interpolation ([`jreleaser.yml` fixture][yaml-fixture]). After parsing,
model validation resolves defaults and credentials before any workflow item runs.
`WorkflowImpl` validates once, logs selection filters, emits listener and hook events,
runs items serially, stops on a non-tolerated failure, writes a report, and always
cleans up extensions and logging ([`WorkflowImpl`][workflow-impl]).

### Input and staging

There are three input routes:

1. **Declared files and distribution artifacts.** Paths are resolved relative to the
   project base directory. An artifact may be optional, platform-selected, and
   renamed with `transform`; `getEffectivePath` resolves the source and transform,
   then copies when necessary ([`Artifact` implementation][artifact-impl]).
2. **Downloaded inputs.** FTP, HTTP, SCP, and SFTP downloaders can populate the
   `download/` area before assembly ([`JReleaserSupport`][support]).
3. **Assembler outputs.** Archive/file sets, Java JAR sets, `jlink`, GraalVM, Debian,
   and `jpackage` assemblers produce artifacts under `assemble/`. The archive
   assembler materializes templates, artifacts, files, and file sets into a work
   tree before packing each selected format ([`ArchiveAssemblerProcessor`][archive-assembler]).

The output root is partitioned into `download/`, `assemble/`, `artifacts/`,
`checksums/`, `catalogs/`, `signatures/`, `deploy/`, `prepare/`, `package/`, and
`publish/` ([`JReleaserContext`][context-dirs]). Packaging adds a deterministic
coordinate below the last three:
`<stage>/<distribution>/<packager>`. `DistributionProcessor` initializes those paths,
resolves the packager through its processor factory, applies include/exclude and
platform selection, and honors per-packager `continueOnError`
([`DistributionProcessor`][distribution-processor]).

### Outputs and targets

The built-in surface has three materially different kinds of output:

| Kind                      | Built-in targets                                                                                                   | What JReleaser actually does                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| Assemblers                | archive, Debian, Java archive, `jlink`, `jpackage`, native image                                                   | Produces payload archives or native packages; external JDK/GraalVM tools are invoked where required |
| Package metadata/builders | AppImage, asdf, Homebrew, Chocolatey, Docker, Flatpak, GoFish, JBang, Jib, MacPorts, Scoop, Snap, RPM spec, Winget | Renders manifests/workflows; some processors also invoke local or remote builders and registries    |
| Distribution endpoints    | GitHub, GitLab, Gitea, Forgejo, Codeberg, generic Git; Maven deployers; uploaders                                  | Creates forge releases/assets, deploys Maven repositories, or uploads files independently           |

The exact assembler, packager, downloader, uploader, Maven deployer, announcer, and
SBOM cataloger registries are enumerated in [`JReleaserSupport`][support]. Docker
illustrates why “packager” does not mean “manifest only”: it renders a `Dockerfile`,
constructs an assembly context, runs `docker build` or `docker buildx build`, tags the
result, and later publishes it ([`DockerPackagerProcessor`][docker-processor]). By
contrast, repository packagers prepare files and publish them by cloning a tap/bucket
repository, creating a branch, copying generated metadata, committing, tagging, and
pushing ([`AbstractRepositoryPackagerProcessor`][repository-packager]).

### Metadata and dependencies

The project model carries name/version, snapshot policy, descriptions, license,
vendor, stereotype, authors, maintainers, tags, screenshots, icons, language data,
and homepage/documentation/license/support/contribution links
([`Project`][project-api]). A distribution adds type, executable, platform mappings,
artifacts, Java metadata, tags, and a matrix ([`Distribution`][distribution-api]).
Packager templates receive these values plus computed artifact name, version, OS,
architecture, file format, size, root entry, URL, platform replacement, and configured
hashes ([`AbstractPackagerProcessor`][abstract-packager]).

Dependency semantics remain **target-specific**, not normalized across ecosystems.
The Debian assembler exposes `Depends`, `Pre-Depends`, `Recommends`, `Suggests`,
`Enhances`, `Breaks`, and `Conflicts`; the resulting strings are written to Debian
control metadata ([`DebAssemblerProcessor`][deb-assembler]). `jpackage` and Java
assemblers gather configured JARs/runtime images; Homebrew, Snap, Flatpak, Docker,
and other templates express their own runtime requirements. JReleaser does not solve
or lock a universal application dependency graph.

### Install, upgrade, and uninstall

Installation behavior belongs to the selected output ecosystem:

- Homebrew formula templates install the payload under `libexec` and symlink its
  executable; cask templates can render explicit uninstall stanzas
  ([Homebrew templates][brew-templates]).
- Scoop manifests include URLs, hashes, extraction rules, executable declarations,
  and `autoupdate`; Scoop performs install, upgrade, and removal
  ([Scoop template][scoop-template]).
- Chocolatey can receive install and uninstall PowerShell scripts; Winget receives
  version, locale, and installer manifests ([template registry][template-registry]).
- Debian packages carry maintainer scripts and dependency metadata, while `jpackage`
  delegates native installer semantics to the JDK tool.

Consequently, behavior is not uniform: a generated archive has no managed uninstall,
a package-manager entry normally does, and upgrade rollback semantics are whatever
that manager and repository provide. JReleaser itself does not maintain an installed
file database or execute an in-app replacement protocol.

### Signing and trust

Signing is a separate stage after checksums and catalogs. `Signer` can activate PGP,
Cosign, and Minisign independently ([`Signer`][signer]). Each backend selects ordinary
files, distribution artifacts, packed catalogs, and/or aggregate checksum files into
`signatures/`; per-artifact `skipSigning` can exclude inputs
([`AbstractSigner`][abstract-signer]).

PGP is implemented with Bouncy Castle or a command signer. Cosign and Minisign invoke
managed external tools, skip signatures that still validate and are newer than the
input, sign stale/missing pairs, then verify the new signatures. Cosign can generate
a local keypair when none exists ([`CosignSigner`][cosign-signer]). This provides
artifact authenticity, not consumer policy: public-key distribution, identity
binding, key rotation, transparency-log policy, and package-manager trust roots still
need an explicit operational design. The validation tests also make the dangerous
escape hatch concrete: with `yolo`, missing PGP material becomes a warning and PGP is
disabled rather than failing configuration ([`SigningValidatorTest`][signing-test]).

### Publication and discovery

The release stage selects a forge adapter for GitHub, GitLab, Gitea, Forgejo,
Codeberg, or generic Git through `ServiceLoader` factories
([`Releasers`][releasers]). Forge releases become the canonical artifact URL source
used by package templates. Independent uploaders cover Artifactory, FTP, Git forges,
HTTP, S3, SCP, and SFTP; Maven deployers target common Maven repository services
([`JReleaserSupport`][support]).

Package discovery is then delegated to ecosystem indexes or source repositories. A
repository packager can create the repository when needed, clone its configured base
branch, write generated files, optionally sign the commit and tag, and push all refs.
Not every target uses Git: SDKMAN!, for example, calls its API with candidate,
version, per-platform URLs, and release notes ([`SdkmanPackagerProcessor`][sdkman]).
Announcers form a final, independent fan-out to chat, social, mail, discussion, and
webhook services.

### Updates and channels

JReleaser models **release-time channel publication**, not runtime update checks.
`Project.Snapshot` defines a regex (default `.*-SNAPSHOT`), label (default
`early-access`), and changelog policy ([`Project`][project-api]). Packagers declare
whether snapshots are supported; unsupported snapshot publication is skipped in
`AbstractPackagerProcessor` ([`AbstractPackagerProcessor`][abstract-packager]). JBang
has snapshot-specific templates/names, while application-data packagers can exclude
versions by exact value or regex.

Stable upgrades usually happen by publishing a new version of the same formula,
manifest, candidate, image tag, or repository entry. Channels such as `latest`, beta,
nightly, staged rollout, or rollback are therefore conventions expressed in version,
tag, repository branch, image-name, or per-packager configuration—not one global
JReleaser channel abstraction. There is no delta-update protocol or resident update
client.

### Automation and CI

The CLI exposes granular commands for every stage plus `full-release`, configuration
inspection, initialization, template generation/evaluation, JSON schema generation,
and shell completion ([`Main`][cli-main]). Equivalent entry points exist as Gradle
plugin tasks, Maven mojos, Ant tasks, and a Java tool provider. Filters allow CI jobs
to select platforms, distributions, assemblers, packagers, deployers, uploaders, and
announcers; `dryrun` suppresses destructive publication while still exercising much
of model resolution and generation.

The project's own release workflow is an instructive integration test: matrix jobs
produce archives, `jlink`, `jpackage`, and native-image outputs; a release job downloads
them into the exact configured staging paths, invokes the SHA-pinned
`jreleaser/release-action` with `full-release`, passes credentials through
`JRELEASER_*` environment variables, and archives `trace.log` and
`output.properties` ([`release.yml`][release-workflow]). Hooks surround every workflow
item, while extensions can observe before/success/failure events
([`AbstractWorkflowItem`][workflow-item]).

### Supply chain and reproducibility

JReleaser provides useful supply-chain building blocks, but they are composable rather
than a complete trust policy:

- SHA-256 is always added to the checksum algorithm set; aggregate and optional
  individual checksum files are cached until inputs become newer
  ([`Checksum`][checksum]). Other supported digests include SHA-1/384/512, SHA-3,
  RMD160, MD5, and MD2, so policy must reject obsolete choices where inappropriate
  ([`Algorithm`][algorithm]).
- CycloneDX and Syft catalogers invoke external tools per artifact and can pack the
  generated SBOMs into an archive ([`CyclonedxSbomCatalogerProcessor`][cyclonedx]).
- Archive and Debian timestamps resolve to the source commit timestamp when a commit
  is available, otherwise the current time ([`JReleaserModel`][model-timestamp]). The
  `--reproducible` flag also removes the wall-clock timestamp from generated-file
  stamps ([model template properties][model-timestamp]). This improves determinism but
  does not prove every external builder, downloaded tool, container base image, or
  remote package service is reproducible.
- The upstream project combines reproducible Gradle builds, JReleaser checksums, and
  the external SLSA GitHub generator to publish an in-toto provenance asset
  ([`release.yml`][release-workflow]). That workflow demonstrates composition; the
  provenance generator is not the JReleaser packaging engine itself.

Artifact URLs and hashes bind generated package metadata to release payloads, and
signing can bind those payloads to keys. Remaining risks include mutable remote base
images, auto-downloaded tool versions, credential breadth, package-repository review
queues, and publication that spans multiple systems without a cross-system atomic
transaction.

### Extensibility and UX

Configuration is available in YAML, TOML, JSON, Gradle DSL, Maven, and Ant forms.
Mustache templates can be overlaid from a project directory, skipped selectively,
and supplied extra properties. Preparation clears its target directory, merges stock
and local templates, renders text, copies binary resources, and normally copies
license files ([`AbstractTemplatePackagerProcessor`][template-packager]). The
`prepare`, `package`, and `publish` split makes generated metadata reviewable before
network mutation.

Extension JARs are discovered with `ServiceLoader` from defaults, a directory, a Maven
GAV resolved into `output/extensions/<name>`, or a JBang portable export. Extensions
provide initialized extension points, presently including workflow listeners and
Mustache functions in the public API ([`DefaultExtensionManager`][extension-manager]).
Internally, assemblers, packagers, releasers, uploaders, deployers, and announcers also
use factory SPIs. This is powerful but JVM-centric: adding a first-class backend means
shipping Java code and tracking model/validation/template compatibility, whereas a
local template override is simpler but cannot add a new engine stage.

Operational UX is strong for diagnosis—schema generation, config inspection, dry run,
trace logging, stage commands, include/exclude filters, and output partitioning—but
the model is large. The same breadth that consolidates release automation creates a
wide credential surface and target-specific exceptions that users must understand.

## Strengths

- **One release model across polyglot payloads** without requiring JReleaser to build
  the original application.
- **Unusually broad end-to-end control plane** spanning assembly, integrity metadata,
  forge assets, package managers, repositories, uploads, and announcements.
- **Reviewable three-phase package flow** (`prepare`/`package`/`publish`) with isolated
  output directories and granular commands.
- **Real packaging where useful, delegation where native tooling is authoritative**:
  Debian assembly, archives, `jlink`, `jpackage`, GraalVM, Docker/buildx, and remote
  package workflows can coexist.
- **Strong customization surface** through Mustache overlays, matrices, hooks,
  per-target properties, Java SPIs, and loadable extensions.
- **Practical integrity tooling**: multiple checksum algorithms, PGP/Cosign/Minisign,
  SBOM generation, signed repository commits/tags, and composability with SLSA.
- **CI-friendly integrations** and environment-based secret injection across common
  JVM build tools and hosted CI.

## Weaknesses

- **Not a uniform application lifecycle.** Install, upgrade, uninstall, rollback,
  channels, and trust vary by target; archives receive almost none of these semantics.
- **Large configuration and credential surface.** A `full-release` may mutate a forge,
  registries, Maven repositories, package repositories, and announcement channels in
  one serial workflow.
- **No global transactional publication.** A later target can fail after earlier
  targets are visible; `continueOnError` improves availability but can deepen drift.
- **Reproducibility is bounded.** Timestamps are controlled in key outputs, but
  external tools, remote builds, package indexes, and mutable image inputs remain
  outside the guarantee.
- **Updater functionality is delegated.** Applications needing signed in-app updates,
  deltas, staged rollout, or rollback require another system.
- **Extension development is JVM-specific**, and first-class backends cross model,
  validation, processor, SDK, template, and documentation layers.
- **Safety bypasses need governance.** `yolo`, broad tokens, generated key material,
  and permissive per-target continuation are useful in development but hazardous in
  production without policy gates.

## Key design decisions and trade-offs

| Decision                                                                               | Rationale                                                                       | Trade-off                                                                           |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Treat existing artifacts as the primary input                                          | Works with Java, Go, Rust, C#, Elixir, and arbitrary build systems              | Build reproducibility and dependency resolution usually remain upstream             |
| Fixed serial workflow with granular subcommands                                        | Gives understandable stage order and allows CI to split work                    | No cross-target transaction; partial publication is possible                        |
| Separate assembler from packager                                                       | Distinguishes payload construction from package-manager distribution            | Terms overlap in practice, especially for Docker, AppImage, and remote builders     |
| Split package handling into `prepare`, `package`, `publish`                            | Enables inspection, offline generation, and delayed network mutation            | More intermediate state and stage-order assumptions                                 |
| Generate native ecosystem metadata instead of inventing one format                     | Preserves native discovery, install, upgrade, and uninstall behavior            | Semantics and review latency differ across every target                             |
| Resolve templates from model plus artifact facts                                       | One declaration can drive URLs, hashes, platforms, manifests, and announcements | Mustache/property indirection can make final output hard to predict                 |
| Keep signing and cataloging as independent stages                                      | The same artifacts/checksums/SBOMs can be selected and verified consistently    | Key identity, trust roots, and provenance policy are still operator concerns        |
| Use external authoritative tools (`jpackage`, GraalVM, Docker, Syft, Cosign, Minisign) | Avoids reimplementing complex ecosystems and formats                            | Tool acquisition/versioning and host capabilities affect repeatability              |
| Update package repositories through Git commits and tags                               | Produces reviewable history and fits tap/bucket/community workflows             | Repository conflicts, branch policy, and PR review are remote concerns              |
| Offer both templates and Java extensions                                               | Simple branding tweaks stay local; deeper behavior remains extensible           | Two customization models and JVM coupling increase maintenance cost                 |
| Delegate update execution to package managers                                          | Reuses trusted client databases and normal user workflows                       | No common channel, delta, rollback, or in-app update API                            |
| Make the implementation fully Apache-2.0 OSS                                           | Low adoption friction and auditable release mechanics                           | Sustainability relies on community and sponsorship rather than paid product support |

## Sources

- [JReleaser repository at reviewed SHA][reviewed-tree]
- [`README.adoc` — purpose, version, supported project types, install/docs links][readme]
- [`LICENSE` — Apache License 2.0][license]
- [`jreleaser.yml` — the project releasing itself across assemblers and packagers][self-config]
- [`Workflows.java` — exact stage composition][workflows]
- [`JReleaserSupport.java` — built-in backend registries][support]
- [`DistributionProcessor.java` — per-distribution/packager stage mechanics][distribution-processor]
- [`AbstractPackagerProcessor.java` and repository/template specializations][abstract-packager]
- [`JReleaserContext.java` — output directory layout][context-dirs]
- [`Signer.java`, `AbstractSigner.java`, and signing tests][signer]
- [`Checksum.java` and SBOM processors][checksum]
- [`DefaultExtensionManager.java` — extension loading][extension-manager]
- [`release.yml` — upstream CI, release action, credentials, and SLSA composition][release-workflow]
- [Official JReleaser guide][guide]

<!-- References -->

[repo]: https://github.com/jreleaser/jreleaser
[guide]: https://jreleaser.org/guide/latest/
[reviewed-tree]: https://github.com/jreleaser/jreleaser/tree/98de563b61df6232d38dafafa8d1f1728432c207
[readme]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/README.adoc
[license]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/LICENSE
[banner]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/plugins/jreleaser/src/main/resources/org/jreleaser/cli/Banner.properties
[self-config]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/jreleaser.yml
[workflows]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/workflow/Workflows.java
[workflow-impl]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/workflow/WorkflowImpl.java
[workflow-item]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/workflow/AbstractWorkflowItem.java
[support]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-model-impl/src/main/java/org/jreleaser/model/internal/JReleaserSupport.java
[artifact-api]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/api/jreleaser-model-api/src/main/java/org/jreleaser/model/api/common/Artifact.java
[artifact-impl]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-model-impl/src/main/java/org/jreleaser/model/internal/common/Artifact.java
[project-api]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/api/jreleaser-model-api/src/main/java/org/jreleaser/model/api/project/Project.java
[distribution-api]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/api/jreleaser-model-api/src/main/java/org/jreleaser/model/api/distributions/Distribution.java
[yaml-fixture]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-config-yaml/src/test/resources/jreleaser.yml
[context-dirs]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-model-impl/src/main/java/org/jreleaser/model/internal/JReleaserContext.java
[distribution-processor]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/engine/distribution/DistributionProcessor.java
[abstract-packager]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/packagers/AbstractPackagerProcessor.java
[template-packager]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/packagers/AbstractTemplatePackagerProcessor.java
[repository-packager]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/packagers/AbstractRepositoryPackagerProcessor.java
[archive-assembler]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/assemblers/ArchiveAssemblerProcessor.java
[deb-assembler]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/assemblers/DebAssemblerProcessor.java
[jpackage]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/assemblers/JpackageAssemblerProcessor.java
[docker-processor]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/packagers/DockerPackagerProcessor.java
[brew-templates]: https://github.com/jreleaser/jreleaser/tree/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-templates/src/main/resources/META-INF/jreleaser/templates/binary/brew
[scoop-template]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-templates/src/main/resources/META-INF/jreleaser/templates/binary/scoop/manifest.json.tpl
[template-registry]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-templates/src/main/resources/META-INF/jreleaser/templates.properties
[signer]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/engine/sign/Signer.java
[abstract-signer]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/engine/sign/AbstractSigner.java
[cosign-signer]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/engine/sign/CosignSigner.java
[signing-test]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-model-impl/src/test/java/org/jreleaser/model/internal/validation/signing/SigningValidatorTest.java
[releasers]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/engine/release/Releasers.java
[sdkman]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/packagers/SdkmanPackagerProcessor.java
[cli-main]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/plugins/jreleaser/src/main/java/org/jreleaser/cli/Main.java
[release-workflow]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/.github/workflows/release.yml
[checksum]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/engine/checksum/Checksum.java
[algorithm]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/api/jreleaser-utils/src/main/java/org/jreleaser/util/Algorithm.java
[cyclonedx]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/catalogers/CyclonedxSbomCatalogerProcessor.java
[model-timestamp]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-model-impl/src/main/java/org/jreleaser/model/internal/JReleaserModel.java
[extension-manager]: https://github.com/jreleaser/jreleaser/blob/98de563b61df6232d38dafafa8d1f1728432c207/core/jreleaser-engine/src/main/java/org/jreleaser/extensions/internal/DefaultExtensionManager.java
