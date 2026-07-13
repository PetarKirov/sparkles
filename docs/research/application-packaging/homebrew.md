# Homebrew Formulae, Casks, and taps (macOS/Linux, Ruby)

Homebrew is both a source/binary package manager and a catalog for vendor-delivered
macOS applications: Formulae build or pour versioned kegs into the Cellar, while Casks
activate upstream app bundles, packages, fonts, and other artifacts from the Caskroom.

| Field                   | Value                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------ |
| Language                | Ruby and shell                                                                       |
| License                 | BSD-2-Clause                                                                         |
| Repository              | [Homebrew/brew][brew-repo]                                                           |
| Documentation           | [Homebrew documentation][brew-docs]                                                  |
| Official catalogs       | [homebrew-core][core-repo] · [homebrew-cask][cask-repo]                              |
| Extension/catalog unit  | Git-backed or API-backed tap                                                         |
| Formula output          | Source build or bottle installed as a versioned keg                                  |
| Cask input              | Vendor artifact such as DMG, ZIP, or PKG                                             |
| Pinned source revisions | brew [`586f1c2`][brew-sha] · core [`2d16a4b`][core-sha] · cask [`4efd588`][cask-sha] |
| Category                | Package manager, binary catalog, and macOS app activator                             |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Homebrew gives users one CLI for discovery, installation, upgrade, dependency handling,
and removal while allowing two fundamentally different packaging contracts:

- A **Formula** is a build/install recipe. It produces a versioned **keg** under the
  Cellar, usually links selected paths into the Homebrew prefix, and may instead pour a
  prebuilt **bottle**.
- A **Cask** is declarative activation metadata around an upstream vendor artifact. It
  can move an `.app`, invoke a `.pkg`, install fonts or plug-ins, and describe explicit
  uninstall and optional `zap` cleanup.

Homebrew's pinned Formula Cookbook describes its central layout directly:

> “Homebrew installs formulae to the Cellar at `$(brew --cellar)` and then symlinks
> some of the installation into the prefix at `$(brew --prefix)`.” —
> [`docs/Formula-Cookbook.md`][formula-cookbook]

### Design philosophy

Homebrew separates **recipe/catalog metadata** from **immutable versioned
installations**. Formulae prefer reproducible source recipes with bottles as cacheable
results. Casks deliberately do not repackage vendor apps: they verify a download and
activate declared artifacts. Taps decentralize both DSLs through ordinary repositories,
while the official catalogs impose stronger review and automation policy.

## How it works

### Formula mechanics

A Formula declares source URL, SHA-256, license, dependencies, build/install method,
and a `test do` block:

```ruby
class Example < Formula
  desc "Example command"
  homepage "https://example.invalid/"
  url "https://example.invalid/example-1.2.3.tar.gz"
  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  license "MIT"

  depends_on "pkgconf" => :build

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    system "#{bin}/example", "--version"
  end
end
```

The install prefix is a versioned keg such as
`/opt/homebrew/Cellar/example/1.2.3`; Homebrew links public files into
`/opt/homebrew` and maintains `/opt/homebrew/opt/example` as the active-version
symlink. A bottle is a gzipped tarball of a built keg. The pinned Bottles guide says
its formula definition is included under `<formula>/<version>/.brew/<formula>.rb`,
while bottle DSL records per-platform hashes and relocatability.

### Cask mechanics

A Cask declares the vendor release and how to activate it:

```ruby
cask "example" do
  version "1.2.3"
  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  url "https://example.invalid/Example-#{version}.dmg"
  name "Example"
  desc "Example desktop application"
  homepage "https://example.invalid/"

  app "Example.app"

  zap trash: [
    "~/Library/Application Support/Example",
    "~/Library/Preferences/com.example.app.plist",
  ]
end
```

Homebrew downloads and verifies the artifact, stages it in the Caskroom, and executes
artifact-specific activation. `app` normally moves/copies the bundle into Applications;
`pkg` delegates to `/usr/sbin/installer`; `binary`, fonts, services, plug-ins, and
other artifact classes have their own activators. The Cask Cookbook is explicit that
accepted vendor installation actions are trusted and that PKGs and installer scripts
are not run in Homebrew's cask sandbox.

### Taps and the API

A tap is a namespaced repository (`user/repo`) containing Formulae, Casks, commands,
or migrations. `brew tap user/repo` adds it; fully qualified names avoid collisions.
For default official installs, modern Homebrew can consume signed JSON API metadata
instead of requiring a complete local clone; source definitions remain retrievable and
pinned to the tap Git head in [`api/formula.rb`][formula-api] and
[`api/cask.rb`][cask-api]. Custom taps remain the primary extension and independent
publication mechanism.

## Analysis spine

### Input and staging

Formula inputs are checksummed source archives or pinned VCS revisions, resources,
patches, declared dependencies, and the host/build environment. Homebrew stages and
builds them under a temporary tree using `superenv`, which removes user `PATH` entries
and injects controlled compiler paths and flags. Cask inputs are vendor-produced
artifacts plus a declarative recipe; Homebrew downloads, verifies, mounts/extracts, and
stages before activation. `sha256 :no_check` is an explicit weakening reserved for
mutable downloads such as `version :latest`.

### Outputs and targets

Formulae target CLI tools and libraries represented as Cellar kegs, with bottles by
OS and architecture. Casks target prebuilt apps and macOS integration artifacts,
including `.app`, `.pkg`, font, preference pane, Quick Look, and plug-in outputs.
Architecture and macOS blocks can select distinct URLs/hashes or dependencies for
Apple Silicon and Intel. Formula and Cask are not interchangeable synonyms: one owns
the build/install tree; the other activates an upstream distribution.

### Metadata and dependencies

Formula metadata includes `url`, `version`, `sha256`, `license`, `revision`,
`version_scheme`, dependencies/resources, bottle checksums, service declarations, and
tests. Dependency tags distinguish build, test, recommended, and optional scopes;
`uses_from_macos` models dependencies supplied by the OS. Casks record version,
checksum, URL provenance, artifacts, macOS/architecture requirements, conflicts, and
formula/cask dependencies. Cask dependency declarations order Homebrew installs but do
not change the vendor app's own runtime loader graph.

### Install, upgrade, and uninstall

Formula install builds or pours a keg, then links it; upgrade installs a new keg and
switches links, permitting cleanup or rollback while old kegs remain. `brew uninstall`
unlinks and removes managed kegs. Cask upgrade downloads and activates the new vendor
artifact; `auto_updates true` tells Homebrew the app has its own updater and affects
outdated/upgrade policy. Cask uninstall reverses managed artifacts. `brew uninstall
--zap` additionally applies opt-in cleanup for user files and shared resources and can
therefore affect other apps. PKG-based casks must declare uninstall procedures because
macOS receipts alone do not remove payloads.

### Signing and trust

Homebrew's checksum verifies that bytes match the reviewed recipe. It does not replace
Apple code signing, notarization, or Gatekeeper for vendor apps; Casks should preserve
those artifacts and quarantine semantics. Formula bottles add per-platform SHA-256
metadata. Tap trust is also code trust: Formula and Cask files are Ruby DSL evaluated
by Homebrew, and third-party taps can include broader behavior. Homebrew therefore has
source/download/catalog trust layers rather than one universal signature boundary.

### Publication and discovery

Official Formulae live in `homebrew-core`; official Casks in `homebrew-cask`; both are
searchable with `brew search` and consumable through API metadata. Third parties
publish taps in Git repositories and users install with a fully qualified token or add
the tap. Pull requests, audit policy, ownership checks, popularity/notability rules,
and CI act as catalog governance. A tap gives immediate distribution autonomy at the
cost of weaker default discoverability and maintainer trust.

### Updates and channels

`brew update` refreshes Homebrew and catalog metadata; `brew outdated` compares
versions; `brew upgrade` installs newer recipes. Formula `livecheck` and Cask
`livecheck` discover upstream releases, while bump commands and autobump workflows
prepare catalog updates. Versioned channel tokens (for example an `@` Formula or
vendor-specific beta Cask) can coexist, but maintainers must model conflicts and
migration. `version :latest` plus `sha256 :no_check` gives freshness at the expense of
immutability and autobump eligibility.

### Automation and CI

`brew audit`, `brew style`, Formula `test do`, `brew test-bot`, and official repository
workflows validate changes. BrewTestBot builds bottles for supported runners, updates
bottle DSL, and publishes approved binaries to GitHub Packages. Cask CI checks syntax,
policy, URL/checksum behavior, and installability where feasible; `livecheck` and
scheduled autobump workflows reduce manual release tracking. Custom taps can reuse
Homebrew's GitHub Actions.

### Supply chain and reproducibility

Formula checksums, resource hashes, pinned revisions, isolated `superenv`, tests, and
bottle hashes provide strong inputs, but recipes can still run arbitrary upstream build
systems. Bottles improve repeatable installation without proving reproducible
compilation; consumers trust the bottle builder and registry. Casks normally install
vendor bytes rather than rebuilding them, so trust rests on URL provenance, immutable
checksums, vendor signatures/notarization, and review. `:no_check`, mutable URLs,
privileged PKG scripts, and third-party taps are explicit high-risk seams.

### Extensibility and UX

The Ruby DSL, artifact classes, `on_macos`/`on_arm` conditionals, services,
`livecheck` strategies, external commands, and taps are highly extensible. The user
still sees one vocabulary—`install`, `upgrade`, `uninstall`, `info`, `search`—across
source packages and GUI apps. That uniformity can hide semantic differences: Cask
`zap` is destructive user-state cleanup, a vendor auto-updater can race package-manager
policy, and a PKG executes outside the cask sandbox.

## Strengths

- One discoverable CLI covers source builds, bottles, and vendor macOS applications.
- Versioned kegs and symlink activation make Formula upgrades and rollback tractable.
- Checksums, scoped dependencies, tests, bottles, audits, and CI form a mature pipeline.
- Casks preserve upstream notarized bundles instead of wrapping them unnecessarily.
- Taps decentralize catalogs and custom commands without forking the client.

## Weaknesses

- Formula/Cask uniform UX masks very different installation and trust semantics.
- Ruby recipes and third-party taps are executable supply-chain inputs.
- Cask PKGs and installer scripts can write broadly and are not cask-sandboxed.
- Cask uninstall is only as complete as declared artifacts; `zap` can over-delete.
- `version :latest`/`:no_check` sacrifices immutable checksum verification.
- Bottles are trusted binary outputs, not automatic reproducible-build proofs.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                | Trade-off                                                  |
| ------------------------------------------ | -------------------------------------------------------- | ---------------------------------------------------------- |
| Formula and Cask as separate DSL contracts | Distinguish owned builds from vendor artifact activation | Similar CLI can obscure different trust/uninstall behavior |
| Versioned Cellar kegs plus prefix links    | Atomic active-version switching and coexistence          | Relocation/linkage rewriting complexity                    |
| Bottles as prebuilt kegs                   | Fast installs while retaining Formula source recipe      | Trust shifts to CI builder and registry                    |
| Cask SHA-256 plus vendor signature         | Bind catalog review to exact upstream bytes              | Mutable “latest” downloads cannot use this guarantee       |
| `auto_updates` declaration                 | Avoid fighting a vendor's in-app updater                 | Split ownership of channel and version state               |
| Optional `zap`                             | Offer complete cleanup when explicitly requested         | Can delete user data or shared resources                   |
| Git/API taps                               | Decentralized extension and efficient official metadata  | Third-party catalog code has variable governance           |

## Sources

- [Homebrew/brew at pinned SHA][brew-sha]
- [Formula Cookbook at pinned SHA][formula-cookbook]
- [Cask Cookbook at pinned SHA][cask-cookbook]
- [Bottles documentation at pinned SHA][bottles]
- [Taps documentation at pinned SHA][taps]
- [Formula API source at pinned SHA][formula-api]
- [Cask API source at pinned SHA][cask-api]
- [homebrew-core at pinned SHA][core-sha] and [homebrew-cask at pinned SHA][cask-sha]
- [`gocloc` Formula snapshot][formula-example] and [`jbrowse` Cask snapshot][cask-example]
- Related: [application bundles][bundles] · [DMG, PKG, and XIP][containers] ·
  [signing and notarization][signing]

<!-- References -->

[brew-repo]: https://github.com/Homebrew/brew
[brew-docs]: https://docs.brew.sh/
[core-repo]: https://github.com/Homebrew/homebrew-core
[cask-repo]: https://github.com/Homebrew/homebrew-cask
[brew-sha]: https://github.com/Homebrew/brew/tree/586f1c222e5569e639deeb3a8effdbc83fea0895
[core-sha]: https://github.com/Homebrew/homebrew-core/tree/2d16a4b686030251a4b801338d28948b1ba690b5
[cask-sha]: https://github.com/Homebrew/homebrew-cask/tree/4efd5887040f7cc964f5ed16b2bcdc8aecc7cf4c
[formula-cookbook]: https://github.com/Homebrew/brew/blob/586f1c222e5569e639deeb3a8effdbc83fea0895/docs/Formula-Cookbook.md
[cask-cookbook]: https://github.com/Homebrew/brew/blob/586f1c222e5569e639deeb3a8effdbc83fea0895/docs/Cask-Cookbook.md
[bottles]: https://github.com/Homebrew/brew/blob/586f1c222e5569e639deeb3a8effdbc83fea0895/docs/Bottles.md
[taps]: https://github.com/Homebrew/brew/blob/586f1c222e5569e639deeb3a8effdbc83fea0895/docs/Taps.md
[formula-api]: https://github.com/Homebrew/brew/blob/586f1c222e5569e639deeb3a8effdbc83fea0895/Library/Homebrew/api/formula.rb
[cask-api]: https://github.com/Homebrew/brew/blob/586f1c222e5569e639deeb3a8effdbc83fea0895/Library/Homebrew/api/cask.rb
[formula-example]: https://github.com/Homebrew/homebrew-core/blob/2d16a4b686030251a4b801338d28948b1ba690b5/Formula/g/gocloc.rb
[cask-example]: https://github.com/Homebrew/homebrew-cask/blob/4efd5887040f7cc964f5ed16b2bcdc8aecc7cf4c/Casks/j/jbrowse.rb
[bundles]: ./macos-app-bundles.md
[containers]: ./macos-dmg-pkg-xip.md
[signing]: ./macos-signing-notarization.md
