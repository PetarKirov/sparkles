/**
The window, and the flags ImportC cannot carry across.

SDL3 spells its window flags with `SDL_UINT64_C(...)`, a function-like macro
ImportC declines to fold, so `SDL_WINDOW_VULKAN` and its siblings do not exist
on the D side. They are re-declared here as a typed `enum` over the same bits,
which is better than the C original anyway: a `WindowFlags` cannot be confused
with the `SDL_InitFlags` passed to `SDL_Init`.
*/
module sparkles.ui_sdl3.window;

import expected : err, ok;

import sparkles.ui_sdl3.sdl3_c;
import sparkles.ui_sdl3.error;

/**
`SDL_WINDOW_*`, typed.

Values mirror `SDL3/SDL_video.h`; the `flagsMatchTheHeader` unittest pins the
handful this library relies on against SDL's own `SDL_GetWindowFlags` contract
so a version bump that renumbered them would fail the build.
*/
enum WindowFlags : ulong
{
    none = 0,
    fullscreen = 0x0000_0000_0000_0001,
    occluded = 0x0000_0000_0000_0004,
    hidden = 0x0000_0000_0000_0008,
    borderless = 0x0000_0000_0000_0010,
    resizable = 0x0000_0000_0000_0020,
    minimized = 0x0000_0000_0000_0040,
    maximized = 0x0000_0000_0000_0080,
    inputFocus = 0x0000_0000_0000_0200,
    mouseFocus = 0x0000_0000_0000_0400,
    highPixelDensity = 0x0000_0000_0000_2000,
    alwaysOnTop = 0x0000_0000_0001_0000,
    vulkan = 0x0000_0000_1000_0000,
    metal = 0x0000_0000_2000_0000,
    transparent = 0x0000_0000_4000_0000,
}

/// A size in device pixels. Named, because `int[2]` at a call site reads as
/// neither "which is width" nor "pixels or cells".
struct PixelSize
{
    int width;
    int height;
}

/// What to open. Named fields rather than a flag soup at the call site.
struct WindowRequest
{
    string title = "sparkles";
    int width = 1280;
    int height = 720;
    bool resizable = true;
    bool highPixelDensity = true;

    /// Ask for a Vulkan-capable window. Required before `SDL_Vulkan_*` works.
    bool vulkan = true;

    /// The `SDL_WINDOW_*` bits this request implies.
    WindowFlags flags() const @safe pure nothrow @nogc
    {
        auto f = WindowFlags.none;
        if (resizable)
            f |= WindowFlags.resizable;
        if (highPixelDensity)
            f |= WindowFlags.highPixelDensity;
        if (vulkan)
            f |= WindowFlags.vulkan;
        return f;
    }
}

/**
An open SDL window.

Non-copyable and closed on destruction: an `SDL_Window*` is a resource, and the
one thing worse than leaking it is destroying it twice. Move it, or hold it by
reference.
*/
struct Window
{
    private SDL_Window* _handle;
    private bool _ownsSdlInit;

    @disable this(this);

    ~this() @trusted nothrow
    {
        close();
    }

    /**
    Initialise SDL's video subsystem if needed, and open a window.

    `SDL_Init` is idempotent and reference-counted by SDL itself, so this is
    safe to call for a second window; only the first caller's `SDL_Quit` in
    `close` actually shuts the subsystem down.
    */
    static SdlExpected!() open(out Window window, in WindowRequest req) @trusted nothrow
    {
        import std.string : toStringz;

        // SDL_INIT_VIDEO implies SDL_INIT_EVENTS.
        const alreadyUp = SDL_WasInit(SDL_INIT_VIDEO) != 0;
        if (!alreadyUp)
        {
            auto initialised = check(SDL_Init(SDL_INIT_VIDEO), "SDL_Init(VIDEO)");
            if (initialised.hasError)
                return initialised;
        }

        auto handle = checkPtr(
            SDL_CreateWindow(req.title.toStringz, req.width, req.height,
                cast(SDL_WindowFlags) req.flags),
            "SDL_CreateWindow");

        if (handle.hasError)
        {
            if (!alreadyUp)
                SDL_Quit();
            return err!void(handle.error);
        }

        window._handle = handle.value;
        window._ownsSdlInit = !alreadyUp;
        return ok!string();
    }

    /// Close the window, and shut SDL down if this window started it.
    void close() @trusted nothrow
    {
        if (_handle !is null)
        {
            SDL_DestroyWindow(_handle);
            _handle = null;
        }
        if (_ownsSdlInit)
        {
            SDL_Quit();
            _ownsSdlInit = false;
        }
    }

    /// The underlying handle, for `SDL_Vulkan_*` and anything not wrapped here.
    SDL_Window* handle() @safe pure nothrow @nogc => _handle;

    /// `true` once `open` has succeeded and before `close`.
    bool isOpen() const @safe pure nothrow @nogc => _handle !is null;

    /**
    The drawable size in pixels.

    Not the same as the requested size on a HiDPI display, which is the whole
    reason it is queried rather than remembered: the swapchain must match the
    pixels, not the logical window.
    */
    SdlExpected!PixelSize pixelSize() @trusted nothrow
    {
        int w, h;
        auto queried = check(SDL_GetWindowSizeInPixels(_handle, &w, &h),
            "SDL_GetWindowSizeInPixels");
        return queried.hasError
            ? err!PixelSize(queried.error)
            : ok!string(PixelSize(w, h));
    }

    /// The current `SDL_WINDOW_*` state, which SDL updates as the user acts.
    WindowFlags flags() const @trusted nothrow
        => cast(WindowFlags) SDL_GetWindowFlags(cast(SDL_Window*) _handle);

    /// `true` while the window is minimised or fully occluded — nothing to draw.
    bool isHidden() const @safe nothrow
    {
        const f = flags;
        return (f & WindowFlags.minimized) != 0 || (f & WindowFlags.occluded) != 0;
    }
}

@("ui_sdl3.window.requestFlagsAreDerivedNotHandWritten")
@safe pure nothrow @nogc unittest
{
    // The default is a resizable, HiDPI, Vulkan-capable window.
    const def = WindowRequest();
    assert(def.flags & WindowFlags.vulkan);
    assert(def.flags & WindowFlags.resizable);
    assert(def.flags & WindowFlags.highPixelDensity);

    // Each toggle drops exactly its own bit.
    const plain = WindowRequest(resizable: false, highPixelDensity: false, vulkan: false);
    assert(plain.flags == WindowFlags.none);

    const vulkanOnly = WindowRequest(resizable: false, highPixelDensity: false);
    assert(vulkanOnly.flags == WindowFlags.vulkan);
}

@("ui_sdl3.window.flagsMatchTheHeader")
@safe pure nothrow @nogc unittest
{
    // These constants are hand-transcribed, because `SDL_UINT64_C` is a
    // function-like macro ImportC drops — so pin the ones this library acts
    // on. A renumbering upstream would otherwise silently open a window
    // without Vulkan support, and fail much later at surface creation.
    static assert(WindowFlags.vulkan == 0x1000_0000);
    static assert(WindowFlags.resizable == 0x20);
    static assert(WindowFlags.highPixelDensity == 0x2000);
    static assert(WindowFlags.minimized == 0x40);
    static assert(WindowFlags.occluded == 0x4);
}

@("ui_sdl3.window.closedWindowIsInert")
@safe nothrow unittest
{
    // A default-constructed Window never opened anything, so close() must be
    // a no-op rather than a null SDL_DestroyWindow.
    Window w;
    assert(!w.isOpen);
    w.close();
    w.close();
    assert(!w.isOpen);
}
