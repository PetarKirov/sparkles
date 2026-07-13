# Application Packaging Research Plan

A working plan for the source-grounded application-packaging catalog under
`docs/research/application-packaging/`. The catalog surveys how native applications
become portable archives, platform bundles, installers, repository packages, and
package-manager entries across Linux, Windows, and macOS. It also compares the release
control planes that coordinate those artifacts.

**Plan updated:** July 12, 2026

> [!IMPORTANT]
> This is an execution plan, not a findings page. Claims intended for readers belong in
> the catalog's deep-dives and synthesis pages, where they must carry primary-source
> citations. Remove this plan from the published catalog, or move it to the final design
> issue, once the research tree is complete and its remaining work is tracked elsewhere.

## 1. Outcome

Deliver a VitePress-integrated research tree that answers five layers of the packaging
problem without conflating them:

1. **Build outputs** — target-specific executables, libraries, resources, debug symbols,
   and runtime dependencies.
2. **Application staging** — the filesystem tree or platform bundle from which artifacts
   are produced.
3. **Artifact construction** — archives, Linux packages, Windows installers, macOS
   bundles and containers, sandboxed application formats, and update packages.
4. **Trust and distribution** — signing, timestamping, notarization, repository metadata,
   hosted release assets, package-manager catalogs, stores, and update feeds.
5. **Release orchestration** — planning the target matrix, dispatching native builders,
   collecting artifacts, generating checksums/SBOM/provenance, publishing, promoting,
   and announcing a release.

The final synthesis must recommend a staged packaging architecture for Sparkles while
keeping the research/design boundary explicit: deep-divives establish prior art;
`recommendations.md` interprets it; future implementation specifications belong under
`docs/specs/`.

## 2. Research questions

The umbrella must link each question to the page that answers it:

1. What do `stage`, `package`, `bundle`, `sign`, `notarize`, `staple`, `publish`, and
   `promote` mean, and which operations mutate bytes?
2. Which artifact formats are portable payload containers, native installer databases,
   sandboxed application deployments, or merely manifests pointing at another artifact?
3. Which targets can be cross-compiled or cross-packaged, and which require a native
   Windows or macOS runner?
4. How do application identity and version semantics control upgrades, downgrades,
   side-by-side installation, repair, rollback, and uninstall?
5. How do platform code signing, repository signing, checksums, notarization, and
   provenance attestations differ?
6. What does each Linux distribution format own, and when should an application prefer a
   universal format such as AppImage, Flatpak, or Snap?
7. How do MSI, MSIX, installer EXEs, portable archives, WinGet, Chocolatey, and Scoop
   compose rather than compete?
8. How do `.app`, `.dmg`, `.pkg`, `.xip`, Developer ID, hardened runtime, notarization,
   stapling, Gatekeeper, Homebrew Formulae, and Casks compose?
9. Which tools are release control planes, application packagers/updaters, or low-level
   format backends?
10. What does Sparkles already release, what is missing, and what is the smallest staged
    path to trustworthy multi-platform application artifacts?

## 3. Scope

### 3.1 In scope

- Native CLI and desktop applications with prebuilt binaries.
- Linux native and universal package formats.
- Windows portable archives, installers, and community catalogs.
- macOS bundles, transport/installer containers, signing, notarization, and Homebrew.
- Multi-target release orchestration and artifact publication.
- Upgrade, uninstall, update-feed, and release-channel semantics.
- Checksums, SBOMs, provenance, reproducibility, and signing-secret handling.
- Host-OS/toolchain constraints and realistic CI matrices.
- Open-source tools plus a small number of important commercial comparators when their
  architecture exposes a distinct capability.
- A source audit of the current Sparkles release and Nix workflows.

### 3.2 Out of scope

- Mobile app stores except where a desktop tool shares the same signing or publishing
  architecture.
- Container-image deployment except as an output of a surveyed release orchestrator.
- Language-library publication except where it demonstrates a release control plane.
- Full package-manager dependency resolution internals.
- Implementing packaging code in `apps/release` during the research phase.
- Treating a tag/changelog bot as a packager when it produces no application artifact.
- Treating raw WiX, Inno Setup, `jpackage`, or an app store as an end-to-end release
  orchestrator unless another tool coordinates it as such.

## 4. Local-first grounding protocol

The research must prefer locally cloned source over ad-hoc web fetching.

For every open-source subject:

1. Check `$REPOS` (`/home/petar/code/repos`) for an existing clone.
2. Clone a missing upstream into a stable category directory under `$REPOS`.
3. Record `git remote get-url origin`, the full reviewed commit SHA, and when useful the
   nearest tag from `git describe --tags --always`.
4. Read checked-in source, documentation, schemas, tests, examples, and CI workflows.
5. Locate implementation identifiers supporting each important claim.
6. Cite a permanent GitHub/GitLab `blob/<sha>/path` URL corresponding to the locally read
   file, not a floating `main` URL.
7. Use online vendor documentation only when the behavior is policy/specification not
   present in a source repository, especially Microsoft and Apple platform contracts.
8. Record unavailable hardware or host verification honestly instead of inferring that a
   documented path was executed.

Each deep-dive's Sources section must name its pinned revision and the local paths used
for the investigation. Local filesystem paths are research provenance, while public
permalinks remain the reader-facing citations.

### 4.1 Already grounded reference repositories

| Subject                         | Local clone / reviewed revision                                                           |
| ------------------------------- | ----------------------------------------------------------------------------------------- |
| `cargo-dist` / `dist`           | `$REPOS/cargo-dist` at `25b2af882b1641c6ae50bc81c11ec174b8a6e1d8`                         |
| `cargo-packager`                | `$REPOS/cargo-packager` at `37a538e76608b33eaa3f36f7c57b30b284dfa5a9`                     |
| GoReleaser                      | `$REPOS/packaging/goreleaser` at `7630cd166fb4dbad0a29ea23cf5e941b66f72b09`               |
| nFPM                            | `$REPOS/packaging/nfpm` at `6595841499a18755f03356b69511f32a8cec2761`                     |
| fpm                             | `$REPOS/packaging/fpm` at `f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99`                      |
| JReleaser                       | `$REPOS/packaging-research/jreleaser` at `98de563b61df6232d38dafafa8d1f1728432c207`       |
| dotnet-releaser                 | `$REPOS/packaging-research/dotnet-releaser` at `a7f1a62decd89e97297d55e6563fc246cac23d71` |
| Velopack                        | `$REPOS/packaging-research/velopack` at `9ba468337e367c59db339828b59c8a20a0f6ea90`        |
| Conveyor docs/plugin repository | `$REPOS/packaging-research/conveyor` at `9e90ce7c2a4356c99d68c63f41e4bc497da279c8`        |
| Briefcase                       | `$REPOS/python-packaging/briefcase` at `389be4fe5d4c890a1c7b558164f867d16e295bf0`         |
| cx_Freeze                       | `$REPOS/python-packaging/cx-freeze` at `ecd80b36d241ce67d648ede65bd2cd5ac10436c4`         |
| electron-builder                | `$REPOS/js/electron-builder` at `39df92fd14d9a3788add09a3963028a48eed176e`                |
| Electron Forge                  | `$REPOS/js/electron-forge` at `fc5fb4d4269cbce909fc59f570b8aa1e1add4090`                  |
| CMake / CPack                   | `$REPOS/pkg-research-native/CMake` at `22fd26b6c44ef5ae36eb6a70324c30776005b239`          |
| linuxdeploy                     | `$REPOS/packaging/linuxdeploy` at `a9f929ff0e32d5c4bcb7b5c380adff4802f918ba`              |
| appimagetool                    | `$REPOS/packaging/appimagetool` at `8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81`             |
| Swift Bundler                   | `$REPOS/pkg-research-native/swift-bundler` at `4ad3f14f0b4c292f5bb57105b834be7f321c4f05`  |

The exact clone locations and revisions for Linux, Windows, Homebrew, and Apple-adjacent
sources must be copied from their completed deep-divives into a final grounding ledger
before review.

## 5. Catalog structure and ownership

```text
docs/research/application-packaging/
├── index.md
├── concepts.md
├── artifact-formats.md
├── release-pipeline.md
├── sparkles-baseline.md
│
├── linux-native-packages.md
├── linux-repositories.md
├── appimage.md
├── flatpak.md
├── snap.md
├── linuxdeploy-appimagetool.md
│
├── windows-portable.md
├── wix-msi.md
├── msix.md
├── inno-setup-nsis.md
├── winget.md
├── chocolatey.md
├── scoop.md
│
├── macos-app-bundles.md
├── macos-dmg-pkg-xip.md
├── macos-signing-notarization.md
├── homebrew.md
│
├── cargo-dist.md
├── cargo-packager.md
├── goreleaser.md
├── jreleaser.md
├── dotnet-releaser.md
├── velopack.md
├── conveyor.md
├── briefcase.md
├── cx-freeze.md
├── electron-builder.md
├── electron-forge.md
├── cpack.md
├── fpm-nfpm.md
├── jpackage.md
├── swift-bundler.md
│
├── comparison.md
├── platform-gotchas.md
└── recommendations.md
```

### 5.1 Umbrella and synthesis pages

#### `index.md`

Required order:

1. Framing and linked research questions.
2. `**Last reviewed:** July 12, 2026`.
3. The catalog's fixed analysis spine.
4. Master table covering every subject.
5. Taxonomies by role, install model, native-host requirement, trust model, and
   distribution channel.
6. Milestones across formats and tooling.
7. Reading paths for vocabulary, each platform, release-tool authors, and Sparkles
   design work.
8. Source/provenance summary and reference links.

#### `concepts.md`

Define once and link everywhere:

- build, stage, package, bundle, freeze, sign, notarize, staple, publish, promote;
- payload, manifest, package index, repository metadata, bottle, cask, tap, feed;
- portable archive, fetching installer, bundling installer, native package, app bundle,
  sandboxed deployment;
- package identity, upgrade identity, product/component identity, bundle identifier;
- runtime dependency declaration versus vendoring;
- platform code signing versus package/repository signing;
- Authenticode timestamps, Apple tickets, checksums, signatures, and attestations;
- target triples, architecture labels, fat/universal binaries;
- stable/beta/nightly channels, immutable assets, deltas, rollback;
- SBOM, provenance, reproducibility, and hermetic versus native-host packaging.

#### `artifact-formats.md`

Compare the format contract rather than the generating tools. For each format record:
container/layout, metadata location, payload model, dependency model, identity, signing
envelope, install transaction, upgrade/uninstall owner, repository/channel, native
inspection commands, and cross-packaging constraints.

#### `release-pipeline.md`

Model the artifact DAG:

```text
source tag
  → target binaries and symbols
  → staged filesystem trees / app bundles
  → archives and native packages
  → platform signing / notarization / timestamping
  → checksums + SBOM + provenance
  → immutable release host
  → package-manager manifests and repository indexes
  → validation, promotion, and announcement
```

Explain failure boundaries, immutable inputs, fan-out/fan-in CI, native signing jobs,
secret isolation, partial publication, retry/idempotency, and the distinction between
hosting an artifact and registering it in a catalog.

#### `sparkles-baseline.md`

Audit only locally observed behavior:

- tag-derived monorepo versioning;
- `apps/release` stages and preflight;
- GitHub Release publication;
- code.dlang.org registry notification;
- `.#all` Linux/macOS Nix builds, Cachix push, and retention pins;
- available application packages and native dependencies;
- current absence of Windows release artifacts, archives/installers, macOS `.app`/DMG,
  code signing/notarization, package-manager manifests, checksums/SBOM/provenance, and an
  artifact fan-in release manifest.

#### `comparison.md`

Include:

1. At-a-glance role/capability matrix.
2. Per-dimension comparisons using the common spine.
3. Consensus standard.
4. Architectural trade-offs among control planes, app packagers/updaters, and format
   primitives.
5. Native-host versus cross-packaging boundary.
6. Open-source versus paid capability boundary.
7. Explicit Sparkles delta table.
8. Open questions and evidence limitations.

#### `platform-gotchas.md`

A concise operational checklist, with every trap linked to the evidence-owning page.
Do not introduce uncited new claims here.

#### `recommendations.md`

Resolve the target artifact matrix and present a staged roadmap. Every milestone must
name:

- user-visible deliverable;
- selected prior art;
- required host/runner;
- signing secrets and trust boundary;
- generated metadata and validation;
- rollback/idempotency behavior;
- intentionally deferred formats/channels.

### 5.2 Platform pages

#### Linux

- `linux-native-packages.md`: Debian, RPM, and Arch file layouts, metadata,
  dependencies, scripts, transactions, signing, upgrade/uninstall semantics.
- `linux-repositories.md`: APT and RPM-family indexes/signatures plus OBS, COPR, PPAs,
  and AUR's recipe-vs-binary distinction.
- `appimage.md`: AppDir, runtime/SquashFS, desktop integration, update metadata,
  signatures, compatibility and sandbox absence.
- `flatpak.md`: manifests, runtimes, portals, OSTree repositories, permissions, signing,
  and Flathub publication.
- `snap.md`: squashfs package, confinement/interfaces, assertions, channels, refresh,
  Snapcraft and Store publication.
- `linuxdeploy-appimagetool.md`: concrete implementation of AppDir staging and AppImage
  finalization.

#### Windows

- `windows-portable.md`: ZIP/directory conventions, PATH/shortcuts, per-user placement,
  update/uninstall ownership, checksums/signing.
- `wix-msi.md`: Windows Installer database, Product/Package/Upgrade codes, component
  rules, major/minor upgrades, repair/rollback, Burn, WiX build/signing.
- `msix.md`: package identity, manifests, block maps, signatures, bundles, sparse
  packages, App Installer/update behavior, Store/private distribution.
- `inno-setup-nsis.md`: scriptable installer EXEs, payload compression, registry and
  shortcut operations, uninstallers, update identity, signing.
- `winget.md`: catalog manifests referring to hosted installers, validation, installer
  switches, versions, portable packages, submission automation.
- `chocolatey.md`: `.nupkg`, PowerShell install/uninstall scripts, embedded versus remote
  payloads, moderation, checksums, internal repositories.
- `scoop.md`: JSON manifests, portable extraction, shims, persistence, buckets,
  autoupdate, checksums.

#### macOS

- `macos-app-bundles.md`: bundle anatomy, `Info.plist`, bundle identity/version,
  resources/frameworks/helpers, universal binaries, relocation.
- `macos-dmg-pkg-xip.md`: DMG transport UX, component/distribution PKG installer
  semantics, receipts/scripts, XIP's narrower signed archive role.
- `macos-signing-notarization.md`: designated requirements, nested-code signing order,
  entitlements, hardened runtime, Developer ID, `notarytool`, stapling, quarantine and
  Gatekeeper.
- `homebrew.md`: Formula versus Cask, bottles/kegs, taps, artifact checksums, upgrades,
  uninstall/zap, publication automation.

### 5.3 Tool pages

Classify every tool before discussing features:

- **Release control planes:** `cargo-dist`, GoReleaser, JReleaser, dotnet-releaser.
- **Application packagers/updaters:** `cargo-packager`, Velopack, Conveyor, Briefcase,
  cx_Freeze, electron-builder, Electron Forge, Swift Bundler.
- **Format/backend primitives:** CPack, fpm/nFPM, `jpackage` and Beryx plugins,
  linuxdeploy/appimagetool.

The page must state when a capability belongs to a delegated backend rather than the
orchestrator itself. Paid or hosted capabilities must be separated visibly from the OSS
core.

## 6. Fixed deep-dive skeleton

Every subject page follows this order:

1. `# Subject (ecosystem/role)` and one-sentence position.
2. Metadata table: language, license, repository, docs, reviewed SHA/version, category,
   supported hosts/targets, OSS/paid boundary.
3. `**Last reviewed:** July 12, 2026` where the page synthesizes current state.
4. `## Overview`
   - `### What it solves`
   - `### Design philosophy`
   - at least one verbatim primary-source quotation.
5. `## How it works` with real identifiers and short labelled excerpts.
6. Fixed analysis spine:
   - input and staging;
   - outputs and target matrix;
   - metadata and dependencies;
   - installation, upgrade, and uninstall;
   - signing and platform trust;
   - publication and discovery;
   - updates and release channels;
   - automation and CI;
   - supply-chain evidence and reproducibility;
   - extensibility and UX.
7. `## Strengths`.
8. `## Weaknesses`.
9. `## Key design decisions and trade-offs` table.
10. `## Sources` followed by the reference-link block.

When a dimension is not applicable, record the absence and why. Do not silently omit it.

## 7. Evidence labels and verification

Use explicit labels where the verification boundary matters:

| Label                        | Meaning                                                                        |
| ---------------------------- | ------------------------------------------------------------------------------ |
| `[source-verified]`          | Read in pinned implementation, tests, schema, or checked-in docs.              |
| `[spec-verified]`            | Read in an authoritative platform/package-format specification.                |
| `[host-verified: <os/arch>]` | Command or artifact behavior executed on that host.                            |
| `[schema-validated]`         | A sample manifest passed the upstream schema/validator.                        |
| `[literature]`               | Secondary or historical source; never the sole support for a current mechanic. |
| `[unverified]`               | Open question retained explicitly; not written as fact.                        |

No Windows or macOS behavior should be called host-verified unless a corresponding run
record exists. Documentation/source verification is still valuable, but it is a different
claim.

## 8. Samples and runnable evidence

Only add samples that increase confidence rather than decorate the catalog.

Candidate fixtures:

- one canonical staged application tree with executable, license, resources, desktop
  metadata, and icons;
- nFPM/CPack/cargo-packager manifests consuming that tree;
- WinGet, Chocolatey, Scoop, Homebrew, Flatpak, and Snap manifests pointing at a fake or
  fixture artifact;
- a small D artifact-inspection utility only if it demonstrates a cross-format invariant
  that ordinary shell tools cannot express clearly.

Rules:

- Co-locate substantial fixtures under `<subject>/sample/` and move the page to
  `<subject>/index.md`.
- Validate schemas with pinned upstream tools where practical.
- Never claim Linux CI validates MSI, MSIX, DMG, PKG, Authenticode, or notarization.
- Prefer a future OS matrix over mocks for native tooling.
- Do not commit generated packages, signatures, dependency stores, or build outputs.

Samples are not required for platform policy that cannot be meaningfully exercised on the
current host; pinned sources/specifications and honest evidence labels are the correct
fallback.

## 9. Current execution state

### 9.1 Completed research content

All 40 planned reader-facing catalog pages now exist on `research/packaging`:

- eight umbrella/concept/synthesis pages;
- six Linux pages;
- seven Windows pages;
- four macOS pages;
- six initial control-plane/updater pages;
- nine cross-ecosystem packager/backend pages.

The principal landed commit groups are macOS packaging and trust; release control
planes/updaters; Electron packaging; native and universal Linux packaging; Windows
formats and package-manager channels; backend primitives; the umbrella/synthesis; and
VitePress registration. The plan intentionally records stable subjects rather than
commit hashes, because the outstanding autosquash will rewrite those hashes.

Formatting and review fixups are attached to their owning commits and remain to be
autosquashed only after user approval.

### 9.2 Validation state

- Prettier is clean across the catalog and VitePress configuration.
- `dub run :ci -- --verify --files 'docs/research/application-packaging/*.md'` passes.
- `npm run docs:build` passes after escaping literal Go-template delimiters and allowing
  links to repository `.nix` source files.
- `lychee` passes for all catalog pages and the sidebar.
- The complete pre-commit suite passes over the catalog, grounding artifacts, sidebar,
  and EditorConfig.
- Durable Apple policy/manual snapshots have recorded SHA-256 digests and are excluded
  from the published VitePress source set.
- The working `PLAN.md` is retained in the repository but excluded from the published
  VitePress source set.

### 9.3 Review and cleanup state

Both independent, read-only reviews now pass after fail-closed rechecks:

1. the structural/cross-page audit verified the canonical spine, taxonomy, metadata,
   resolved artifact matrix, sidebar coverage, and quote/source shape;
2. the factual/source audit verified its sampled Linux, Windows, macOS, control-plane,
   packager/updater, backend, comparison, and recommendation claims against pinned local
   sources and durable Apple evidence.

All delegated worktrees were clean and have been removed. Remaining work is only the
user-approved autosquash/reorder and, if requested, pushing/opening a PR.

## 10. Execution phases

### Phase 0 — Preserve completed delegated work

1. Commit the six tool pages on `docs/application-packaging-deep-dives`.
2. Commit the eight synthesis pages on `docs/application-packaging-synthesis`.
3. Cherry-pick both commits onto `research/packaging`.
4. Run Prettier over all landed Markdown.
5. Check duplicate/undefined reference labels before authoring missing siblings.
6. Keep the dead Linux/Windows worktrees until their transcripts and clone ledgers have
   been inspected for useful source discoveries; then remove them safely.

**Exit condition:** all persisted prose is tracked on the main research branch and no
unique work exists only in an ephemeral worktree.

### Phase 1 — Complete platform research

Run three focused passes, each small enough to finish and commit atomically:

1. Linux formats: native packages, AppImage, Flatpak, Snap.
2. Linux distribution/tooling: repositories and linuxdeploy/appimagetool.
3. Windows formats/installers: portable, WiX/MSI, MSIX, Inno/NSIS.
4. Windows catalogs: WinGet, Chocolatey, Scoop.
5. Re-audit the landed macOS pages against the fixed spine and pin/expand weak sources.

**Exit condition:** every platform sibling linked by `index.md` exists and follows the
same ten dimensions.

### Phase 2 — Complete cross-ecosystem tool research

Author remaining pages in role-based batches:

1. Application updater/package systems: Conveyor, Briefcase, cx_Freeze.
2. Electron ecosystem: electron-builder and Electron Forge.
3. Backend primitives: CPack and fpm/nFPM.
4. Native language packagers: `jpackage`/Beryx and Swift Bundler.

Then re-read all tool pages together to normalize capability vocabulary and prevent an
orchestrator from receiving credit for a delegated backend.

**Exit condition:** all master-catalog rows resolve and every page states role plus
OSS/paid boundary.

### Phase 3 — Synthesis reconciliation

The synthesis draft was written before all evidence pages existed. Reconcile it after
Phases 1–2:

1. Verify every catalog row and matrix cell against the owning deep-dive.
2. Remove forward claims unsupported by a completed page.
3. Align the stated analysis spine with the actual page headings.
4. Add the final milestones and primary-source provenance.
5. Recompute the consensus standard and Sparkles delta from the completed matrix.
6. Ensure recommendations cite comparison findings rather than introducing new facts.
7. Record open questions and host-verification gaps.

**Exit condition:** synthesis is derivable from the deep-dives and contains no orphan
assertions.

### Phase 4 — VitePress integration

Edit `docs/.vitepress/config.mts` under Research:

- Application Packaging umbrella
- Concepts and baseline
- Linux
- Windows
- macOS
- Release control planes
- Application packagers/updaters
- Format/backend primitives
- Synthesis

Keep groups collapsed and use exact slugs. Add dead-link ignores only for genuine source
fixtures, never to hide missing Markdown pages.

**Exit condition:** every catalog page is reachable from the sidebar.

### Phase 5 — Validation and review

Run, in order:

```bash
npx prettier --write 'docs/research/application-packaging/**/*.md' \
    docs/.vitepress/config.mts
npm run docs:build
dub run :ci -- --verify --files 'docs/research/application-packaging/*.md'
git diff --check
```

Then run the repository hooks. For the large docs commit, it is acceptable to bypass
only the documented flaky/OOM-prone checks during commit:

```bash
SKIP=lychee,verify-md-examples git commit ...
```

Run/link-review separately afterward; bypassing a hook is not evidence that the catalog
passes it.

Manual review checklist:

- every deep-dive has a verbatim quote and pinned source;
- all identifiers use backticks;
- every internal link resolves;
- no floating `main` source permalink where a pinned SHA is possible;
- no feature credited to the wrong layer;
- no paid feature described as OSS;
- no documented behavior described as host-tested;
- all version/date claims are absolute and sourced;
- tables agree across index and comparison;
- recommendations reflect, rather than precede, the evidence;
- Prettier did not corrupt literal identifiers or versions.

### Phase 6 — Independent review and branch cleanup

1. Ask a research reviewer to sample at least one page per platform and one tool per role,
   checking every sampled claim against the local clone.
2. Ask a link/structure reviewer to check the full tree and sidebar.
3. Fix factual issues in the commit that introduced the affected page using fixups.
4. Propose an autosquash/reorder plan before rewriting history.
5. Remove completed external worktrees only after all unique commits/files are preserved.
6. Do not push until explicitly requested.

## 11. Commit plan

Keep history bisectable and group prep before dependent content:

1. `chore(research): ignore agent runtime worktrees` — landed.
2. `docs(research): survey macOS application packaging` — landed.
3. `docs(research): survey packaging release orchestrators` — salvage six completed
   control-plane/updater pages.
4. `docs(research): add application packaging synthesis` — salvage the draft synthesis.
5. `docs(research): survey Linux application packaging`.
6. `docs(research): survey Windows application packaging`.
7. `docs(research): complete cross-platform packaging tool survey`.
8. `docs(research): reconcile application packaging synthesis`.
9. `docs(research): register application packaging catalog` — sidebar integration.
10. Fixups for factual/link/format review, autosquashed only after approval.

Because the initial synthesis links missing siblings, commits 3–7 may not individually pass
the full VitePress dead-link build. If strict per-commit greenness is required before merge,
reorder the final history so the sidebar and synthesis commit follows every deep-dive, or
combine the densely cross-linked catalog into one coherent research commit as permitted by
`docs/guidelines/research-docs.md`.

## 12. Definition of done

- [x] Every planned file exists or has been explicitly removed from scope with rationale.
- [x] Every subject follows the fixed skeleton and ten-dimension spine.
- [x] Every deep-dive contains at least one verbatim pinned primary-source quote.
- [x] Every open-source subject records its local clone and reviewed SHA.
- [x] Index includes questions, master catalog, taxonomies, milestones, navigation, and
      sources.
- [x] Comparison includes consensus, architectural trade-offs, native-host boundary,
      Sparkles delta, and open questions.
- [x] Baseline is grounded in current Sparkles source/workflows.
- [x] Recommendations are linked to evidence and staged by artifact/trust capability.
- [x] VitePress sidebar is grouped by category.
- [x] `npm run docs:build` passes.
- [x] Runnable/manifest examples, if any, pass their declared verification.
- [x] No untracked research survives only in delegated worktrees.
- [x] Branch history is reviewed and ready for autosquash/reorder.
- [x] Nothing has been pushed without explicit authorization.
