# hue on Android — requirements & architecture

_**Status:** shipped v0 on raylib — every requirement confirmed on a physical
arm64 device (Xiaomi 11T Pro), the emulator having been the development
target; pinch-zoom (`AND6`) host-tested only. The native arm (`AND15`) is the
default APK, run on the emulator (API 36) and not yet on hardware.
· **Date:** 2026-11-07 · **Scope:** the Android
port of the GUI sink — `apps/hue` (`android_entry.d`, `android_glue.d`,
`android_paths.d`, `gui_surface.d`, the remaining `version (Android)` gates),
`libs/raylib-text` (`FontSources`), `libs/syntax`
(`GrammarRegistry.fromSonames`), `nix/packages/android/`, `apps/hue/android/`._

hue runs on Android as a pure `NativeActivity` APK — no Java, no DEX
(`hasCode="false"`), on either of the desktop's two arms:

- **The native arm** (`.#hue-apk`, the default): `sparkles:wsi`'s Android
  backend owns the activity — its window, input, soft keyboard, insets and
  frames — and runs hue's `main()` on a thread of its own (`AndroidWsiMain`,
  `apps/hue/src/android_entry.d`); `sparkles:ui-vulkan` draws. No raylib is
  linked. dub builds it, from apps/hue's `android` configuration.
- **The raylib arm** (`.#hue-raylib-apk`, until the raylib window is retired):
  raylib's `PLATFORM_ANDROID` backend (`android_native_app_glue` + EGL/GLES2)
  owns `android_main()` and calls the library's `main()`; a raw `ldc2 -i`
  cross build makes the library.

Either way the whole desktop GUI — the `sparkles:ui` widget pipeline,
tree-sitter highlighting, the markdown preview, ghostty ansi fences, the
explorer, twoslash — carries over, and `gui.d` names no platform: what a phone
changes (touch, the soft keyboard, the clipboard) it asks the arm behind
`gui_surface` (`AND16`). The APK, and every native dependency in it, is built by
nix (no Gradle): see `nix/packages/android/`.

## Architecture decisions

| Decision          | Choice                                                                                                                                                                                                                                                                                                                                                          | Where                                                       |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Rendering backend | The native arm by default: `sparkles:wsi`'s Android backend and `sparkles:ui-vulkan` (Vulkan 1.1), the library built by dub from the `android` configuration. The raylib arm beside it: raylib cross-built for `PLATFORM_ANDROID` (static, per ABI), `RaylibCanvas`                                                                                             | `apps/hue/dub.sdl`, `nix/packages/android/{hue,raylib}.nix` |
| ABIs              | `arm64-v8a` (devices) + `x86_64` (emulator); the dual-ABI `ldc-android` (dlang.nix) carries one ldc2.conf section per target. API level 26 throughout — `ndk.minSdk` is the single source for the clang wrappers, every native dep's platform flag, and aapt2's `--min-sdk-version`                                                                             | `nix/packages/android/ndk.nix`, dlang.nix `feat/ldc-wasm`   |
| Entry / dispatch  | Native arm: `AndroidWsiMain` (`sparkles_wsi_onCreate`) runs `main(["hue"])` on the application thread, then `_exit`s. Raylib arm: raylib's glue calls `main()`. Either way `pickBackend` answers `gui` unconditionally; the terminal session (`sparkles.tui.terminal`) is empty on Android, which has no terminal                                               | `android_entry.d`, `app.d`                                  |
| Font resolution   | fontconfig-free: `FontSet.FontSources` scans the extracted `fonts/` dir + `/system/fonts`; coverage from build-time `fc-query` `.charset` sidecars. The font set itself is shared with the desktop (`nix build .#sparkles-fonts`, also reachable from `terminal --font-dir`): Maple Mono NF CN primary + Uiua386 (codepoint-mapped) + FiraCode/DejaVu fallbacks | `libs/raylib-text/…/font_set.d`, `nix/packages/fonts.nix`   |
| Grammars          | parsers ship as `lib/<abi>/libtree_sitter_<lang_>.so`, dlopen'd by bare soname from the app's linker namespace (`GrammarRegistry.fromSonames`); queries are extracted assets                                                                                                                                                                                    | `libs/syntax/…/ts/registry.d`, `ts-grammars.nix`            |
| Assets            | one `assets/` bundle (fonts + sidecars, grammar queries, sample docs), extracted by D over `AAssetManager` on first run, keyed by `bundle-hash`, driven by `asset-manifest.txt` (AAssetDir cannot list subdirectories)                                                                                                                                          | `android_glue.d`, `nix/packages/android/hue.nix`            |
| Lifecycle         | rotation resizes IN PLACE (the native arm follows the surface; the nix raylib build carries raylib-android-in-place-resize.patch — stock raylib — verified through the released 6.0 tag — never resizes on Android), and the process ends with `main()` — a statically linked druntime cannot `rt_init` twice in a reused process                               | raylib.nix patch, manifests, `app.d`                        |
| Input             | `sparkles:input`'s gesture recogniser, behind the arm's event source: tap = click, drag = kinetic scroll + fling, long-press = selection (then drag to extend), pinch = font zoom; a five-segment bottom toolbar covers the keyboard essentials, shown wherever the target cannot hover (`InputCapabilities`); hardware keyboards keep every desktop binding    | `gui.d`, `gui_surface.d`                                    |
| Logging           | a `CoreLogger` subclass writing to logcat tag `hue` (stderr goes nowhere in an activity), at `warning` — hue emits only degradation warnings                                                                                                                                                                                                                    | `android_glue.d`                                            |
| Debug hooks       | `<dataDir>/hue-debug.env` (`KEY=VALUE`) loads into the environment at boot, re-enabling every `HUE_GUI_*` golden/screenshot hook on-device                                                                                                                                                                                                                      | `android_paths.d`, `android_glue.d`                         |

## Requirements

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status                                        | Where                                                                    |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------ |
| AND1  | `nix build .#hue-apk` (and `.#hue-raylib-apk`) produces an installable dual-ABI NativeActivity APK, fully nix-built (aapt2 + zipalign + apksigner) and **bit-reproducible**; debug vs release is a build knob, and a release build refuses the checked-in key. Distribution adds a third state — an _unsigned_ release variant, because nix must never hold the signing key ([`FDR1`](./fdroid.md))                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | full                                          | `nix/packages/android/{hue,build-apk}.nix`                               |
| AND2  | The GUI sink boots on-device with no CLI: built-in document, asset bundle extracted idempotently, logcat logging                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | full (device)                                 | `app.d`, `android_glue.d`                                                |
| AND3  | Fonts resolve without fontconfig: Maple Mono NF CN primary (4 styled faces), FiraCode Nerd Font Mono + DejaVu fallbacks, `/system/fonts` last; styled faces by the sibling naming convention, fallbacks ranked so a Regular face wins                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | full                                          | `font_set.d` `FontSources`                                               |
| AND4  | Syntax highlighting on-device: all bundled grammars as soname-dlopen'd native libs, queries from assets, plain-text degrade intact (totality)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | full (device)                                 | `registry.d` `fromSonames`                                               |
| AND5  | The markdown preview incl. ` ```ansi ` fences (libghostty-vt cross-built, `-Dsimd=false`) renders on-device                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | full (device)                                 | `libghostty-vt.nix`, `gui_ansi.d`                                        |
| AND6  | Touch: drag scroll + fling, tap = click, long-press selection, pinch zoom, toolbar for theme/view/tree/line-numbers (and `copy` while a selection is live), system back closes tree → exits                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | full (pinch: host-tested, on-device untested) | `gui.d`, `sparkles.input.gesture`                                        |
| AND7  | Lifecycle: pause/resume identical frames; rotation resizes in place — same process, scroll/document/theme preserved, reflow at the new width                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | full (device)                                 | raylib patch, manifests, `app.d`                                         |
| AND8  | The explorer browses the extracted sample docs (markdown, D, twoslash) with file-type icons                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | full (device)                                 | `app.d` (Android tree root), `hue.nix` docs                              |
| AND9  | On-device goldens: `hue-debug.env` + `HUE_GUI_SCREENSHOT` (data-dir-anchored) round-trip via `adb shell run-as`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | full                                          | `gui.d`, `android_paths.d`                                               |
| AND10 | `hue-apk-repo`: the whole tracked repository (sources, markdown, text aux; minus docs/.vitepress and binaries) embedded as the explorer browse surface — ~1.5k files, ~1 s first-run extraction                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | full (device)                                 | `hue.nix` `repoDocsTree`                                                 |
| AND11 | **CLI-less diff/PR entry**: Android has no command line, so diff and PR sessions must be reachable through the UI — the explorer opens a worktree diff from a `GitStatus`-badged file, a **forge PR picker** lists PRs over the forge seam ([`DPR7`](./diff-view.md)), and an **intent/share handler** opens a forge PR URL from the browser/share sheet directly into hue. Forge tokens come from the config file ([`CFG12`](./config.md)) — plain-text storage, documented.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | not started (planned)                         | [`DPR7`](./diff-view.md); [`CFG12`](./config.md); proposed intent filter |
| AND12 | **Touch review vocabulary**: tap expands/collapses a hunk; long-press opens the stage / discard / comment menu (the existing `gui_touch.d` tap / long-press machinery); next/prev-hunk and next-conflict as toolbar buttons; destructive ops ([`DST4`](./diff-view.md)) confirm through notifier-style popups with touch-sized targets. Inline editing ([`DST5`](./diff-view.md)) is deferred until the [`UIA9`](./ui-architecture.md) editor component has soft-keyboard support.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | not started (planned)                         | `gui_touch.d`; [`DST*`](./diff-view.md); [`UIA9`](./ui-architecture.md)  |
| AND13 | **No type overlay on device**: the diff type overlay ([`DVT`](./diff-view.md)) needs `twoslash-extract`, a DMD frontend, `dub describe` and a git worktree — none of which exist inside the APK. Android renders the diff without types and without verdict badges, and must not present the affordance at all (no greyed-out control, no notice on every file) — a capability the platform lacks is absent, not broken. A PR session viewed on Android is a text-and-comments review.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | not started (planned)                         | [`DVT7`](./diff-view.md) degradation; `AND11`                            |
| AND14 | **The leader menu is the command surface.** Android has no keyboard, so every command reachable only by a key is unreachable there. The [lantern](./lantern.md) panel already enumerates them and already carries hit ids, so making its rows tappable — tap activates, tap a group drills down, the system Back key pops one level — turns the whole keymap into a touch menu from **one** definition rather than a parallel toolbar that would drift from it ([`LTN13`](./lantern.md)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | not started (planned)                         | [`LTN13`](./lantern.md); `lantern_view` hit ids; `Key.back`              |
| AND15 | **The native arm.** The APK's library is apps/hue's `android` dub configuration — `sparkles:wsi`'s activity, window, input and frames, drawn by `sparkles:ui-vulkan`, no raylib in the closure (its build document says so, `checkHueBuildInfo`) — and every requirement above that the raylib APK meets holds on it: the built-in document, extracted assets and fonts (`AND2`–`AND4`), the explorer (`AND8`), touch (`AND6`, long-press drag through `RunConfig.longPressDrags`), Back closing the tree then leaving, rotation in place, leaving and returning. Beyond the raylib APK: the soft keyboard follows the search, goto and filter lines (`EDI9`) with the layout ending above it, the clipboard is read as well as written (a paste chord in every field), the action bar sits inside the safe insets, and an idle window draws nothing. The CRT runs on an unturned panel and is skipped on a turned (pre-rotated) one ([`UVK15`](../ui-vulkan/SPEC.md)) | full (emulator, API 36); not run on hardware  | `android_entry.d`, `dub.sdl` `android`, `hue.nix` `libhue`               |
| AND16 | **No platform in the window code.** What a phone changes is a question `gui.d` asks the arm behind `gui_surface`: what its input offers (`capabilities` — a target that cannot hover gets the action bar, taps for clicks and the soft keyboard), `softKeyboard`, `visibleHeight`, and whether the clipboard reads (`clipboardReadable`). The native host answers from the platform; the raylib arm answers for the raylib APK in its own half. The extracted font directory, which names hue's asset layout, is the one `version (Android)` left in `gui.d`                                                                                                                                                                                                                                                                                                                                                                                                           | full                                          | `gui_surface.d`, `gui.d`                                                 |

## Desktop-parity checklist

Interaction parity is honest, not aspirational: **touch covers the reading
workflows; full parity needs a (BT) keyboard**, whose events flow through
the arm's input into every existing binding. Where the arms differ, the row
says which.

| Desktop feature                      | On Android                                                                                                                                                                                    |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scroll (wheel / j k / PgUp…)         | touch drag + fling; keyboard works                                                                                                                                                            |
| Theme cycling (← →)                  | toolbar `◀ thm` / `thm ▶`                                                                                                                                                                     |
| Raw ↔ preview (`v`)                  | toolbar `view`                                                                                                                                                                                |
| Explorer (e)                         | toolbar `tree`; back button closes                                                                                                                                                            |
| Line numbers (l)                     | toolbar `ln №`                                                                                                                                                                                |
| Font size (Ctrl-±)                   | pinch zoom                                                                                                                                                                                    |
| Click (fold chevrons, tree, buttons) | tap                                                                                                                                                                                           |
| Text/table selection (mouse drag)    | long-press, then drag                                                                                                                                                                         |
| Copy (`y` / copy buttons)            | works — native arm: the host's clipboard; raylib arm: the JNI `ClipboardManager` bridge (`sparkles.android.clipboard` over an ImportC'd `<jni.h>`; raylib's own Android clipboard is a no-op) |
| Paste into a field                   | native arm: the field's paste chord reads the clipboard; raylib arm: none (the bridge only writes)                                                                                            |
| Search `/`, goto `g`, copy-modes y/t | **opened by a key** (no touch route yet, `AND14`); once a line is open the soft keyboard comes up and types into it, the layout ending above it                                               |
| Set navigation `[` `]` `i`           | keyboard-only (explorer covers browsing)                                                                                                                                                      |
| Fullscreen F11                       | n/a — the surface is the screen                                                                                                                                                               |
| Hover popups (twoslash)              | tap a token (the pointer rests where the last tap landed)                                                                                                                                     |
| Window title                         | n/a                                                                                                                                                                                           |

## Build & run

Every Android output exists on the build hosts the NDK ships a toolchain for —
**x86_64-linux and aarch64-darwin** — and nowhere else: `aarch64-linux` has no
NDK, so these attributes do not exist there
(`nix/packages/android/host.nix`). Both hosts build both ABIs. The emulator is
the exception that follows the host: `hue-emulator` boots a system image of
the host's own architecture (x86_64 on Linux, arm64 on Apple Silicon).

The two hosts' APKs are equivalent but not bit-identical. D bakes `__FILE__`
into template instances, and those paths name the host's own `ldc` store path
(43 strings in the stripped terminal library) and, on an unsandboxed Mac, the
random build directory of druntime (10 more); D has no `-ffile-prefix-map` to
normalise them. Reproducibility (AND1) therefore holds per host, and the
artifact that is rebuilt and compared — the F-Droid release (fdroid.md) — is
built on x86_64-linux.

```console
$ nix build .#hue-apk            # the native arm: both ABIs + assets, signed, reproducible
$ nix build .#hue-raylib-apk     # the raylib arm (its own package id)
$ nix build .#hue-apk-repo       # …with the whole repo embedded (separate package id)
$ nix build .#hue-apk-unsigned   # the release artifact; signed outside nix (fdroid.md)
$ nix develop .#android          # adb/aapt2 on PATH + helpers
$ hue-emulator &                 # host-ABI AVD of the SDK platform (created on first use)
$ hue-emulator -no-window -gpu swiftshader_indirect &   # headless: Vulkan through SwiftShader
$ hue-adb-install result/hue.apk
$ hue-logcat                     # tags: hue, sparkles-wsi, raylib + crash channels
```

On-device goldens: write `HUE_GUI_*` lines to a file, push via
`adb push … /data/local/tmp/ && adb shell run-as dev.petar_kirov.sparkles.hue cp …
files/hue-debug.env` (direct `run-as sh -c 'cat > …'` writes are
SELinux-denied), relaunch, pull the PNG the same way.

## Traps (each cost a debugging round)

- `InitWindow(w, h)` is **not** ignored on Android: a non-zero size letterboxes
  onto the surface. `InitWindow(0, 0)` = native resolution.
- Final links need `-Wl,-u,ANativeActivity_onCreate` (glue object otherwise
  unreferenced) and `-Wl,--wrap=fopen` (raylib's asset-manager fopen routing +
  its `__real_fopen`), plus `-Wl,-z,max-page-size=16384` on **every** `.so`
  (16 KB-page devices).
- ImportC vs bionic: `-P-U__SIZEOF_INT128__` (kernel headers typedef
  `__int128`); `android_native_app_glue.h` cannot be ImportC'd at all — the
  glue structs are hand-mirrored in `sparkles.android.activity`. `<jni.h>`
  **can** be, and is (`libs/android/c/jni_c.c`), so the clipboard bridge is D
  rather than C —
  ImportC's preprocessor is the _host_ cc, so the cross build points it at the
  NDK sysroot with `-P-I${ndk.sysrootInclude}`.
- JNI method calls go through the `…A` (`jvalue[]`) forms. This is a
  _legibility_ choice, not an ABI requirement: LDC's `extern(C)` variadic
  support on AArch64 was measured correct on both ABIs — verified by running
  a mixed pointer/int/double/stack-spill matrix under `qemu-aarch64` against
  an `aarch64-linux-android` C control (identical results), and by diffing
  LDC's against clang's codegen, which is instruction-identical for
  `aarch64-linux-gnu` (no shuffling; AAPCS64 passes variadic and fixed args
  alike) _and_ for `arm64-apple-macos` (`stp x3, x4, [sp]` — Apple's
  stack-passing rule, which LDC implements). The `jvalue[]` forms are simply
  explicit about each argument's JNI type.
- A statically linked druntime cannot `rt_init` twice: Android reuses the
  process across activity recreations → exit the process when `main` returns.
- Stock raylib (verified through the released 6.0 tag) never resizes on Android (empty `CONFIG_CHANGED` stub, no
  `WINDOW_RESIZED` case, resume path pins the old buffer geometry) — an
  in-place rotation keeps rendering the stale orientation, compositor-scaled.
  `raylib-android-in-place-resize.patch` fixes it — confirmed on hardware, not
  just the emulator (AND7); without the patch, keep
  orientation OUT of `configChanges` so a restart re-inits at the new size.
- `dub test`'s silence is not coverage: `version (Android)` code only compiles
  under the cross triple — the nix `libhue-android` and `libhue-raylib-android`
  builds are the type-check (e.g. sparkles' loggers are IES-only; plain-string
  calls hid in gated code, and did again in `gui_setup.d`'s `whyNot`).
- `builtinThemes` has alias keys (`catppuccinmocha` ≍ `catppuccin-mocha`):
  theme-cycling one step can land on an identically-colored twin.
- `run-as` needs `android:debuggable="true"` — debug-_signed_ is not enough.
  aapt2's debug-mode flag injects it for debug builds, so a release APK does
  not carry it (and cannot be signed with the checked-in key).
- The APK is bit-reproducible, but only for a fixed font input: the Maple Mono
  build is not itself reproducible (measured; see nix/packages/maple-mono).
- Targeting API 36 makes edge-to-edge **mandatory** — Android 15 still honoured
  `windowOptOutEdgeToEdgeEnforcement`, Android 16 ignores it. The native arm
  reads the window's insets and lays hue out inside them, so its toolbar sits
  above the gesture navigation bar (seen on the emulator); the raylib arm reads
  none, and its toolbar is expected to sit under it. Recorded as
  [`HUE-O4`](./open-issues.md#hue-o4).
- Targeting API 36 also makes back **predictive**: the system stops
  dispatching `KEYCODE_BACK` and leaves the activity itself, so Back sent hue
  to the background with the explorer open. The manifest opts out
  (`enableOnBackInvokedCallback="false"`) and Back arrives as a key again.
- dub leaves a library's main source file out, and app.d is hue's: the native
  `android` configuration names a main source file that does not exist so
  app.d compiles in. dub also compiles every module of a library it links, so
  `sparkles:tui`'s raw terminal, which a raw `ldc2 -i` build never reached,
  had to become empty on Android (bionic's `tcgetattr` is a header inline
  druntime does not declare).
- The native arm draws only when an event arrives or the application asks
  (`requestFrame`); raylib draws sixty times a second. hue's key handlers run
  after the frame's layout is taken, so without asking, a key's effect showed
  only at the next event (`/` opened the search line one key late).
- The native arm resolved hue's font family through fontconfig (`fc-match`),
  which Android does not have, until it learnt to search only the directories
  an application hands it — the window never opened.
- Ending the process with `exit()` runs C++ static destructors while the
  framework's render threads still lock their mutexes (FORTIFY aborts the
  process): the native entry `_exit`s.
- The soft keyboard's hidden editor keeps the focus, and the system shows an
  input method again for a focused editor when the window returns; the WSI
  hides it again on focus unless text input is on.
