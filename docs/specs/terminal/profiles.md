---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-05
---

# Terminal profiles (`TPF`)

## Abstract

`sparkles:terminal` uses named profiles to start panes in desktop shells and Android
Nix development environments. Each profile supplies an explicit argument array,
environment variables, and a starting directory for its selected environment.
Declarative configuration files can contribute independently to profiles and their fields.
Running panes retain their launch settings; workspace restoration resolves stable
profile identities against the loaded configuration and exposes unavailable targets.
The same launch contract applies across local processes, PRoot, native Nix stores,
and virtual machines.

## Introduction

A developer may use a login shell, a project-specific development shell, and a
build command in separate panes. On Android these commands may run in different
execution contexts with different directory namespaces and prerequisites. A
single application-wide startup command cannot describe that workspace.

Launch configuration also changes while sessions are running. Applying an edit
to an existing pane can misrepresent how its process started; restoring a saved
command can unexpectedly rerun a build. Whole-map replacement makes a small
profile override accidentally erase unrelated profiles.

A [terminal profile](../../glossary.md#terminal-profile) gives a launch recipe a
stable identity and references a [development environment](../../glossary.md#terminal-environment).
Configuration resolves before launch. A live pane captures the resolved recipe,
while persistent workspace metadata references identities for deliberate resolution
on restoration. There is no implicit shell parsing or backend fallback.

This page owns cross-platform profile composition, selection, execution, and
restoration. [Environment integration](../android-dev-env/SPEC.md) owns readiness,
provisioning and resource lifecycle; [sessions](./sessions.md) owns workspace
presentation. [Wired configuration](../wired/config/SPEC.md) owns generic resolution.
File discovery and reference validation belong to the terminal application.
Arbitrary executable configuration and automatic project-folder imports are excluded.

Sections 1–4 define the contract and compatibility amendment. The project
[delivery plan](../android-dev-env/PLAN.md) and
[testing strategy](../android-dev-env/testing.md) own progress and evidence for this
extension; [decisions](../android-dev-env/decisions.md) records its design gates.

## 1. Contract at a glance

1. Profile and environment identities are distinct from pane identities and the identities wired uses to track individual configuration contributions.
2. Commands are explicit argv arrays with environment variables, without a shell-command mode.
3. Contributions resolve per ID and per field; an override replaces the complete argument array.
4. Readiness failure never launches the command in a different environment.
5. Live panes capture launch settings; restore resolves saved references.
6. Restored one-off commands show an inactive pane with an explicit execute action; the existing exit-prompt UI presents that state.

Normative obligations use bold **must**, **must not**, and **may**.

## 2. Values and configuration

**TPF1: Identity and references.** A profile **must** have a stable ID, display
name, enabled state, environment reference, nonempty argv, environment-variable
overrides, and starting directory. Environment records **must** have separate
stable IDs. Renaming a display name **must not** break references. Missing references,
duplicate IDs within one source, or duplicate definition identities **must** yield
located errors, not select the first matching name. Repeated object IDs across
modules are valid contributions under `TPF3`. IDs are opaque application identifiers,
not executable code or filesystem paths.

**TPF2: Execution values.** The adapter **must** preserve argv elements, including
empty noninitial elements and spaces, without joining them into a shell string.
The first element identifies the executable under the selected environment's
lookup rules. Environment variables **must** be passed by name and value; cwd
**must** be interpreted in that environment's namespace. Invalid values, an empty
executable, embedded NUL, or an inaccessible directory **must** fail before entry
execution. Selecting a shell executable with explicit arguments is allowed; there
is no special shell-command configuration mode or implicit expansion.
Exact executable lookup and inherited environment policies require per-backend
qualification. An environment adapter **may** wrap the transport/entry mechanism,
but **must not** change the guest command's arguments or cwd semantics.

**TPF3: Modular resolution.** Definitions **must** resolve separately for each
profile/environment ID and each field within it. An absent field or ID **must not**
erase another source's contribution. Environment variables resolve per variable
name; argv resolves as one complete array, never concatenation. Disabling a profile
**must** be explicit. One module **may** contribute to multiple objects, and multiple
modules **may** contribute to one object. Equal-priority atomic conflicts follow
wired's conflict rules; loading order **must not** silently resolve them.

Wired's `WCFG12` selects a whole map before its keys; applying it directly would
violate this contract. Dynamic per-ID field distribution is an explicit delivery
prerequisite, not a claim that `attrsOf(submodule)` already supplies these semantics.
The generic policy remains owned by wired; the terminal owns object identity and
reference checking.

**TPF4: Explicit imports.** The main JSONC configuration **must** declare imports
explicitly. Relative import paths resolve against the importing file. Project
folders **must not** automatically contribute launch commands. The terminal owns
file discovery, cycle detection, decoding and source metadata; wired owns typed
resolution. Import failure **must** identify its source and prevent publication
of an incomplete launch configuration. Import depth, byte/count limits, priority
assignment and repeated-import handling require the configuration gate in
[decisions](../android-dev-env/decisions.md#open-design-gates).

**TPF5: Deliberate settings writes.** Settings edits **must** persist deliberate
local overrides, not flatten imported or effective values. Imported human-owned
files **must not** be rewritten by an ordinary settings edit. Removing a local
override **must** reveal the lower-priority contribution rather than disable the
profile. Setting `enabled = false` explicitly disables it. Reload **must** validate
a complete launch snapshot before publication; failure **must** retain the last
valid live snapshot and expose rejection, without using it to silently replace an
explicitly requested invalid target. Initial startup without a valid snapshot
**must** expose configuration recovery instead of launching.
The writable layer and precedence cutover are blocked compatibility decisions.

## 3. Launch selection and restoration

**TPF6: Selection.** Each platform **must** have an explicit default profile.
A new tab uses it unless a profile is explicitly selected. A split inherits the
focused pane's profile and observed directory within the same environment unless
the user explicitly selects another profile. A changed environment selection
**must not** reinterpret the inherited directory in another namespace. If no
reliable current directory is available, the UI **must** disclose that fact and
use the profile's starting directory. Disabled, missing or unready targets **must**
present recovery, without a fallback launch.

**TPF7: Captured launch.** A running pane **must** retain an immutable resolved
launch snapshot, including profile/environment identity and the configuration
revision used. Profile edits affect subsequent launches, not running panes.
Explicit rerun **must** use that captured argv/env/cwd and recheck readiness.
A removed environment or incompatible backend change **must** refuse rerun rather
than redirect the snapshot. Captured values **must** remain valid for the pane's
lifetime independently of decoder buffers and later config edits.

**TPF8: Restore.** Workspace persistence **must** record profile and environment
IDs, directory metadata, and whether a pane is a normal profile session or an
explicit one-off command. Restoration **must** resolve the stable profile ID
against the loaded configuration. Within an unchanged environment, a reliably
saved current directory **must** take precedence over the profile's starting
directory. An inaccessible saved directory **must** produce recovery rather than
silently select a different directory. If no reliable directory was saved, use
the loaded profile's starting directory and disclose that limitation.
Missing, disabled or incompatible targets
**must** enter recovery. Changing a profile's environment **must** require explicit
recovery selection rather than silently reinterpret the saved directory. Normal
profile sessions run their configured entry command; explicit one-offs restore
at the exit prompt without execution. Live processes are not serialized or
reattached by this contract. Resolved environment-variable values **must not**
be copied into workspace metadata merely because a pane captured them in memory.

**TPF9: One-off execution.** An explicitly requested one-off command **must**
run through the selected environment's session adapter using explicit argv/env.
It **must not** bypass that environment through an Android host shell. The pane
**must** retain its classification as a one-off for restore and explicit rerun.
Desktop CLI migration from shell-string joining requires compatibility review;
old strings **must not** be guessed into an argv array.

**TPF10: Visible context.** Profile selection and recovery **must** identify the
profile, environment and failed prerequisite. A mixed-environment workspace **must**
make each pane's environment discoverable. Configuration inspection **must** explain
field contributors and conflicts using wired's snapshot rather than fabricate
last-writer provenance. Visual layout requires a separately reviewed mockup before
implementation; this page does not choose one.

## 4. Compatibility amendment

The accepted terminal baseline remains authoritative until this draft extension
is accepted. The following are intentional amendments, not delivered behavior:

| Existing contract                                    | Amendment on accepting profiles                                                                                           |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `TSS4`, app-wide shell/bootstrap selection           | Selection follows `TPF6`; legacy values require a documented default-profile migration                                    |
| `TSS5`, last-pane closure quits the app              | With a running managed AVF environment, closure leaves an empty workspace and owner alive; explicit quit remains separate |
| `TSS8`, new-pane directory inheritance               | Profile-aware same-environment inheritance follows `TPF6`                                                                 |
| `TSS14`, fresh-shell restore and one-off suppression | Identity-aware restore follows `TPF8`; its non-replay guarantee remains                                                   |
| `TCF2`, defaults → Termux → file → CLI               | Preserve precedence for existing options; profile imports and writable overrides require the explicit cutover gate        |
| `TCF4`, tolerant invalid-setting handling            | An invalid requested launch target produces recovery, never a substitute execution context                                |
| `TSP3`, deliberate edits to `config.json`            | Preserve deliberate sparse edits; avoid rewriting imported human-owned files under `TPF5`                                 |
| `NOD3`, Android SDK policy for PRoot                 | AVF compatibility must be proved without silently raising the PRoot flavor's target SDK                                   |
| Session detach/sharing exclusion                     | Unchanged; VM ownership across pane closure does not imply process reattachment                                           |

**TPF11: Persisted compatibility.** Before cutover, migration **must** specify
how legacy workspace/configuration records are recognized, converted and rejected,
and how older versions behave with new records. Unsupported persisted versions
**must** be reported without overwriting the source. Migration **must not** turn
saved one-off commands into automatically executed profile sessions. Exact version
markers and backup procedure are a release gate, not a shipped format claim.
