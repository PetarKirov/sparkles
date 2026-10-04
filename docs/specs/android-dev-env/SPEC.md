---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-05
---

# Android Nix development environments

## Abstract

`sparkles:terminal` provides a terminal-based Nix development environment on
Android through nix-on-droid, an externally provisioned native Nix store, or a
managed NixOS virtual machine. Named terminal profiles select where and how each
pane starts. Environment ownership makes readiness, persistent files, session
termination, and recovery explicit across different execution mechanisms. The
first release requires a complete local development workflow and acceptance of
Android Virtualization Framework (AVF) on one documented stock Pixel firmware
configuration. Backend failures remain
visible; launching elsewhere is never an implicit recovery action.

## Introduction

Developers need an Android terminal that can run ordinary Nix tools, edit projects,
build and test them, and reach local development servers. A custom terminal should
provide this workflow without depending on the Termux app or Android Terminal.
Using the nix-on-droid distribution and its PRoot execution mechanism remains in
scope; replacing those applications does not require replacing every distribution.

Android execution mechanisms have different prerequisites and ownership rules.
PRoot installs an application-owned userspace, a native Nix store (NNS) relies on an external
privileged stack, and AVF starts a guest with its own kernel and filesystem.
A successful stock Microdroid boot does not establish custom NixOS boot or access
from a native application. A single boot console does not establish independent
interactive sessions.

The integration gives each [development environment](../../glossary.md#terminal-environment)
an explicit lifecycle and uses [terminal profiles](../../glossary.md#terminal-profile)
to launch panes within it. The terminal owns user-facing policy, backend adapters
own execution and resource cleanup, and externally managed resources retain their
external owner. Device qualification records exact firmware and grants rather
than inferring support from the SoC name.

This contract owns environment integration and the Android development workflow.
[Profiles](../terminal/profiles.md) owns cross-platform launch semantics;
[the terminal specification](../terminal/index.md) owns rendering and input, and
its [sessions contract](../terminal/sessions.md) owns workspace presentation.
NNS installation, app-managed guest image upgrades,
QEMU TCG, live Android-folder sharing, and deeper Podroid integration are excluded.
No library package is prescribed for each backend.

Sections 1–5 define ownership, operations, and support boundaries.
[PLAN.md](./PLAN.md) owns project milestones and delivery order.
[testing.md](./testing.md) owns acceptance scenarios and evidence.
[decisions.md](./decisions.md) records accepted choices and blocked design work.

## 1. Contract at a glance

1. A pane launches only inside its explicitly selected environment.
2. Environment readiness and session readiness are separate observations.
3. External NNS resources remain externally owned.
4. Pane closure ends one session; Sparkles stops managed environments, while external owners control NNS resources.
5. Persistent environment files survive pane closure, environment stop, and app updates.
6. AVF support requires custom NixOS and independent guest PTYs on qualified firmware.
7. The app and all helpers distributed by Sparkles contain no Android DEX bytecode.
8. Unsupported capabilities and failed operations have explicit outcomes.

Bold **must**, **must not**, and **may** indicate normative obligations.
The first release requires all three backends; no AVF gate is waived by a PRoot pass.

## 2. Scope and ownership

**ADE1: Development workflow.** On each qualified backend, the terminal **must**
support Git and SSH, a terminal editor with a language server, and a flake-based
build/test/run workflow using Sparkles' D project. A development HTTP server
**must** be reachable from an Android browser through an explicitly configured
path. Merely opening a shell or printing `nix --version` does not satisfy this gate.
A second-language qualification project is deferred.

**ADE2: Backend qualification.** The release **must** identify tested app and
backend revisions, architecture, device, Android build, required grants, and
provisioning procedure. AVF **must** qualify at least one stock Pixel firmware
configuration, allowing explicitly documented development grants. Other devices
**must** receive observed capability results and an unqualified designation until
their acceptance suite passes. Rooted Pixel evidence **must not** certify stock
firmware. Hypervisor backend and protected/unprotected guest mode are separate facts.

**ADE3: Native distribution.** Every distributed app and helper component
**must** be native without DEX. AVF ownership through native code **must** be
proved before committing to an owner API or helper design. An unsuccessful spike
requires an explicit scope/design decision, not an undisclosed managed helper.

| Boundary                                          | Policy owner                                        | Resource owner                                      |
| ------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------- |
| Configuration, launch requests, readiness display | `apps/terminal`                                     | terminal configuration snapshots                    |
| Schema resolution and provenance                  | `sparkles:wired`                                    | caller-owned resolution snapshot                    |
| VT rendering and pane-local I/O                   | `sparkles:terminal-view`                            | session adapter owns execution handles              |
| PRoot provisioning                                | `apps/terminal` Android adapter                     | Sparkles-installed userspace                        |
| NNS entry                                         | `apps/terminal` native-store adapter                | external provisioner owns store, daemons and policy |
| AVF VM and guest sessions                         | `apps/terminal` AVF adapter and native guest broker | Sparkles environment owner                          |

These are contract boundaries, not claims that the adapters or broker exist.
Package dependencies run from the terminal application to libraries, never from
wired to the terminal. Delivery dependencies additionally include wired's dynamic
per-ID field resolution and AVF firmware experiments.

## 3. Readiness, provisioning, and launch

Here, entry-command execution means executing the requested profile/one-off argv.
Authorized backend preparation, namespace entry and readiness probes may run
before it; guest-directory checks need not use the Android host namespace.

**ADE4: Readiness.** Before entry-command execution, an adapter **must** check
its relevant prerequisites and report a distinguishable outcome: ready,
provisioning required, prerequisite unavailable, unsupported configuration,
resource exhausted, or operation failed. Reports **must** identify the failed
check and a recovery action. Checks **must not** repair NNS policy or interpret a
stock Microdroid result as custom-guest readiness. A failed check **must not**
execute the entry command or select another backend.

**ADE5: Provisioning commit.** PRoot and AVF provisioning **must** stage a
versioned artifact, validate completeness and backend readiness, then publish the
ready environment. Until publication, launch **must** report provisioning rather
than consume a partial installation. Failure or cancellation **must** preserve an
existing environment and leave identifiable staging data that can be retried or
explicitly discarded. Concurrent provision/stop/remove requests for one environment
**must** be serialized or refused as busy, with no two writers of its metadata.
Artifact authenticity policy is a blocker in [decisions](./decisions.md#open-design-gates).

**ADE6: Provisioning scope.** Ordinary PRoot installation **must** be possible
entirely on-device from published artifacts. AVF and NNS **may** require documented
ADB/root provisioning. NNS installation and management **must** remain external;
Sparkles checks readiness and launches the configured entry command. A bundled
bootstrap **must not** be described as a complete offline first Nix generation
when generation construction downloads packages.

**ADE7: Independent sessions.** A ready environment **must** accept separate
pane sessions with independent PTYs, argv, environment variables, directory,
resize, signal handling, output, and exit status. One pane's close or resize
**must not** affect another session. AVF boot-console access alone does not satisfy
this requirement. Session launch is committed when the adapter returns a live
session handle; failure **must** clean up any partially created execution resources
and report whether the command began execution. Automatic replay after an ambiguous
launch result **must not** occur.

**ADE8: Cancellation and stale results.** Cancellation **must** revoke an
operation's authority to publish readiness or attach a session. An adapter
**must** retain resources until in-flight users relinquish them, and clean up a
late successful creation. Results **must** be associated with environment and
operation generations so a removed/reconfigured target cannot accept a stale
completion. A failed cancellation **must** report the remaining operation; it is
not rollback of a command that has executed.

## 4. Lifecycle and persistent data

**ADE9: Stop authority.** Closing a pane **must** end its session. Closing the
last AVF pane **must not** implicitly stop its VM: the owner keeps it running until
explicit environment stop or owner shutdown. With a running managed AVF
environment, last-pane closure **must** leave an empty workspace rather than quit
the app; explicit app quit is a separate owner-shutdown action. This intentionally
amends terminal `TSS5` on acceptance of this draft.
Explicit stop with active sessions
**must** require confirmation, identify affected sessions, and refuse new launches
while stopping. Confirmation **must** bind to the displayed affected session set;
if that set changes before acceptance, re-confirm the changed set before stopping.
Declining confirmation **must** leave execution unchanged. Sparkles
**must not** stop externally owned NNS daemons or unmount/delete its store.

**ADE10: Android continuity.** Ordinary backgrounding and activity recreation
**must** preserve sessions while their execution owner remains alive, subject to
documented Android process limits. Owner death **may** end execution; the terminal
**must** detect lost authority and provide recovery rather than display a connected
pane. Force-stop/reboot recovery **must not** promise live process reattachment or
silently replay one-off commands. Profile-aware workspace restoration is owned by
[TPF8](../terminal/profiles.md#_3-launch-selection-and-restoration).

**ADE11: Persistent files.** Pane closure, environment stop, and app updates
**must** preserve environment files. Projects default to persistent environment-local
storage. Removing Sparkles-owned environment data **must** require confirmation
identifying the data to be deleted and affected sessions. NNS data removal remains
external. App uninstall and Android storage clearing are outside this preservation
promise and **must** be documented. Persistence does not imply immunity to filesystem
corruption or sudden power loss.

**ADE12: Transfer and recovery.** Each qualified backend **must** document a
working project import/export procedure, including recovery when a guest is
unbootable where the platform permits access. The qualification report **must**
state inaccessible recovery cases rather than promise universal extraction.
Transfer failure **must** identify incomplete output and preserve the source.
Live shared folders and seamless cross-environment paths are deferred.

**ADE13: Guest maintenance.** AVF **must** provision a versioned NixOS image
with systemd and canonical `/nix/store`, support a documented in-guest configuration
and rebuild procedure, and document recovery for an unbootable guest. Kernel and
boot-asset changes **must** have a documented compatibility procedure. App-managed
image upgrades and automatic rollback are excluded; an app update **must not**
replace an existing guest disk as an implicit migration.

## 5. Network, bounds, and diagnosis

**ADE14: Development networking.** Each qualified backend **must** permit
outbound development traffic under the documented network conditions. Explicit
host port forwarding **must** bind to loopback by default; LAN exposure requires
explicit configuration. Port conflicts **must** fail with the requested endpoint
identified, without silently selecting another port. Stop **must** release
Sparkles-owned forwards. Transparent networking and automatic discovery are deferred.

**ADE15: AVF resources.** AVF **must** offer memory, CPU-count, and disk-capacity
settings with documented units, defaults, and limits for qualified firmware.
Configured and effective values **must** be observable. Unsupported values
**must** be rejected rather than silently reduced. Changes apply to a stopped VM's
next start. Exhaustion **must** report the affected resource without automatically
deleting projects or store contents. Automatic tuning and disk shrinking are excluded.
Numerical limits await the firmware capability spike; no universal limits are implied.

**ADE16: Bounded transport.** Each session adapter **must** declare finite
buffering limits and backpressure behavior before implementation acceptance.
Slow output consumption **must not** permit unbounded buffering or mix sessions;
control operations and teardown **must** remain possible under saturation.
Guest transport **must** reject unauthorized launch/control requests and stale
session identities. Exact protocol, authority mechanism, and limits are gated by
the native multi-PTY spike; a general AVF security guarantee is not inferred.

**ADE17: Diagnostic privacy.** Environment diagnostics **must** distinguish
readiness, launch, guest boot, transport loss, storage exhaustion, and configuration
failures. Routine logs and exported reports **must not** include argv payloads,
environment-variable values, private keys, project contents, or terminal output
without an explicit user export choice. Reports **must** expose a reviewable
preview before export. IDs, firmware identifiers, and paths require a documented
redaction policy before report distribution. Diagnostic policy belongs to the app,
not the wired resolver.
