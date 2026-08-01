# hue on Android — requirements & architecture

_**Status:** shipped v0 — every requirement confirmed on a physical arm64
device (Xiaomi 11T Pro), the emulator having been the development target. The
one exception is pinch-zoom (`AND6`), which is host-tested but not yet
exercised on hardware. · **Date:** 2026-08-02 · **Scope:** the Android
port of the GUI sink — `apps/hue` (`android_glue.d`, `android_clipboard.d`,
`android_paths.d`, `gui_touch.d`, the `version (Android)` gates),
`libs/raylib-text` (`FontSources`), `libs/syntax`
(`GrammarRegistry.fromSonames`), `nix/packages/android/`, `apps/hue/android/`._

hue runs on Android as a pure `NativeActivity` APK — no Java, no DEX
(`hasCode="false"`). raylib's `PLATFORM_ANDROID` backend
(`android_native_app_glue` + EGL/GLES2) owns `android_main()` and calls the
library's `main()`, so the whole desktop GUI — the `sparkles:ui` widget
pipeline, `RaylibCanvas`, `FontSet`, tree-sitter highlighting, the markdown
preview, ghostty ansi fences, the explorer, twoslash — carries over. The APK,
and every native dependency in it, is built by nix (no Gradle): see
`nix/packages/android/`.

## Architecture decisions

| Decision          | Choice                                                                                                                                                                                                                                                                                                                                                          | Where                                                     |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Rendering backend | raylib cross-built for `PLATFORM_ANDROID` (static, per ABI); `RaylibCanvas` unchanged                                                                                                                                                                                                                                                                           | `nix/packages/android/raylib.nix`                         |
| ABIs              | `arm64-v8a` (devices) + `x86_64` (emulator); the dual-ABI `ldc-android` (dlang.nix) carries one ldc2.conf section per target                                                                                                                                                                                                                                    | `nix/packages/android/ndk.nix`, dlang.nix `feat/ldc-wasm` |
| Entry / dispatch  | `main()` runs inside the activity: `pickBackend` answers `gui` unconditionally; TUI modules stay out of the module graph                                                                                                                                                                                                                                        | `apps/hue/src/app.d`                                      |
| Font resolution   | fontconfig-free: `FontSet.FontSources` scans the extracted `fonts/` dir + `/system/fonts`; coverage from build-time `fc-query` `.charset` sidecars. The font set itself is shared with the desktop (`nix build .#sparkles-fonts`, also reachable from `terminal --font-dir`): Maple Mono NF CN primary + Uiua386 (codepoint-mapped) + FiraCode/DejaVu fallbacks | `libs/raylib-text/…/font_set.d`, `nix/packages/fonts.nix` |
| Grammars          | parsers ship as `lib/<abi>/libtree_sitter_<lang_>.so`, dlopen'd by bare soname from the app's linker namespace (`GrammarRegistry.fromSonames`); queries are extracted assets                                                                                                                                                                                    | `libs/syntax/…/ts/registry.d`, `ts-grammars.nix`          |
| Assets            | one `assets/` bundle (fonts + sidecars, grammar queries, sample docs), extracted by D over `AAssetManager` on first run, keyed by `bundle-hash`, driven by `asset-manifest.txt` (AAssetDir cannot list subdirectories)                                                                                                                                          | `android_glue.d`, `nix/packages/android/hue.nix`          |
| Lifecycle         | rotation resizes IN PLACE (the nix raylib build carries raylib-android-in-place-resize.patch — stock raylib — verified through the released 6.0 tag — never resizes on Android), and `main()` exits the process when the activity is destroyed — a statically linked druntime cannot `rt_init` twice in a reused process                                        | raylib.nix patch, manifests, `app.d`                      |
| Input             | `TouchScroller` (pure, host-tested): tap = click, drag = kinetic scroll + fling, long-press = selection, pinch = font zoom; a five-segment bottom toolbar covers the keyboard essentials; hardware keyboards keep every desktop binding                                                                                                                         | `apps/hue/src/gui_touch.d`, `gui.d`                       |
| Logging           | a `CoreLogger` subclass writing to logcat tag `hue` (stderr goes nowhere in an activity), at `warning` — hue emits only degradation warnings                                                                                                                                                                                                                    | `android_glue.d`                                          |
| Debug hooks       | `<dataDir>/hue-debug.env` (`KEY=VALUE`) loads into the environment at boot, re-enabling every `HUE_GUI_*` golden/screenshot hook on-device                                                                                                                                                                                                                      | `android_paths.d`, `android_glue.d`                       |

## Requirements

| ID    | Requirement                                                                                                                                                                                                                           | Status                                        | Where                                       |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------- |
| AND1  | `nix build .#hue-apk` produces an installable dual-ABI NativeActivity APK, fully nix-built (aapt2 + zipalign + apksigner) and **bit-reproducible**; debug vs release is a build knob, and a release build refuses the checked-in key  | full                                          | `nix/packages/android/{hue,build-apk}.nix`  |
| AND2  | The GUI sink boots on-device with no CLI: built-in document, asset bundle extracted idempotently, logcat logging                                                                                                                      | full (device)                                 | `app.d`, `android_glue.d`                   |
| AND3  | Fonts resolve without fontconfig: Maple Mono NF CN primary (4 styled faces), FiraCode Nerd Font Mono + DejaVu fallbacks, `/system/fonts` last; styled faces by the sibling naming convention, fallbacks ranked so a Regular face wins | full                                          | `font_set.d` `FontSources`                  |
| AND4  | Syntax highlighting on-device: all bundled grammars as soname-dlopen'd native libs, queries from assets, plain-text degrade intact (totality)                                                                                         | full (device)                                 | `registry.d` `fromSonames`                  |
| AND5  | The markdown preview incl. ` ```ansi ` fences (libghostty-vt cross-built, `-Dsimd=false`) renders on-device                                                                                                                           | full (device)                                 | `libghostty-vt.nix`, `gui_ansi.d`           |
| AND6  | Touch: drag scroll + fling, tap = click, long-press selection, pinch zoom, toolbar for theme/view/tree/line-numbers (and `copy` while a selection is live), system back closes tree → exits                                           | full (pinch: host-tested, on-device untested) | `gui_touch.d`, `gui.d`                      |
| AND7  | Lifecycle: pause/resume identical frames; rotation resizes in place — same process, scroll/document/theme preserved, reflow at the new width                                                                                          | full (device)                                 | raylib patch, manifests, `app.d`            |
| AND8  | The explorer browses the extracted sample docs (markdown, D, twoslash) with file-type icons                                                                                                                                           | full (device)                                 | `app.d` (Android tree root), `hue.nix` docs |
| AND9  | On-device goldens: `hue-debug.env` + `HUE_GUI_SCREENSHOT` (data-dir-anchored) round-trip via `adb shell run-as`                                                                                                                       | full                                          | `gui.d`, `android_paths.d`                  |
| AND10 | `hue-apk-repo`: the whole tracked repository (sources, markdown, text aux; minus docs/.vitepress and binaries) embedded as the explorer browse surface — ~1.5k files, ~1 s first-run extraction                                       | full (device)                                 | `hue.nix` `repoDocsTree`                    |

## Desktop-parity checklist

Interaction parity is honest, not aspirational: **touch covers the reading
workflows; full parity needs a (BT) keyboard**, whose events flow through
raylib's Android input into every existing binding.

| Desktop feature                      | On Android                                                                                                                               |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Scroll (wheel / j k / PgUp…)         | touch drag + fling; keyboard works                                                                                                       |
| Theme cycling (← →)                  | toolbar `◀ thm` / `thm ▶`                                                                                                                |
| Raw ↔ preview (Tab)                  | toolbar `view`                                                                                                                           |
| Explorer (e)                         | toolbar `tree`; back button closes                                                                                                       |
| Line numbers (l)                     | toolbar `ln №`                                                                                                                           |
| Font size (Ctrl-±)                   | pinch zoom                                                                                                                               |
| Click (fold chevrons, tree, buttons) | tap                                                                                                                                      |
| Text/table selection (mouse drag)    | long-press, then drag                                                                                                                    |
| Copy (Ctrl-C / copy buttons)         | works — the JNI `ClipboardManager` bridge (`android_clipboard.d` over an ImportC'd `<jni.h>`; raylib's own Android clipboard is a no-op) |
| Search `/`, goto `g`, copy-modes y/t | **keyboard-only** (no soft-keyboard IME through raylib)                                                                                  |
| Set navigation `[` `]` `i`           | keyboard-only (explorer covers browsing)                                                                                                 |
| Fullscreen F11                       | n/a — the surface is the screen                                                                                                          |
| Hover popups (twoslash)              | tap a token (the pointer rests where the last tap landed)                                                                                |
| Window title                         | n/a                                                                                                                                      |

## Build & run

Every Android output is **x86_64-linux only** — the NDK and SDK ship prebuilt
for that host alone — so these attributes do not exist on darwin.

```console
$ nix build .#hue-apk            # both ABIs + assets, signed, reproducible
$ nix build .#hue-apk-repo       # …with the whole repo embedded (separate package id)
$ nix develop .#android          # adb/aapt2 on PATH + helpers
$ hue-emulator &                 # x86_64 API-35 AVD (created on first use)
$ hue-adb-install result/hue.apk
$ hue-logcat                     # tags: hue, raylib + crash channels
```

On-device goldens: write `HUE_GUI_*` lines to a file, push via
`adb push … /data/local/tmp/ && adb shell run-as dev.sparkles.hue cp …
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
  glue structs are hand-mirrored in `android_glue.d`. `<jni.h>` **can** be, and
  is (`apps/hue/android/jni_c.c`), so the clipboard bridge is D rather than C —
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
  under the cross triple — the nix `libhue-android` build is the type-check
  (e.g. sparkles' loggers are IES-only; plain-string calls hid in gated code).
- `builtinThemes` has alias keys (`catppuccinmocha` ≍ `catppuccin-mocha`):
  theme-cycling one step can land on an identically-colored twin.
- `run-as` needs `android:debuggable="true"` — debug-_signed_ is not enough.
  aapt2's debug-mode flag injects it for debug builds, so a release APK does
  not carry it (and cannot be signed with the checked-in key).
- The APK is bit-reproducible, but only for a fixed font input: the Maple Mono
  build is not itself reproducible (measured; see nix/packages/maple-mono).
