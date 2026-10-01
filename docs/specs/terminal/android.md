# `apps/terminal` on Android — the nix-on-droid terminal

_**Status:** accepted; slices A–F delivered · **Date:** 2026-09-28 ·
**Owners:** `apps/terminal` (the app and its session modes),
[`sparkles:android`](../../guidelines/packages.md) (NDK/JNI plumbing),
`nix/packages/android/terminal.nix` (the APK builder) · **Consumer:**
[nix-on-droid](https://github.com/nix-community/nix-on-droid), whose Termux
fork (`nix-on-droid-app`) this replaces._

## Problem and scope

nix-on-droid runs a Nix environment on Android under `proot`. Its only link to
the Android world is a fork of Termux 0.118 whose job is: download a bootstrap
zip, unpack it into the app's data dir, and run `usr/bin/login` in a terminal.
Everything nix-on-droid needs from that app is small; everything Termux _is_
(Java, Gradle, a JNI pty, a dozen manifest components) is large, and none of it
is Nix-built.

This spec makes `apps/terminal` that app: a pure NativeActivity APK — no Java,
no DEX, built entirely by Nix — that renders with the same `sparkles:terminal-view`
core as the desktop terminal.

**In scope:** the Android build of `apps/terminal`; two session modes (a plain
shell, and a nix-on-droid bootstrap-then-login); the soft keyboard and an
extra-keys row; the clipboard; the `~/.termux/` appearance files nix-on-droid's
`terminal` module writes; native replacements for the Termux IPC that
nix-on-droid's opt-in `android-integration` tools call; the APK builder; an
on-device test oracle.

**Non-goals** (each with its reason):

| Not here                                          | Why                                                                                                                      |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| A foreground service                              | Needs a Java `Service` subclass; the app ships no code by decision (see [D2](#decisions))                                |
| Composing text (suggestions, swipe typing)        | The IME field ([NOD8](#requirements)) turns suggestions off, as Termux does: a terminal wants each keystroke, not a word |
| `RUN_COMMAND`, `DocumentsProvider`, share targets | Manifest components are Java classes; nix-on-droid does not use them                                                     |
| Upgrading an installed `com.termux.nix` in place  | Android pins the signing key and data dir per package; the new app is a new package ([D1](#decisions))                   |
| Play Store publication                            | `targetSdk 28` ([NOD3](#requirements)) is below Play's floor; F-Droid and sideloading accept it                          |

## Evidence (slice A spike, x86_64 emulator, API 36)

Established by running the spike APK, not by reading code:

- The terminal core cross-compiles for Bionic once `live.d` stops assuming glibc
  (`confstr`, the pty quartet, `ioctl`'s request type, the API-34
  `posix_spawn_file_actions_addchdir_np`) — fixed in `sparkles:event-horizon`.
- **The effective device floor is API 29**, for hue as much as for the terminal:
  LDC's static druntime uses native ELF TLS, which references
  `__tls_get_addr`, exported by Bionic from API 29. hue's declared `minSdk 26`
  is not a floor any device below 29 can load.
- `sparkles:ui-app`'s GPU loop froze every NativeActivity after one frame: a
  first frame that overruns the tick asks the kqueue backend for a zero-length
  timer, which libkqueue arms as a _disarmed_ timerfd. Fixed in
  `sparkles:event-horizon` (the zero timeout completes inline); hue had the same
  freeze.
- raylib's Android backend delivers key codes only — no text, no meta state —
  and blocks the whole thread in `ALooper_pollOnce(-1)` while the activity is
  unfocused. Text now comes from `sparkles.android.text_input`
  (`KeyCharacterMap` over JNI). The unfocused block is [NOD9](#requirements).
- ART aborts `AttachCurrentThread` on an event-horizon fiber stack. Every JNI
  call runs on one attached worker thread (`sparkles.android.jni.withJni`).
- `/system/bin/sh` spawned through `forkpty` from app data runs, reads input
  typed through `adb shell input text`, and renders.

## Decisions

**D1 — A new package, `dev.petar_kirov.sparkles.terminal.nix`.** Termux's data
dir is `/data/data/com.termux.nix`, and the fork's signing key is not ours, so
the new app cannot replace an installed one either way. nix-on-droid gains an app-id
option from which `installationDir`, `user.home` and the IPC paths derive; its
default stays `com.termux.nix`, so an unchanged configuration keeps working with
the old app. The bootstrap built _for_ the new app bakes its id into the
first-boot configuration it generates.

**D2 — No DEX, ever.** The user's decision. JNI calls into _framework_ classes
(`ClipboardManager`, `KeyCharacterMap`, `HttpURLConnection`, `PowerManager`,
`Intent`) are native code calling the platform, and are allowed. Consequences
accepted: no foreground service (Android may kill background sessions; a wake
lock is the partial mitigation). The soft keyboard needed no code of ours
either: it types into a framework `EditText`, created over JNI on the main
thread ([NOD8](#requirements)).

**D3 — `targetSdk 28`.** From API 29, an app targeting ≥ 29 may not `execve`
files in its own data dir. nix-on-droid's `login` execs `proot-static` from
there, so this is the only way it runs without Java (Termux's F-Droid build
makes the same choice). `minSdk` is 29 ([Evidence](#evidence-slice-a-spike-x86_64-emulator-api-36)).

**D4 — The installer runs inside the terminal.** A pty pair; a D thread owns
the slave and runs the installer as a line-mode program, so prompts, the URL
input and progress are terminal text, editable with the tty's own line
discipline. When it finishes, the login session replaces it in the same pane.
No second UI toolkit, and the emulator tests drive it with the same keystrokes
as a shell.

**D5 — The APK is data-driven.** An asset `session.conf` (`KEY=VALUE` lines) selects
the mode and its parameters; the Nix builder writes it. `apps/terminal` knows nothing about
nix-on-droid beyond the bootstrap format, and the nix-on-droid flake builds its
APK by calling sparkles' builder with its own values.

## Requirements

Normative for `apps/terminal` on Android unless the owner says otherwise.

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Verified by                                   |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| NOD1  | The APK contains no DEX (`hasCode="false"`) and is produced by a Nix derivation from tracked sources alone; `sign = false` yields the publishable unsigned artifact.                                                                                                                                                                                                                                                                                                                                                     | `unzip -l` in the derivation's check phase    |
| NOD2  | Package id, label, and session parameters are builder inputs; the same code builds both the plain terminal and the nix-on-droid app.                                                                                                                                                                                                                                                                                                                                                                                     | two flake outputs                             |
| NOD3  | `targetSdk` is 28 and `minSdk` 29 ([D3](#decisions)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `aapt2 dump badging`                          |
| NOD4  | **Plain mode:** the session is `/system/bin/sh` as a login shell (`-sh`), `HOME` = `<files>/home` (created), cwd `HOME`, `PATH` = `<files>/bin:/system/bin`. `<files>/bin` holds the app's own commands (`shellTools`): a `clear` that also erases the scrollback (`ESC[3J`), which Android's toybox `clear` does not.                                                                                                                                                                                                   | emulator: `echo $HOME` in the screen oracle   |
| NOD5  | **Bootstrap mode, install:** when `<files>/usr` is absent or empty, the installer prompts for the bootstrap base URL (default from `session.json`, Enter accepts), downloads `<url>/bootstrap-<arch>.zip` (`arch` ∈ `aarch64`, `x86_64` from the running ABI), and extracts it into `<files>/usr-staging`.                                                                                                                                                                                                               | emulator bootstrap test                       |
| NOD6  | Extraction honours the nix-on-droid bootstrap format: `SYMLINKS.txt` lines `target←linkpath` become symlinks, `EXECUTABLES.txt` entries become mode `0700`, and a missing list is an error. Only after every entry lands is `usr-staging` renamed to `usr`; any failure removes `usr-staging`, prints the cause, and offers retry. No entry may escape the staging dir.                                                                                                                                                  | host unit tests over zip fixtures             |
| NOD7  | **Bootstrap mode, session:** with `<files>/usr/bin/login` present, the session runs it as `-login` with `HOME`, `PREFIX`, `TMPDIR`, `PATH`, `LANG`, `TERM`, `COLORTERM` set and the Android system variables (`ANDROID_*`, `BOOTCLASSPATH`, `EXTERNAL_STORAGE`, …) passed through; `LD_LIBRARY_PATH` and `LD_PRELOAD` removed. A missing `login` falls back to `/system/bin/sh`.                                                                                                                                         | emulator: nix-on-droid first boot reaches `$` |
| NOD8  | Tapping the terminal shows the soft keyboard. Its text — any character, including ones it has no key for (`©`, `√`) — and its backspace and Enter reach the pty with the bytes a desktop keyboard would send: it types into a hidden framework `EditText` (`sparkles.android.ime`) whose edits are diffed each frame, on a main thread reached through a looper pipe (`sparkles.android.main_thread`; the manifest names `sparkles_onCreate` as `android.app.func_name`). Hardware keys arrive as key events, each once. | `adb shell input` + oracle; host key fixtures |
| NOD9  | An unfocused activity (a dialog, the notification shade) keeps draining the pty and stays responsive; a stopped one (no window) keeps draining without drawing.                                                                                                                                                                                                                                                                                                                                                          | emulator: output produced while shade open    |
| NOD10 | An extra-keys row sits above the keyboard: Esc, Tab, Ctrl, Alt (latching modifiers), arrows, Home/End/PgUp/PgDn, `-`, `/`, `\|`; `~/.termux/termux.properties`' `extra-keys` replaces the layout when present, on start and on reload.                                                                                                                                                                                                                                                                                   | emulator: PGUP/F12 layout test (ported)       |
| NOD11 | `~/.termux/font.ttf` and `~/.termux/colors.properties` (Termux format), when present, set the font and the palette, on start and on reload.                                                                                                                                                                                                                                                                                                                                                                              | emulator: colors test (ported)                |
| NOD12 | Copy (selection) and paste use the system clipboard.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | emulator                                      |
| NOD13 | A request socket at the path nix-on-droid's `termux-am` expects accepts its protocol and executes the intents the `android-integration` tools send — open URL/file, wake lock / unlock, reload settings — natively (JNI), refusing anything else with a message.                                                                                                                                                                                                                                                         | emulator: android-integration test (ported)   |
| NOD14 | **Test oracle:** when `<files>/.debug/screen-dump` exists, the app writes the screen text (`TerminalView.screenText`) to `<files>/.debug/screen.txt` (atomically) whenever the screen changed. Absent flag, no file I/O.                                                                                                                                                                                                                                                                                                 | the emulator tests themselves                 |

## Delivery slices

| Slice | Content                                                                                                             | State   |
| ----- | ------------------------------------------------------------------------------------------------------------------- | ------- |
| A     | Bionic build fixes, zero-timer fix, `sparkles:android` (logcat, assets, JNI worker, clipboard, text), spawn options | shipped |
| B     | `terminal.nix` builder + plain-mode APK (NOD1–4, NOD8, NOD12, NOD14), soft keyboard, focus/stop handling (NOD9)     | shipped |
| C     | Bootstrap mode (NOD5–7): installer, download, extraction                                                            | shipped |
| D     | Extra keys and `~/.termux` appearance (NOD10, NOD11)                                                                | shipped |
| E     | nix-on-droid side: app-id option, bootstrap for the new app, flake output building the APK, docs                    | shipped |
| F     | IPC (NOD13) and the emulator test port                                                                              | shipped |

## Verification

What was checked, where, and against what — beyond the host unit tests of
every pure module (`session`, `bootstrap_zip`, `installer` through a real pty,
`extra_keys`, `termux_config`, `am_command`, `screen_oracle`, and the
`terminal-view` spawn/adoption/colour tests).

| Claim                                                                                             | How                                                                                              | Where                   |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------- |
| NOD1, NOD3: no DEX; targetSdk 28, minSdk 29                                                       | the derivation refuses a `.dex`; `aapt2 dump badging`                                            | build                   |
| NOD4, NOD8, NOD12: plain shell, soft keyboard typing, output above the IME                        | `adb shell input`, keyboard taps, screenshots, the oracle                                        | x86_64 emulator, API 36 |
| NOD5–NOD7: install from a `file://` and an `http://` bootstrap, then `-login`; relaunch → `login` | a fake bootstrap, then nix-on-droid's real one built for `dev.petar_kirov.sparkles.terminal.nix` | emulator                |
| The whole of nix-on-droid: flakes first boot to `bash-5.2$`, config carries `build.androidAppId`  | nix-on-droid's `bootstrap_flakes.py`, ported, under droidctl                                     | emulator                |
| NOD9: output produced in the background is drained                                                | a command finishing while the app sat behind the launcher                                        | emulator                |
| NOD10, NOD11: extra keys, Ctrl latch (Ctrl+c interrupts), Up recalls history, a colour scheme     | taps on the row, the oracle, screenshots                                                         | emulator                |
| NOD13: wake lock, open URL, reload settings, refusals                                             | a termux-am-socket client run in the app's own shell; `dumpsys power`                            | emulator                |

Not yet run: the other ported emulator tests in CI (they need `app/flake.lock`
pinned to a published sparkles revision), and any physical device.

## Open issues

- **Phantom-process killing.** Android 12+ kills an app's child processes beyond
  a device-wide budget of 32 when the app is in the background; Termux users hit
  it with long builds. Without a foreground service there is no mitigation inside
  the app; the user-side one is the developer option
  "Disable child process restrictions" (API 34+).
- **IME resize** was measured in slice B: `adjustResize` reports a smaller
  content rect and leaves the native window full-size; the pane follows the
  content rect. Rotation goes through raylib's in-place-resize patch and has
  not been exercised on this app.
- **Where the bootstrap lives.** The APK's default bootstrap URL
  (`…/bootstrap-sparkles`) must be published by nix-on-droid's deploy
  (`BOOTSTRAP_FOR=sparkles`); until then the offline APK, or a URL typed at the
  prompt, is the way in.
- **`termux-open` on a local file** needs a content provider — refused, with a
  message, by `D2`.
- **libkqueue's own tests on Linux** fail two kqueue-backend unit tests
  (`changeList…queuedItsDelete`, `waitid…aRejectedProcAdd…`) at `main` too; the
  backend's tests normally run only on macOS CI. Unrelated to this work, found
  while adding the zero-timeout test.
