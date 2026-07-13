# APT, RPM, and pacman repositories (Linux distribution channels)

Linux repositories turn native package files into signed, discoverable update channels;
OBS, COPR, PPAs, and AUR occupy different build/catalog roles around those protocols.

| Field                     | Value                                                                                                                                                                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repository protocols      | APT archive metadata; RPM-MD; `pacman` sync databases                                                                                                                                                                                             |
| Languages                 | C/C++, Python, Perl, Ruby, shell, and service-specific web stacks                                                                                                                                                                                 |
| Licenses                  | Open-source GPL-family and component-specific licenses; see each pinned upstream tree                                                                                                                                                             |
| Reference implementations | [APT][apt-repo], [`createrepo_c`][createrepo-repo], and [`repo-add`/`libalpm`][pacman-repo]                                                                                                                                                       |
| Hosted services/catalogs  | [Open Build Service][obs-repo], [Fedora COPR][copr-repo], [Launchpad PPAs][launchpad-repo], and [Arch User Repository][aurweb-repo]                                                                                                               |
| Documentation             | Checked-in manuals, architecture documents, schemas, publisher implementations, and service documentation at the linked revisions                                                                                                                 |
| Primary index roots       | `dists/<suite>/Release` plus `Packages`/`Sources`; `repodata/repomd.xml`; `<repo>.db` plus optional `<repo>.files`                                                                                                                                |
| Trust anchors             | OpenPGP-signed `InRelease`/`Release.gpg`; signed `repomd.xml` plus RPM package signatures; detached database/package signatures                                                                                                                   |
| Reviewed revisions        | APT [`4c20fd71`][apt-sha] · `createrepo_c` [`b5b5d472`][createrepo-sha] · `pacman` [`a6f7467d`][pacman-sha] · OBS [`a63d809b`][obs-sha] · COPR [`e366be57`][copr-sha] · Launchpad [`7cbed6e1`][launchpad-sha] · `aurweb` [`4438072f`][aurweb-sha] |
| Category                  | Binary repository formats, archive trust, hosted build/publish services, and source-recipe catalog                                                                                                                                                |
| Supported hosts/targets   | HTTP/file mirrors are platform-neutral; repository generation and hosted builders publish distribution-, release-, architecture-, and format-specific views                                                                                       |
| OSS/paid boundary         | All implementations reviewed are open source; hosted instances may impose quotas/policy, and official distribution inclusion remains a separate governance process                                                                                |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **A recipe catalog is not a binary repository.** APT, RPM-MD, and `pacman` repository
> databases index downloadable binary packages. OBS, COPR, and PPAs accept source/build
> inputs and publish binary repositories. AUR stores community `PKGBUILD` recipes that a
> user or helper builds; it does not become a binary repository merely because `pacman`
> installs the result.

## Overview

### What it solves

A directory full of package files cannot answer candidate selection, architecture,
dependencies, freshness, or trust efficiently. A repository publishes compact indexes
that map package identity/version to immutable package bytes, then authenticates the
index snapshot. Clients cache metadata, solve against it, retrieve selected artifacts,
verify their digests/signatures, and commit a native package transaction.

APT's checked-in trust documentation describes the key distinction verbatim:

> “`apt-secure` does not review signatures at a package level.” —
> [`doc/apt-secure.8.xml`][apt-secure-config]

Instead, APT verifies a signed `Release` view whose hashes bind `Packages` files, whose
entries bind `.deb` files. RPM ecosystems can verify both a signed RPM-MD root and
embedded RPM signatures. `pacman` can require signatures independently for repository
databases and packages. In every case, repository signing authenticates a publisher and
snapshot; it does not prove that indexed software is safe.

### Design philosophy

The shared design is a **small signed root over content-addressed or digest-addressed
metadata**. Mirrors may be untrusted because clients authenticate the metadata graph.
Publication should expose a coherent generation: package blobs first, subordinate
indexes next, signed root last. Retention and by-hash/content-addressed paths keep a
client that fetched one root from racing into another generation.

Hosted services add a build control plane, not a new package format. OBS's own README
states:

> “The Open Build Service (OBS) is a generic system to build and distribute binary
> packages from sources in an automatic, consistent, and reproducible way.” —
> [`README.md`][obs-readme]

COPR narrows that model to community RPM projects; Launchpad PPAs build and publish
Debian-family archives; AUR deliberately stops at community build scripts.

## How it works

### APT archives

A conventional archive separates package blobs from distribution views:

```text
pool/main/s/sparkles/sparkles_0.4.0-2_amd64.deb
dists/stable/InRelease
dists/stable/Release
dists/stable/Release.gpg
dists/stable/main/binary-amd64/Packages.xz
dists/stable/main/source/Sources.xz
dists/stable/main/Contents-amd64.xz
```

`pool/` permits package files to be shared across suites. Under `dists/`, a **suite** or
codename selects a release view, **components** such as `main` partition policy/content,
and `binary-<architecture>` selects architecture. Flat repositories can instead expose a
single `Packages` path, but lose the standard suite/component topology.

A `Packages` stanza repeats binary control metadata and adds transport fields such as
`Filename`, `Size`, and checksums. `Sources` indexes source package files and build
metadata. `Contents` maps installed paths to packages and is optional for installation.
Translations and other index targets are extensible; APT's `Acquire::IndexTargets`
document shows `Packages`, `Sources`, and optional data as separately acquired targets
[in `acquire-additional-files.md`][apt-index-targets].

`Release` identifies `Origin`, `Label`, `Suite`, `Codename`, `Version`,
`Architectures`, and `Components`, and hashes every subordinate index. `InRelease` is a
clear-signed `Release`; `Release.gpg` is the detached-signature alternative. APT's own
publisher instructions are:

```bash
gpg --clearsign -o InRelease Release
gpg -abs -o Release.gpg Release
```

— [`apt-secure(8)`][apt-secure-config]. Clients should scope a repository's key with
`Signed-By` in its `.sources` stanza or a dedicated keyring, rather than treating one
third-party key as globally authoritative.

Freshness and consistency are part of trust. `Valid-Until` bounds replay of stale
metadata. `Acquire-By-Hash` advertises hash-named index paths so old and new generations
can coexist while mirrors synchronize. APT refuses a previously authenticated repository
that becomes unsigned by default and requires confirmation when release identity fields
change [in `apt-secure(8)`][apt-secure-config]. Pin priorities and `NotAutomatic`/
`ButAutomaticUpgrades` influence candidate/channel policy; they do not alter package
version ordering.

### RPM-MD repositories

A minimal RPM-MD tree is:

```text
Packages/s/sparkles-0.4.0-2.fc42.x86_64.rpm
repodata/repomd.xml
repodata/<checksum>-primary.xml.zst
repodata/<checksum>-filelists.xml.zst
repodata/<checksum>-other.xml.zst
repodata/repomd.xml.asc
```

`repomd.xml` is the root manifest: each `<data type="…">` record gives a location,
digest, open digest where applicable, size, and timestamp for a metadata object.
`primary` carries package identity, checksum/location, summary, and dependency
capabilities; `filelists` carries file ownership/search data; `other` carries changelog
metadata. Optional records include `updateinfo` advisories, `comps` groups, module data,
deltas, and SQLite variants. `createrepo_c` explicitly distinguishes the core
`primary`, `filelists`, and `other` sets from “additional metadata”
[in its manual][createrepo-man].

Yum/DNF/Zypper repository configuration selects `baseurl`, `mirrorlist`, or `metalink`,
plus enabled/priority/cost and key policy. `gpgcheck` verifies package signatures;
`repo_gpgcheck` verifies repository metadata where supported. These are independent:
signing only RPMs does not authenticate which versions a mirror advertises, while
signing only `repomd.xml` does not supply an independent per-package publisher signature.
The root is commonly detached-signed (`repomd.xml.asc`), and its hashes bind the
subordinate metadata and RPM checksums.

`createrepo_c` builds a new metadata generation in a temporary `.repodata.*` area and
moves it into place; its `--update` and retention options reuse/retain data. Publication
still needs package-first/root-last ordering and CDN/mirror cache discipline. Mutating an
RPM or index after generation breaks the corresponding digest chain.

### pacman repositories

A `pacman` repository is intentionally compact:

```text
x86_64/sparkles-0.4.0-2-x86_64.pkg.tar.zst
x86_64/sparkles-0.4.0-2-x86_64.pkg.tar.zst.sig
x86_64/sparkles.db
x86_64/sparkles.db.sig
x86_64/sparkles.files
```

`repo-add` reads built package metadata and updates a compressed tar database. Its manual
says, “A package database is a tar file, optionally compressed,” and notes that matching
package `.sig` data can be embedded [in `repo-add(8)`][repo-add]. The smaller `.db`
contains package descriptions and dependencies used by synchronization; `.files` adds
file lists for `pacman -F`. `repo-add --sign` generates a detached OpenPGP signature for
the database, while packages can have their own detached signatures.

A `[repository]` section in `pacman.conf` lists one or more `Server` URLs. `$repo` and
`$arch` expand into mirror paths; repository order resolves duplicate names. `SigLevel`
can separately require trusted signatures for packages and databases, and `Usage`
controls refresh, search, install, and sysupgrade participation
[in `pacman.conf(5)`][pacman-conf]. `pacman -Sy` downloads a fresh whole sync database;
`pacman -Syu` then solves and upgrades against that synchronized view. Publishing only
one package without updating/re-signing `.db` leaves it undiscoverable.

### Hosted build, publication, and catalog roles

| Service/catalog | Input owned by project                                  | Service output                               | Binary repository? | Official distribution inclusion?    |
| --------------- | ------------------------------------------------------- | -------------------------------------------- | ------------------ | ----------------------------------- |
| OBS             | Source package/recipe, project/repository target matrix | Built DEB/RPM/Arch and other repositories    | Yes                | No; an OBS project is separate      |
| COPR            | SRPM/spec, SCM, or supported source method and chroots  | Signed RPMs and RPM-MD repositories          | Yes                | No; COPR is community hosting       |
| Launchpad PPA   | Signed Debian source upload and Ubuntu series targets   | Built `.deb` files and signed APT archive    | Yes                | No; a PPA is outside Ubuntu archive |
| AUR             | Git repository containing `PKGBUILD` and `.SRCINFO`     | Search/review/community metadata for recipes | **No**             | No; user builds resulting package   |

#### Open Build Service

OBS separates a backend that schedules/builds/publishes from a web/XML API frontend and
the separate `osc` client [in its README][obs-readme]. Projects declare repositories,
architectures, dependency paths, and source packages. Workers build per
repository-architecture cell; publisher code then selects format backends.
`bs_publish` calls RPM-MD generation, creates Debian `Packages`/`Sources`/`Release`, and
has a distinct Arch repository path [in `src/backend/bs_publish`][obs-publisher]. It can
sign `repomd.xml` and repository/package outputs when a signing service is configured.

OBS is therefore a multi-distribution build-and-publish control plane. It can host a
vendor's repositories, but it does not make those packages part of openSUSE, Debian,
Fedora, or Arch official repositories. Project/repository names form build dependency
and publication namespaces; promotion between projects remains an explicit release
operation.

#### Fedora COPR

COPR's source description is concise:

> “Copr (‘Community projects’) is a service that builds your open-source projects and
> creates your own RPM repositories.” — [`README.md`][copr-readme]

A project chooses build chroots such as Fedora/EPEL release and architecture cells.
Builders produce source and binary RPMs in isolated `mock` roots; backend/key service
signs results and regenerates repository metadata. The architecture document shows source
processing, SRPM import, fan-out to RPM build tasks, signing, then placement in an RPM
repository [in `architecture.rst`][copr-architecture].

COPR is excellent for third-party RPM channels and CI-triggered rebuilds. It is not the
Fedora package collection, Bodhi update process, or a promise of Fedora QA/support.
Enabling a COPR grants that project repository authority on the client, so projects must
communicate owner, key, target chroot, and lifecycle clearly.

#### Launchpad PPAs

A PPA is an APT archive attached to a person/team in Launchpad. The producer uploads
Debian source-package material, Launchpad schedules architecture builds, publishes source
and binary records, generates `Sources` and `Packages`, creates `Release`, and emits
`InRelease`/`Release.gpg`. These are implementation facts in Launchpad's
[`indices.py`][launchpad-indices], [`publishing.py`][launchpad-publishing], and archive
signing code [at the pinned revision][launchpad-signing].

The result composes with ordinary Ubuntu APT tooling, but it is a separately trusted
archive under `ppa.launchpadcontent.net`; it is not an Ubuntu archive component and does
not inherit Ubuntu's official review/support merely by using Launchpad builders. A PPA
may build against Ubuntu and configured PPA dependencies, which can make its binary set
series-specific and coupled to another third-party channel.

#### Arch User Repository

`aurweb` defines the AUR unambiguously:

> “a collection of packaging scripts that are created and submitted by the Arch Linux
> community.” — [`README.md`][aurweb-readme]

Each package base is exposed as Git and must contain `PKGBUILD`; `.SRCINFO` supplies
parseable metadata to the web service. Users inspect/clone the recipe and run `makepkg`,
possibly through an AUR helper. The downloaded upstream source and resulting package are
not hosted as a normal AUR binary repository. The user's build/signing environment owns
the binary evidence, and `pacman` only sees the locally built package afterward.

A private automation service can build AUR recipes and publish the results through
`repo-add`, but that new service is an independent binary repository with its own keys,
rebuild policy, and trust. It must not describe its binaries as “from AUR” in a way that
implies AUR built or signed them.

## Analysis spine

### Input and staging

APT/RPM-MD/`pacman` repository generators consume **finished immutable packages** and
channel metadata; they do not stage application payloads. OBS/COPR/PPA additionally
consume source recipes/uploads and own clean build roots before repository generation.
AUR consumes recipes only and delegates staging/building to each user.

The reliable release boundary is: build and test package → sign package where applicable
→ place immutable package blob → generate indexes from exactly those bytes → sign root
metadata → publish root last. Regenerating metadata from an incompletely synchronized
package directory creates advertised-but-unavailable candidates.

### Outputs and target matrix

APT partitions suites, components, source, and binary architectures. RPM-MD normally
uses one repository root per distribution/release/architecture or a carefully modeled
multilib view. `pacman` mirror layouts conventionally separate `$repo/os/$arch`. Hosted
builders fan one source revision out over these cells and can publish only successful
cells.

Repository URL, suite/chroot, architecture, and signing identity together define a
channel. Reusing one path for incompatible distributions makes dependency resolution
appear valid until install time; explicit matrix cells are safer.

### Metadata and dependencies

Repository indexes copy enough native metadata for solving without downloading every
package. APT `Packages` carries Debian relationships; RPM `primary` carries capability
relationships; a `pacman` `.db` carries `.PKGINFO`-derived dependencies. The index must
preserve each package system's version semantics rather than normalize to SemVer.

Source indexes and recipe catalogs are different. APT `Sources` references published
source artifacts; an SRPM can be indexed as a package artifact; AUR Git holds executable
recipes. None of those alone tells a binary client that an installable build exists.

### Installation, upgrade, and uninstall

Repositories do not install files. They provide candidate and transport metadata to APT,
DNF/Yum/Zypper, or `pacman`, which solve and delegate to the native transaction layer
described in [Linux native packages][linux-native]. Removing a repository
does not uninstall its packages, and deleting an indexed version can strand installed
clients without an upgrade/downgrade path.

Promotion should copy an already-tested immutable package between channel views rather
than rebuild it. Rebuilding “the same version” changes digest/provenance and can collide
with client caches and package-manager assumptions.

### Signing and platform trust

| Ecosystem | Signed root/database                     | Package binding                                                   | Freshness/replay mechanism                           |
| --------- | ---------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------- |
| APT       | `InRelease` or `Release` + `Release.gpg` | `Release` hashes `Packages`; stanza hashes `.deb`                 | `Valid-Until`, date, by-hash, identity checks        |
| RPM-MD    | Usually `repomd.xml.asc`                 | `repomd` hashes metadata; metadata hashes RPM; RPM may be signed  | metadata expiry/cache policy and metalink timestamps |
| pacman    | `<repo>.db.sig` according to `SigLevel`  | DB contains package metadata/signature; package `.sig` separately | refreshed whole DB; mirror/key policy                |

A key must be scoped to the intended repository. APT `Signed-By`, RPM repo `gpgkey` plus
verification settings, and `pacman` keyring/trust policy prevent one third-party key from
silently authorizing unrelated channels. Key rotation requires overlap and signed,
well-documented transition; merely replacing a key URL can be intercepted at the same
trust boundary.

Hosted builder trust is additional: a service key authenticates what the service
published, while source upload signatures, build logs, SBOMs, and provenance explain why
those bytes should be trusted.

### Publication and discovery

APT sources are registered through `.sources`/`.list`; RPM repositories through `.repo`
files or package-manager commands; `pacman` repositories through ordered configuration
sections. OBS/COPR/PPA provide repository endpoints and onboarding snippets. AUR is
discovered through `aurweb` search/RPC/Git, not `pacman -S` against a binary sync DB.

Discovery text must state whether the channel is official, vendor-operated, community
built, or only a recipe catalog. “Available for Fedora/Ubuntu/Arch” does not imply
inclusion in those distributions.

### Updates and release channels

Suites/repos/projects naturally encode stable, beta, nightly, per-release, or per-owner
channels. APT release fields and pinning, RPM repository priority/cost/module/advisory
metadata, and `pacman` repository order affect candidate choice. They should supplement,
not fight, monotonic package versions.

Retain previous artifacts long enough for mirrors, caches, staged rollout, and rollback.
APT by-hash paths address index-generation races; content-checksummed RPM-MD filenames
allow generations to coexist; `pacman`'s whole database requires careful atomic
replacement and package retention.

### Automation and CI

Repository CI should validate:

1. every indexed path exists and its size/digest matches;
2. root and package signatures verify using only the documented scoped key;
3. metadata parses with the native client;
4. a clean client can refresh, solve, download, install, upgrade, and remove;
5. stale, unsigned, wrong-key, and partially published generations fail closed;
6. all advertised distribution/architecture cells are install-tested;
7. promotion preserves package digests and provenance.

OBS, COPR, and PPA automate large parts of build/index/sign/publish. They do not remove
the need for application-level upgrade tests or release fan-in that refuses to promote a
partial target matrix.

### Supply-chain evidence and reproducibility

A signed repository records publisher authorization over a snapshot, not source identity
or deterministic construction. Package checksums, source package/recipe revisions, build
logs, `.buildinfo`/`.BUILDINFO`, SBOMs, and provenance should be linked by immutable
digests. OBS claims reproducible intent; actual bit-for-bit reproducibility remains a
per-package, per-builder result requiring independent rebuild evidence.

AUR has the largest trust gap by design: recipe review and upstream checksum/signature
verification precede a local build, but no central AUR binary signature exists. A binary
cache derived from AUR must publish its own builder provenance and must own vulnerability
rebuilds.

### Extensibility and UX

APT adds index targets and release fields; RPM-MD adds typed metadata records such as
`updateinfo` and `comps`; `pacman` keeps a small database plus optional file index. OBS
supports multiple build and repository backends; COPR exposes source methods/chroots;
PPAs reuse Debian archive machinery; AUR exposes Git, SSH submission, RPC, comments,
votes, and maintenance workflows around recipes.

For users, a signed native repository gives the strongest update UX: add a scoped source
once, then use normal system updates. The corresponding security burden is long-lived:
the publisher controls future candidates for every package identity in that repository.

## Strengths

- Compact signed metadata scales package discovery across mirrors and architectures.
- Native clients integrate dependency solving, cache policy, update selection, and
  installed-state transactions.
- Separate suites/repositories provide explicit release channels and promotion points.
- OBS, COPR, and PPAs can turn reviewed source inputs into repeatable target matrices and
  immediately consumable repositories.
- AUR maximizes transparent community recipe collaboration without pretending to be a
  central binary builder.

## Weaknesses

- Repository keys are high-impact online release authority and require rotation,
  isolation, and scoped client configuration.
- Metadata/package/mirror publication races can break clients unless generations are
  atomic or content-addressed.
- Third-party hosted repositories are easy to mistake for official distribution
  inclusion and support.
- Channel deletion or short retention can strand clients and eliminate rollback paths.
- AUR convenience helpers can hide the crucial recipe-review and local-build boundary.
- Repository signatures do not provide source provenance, SBOMs, or reproducibility by
  themselves.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                        | Trade-off                                                          |
| ----------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------ |
| Signed root over hashed subordinate indexes     | Authenticate large mirrored archives efficiently                 | Root key compromise authorizes the whole snapshot                  |
| Package blobs separate from release views       | Reuse immutable bytes across suites/channels                     | Garbage collection and retention require reference tracking        |
| Publish packages and indexes before signed root | Keep every advertised snapshot internally coherent               | Publication pipeline needs atomic promotion and retry discipline   |
| Per-distribution/release/architecture views     | Match native dependency and ABI universes                        | Multiplies build, test, and retention work                         |
| Separate package and repository verification    | Authenticate both artifact producer and advertised candidate set | Two key policies and failure modes                                 |
| Hosted source-to-repository services            | Centralize clean builders, fan-out, signing, and metadata        | Adds service governance, quotas, and builder trust                 |
| AUR as recipes rather than binaries             | Keep community packaging inspectable and user-built              | Slow builds, variable environments, and no central binary evidence |
| Promotion without rebuilding                    | Preserve tested digest and provenance across channels            | Requires immutable artifact storage and explicit channel metadata  |

## Sources

- `[source-verified]` APT at `4c20fd71d647ea8289daa4e117f8d48a03b366bc`
  (`$REPOS/packaging-research/linux/apt`): `doc/apt-secure.8.xml`,
  `doc/apt-ftparchive.1.xml`, `doc/acquire-additional-files.md`,
  `doc/sources.list.5.xml`, and `doc/apt.conf.5.xml`.
- `[source-verified]` `createrepo_c` at
  `b5b5d4720e599531a5fec90bbdc1b5e1a022657e`
  (`$REPOS/packaging-research/linux/createrepo_c`): `doc/createrepo_c.8.in`,
  `src/cmd_parser.c`, and RPM-MD parser/dumper sources.
- `[source-verified]` `pacman` at
  `a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d`
  (`$REPOS/packaging-research/linux/pacman`): `doc/repo-add.8.asciidoc`,
  `doc/pacman.conf.5.asciidoc`, and `doc/pacman.8.asciidoc`.
- `[source-verified]` Open Build Service at
  `a63d809b3a5937c367094ea15eb94c5893cc30ab`
  (`$REPOS/packaging-research/linux/open-build-service`): `README.md`,
  `src/backend/bs_publish`, publisher/signer configuration, and API repository schemas.
- `[source-verified]` COPR at `e366be57e530df0497040a393da8345840924643`
  (`$REPOS/packaging-research/linux/copr`): `README.md`,
  `doc/developer_documentation/architecture.rst`, and `doc/createrepo.rst`.
- `[source-verified]` Launchpad at
  `7cbed6e13f6cda8233e876935bcf16273b753df1`
  (`$REPOS/packaging-research/linux/launchpad`): `lib/lp/archivepublisher/indices.py`,
  `publishing.py`, `archivegpgsigningkey.py`, and PPA upload tests.
- `[source-verified]` `aurweb` at
  `4438072f1b205706ddeb1b3aef3283d3d4f050d5`
  (`$REPOS/packaging-research/linux/aurweb`): `README.md`,
  `doc/git-interface.txt`, and `aurweb/git/update.py`.
- `[unverified]` No hosted service was exercised and no repository was published for
  this page; findings are source verified, not host verified.

<!-- References -->

[apt-index-targets]: https://salsa.debian.org/apt-team/apt/-/blob/4c20fd71d647ea8289daa4e117f8d48a03b366bc/doc/acquire-additional-files.md
[apt-repo]: https://salsa.debian.org/apt-team/apt
[apt-secure-config]: https://salsa.debian.org/apt-team/apt/-/blob/4c20fd71d647ea8289daa4e117f8d48a03b366bc/doc/apt-secure.8.xml
[apt-sha]: https://salsa.debian.org/apt-team/apt/-/commit/4c20fd71d647ea8289daa4e117f8d48a03b366bc
[aurweb-readme]: https://gitlab.archlinux.org/archlinux/aurweb/-/blob/4438072f1b205706ddeb1b3aef3283d3d4f050d5/README.md
[aurweb-repo]: https://gitlab.archlinux.org/archlinux/aurweb
[aurweb-sha]: https://gitlab.archlinux.org/archlinux/aurweb/-/commit/4438072f1b205706ddeb1b3aef3283d3d4f050d5
[copr-architecture]: https://github.com/fedora-copr/copr/blob/e366be57e530df0497040a393da8345840924643/doc/developer_documentation/architecture.rst
[copr-readme]: https://github.com/fedora-copr/copr/blob/e366be57e530df0497040a393da8345840924643/README.md
[copr-repo]: https://github.com/fedora-copr/copr
[copr-sha]: https://github.com/fedora-copr/copr/commit/e366be57e530df0497040a393da8345840924643
[createrepo-man]: https://github.com/rpm-software-management/createrepo_c/blob/b5b5d4720e599531a5fec90bbdc1b5e1a022657e/doc/createrepo_c.8.in
[createrepo-repo]: https://github.com/rpm-software-management/createrepo_c
[createrepo-sha]: https://github.com/rpm-software-management/createrepo_c/commit/b5b5d4720e599531a5fec90bbdc1b5e1a022657e
[launchpad-indices]: https://git.launchpad.net/launchpad/tree/lib/lp/archivepublisher/indices.py?id=7cbed6e13f6cda8233e876935bcf16273b753df1
[linux-native]: ./linux-native-packages.md
[launchpad-publishing]: https://git.launchpad.net/launchpad/tree/lib/lp/archivepublisher/publishing.py?id=7cbed6e13f6cda8233e876935bcf16273b753df1
[launchpad-repo]: https://git.launchpad.net/launchpad
[launchpad-sha]: https://git.launchpad.net/launchpad/commit/?id=7cbed6e13f6cda8233e876935bcf16273b753df1
[launchpad-signing]: https://git.launchpad.net/launchpad/tree/lib/lp/archivepublisher/archivegpgsigningkey.py?id=7cbed6e13f6cda8233e876935bcf16273b753df1
[obs-publisher]: https://github.com/openSUSE/open-build-service/blob/a63d809b3a5937c367094ea15eb94c5893cc30ab/src/backend/bs_publish
[obs-readme]: https://github.com/openSUSE/open-build-service/blob/a63d809b3a5937c367094ea15eb94c5893cc30ab/README.md
[obs-repo]: https://github.com/openSUSE/open-build-service
[obs-sha]: https://github.com/openSUSE/open-build-service/commit/a63d809b3a5937c367094ea15eb94c5893cc30ab
[pacman-conf]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/pacman.conf.5.asciidoc
[pacman-repo]: https://gitlab.archlinux.org/pacman/pacman
[pacman-sha]: https://gitlab.archlinux.org/pacman/pacman/-/commit/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d
[repo-add]: https://gitlab.archlinux.org/pacman/pacman/-/blob/a6f7467d8c7c4d7e9cc846884e74c0ab7215c48d/doc/repo-add.8.asciidoc
