/** Cross-target compile/run probe for native Vulkan surface handle plans. */
module surface_plan_smoke;

import std.stdio : writeln;

import sparkles.vulkan_wsi;
import sparkles.wsi;

int main()
{
    NativeHandles handles;
    version (Windows)
    {
        handles.display = DisplayHandle(Win32DisplayHandle(cast(void*) 1));
        handles.window = WindowHandle(Win32WindowHandle(cast(void*) 2));
        auto plan = planNativeSurface(handles);
        assert(plan.hasValue);
        assert(plan.value.backend == BackendKind.win32);
        writeln("ok: Win32 native Vulkan surface ABI/plan");
    }
    else version (linux)
    {
        handles.display = DisplayHandle(WaylandDisplayHandle(cast(void*) 1));
        handles.window = WindowHandle(WaylandWindowHandle(cast(void*) 2));
        auto plan = planNativeSurface(handles);
        assert(plan.hasValue);
        assert(plan.value.backend == BackendKind.wayland);
        writeln("ok: Linux native Vulkan surface ABI/plan");
    }
    else
        writeln("SKIP: native Vulkan surface plan is not targeted here");
    return 0;
}
