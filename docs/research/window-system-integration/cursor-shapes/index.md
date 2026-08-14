# Pointer-shape probe

A clickable raylib grid that asks GLFW for every standard cursor token
([`cursor-shapes.d`](./cursor-shapes.d)). Hue's GUI splitters and
scrollbars go through the same `SetMouseCursor` path; if a shape cannot
be realised the pointer snaps back to the default arrow.

```bash
# from a sparkles nix shell
dub run --single --compiler=ldc2 \
  docs/research/window-system-integration/cursor-shapes/cursor-shapes.d
```

Hover or click a tile. The program calls raylib `SetMouseCursor` every frame.

**Last reviewed:** August 14, 2026

## What we found (GNOME / Wayland)

Those extra cursor tokens in the GLFW changelog (`GLFW_RESIZE_NWSE_CURSOR`,
`GLFW_POINTING_HAND_CURSOR`, …) landed in **3.4**, not 3.5.1. 3.5.1 did not
add compositor-side cursor shapes.

The pipeline hue uses is:

```
sparkles PointerShape
  → SetMouseCursor (raylib rcore_desktop_glfw.c)
  → glfwCreateStandardCursor(0x00036000 + cursor)
  → Wayland: wl_cursor_theme_get_cursor(XDG name, else X11 name)
```

Stock GLFW 3.5.1 still **does not speak `wp_cursor_shape_v1`**. On Wayland it
only uploads XCursor pixmap buffers via `wl_pointer.set_cursor`. See the
[GLFW deep-dive](../glfw.md#3-input--ime).

A probe against this machine's nixpkgs `glfw 3.5.1` (`/tmp/glfw-cursor-probe.c`):

| shape            | result                                     |
| ---------------- | ------------------------------------------ |
| ARROW            | ok                                         |
| IBEAM            | ok                                         |
| POINTING_HAND    | ok                                         |
| RESIZE_ALL       | ok                                         |
| CROSSHAIR        | NULL (`"crosshair"` missing)               |
| RESIZE_EW        | NULL (`"ew-resize"` then X11 name missing) |
| RESIZE_NS        | NULL (`"ns-resize"` then X11 name missing) |
| RESIZE_NWSE/NESW | NULL (no X11 fallback)                     |
| NOT_ALLOWED      | NULL (no X11 fallback)                     |

Hue's splitters and scrollbars ask for `ewResize` / `nsResize`. Those are
exactly the shapes that fail, so `glfwSetCursor(window, NULL)` snaps back to
the default arrow. That is why the pointer appeared stuck after the 3.5.1
upgrade.

`/usr/share/icons/Adwaita` on this host has **no `cursors/` directory**.
Recent Adwaita dropped XCursor files in favour of compositor-owned shapes.
GLFW never asked the compositor for a named shape.

Raylib also **allocates a new `GLFWcursor` on every `SetMouseCursor` call**
and never caches or destroys it. Hue does this every frame. Harmless when
creation succeeds; when it fails, it repeatedly resets the cursor to default.

## Fix (applied)

`nix/d-toolchain.nix` overlays `glfw` / `glfw3` onto
[`PetarKirov/glfw` at `1e59848ba2856c25515a80f52e97c78d5412395e`][sparkles-glfw]:
[glfw#2679][glfw-pr-2679] rewritten on 3.5.1.

After that overlay, `glfwCreateStandardCursor` succeeds for every standard
token on this GNOME/Wayland session (including `RESIZE_EW` / `RESIZE_NS`).
The D probe emits only the usual Wayland "window position unavailable"
warnings, not `GLFW_CURSOR_UNAVAILABLE`.

Raylib should still cache standard cursors. That is no longer what hides the
shapes.

[sparkles-glfw]: https://github.com/PetarKirov/glfw/tree/1e59848ba2856c25515a80f52e97c78d5412395e
[glfw-pr-2679]: https://github.com/glfw/glfw/pull/2679
