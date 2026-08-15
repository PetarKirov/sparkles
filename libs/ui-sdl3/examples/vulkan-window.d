#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_window"
    dependency "sparkles:ui-sdl3" path="../../.."
    dependency "sparkles:vulkan" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "expected" version="~>0.4.1"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
 * Opens an SDL3 window, brings Vulkan up against it, and reports what the
 * surface can do.
 *
 * This is the seam `sparkles:ui-skia` is built on, exercised end to end: SDL
 * supplies the loader, the required instance extensions and the surface;
 * everything from the instance down — physical-device selection against *this*
 * surface, the logical device, the graphics/present queue — is ours.
 *
 * The surface report is the interesting part rather than decoration. Format,
 * colour space, present mode and image count are exactly the inputs a
 * swapchain needs, and Skia's `VulkanBackendContext` adopts the same instance,
 * device and queue this prints.
 */
module vulkan_window_example;

import std.algorithm : map;
import std.array : array;
import std.format : format;

import expected : Expected, err, ok;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.core_cli.args;
import sparkles.ui_sdl3;
import sparkles.vulkan;

int main(string[] args) => runCli!VulkanWindow(args);

@(Command("vulkan-window",
    shortDescription: "Open an SDL3 window and report its Vulkan surface capabilities",
))
struct VulkanWindow
{
    @(Option(`W|width`, description: "Window width in logical units"))
    int width = 960;

    @(Option(`H|height`, description: "Window height in logical units"))
    int height = 540;

    @(Option(`f|frames`, description: "Hold the window open for N event-pump frames (0 = exit at once)"))
    int frames;

    @(Option("validation", description: "Enable VK_LAYER_KHRONOS_validation if installed"))
    bool validation;

    @(Option("no-color", description: "Disable colored output"))
    bool noColor;

    Expected!(void, string) run()
    {
        Window window;
        auto opened = Window.open(window, WindowRequest(
            title: "sparkles — vulkan window",
            width: width,
            height: height,
        ));
        // No display is a degraded environment, not a failure: CI runs this
        // with --help, but a developer on a tty should get a clear skip.
        if (opened.hasError)
            return skip("cannot open a window", opened.error);

        VulkanContext vk;
        auto brought = VulkanContext.create(vk, window, ContextRequest(
            applicationName: "sparkles-vulkan-window",
            validation: validation,
        ));
        if (brought.hasError)
            return skip("cannot bring up Vulkan", brought.error);

        auto report = describe(vk, window);
        auto opt = PrettyPrintOptions!void(
            colored: !noColor,
            softMaxWidth: 100,
            maxItems: 64,
        );
        writeln(prettyPrint(report, opt));

        foreach (_; 0 .. frames)
        {
            SDL_Event ev;
            while (SDL_PollEvent(&ev))
                if (ev.type == SDL_EventType.SDL_EVENT_QUIT)
                    return ok();
            SDL_Delay(16);
        }

        return ok();
    }
}

import std.stdio : writeln;

/// A skip is a success: the environment lacks a display or a driver.
Expected!(void, string) skip(string what, string detail)
{
    writeln("SKIP: ", what, " — ", detail);
    return ok();
}

// -----------------------------------------------------------------------------
// Report model
// -----------------------------------------------------------------------------

struct SurfaceReport
{
    string device;
    string deviceType;
    uint queueFamily;
    string windowPixels;
    string currentExtent;
    uint minImageCount;
    uint maxImageCount;
    SwapchainReport swapchain;
    string[] formats;
    string[] presentModes;
}

/// What the four `choose*` policies actually settled on against this driver.
struct SwapchainReport
{
    string created;
    string extent;
    string format;
    string colorSpace;
    string presentMode;
    uint imageCount;
}

SurfaceReport describe(ref VulkanContext vk, ref Window window) @system
{
    SurfaceReport r = {
        device: vk.deviceName,
        deviceType: deviceTypeName(vk.properties.deviceType),
        queueFamily: vk.queueFamily,
    };

    auto px = window.pixelSize;
    r.windowPixels = px.hasError ? "?" : format("%dx%d", px.value.width, px.value.height);

    VkSurfaceCapabilitiesKHR caps;
    if (!vk.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
            vk.physicalDevice, vk.surface, &caps).check.hasError)
    {
        // 0xFFFFFFFF is Vulkan's "the surface has no size of its own — the
        // swapchain picks, and the window's pixel size is the answer". Several
        // Wayland and RADV paths report it, so a swapchain that trusts
        // `currentExtent` blindly creates a 4-billion-pixel image and fails.
        r.currentExtent = caps.currentExtent.width == uint.max
            ? "surface-defined (0xFFFFFFFF — use the window's pixel size)"
            : format("%dx%d", caps.currentExtent.width, caps.currentExtent.height);
        r.minImageCount = caps.minImageCount;
        r.maxImageCount = caps.maxImageCount;
    }

    // Creating it is the point: `chooseExtent` and friends are unit-tested,
    // but only a real driver says whether the combination they pick is one it
    // will actually accept.
    auto px2 = window.pixelSize;
    Swapchain sc;
    auto made = Swapchain.create(sc, vk,
        px2.hasError ? PixelSize(0, 0) : px2.value);
    if (made.hasError)
    {
        r.swapchain.created = "failed: " ~ made.error;
    }
    else
    {
        r.swapchain = SwapchainReport(
            created: "yes",
            extent: format("%dx%d", sc.extent.width, sc.extent.height),
            format: format("%s", sc.format),
            colorSpace: format("%s", sc.colorSpace),
            presentMode: presentModeName(sc.presentMode),
            imageCount: cast(uint) sc.images.length,
        );
        sc.destroy(vk);
    }

    r.formats = queryVkList!VkSurfaceFormatKHR(
        vk.instance.getPhysicalDeviceSurfaceFormatsKHR, vk.physicalDevice, vk.surface)
        .map!(f => format("%s / %s", f.format, f.colorSpace))
        .array;

    r.presentModes = queryVkList!VkPresentModeKHR(
        vk.instance.getPhysicalDeviceSurfacePresentModesKHR, vk.physicalDevice, vk.surface)
        .map!(m => presentModeName(m))
        .array;

    return r;
}

string deviceTypeName(VkPhysicalDeviceType t) @safe pure nothrow @nogc
{
    with (VkPhysicalDeviceType) switch (t)
    {
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated-gpu";
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "discrete-gpu";
        case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return "virtual-gpu";
        case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "cpu";
        default:                                     return "other";
    }
}

string presentModeName(VkPresentModeKHR m) @safe pure nothrow @nogc
{
    with (VkPresentModeKHR) switch (m)
    {
        case VK_PRESENT_MODE_IMMEDIATE_KHR:    return "immediate (no vsync, tears)";
        case VK_PRESENT_MODE_MAILBOX_KHR:      return "mailbox (vsync, no tear, drops frames)";
        case VK_PRESENT_MODE_FIFO_KHR:         return "fifo (vsync, always available)";
        case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "fifo-relaxed (vsync, tears when late)";
        default:                               return "other";
    }
}
