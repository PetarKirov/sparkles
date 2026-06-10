# Wayland scaffold — a real `xdg-shell` window

Findings from [`./examples/scaffold/app.d`](./examples/scaffold/app.d), the evolved form of
the minimal registry bootstrap [`./example/app.d`](./example/app.d): it completes the whole
[no-buffer-no-window][nbnw] handshake and opens an actual `xdg_toplevel` window titled
`wsi-scaffold`, with `wl_shm` double-buffered ARGB software rendering, frame-callback-driven
redraw, and a programmatic maximize/unmaximize resize storm. It is the baseline every
per-feature Wayland demo (`examples/fXX-*`) copies, and the source of the
[F01][f01]/[F02][f02] numbers below. Verified Tier A: `weston --backend=headless`, exit `0`,
120 frames presented.

**Last reviewed:** June 10, 2026

| Measurement                            | Value                                                                                                |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Concepts to first pixel                | **11** protocol object types (10 to the first commit, +1 — `wl_callback` — to _confirm_ it)          |
| LOC (`app.d`)                          | 463 lines (346 excluding comments/blanks); `instrument.d` and the `c.c` shim excluded per [F01][f01] |
| `init_start` → `first_commit`          | ≈ 2.2 ms (of which ≈ 1.3 ms is painting the first 640×480 gradient)                                  |
| `init_start` → `first_pixel_presented` | ≈ 12.4 ms — dominated by waiting for the compositor's first 60 Hz `wl_surface.frame` tick            |
| Round-trips before first pixel         | 2 blocking waits: `wl_display_roundtrip` (registry) + the configure event after the initial commit   |

## Concepts to pixel

Distinct protocol object types touched before the first confirmed pixel, in first-touch order
(spec links go to the rendered protocol XML on wayland.app — the [core protocol][p-wayland]
and [`xdg-shell`][p-xdgshell]):

1. `wl_display` — the connection
2. `wl_registry` — global discovery
3. `wl_callback` — first used internally by `wl_display_roundtrip` (`wl_display.sync`), later
   as the frame callback that confirms presentation
4. `wl_compositor` — bound v4 (needed for `wl_surface.damage_buffer`)
5. `wl_shm` — software-buffer factory
6. `xdg_wm_base` — the window-role factory from [`xdg-shell`][p-xdgshell]
7. `wl_surface` — the pixel rectangle
8. `xdg_surface` — the desktop-window adapter
9. `xdg_toplevel` — the window role (title, app-id, maximize)
10. `wl_shm_pool` — wraps the `memfd` mapping
11. `wl_buffer` — the committable pixels

`wl_seat` is bound when advertised, but headless weston advertises **no seat at all** (see
[surprises](#what-surprised-us)), so the Tier-A count stays 11. Two non-protocol OS objects
ride along: a `memfd_create(2)` file descriptor and its `mmap(2)` mapping. For comparison,
the minimal [`./example/app.d`](./example/app.d) touches 3 (`wl_display`, `wl_registry`,
`wl_callback`) — a visible window costs almost 4× the object vocabulary of the bootstrap.

## Init step sequence (instrument log)

From the demo's `instrument.d` stream (microseconds since `init_start`; format defined in
[F01 § Instrumentation][f01]), recorded under `weston --backend=headless` with
`WSI_AUTO_EXIT=1`:

```text
0 scaffold-wayland init_start
56 scaffold-wayland step name=wl_display_connect
86 scaffold-wayland step name=wl_display_get_registry
244 scaffold-wayland step name=wl_registry_bind iface=wl_compositor version=5
355 scaffold-wayland step name=wl_registry_bind iface=wl_shm version=2
406 scaffold-wayland step name=wl_registry_bind iface=xdg_wm_base version=5
435 scaffold-wayland step name=wl_display_roundtrip
458 scaffold-wayland step name=wl_compositor_create_surface
480 scaffold-wayland step name=xdg_wm_base_get_xdg_surface
505 scaffold-wayland step name=xdg_surface_get_toplevel
527 scaffold-wayland step name=xdg_toplevel_set_title
548 scaffold-wayland step name=xdg_toplevel_set_app_id
568 scaffold-wayland window_created
584 scaffold-wayland step name=wl_surface_commit
759 scaffold-wayland xdg_toplevel_configure size=0x0 maximized=0
783 scaffold-wayland configure serial=1 size=640x480
810 scaffold-wayland step name=xdg_surface_ack_configure
828 scaffold-wayland first_configure
854 scaffold-wayland step name=memfd_create+mmap
884 scaffold-wayland step name=wl_shm_create_pool
910 scaffold-wayland step name=wl_shm_pool_create_buffer
935 scaffold-wayland buffer_alloc size=640x480 bytes=1228800
2241 scaffold-wayland first_commit size=640x480
12364 scaffold-wayland frame_callback t=475658634
12386 scaffold-wayland first_pixel_presented
```

Readings:

- **Everything client-side is cheap.** Connect through `window_created` is ~0.6 ms total; the
  only real costs are the two server waits — `wl_display_roundtrip` for the registry and the
  wait for the first `configure` after the no-buffer commit (~175 µs on a local socket) — and
  the final 10 ms of simply waiting for the compositor's next vsync tick to fire the frame
  callback. "First pixel" on Wayland is gated by the frame clock, not by init work.
- `xdg_toplevel.configure` suggested `0x0` ("you pick"), so the demo chose its 640×480
  default — the size a Wayland client "decides" is itself part of the negotiation.
- The gap `buffer_alloc` → `first_commit` (~1.3 ms) is painting the 640×480 gradient
  (307200 pixels), not protocol.

## Configure → ack → commit, proven

The `WAYLAND_DEBUG=1` wire trace (also stderr, so it interleaves with the instrument lines)
around the first configure shows the ordering [F02][f02] demands — `ack_configure` carrying
the right serial _before_ the buffer commit, and the committed buffer sized exactly to the
acked configure:

```text
[ 272970.453] {Default Queue}  -> wl_surface#3.commit()
584 scaffold-wayland step name=wl_surface_commit
[ 272970.628] {Default Queue} xdg_toplevel#8.configure(0, 0, array[0])
[ 272970.653] {Default Queue} xdg_surface#7.configure(1)
783 scaffold-wayland configure serial=1 size=640x480
[ 272970.679] {Default Queue}  -> xdg_surface#7.ack_configure(1)
[ 272970.753] {Default Queue}  -> wl_shm#5.create_pool(new id wl_shm_pool#9, fd 5, 1228800)
[ 272970.778] {Default Queue}  -> wl_shm_pool#9.create_buffer(new id wl_buffer#10, 0, 640, 480, 2560, 0)
[ 272972.079] {Default Queue}  -> wl_surface#3.attach(wl_buffer#10, 0, 0)
[ 272972.091] {Default Queue}  -> wl_surface#3.damage_buffer(0, 0, 640, 480)
[ 272972.103] {Default Queue}  -> wl_surface#3.frame(new id wl_callback#11)
[ 272972.110] {Default Queue}  -> wl_surface#3.commit()
```

The auto-exit resize storm (`set_maximized` at frame 30) exercises the same contract at a new
size — note the new serial, the immediate ack, and the freshly allocated 1024×608 buffer
committed right after:

```text
[ 273465.568] {Default Queue}  -> xdg_toplevel#8.set_maximized()
[ 273466.219] {Default Queue} xdg_toplevel#8.configure(1024, 608, array[4])
496354 scaffold-wayland xdg_toplevel_configure size=1024x608 maximized=1
[ 273466.254] {Default Queue} xdg_surface#7.configure(2)
[ 273466.292] {Default Queue}  -> xdg_surface#7.ack_configure(2)
496449 scaffold-wayland resize size=1024x608 scale=1
[ 273466.431] {Default Queue}  -> wl_shm_pool#9.create_buffer(new id wl_buffer#12, 0, 1024, 608, 4096, 0)
[ 273468.962] {Default Queue}  -> wl_surface#3.attach(wl_buffer#12, 0, 0)
[ 273468.985] {Default Queue}  -> wl_surface#3.damage_buffer(0, 0, 1024, 608)
[ 273468.992] {Default Queue}  -> wl_surface#3.commit()
```

`render()` asserts `buffer.size == acked size` on every commit, so a violation would abort
the demo rather than silently stretch. Buffer lifetime is `wl_buffer.release`-driven: a
buffer is `busy` from commit until its release event, and stale-sized buffers are destroyed
lazily, only when picked for reuse (never while the compositor holds them). Teardown destroys
children before parents (buffers → frame callback → `xdg_toplevel` → `xdg_surface` →
`wl_surface` → `xdg_wm_base` → globals → registry) and disconnects; the demo exits `0` after
120 frames / 122 commits (the two extras are the immediate post-resize commits).

## What surprised us

- **Headless weston advertises no `wl_seat`.** With no input backend there is simply no seat
  global — `wl_seat` binding is written but unexercised in Tier-A runs, and any input-feature
  demo (F06+) must treat "no seat" as a skippable host capability, not an error.
- **Weston releases `wl_shm` buffers almost immediately** (it copies the pixels at repaint),
  so steady-state rendering reuses a single buffer and the second one is only ever touched
  during resize transitions, when the first is still held. Double buffering is therefore
  _insurance_, not throughput — but it is what makes the resize path race-free.
- **Maximized on headless weston is 1024×608, not 1024×640**: the default output is 1024×640
  and `weston-desktop-shell`'s panel eats 32 px. Unmaximize suggests `0x0` — the client is
  again "free" to pick, so a robust client must remember its own floating size.
- **The D/ImportC walls were all build-system, not protocol** (details in the gotchas list
  below): `static inline` request helpers, dub's `*.d`-only source glob, the hyphenated
  generated filename, and Nix's `-D_FORTIFY_SOURCE` each broke the build before the first
  protocol message was ever sent.

## What the scaffold adds over the minimal example

[`./example/app.d`](./example/app.d) stops — deliberately — at the registry: 77 lines, three
object types, no window, because the `xdg-shell` glue beyond that point is scanner-generated.
The scaffold pays exactly that cost and crosses the line. Concretely it adds:

| Capability      | Minimal [`./example/app.d`](./example/app.d)  | Scaffold [`./examples/scaffold/app.d`](./examples/scaffold/app.d)                              |
| --------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Protocol glue   | Core ABI only (hand-expanded `static inline`) | `wayland-scanner`-generated `xdg-shell` glue, regenerated at every build (`generate.sh`)       |
| Registry        | Enumerates globals                            | Binds `wl_compositor`, `wl_shm`, `xdg_wm_base`, `wl_seat` (when present)                       |
| Window          | None (impossible by construction)             | `wl_surface` → `xdg_surface` → `xdg_toplevel`, title `wsi-scaffold`                            |
| Pixels          | None                                          | Double-buffered `memfd` + `mmap` + `wl_shm` ARGB8888 gradient                                  |
| Lifecycle       | One `wl_display_roundtrip`                    | configure/ack/commit negotiation, frame-callback redraw loop, `xdg_wm_base.ping` → `pong`      |
| Resize          | n/a                                           | maximize/unmaximize storm; per-configure buffer realloc; size assertion ([F02][f02])           |
| Instrumentation | `printf` only                                 | `instrument.d` — the canonical `<monotonic_us> <DEMO> <EVENT_KIND>` logger all demos copy      |
| Exit            | After the roundtrip                           | `WSI_AUTO_EXIT=1` → ~120 frames then clean teardown; otherwise runs until `xdg_toplevel.close` |

Implementation gotchas the feature demos inherit (all encoded in
[`./examples/scaffold/c.c`](./examples/scaffold/c.c) and the package config):

- **ImportC cannot call `static inline`** — and _all_ scanner-generated request helpers are
  `static inline`. Hand-marshalling via `wl_proxy_marshal_flags` (the minimal example's
  trick) does not scale to the ~25 helpers a window needs; the shim re-exports each as a real
  `wsi_*` function instead, which also keeps listener types exact (no function-pointer casts
  in D).
- **dub's source glob only picks up `*.d`.** A `.c` shim that is merely _imported_ compiles
  declaration-only — every wrapper becomes an undefined reference at link time. The shim must
  be listed explicitly (`sourceFiles "c.c"`).
- **`xdg-shell-protocol.c` cannot be a dub source**: ldc rejects the hyphenated filename as a
  module name ("module `xdg-shell-protocol` has non-identifier characters in filename"). The
  shim `#include`s it textually (one translation unit) and `excludedSourceFiles` keeps dub
  away from it. Both generated files are gitignored and rebuilt by `generate.sh` via
  `preGenerateCommands`, locating the XML through `pkg-config --variable=pkgdatadir wayland-protocols`.
- **Nix's cc wrapper injects `-D_FORTIFY_SOURCE`**, and glibc's fortified `bits/unistd.h`
  uses `__builtin_dynamic_object_size`, which ImportC does not implement — the shim must
  `#undef _FORTIFY_SOURCE` before its first glibc include.

## Sources

- **Protocol** — the [core Wayland protocol][p-wayland] (`wl_display`, `wl_registry`,
  `wl_compositor`, `wl_shm`, `wl_surface`, `wl_buffer`, `wl_callback`, `wl_seat`) and
  [`xdg-shell`][p-xdgshell] (`xdg_wm_base`, `xdg_surface`, `xdg_toplevel`; the
  initial-commit/configure/ack contract quoted in [the survey](./index.md)); the glue is
  generated from the `wayland-protocols` XML (`stable/xdg-shell/xdg-shell.xml`).
- **Shared-memory buffers** — the [Wayland Book's shared-memory chapter][book-shm]
  (`memfd_create` + `wl_shm` pool pattern the scaffold follows).
- **Specs implemented** — [F01 first pixel][f01] and [F02 resize][f02]; conventions in
  [the features index](../features/index.md).
- **Code** — [`./examples/scaffold/app.d`](./examples/scaffold/app.d),
  [`./examples/scaffold/instrument.d`](./examples/scaffold/instrument.d),
  [`./examples/scaffold/c.c`](./examples/scaffold/c.c); the predecessor
  [`./example/app.d`](./example/app.d) and its survey [`./index.md`](./index.md).

<!-- References -->

[f01]: ../features/f01-first-pixel.md
[f02]: ../features/f02-resize.md
[nbnw]: ../../concepts.md#no-buffer-no-window
[p-wayland]: https://wayland.app/protocols/wayland
[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[book-shm]: https://wayland-book.com/surfaces/shared-memory.html
