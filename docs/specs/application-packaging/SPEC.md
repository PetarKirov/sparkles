# `sparkles:packaging` — Specification

_Audience: developers and coding agents building against the library and its
optional command-line frontend. This document is the desired-state contract.
Decisions still requiring product input are explicitly marked **Open** rather
than silently fixed. For delivery order, see [PLAN.md](./PLAN.md); for evidence,
terminology, and prior art, see the
[application-packaging research catalog](../../research/application-packaging/)._

## 1. Overview

`sparkles:packaging` turns an already-built application payload into
inspectable, deterministic release artifacts. One model describes product
identity, target identity, a logical stage tree, and requested artifact
formats. The library validates that model, produces an execution plan, and
then executes the plan with either built-in D encoders or explicit
host-tool capabilities.

The stable seam is the **stage tree**, not a build system and not a particular
package format:

```text
prebuilt inputs + identity + target
                │
                ▼
        validated stage tree
                │
                ▼
         inspectable package plan
                │
                ▼
   archive / bundle / native package
                │
                ▼
      sign / notarize / verify hooks
                │
                ▼
 final digest + target artifact receipt
```

The first useful release must package a prebuilt CLI for Linux, Windows, and
macOS without requiring a third-party packaging framework. Platform-native
formats whose trust or container policy is owned by an operating-system vendor
use that vendor's tools through a capability boundary. Formats such as
AppImage and Inno Setup may use user-provisioned tools through the same
boundary; the library never downloads them implicitly.

“Cross-platform” means that the model, planning API, built-in archive encoders,
and diagnostics are portable. It does **not** promise that every target format
can be finalized on every host. Host restrictions are reported before
execution (§8).

## 2. Scope and dependency envelope

### 2.1 Committed scope

The package owns:

- product, target, version-mapping, stage-tree, artifact, and capability models;
- safe construction and validation of logical package paths;
- deterministic stage materialization and archive encoding;
- an inspectable plan with a read-only dry-run mode;
- built-in portable TAR and ZIP artifacts;
- a built-in Debian package writer after the archive core is stable;
- macOS `.app` layout assembly and adapters for Apple signing, notarization,
  stapling, verification, and DMG creation;
- Windows portable ZIP assembly and an Authenticode adapter;
- optional adapters for selected external packagers, beginning only after a
  concrete product format has been chosen;
- final SHA-256 digests and a versioned machine-readable artifact receipt;
- deterministic/reproducibility checks and format-native validation hooks.

The input is a prebuilt payload. The packager may arrange, transform metadata
for, sign, or containerize that payload, but it does not compile application
source.

### 2.2 Dependency policy

The baseline library uses Phobos, in-tree Sparkles libraries (initially
`sparkles:base` and `sparkles:versions`), and exactly one approved third-party
DUB package: the small `expected` result type already shared by those
libraries. `sparkles:packaging` declares `expected` directly if its public
result types import it; it does not rely accidentally on a transitive import.
This is the known exception to literal zero third-party dependencies. Packaging
must not widen that external dependency set without a recorded specification
change.

The following are not library dependencies:

- operating-system SDK tools already required for native signing or container
  creation, such as `codesign`, `notarytool`, `stapler`, `hdiutil`, and
  `signtool`;
- optional, user-provisioned format tools such as `xz`, `appimagetool`, or an
  installer compiler;
- native validators used only in verification jobs.

The core never downloads, installs, or upgrades any of these tools. A frontend
may explain how to satisfy a missing capability, but execution fails closed
until the caller supplies it.

### 2.3 Non-goals

The first release is not:

- a compiler or replacement for Dub, Nix, or a CI build matrix;
- a release publisher, package repository, app store client, or GitHub client;
- an automatic updater or delta-update framework;
- a universal abstraction that erases format-native metadata or lifecycle
  semantics;
- a guarantee of cross-host Apple or Windows signing;
- an SBOM scanner capable of discovering every dependency from arbitrary
  binaries;
- simultaneous support for every Linux, Windows, and macOS package format;
- a secrets store or signing-key custody system.

Publication, catalog generation, candidate/stable promotion, and updater feeds
consume finalized artifact receipts in later tools; they are not execution
steps in this package.

## 3. Package and module layout

| Identifier      | Value                                    |
| --------------- | ---------------------------------------- |
| Dub sub-package | `sparkles:packaging`                     |
| Source root     | `libs/packaging/src/sparkles/packaging/` |
| Package module  | `sparkles.packaging`                     |
| Default target  | library                                  |

The initial module boundary is:

| Module                                | Contents                                                       |
| ------------------------------------- | -------------------------------------------------------------- |
| `sparkles.packaging`                  | Public re-exports only                                         |
| `sparkles.packaging.identity`         | Product identity and format-specific identity overrides        |
| `sparkles.packaging.target`           | Target/host triples and target path policy                     |
| `sparkles.packaging.stage`            | Logical stage tree, entries, sources, metadata, validation     |
| `sparkles.packaging.plan`             | Plan graph, validation, capability requirements, dry-run model |
| `sparkles.packaging.execute`          | Workspace, atomic output, and plan execution                   |
| `sparkles.packaging.capability`       | Capability probes and structured unavailability reasons        |
| `sparkles.packaging.receipt`          | Artifact inventory, canonical JSON, SHA-256                    |
| `sparkles.packaging.formats.tar`      | TAR/PAX encoder                                                |
| `sparkles.packaging.formats.zip`      | ZIP encoder                                                    |
| `sparkles.packaging.formats.deb`      | Debian binary-package encoder                                  |
| `sparkles.packaging.platform.macos`   | `.app` layout and Apple native-tool adapters                   |
| `sparkles.packaging.platform.windows` | Windows layout and Authenticode adapter                        |
| `sparkles.packaging.tools`            | Argument-vector process runner and external-tool provenance    |
| `sparkles.packaging.testing`          | Test-only stage, byte, fixture, and determinism helpers        |

Modules are added when their milestone starts; the table is an ownership map,
not a requirement to create empty files.

### 3.1 JSON command-line frontend

The library ships with a thin JSON-driven frontend:

| Identifier      | Value                           |
| --------------- | ------------------------------- |
| Dub sub-package | `packaging-cli` (executable)    |
| Source root     | `apps/packaging/src/`           |
| Binary          | `sparkles-package`              |
| Library         | depends on `sparkles:packaging` |

The initial command surface is:

```text
sparkles-package validate <request.json>
sparkles-package plan <request.json> [--json]
sparkles-package build <request.json> [--output-dir <path>]
sparkles-package capabilities <request.json> [--json]
```

The request document is a strict, versioned JSON representation of
`PackageRequest`. It requires a schema identifier, rejects unknown fields by
default, and resolves relative input paths against the request file's
directory, not the caller's current directory. Semantic packaging choices live
in the request; the CLI limits overrides to execution concerns such as output
location, presentation, and log level.

`validate`, `plan`, and `capabilities` are read-only. `plan --json` emits the
canonical plan representation. `build` is the only baseline command that
creates workspaces or artifacts. Secret values are never accepted inline in
the JSON document; native backends accept named credential references whose
resolution is outside the serialized request.

## 4. Core model

### 4.1 Package request

A `PackageRequest` contains:

- one `ProductIdentity` (§4.2);
- one source version and full source revision;
- an optional native build number for formats that require one;
- one target (§4.3);
- one validated stage-tree description (§5);
- one or more `ArtifactRequest`s;
- reproducibility policy, including the normalization epoch;
- optional signer, post-processor, and validator capabilities;
- output and workspace policies.

A request is data. Constructing it performs no process execution, network
access, signing, or output mutation.

### 4.2 Product identity

The shared identity contains at least:

| Field         | Meaning                                                  |
| ------------- | -------------------------------------------------------- |
| `name`        | stable machine-readable product name                     |
| `displayName` | user-facing name                                         |
| `version`     | source SemVer from the immutable source/release identity |
| `description` | short human-readable summary                             |
| `vendor`      | publisher/vendor display identity                        |
| `homepage`    | canonical project URL                                    |
| `license`     | declared payload license expression or identifier        |

Format identities are separate, explicit values rather than synthesized
late in execution:

- Linux package name, maintainer, architecture mapping, and package release;
- Windows package/application identity, publisher identity, installation
  scope, and any future upgrade lineage identifier;
- Apple bundle identifier, bundle version mapping, category, minimum OS, and
  signing team identity where signing is requested.

Once a format with upgrade semantics is publicly released, its stable identity
fields are immutable unless the product intentionally starts a new lineage.
The artifact receipt records the resolved identity used for every artifact.

### 4.3 Target and host

`Target` and `Host` are distinct. A target contains OS, architecture, ABI or
environment where relevant, and optional minimum-runtime claims. Architecture
names are canonicalized once and mapped by each backend to its native spelling.

The baseline canonical OS values are `linux`, `windows`, and `macos`; baseline
architectures are `x86_64`, `aarch64`, and the macOS-only `universal2` payload
class. A universal artifact is accepted only when the stage declares how its
universal binaries were produced; packaging does not merge binaries itself.

The host is detected or supplied to capability probing. A plan may target a
different host, but execution succeeds only when every required operation is
available on the actual host.

### 4.4 Version mappings

The source version is a `sparkles:versions` `SemVer`. Every non-SemVer native
version is derived by a named, testable mapping before artifact creation.
No backend reparses or silently truncates the source string.

The full commit hash is the request's opaque source/build identifier. It is
recorded in plans and receipts and may appear in snapshot artifact names. It is
not converted into a native numeric version: truncating or hashing it into an
integer would not preserve commit or release order.

The initial mappings are:

- archive/display version: canonical SemVer without a leading `v`;
- Debian upstream version: canonical SemVer; Debian revision is a separate
  explicit field, defaulting to `1` only for the first package build;
- Apple short version: SemVer core `major.minor.patch`; prerelease/build
  handling is explicit, and a numeric bundle build version is supplied when
  the selected distribution path requires monotonic build ordering;
- Windows portable artifacts: canonical SemVer in names and receipts;
- installer-specific numeric versions: derived from SemVer where lossless, or
  supplied as a separate native build number and rejected if ambiguous.

Mapping failure is a planning error, not a best-effort warning.

The commit hash and native build number have different jobs:

- `sourceRevision` is the full Git object ID and gives exact provenance;
- `nativeBuildNumber` is an optional decimal integer/tuple used only by a
  backend whose format requires numeric or monotonically ordered versions;
- the caller/release pipeline supplies `nativeBuildNumber`; the library
  validates syntax, range, and ordering against a supplied previous version;
- portable archives and Debian packages do not invent a native build number
  when their existing version fields are sufficient.

This keeps packaging reproducible from explicit inputs without pretending a
commit hash is ordered. A CI run number, release-sequence counter, or a
repository-owned SemVer mapping may supply the numeric value, but that policy
is outside the generic library.

## 5. The stage tree

### 5.1 Entries and sources

A `StageTree` is an ordered logical tree independent of the host filesystem.
It contains regular files, directories, and symbolic links. Hard links,
devices, sockets, and FIFOs are rejected in the baseline.

Regular-file content may come from:

- a host filesystem path;
- caller-owned bytes or an input range;
- a generator that writes to a supplied output range.

Each entry carries the format-neutral metadata that can be represented
honestly: logical path, kind, executable/permission mode, normalization time,
and link target where applicable. Backend-specific metadata lives in that
backend's request, not in generic entries.

Inputs are read during execution. The receipt records their observed size and
SHA-256; a changed input between planning and execution aborts when the caller
provided an expected size or digest.

### 5.2 Path rules

Logical paths always use `/`, are relative to the stage root, and are stored in
normalized UTF-8. Validation rejects:

- empty paths, absolute paths, drive/UNC prefixes, NUL, `.` and `..` segments;
- duplicate entries or file/directory prefix conflicts;
- names not representable by the requested format;
- target-equivalent collisions, including case-folding collisions for a
  Windows target;
- symlinks that are absolute or escape the stage root, unless a native-package
  backend explicitly opts into and validates a stricter format-specific rule.

Host path joining occurs only after logical validation and must prove that the
result stays under the workspace root. Archive extraction is never used as an
internal shortcut for materializing untrusted entries.

### 5.3 Metadata normalization

Reproducibility is the default. Every request resolves one normalization epoch,
normally `SOURCE_DATE_EPOCH` supplied as data by the build/release layer. If it
is absent, the library uses a documented fixed epoch, adjusted only to the
minimum timestamp representable by the target format (for example ZIP's DOS
timestamp floor), and reports that fallback in the receipt.

Unless a backend's semantics require otherwise:

- entries are emitted in normalized lexical path order;
- owner/group names and numeric IDs are normalized;
- directory and regular-file modes use caller values or stable defaults;
- host umask, locale, timezone, current directory, and wall-clock time do not
  affect bytes;
- archive comments, random identifiers, and host-specific extra fields are
  omitted;
- compression parameters are explicit and recorded.

## 6. Artifact and format contract

### 6.1 Artifact lifecycle

Each planned artifact passes through named states:

1. `staged` — the payload tree and metadata are validated;
2. `encoded` — the unsigned package/container bytes exist in a workspace;
3. `mutated` — optional signing, notarization, or stapling has changed bytes;
4. `verified` — required structural and trust checks passed;
5. `finalized` — final size and SHA-256 are recorded and output is atomically
   installed;
6. `receipted` — the final receipt references the immutable output bytes.

No checksum calculated before the last byte-mutating step may be presented as
the final checksum. A finalized artifact is never reopened for mutation by the
same plan.

### 6.2 Baseline format matrix

| Format/output            | Implementation boundary | Baseline contract                                                  |
| ------------------------ | ----------------------- | ------------------------------------------------------------------ |
| Materialized stage       | built-in D              | deterministic directory tree for inspection/testing                |
| TAR/PAX                  | built-in D              | portable POSIX metadata, long paths/links, deterministic ordering  |
| ZIP/ZIP64                | built-in D              | UTF-8 names, portable permissions, deterministic central directory |
| Gzip compression         | Phobos/runtime          | fixed header metadata and explicit compression level               |
| XZ/Zstandard compression | optional capability     | argument-vector tool invocation; version and parameters recorded   |
| Debian `.deb`            | built-in D              | `ar` container plus valid control/data TAR members                 |
| macOS `.app` tree        | built-in D              | validated bundle layout and generated `Info.plist`                 |
| macOS signed ZIP/DMG     | Apple capability        | native signing/notarization/stapling/container sequence            |
| Windows portable ZIP     | built-in D              | target-aware launcher/payload layout                               |
| Windows Authenticode     | Windows capability      | supplied signer tool; signature verified before finalization       |
| AppImage                 | optional capability     | consumes a completed AppDir; pinned runtime/tool inputs required   |
| Inno Setup installer     | optional capability     | generated/owned script plus user-provisioned compiler              |

MSI, MSIX, RPM, Arch packages, Flatpak, Snap, PKG, XIP, NSIS,
Chocolatey packages, and updater bundles are deferred until a concrete product
and lifecycle requirement selects them. Adding a format requires its own
identity, upgrade, uninstall, signing, validation, and clean-host contract; it
is not merely another filename extension.

The first product order is resolved: `apps/ci` and `apps/release` prove the
portable TAR/ZIP path; `apps/terminal` then proves the AppImage, Inno Setup, and
macOS `.app` + DMG native paths. The relative placement of the optional `.deb`
slice remains an implementation-order decision (§13 D3).

### 6.3 Encoder requirements

Built-in encoders:

- write to an output range or seek-capable sink where the format requires it;
- do not shell out;
- validate overflow, size, offset, checksum, and format limits before narrowing;
- return structured errors rather than partial success;
- make streaming possible for payload files that need not be retained in
  memory;
- remove incomplete workspace output after failure while preserving the
  caller's pre-existing destination;
- expose lower-level writer APIs independently of plan execution.

Whether a format uses a seekable output, data descriptors, or bounded buffering
is part of that encoder's contract and tests. The API must not pretend all
formats can be emitted through the same weakest writer concept.

## 7. Planning and execution

### 7.1 Plan construction

`makePackagePlan(request, host)` performs validation and returns either a
`PackagePlan` or structured errors. Planning may inspect explicitly named input
files, but it does not write outputs, invoke tools, access the network, or read
credentials.

The plan contains:

- resolved product, target, and per-format identities/versions;
- normalized stage entries and output names;
- a dependency graph of stage, encode, mutation, verification, and receipt
  operations;
- required and optional capabilities with probe results;
- every external executable and non-secret argument known at plan time;
- expected byte mutations and the point at which the final digest is valid;
- reproducibility policy and declared sources of non-determinism;
- conflicts, warnings, and unavailable-operation reasons.

A plan is serializable for inspection, but it is not a durable promise that
filesystem inputs or host capabilities will remain unchanged. Execution
revalidates them.

### 7.2 Dry-run

Dry-run renders or serializes the plan and exits without creating a workspace,
writing an output, invoking a signer, or acquiring a credential. Missing
required capabilities make the plan non-executable but do not prevent dry-run
from describing the full requirement set.

### 7.3 Execution

`executePackagePlan`:

1. revalidates the request, inputs, output conflicts, and capabilities;
2. creates a private workspace beside or under the configured output root;
3. executes operations in dependency order;
4. verifies every requested artifact;
5. atomically installs final artifacts without overwriting an unrelated file;
6. writes the receipt last.

The executor has no hidden network access. A declared native tool such as
Apple's notarization client may use the network as part of its explicit
operation. Such a step is labelled in the plan and its externally meaningful
request/result identifier is recorded without secrets.

Independent artifact branches may execute concurrently only when their inputs,
outputs, tool workspaces, and credentials are disjoint. Deterministic output
must not depend on scheduling.

## 8. Capability and backend model

A capability answers three questions:

1. is this operation supported by the compiled library and actual host?
2. if not, why not and what requirement is missing?
3. if yes, which implementation and version will execute it?

The result is one of `available`, `unavailable`, or `unknown`, with a stable
capability key and human-readable reason. Examples include
`format.zip.builtin`, `compress.xz.command`, `apple.codesign`,
`apple.notary`, `windows.authenticode`, and `format.appimage`.

Backends follow Sparkles' design-by-introspection style: a small required
surface plus optional primitives detected by presence. Generic orchestration
provides fallback behavior only where the semantics are genuinely equivalent.
There is no mandatory runtime plugin loader, global registry, or class
hierarchy.

An external-tool backend must:

- invoke an executable with an argument vector, never an interpolated shell
  command;
- probe without mutating user state;
- report resolved executable path and version;
- use a plan-owned workspace and explicit environment allowlist;
- distinguish unsupported host, missing tool, invalid version, failed command,
  and failed verification;
- redact credential values and secret-bearing environment variables;
- permit a fake process boundary for unit tests.

Native tools are not treated as evidence of success by exit code alone when a
native inspection or trust-verification command exists.

## 9. Receipt and supply-chain boundary

Successful execution produces a canonical, schema-versioned JSON
`ArtifactReceipt` for one target request and all artifacts derived from it. It
contains:

- schema and packager version;
- source version/revision and resolved product identity;
- target and actual host;
- normalized stage inventory with path, kind, size, mode, and SHA-256 for files;
- final artifact name, format, size, SHA-256, and content relationship;
- exact built-in encoder version or external-tool path/version and non-secret
  parameters;
- signing/notarization/verification status and non-secret identity metadata;
- normalization epoch, compression settings, and known non-determinism;
- warnings and explicitly skipped optional checks.

Canonical JSON uses UTF-8, stable key/array ordering, and locale-independent
number/string rendering. Serialization must not require a new third-party JSON
dependency. The receipt is written only after all final artifact digests are
known; a separate checksum file may cover the receipt itself.

The receipt is an evidence substrate, not an SBOM, release-wide manifest, or
provenance attestation. Later integrations may aggregate target receipts into a
release manifest and may generate SPDX/CycloneDX or signed provenance documents
from them plus build-system evidence. The packager must not claim dependencies
it did not actually inspect.

## 10. Signing, notarization, and trust

Signing is modeled as a byte-mutating capability with an explicit verification
step. The package accepts credential references or caller-provided signer
objects; secrets are never copied into plans, receipts, logs, or errors.

Platform rules remain visible:

- macOS bundle contents are signed inside-out, then the outer bundle/container
  sequence is applied as required; notarization and stapling are separate
  operations with separate results;
- Windows executable signing and installer/container signing are separate
  operations; the requested timestamp policy is explicit;
- Linux archive checksums are not signatures; package/repository signing is a
  separate capability and repository metadata is outside baseline scope.

Signing jobs may consume a digest-addressed unsigned input produced elsewhere,
but the resulting signed bytes are a new artifact that must be verified and
digested again. The library never promotes an unsigned digest as the digest of
its signed descendant.

## 11. Errors, diagnostics, and safety

Public fallible operations return `Expected!(T, PackagingError)` or a
package-specific alias. `PackagingError` includes:

- a stable error code;
- operation and optional artifact/capability key;
- logical and host paths where safe to disclose;
- a human-readable message;
- an optional nested process/format error with exit status and bounded output.

Expected failures do not throw across the public API. Allocation-free lower
level codecs may use a compact error enum/offset type; IO orchestration may
allocate diagnostic text. Templates generic over writers and backends infer
their safety attributes as required by the repository guidelines.

Security invariants include:

- no path traversal, target-root escape, or ambiguous duplicate path;
- no shell interpretation of filenames or metadata;
- no implicit following of source symlinks;
- no credential value in a plan, receipt, log, exception, or command preview;
- bounded parsing of external-tool and archive metadata;
- refusal to overwrite existing outputs unless the caller supplies an explicit
  matching-artifact replacement policy;
- cleanup limited to plan-owned workspaces.

## 12. Verification contract

Every milestone is green on its supported hosts and tests at three levels:

1. **Codec/model tests** — pure unit tests, format boundary/overflow cases,
   malicious paths, deterministic byte fixtures, and writer capability tests.
2. **Native conformance tests** — independent readers/validators inspect output
   (`tar`, ZIP readers, `dpkg-deb`, Apple/Windows trust tools). Tests skip with a
   stated reason when an optional environment capability is absent.
3. **Lifecycle tests** — clean-host extract/install → launch → upgrade from the
   previous stable identity → uninstall, with documented user-data behavior for
   formats that own installation state.

Required acceptance properties are:

- packaging the same stage, identity, epoch, and parameters twice produces the
  same unsigned bytes;
- a one-byte payload or metadata change changes the recorded digest;
- every artifact is readable by an implementation independent of its writer;
- plan-only mode causes no filesystem/process/credential side effects;
- missing host tools are diagnosed before artifact mutation;
- interrupted or failed execution leaves no partial final artifact;
- signed artifacts pass native verification on a clean target host;
- the receipt describes the bytes actually installed in the output directory.

## 13. Scope decisions

Resolved decisions are normative. Open decisions still gate the indicated
implementation milestones.

| ID  | Status   | Decision                      | Resolution/current recommendation                                                   |
| --- | -------- | ----------------------------- | ----------------------------------------------------------------------------------- |
| D1  | resolved | Frontend                      | library plus thin `sparkles-package` executable in `apps/packaging`                 |
| D2  | resolved | Build identity                | full commit hash for provenance; separate caller-supplied native number when needed |
| D3  | partial  | First product/format vertical | CLIs first, then `terminal`; decide whether `.deb` precedes or follows desktop      |
| D4  | resolved | CLI configuration             | strict versioned JSON request; D API remains authoritative                          |
| D5  | open     | Compression floor             | built-in TAR/ZIP + gzip; external explicit adapters for XZ and Zstandard            |
| D6  | open     | Publishing/catalog boundary   | emit receipts only; keep upload, indexes, repositories, and promotion outside       |

Changing a resolved decision updates this document and the milestone gates in
[PLAN.md](./PLAN.md) before implementation relies on the change.
