# Flatpak (sandboxed Linux deployment and repository system)

Flatpak deploys desktop applications as versioned OSTree refs assembled against shared
runtimes, executes them in Bubblewrap sandboxes, mediates desktop access through declared
permissions and portals, and installs/updates them from cryptographically configured
remotes such as Flathub.

| Field                   | Value                                                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Language                | C (Flatpak), C (xdg-desktop-portal), C (flatpak-builder)                                                                              |
| License                 | LGPL-2.1-or-later (Flatpak and builder); LGPL-2.0-or-later (portal)                                                                   |
| Repositories            | [flatpak/flatpak][flatpak-repo] · [flatpak/flatpak-builder][builder-repo] · [flatpak/xdg-desktop-portal][portal-repo]                 |
| Documentation           | [flatpak/flatpak-docs][docs-repo] · [Flathub documentation][flathub-docs]                                                             |
| Reviewed revisions      | Flatpak [`478d355c`][flatpak-sha] · docs [`d2a17baa`][docs-sha] · builder [`213ae1dc`][builder-sha] · portal [`c2528f73`][portal-sha] |
| Category                | Sandboxed application deployment, runtime, and signed repository system                                                               |
| Supported hosts/targets | Linux host with Flatpak/Bubblewrap support; refs are separated by architecture and branch                                             |
| OSS/paid boundary       | Client, builder, portal, OSTree repositories, and Flathub service are open/community infrastructure; CI/hosting may be self-managed   |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

Flatpak gives Linux desktop publishers one application identity and build manifest across
distributions while moving most application dependencies into either a shared runtime or
the app's `/app` deployment. The checked-in concepts guide states:

> “Each sandbox contains the application and its runtime. By default, the application
> can only access the contents of its sandbox.” — [Flatpak basic concepts][basic-concepts]

The same system owns repository discovery, transactional deployment, updates, branches,
runtime lifecycle, exports to the desktop, permissions, and uninstall—features that a
portable archive alone does not provide.

### Design philosophy

Flatpak separates stable platform content from application content. A runtime/SDK pair
supplies a known ABI; the application bundles dependencies absent from that runtime.
OSTree stores content-addressed commits and permits deduplicated pulls and atomic active
deployments. Static sandbox permissions describe unavoidable ambient access, while
portals provide user-mediated, desktop-native access to files, URIs, printing, capture,
secrets, and other host services without broad filesystem or D-Bus access.

## How it works

A `flatpak-builder` manifest selects application identity, runtime, SDK, branch, commands,
sources/modules, and final permissions:

```yaml
app-id: org.example.Example
runtime: org.freedesktop.Platform
runtime-version: '24.08'
sdk: org.freedesktop.Sdk
command: example
finish-args:
  - --share=network
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
modules:
  - name: example
    buildsystem: simple
    build-commands:
      - install -Dm755 example /app/bin/example
    sources:
      - type: file
        path: example
```

`flatpak-builder build-dir manifest.yaml` downloads declared sources, builds modules in a
sandbox against the SDK, installs into `/app`, cleans the tree, exports desktop/AppStream
metadata, and records `finish-args`. `flatpak build-export` writes the finalized result to
an OSTree ref named `app/APP_ID/ARCH/BRANCH`; runtimes use
`runtime/ID/ARCH/BRANCH` [source-verified: [`flatpak-build-export`][build-export]].

At run time, Flatpak creates a mount namespace with the runtime at `/usr`, app at `/app`,
a filtered environment, private or mediated filesystems, and controlled sockets/devices
and D-Bus names. xdg-desktop-portal exposes `org.freedesktop.portal.Desktop` at a stable
D-Bus object path; desktop-specific backend processes implement the user interaction
[source-verified: [portal README][portal-readme]]. The document and permission stores can
grant a selected file or durable capability to one app ID without exposing the entire
home directory.

## Analysis spine

### Input and staging

The manifest is an auditable build graph: modules, source archives/VCS commits/files,
checksums, patches, build systems, environment, cleanup rules, runtime/SDK, and exported
metadata. Network access is normally a source acquisition concern rather than an
unbounded compile step. `flatpak-builder` maintains source/build/cache directories and
can export directly to a repository. Reproducible staging requires immutable URLs or
commits plus hashes and a pinned runtime branch/commit; a branch name alone can advance.

### Outputs and target matrix

The canonical output is an OSTree application or runtime ref keyed by kind, ID,
architecture, and branch. A repository may expose multiple architectures and branches;
several branches can be installed together. A single-file `.flatpak` bundle is an OSTree
static delta against an empty base and can optionally configure an origin remote, but it
is primarily transport: continued updates depend on that origin
[source-verified: [`flatpak-build-bundle`][build-bundle]]. Build each architecture on a
compatible Linux builder or through controlled emulation/cross tooling, then run the
sandboxed output on representative desktops.

Host compatibility is split. Bundled app and runtime content reduce distribution ABI
differences, but Flatpak, Bubblewrap, kernel namespaces/seccomp, graphics drivers,
portals, and portal backends remain host contracts. Runtime extensions bridge graphics
drivers and locales. Applications must test both runtime support windows and desktop
portal/backend behavior; “runs on every distribution” is not guaranteed by one build.

### Metadata and dependencies

The application ID is reverse-DNS-like and anchors the ref, exported desktop file,
AppStream metadata, D-Bus ownership, portal permissions, and Flathub identity. The
manifest declares one runtime and SDK; libraries absent from the runtime are built into
`/app`, while extensions can add locale, debug, source, codec, or platform content. A
runtime branch can coexist with newer branches, but publishers must migrate before its
end of life. `finish-args` become deployment permission metadata and deserve security
review like code.

### Installation, upgrade, and uninstall

`flatpak install REMOTE REF` pulls content into a per-user or system repository, resolves
the required runtime/extensions, creates a deployment, and exports launch metadata.
Updates pull the new branch head and atomically activate a deployment; OSTree object
sharing avoids retransmitting unchanged content, with static deltas as an optimization.
`flatpak uninstall` removes the deployment and exports; `--delete-data` additionally
removes app data. Unused runtimes can be removed separately. Installed commits can be
pinned or rolled back explicitly, but repository heads define ordinary forward updates.

### Signing and platform trust

Repository commits and summary metadata can be GPG-signed. `flatpak build-export
--gpg-sign=KEYID` signs exported commits; `flatpak build-update-repo --gpg-sign=KEYID`
updates and signs discoverability metadata [source-verified: [export][build-export] and
[repository update][update-repo]]. A remote configuration distributes the trusted key.
This authenticates repository content; it does not mean every app is reviewed, prove a
reproducible build, or replace developer/source provenance. Flathub's build/publication
pipeline adds catalog review and controlled signing after server-side builds.

### Publication and discovery

A self-hosted Flatpak remote is an HTTP-served OSTree repository plus summary/AppStream
metadata and a `.flatpakrepo` configuration file. `flatpak remote-add`, `remote-ls`, and
software centers consume that metadata. Flathub is the dominant public catalog: projects
submit manifests, pass automated checks and review, and are built/published by Flathub
infrastructure rather than uploading an arbitrary prebuilt `.flatpak`. Ownership and
verification badges are catalog policy, distinct from the format's app ID and repository
signature.

### Updates and release channels

Branches are the channel/version axis—commonly `stable`, with beta or versioned branches
where policy needs them. A remote head moves to a new immutable OSTree commit; clients
pull only missing objects or deltas. Applications and runtimes update independently.
Flatpak supports per-app update and masking/pinning, but there is no publisher-forced
instant refresh: host/package-manager policy schedules updates. A `.flatpakref` can name
a branch and runtime repository; a `.flatpak` bundle can seed an origin.

### Automation and CI

CI should validate manifest syntax, lock/hash every network source, run `flatpak-builder`
from a clean cache policy, execute tests in the build sandbox, inspect exported metadata
and permissions, and launch the installed ref under portal-capable desktops. The Flatpak
repository contains broad unit/integration tests around remotes, deploy/update/uninstall,
permissions, and OCI/OSTree paths; xdg-desktop-portal's suite uses mock backends and
integrated portal tests [source-verified: [portal tests][portal-tests]]. Publication CI
must isolate repository GPG keys or submit source manifests to a trusted builder such as
Flathub rather than exposing signing keys to untrusted pull requests.

### Supply-chain evidence and reproducibility

OSTree content addressing and signed commits make deployed bytes and history inspectable.
Manifests with checksummed archives and fixed commits are strong source evidence; runtime
commit selection, toolchains, generated timestamps, network-enabled build steps, and
non-deterministic compilers can still prevent byte reproducibility. Flathub manifests and
build logs improve transparency but are not automatically SLSA provenance. Publish SBOMs
or provenance separately and retain source→manifest→runtime commit→app commit mappings.

### Extensibility and UX

Builder modules/build systems and runtime extensions cover diverse stacks. Permissions
can expose filesystem paths, devices, sockets, features, and selected D-Bus names; broad
`--filesystem=host`, X11, or unrestricted bus access weakens confinement. Prefer portals:
toolkits can transparently use file chooser and URI portals, preserving native UX while
returning only user-approved resources. Portal availability/version and backend quality
are compatibility dependencies, so graceful fallback matters.

## Strengths

- One ref model combines identity, architecture, branch, runtime, install, and update.
- Shared runtimes balance vendoring control with deduplication and security updates.
- Bubblewrap confinement plus portals supports practical least-privilege desktop UX.
- OSTree provides immutable commits, atomic deployment, deduplication, and rollback data.
- Signed remotes can be self-hosted; Flathub adds discovery, review, and centralized builds.
- Manifests make sources, build steps, dependencies, and permissions reviewable.

## Weaknesses

- Host Flatpak/kernel/portal/backend/driver integration still creates compatibility edges.
- Broad static permissions can collapse much of the sandbox's value.
- Runtime EOL forces migrations and may leave multiple large branches installed.
- Builder manifests and shared runtimes add concepts beyond shipping one portable file.
- GPG repository signatures authenticate output but do not prove reproducibility.
- Flathub policy and infrastructure are a separate trust/governance dependency.

## Key design decisions and trade-offs

| Decision                              | Rationale                                          | Trade-off                                            |
| ------------------------------------- | -------------------------------------------------- | ---------------------------------------------------- |
| Shared versioned runtimes             | Stable ABI and deduplicated security updates       | Runtime lifecycle and compatibility obligation       |
| `/app` separated from `/usr`          | Clear ownership between app and runtime            | Nontraditional filesystem assumptions need patching  |
| OSTree refs/commits                   | Atomic, deduplicated, inspectable deployment       | More repository machinery than archive hosting       |
| Static permissions plus portals       | Support legacy access and least-privilege UX       | Broad permissions can bypass mediation               |
| App ID as security/discovery identity | Join desktop, D-Bus, portal, and repository policy | Renaming/ownership mistakes are costly               |
| Repository GPG trust                  | Decentralized authenticated remotes                | Key distribution/revocation remain operator duties   |
| Flathub source builds                 | Reviewable public catalog and controlled signing   | Submission policy and centralized service dependency |

## Sources

- Flatpak locally reviewed at `$REPOS/packaging/flatpak`, revision
  [`478d355c`][flatpak-sha]: command docs for export, bundle, repository update,
  install/update/uninstall, and checked-in tests.
- Flatpak documentation locally reviewed at `$REPOS/packaging/flatpak-docs`, revision
  [`d2a17baa`][docs-sha]: [basic concepts][basic-concepts], manifests, dependencies,
  permissions, portals, repositories, and publishing.
- flatpak-builder locally reviewed at `$REPOS/packaging/flatpak-builder`, revision
  [`213ae1dc`][builder-sha].
- xdg-desktop-portal locally reviewed at `$REPOS/packaging/xdg-desktop-portal`, revision
  [`c2528f73`][portal-sha]: [service contract][portal-readme] and [tests][portal-tests].
- [Flathub app submission documentation][flathub-docs] for current service policy.

<!-- References -->

[flatpak-repo]: https://github.com/flatpak/flatpak
[builder-repo]: https://github.com/flatpak/flatpak-builder
[portal-repo]: https://github.com/flatpak/xdg-desktop-portal
[docs-repo]: https://github.com/flatpak/flatpak-docs
[flatpak-sha]: https://github.com/flatpak/flatpak/tree/478d355cd200dd39a4c13ce0ed5adaf268f9d5ef
[docs-sha]: https://github.com/flatpak/flatpak-docs/tree/d2a17baabd300d911d42c353b6cbc49aec41a381
[builder-sha]: https://github.com/flatpak/flatpak-builder/tree/213ae1dc5c2469b971dab7f16e6847899d37adf0
[portal-sha]: https://github.com/flatpak/xdg-desktop-portal/tree/c2528f73a4f770f4655c3a259145e27ddb461d7f
[basic-concepts]: https://github.com/flatpak/flatpak-docs/blob/d2a17baabd300d911d42c353b6cbc49aec41a381/docs/basic-concepts.rst
[build-export]: https://github.com/flatpak/flatpak/blob/478d355cd200dd39a4c13ce0ed5adaf268f9d5ef/doc/flatpak-build-export.xml
[build-bundle]: https://github.com/flatpak/flatpak/blob/478d355cd200dd39a4c13ce0ed5adaf268f9d5ef/doc/flatpak-build-bundle.xml
[update-repo]: https://github.com/flatpak/flatpak/blob/478d355cd200dd39a4c13ce0ed5adaf268f9d5ef/doc/flatpak-build-update-repo.xml
[portal-readme]: https://github.com/flatpak/xdg-desktop-portal/blob/c2528f73a4f770f4655c3a259145e27ddb461d7f/README.md
[portal-tests]: https://github.com/flatpak/xdg-desktop-portal/blob/c2528f73a4f770f4655c3a259145e27ddb461d7f/tests/README.md
[flathub-docs]: https://docs.flathub.org/docs/for-app-authors/submission
