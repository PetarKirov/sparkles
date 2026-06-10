# X11 F12 — cursors — findings

System-themed, custom-ARGB and animated cursors on X11, measured: who loads
them, who scales them, and who animates them (the server, on all three counts
once the cursor object exists). The demo,
[`./examples/f12-cursors/app.d`](./examples/f12-cursors/app.d), is built on the
[scaffold](./scaffold.md) (same ImportC binding style, same `poll(2)` loop,
same [`instrument.d`](./examples/f12-cursors/instrument.d) log) and implements
the [F12 feature spec][f12]: a 3×3 hover-zone grid whose eight edge/corner
zones carry the eight resize cursors and whose centre zone cycles
default → text → pointer → custom bullseye → animated `watch` on each
re-entry. Every switch is one `XDefineCursor` + `XFlush`, logged as
`cursor_set`. All numbers are from Tier-A `xvfb-run` runs (exit 0): the bare
binary's built-in `XWarpPointer` storm, plus the co-located
`examples/f12-cursors/run.sh` driver which varies `XCURSOR_THEME` /
`XCURSOR_PATH` / `XCURSOR_SIZE` across five passes and drives one pass with
`xdotool mousemove`.

**Last reviewed:** June 11, 2026

## Two mechanisms for the same shape, loaded side by side

For every shape the demo loads **both** the core-font cursor and the themed
cursor and logs both handles:

- **Core cursor font** — [`XCreateFontCursor`][fontcursor-man] indexes the
  `cursor` font baked into every X server; the glyph ids
  (`XC_top_left_corner = 134`, `XC_xterm = 152`, …) come from
  [`<X11/cursorfont.h>`][cursorfont] (macros only — re-declared in the demo
  per the [scaffold ImportC gotcha](./scaffold.md#surprises)). This path
  cannot fail and needs no files on disk, but it is the 1987 monochrome
  vocabulary.
- **libXcursor themed lookup** — [`XcursorLibraryLoadCursor`][xcursor-man]
  resolves a _name_ (the demo uses the cursor-spec/CSS names that
  [`cursor-shape-v1`][cursor-shape] later standardized on Wayland: `default`,
  `text`, `pointer`, `nw-resize`, …) through the theme machinery to an ARGB
  image file, falling back through theme inheritance.

Pass A (bare Xvfb, `XCURSOR_*` scrubbed, no theme on any default path) shows
the failure mode honestly — every themed lookup returns `0`, including for
the plain names, so a client **must** keep the font path as fallback:

```text
317 f12_x11 xcursor_env XCURSOR_THEME=(unset) XCURSOR_PATH=(unset) XCURSOR_SIZE=(unset)
381 f12_x11 cursor_load name=nw-resize font_glyph=134 font=0x200002 theme=0x0
513 f12_x11 cursor_load name=default font_glyph=68 font=0x200006 theme=0x0
```

With a theme in reach (pass D: `XCURSOR_THEME=Adwaita`,
`XCURSOR_PATH=…/share/icons` from `nix build nixpkgs#adwaita-icon-theme`)
every lookup resolves and the grid runs entirely on the themed path:

```text
12182 f12_x11 cursor_load name=nw-resize font_glyph=134 font=0x200005 theme=0x200009
18092 f12_x11 cursor_set zone=4 name=default path=theme size=48 cursor=0x200051
518842 f12_x11 cursor_set zone=0 name=nw-resize path=theme size=48 cursor=0x200009
2021291 f12_x11 cursor_set zone=4 name=custom-bullseye path=custom size=48 cursor=0x200065
2622373 f12_x11 cursor_set zone=4 name=watch path=animated size=48 cursor=0x200156
```

## Theme & size resolution: which knobs libXcursor honors, measured

The demo logs the three environment variables next to what
`XcursorGetTheme`/`XcursorGetDefaultSize` actually resolve; `run.sh` varies
them per pass:

| Pass | `XCURSOR_THEME` / `XCURSOR_SIZE`   | `XcursorGetTheme` | `XcursorGetDefaultSize` | `default` file loaded |
| ---- | ---------------------------------- | ----------------- | ----------------------- | --------------------- |
| A    | unset / unset (no theme installed) | `(null)`          | **10**                  | none (`frames=0`)     |
| B    | `Adwaita` / unset                  | `Adwaita`         | **10**                  | `24x24 nominal=24`    |
| C    | `Adwaita` / `16`                   | `Adwaita`         | **16**                  | `24x24 nominal=24`    |
| D    | `Adwaita` / `48`                   | `Adwaita`         | **48**                  | `48x48 nominal=48`    |

Three rules fall out:

1. **All three env vars are honored** by this libXcursor (1.2.3):
   `XCURSOR_THEME` and `XCURSOR_SIZE` override the display's `Xcursor.theme` /
   `Xcursor.size` resources, and `XCURSOR_PATH` replaces the search path. The
   man page documents only `XCURSOR_PATH`; the env-before-resource precedence
   for theme and size is in [libXcursor's `src/display.c`][xcursor-src]
   (`getenv ("XCURSOR_SIZE"); if (!v) v = XGetDefault (dpy, "Xcursor",
"size");` and the same shape for `XCURSOR_THEME`).
2. **The HiDPI default-size chain is size → resource → `Xft.dpi` →
   `min(display dimension) / 48`.** With nothing set, [`display.c`][xcursor-src]
   first tries `dpi * 16 / 72` from the `Xft.dpi` resource ("make cursors 16
   'points' tall"), then falls back to the smaller display dimension over 48
   ("16 pixels on a display of dimension 768", per the source comment) — a
   640×480 Xvfb with no resources yields the measured **480 / 48 = 10**.
3. **The requested size is a nomination, not a contract.** Asking Adwaita for
   size 10 or 16 returns its nearest stocked size — `24x24 nominal=24`
   (pass B/C log: `cursor_images name=default … size_requested=16 frames=1
frame0=24x24 nominal=24`). The _chosen_ size is only knowable from the
   loaded image, which is why the demo logs `frame0`/`nominal` per load.

## Custom ARGB cursor: libXcursor is the only full-color road

The centre zone's fourth stop is a 24×24 bullseye built from raw
premultiplied-ARGB pixels with a deliberately non-trivial hotspot (12,12 —
dead centre, where the arrow's (0,0) habit would aim a quadrant off):

```text
8594 f12_x11 cursor_custom api=XcursorImageLoadCursor size=24x24 hotspot=12,12 cursor=0x200065 (legacy XCreatePixmapCursor: 1-bit source+mask, exactly 2 colors)
```

`XcursorImageCreate` → fill `pixels` → [`XcursorImageLoadCursor`][xcursor-man]
is three calls and works even with no theme installed (it uploads the pixels
via RENDER; the demo logs `XcursorSupportsARGB=1` even on Xvfb). The core
alternative the log line cites, [`XCreatePixmapCursor`][fontcursor-man], takes
a 1-bit source + 1-bit mask and **exactly two colors** (a foreground/background
pair, re-colorable via `XRecolorCursor`) — no alpha, no mid-tones; it is why
every pre-Xcursor toolkit cursor looks like a woodcut.

## Animated cursor: the server runs the animation

The fifth centre stop loads Adwaita's `watch` via
`XcursorLibraryLoadImages` — which returns the _frame list_, proving the
animation exists client-side before handing it off — then bakes all frames
into one cursor with `XcursorImagesLoadCursor`:

```text
15220 f12_x11 cursor_images name=watch theme=Adwaita size_requested=48 frames=60 frame0=48x48 nominal=48 hot=22,22 delay_ms=16
17675 f12_x11 cursor_animated name=watch frames=60 delay_ms=16 cursor=0x200156 animator=server (client sets it once, never ticks)
```

**60 frames at 16 ms** (a ~1 s loop) verified loaded (`frames>1` — the F12
check), one `XDefineCursor`, and the client never wakes again: no timer, no
redraw, no further protocol. The X server composites and steps the cursor.
This is the sharpest contrast with Wayland's classic `wl_pointer.set_cursor`
path, where the _client_ owns a `wl_surface`, must attach each frame, and
runs the frame timer itself off `wl_cursor` image delays — animation cost
moves from server to client. (Wayland's newer `cursor-shape-v1` hands the job
back to the compositor, X11-style.) On pass A, where no theme exists, the
demo logs `cursor_animated frames=0` and degrades to the static font
`XC_watch` — the font path has no animation concept at all.

> [!NOTE]
> **Tier C — pixels need eyes.** Everything above observes cursor _requests_
> and loaded _images_; whether the right pixels appear at the right hotspot
> on screen needs a human on a real session, per the [F12 verification
> split][f12]. The custom-bullseye hotspot and the watch animation are queued
> for that visual pass.

## Surprises

- **libXcursor does not fall back to the core font for CSS names.** With no
  theme, `XcursorLibraryLoadCursor("nw-resize")` (and even `"default"`)
  returns `0` rather than mapping to the obvious glyph — its internal
  name→glyph fallback table speaks the legacy font vocabulary
  (`top_left_corner`, `xterm`, …), not the cursor-spec names. The fallback
  is the application's problem.
- **Cursor size defaults to `min(display dimension) / 48`** (after `Xft.dpi`),
  so the same client gets size-10 cursors on a 640×480 server and 22+ on
  HiDPI — resolution scaling that predates every per-monitor-DPI mechanism,
  and wrong on mixed-DPI multihead (one global size for all screens).
- **`XCURSOR_SIZE` is honored but quantized** to the theme's stocked sizes
  at load time; `XcursorGetDefaultSize` faithfully parrots the env var even
  when no such size exists.
- **`xcursor_env` on a desktop session is pre-polluted:** the demo run from a
  NixOS session inherits a many-entry `XCURSOR_PATH`, so measuring the true
  "unset" baseline required `env -u` scrubbing in `run.sh` — trust nothing
  inherited when measuring resolution order.
- **A 60-frame, 48×48 ARGB animated cursor is one round-trip** to create and
  zero ongoing cost to the client — X11's server-side cursor plane is doing
  real work that Wayland deliberately pushed back to clients.

## Build and run

Tier A, from the repo root — the bare binary sweeps all zones via its
built-in `XWarpPointer` storm and exits 0 (no display → `SKIP: no X11
display`, exit 0; `WSI_NO_WARP=1` disables the storm for external driving):

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f12-cursors
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    docs/research/window-system-integration/os-apis/x11/examples/f12-cursors/build/f12_cursors_x11
```

The theme/size matrix and the `xdotool`-driven pass are the co-located driver
`examples/f12-cursors/run.sh` (run from the dev shell; it pulls `xdotool` via
`nix shell` and the Adwaita cursor theme via `nix build`). Link dependencies:
`x11`, `xcursor` (pkg-config names, both in the dev shell).

## Sources

- **[Xcursor man page][xcursor-man]** — the theme-file model (nominal sizes,
  "the library automatically picks the best size", `index.theme`
  inheritance), `XCURSOR_PATH`, `XcursorImageCreate`/`XcursorImageLoadCursor`,
  `XcursorLibraryLoadImages`/`XcursorImagesLoadCursor`,
  `XcursorSupportsARGB`.
- **[libXcursor `src/display.c`][xcursor-src]** — the measured resolution
  chain (env var → `Xcursor.*` resource → `Xft.dpi` → `dim / 48`), quoted
  above.
- **[XCreateFontCursor / XCreatePixmapCursor man page][fontcursor-man]** —
  the core cursor font and the two-color pixmap-cursor limit.
- **[`<X11/cursorfont.h>`][cursorfont]** — the glyph-id table the demo
  re-declares.
- **[XDefineCursor (Tronche)][definecursor]** — the per-window cursor
  attribute the grid switches.
- **[`cursor-shape-v1`][cursor-shape]** — the Wayland shape vocabulary whose
  names the themed lookups use; the contrast case for who animates.
- **This survey** — the [X11 deep-dive](./index.md), the
  [scaffold findings](./scaffold.md), and the [F12 feature spec][f12]; the
  runnable sources [`./examples/f12-cursors/app.d`](./examples/f12-cursors/app.d)
  and [`./examples/f12-cursors/instrument.d`](./examples/f12-cursors/instrument.d)
  (plus the `c.c` ImportC shim and the `run.sh` driver alongside them).

<!-- References -->

[cursor-shape]: https://wayland.app/protocols/cursor-shape-v1
[cursorfont]: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/include/X11/cursorfont.h
[definecursor]: https://tronche.com/gui/x/xlib/window/XDefineCursor.html
[f12]: ../features/f12-cursors.md
[fontcursor-man]: https://www.x.org/releases/current/doc/man/man3/XCreateFontCursor.3.xhtml
[xcursor-man]: https://www.x.org/releases/current/doc/man/man3/Xcursor.3.xhtml
[xcursor-src]: https://gitlab.freedesktop.org/xorg/lib/libxcursor/-/blob/master/src/display.c
