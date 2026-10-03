---
status: accepted
owner: sparkles:terminal
reviewed: 2026-10-03
---

# `apps/terminal` on Android — the nix-on-droid terminal

## Abstract

`apps/terminal` on Android is the terminal app of
[nix-on-droid](https://github.com/nix-community/nix-on-droid): a native
Android app with no Java code, built entirely by Nix, that runs a shell or
nix-on-droid's login session in the same terminal component as the desktop
build. It installs nix-on-droid's bootstrap from inside its own terminal,
honours the appearance files nix-on-droid's configuration writes, and answers
the Android requests that nix-on-droid's integration tools send, such as
opening a URL, holding a wake lock or linking shared storage, natively, by
calling the platform's own classes.

## Introduction

nix-on-droid runs a Nix environment on Android under `proot`. Its only link
to the Android world is an app: a fork of Termux 0.118 whose job is to
download a bootstrap archive, unpack it into the app's data directory, and run
`usr/bin/login` in a terminal. What nix-on-droid needs from that app is
small.

What Termux is, though, is large: Java, Gradle, a JNI pseudo-terminal and a
dozen manifest components, none of it built by Nix. Android also constrains
any replacement. From API 29 an app may not execute files from its own data
directory unless it targets an older API, and nix-on-droid's login executes
`proot-static` from exactly there. Without Java an app has no services, no
content providers and no way to receive an intent's extras, which rules out
the usual answers to background work, file sharing and notification taps.

This app is a pure NativeActivity: no DEX, built by a Nix derivation, and
rendering with the same `sparkles:terminal-view` component as the desktop.
Where it needs Android, it calls framework classes over JNI from native code,
which runs no Java of its own. Its installer is a program inside the terminal
rather than a second user interface, and the APK is data-driven: an asset
selects the session mode, so the same code builds a plain terminal and
nix-on-droid's app. [Decisions](#decisions) D1–D5 record these choices.

**In scope:** the Android build of `apps/terminal`; two session modes (a plain
shell, and a nix-on-droid bootstrap followed by its login); the soft keyboard
and the [extra-keys row](../../glossary.md#extra-keys-row); the clipboard; the
`~/.termux/` appearance files nix-on-droid's `terminal` module writes; native
replacements for the Termux requests that nix-on-droid's opt-in
`android-integration` tools send; the APK builder; and an on-device test
oracle. Everything else the terminal does on Android, from configuration to
selection and sessions, is specified once for every platform on the
[overview](./index.md)'s pages.

**Non-goals** (each with its reason):

| Not here                                          | Why                                                                                                                      |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| A foreground service                              | Needs a Java `Service` subclass; the app ships no code by decision ([D2](#decisions))                                    |
| Composing text (suggestions, swipe typing)        | The IME field ([NOD8](#requirements)) turns suggestions off, as Termux does: a terminal wants each keystroke, not a word |
| `RUN_COMMAND`, `DocumentsProvider`, share targets | Manifest components are Java classes; nix-on-droid does not use them                                                     |
| Upgrading an installed `com.termux.nix` in place  | Android pins the signing key and data directory per package; the app is a new package ([D1](#decisions))                 |
| Play Store publication                            | `targetSdk 28` ([NOD3](#requirements)) is below Play's floor; F-Droid and sideloading accept it                          |

[Platform findings](#platform-findings) records what running the app
established about Android; [Decisions](#decisions) and
[Requirements](#requirements) follow, with the
[Android integration](#android-integration) requests in a section of their
own. [Verification](#verification) records what was checked where, and the
delivery slices are in the [delivery plan](./PLAN.md#android-slices).

## Platform findings

Established by running the app on an x86_64 emulator (API 36), not by
reading code:

- The terminal core cross-compiles for Bionic once `live.d` stops assuming
  glibc: `confstr`, the pty functions, `ioctl`'s request type, and the API-34
  `posix_spawn_file_actions_addchdir_np`. The fixes live in
  `sparkles:event-horizon`.
- **The effective device floor is API 29**, for hue as much as for the
  terminal. LDC's static druntime uses native ELF TLS, which references
  `__tls_get_addr`, exported by Bionic from API 29, so hue's declared
  `minSdk 26` is not a floor any device below 29 can load.
- `sparkles:ui-app`'s GPU loop froze every NativeActivity after one frame: a
  first frame that overran the tick asked the kqueue backend for a
  zero-length timer, which libkqueue arms as a _disarmed_ timerfd.
  `sparkles:event-horizon` completes a zero timeout inline; hue had the same
  freeze.
- raylib's Android backend delivers key codes only, with no text and no meta
  state, and blocks the whole thread in `ALooper_pollOnce(-1)` while the
  activity is unfocused. Text comes from `sparkles.android.text_input`
  (`KeyCharacterMap` over JNI); the unfocused block is [NOD9](#requirements).
- ART aborts `AttachCurrentThread` on an event-horizon fiber stack, so every
  JNI call runs on one attached worker thread (`sparkles.android.jni.withJni`).
- `/system/bin/sh`, spawned through `forkpty` from the app's data, runs, reads
  input typed through `adb shell input text`, and renders.

## Decisions

**D1 — A new package, `dev.petar_kirov.sparkles.terminal.nix`.** Termux's
data directory is `/data/data/com.termux.nix`, and the fork's signing key is
not ours, so the new app cannot replace an installed one either way.
nix-on-droid gains an app-id option from which `installationDir`,
`user.home` and the request paths derive; its default stays
`com.termux.nix`, so an unchanged configuration keeps working with the old
app. The bootstrap built _for_ the new app bakes its id into the first-boot
configuration it generates.

**D2 — No DEX, ever.** The repository owner's decision. JNI calls into
_framework_ classes (`ClipboardManager`, `KeyCharacterMap`,
`HttpURLConnection`, `PowerManager`, `Intent`) are native code calling the
platform, and are allowed. Consequences accepted: no foreground service, so
Android may kill background sessions, which a wake lock partly mitigates. The
soft keyboard needs no code of ours either: it types into a framework
`EditText`, created over JNI on the main thread ([NOD8](#requirements)).

**D3 — `targetSdk 28`.** From API 29, an app targeting 29 or later may not
`execve` files in its own data directory. nix-on-droid's `login` executes
`proot-static` from there, so this is the only way it runs without Java;
Termux's F-Droid build makes the same choice. `minSdk` is 29
([Platform findings](#platform-findings)).

**D4 — The installer runs inside the terminal.** A pty pair; a D thread owns
the slave and runs the installer as a line-mode program, so prompts, the URL
input and progress are terminal text, editable with the tty's own line
discipline. When it finishes, the login session replaces it in the same pane.
There is no second user interface, and the emulator tests drive it with the
same keystrokes as a shell.

**D5 — The APK is data-driven.** An asset, `session.conf`, of `KEY=VALUE`
lines selects the mode and its parameters, and the Nix builder writes it.
`apps/terminal` knows nothing about nix-on-droid beyond the bootstrap format,
and the nix-on-droid flake builds its APK by calling sparkles' builder with
its own values.

## Requirements

Normative for `apps/terminal` on Android.

**NOD1: No code, Nix-built.** The APK **must** contain no DEX
(`hasCode="false"`) and **must** be produced by a Nix derivation from tracked
sources alone; `sign = false` yields the publishable unsigned artifact.

**NOD2: One code base, two apps.** The package id, label and session
parameters **must** be builder inputs, so the same code builds both the plain
terminal and the nix-on-droid app.

**NOD3: SDK levels.** `targetSdk` **must** be 28 and `minSdk` 29
([D3](#decisions)).

**NOD4: Plain mode.** In plain mode the session **must** be `/system/bin/sh`
as a login shell (`-sh`), with `HOME` = `<files>/home` (created), the working
directory `HOME`, and `PATH` = `<files>/bin:/system/bin`. `<files>/bin` holds
the app's own commands (`shellTools`), among them a `clear` that also erases
the scrollback (`ESC[3J`), which Android's toybox `clear` does not.

**NOD5: Bootstrap install.** In bootstrap mode, when `<files>/usr` is absent
or empty, the installer **must** prompt for the bootstrap base URL, with the
default from `session.conf` accepted by Enter; download
`<url>/bootstrap-<arch>.zip`, where `arch` is `aarch64` or `x86_64` from the
running ABI; and extract it into `<files>/usr-staging`.

**NOD6: Bootstrap extraction.** Extraction **must** honour the nix-on-droid
bootstrap format: `SYMLINKS.txt` lines `target←linkpath` become symlinks,
`EXECUTABLES.txt` entries become mode `0700`, and a missing list is an error.
Only after every entry lands is `usr-staging` renamed to `usr`; any failure
removes `usr-staging`, prints the cause and offers a retry. No entry **may**
escape the staging directory.

**NOD7: Bootstrap session.** In bootstrap mode, with `<files>/usr/bin/login`
present, the session **must** run it as `-login` with `HOME`, `PREFIX`,
`TMPDIR`, `PATH`, `LANG`, `TERM` and `COLORTERM` set, the Android system
variables (`ANDROID_*`, `BOOTCLASSPATH`, `EXTERNAL_STORAGE` and the like)
passed through, and `LD_LIBRARY_PATH` and `LD_PRELOAD` removed. A missing
`login` falls back to `/system/bin/sh`.

**NOD8: The soft keyboard.** A tap on the terminal **must** show the soft
keyboard, and its text, including characters it has no key for (`©`, `√`),
its backspace and its Enter **must** reach the pty as the bytes a desktop
keyboard would send. It types into a hidden framework `EditText`
(`sparkles.android.ime`) whose edits are compared each frame, on a main
thread reached through a looper pipe (`sparkles.android.main_thread`; the
manifest names `sparkles_onCreate` as `android.app.func_name`). Hardware keys
arrive as key events, each once.

**NOD9: Draining in the background.** An unfocused activity, behind a dialog
or the notification shade, **must** keep draining the pty and stay
responsive; a stopped one, with no window, keeps draining without drawing.

**NOD10: The extra-keys row.** An extra-keys row **must** sit above the
keyboard: Esc, Tab, Ctrl and Alt (latching modifiers), the arrows,
Home/End/PgUp/PgDn, `-`, `/` and `|`. The `extra-keys` entry of
`~/.termux/termux.properties` replaces the layout when present, on start and
on reload.

**NOD11: Termux appearance files.** `~/.termux/font.ttf` and
`~/.termux/colors.properties` (Termux format), when present, **must** set the
font and the palette, on start and on reload; on reload, an absent file
restores the defaults it overrode.

**NOD12: The clipboard.** Copy and paste **must** use the system clipboard;
selecting by touch is [`TSE`](./selection.md)'s.

**NOD13: The request socket.** A request socket **must** accept
`termux-am-socket`'s protocol and answer the requests nix-on-droid's
`android-integration` tools send, natively over JNI, one per connection. What
each request does is [NOD15–NOD22](#android-integration).

**NOD14: Test oracle.** When `<files>/.debug/screen-dump` exists, the app
**must** write the screen text (`TerminalView.screenText`) to
`<files>/.debug/screen.txt`, atomically, whenever the screen changed. Without
the flag it performs no such file I/O.

| ID    | Status | Verified by                                         |
| ----- | ------ | --------------------------------------------------- |
| NOD1  | full   | `unzip -l` in the derivation's check phase          |
| NOD2  | full   | two flake outputs                                   |
| NOD3  | full   | `aapt2 dump badging`                                |
| NOD4  | full   | emulator: `echo $HOME` in the screen oracle         |
| NOD5  | full   | emulator bootstrap test                             |
| NOD6  | full   | host unit tests over zip fixtures                   |
| NOD7  | full   | emulator: nix-on-droid's first boot reaches `$`     |
| NOD8  | full   | `adb shell input` and the oracle; host key fixtures |
| NOD9  | full   | emulator: output produced while the shade is open   |
| NOD10 | full   | emulator: the PGUP/F12 layout test (ported)         |
| NOD11 | full   | emulator: the colours test (ported)                 |
| NOD12 | full   | emulator                                            |
| NOD13 | full   | emulator: the android-integration test (ported)     |
| NOD14 | full   | the emulator tests themselves                       |

### Android integration

nix-on-droid's `android-integration.<tool>.enable` options install Termux's
client commands, which reach the app through `am` (`termux-am`, a
`termux-am-socket` client) and the socket of NOD13. These requirements are
the app's side of each tool; nix-on-droid owns the commands, their options
and `android-integration.am.socketPath`. A request is one `am` command line,
and the reply carries an exit status: `0` done, or `1` refused or failed with
a message on stderr.

**NOD15: On from first boot.** The Nix flavour's bootstrap **must** write
into the first configuration `android-integration.<tool>.enable = true` for
`am`, `termux-open`, `termux-open-url`, `xdg-open`, `termux-setup-storage`,
`termux-reload-settings`, `termux-wake-lock` and `termux-wake-unlock`, and
`android-integration.am.socketPath` set to NOD16's path, so that all eight
commands are on `PATH` after first boot with no edit. It **must not** enable
`unsupported`.

**NOD16: Socket location.** The server **must** listen on
`SessionPaths.amSocket`: `session.conf`'s `amSocket` when set, else Termux's
layout `<files>/apps/<package>/termux-am/am.sock`. A bootstrap session
**must** export the same path as `NIX_ON_DROID_AM_SOCKET`, nix-on-droid's
channel default for `socketPath`. A path over the 107 bytes of `sun_path`
**must** be logged and the server not started. The Nix flavour's path is
`/data/data/<id>/files/apps/termux-am/am.sock`, 79 bytes, where Termux's
layout takes 115 for this app's id.

**NOD17: Open a URL.** `am start -a android.intent.action.VIEW -d <url>`,
which `termux-open-url`, `xdg-open <url>` and `termux-open <url>` send,
**must** start an `ACTION_VIEW` activity for the URL and reply `0`; if Android
cannot start one, the reply is `1` with its reason.

**NOD18: Open a local file.** `termux-open <file>` of a kind the app cannot
view **must** be refused (`1`) with a message naming the cause, that there is
no content provider (`D2`), and the workaround, `~/storage/shared`, starting
no activity. A file the app can view opens in the app ([`TDV1`](./viewer.md)).

**NOD19: Wake lock.** `termux-wake-lock` **must** take a partial wake lock
tagged `sparkles:terminal`, held until `termux-wake-unlock` releases it or the
process ends.

**NOD20: Shared storage.** `termux-setup-storage` **must** request
`READ_EXTERNAL_STORAGE` and `WRITE_EXTERNAL_STORAGE` through the system
dialog when they are not granted, waiting up to 120 s for the answer, and once
granted link `~/storage/{shared,downloads,dcim,documents,movies,music,pictures}`
to `/storage/emulated/0/…`. If they are granted already there is no dialog; if
denied, there are no links and a warning is logged.

**NOD21: Reload settings.** `termux-reload-settings` **must** make the running
session re-apply NOD10 and NOD11, the extra keys, colours and font, without a
restart, an absent file restoring the defaults.

**NOD22: Refusal.** Any other request **must** be refused (`1`) with a message
listing what the app answers, and **must** have no other effect.

`android-integration.unsupported` is not part of this contract. It installs
only Termux's `termux-backup`, a local `tar` script that never reaches the
app; nix-on-droid's packaging removes the rest of Termux's leftovers,
`termux-restore` included. The bootstrap leaves it off (NOD15).

Status follows [the spec guide](../../guidelines/spec-docs.md#keep-evidence-scoped-and-honest):
`verified` means the named check passed in the named configuration, and
`partial` names what was not checked or does not hold. The device evidence
was taken in place on an existing installation of the Nix flavour on a Xiaomi
11T Pro (arm64), with sparkles `ce3565247` and nix-on-droid `e3e71f5`
(`feat/android-app-id`).

| ID    | Status                                                                                                                                                                                   | Evidence                                                                             | Verified by                                                                                                                                   |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| NOD15 | partial: the eight `enable` settings verified by a first boot; the `socketPath` setting verified in the bootstrap's `login-inner` and applied by hand on the device, not by a first boot | `nix/packages/android/terminal-nix.nix`                                              | phone: first boot printed the settings; `type -p` found all eight                                                                             |
| NOD16 | verified (unit tests; phone); the over-length log is not exercised                                                                                                                       | `SessionPaths.amSocket`, `startAmServer`, `sessionEnvironment`, `parseSessionConfig` | `session.SessionPaths`, `session.sessionEnvironment` tests; phone: `echo $NIX_ON_DROID_AM_SOCKET`, every tool below reaching the server       |
| NOD17 | verified (all four forms); the failure reply is not exercised                                                                                                                            | `classify`, `viewUri`                                                                | phone: each form brought Chrome to the front, and Back returned to the terminal                                                               |
| NOD18 | verified                                                                                                                                                                                 | `classify`, `apps/terminal/src/am_server.d`                                          | phone: `termux-open .bashrc` printed the message, and the terminal stayed in front                                                            |
| NOD19 | verified                                                                                                                                                                                 | `setWakeLock`, `wakeLockHeld`                                                        | phone: `dumpsys power` listed the lock after the first command and not after the second                                                       |
| NOD20 | partial: grant, links, reading and writing through them, and a second run verified; denial is not exercised                                                                              | `requestPermissions`, `hasPermission`, `storageLinks`                                | phone: dialog answered, `ls -l ~/storage`, a file written to `downloads` and seen in `/sdcard/Download`                                       |
| NOD21 | partial: keys and colours verified, including the restored defaults; the font is chosen at start only and not reloaded                                                                   | `takeReloadRequest`, `loadSettings`, `recolor`                                       | phone: the key row via the oracle's `keys.txt`, the background via a sampled screen pixel; `terminal_view.component.recolorReplacesTheScheme` |
| NOD22 | verified                                                                                                                                                                                 | `classify`                                                                           | phone: `am start -a android.settings.SETTINGS`                                                                                                |

## Verification

What was checked, where, and against what, beyond the host unit tests of
every pure module (`session`, `bootstrap_zip`, `installer` through a real pty,
`extra_keys`, `termux_config`, `am_command`, `screen_oracle`, and the
`terminal-view` spawn, adoption and colour tests).

| Claim                                                                                             | How                                                                                              | Where                   |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------- |
| NOD1, NOD3: no DEX; targetSdk 28, minSdk 29                                                       | the derivation refuses a `.dex`; `aapt2 dump badging`                                            | build                   |
| NOD4, NOD8, NOD12: plain shell, soft keyboard typing, output above the IME                        | `adb shell input`, keyboard taps, screenshots, the oracle                                        | x86_64 emulator, API 36 |
| NOD5–NOD7: install from a `file://` and an `http://` bootstrap, then `-login`; relaunch → `login` | a fake bootstrap, then nix-on-droid's real one built for `dev.petar_kirov.sparkles.terminal.nix` | emulator                |
| The whole of nix-on-droid: flakes first boot to `bash-5.2$`, config carries `build.androidAppId`  | nix-on-droid's `bootstrap_flakes.py`, ported, under droidctl                                     | emulator                |
| NOD9: output produced in the background is drained                                                | a command finishing while the app sat behind the launcher                                        | emulator                |
| NOD10, NOD11: extra keys, Ctrl latch (Ctrl+c interrupts), Up recalls history, a colour scheme     | taps on the row, the oracle, screenshots                                                         | emulator                |
| NOD13: wake lock, open URL, reload settings, refusals                                             | a termux-am-socket client run in the app's own shell; `dumpsys power`                            | emulator                |
| NOD4, NOD8, NOD12: plain shell, keyboard, clipboard                                               | Gboard typing, `©`, backspace, CTRL + letters, `clear`                                           | phone (arm64)           |
| NOD5–NOD7: the Nix flavour's first boot with flakes to `bash-5.2$`                                | the docs' install steps, a `file://` bootstrap                                                   | phone (arm64)           |
| NOD15–NOD22                                                                                       | in place over that installation; see [Android integration](#android-integration)                 | phone (arm64)           |

Not run: the ported emulator tests against the renamed package with NOD16's
socket path, and a first boot with a bootstrap that writes `socketPath`
(NOD15).

## Open issues

- **Phantom-process killing.** Android 12 and later kill an app's child
  processes beyond a device-wide budget of 32 while the app is in the
  background; Termux users hit it with long builds. Without a foreground
  service there is no mitigation inside the app; the user-side one is the
  developer option "Disable child process restrictions" (API 34 and later).
- **IME resize.** `adjustResize` reports a smaller content rectangle and
  leaves the native window full-size; the pane follows the content
  rectangle. Rotation goes through raylib's in-place resize and repaints the
  whole window on the new size.
- **Where the bootstrap lives.** The APK's default bootstrap URL
  (`…/bootstrap-sparkles`) is not published, so Enter at the prompt fails. A
  bootstrap built for the app (`terminal-nix-bootstrap-<arch>`, or
  nix-on-droid's `ANDROID_APP_ID=… nix run .#deploy`) must be hosted, or the
  offline APK or a `file://` location used.
- **`termux-open` on a local file** needs a content provider, so it is
  refused with a message by `D2` (NOD18).
- **The font on reload** (NOD21): `termux-reload-settings` re-applies the keys
  and colours but not `~/.termux/font.ttf`, which the app chooses at start
  only. Termux reloads it; here that means rebuilding the font atlas in the
  running session.
- **libkqueue's own tests on Linux.** Two kqueue-backend unit tests
  (`changeList…queuedItsDelete`, `waitid…aRejectedProcAdd…`) fail on Linux;
  the backend's tests normally run only on macOS CI.

→ [Overview](./index.md) · [Delivery plan](./PLAN.md) · [Testing](./testing.md)
