---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-03
---

# About, logs and the notification log (`TPG`)

## Introduction

A user who reports a problem is asked which build they run and what the app
logged; a user who missed a notification wants to see it again; and every
user is owed the licences of the software inside the app. On the desktop,
answers can come from a terminal and the file system. On Android, `adb
logcat` is out of reach for most users, the licences sit in an APK asset
nobody can open, and a notification dismissed while the screen was off is
gone.

This page specifies the application's read-mostly pages: about, credits, the
log and the notification log. Each is a [surface](../../glossary.md#surface)
reached from the [key guide](../../glossary.md#key-guide), and each has a
chosen mockup for its layout ([design](./design.md)); this page fixes its
content and behaviour. The log ring and its file sink belong to
`sparkles:base`, so any application can install them; the pages belong to
`apps/terminal`. The credits are one document in the repository, rendered by
the documentation site and by the app's embedded document viewer, so the two
cannot disagree.

Out of scope: uploading logs or crash reports to a server, and a notification
history that survives a restart, since the notification log is kept in
memory only. The protocols that raise notifications are
[Protocols](./protocols.md)'s; opening a file in the viewer is
[Viewer](./viewer.md)'s.

The requirements follow, grouped by page, with one [status](#status) table
for them all; the evidence is in [Testing](./testing.md).

## About (`TPG1`–`TPG3`)

**TPG1: Build facts.** The about page **must** show the name
(`sparkles:terminal`), the version and the short commit it was built from,
the build type, libghostty-vt's version and build options, and the rendering
backend; on Android also the package id, `versionCode`, the device ABI and
the API level. These are the facts hue's startup popup shows
([`NSI1`](../hue/notifier.md)).

**TPG2: Version from the build.** The version and commit **must** come from
the build, not from the source tree at run time. The Nix build passes them in,
the commit only in a release build so that other builds stay cached across
commits; a plain `dub build` reports `dev`. A dirty tree **must** be reported
as such, never as the last commit.

**TPG3: Credits and sources.** The about page **must** link to the credits
page (`TPG12`) and to the source and the documentation, opened through the
link allow-list ([`TPR6`](./protocols.md)). It **must not** carry a second,
hand-kept licence list.

## Logs (`TPG4`–`TPG8`)

**TPG4: The ring.** A ring sink in `sparkles:base` **must** keep the last
10 000 log entries, truncating any entry over 4 KiB, and forward each entry
to the sink it replaced (logcat, stderr), so that installing it changes
nothing else. Writing to it is `@nogc`; a full ring overwrites the oldest
entry and counts the drop.

**TPG5: The file.** A file sink **must** append the same entries to
`<state dir>/sparkles-terminal/terminal.log`, rotating at 1 MiB to a single
`terminal.log.1`, so that the previous run's last entries survive a crash. A
write failure disables the file sink with one logged warning and never stops
the app.

**TPG6: Nothing typed reaches the log.** The log **must never** contain text
that was typed, pasted, autofilled or copied, nor an OSC 52 payload; protocol
events log their kind, pane and length only. Violation: a test that types,
pastes, autofills and copies a marker string and finds it in the ring or the
file.

_Rationale:_ A terminal's input includes passwords and secrets, and a log is
shared to report a problem ([D24](./decisions.md)).

**TPG7: Sources.** The log **must** collect the app's own logger calls,
terminal-view's output (its raylib `TraceLog` routed into the logger), the
`am` server, the installer, and, at `debug`, protocol events and
notifications.

**TPG8: The log page.** The log page (mockup LG1) **must** have its search on
its own row under the header, taking free text, `source:<name>` and
`/regex/`, matched and ranked by `sparkles:fuzzy` rather than a matcher of
its own. The filters sit on the row below: level chips and a source filter.
The page follows the tail while scrolled to the bottom and stops following
when scrolled up, so a new entry never moves a reader who has scrolled up. It
copies the visible entries, shares them (Android `ACTION_SEND`), and shows
the previous run's file when asked.

## Notification log (`TPG9`–`TPG11`, `TPG18`)

**TPG9: What is recorded.** Every notification event
([`TPR8`](./protocols.md)) **must** be recorded with its time; its source
[pane](../../glossary.md#pane), named by the tab and pane titles of the
moment; the pane's foreground process and working directory at that moment;
its title, body and protocol; and whether it was shown as a system
notification, a toast or neither. The last 500 are kept, in memory.

**TPG10: Going to the source.** Activating an entry **must** select its tab
and focus its pane; an entry whose pane has closed says so and does nothing.
This is the deep link's fallback ([`TPR12`](./protocols.md)).

**TPG11: Unseen entries.** Entries not yet seen **must** be marked, and the
count of unseen entries **must** be shown where the pages are reached from:
the key guide's row and the tab tree. Opening the page marks them seen.

**TPG18: Grouping.** The notification log **must** be grouped by a control
on the page (mockup N2): none (one list, newest first), tab and split, app,
coding agent, project, or user rules. The app is the pane's foreground
process when the notification arrived. The project is its working directory
(OSC 7, [`TPR4`](./protocols.md)), collapsed to the enclosing git root.
Agents are a known list of agent processes (claude, codex, aider and others),
extensible in the configuration. Rules are an ordered list in
`notifications.groups`; each matches on the app, a working-directory glob or
a tab-title glob and assigns a group name, the first match wins, and
unmatched entries fall in "Other". A notification whose app or directory was
unknown falls in "Unknown". The chosen grouping persists.

## Credits (`TPG12`–`TPG17`)

A licence dump says what a project is obliged to say. A credits page says what
it owes: which library draws the glyphs, which parses the escape sequences,
which lays out the emoji. It is written once, as Markdown in the repository,
and read in two places: the documentation site and the app itself.

**TPG12: One credits document.** The project **must** have one credits
document in `docs/credits/`, published on the documentation site, with one
part per third-party component (`docs/credits/parts/<id>.md`). A part gives
the component's name, version source (flake input, nixpkgs attribute or dub
package), licence (SPDX), home, and prose crediting how the project uses it:
which packages or applications depend on it and for what ("libghostty-vt
parses every byte a program writes to the terminal and holds the screen").
A page per application (`docs/credits/terminal.md`, `docs/credits/hue.md`)
includes the parts that application ships; `docs/credits/index.md` includes
all of them.

**TPG13: Composition by inclusion.** The credits **must** be composed by
VitePress file inclusion only, its `@include` comment directive: no part is
copied into a page, and no licence text into prose. Each part includes its
component's licence text from `docs/credits/licenses/<id>/…`, files the build
stages from the component's own source (the upstream licence files of the
Nix derivation) and that are never copied by hand into the repository.

**TPG14: Completeness is checked.** A CI check **must** fail when a component
linked into or shipped with an artifact has no part, and when a part names a
component nothing ships. The shipped components are the dub packages in
`dub.selections.json` and `nix/dub-lock.json`, the static libraries and
bundled fonts the APK builders name (`terminal.nix`, `hue.nix`), and the
desktop builds' native libraries.

**TPG15: Credits in the app.** The app's credits page **must** show its
application page (`TPG12`) rendered by the embedded document viewer
([`TDV10`](./viewer.md)), with includes resolved
([hue `VIW5`–`VIW7`](../hue/viewer.md)), from files bundled with the app: on
Android as APK assets read in place, on the desktop beside the executable or
embedded at build time. Licence sections **may** start folded.

**TPG16: One set of files.** The bundled credits and licence files **must**
be the files the documentation site renders, staged by the same build step,
so the app and the site cannot disagree. The APK's plain `NOTICE`, kept for
tools that look for one, is generated from the parts.

**TPG17: hue's credits.** hue **must** show its own credits page
(`docs/credits/hue.md`) the same way, in its GUI and on Android.

## Wide screens (`TPG19`)

**TPG19: Bounded surfaces.** On a wide screen, a page, the settings page and a
sheet such as the touch guide or a confirmation **must** take at most 100
columns, centred. A sheet **must not** take more rows than its area; what
does not fit scrolls. Violation: a page's controls 100 columns from their
labels, or two rows drawn over each other.

## Status

| ID      | Status                                                                                                                                                                                | Traces to                                                                                                                            |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `TPG1`  | full                                                                                                                                                                                  | `AboutFacts`, `gatherAboutFacts`, `AboutPage`; `componentVersion`, `packageInfo`, `ghosttyBuild`                                     |
| `TPG2`  | partial: a dev build reports `0.1.0 (unknown commit)` on the phone; a release build's commit has not been run on a device                                                             | `buildStampOf`, `parseBuildStamp`, `logBuildInfo`; `build-sparkles-app.nix`, `terminal.nix`                                          |
| `TPG3`  | full                                                                                                                                                                                  | [`TPG12`](#credits-tpg12tpg17); `sourceUrl`, `docsUrl`, `creditsUrl`, `WorkspaceHost.open`                                           |
| `TPG4`  | full                                                                                                                                                                                  | `RingCoreLogger`, `installRingLog`, `ForwardingCoreLogger`                                                                           |
| `TPG5`  | full                                                                                                                                                                                  | `RotatingFileCoreLogger`, `installFileLog`, `installTerminalLog`                                                                     |
| `TPG6`  | partial: typing and pasting are tested, and an autofilled marker was searched for on the device (`TSE9`); copying and OSC 52 payloads are not in the marker test                      | [D24](./decisions.md); `routeTraceLog`, `runInstaller`                                                                               |
| `TPG7`  | full                                                                                                                                                                                  | `logBuildInfo`, `routeTraceLog`, `installTerminalLog`, `startAmServer`, `runInstaller`, `WorkspaceHost.create`                       |
| `TPG8`  | full                                                                                                                                                                                  | [design](./design.md); `LogPage`, `filterLog`, `parseLogQuery`, `parseLogFileLine`, `terminalLog`, `previousLogPath`                 |
| `TPG9`  | partial: the route recorded is the one the hook was given, not whether a system post succeeded (`TPR10`)                                                                              | `NotificationLog`, `NotificationRecord`, `TerminalView.deliverEvents`; `WorkspaceHost.notifications`, `notificationSource`           |
| `TPG10` | full; the deep link's fallback (`DroidPlatform.openPage`) has not been reached by a real notification tap                                                                             | [D15](./decisions.md); `NotificationPage`, `NotificationRecord.source`, `servicesFor`                                                |
| `TPG11` | full                                                                                                                                                                                  | [design](./design.md); `NotificationLog.unseen`, `markAllSeen`, `withUnseen`, `NotificationLog.unseenFrom`, `WorkspaceHost.treeTabs` |
| `TPG12` | full (`cd76314c`)                                                                                                                                                                     | [D30](./decisions.md); `docs/credits/index.md`, `terminal.md`, `hue.md`; `parsePart`                                                 |
| `TPG13` | full (`cd76314c`)                                                                                                                                                                     | [hue `VIW5`](../hue/viewer.md); `nix/packages/credits.nix`, `build-credits.sh`                                                       |
| `TPG14` | partial (`6e220838`): transitive desktop libraries (glfw, libGL, X11 and Wayland under raylib; fontconfig at run time) are not read, only the application closures' `libs` directives | `checkCredits`, `scanShipped`; `--check-credits`                                                                                     |
| `TPG15` | full (`89cb5b577`): on Android `asset:credits/terminal.md` is read in place from the APK, on the desktop `share/sparkles-terminal/credits` beside the executable                      | [`TDV10`](./viewer.md); `showCredits`, `bundledCredits`                                                                              |
| `TPG16` | full (`4d76baf0`)                                                                                                                                                                     | `terminal.nix`, `hue.nix`; `nix/packages/credits.nix`                                                                                |
| `TPG17` | partial (`cbe60d5bc`): `hue credits` shows it in the terminal and with `--gui`; hue on Android has no route to it                                                                     | [D30](./decisions.md); `CreditsCmd`, `creditsDocument`                                                                               |
| `TPG18` | full                                                                                                                                                                                  | [D38](./decisions.md); `groupOf`, `groupLog`, `ruleMatches`, `gitRootOf`, `loadGrouping`, `NotificationsConfig.agents`               |
| `TPG19` | full                                                                                                                                                                                  | `maxSurfaceCols`, `placeOne`, `Layer.backdrop`, `TouchGuide.windowed`                                                                |

→ [Overview](./index.md) · [Protocols](./protocols.md)
