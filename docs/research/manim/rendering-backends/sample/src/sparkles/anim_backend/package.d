/// Cairo CPU-vector rendering-backend binding — illustrative source-only
/// fixture for the `rendering-backends` cluster. Mirrors `libs/ghostty`: an
/// ImportC `cairo_c.c` shim (compiled as a `sourceLibrary` so pkg-config
/// reaches ImportC) plus a `@nogc nothrow` RAII wrapper.
module sparkles.anim_backend;

public import sparkles.anim_backend.cairo_c;
public import sparkles.anim_backend.surface;
