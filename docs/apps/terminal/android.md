# sparkles:terminal on Android

The same terminal as a native Android app: a NativeActivity APK with no Java
in it, built entirely by Nix, running the `sparkles:terminal-view` core and
libghostty-vt on the device. It is also [nix-on-droid](https://github.com/nix-community/nix-on-droid)'s
Android app — the one that installs its bootstrap and runs its `login`. The
design and its requirements are in the
[specification](../../specs/terminal/android.md).

## Build and install

There are two variants, both built from this repository:

| Variant         | Package id                              | Runs on first start                          | Build                          |
| --------------- | --------------------------------------- | -------------------------------------------- | ------------------------------ |
| Plain           | `dev.petar_kirov.sparkles.terminal`     | `/system/bin/sh`                             | `nix build .#terminal-apk`     |
| Nix (bootstrap) | `dev.petar_kirov.sparkles.terminal.nix` | nix-on-droid's bootstrap install, then login | `nix build .#terminal-nix-apk` |

Both are labelled `sparkles:terminal` and can be installed side by side. The
Nix variant runs nix-on-droid in place of its Termux-based app; the bootstrap
it installs is built for its package id by nix-on-droid's
`lib.bootstrapPackages` (the `nix-on-droid` flake input). Its
`terminal-nix-apk-unsigned` is the release build, for signing outside Nix.

The APKs build on x86_64 Linux and Apple Silicon macOS, the hosts the Android
NDK ships a toolchain for, and either host produces both device ABIs. A
published build comes from Linux: the two hosts' APKs behave the same but are
not byte-identical, and reproducible builds compare bytes. Devices need
Android 10 (API 29) or newer.

### On the emulator

The Android dev shell's `hue-emulator` boots an emulator in the host's own
ABI (x86_64 on Linux, arm64 on a Mac), with the host keyboard enabled; it
serves any of the apps. Leave it running and use a second terminal:

```bash
nix develop .#android -c hue-emulator
```

### On a phone

Enable _Developer options_ (tap _Build number_ seven times), then _USB
debugging_, and connect the phone; accept its prompt to trust the computer.
`adb devices` lists it. Some vendors add a step: Xiaomi's MIUI needs _Install
via USB_ enabled as well, and asks on the phone to confirm each new app.

### The plain variant

```bash
nix build .#terminal-apk
nix develop .#android -c adb install -r result/terminal.apk
```

With both an emulator and a phone connected, pick one with
`ANDROID_SERIAL=<serial from adb devices>`.

### The Nix variant

```bash
nix build .#terminal-nix-apk
nix develop .#android -c adb install -r result/sparkles-terminal-nix.apk
```

On first start the app asks for the bootstrap location. Its default download
location is not hosted yet, so install the bootstrap from a file. The zip
must be the device's architecture — `aarch64` for a phone or a Mac's
emulator, `x86_64` for a Linux host's emulator — and building it needs
`--impure`:

```bash
nix build --impure .#terminal-nix-bootstrap-aarch64 -o bootstrap
nix develop .#android -c bash -c '
  adb push bootstrap/bootstrap-aarch64.zip /data/local/tmp/
  adb shell "run-as dev.petar_kirov.sparkles.terminal.nix sh -c \"mkdir -p files/n-o-d && cp /data/local/tmp/bootstrap-aarch64.zip files/n-o-d/\""'
```

Start the app and answer the prompt with the directory holding the zip:

```text
file:///data/user/0/dev.petar_kirov.sparkles.terminal.nix/files/n-o-d
```

Alternatively, `nix build --impure .#terminal-nix-apk-offline` carries both
architectures' bootstraps inside, so Enter at the prompt installs offline (the
APK is `result/sparkles-terminal-nix-offline.apk`).

The installer then starts nix-on-droid's `login`, which asks whether to use
flakes and builds the first generation: hundreds of megabytes of downloads
and around ten minutes on a phone, ending at a `bash` prompt.

### Other flavours

Any other flavour is a call to `mkTerminalApk` — app id, label, icon, and the
session (`mode = "shell"`, or `mode = "bootstrap"` with a `bootstrapUrl`):

```nix
sparkles.legacyPackages.${system}.mkTerminalApk {
  appId = "org.example.term";
  label = "Term";
  session = { mode = "shell"; };
}
```

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
build.androidAppId = "dev.petar_kirov.sparkles.terminal.nix";
```

A configuration created by the app's first start already has it.

nix-on-droid's `android-integration` tools work through the app's built-in
`am` server: `am`, `termux-open-url`, `xdg-open` and `termux-open <url>`,
`termux-wake-lock`/`termux-wake-unlock`, `termux-reload-settings`,
`termux-setup-storage`. All of them are on from first boot: the bootstrap
writes `android-integration.<tool>.enable = true;` into the first
configuration, where you can turn any of them off.
`termux-open` on a local _file_ does not: handing a private file to another
app needs a content provider, which an app without Java cannot have — copy it
to `~/storage/shared` first.

## Limitations

- **No foreground service** (it would need Java): Android may stop a
  background session after a while. `termux-wake-lock` keeps the CPU up; on
  Android 14+, a long background job may also need the developer option
  _Disable child process restrictions_.
- The on-screen keyboard's suggestions and swipe typing are off: a terminal
  wants each keystroke. Everything else it types arrives, symbols like `©` and
  `√` included.
- `targetSdk` is 28 — what lets nix-on-droid run programs from the app's
  storage — so the app is for F-Droid and direct installs, not the Play Store.
