# cargo-dist / dist (Rust and polyglot CLI applications)

An open-source release control plane that also packages application binaries into
archives and installers, then generates the GitHub Actions pipeline that hosts,
publishes, and announces them.

| Field             | Value                                                         |
| ----------------- | ------------------------------------------------------------- |
| Product name      | `dist` (repository and crate still named `cargo-dist`)        |
| Language          | Rust 2021; MSRV 1.74                                          |
| License           | MIT OR Apache-2.0                                             |
| Repository        | [`axodotdev/cargo-dist`][repo]                                |
| Documentation     | [`book/src/`][book]                                           |
| Version at review | `0.32.0`                                                      |
| Reviewed revision | [`25b2af882b1641c6ae50bc81c11ec174b8a6e1d8`][reviewed-tree]   |
| Primary role      | **Release control plane** and **application packager**        |
| Secondary role    | Updater integrator; publication and announcement orchestrator |
| Not its role      | Package-format primitive or general-purpose package manager   |
| Business model    | **OSS** core; no `dist` paid tier is required                 |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Classification:** `dist` is primarily a **control plane**: it plans a release,
> generates CI, distributes work across runners, merges machine-readable manifests,
> publishes, and announces. It is also an **app packager** because it directly emits
> archives, shell/PowerShell installers, npm wrappers, Homebrew formulae, MSI, and
> Apple `pkg` installers. It is only an **updater integrator**: the installed updater
> is the separate open-source `axoupdater` binary. It is **not a format primitive**;
> ZIP, tar, MSI, `pkg`, npm, and Homebrew remain externally defined formats.

> [!NOTE]
> The repository is wholly OSS under dual MIT/Apache-2.0 licensing. Optional external
> facilities can cost money: trusted Windows signing uses SSL.com's commercial eSigner
> service, and GitHub attestations for private repositories require an eligible GitHub
> Enterprise plan. Those are service constraints, not a paid edition of `dist`.

---

## Overview

### What it solves

Shipping a CLI is wider than compiling it. A release must select applications from a
workspace and tag, build each target on a suitable machine, stage files, produce
installers, checksum and optionally attest/sign outputs, upload them, update package
manager metadata, and publish useful release notes. `dist` turns that sequence into a
computed `DistGraph`, a portable `dist-manifest.json`, and generated CI.

The upstream summary is unusually exact about its scope ([`README.md`][readme]):

> _“dist distributes your binaries”_

The project supports Cargo workspaces directly, npm/JavaScript projects through its
project model, and arbitrary languages through a generic `dist.toml` package plus a
user-supplied `build-command`. This makes it a binary-release system rather than a
Rust package publisher: publishing source crates to crates.io remains outside its
normal release pipeline ([`book/src/custom-builds.md`][custom-builds]).

### Design philosophy

Three principles organize the implementation:

1. **Plan before executing.** `gather_work` discovers the project, selects the
   announcement, expands releases into target-specific variants, attaches artifacts,
   then computes build steps. The source calls this function the “heart and soul of
   dist” and aims to compute “every minute detail” ahead of execution
   ([`cargo-dist/src/tasks.rs`][tasks-top]).
2. **The manifest is the protocol.** `dist-manifest.json` is simultaneously a
   preview, final report, and cross-runner communication format. Each runner emits a
   partial manifest; later jobs merge releases, hosting, checksums, assets, systems,
   and linkage data ([`cargo-dist/src/manifest.rs`][manifest-merge]).
3. **Generated CI should remain locally understandable.** A build job mostly installs
   `dist`, invokes it once, and uploads paths reported by the manifest. Local and CI
   builds are not promised bit-identical, but are intended to reproduce the same
   release structure without a container-only build language
   ([`book/src/introduction.md`][introduction]).

---

## How it works

A representative configuration is compact:

```toml
[dist]
cargo-dist-version = "0.32.0"
ci = ["github"]
installers = ["shell", "powershell", "homebrew", "npm", "msi", "pkg"]
targets = [
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
    "x86_64-pc-windows-msvc",
]
checksum = "sha256"

[profile.dist]
inherits = "release"
lto = "thin"
```

`dist init` owns setup and migrations. `dist plan --tag=v1.2.3` computes the complete
release without building it; `dist build` executes selected local/global steps; and
the generated workflow coordinates host, publish, and announce phases. The exact
configuration hierarchy was still migrating from Cargo metadata to Config 1.0 at the
reviewed revision, so both older `[workspace.metadata.dist]`/`[package.metadata.dist]`
and newer `dist-workspace.toml`/`dist.toml` forms occur in the documentation and tests
([`book/src/reference/config.md`][config-reference]).

### Input and staging

`dist` combines four selectors:

- **Project topology and package metadata:** Cargo metadata, npm metadata, or explicit
  generic-package fields (`name`, `version`, `repository`, `binaries`, and
  `build-command`). Cargo packages with binaries are applications by default;
  `publish = false`, `dist = false/true`, or an explicit package allow-list adjusts
  selection ([`book/src/reference/concepts.md`][concepts]).
- **Release configuration:** targets, build profile/features, installers, dependencies,
  hosting, publishers, CI jobs/runners, checksums, signing, and supply-chain helpers.
  Workspace settings layer into app settings in the Config 1.0 model.
- **Announcement tag:** unified tags select same-version apps; package-qualified tags
  select one app. All apps in one announcement must agree on a version. One tag maps
  to one announcement and normally one GitHub Release ([`concepts`][concepts]).
- **Artifact mode:** `local` chooses per-target work; `global` chooses platform-neutral
  installers; `all` plans both; `host` is a deliberately fuzzy local-test mode. An
  explicit `--target` narrows local work.

The planner creates an announcement → releases → release variants → binaries/artifacts
hierarchy. It then reduces this graph to concrete `BuildStep` values such as Cargo or
generic build, copy, archive, installer generation, checksum, source tarball, OmniBOR,
and updater fetch ([`cargo-dist/src/lib.rs`][build-dispatch]). Staging occurs below the
configured distribution directory (normally `target/distrib`): old artifact paths are
removed, archive assembly directories are recreated, binaries and selected static
files are copied, and the chosen compressor writes the final file.

Planning is not a shallow dry run. `check_integrity` verifies generated CI/MSI material
before `build` or `manifest`; `do_env_test` verifies required tools; and `dist plan`
resolves the release graph and output names without executing builds. The planner uses
sorted sets while selecting configured target triples, giving stable target ordering
([`cargo-dist/src/tasks.rs`][target-selection]).

### Outputs and targets

The baseline output is one prebuilt archive per application/target. Archives place
executables at their root, optionally include C dynamic/static libraries, and
auto-include detected README, license, and changelog files. The default is ZIP on
Windows and `tar.xz` elsewhere; ZIP and gzip/xz/zstd tar variants are configurable
([`book/src/artifacts/archives.md`][archives]).

The implementation's installer enum is the authoritative current list
([`cargo-dist/src/config/mod.rs`][installer-enum]):

| Output            | Scope           | Mechanism                                                                              |
| ----------------- | --------------- | -------------------------------------------------------------------------------------- |
| Shell script      | Global/fetching | Detects OS/CPU, downloads an archive, installs files, adjusts shell path               |
| PowerShell script | Global/fetching | Equivalent Windows-oriented fetch/install flow and registry `PATH` handling            |
| npm package       | Global/fetching | Publishes a JavaScript launcher package that selects/downloads the native archive      |
| Homebrew formula  | Global/fetching | Formula contains per-platform URLs and SHA-256 values                                  |
| MSI               | Local/bundled   | WiX v3 installer embeds Windows binaries and participates in Windows upgrade/uninstall |
| Apple `pkg`       | Local/bundled   | Native macOS package assembled with `pkgbuild`/`productbuild`                          |

The reviewed source knows seven desktop triples (x86-64 and ARM64 GNU Linux, x86-64
musl Linux, x86-64 and ARM64 macOS, and x86-64 and ARM64 MSVC Windows); its default set
omits musl and ARM64 Windows. Arbitrary configured Rust triples can be represented, but
runner mapping, cross-compilers, installer templates, and updater binaries determine
what is practical. GitHub runner mapping supports native jobs and selected
`cargo-zigbuild`/`cargo-xwin` paths; custom runners and containers cover the rest
([`cargo-dist/src/backend/ci/github.rs`][github-ci]).

Additional artifacts include per-file and unified checksums, symbols, source tarballs,
`dist-manifest.json`, linkage reports, optional CycloneDX SBOMs, embedded
`cargo-auditable` metadata, and OmniBOR artifact IDs. Extra artifact build commands
provide an escape hatch for outputs the native graph does not model.

### Metadata and dependencies

`cargo-dist-schema` defines a versioned, forward/backward-tolerant manifest. Its
`DistManifest` records the generator version, announcement/tag/changelog, releases,
artifact map, systems, assets, publish/latest policy, CI matrix, dynamic linkage,
upload files, and attestation policy ([`cargo-dist-schema/src/lib.rs`][manifest-schema]).
Most fields default or remain optional so an older self-hosting `dist` can exchange
manifests with a newer release.

The manifest is operational state, not only catalog metadata:

1. The plan job emits hosting and the full expected graph.
2. native build jobs emit their produced assets, checksums, system identity, and
   linkage;
3. global work imports those partial manifests so fetching installers can bake the
   final archive URLs/checksums into templates;
4. host/announce jobs merge the results and publish the final manifest.

Package metadata supplies name, version, authors/manufacturer, repository, homepage,
documentation, changelog, readme, license/license files, binaries, `cdylib`/`cstaticlib`
outputs, and custom commands. Dependency configuration is stage- and target-aware:
APT, Homebrew, Chocolatey, and generic setup commands can install build dependencies
on the runner. The generated GitHub matrix collects only dependencies wanted for a
runner's targets, then adds cross-build tools where needed
([`cargo-dist/src/backend/ci/github.rs`][github-dependencies]). Runtime dependency
knowledge is shallower: linkage inspection reports dynamic libraries and their likely
provider, while Homebrew dependencies can be rendered into formulae; `dist` is not a
system dependency solver.

### Install, upgrade, and uninstall

Fetching installers choose a compatible archive using the baked platform matrix,
download and unpack it, install binaries/libraries/aliases, optionally modify `PATH`,
and write a receipt. Install location can be configured by the producer and overridden
by app-specific environment variables. End users can also override GitHub/GitHub
Enterprise bases, the complete download URL, bearer token, proxies, quiet/verbose
mode, and unmanaged CI mode ([`book/src/installers/usage.md`][installer-usage]).

Receipts record enough installation context for `axoupdater`; unmanaged mode suppresses
both receipts and updater tooling, avoids `PATH` edits, and uses a flat destination.
Repeated script installation effectively replaces files, but shell and PowerShell
installers do **not** expose a first-class uninstall command. Uninstall semantics come
from the surrounding format:

- MSI persists stable upgrade/path GUIDs, rejects downgrade, uninstalls the previous
  version during upgrade, and registers with Windows “Add or remove programs”
  ([`book/src/installers/msi.md`][msi]);
- Homebrew and npm delegate upgrade/uninstall to their package managers;
- Apple `pkg` uses platform installation receipts but has no `dist`-generated friendly
  uninstaller;
- raw archives require manual file removal.

The release project's own configuration is upgraded separately: install a newer
`dist`, rerun `dist init`, review prompts, and commit regenerated config/workflow/MSI
files. Other commands reject materially stale generated files unless the user opts
into `allow-dirty` ownership ([`book/src/updating.md`][updating]).

### Signing and trust

Trust is layered, and the layers should not be conflated:

- **Transport/integrity:** HTTPS plus default SHA-256 archive checksums; algorithms also
  include SHA-512, SHA3-256/512, and BLAKE2s/b. A unified `<algorithm>.sum` is emitted.
  Unsigned hashes catch corruption but do not establish publisher identity. Homebrew
  always embeds SHA-256. Fetching-installer checksum coverage has historically been
  incomplete, so consumers must not assume every path verifies an adjacent checksum
  ([`book/src/artifacts/checksums.md`][checksums]).
- **Windows platform identity:** optional SSL.com eSigner cloud signing signs EXEs and
  MSIs so SmartScreen can establish a certificate-backed publisher. It requires paid
  certificate/service credentials stored as GitHub secrets and is vendor-specific
  ([`book/src/supplychain-security/signing/windows.md`][windows-signing]).
- **Build provenance:** optional GitHub Artifact Attestations use GitHub's attestation
  action and OIDC permissions. Phase and glob filters select whether local, host, or
  announce outputs are attested; release notes tell consumers to use
  `gh attestation verify` ([`book/src/supplychain-security/attestations/github.md`][attestations]).
- **Software inventory/identity:** CycloneDX, `cargo-auditable`, and OmniBOR are optional
  and require extra tools. They describe components or identify content; they do not
  replace code signatures ([`book/src/supplychain-security/index.md`][supply-chain]).

macOS code signing/notarization and general Linux/Sigstore artifact signing were not
implemented in the reviewed documentation. This leaves a major trust gap for native
macOS `pkg` distribution and non-GitHub Linux verification.

### Publication and discovery

GitHub Releases is the only natively operated hosting backend. The generated workflow
creates/updates a release, uploads artifacts, attaches `dist-manifest.json`, composes a
release body with install hints and artifact/checksum tables, then announces the
release. A `simple` host can contribute templated download URLs, but source code calls
it “currently download-only”; `dist` does not upload to that server
([`cargo-dist/src/host.rs`][hosting]). Multiple configured hosts can be ordered for
installer fallback.

Native publishers are intentionally narrower than installers: Homebrew updates a tap
repository, and npm publishes the wrapper package. User-defined publish jobs extend the
pipeline to other registries. crates.io publication, OS distribution repositories,
Winget, Flatpak, container registries, and PyPI are not built-in publishers at this
revision ([`cargo-dist/src/config/mod.rs`][publisher-enum]).

Discovery therefore happens through GitHub release pages/API and stable artifact URLs,
Homebrew taps, npm search/package names, and websites such as the separate OSS `oranda`
tool that consume release metadata. `dist-manifest.json` is a useful discovery API for
tools, but not a federated catalog or repository index.

### Updates and channels

`install-updater = true` makes shell/PowerShell installers include a target-specific
prebuilt `axoupdater` renamed to `<app>-update`. `dist` fetches a known compatible
`axoupdater` release by default, or its latest release when explicitly configured,
and fails when no updater binary exists for the target
([`cargo-dist/src/lib.rs`][updater-fetch]). At runtime the receipt directs the updater
to the original install location, and GitHub Releases supplies release discovery.
Applications may instead embed `axoupdater` as a library; `dist` rejects dependency
versions below its safety floor.

Channel support is minimal. SemVer prereleases are recognized, package-manager
publication of prereleases is separately gated, and `force-latest` can override latest
selection. There are no named stable/beta/nightly channels, cohorts, staged rollout,
delta updates, rollback, or background policy engine. Homebrew/npm users update through
the package manager; archive users update manually; script users get only the optional
explicit updater command ([`book/src/installers/updater.md`][updater-doc]).

### Automation and CI

`dist init` generates `.github/workflows/release.yml`; GitHub Actions is the sole
first-class CI backend. The pipeline is a manifest-driven DAG:

1. **plan/host-create** selects the tag and emits the matrix;
2. **build-local-artifacts** runs target groups on appropriate runners;
3. **build-global-artifacts** creates universal/fetching installers;
4. **host** merges manifests, creates/uploads the GitHub release, and makes hosted URLs
   available;
5. **publish** updates Homebrew/npm and runs custom jobs;
6. **announce** finalizes release contents and runs post-announce hooks.

Local target jobs are independently parallelizable, while one global Linux job stitches
manifests. Within one `dist build`, build steps execute sequentially—local first, then
global—because concurrent Cargo invocations with different feature sets can clobber
shared output paths ([`cargo-dist/src/lib.rs`][build-order]).

Customization includes target→runner mappings, containers, build setup fragments,
system dependencies, merged/split target jobs, caching, fail-fast, pull-request plan or
artifact builds, manual dispatch, permission maps, and custom jobs at every phase.
Generated files are checked for drift. Snapshot-heavy integration tests exercise the
manifest and generated workflow together, including all six installers, alternate
hashes, simple/GitHub host order, updater assets, signing, and attestation phases
([`cargo-dist/tests/integration-tests.rs`][integration-tests]).

### Supply chain and reproducibility

`dist` improves repeatability but does not claim reproducible builds:

- `cargo-dist-version` pins the generator used in CI, and `dist` rejects a mismatched
  local version; `Cargo.lock`, an optional Rust toolchain file, locked npm wrapper
  dependencies, and configurable action commit pins can constrain inputs.
- the plan fixes application versions, targets, artifacts, URLs, and commands before
  runners execute; stable ordering and the merged manifest make discrepancies visible;
- generated workflows can pin every action by full commit SHA; the project's own
  `release.yml` does so ([`.github/workflows/release.yml`][self-release-workflow]);
- checksums, attestations, SBOMs, auditable dependency metadata, OmniBOR IDs, system
  build information, and linkage reports improve post-build inspection.

The remaining gaps are material: default GitHub Action references may use floating tags
unless commit overrides are configured; toolchains and runner images can float; generic
commands are arbitrary; archive metadata/compressor behavior is not normalized for
bit-for-bit determinism; package downloads and the fetched updater are not described by
a single hermetic lock; and builds run on mutable hosted machines rather than a
sandboxed content-addressed environment. The project's own self-hosting pipeline also
uses a previous `dist` release to build the next one, intentionally relying on optional
schema fields for compatibility ([`README.md`][self-hosting]).

### Extensibility and UX

The strongest extension seam is orchestration rather than a stable library API:

- arbitrary `build-command` and extra-artifact commands support non-Rust projects;
- custom setup and phase jobs integrate external builders, publishers, scanners, and
  deployment systems;
- custom runners/containers and target mappings adapt the generated matrix;
- simple download URLs and user publish jobs extend hosting/publishing edges;
- `allow-dirty` lets experts take ownership of generated CI or WiX files.

The Rust library explicitly says it is internal, writes freely to stdout/stderr, and is
not well suited as a reusable pure library ([`cargo-dist/src/lib.rs`][library-status]).
Installer kinds and hosting providers are closed Rust enums rather than runtime plugins,
so adding a truly native format requires upstream code. Template customization is
therefore less composable than hook-based packaging frameworks.

UX is opinionated and preventative: interactive `dist init` can be rerun to migrate
configuration; `plan` previews an exact release; generated-file drift blocks releases;
PR mode catches release failures early; human and JSON output serve operators and CI;
and release notes include ready-to-copy install commands. The cost is a large
configuration surface, terminology (`announcement`, `release`, `variant`, local/global
artifact), migration-era duplicate config forms, and strong GitHub assumptions.

---

## Strengths

- **End-to-end release graph:** one plan connects workspace selection, native builds,
  installers, metadata, hosting, publishing, and announcement.
- **Manifest-mediated fan-out/fan-in:** cross-platform jobs remain independent while a
  typed, mergeable protocol preserves a coherent release.
- **Useful application packaging:** six installer families cover common CLI delivery
  paths, not just raw archives.
- **Local-first diagnostics:** `plan`, host-mode builds, integrity checks, and PR plans
  expose release mistakes before a tag is pushed.
- **Polyglot escape hatches:** generic projects, custom commands, extra artifacts,
  custom jobs, runners, and publishers avoid a Rust-only dead end.
- **Layered supply-chain options:** checksums, signing, attestations, SBOMs, embedded
  dependencies, linkage, and OmniBOR can be enabled independently.
- **No required commercial control service:** the orchestration logic and generated
  workflow are inspectable OSS committed to the application repository.

## Weaknesses

- **GitHub-centric control plane:** only GitHub Actions and GitHub Releases are fully
  operated; simple hosting is download-only and other CI systems are not generated.
- **Incomplete lifecycle:** shell/PowerShell installs lack first-class uninstall and
  rollback; updater channels, cohorts, deltas, and background policy are absent.
- **Trust gaps:** trusted signing is Windows/SSL.com-specific; macOS signing/notarization
  and general Linux signing are absent; unsigned checksums are not authenticity.
- **Not hermetic or bit-reproducible:** mutable runners, tools, tags, timestamps, and
  arbitrary commands remain outside a content-addressed build model.
- **Closed native extension points:** adding an installer/host requires Rust changes;
  the core crate is not a supported embeddable API.
- **Format/runtime prerequisites:** WiX v3, Apple packaging tools, package-manager
  credentials, signing services, and target-specific updater availability complicate
  ostensibly uniform releases.
- **Migration and conceptual load:** Config 1.0 coexistence and local/global/host/all
  modes make advanced debugging demanding.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                              | Trade-off                                                                                 |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Compute a complete `DistGraph` before execution                  | Validate selection and make CI generation deterministic at the release-structure level | Planner must understand every native artifact and becomes complex                         |
| Use `dist-manifest.json` as preview, report, and runner protocol | One schema connects local UX, CI fan-out, installers, hosting, and downstream tools    | Optional compatibility fields weaken strictness; merge semantics require care             |
| Separate local and global artifacts                              | Build native outputs where toolchains exist while producing universal installers once  | Two-phase staging and manifest stitching are harder than one monolithic build             |
| Generate and own `release.yml`                                   | Users receive a complete pipeline and upgrades can migrate it                          | Hand edits fight regeneration; GitHub Actions becomes an architectural dependency         |
| Treat archives as canonical payloads                             | Every fetching installer can deliver the same binary bytes                             | Package-manager-native builds/policies are bypassed; archive hosting must remain stable   |
| Support both fetching and bundling installers                    | Fetchers are small/universal; bundles work offline and integrate with OS lifecycle     | Different security, upgrade, and target semantics prevent a single uniform model          |
| Delegate updates to `axoupdater` and receipts                    | Reuse a focused OSS updater without embedding update policy in every app               | Extra downloaded artifact, GitHub-centric discovery, limited channels and targets         |
| Pin the `dist` version in project config                         | Generated CI and schema behavior remain reviewable and repeatable                      | Upgrades require explicit local install, `dist init`, review, and regeneration            |
| Make GitHub the native host and allow simple URL fallback        | GitHub supplies tags, CI, secrets, releases, and an API in one place                   | Other hosts cannot be uploaded to natively; private/mirrored deployments need custom work |
| Offer optional rather than mandatory security features           | Projects can choose cost/complexity appropriate to their threat model                  | Default releases may have hashes but no publisher signature, provenance, or SBOM          |
| Permit custom commands/jobs but keep native kinds closed         | Cover polyglot and unusual pipelines without designing a plugin ABI                    | Extensions are less typed and integrated; native new formats still require upstream code  |

---

## Sources

- [`axodotdev/cargo-dist` repository at reviewed SHA][reviewed-tree]
- [`README.md` — positioning, pipeline, and self-hosting][readme]
- [`book/src/reference/concepts.md` — inputs, announcements, artifact modes][concepts]
- [`cargo-dist/src/tasks.rs` — graph construction and target selection][tasks-top]
- [`cargo-dist/src/manifest.rs` — manifest roles and cross-runner merge][manifest-merge]
- [`cargo-dist/src/lib.rs` — build-step dispatch, checksums, updater fetch][build-dispatch]
- [`cargo-dist/src/config/mod.rs` — installer, hosting, and publisher enums][installer-enum]
- [`cargo-dist-schema/src/lib.rs` — serialized release protocol][manifest-schema]
- [`cargo-dist/src/backend/ci/github.rs` — matrix and dependency computation][github-ci]
- [`cargo-dist/src/host.rs` — GitHub/simple hosting behavior][hosting]
- [`cargo-dist/tests/integration-tests.rs` — source-driven integration gallery][integration-tests]
- [`book/src/supplychain-security/` — signing, attestations, SBOMs][supply-chain]

<!-- References -->

[repo]: https://github.com/axodotdev/cargo-dist
[reviewed-tree]: https://github.com/axodotdev/cargo-dist/tree/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8
[book]: https://github.com/axodotdev/cargo-dist/tree/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src
[readme]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/README.md
[self-hosting]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/README.md#cutting-releases
[introduction]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/introduction.md
[custom-builds]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/custom-builds.md
[concepts]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/reference/concepts.md
[config-reference]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/reference/config.md
[archives]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/artifacts/archives.md
[installer-usage]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/installers/usage.md
[msi]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/installers/msi.md
[updating]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/updating.md
[checksums]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/artifacts/checksums.md
[windows-signing]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/supplychain-security/signing/windows.md
[attestations]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/supplychain-security/attestations/github.md
[supply-chain]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/supplychain-security/index.md
[updater-doc]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/book/src/installers/updater.md
[tasks-top]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/tasks.rs#L1-L60
[target-selection]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/tasks.rs#L3123-L3185
[build-dispatch]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/lib.rs#L142-L269
[build-order]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/lib.rs#L142-L185
[updater-fetch]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/lib.rs#L272-L369
[library-status]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/lib.rs#L9-L17
[manifest-merge]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/manifest.rs#L1-L180
[installer-enum]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/config/mod.rs#L174-L203
[publisher-enum]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/config/mod.rs#L266-L290
[manifest-schema]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist-schema/src/lib.rs#L147-L239
[github-ci]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/backend/ci/github.rs#L264-L352
[github-dependencies]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/backend/ci/github.rs#L745-L896
[hosting]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/src/host.rs#L19-L184
[integration-tests]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/cargo-dist/tests/integration-tests.rs
[self-release-workflow]: https://github.com/axodotdev/cargo-dist/blob/25b2af882b1641c6ae50bc81c11ec174b8a6e1d8/.github/workflows/release.yml
