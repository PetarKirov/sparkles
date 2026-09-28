# Sparkles Terminal on Android

The same terminal as a native Android app: a NativeActivity APK with no Java
in it, built entirely by Nix, running the `sparkles:terminal-view` core and
libghostty-vt on the device. It is also [nix-on-droid](https://github.com/nix-community/nix-on-droid)'s
Android app — the one that installs its bootstrap and runs its `login`. The
design and its requirements are in the
[specification](../../specs/terminal/android.md).

## Build and install

The Android SDK and NDK run on an x86_64 Linux host only.

```bash
nix build .#terminal-apk            # a plain terminal: /system/bin/sh
adb install result/terminal.apk
```

nix-on-droid's app is the same code with nix-on-droid's settings — its own
package id (`dev.sparkles.nix`), label, icon and bootstrap URL — and is built
by the `app/` flake in a nix-on-droid checkout:

```bash
nix build ./app#apk           # downloads the bootstrap on first start
nix build ./app#apk-offline   # carries the bootstrap inside
```

Any other flavour is a call to `mkTerminalApk` — app id, label, icon, and the
session (`mode = "shell"`, or `mode = "bootstrap"` with a `bootstrapUrl`):

```nix
sparkles.legacyPackages.x86_64-linux.mkTerminalApk {
  appId = "org.example.term";
  label = "Term";
  session = { mode = "shell"; };
}
```

Devices need Android 10 (API 29) or newer.

## Using it

- **Tap** the terminal to bring up the keyboard. **Drag** to scroll back
  (inside a program that uses the mouse, a drag scrolls _it_ instead).
  **Pinch** to change the font size.
- The **extra-keys row** above the keyboard has what a phone keyboard lacks:
  Esc, Tab, Ctrl, Alt, arrows, Home/End, PgUp/PgDn. Ctrl and Alt latch for the
  next key — tap Ctrl, then `c`.
- **Configuration** is Termux's, in `~/.termux/`:
  - `termux.properties`: `extra-keys = [['ESC','TAB','CTRL', …], […]]` sets
    the row (Termux's syntax, including `{key: …, display: …}`);
  - `colors.properties`: `foreground`, `background`, `cursor`,
    `color0`…`color15` as `#rrggbb`;
  - `font.ttf`: the terminal font.

  nix-on-droid's `terminal.font` and `terminal.colors` options write the last
  two; `termux-reload-settings` applies changes without a restart.

## nix-on-droid

On first start the app asks for the bootstrap location (Enter takes the
default, or the bootstrap bundled in an offline APK), downloads and unpacks it,
and starts nix-on-droid's `login`. Your configuration must name the app:

```nix
build.androidAppId = "dev.sparkles.nix";
```

A configuration created by the app's first start already has it.

nix-on-droid's `android-integration` tools work through the app's built-in
`am` server: `termux-open-url` and `termux-open <url>`, `termux-wake-lock`/
`termux-wake-unlock`, `termux-reload-settings`, `termux-setup-storage`.
`termux-open` on a local _file_ does not: handing a private file to another
app needs a content provider, which an app without Java cannot have — copy it
to `~/storage/shared` first.

## Limitations

- **No foreground service** (it would need Java): Android may stop a
  background session after a while. `termux-wake-lock` keeps the CPU up; on
  Android 14+, a long background job may also need the developer option
  _Disable child process restrictions_.
- The keyboard types through key events: there is no composing input
  (suggestions, swipe typing). Text an IME has no key for arrives on Android 12
  and newer.
- `targetSdk` is 28 — what lets nix-on-droid run programs from the app's
  storage — so the app is for F-Droid and direct installs, not the Play Store.
