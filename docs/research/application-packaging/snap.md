# Snap (confined Linux application package and Store channel system)

Snap combines a read-only SquashFS application package with `snapd`-managed mounting,
confinement, interfaces, signed assertions, transactional refresh/revert, and a Store
channel model; Snapcraft turns `snapcraft.yaml` projects into those packages and
publishes revisions.

| Field                   | Value                                                                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                | Go (`snapd`); Python (Snapcraft)                                                                                                            |
| License                 | GPL-3.0 (`snapd` and Snapcraft)                                                                                                             |
| Repositories            | [canonical/snapd][snapd-repo] · [canonical/snapcraft][snapcraft-repo]                                                                       |
| Documentation           | [Pinned Snapcraft documentation][snapcraft-sha] and [snapd API/source][snapd-sha]                                                           |
| Reviewed revisions      | snapd [`ccbc0c3d`][snapd-sha] (`2.76-211-gccbc0c3d59`) · Snapcraft [`429f6289`][snapcraft-sha] (`9.0.0-52-g429f62894`)                      |
| Package/output          | SquashFS `.snap` plus Store assertions for published revisions                                                                              |
| Category                | Sandboxed package, system daemon, assertion trust system, and hosted Store channels                                                         |
| Supported hosts/targets | Linux systems supported by `snapd`; builds/releases are architecture-specific or architecture-declared                                      |
| OSS/paid boundary       | snapd and Snapcraft are open source; the primary Snap Store is Canonical-operated, with private-store services outside the client/tool core |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Snap gives publishers one package recipe and Store release workflow while giving the host
a daemon that owns installation, mount activation, permission connections, refresh,
rollback data, services, aliases, and removal. Snapcraft describes its build input in the
checked-in README:

> “A snap's build configuration is stored in simple language as a project file called
> `snapcraft.yaml`.” — [Snapcraft `README.md`][snapcraft-readme]

Unlike a portable image, a snap is normally installed into `snapd`'s state and identified
by a Store-assigned snap ID/revision. Unlike Flatpak, its scope includes CLI tools,
daemons, kernels, bases, and Ubuntu Core system components as well as desktop apps.

### Design philosophy

The immutable application image is only one layer. A declared **base snap** supplies the
runtime root for strict confinement; application content mounts at `$SNAP`; writable
system/user state lives under `$SNAP_DATA`, `$SNAP_COMMON`, `$SNAP_USER_DATA`, and
`$SNAP_USER_COMMON`. **Plugs** request capabilities and **slots** provide them; snapd
policy connects compatible interfaces and compiles AppArmor, seccomp, device-cgroup,
mount-namespace, and related enforcement. Signed assertions bind Store identity and
revision hashes to the device trust root.

## How it works

A minimal project names metadata, base, confinement, apps, plugs, and build parts:

```yaml
name: example
base: core24
version: '1.2.3'
summary: Example application
description: Example desktop application.
grade: stable
confinement: strict

apps:
  example:
    command: bin/example
    plugs: [network, wayland, desktop, desktop-legacy, opengl]

parts:
  example:
    plugin: dump
    source: build/stage
```

Snapcraft's lifecycle pulls and builds parts, stages their files together, primes the
final payload, generates metadata, runs linters, and packs SquashFS. A base defines both
build assumptions and, for strict snaps, the runtime root filesystem
[source-verified: [base documentation][bases]]. `stage-packages` bring distribution
packages into staging; plugins and overrides control source-specific build behavior.

On installation, snapd verifies Store assertions, mounts the revision read-only under
`/snap/NAME/REVISION`, maintains `/snap/NAME/current`, generates wrappers/services and
security policy, and connects allowed interfaces. The Store assigns monotonically
increasing revisions independently of the publisher's human `version`. A channel is
`TRACK/RISK[/BRANCH]`, for example `2.0/stable` or `latest/edge/pr-42`; releasing a
revision moves a channel pointer rather than rebuilding bytes
[source-verified: [channel reference][channels]].

## Analysis spine

### Input and staging

`snapcraft.yaml` supplies identity/version, base/build-base, target platforms, parts,
apps/hooks/services, plugs/slots, layouts, components, confinement, grade, and Store
metadata. Parts traverse pull, build, stage, and prime; filters decide which files move
between shared staging and final prime trees [source-verified: [build process][build-process]].
Inputs can include VCS/archive sources, local files, language plugins, and Ubuntu archive
packages. Reproducible staging requires pinning each source and package repository
snapshot; a package name in `stage-packages` alone follows the selected archive state.

### Outputs and target matrix

`snapcraft pack` emits a `.snap` SquashFS file. Store revisions are architecture-specific
unless metadata declares otherwise; one snap name can have revisions for several
architectures in the same channel. Bases couple applications to an Ubuntu-derived runtime
ABI, while the host kernel and snapd supply confinement and mounts. Snapcraft can use
local providers or remote-build services; cross-compilation support depends on plugin,
toolchain, and project, so native/emulated launch tests remain necessary.

Compatibility depends on more than bundled files: snapd version, Linux Security Module
support, distribution integration, base availability, interface implementations,
desktop helpers, graphics stack, and kernel features vary. Strict confinement is the
portable target on well-supported snapd distributions. Classic confinement deliberately
uses the host more directly and is not an escape hatch that can be assumed available:
Store publication requires review/approval for classic use
[source-verified: [classic confinement][classic]].

### Metadata and dependencies

The snap name is public catalog identity; Store assertions add an immutable snap ID and
publisher relationship. Publisher `version` is display metadata; Store `revision` orders
uploaded builds. `base` supplies runtime content, `content` interfaces can share
publisher-managed payloads, and staged packages vendor files inside the snap rather than
becoming host package-manager dependencies. Plugs/slots and app declarations are both
runtime metadata and security inputs. Layouts synthesize paths in the mount namespace
without mutating the read-only image.

### Installation, upgrade, and uninstall

`snap install` asks snapd to resolve a channel/revision, download and verify it, mount it,
create security profiles/wrappers, connect interfaces, and start declared services.
Refresh installs a new revision, runs hooks/state transitions, switches the active
revision, and retains prior revision data for revert policy. `snap revert` can reactivate
a retained revision. `snap remove` disables services, disconnects interfaces, and removes
package revisions; by default snapd can preserve a data snapshot for recovery, while
`--purge` avoids that snapshot. Application data is external to the SquashFS and must
honor version migration/backward-compatibility rules.

### Signing and platform trust

A locally built `.snap` is not made trustworthy merely by its SquashFS container.
Store-installed snaps arrive with an assertion chain: account/account-key trust,
`snap-declaration` identity/policy, and `snap-revision` binding a revision to its
SHA3-384 digest and provenance. snapd's [`AssertManager`][assert-manager] fetches and
cross-checks these assertions during validation [source-verified]. Sideloading with
`--dangerous` explicitly bypasses normal signed Store assertions; local testing must not
be presented as Store-equivalent verification. Publisher authentication and Store
credentials authorize upload/release but Store infrastructure signs accepted revision
assertions.

### Publication and discovery

`snapcraft register` reserves a name; `snapcraft upload` creates a Store revision;
`snapcraft release REVISION CHANNELS` moves channel pointers. `snapcraft upload
--release=CHANNEL` combines the last two operations. The Store supplies search,
publisher pages, metrics, review, declarations, and hosted delivery. Private snaps and
brand/private stores change access/governance, but the open-source client does not itself
provide a drop-in decentralized public repository protocol equivalent to an arbitrary
Flatpak remote.

### Updates and release channels

Channels have three nested axes: a track for a long-lived release line, risk
(`stable`, `candidate`, `beta`, `edge`), and optional temporary branch. Devices track one
channel and refresh when its pointer offers a suitable new revision. `snap refresh
--channel` changes tracking; `--revision` selects a revision where policy permits.
Refresh scheduling, holds, metered-network behavior, app-awareness, validation sets,
gating, and re-refresh are snapd policy—not publisher code. Promotion is pointer movement
of already uploaded immutable revisions, enabling build-once/promote without changing
bytes. Branches expire and are unsuitable as permanent channels.

### Automation and CI

CI typically builds once per architecture, runs tests/linters, uploads the exact file,
then releases its returned revision to a low-risk channel before promotion. Snapcraft's
own [`publish.yaml`][snapcraft-publish-ci] demonstrates Store credentials in an isolated
GitHub Actions environment and publishes ordinary builds to `latest/candidate` and
feature builds to `latest/edge/BRANCH`. Consumer workflows must block secrets on
untrusted pull requests, record upload revision/digest, separate upload from promotion,
and test install/refresh/revert/interface connections in disposable snapd hosts. Store
review can be asynchronous, especially for privileged interfaces or classic confinement.

### Supply-chain evidence and reproducibility

The Store assertion binds distributed bytes, identity, revision, and publisher trust;
it does not by itself attest source or make the build reproducible. `snapcraft.yaml`,
lockfiles, build logs, source hashes, base revision, staged package versions, `.snap`
digest, Store revision, and channel-release record form the minimum release ledger.
Snapcraft can produce SBOM-related metadata through evolving tooling, but projects should
publish and archive explicit SBOM/provenance rather than infer it from Store assertions.
SquashFS timestamps/order, package archive movement, plugin networks, and remote builders
must be controlled for byte-for-byte reproducibility.

### Extensibility and UX

Snapcraft plugins, extensions, lifecycle overrides, components, layouts, hooks, services,
and content snaps support many stacks and system roles. Interfaces give users/admins a
common `snap connections`, `snap connect`, and `snap disconnect` vocabulary. Auto-connect
policy can make safe common capabilities seamless; privileged interfaces require review
or manual action. Desktop snaps can also use xdg-desktop-portal—the portal test suite
explicitly supports snap metadata [source-verified: [portal tests][portal-tests]]—but
portals complement rather than replace snap interfaces: an interface enables access to
the D-Bus service, while the portal mediates individual user-facing requests.

## Strengths

- One daemon owns verified install, service setup, interface policy, refresh, and revert.
- Immutable revisions and channel pointers support build-once promotion across risks.
- Strict confinement combines several Linux enforcement mechanisms behind interfaces.
- Bases and staged dependencies reduce distribution variation for apps and daemons.
- Assertion chains bind Store identity and exact revision digest to trusted authority.
- Snapcraft parts/plugins and Store CI workflows cover diverse language stacks and targets.

## Weaknesses

- The primary distribution/control plane is a Canonical-operated Store rather than an
  arbitrary decentralized repository protocol.
- snapd, kernel security features, desktop integration, and base/interface availability
  create host compatibility constraints.
- Classic confinement weakens portability/security and requires Store approval.
- Automatic refresh ownership can conflict with long-running applications or operator
  maintenance policy despite holds and app-awareness controls.
- Store assertions authenticate distribution but do not prove reproducible/source builds.
- Interface declarations, auto-connect policy, Store review, and portal behavior add a
  larger policy surface than an ordinary archive.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                         | Trade-off                                             |
| --------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------- |
| Read-only SquashFS revisions                  | Immutable, mountable application payload          | Writable state must be external and migrated          |
| Base snaps                                    | Shared, versioned runtime ABI                     | Ubuntu-derived lifecycle and extra mounted content    |
| snapd-managed transaction                     | Consistent install/refresh/revert/services        | Requires privileged resident daemon/integration       |
| Interfaces and strict confinement             | Capability-oriented host access                   | Policy/auto-connect complexity and compatibility work |
| Classic confinement exception                 | Support host-integrated developer/system tools    | Much weaker isolation and Store review requirement    |
| Signed assertion chain                        | Bind Store identity, policy, revision, and digest | Trust/distribution centers on assertion authority     |
| Track/risk/branch channels                    | Build once, test, and promote immutable revisions | Publisher and device refresh policy can diverge       |
| Store-assigned revision separate from version | Unambiguous uploaded build ordering               | Two version concepts must be recorded and explained   |

## Sources

- snapd locally reviewed at `$REPOS/packaging/snapd`, revision
  [`ccbc0c3d`][snapd-sha]: assertion manager, interface implementations, refresh state,
  REST schemas, and integration tests.
- Snapcraft locally reviewed at `$REPOS/packaging/snapcraft`, revision
  [`429f6289`][snapcraft-sha]: [`README.md`][snapcraft-readme], bases, parts/build
  process, confinement/interfaces, channels, publishing, schemas, tests, and CI.
- xdg-desktop-portal locally reviewed at `$REPOS/packaging/xdg-desktop-portal`, revision
  [`c2528f73`][portal-sha], for Snap portal metadata integration tests.

<!-- References -->

[snapd-repo]: https://github.com/canonical/snapd
[snapcraft-repo]: https://github.com/canonical/snapcraft
[snapd-sha]: https://github.com/canonical/snapd/tree/ccbc0c3d5949f30939189a26b9842e5141956333
[snapcraft-sha]: https://github.com/canonical/snapcraft/tree/429f628949378c1c93434e8805310818e53ac752
[snapcraft-readme]: https://github.com/canonical/snapcraft/blob/429f628949378c1c93434e8805310818e53ac752/README.md
[bases]: https://github.com/canonical/snapcraft/blob/429f628949378c1c93434e8805310818e53ac752/docs/explanation/bases.rst
[build-process]: https://github.com/canonical/snapcraft/blob/429f628949378c1c93434e8805310818e53ac752/docs/explanation/snap-build-process.rst
[classic]: https://github.com/canonical/snapcraft/blob/429f628949378c1c93434e8805310818e53ac752/docs/explanation/classic-confinement.rst
[channels]: https://github.com/canonical/snapcraft/blob/429f628949378c1c93434e8805310818e53ac752/docs/reference/channels.rst
[assert-manager]: https://github.com/canonical/snapd/blob/ccbc0c3d5949f30939189a26b9842e5141956333/overlord/assertstate/assertmgr.go
[snapcraft-publish-ci]: https://github.com/canonical/snapcraft/blob/429f628949378c1c93434e8805310818e53ac752/.github/workflows/publish.yaml
[portal-sha]: https://github.com/flatpak/xdg-desktop-portal/tree/c2528f73a4f770f4655c3a259145e27ddb461d7f
[portal-tests]: https://github.com/flatpak/xdg-desktop-portal/blob/c2528f73a4f770f4655c3a259145e27ddb461d7f/tests/README.md
