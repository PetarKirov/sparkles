# `sparkles:packaging` — Delivery Plan

_Audience: contributors implementing the library and its optional frontend.
This document is execution-only: milestone order, concrete outputs, gates, and
deferrals. For desired behavior and open scope decisions, read
[SPEC.md](./SPEC.md); for the evidence behind the architecture, read the
[application-packaging research catalog](../../research/application-packaging/)._

The plan delivers vertical slices from one prebuilt stage tree to independently
validated artifacts. Each milestone builds and tests green before the next one
starts. Format count is not a progress metric: a format ships only with its
identity, determinism, validation, and lifecycle contract.

Milestones M0–M2 are the packaging-framework-free portable floor. M3–M5 add
one useful native path per platform. M6 hardens extensibility and supply-chain
handoff without turning the package into a release publisher.

## 1. Milestone overview

| #      | Deliverable                                                                | Depends on | Decision gate |
| ------ | -------------------------------------------------------------------------- | ---------- | ------------- |
| **M0** | Close the remaining release/product contract and executable proof fixtures | —          | D3, D5, D6    |
| **M1** | Core model, JSON CLI, stage tree, capability, plan, and receipt            | M0         | —             |
| **M2** | Deterministic TAR/ZIP/gzip encoders and three-host portable-archive proof  | M1         | D5            |
| **M3** | Built-in Debian `.deb` vertical slice                                      | M2         | D3            |
| **M4** | macOS `.app`, signing/notarization/stapling, ZIP/DMG vertical slice        | M2         | —             |
| **M5** | Windows portable/signing plus Inno Setup vertical slice                    | M2         | —             |
| **M6** | Optional backend seam, reproducibility evidence, docs, and release handoff | M3–M5      | D6            |

M3, M4, and M5 can proceed independently after M2. Their order in this document
does not claim that Linux is more important; available native hosts and the
product selected by D3 determine scheduling.

## 2. Cross-cutting invariants

Every milestone preserves these rules:

- input is an already-built payload; packaging never recompiles it;
- planning precedes mutation and dry-run remains side-effect free;
- logical paths are validated before touching a host path;
- all process calls use argument vectors and an explicit environment;
- unsigned deterministic bytes are tested independently of signing;
- every byte-mutating operation precedes the final digest;
- native-host limitations and missing tools are capability results, not hidden
  fallbacks;
- no tool or SDK is downloaded implicitly;
- no secret value enters plans, receipts, logs, test snapshots, or errors;
- each built-in codec has both pure unit coverage and an independent reader;
- each public function has a named, explicitly attributed unittest outside
  `package.d`;
- changes follow the repository's preview flags, DDoc, functional style, and
  test-runner conventions.

## 3. M0 — Contract closure and proof fixtures

M0 closes the remaining open decisions in SPEC §13 and turns the resolved
choices into a small testable release contract. It writes no production
package code.

### Outputs

- Resolve D3, D5, and D6 with the product owner and update SPEC/PLAN.
- Define the real payload fixtures in the resolved order:
  - `apps/ci` and `apps/release`, each with its executable plus shipped
    license/readme/support files;
  - `apps/terminal` with its executable, native libraries, resources, and
    desktop metadata.
- For each selected product, record stable names/IDs, SemVer mapping, supported
  target triples, full commit revision, optional native build-number source,
  minimum runtime claims, entry point, installation scope, signing owner,
  update owner, and user-data policy.
- Check in reviewed logical stage-tree manifests for the fixtures, independent
  of Nix/Dub output paths.
- Record the native-host CI matrix and which optional validators are expected on
  Linux, Windows, and macOS.
- Write golden artifact naming examples and failure examples.

### Gate

- No required identity, version mapping, credential owner, or lifecycle policy
  is ambiguous.
- Each requested format has a named product/channel reason.
- The fixtures can be built before packaging begins and smoke-run outside their
  build directories.
- The SPEC contains no “automatic” fallback that would change identity or final
  bytes based on the host.

## 4. M1 — Model, JSON CLI, stage tree, plan, and receipt

M1 creates `libs/packaging` and implements the format-neutral core. The only
artifact is a materialized inspection stage and its receipt; no archive encoder
is needed to prove the architecture.

### Package foundation

- Add `libs/packaging/dub.sdl` and the root `subPackage` entry.
- Depend directly only on the approved in-tree libraries and `expected`; record
  the resolved DUB graph to enforce the dependency envelope.
- Integrate `sparkles:test-runner` through the default fast path unless the
  actual dependency graph demonstrates a cycle.
- Add package and feature modules from SPEC §3 as they become non-empty.

### Core model

- Implement product/format identity and target/host types.
- Implement source SemVer, full commit revision, optional native build number,
  and named version-mapping results without converting hashes to numbers.
- Implement normalized logical paths and target-equivalence collision checks.
- Implement regular-file, directory, and symlink entries with filesystem,
  bytes, and generated sources.
- Implement stage validation, normalized ordering, metadata defaults, input
  fingerprints, and safe workspace materialization.
- Implement structured `PackagingError` codes and `Expected` aliases.

### Planning and evidence

- Implement capability keys/results and a fakeable probe boundary.
- Implement plan operations and dependency validation.
- Implement side-effect-free human and canonical JSON plan rendering.
- Implement execution workspaces, atomic output installation, and failure
  cleanup.
- Implement SHA-256 stage inventory and the schema-versioned canonical JSON
  receipt without introducing a JSON dependency.
- Add `apps/packaging` with the `sparkles-package` executable and strict,
  versioned JSON request decoder.
- Implement `validate`, `plan`, `capabilities`, and stage-only `build` behavior;
  M2 extends `build` with portable archives.
- Resolve relative input paths against the request document and keep secret
  values out of the schema.

### Gate

- `dub test :packaging` passes with the test runner reporting non-zero tests.
- Malicious path, duplicate, prefix-conflict, case-collision, symlink-escape,
  changed-input, and output-conflict matrices are covered.
- Filesystem traversal tests prove plan-owned cleanup cannot escape its
  workspace.
- Two materializations from the same request have identical inventories and
  metadata.
- Dry-run causes zero writes and zero fake-process invocations.
- CLI JSON rejects missing schema versions, unknown fields, malformed commit
  hashes/native versions, inline secrets, and current-directory-dependent
  relative paths.
- Receipt JSON round-trips through `std.json` and a second JSON implementation
  in CI or a small external fixture validator.

## 5. M2 — Deterministic portable archives

M2 delivers the first end-user artifacts: portable archives produced entirely
by Sparkles code plus the approved runtime compression floor.

### TAR/PAX

- Implement checked numeric/header encoding, padding, checksums, paths, links,
  modes, IDs, and deterministic PAX extended records.
- Stream regular-file content; reject a source that changes size/digest during
  encoding.
- Provide lower-level writer and plan-backend surfaces.
- Add gzip with normalized headers and explicit compression parameters if D5
  retains it.

### ZIP/ZIP64

- Implement local records, data/checksum handling, UTF-8 names, Unix mode bits,
  central directory, ZIP64 thresholds, and deterministic timestamps/extra
  fields.
- Define the seekable-sink and streaming/data-descriptor capabilities rather
  than buffering every artifact unconditionally.
- Make symlink representation explicit; Windows portable archives may reject
  symlinks instead of emitting entries Windows extractors mishandle.

### Portable artifact slice

- Package both M0 CLI fixtures for Linux, Windows, and macOS from
  target-specific prebuilt inputs.
- Use stable filenames derived from product, version, and target.
- Emit one final receipt per target request, covering every archive derived
  from that target's stage.
- Add extract → launch smoke tests on every declared target host.

### Gate

- Same input/identity/epoch/settings produces byte-identical unsigned TAR and
  ZIP output in two clean workspaces.
- GNU/bsdtar and at least one independent ZIP implementation list/extract the
  expected tree.
- Boundary fixtures cover empty files, long paths, Unicode, executable bits,
  ZIP32→ZIP64 thresholds through synthetic sinks, large numeric fields,
  corruption, and short/failing writers.
- Fresh-host extracted binaries launch without access to the source/build tree.
- Final receipt hashes match independent `sha256sum`/platform equivalents.
- No third-party packager process is invoked.

## 6. M3 — Debian package vertical slice

M3 proves that the archive core supports a format with package-manager
lifecycle semantics. It does not imply RPM/Arch repository support.

### Outputs

- Implement deterministic `ar`, `control.tar.*`, and `data.tar.*` composition.
- Model required Debian metadata, dependency strings, maintainer scripts,
  conffile policy, installed size, and SemVer→Debian mapping explicitly.
- Keep filesystem payload paths separate from portable-archive layouts.
- Generate metadata from the plan; accept lifecycle scripts only as reviewed
  inputs, never synthesized shell logic.
- Add `dpkg-deb` inspection and install/remove test adapters.

### Gate

- `dpkg-deb --info` and `--contents` agree with the receipt/stage inventory.
- A clean supported Debian/Ubuntu environment installs, launches, upgrades from
  the previous fixture version, and removes the package.
- Package identity remains stable across the upgrade and user-data behavior
  matches M0 policy.
- Rebuilding the same unsigned `.deb` is byte-identical.
- Invalid dependency fields, unsafe scripts/paths, ownership/mode overflow, and
  unsupported compression fail during planning.

RPM, Arch packages, APT/RPM repositories, repository signing, and dependency
auto-discovery remain deferred.

## 7. M4 — macOS application vertical slice

M4 runs on a native macOS host and proves the trust-critical Apple sequence.
The built-in work is bundle assembly; Apple tools remain explicit capabilities.

### Outputs

- Implement `.app` layout validation and deterministic `Info.plist` generation.
- Model bundle ID, short/bundle versions, minimum OS, category, executable,
  icons/resources, entitlements, and nested signable code.
- Implement inside-out `codesign`, verification, notarization submission/status,
  stapling, Gatekeeper assessment, ZIP, and `hdiutil` DMG operations.
- Make each operation independently visible in the plan and receipt.
- Support an unsigned local-development path without representing it as a
  distributable trusted artifact.

### Gate

- Unsigned `.app` stages are deterministic before signing.
- A signed application verifies with the native signing tools and launches on
  the minimum declared macOS host.
- A release ZIP and DMG pass notarization, stapling, Gatekeeper assessment, and
  a quarantine/download first-launch test.
- Final hashes are calculated after signing/stapling and independently match the
  receipt.
- Missing identity, entitlements, nested-code ordering, Apple credentials, or
  native host capability fails with a specific planning/probe error.
- No credential value is observable in captured arguments, environment
  snapshots, receipts, or failing-command diagnostics.

PKG, XIP, Homebrew Cask publication, and cross-host Apple signing remain
deferred.

## 8. M5 — Windows application vertical slice

M5 first completes signed portable delivery, then adds exactly one installer
family selected by D3. It does not introduce MSI, MSIX, Inno, and NSIS together.

### Portable/signing outputs

- Finalize the Windows portable stage policy and ZIP extraction behavior.
- Implement an Authenticode signer/verifier capability with explicit timestamp
  policy and credential references.
- Record signature identity and verification, then recalculate final digests.
- Exercise ZIP extraction/launch from paths containing spaces and non-ASCII
  characters on a clean Windows host.

### Installer output

If D3 selects Inno Setup, generate a reviewable script from typed metadata,
permit an owned template for product-specific UI/actions, and invoke a
user-provisioned compiler. If product requirements instead select MSI or MSIX,
replace this slice with a separate specification revision covering that
format's identity and servicing model before coding it.

The selected installer must model installation scope, stable upgrade identity,
shortcuts/file associations, add/remove metadata, silent mode, signing order,
and user-data ownership explicitly.

### Gate

- Windows verifies signatures on every requested signable artifact.
- Clean-host portable extract → launch succeeds without the build tree.
- The selected installer passes install → launch → upgrade from previous stable
  → repair where applicable → uninstall in interactive and silent modes.
- Identity remains stable and documented user data survives or is removed per
  M0 policy.
- Filenames/metadata containing spaces, Unicode, and shell metacharacters never
  change process argument boundaries.
- Final receipt hashes match the post-signing installer/ZIP bytes.

WinGet/Scoop submission, Chocolatey, Store submission, auto-update, and every
unselected installer family remain deferred.

## 9. M6 — Backend seam, hardening, and handoff

M6 proves that optional formats and release tooling can consume the core
without growing hidden dependencies or mutating finalized artifacts.

### Extensibility

- Extract the built-in format contract into the minimal DbI capability surface
  supported by real M2–M5 backends.
- Add compile-time conformance probes and fixtures for a user-defined pure-D
  backend and a fake external-tool backend.
- Add AppImage only if D3 selected a Linux desktop fixture and its runtime/tool
  inputs can be pinned and clean-host tested; otherwise keep the capability
  adapter as the next named milestone rather than a stub.
- Document how downstream code adds a backend without a global registry or
  library fork.

### Reproducibility and supply-chain evidence

- Run two isolated unsigned builds and emit a structured match/difference
  report.
- Record compiler/runtime/tool versions and declared non-determinism.
- Provide receipt consumers for the existing `release` app or CI without adding
  upload/publish behavior to `sparkles:packaging`.
- Define, but do not fabricate, the inputs an SPDX/CycloneDX/provenance producer
  needs beyond the stage receipt.

### Documentation

- Add `docs/libs/packaging/` as a Diátaxis tree with a runnable first-package
  tutorial, format how-tos, API/schema reference, architecture/dependency
  explanation, and native-host troubleshooting.
- Add a runnable README example for the library's portable archive path with an
  `[Output]` block.
- Reconcile SPEC/PLAN against the shipped public surface and native test matrix.

### Gate

- A downstream fixture adds a backend without modifying core orchestration.
- Missing optional primitives degrade only as documented; semantic gaps never
  select a misleading fallback.
- Isolated unsigned rebuilds match or produce an explicit classified difference
  in the receipt/report.
- Existing release automation can ingest the receipt and select immutable final
  artifacts by target and digest.
- `dub test :packaging`, repository CI, markdown-example verification, and docs
  build pass on their declared hosts.
- The final DUB dependency graph satisfies SPEC §2.2.

## 10. Verification matrix

| Surface                   | Linux host | Windows host | macOS host | Independent evidence                      |
| ------------------------- | ---------- | ------------ | ---------- | ----------------------------------------- |
| Stage/model/plan          | required   | required     | required   | golden plans + malicious-path matrix      |
| TAR/PAX                   | required   | smoke        | required   | GNU/bsdtar                                |
| ZIP/ZIP64                 | required   | required     | required   | native extractor + independent ZIP reader |
| Debian `.deb`             | required   | —            | —          | `dpkg-deb`, clean Debian/Ubuntu lifecycle |
| macOS `.app`/ZIP/DMG      | —          | —            | required   | codesign/notary/stapler/Gatekeeper        |
| Windows signing/installer | —          | required     | —          | Authenticode + clean Windows lifecycle    |
| Receipt/digests           | required   | required     | required   | independent JSON parse + SHA-256 tool     |

“Smoke” means codec portability only; it does not claim target runtime or trust
verification on the wrong host. Optional-capability tests use
`skipTest(reason)` when the tool, privilege, credential, or native host is not
available. Release acceptance does not treat such a skip as evidence for the
missing capability; protected native jobs must supply it.

## 11. Explicit deferrals

These require later milestone/spec revisions:

- RPM and Arch package writers and signed APT/RPM repositories;
- Flatpak and Snap manifests/store workflows;
- MSI, MSIX, NSIS, PKG, and XIP;
- WinGet, Scoop, Chocolatey, Homebrew, and other catalog publication;
- SBOM dependency discovery and signed provenance generation;
- candidate/stable channel promotion, deltas, and embedded updating;
- remote signing services beyond the generic signer capability;
- automatic binary dependency harvesting or license classification;
- a runtime-loaded plugin ABI.

Deferral does not prevent an application from using an owned external step
after packaging. It means `sparkles:packaging` does not claim, configure, or
verify that step until its lifecycle contract is specified.
