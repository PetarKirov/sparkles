/** Native Vulkan surface planning and creation from typed WSI handles. */
module sparkles.vulkan_wsi.surface;

import sparkles.vulkan;
import sparkles.vulkan_wsi.error;
import sparkles.wsi;

@safe:

struct NativeSurfacePlan
{
    BackendKind backend;
    string platformExtension;
}

/**
Validate that the display and window variants form one native pair and name
the instance extension that can consume them.

AppKit is deliberately rejected: the native macOS renderer is Metal, and an
`NSView*` is not a `CAMetalLayer*`. A future explicit layer handle may add the
Vulkan/MoltenVK compatibility path without weakening this contract.
*/
VulkanWsiResult!NativeSurfacePlan planNativeSurface(in NativeHandles handles)
    pure nothrow @nogc
{
    return handles.display.match!(
        (in WaylandDisplayHandle display) {
            return handles.window.match!(
                (in WaylandWindowHandle window) {
                    if (display.display is null || window.surface is null)
                        return invalidPlan(BackendKind.wayland, "null Wayland handle");
                    version (linux)
                        return vulkanWsiOk(NativeSurfacePlan(
                            BackendKind.wayland, khrWaylandSurface));
                    else
                        return unsupportedPlan(BackendKind.wayland);
                },
                _ => mismatchPlan(BackendKind.wayland));
        },
        (in X11DisplayHandle display) {
            return handles.window.match!(
                (in X11WindowHandle window) {
                    if (display.connection is null || window.window == 0)
                        return invalidPlan(BackendKind.x11, "null XCB handle");
                    version (linux)
                        return vulkanWsiOk(NativeSurfacePlan(
                            BackendKind.x11, khrXcbSurface));
                    else
                        return unsupportedPlan(BackendKind.x11);
                },
                _ => mismatchPlan(BackendKind.x11));
        },
        (in Win32DisplayHandle display) {
            return handles.window.match!(
                (in Win32WindowHandle window) {
                    if (display.instance is null || window.hwnd is null)
                        return invalidPlan(BackendKind.win32, "null Win32 handle");
                    version (Windows)
                        return vulkanWsiOk(NativeSurfacePlan(
                            BackendKind.win32, khrWin32Surface));
                    else
                        return unsupportedPlan(BackendKind.win32);
                },
                _ => mismatchPlan(BackendKind.win32));
        },
        (in AppKitDisplayHandle display) {
            return handles.window.match!(
                (in AppKitWindowHandle window) {
                    if (display.application is null || window.window is null
                        || window.view is null)
                        return invalidPlan(BackendKind.appkit, "null AppKit handle");
                    return unsupportedPlan(BackendKind.appkit);
                },
                _ => mismatchPlan(BackendKind.appkit));
        });
}

/** Create the platform `VkSurfaceKHR` described by `handles`. */
VulkanWsiResult!VkSurfaceKHR createNativeSurface(
    ref InstanceCommands instance, in NativeHandles handles) @system nothrow
{
    auto planned = planNativeSurface(handles);
    if (planned.hasError)
        return vulkanWsiErr!VkSurfaceKHR(planned.error);

    VkSurfaceKHR surface;
    VkResult result;
    final switch (planned.value.backend)
    {
        case BackendKind.wayland:
            version (linux)
            {
                if (!instance.has!khrWaylandSurface)
                    return missingDispatch!VkSurfaceKHR(BackendKind.wayland);
                auto display = handles.display.match!(
                    (in WaylandDisplayHandle h) => h.display, _ => null);
                auto window = handles.window.match!(
                    (in WaylandWindowHandle h) => h.surface, _ => null);
                auto info = vkInfo(VkWaylandSurfaceCreateInfoKHR(
                    display: cast(wl_display*) display,
                    surface: cast(wl_surface*) window,
                ));
                result = instance.createWaylandSurfaceKHR(
                    instance.instance, &info, null, &surface);
            }
            else
                return unsupportedCreate!VkSurfaceKHR(BackendKind.wayland);
            break;

        case BackendKind.x11:
            version (linux)
            {
                if (!instance.has!khrXcbSurface)
                    return missingDispatch!VkSurfaceKHR(BackendKind.x11);
                auto display = handles.display.match!(
                    (in X11DisplayHandle h) => h.connection, _ => null);
                auto window = handles.window.match!(
                    (in X11WindowHandle h) => h.window, _ => 0);
                auto info = vkInfo(VkXcbSurfaceCreateInfoKHR(
                    connection: cast(xcb_connection_t*) display,
                    window: cast(xcb_window_t) window,
                ));
                result = instance.createXcbSurfaceKHR(
                    instance.instance, &info, null, &surface);
            }
            else
                return unsupportedCreate!VkSurfaceKHR(BackendKind.x11);
            break;

        case BackendKind.win32:
            version (Windows)
            {
                if (!instance.has!khrWin32Surface)
                    return missingDispatch!VkSurfaceKHR(BackendKind.win32);
                auto display = handles.display.match!(
                    (in Win32DisplayHandle h) => h.instance, _ => null);
                auto window = handles.window.match!(
                    (in Win32WindowHandle h) => h.hwnd, _ => null);
                auto info = vkInfo(VkWin32SurfaceCreateInfoKHR(
                    hinstance: cast(void*) display,
                    hwnd: cast(void*) window,
                ));
                result = instance.createWin32SurfaceKHR(
                    instance.instance, &info, null, &surface);
            }
            else
                return unsupportedCreate!VkSurfaceKHR(BackendKind.win32);
            break;

        case BackendKind.appkit:
            return unsupportedCreate!VkSurfaceKHR(BackendKind.appkit);
    }

    if (result < 0)
        return vulkanWsiErr!VkSurfaceKHR(vulkanWsiError(
            VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createSurface,
            planned.value.backend, result, "native Vulkan surface creation failed"));
    return vulkanWsiOk(surface);
}

private VulkanWsiResult!NativeSurfacePlan invalidPlan(BackendKind backend,
    scope const(char)[] diagnostic) pure nothrow @nogc
    => vulkanWsiErr!NativeSurfacePlan(vulkanWsiError(
        VulkanWsiErrorKind.mismatchedHandles, VulkanWsiOperation.planSurface,
        backend, VkResult.VK_SUCCESS, diagnostic));

private VulkanWsiResult!NativeSurfacePlan mismatchPlan(BackendKind backend)
    pure nothrow @nogc
    => invalidPlan(backend, "display/window backend mismatch");

private VulkanWsiResult!NativeSurfacePlan unsupportedPlan(BackendKind backend)
    pure nothrow @nogc
    => vulkanWsiErr!NativeSurfacePlan(vulkanWsiError(
        VulkanWsiErrorKind.unsupported, VulkanWsiOperation.planSurface,
        backend, VkResult.VK_SUCCESS, "Vulkan surface unsupported on this target"));

private VulkanWsiResult!T missingDispatch(T)(BackendKind backend)
    pure nothrow @nogc
    => vulkanWsiErr!T(vulkanWsiError(
        VulkanWsiErrorKind.incompleteDispatch, VulkanWsiOperation.createSurface,
        backend, VkResult.VK_SUCCESS, "platform surface commands did not load"));

private VulkanWsiResult!T unsupportedCreate(T)(BackendKind backend)
    pure nothrow @nogc
    => vulkanWsiErr!T(vulkanWsiError(
        VulkanWsiErrorKind.unsupported, VulkanWsiOperation.createSurface,
        backend, VkResult.VK_SUCCESS, "native Vulkan surface unsupported"));

@("vulkan_wsi.surface.planRequiresMatchedLiveHandles")
@system pure nothrow @nogc unittest
{
    NativeHandles handles;
    handles.display = DisplayHandle(WaylandDisplayHandle(cast(void*) 1));
    handles.window = WindowHandle(WaylandWindowHandle(cast(void*) 2));
    auto wayland = planNativeSurface(handles);
    version (linux)
    {
        assert(wayland.hasValue);
        assert(wayland.value.backend == BackendKind.wayland);
        assert(wayland.value.platformExtension == khrWaylandSurface);
    }
    else
        assert(wayland.hasError);

    handles.window = WindowHandle(X11WindowHandle(7, 8));
    auto mismatched = planNativeSurface(handles);
    assert(mismatched.hasError);
    assert(mismatched.error.kind == VulkanWsiErrorKind.mismatchedHandles);

    handles.display = DisplayHandle(X11DisplayHandle(null, null, 0));
    auto missing = planNativeSurface(handles);
    assert(missing.hasError);
    assert(missing.error.kind == VulkanWsiErrorKind.mismatchedHandles);
}
