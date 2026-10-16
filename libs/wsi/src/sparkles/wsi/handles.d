/** Typed native display/window handles handed to render bridges. */
module sparkles.wsi.handles;

import std.sumtype : SumType;
public import std.sumtype : match;

@safe:

struct WaylandDisplayHandle { void* display; }
struct WaylandWindowHandle { void* surface; }

struct X11DisplayHandle
{
    void* connection;
    void* display;
    int screen;
}

struct X11WindowHandle
{
    uint window;
    uint visualId;
}

struct Win32DisplayHandle { void* instance; }
struct Win32WindowHandle { void* hwnd; }
struct AppKitDisplayHandle { void* application; }
/// The `ANativeActivity*` that owns the window.
struct AndroidDisplayHandle { void* activity; }
/// The activity's current `ANativeWindow*`; it changes when the surface is
/// recreated, so query it again after a surface-metrics change.
struct AndroidWindowHandle { void* nativeWindow; }

struct AppKitWindowHandle
{
    void* window;
    void* view;
}

alias DisplayHandle = SumType!(WaylandDisplayHandle, X11DisplayHandle,
    Win32DisplayHandle, AppKitDisplayHandle, AndroidDisplayHandle);
alias WindowHandle = SumType!(WaylandWindowHandle, X11WindowHandle,
    Win32WindowHandle, AppKitWindowHandle, AndroidWindowHandle);

struct NativeHandles
{
    DisplayHandle display;
    WindowHandle window;
}

@("wsi.handles.backendVariantsCannotBeConfused")
@system
unittest
{
    NativeHandles h;
    h.display = DisplayHandle(Win32DisplayHandle(cast(void*) 1));
    h.window = WindowHandle(Win32WindowHandle(cast(void*) 2));

    assert(h.display.match!(
        (in Win32DisplayHandle d) => d.instance == cast(void*) 1,
        _ => false));
    assert(h.window.match!(
        (in Win32WindowHandle w) => w.hwnd == cast(void*) 2,
        _ => false));
}
