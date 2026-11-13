# `sparkles:wsi`

Native window-system integration over event-horizon's event loop. The library
owns window and transfer identities, native event translation, clipboard
offers and platform input. Renderers consume its native handles and events.

- [X11 clipboard transfers](./reference/x11-clipboard.md) explains streaming,
  cancellation and delayed-reply isolation.
- The [window-system contract](../../specs/window-system-integration/SPEC.md)
  defines cross-platform obligations and acceptance gates.
