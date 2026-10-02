# About, logs and the notification log (`TPG`)

_**Status:** proposed · **Date:** 2026-10-02 · **Owners:** `apps/terminal`
(the pages); `sparkles:base` (the log ring and file sink) · **Scope:** the
three read-mostly pages of the application. Their layout is chosen from the
mockups ([design](./design.md)); this page fixes their content and
behaviour._

## Why

On Android, `adb logcat -s terminal` is the only way to see what the app did,
the licences are an APK asset nobody can open, and nothing says which build is
running. A notification that arrived while the screen was off is gone once
dismissed. The desktop has the same gaps behind a terminal of its own.

## About (`TPG1`–`TPG3`)

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                     | Status      | Traces to                                       |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------- |
| `TPG1` | The about page must show the name (`sparkles:terminal`), the version and short commit it was built from, the build type, libghostty-vt's version and build options, the rendering backend, and on Android the package id, `versionCode` and the device ABI and API level. The same facts as hue's startup popup ([`NSI1`](../hue/notifier.md)). | not started | proposed generated `build_info`; `logBuildInfo` |
| `TPG2` | The version and commit come from the build, not from the source tree at run time: the Nix build passes them in; a plain `dub build` reports `dev`. A dirty tree is reported as such, never as the last commit.                                                                                                                                  | not started | `nix/packages/android/build-apk.nix`            |
| `TPG3` | The page must list every third-party component with its licence, from the same `NOTICE` the APK carries (`terminal.nix`), and offer links to the source and the docs, opened through the link allow-list ([`TPR6`](./protocols.md)).                                                                                                            | not started | `readAssetText`                                 |

## Logs (`TPG4`–`TPG8`)

| ID     | Requirement                                                                                                                                                                                                                                                                                               | Status      | Traces to                                          |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------- |
| `TPG4` | A ring sink in `sparkles:base` must keep the last N log entries (N = 10 000, entries over 4 KiB truncated) and forward each entry to the sink it replaced (logcat, stderr), so installing it changes nothing else. Writing to it is `@nogc`; a full ring overwrites the oldest entry and counts the drop. | not started | `CoreLogger`, `sharedCoreLog`                      |
| `TPG5` | A file sink must append the same entries to `<state dir>/sparkles-terminal/terminal.log`, rotating at 1 MiB to one `terminal.log.1`, so the previous run's last entries survive a crash. A write failure disables the file sink with one logged warning; it never stops the app.                          | not started | `DeltaTimeLogger` (the stderr sink it sits beside) |
| `TPG6` | The log must never contain text typed, pasted, autofilled or copied, nor OSC 52 payloads; protocol events log their kind, pane and length only. Violation: a test that types, pastes and autofills a marker string and finds it in the ring or the file.                                                  | not started | [D24](./decisions.md)                              |
| `TPG7` | Sources: the app's own logger calls, terminal-view (its raylib `TraceLog` output routed into the logger), the `am` server, the installer, and — at `debug` — protocol events and notifications.                                                                                                           | not started | `logBuildInfo`                                     |
| `TPG8` | The log page must filter by level, search, follow the tail while scrolled to the bottom (and stop following when scrolled up), copy the visible entries, share them (Android `ACTION_SEND`), and show the previous run's file when asked. A new entry never moves a reader who has scrolled up.           | open        | [design](./design.md)                              |

## Notification log (`TPG9`–`TPG11`)

| ID      | Requirement                                                                                                                                                                                                                                                         | Status      | Traces to             |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------- |
| `TPG9`  | Every notification event ([`TPR8`](./protocols.md)) is recorded with its time, source pane (tab title and pane title at the time), title, body, protocol, and whether it was shown as a system notification, a toast, or neither. The last 500 are kept, in memory. | not started | [D14](./decisions.md) |
| `TPG10` | Activating an entry selects its tab and focuses its pane; an entry whose pane has closed says so and stays inert. This is the deep-link fallback of [`TPR12`](./protocols.md).                                                                                      | not started | [D15](./decisions.md) |
| `TPG11` | Entries not yet seen are marked, and the count of unseen entries is shown where the pages are reached from (the lantern row, the tab strip); opening the page marks them seen.                                                                                      | open        | [design](./design.md) |

→ [Overview](./index.md) · [Protocols](./protocols.md)
