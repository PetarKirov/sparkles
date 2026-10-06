---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-06
---

# Profile configuration sources and persistence (`TPC`)

## Abstract

`sparkles:terminal` combines declarative configuration with persistent settings-menu
edits across desktop and Android. Generated Home Manager files can remain read-only,
including their containing directory, because local edits use separate application
state. Local settings take precedence over command-line options and host environment
variables that supply application settings. Explicit imports add ordinary configuration files and Termux compatibility
inputs. Alternate roots have isolated local settings and saved workspaces, and validated reloads observe
file replacement without changing running panes' captured launch recipes.

## Introduction

Developers manage configuration through Nix Home Manager, hand-written modules,
command-line options, and the terminal's settings menu. A generated file can be a
symlink into an immutable store. Rewriting it to save a font or profile preference
fails or destroys the distinction between managed configuration and local edits.

Configuration also changes outside the app. Home Manager can replace a symlink,
multiple files can import one common module, and another supported settings writer
can change local state while a settings page holds an older draft. A loader that watches only an old
symlink target or saves its opening snapshot can miss changes or lose another edit.

Configuration-environment inputs mean host process variables configuring the
application; they are distinct from a guest's runtime variables.
The terminal treats declarative roots and their imports as read-only inputs, and
keeps local settings in frontend-owned state. A [terminal profile](../../glossary.md#terminal-profile)
selects a [development environment](../../glossary.md#terminal-environment), but that
environment's home does not select the frontend's configuration storage. Source
selection and publication are application policy; the generic resolver receives
explicit typed contributions.

This page owns terminal discovery, import traversal, source precedence, writable
state and migration behavior. [Profiles](./profiles.md) owns launch values and
restoration; [wired configuration](../wired/config/SPEC.md) owns generic composition,
priority representation and snapshot mechanisms. The terminal's
[consumer handoff](../android-dev-env/decisions.md#questions-for-the-wired-configuration-owner)
records the required capabilities at that boundary.
No resolver algorithm, priority number or priority annotation syntax is selected here.
Automatic project/system roots and executable configuration are excluded.

Sections 1–5 define source, persistence and recovery obligations.
[The project plan](../android-dev-env/PLAN.md) owns delivery progress;
[testing](../android-dev-env/testing.md#configuration-source-scenarios) owns scenarios
and evidence; [decisions](../android-dev-env/decisions.md) records agreed policy and
remaining encoding, migration and feasibility gates.

## 1. Contract at a glance

1. Local UI overrides win over invocation inputs, including after restart.
2. Managed roots and imports are never rewritten by a settings edit.
3. Each configured root path has independent local overrides and saved workspaces, stable across symlink retargeting.
4. Explicit `--config` replaces root discovery, not the selected import graph.
5. Termux compatibility exists only through an explicit typed import.
6. Reload commits a validated snapshot; running launch snapshots remain unchanged.
7. Unsupported or stale state is preserved and reported, not overwritten or replayed.

Bold **must**, **must not**, and **may** indicate normative requirements.
This extension intentionally amends the accepted [TCF/TSP baseline](./config.md)
on acceptance; publication of this specification alone does not change shipped behavior.

## 2. Roots and invocation inputs

**TPC1: Default root.** On Linux, the default declarative root **must** be
`$XDG_CONFIG_HOME/sparkles/terminal-config.jsonc`, using `$HOME/.config` when the
XDG directory is unset. Other desktop platforms **must** use the native configuration
base selected by `common_dirs.configDir`, with the same `sparkles/terminal-config.jsonc`
suffix. Android **must** use the frontend's application home configuration directory,
not a selected guest's home. The `.jsonc` extension identifies comment support;
strict JSON remains valid. Automatic system and project roots **must not** load.

**TPC2: Explicit root.** Desktop `--config PATH` **must** disable all other
declarative-root discovery, including legacy fallback. It **must** load that root's
explicit imports, root-isolated local overrides, explicitly supplied CLI settings
and enabled configuration-environment inputs. Missing/unreadable explicit roots
**must** produce configuration recovery/error rather than create a file or select
another root. The option does not designate a writable settings file.

**TPC3: Consumer precedence.** For a setting supplied by several source tiers,
resolution **must** prefer, from strongest to weakest: local UI overrides; explicitly
supplied CLI settings; configuration-environment settings; ordinary declarative
files; explicit Termux compatibility inputs; compiled defaults. Main and imported
ordinary files have equal ordinary preference; equally preferred atomic conflicts
**must not** be resolved by import order. This tier constraint **must** hold even if
files can author explicit priority overrides. The wired owner determines its
representation and file authoring interface. Parser defaults **must not** become
explicit CLI/environment contributions.

**TPC4: Configuration environment.** Only documented `SPARKLES_TERMINAL_*`
configuration variables **must** contribute application settings. `--no-config-env`
**must** exclude those contributions at startup and subsequent reloads for that
invocation, while preserving ordinary OS environment inputs for directory/locale
lookup and the backend's child-process environment. Configuration variables and
profile `env` entries **must** remain separate inputs and provenance categories.
Exact variable bindings/types are a host-schema integration gate; this draft does
not invent a generic environment naming/decoding mechanism.

**TPC5: Root namespace.** Local overrides **must** be scoped to the normalized
absolute configured root path, before resolving a root symlink's target. Replacing
a Home Manager symlink target **must not** change that namespace. Different explicitly
selected root paths **must not** share overrides merely because their contents or
resolved target match. Frontend-owned state **must** remain outside the declarative
configuration tree. On Linux it uses the XDG state base; other desktops use
`desktopStateDir`'s native data fallback; Android uses app-private `files/state`.
Exact namespace encoding and state filename are a persisted-format gate; the
format **must** detect namespace collisions rather than alias roots silently.

## 3. Explicit imports and starter generation

**TPC6: Import traversal.** Relative paths **must** resolve against their importing
file. A source reached through a diamond import graph **must** contribute once per
snapshot, including aliases that resolve to the same filesystem source. An active
traversal cycle **must** fail with its complete path chain before publication;
visited-source deduplication **must not** conceal a cycle. The terminal **must**
retain import locations and configured paths for diagnostics without requiring the
resolver to discover files. Optional absence **may** be ignored only when explicitly
requested; an unreadable or malformed existing source still requires a diagnostic.

Relative imports **must** use the configured importing path's directory, before
resolving that path's symlink target. When aliases of one physical source produce
different resolved import graphs, loading **must** reject the snapshot and identify
both configured paths and the divergent import. Reversing traversal order **must
not** change acceptance or select a different graph. Deduplication **must not**
skip the alias comparison or active-cycle check. Aliases with equivalent resolved
graphs still contribute once. Filesystem identity and graph-comparison mechanics
remain acquisition gates; this rule does not require duplicate contributions.

**TPC7: Explicit Termux adapter.** A typed Termux import **must** list the named
paths for `termux.properties`, `colors.properties`, and `font.ttf` that the adapter
is authorized to consume. The adapter **must not** search `~/.termux` or infer
additional compatibility inputs when no such import exists. It retains the
supported mappings in [TCF3](./config.md#requirements-tcf); unsupported Termux
properties do not acquire behavior through this extension. Missing explicitly
optional inputs **must** be harmless; malformed or unreadable existing inputs
**must** be diagnosed. Compatibility contributions remain weaker than ordinary
JSONC settings regardless of import order.

The following illustrates the terminal-owned descriptor, not wired's priority
metadata syntax or a shipped parser. The final host input schema must be reviewed
with its decoder and fixtures before implementation:

```json
{
  "imports": [
    {
      "type": "termux",
      "paths": {
        "properties": "/path/to/.termux/termux.properties",
        "colors": "/path/to/.termux/colors.properties",
        "font": "/path/to/.termux/font.ttf"
      },
      "optional": true
    }
  ]
}
```

**TPC8: Starter ownership.** First run with neither a default nor legacy root
**must** create a commented `terminal-config.jsonc` starter without replacing an
existing file. Android's starter **must** include the explicit optional typed Termux
import with actual frontend compatibility paths. Existing Home Manager roots
**must not** be edited to inject imports. A legacy installation keeps fallback
until explicit migration; a missing `--config` target **must not** trigger starter
creation. Starter creation failure **must** expose a recovery action. A race that
creates a root before publication **must** preserve that root instead of overwrite it.

**TPC9: Acquisition limits.** Import loading **must** enforce finite limits for
active traversal depth, distinct sources, per-source bytes and total bytes. Typed
binary font acquisition needs a separate limit from JSONC text. Exceeding a limit
**must** name it, preserve the prior snapshot and publish no partial graph. File
content and symlink replacement during acquisition **must** be detected before
commit or reported as an unstable load, with bounded retries. Concrete acquisition
limits, deduplication identity, and consistent-read technique are implementation
acceptance gates owned by the terminal, separate from wired's retained-value budgets.

## 4. Edits and reload

**TPC10: Deliberate local edits.** Settings-menu edits **must** save only deliberately
changed local contributions. They **must not** rewrite managed inputs or copy
unmodified effective values from other sources. Local state **must** remain writable
when the whole declarative directory is read-only. An applicable presentation edit
**must** apply live after successful publication; launch-setting edits affect later
launches under [TPF7](./profiles.md#_3-launch-selection-and-restoration). A committed
local value **must** win over matching CLI/environment settings after restart too.
UI reset **must** remove the local contribution and reveal the next source;
writing the compiled default is a distinct explicit value, not reset.

**TPC11: Stale saves.** Supported writes to local state **must** coordinate through
the app or a terminal settings CLI participating in the same transaction protocol.
Manual editing of local state is supported only while all app/settings writers
using that state are stopped. Declarative roots and imports remain externally
editable while the app runs; this restriction applies only to frontend-owned state.

Within that coordination contract, if writable-state content changed since the settings page's
base snapshot, save **must** refuse before replacing that content. Pending edits
**must** remain available for reload/reapply with a conflict explanation. The app
**must** serialize its own writers and use a transaction that detects external
replacement/content changes; checking parseability alone is insufficient.
Detected changes by an uncoordinated external writer **must** also refuse stale
saves and preserve drafts. The app makes no no-overwrite guarantee for arbitrary
concurrent editors that bypass coordination. The settings CLI and coordination
protocol are planned interfaces requiring specification before implementation;
a hash check followed by rename alone does not satisfy the supported-writer contract.
Automatic merge of external edits is excluded. Failed persistence **must** retain
the pending edit and expose unsaved state, not report a durable success.

**TPC12: External reload.** The app **must** provide explicit reload and automatic
observation of root/import file replacement and symlink retargeting. Observation
**must not** remain attached solely to an old immutable target. Successful reload
**must** validate then atomically publish one complete configuration snapshot;
invalid or exhausted loads **must** preserve the last valid snapshot and expose
rejection. Initial startup without a valid snapshot **must** offer recovery without
launching an invalid target. Removed imports **must** cease contributing after a
successful reload; local override namespaces remain stable across activations.

**TPC13: Pending edits and reload.** Reload **must not** discard pending settings
edits or silently publish them as saved. A changed draft base requires reapply/
conflict resolution before save. Running panes retain their captured launch values;
a newly requested invalid target **must not** be substituted from an older snapshot.
Watcher coalescing, retry and work bounds **must** be specified before acceptance;
a change during an in-flight reload **must** request subsequent revalidation rather
than be lost or permit stale publication after a newer accepted snapshot.

## 5. Compatibility and authority

**TPC14: Legacy sources.** Without an explicit root, absence of the new default
root **must** retain the existing configuration path as fallback. Legacy source
files **must** remain intact until explicit migration. Migration to the JSONC root
**must** make any retained Termux reads explicit rather than introduce a hidden
compatibility source. Exact legacy adapter behavior and migration fixtures are a
cutover gate; this clause does not promise old implicit reads under the new model.

**TPC15: Workspace migration.** Legacy ordinary shell panes **must** migrate to
stable built-in platform/environment profile identities while preserving reliable
directories. Legacy one-off command strings **must** remain visible inactive
records until the user supplies explicit argv; migration **must not** parse them
heuristically or auto-execute them. Existing records **must** be backed up before
migration commit. Unsupported workspace versions **must** enter recovery without
source overwrite. New version markers, atomic backup/publication, repeat-migration
handling and backup transactions remain a format acceptance gate under
[TPF11](./profiles.md#_4-compatibility-amendment).

**TPC16: Workspace root isolation.** Saved workspaces **must** use the same
configured-root namespace as local overrides under TPC5. Starting with root B
**must not** restore root A's panes merely because their profile/environment IDs
match. Returning to root A **must** select A's saved workspace. Symlink retargeting
**must** preserve that association while restoration validates current profile and
environment definitions. Transferring a pane between roots **must** require an
explicit user action and validation against the destination configuration before
launch. Namespace equality never establishes backend readiness. Runtime root
switching and a transfer UI are not promised by this clause; if provided, they
must obey these rules.

**TPC17: Unsupported persisted versions.** An unsupported workspace or local
override-state version **must** remain untouched and produce a version-mismatch
explanation. Recovery **must** offer an explicitly temporary session that restores
no saved panes, regardless of which persisted file caused the mismatch, and does
not apply unsupported overrides.
Such a session **must not** save settings or workspace state over the preserved
files, including during normal exit. Creating replacement state **must** require
an explicit backup/reset action; failed backup **must** leave the originals intact
and refuse reset. Exact format markers and backup/publication mechanics remain
persisted-format gates. This policy applies to downgrade and any other unsupported
version, without promising that every older binary already implements it.

**TPC18: Migration and reset backups.** Backups created for migration or persisted
state reset **must** remain available until explicit user deletion; automatic
pruning **must not** remove them. Recovery **must** expose each backup's location
and size. Migration/reset **must** refuse to commit when a complete backup cannot
be saved, including insufficient space or a failed write. Failure **must** preserve
the original state and explain the failed backup. Ordinary settings saves **must
not** create migration backups. Complete-backup verification, crash-consistent
publication and deletion mechanics remain persisted-format acceptance gates.

**TPC19: Legacy workspace destination.** Migration of a workspace predating root
namespaces **must** be offered into the default/legacy configuration namespace.
Starting with an explicit `--config` root **must not** automatically adopt that
workspace, including when profile/environment ID spellings match. Importing it
into another root **must** require explicit selection and validation against that
destination before launch. The migration **must** preserve TPC15's inactive legacy
command strings and TPC18's backup requirement. Identifying the historical default/
legacy namespace and repeat-import handling remain persisted-format gates; this
clause does not authorize guessing a destination from the current working directory.

| Accepted baseline                  | Intentional amendment on accepting this extension                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| `TCF2`, CLI strongest              | `TPC3`: persistent local edits strongest; invocation sources remain inspectable      |
| `TCF3`, implicit Termux layer      | `TPC7`: same supported mappings, explicitly imported inputs                          |
| `TCF4`, tolerate invalid values    | Invalid launch graphs cannot publish or substitute another execution context         |
| `TCF5`/`TCF6`, show/write starter  | Same reflected options; source-aware inspection and new JSONC starter path           |
| `TSP3`, save `config.json`         | `TPC10`: root-scoped writable app state, managed files untouched                     |
| `TSP2`/reset UI                    | Reset removes local contribution; deliberate compiled-default assignment is distinct |
| `TPF11`/`TSS14`, workspace restore | `TPC15`: conservative legacy migration, inactive strings and preserved records       |

Only consumer constraints are specified here. The [wired handoff](../android-dev-env/decisions.md#questions-for-the-wired-configuration-owner)
remains authoritative for questions assigned to that agent; generic mechanism and
encoding choices need its specification PR. Publication does not certify a resolver,
watcher, persistence implementation or device workflow.
