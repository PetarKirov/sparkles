/**
Bringing Vulkan up against an SDL3 window.

SDL3's Vulkan surface is deliberately small — `SDL_Vulkan_LoadLibrary`,
`SDL_Vulkan_GetVkGetInstanceProcAddr`, `SDL_Vulkan_GetInstanceExtensions`,
`SDL_Vulkan_CreateSurface` and their teardown. There is no device creation, no
swapchain and no present, so everything from the instance down is built here on
$(MREF sparkles,vulkan).

The device is chosen for the surface rather than in the abstract: a queue
family must support both graphics and presentation to $(I this) surface, which
is why selection cannot happen before a window exists. Skia's Graphite backend
then adopts the instance, physical device, device and queue this produces —
`vuk` and `Silk.NET` both take externally created handles the same way, and it
is why `sparkles:vulkan`'s dispatch tables are per-device rather than global.
*/
module sparkles.ui_sdl3.vulkan_context;

import std.algorithm : canFind, filter, map, maxElement;
import std.array : array;
import std.range : iota;
import std.string : fromStringz;

import expected : err, ok;

import sparkles.ui_sdl3.error;
import sparkles.ui_sdl3.sdl3_c;
import sparkles.ui_sdl3.window;
import sparkles.vulkan;

/// What to ask of the instance and device.
struct ContextRequest
{
    string applicationName = "sparkles";

    /// The Vulkan version to request. Graphite wants 1.1 or better.
    uint apiVersion = apiVersion11;

    /**
    Enable `VK_LAYER_KHRONOS_validation`.

    Off by default because it is a large runtime cost and absent on most
    non-developer systems; a missing layer is reported rather than fatal.
    */
    bool validation;
}

/// One physical device's suitability for presenting to a surface.
private struct Candidate
{
    VkPhysicalDevice handle;
    uint queueFamily;
    VkPhysicalDeviceProperties props;

    /// Discrete GPUs first, then integrated, then anything else.
    ///
    /// Not a `final switch`: ImportC carries Vulkan's `*_MAX_ENUM` sentinel
    /// across as a real member, and a driver reporting anything unexpected
    /// should rank last rather than fail the build.
    int score() const @safe pure nothrow @nogc
    {
        with (VkPhysicalDeviceType) switch (props.deviceType)
        {
            case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return 3;
            case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 2;
            case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return 1;
            default:                                     return 0;
        }
    }
}

/**
A Vulkan instance, surface, device and queue, all bound to one window.

Non-copyable, and torn down in reverse order of creation. The handles are
public because Skia's `VulkanBackendContext` needs every one of them.
*/
struct VulkanContext
{
    GlobalCommands global;
    InstanceCommands instance;
    DeviceCommands device;

    VkPhysicalDevice physicalDevice;
    VkSurfaceKHR surface;

    /// The family that supports both graphics and presentation to `surface`.
    uint queueFamily = uint.max;
    VkQueue queue;

    /// The selected device's properties, for logging and capability decisions.
    VkPhysicalDeviceProperties properties;

    @disable this(this);

    ~this() @trusted nothrow
    {
        destroy();
    }

    /**
    Load Vulkan through SDL, create an instance and surface, pick a device.

    `window` must have been opened with `WindowRequest.vulkan` set; SDL refuses
    to create a surface otherwise.
    */
    static SdlExpected!() create(out VulkanContext ctx, ref Window window,
        in ContextRequest req = ContextRequest.init) @trusted nothrow
    {
        import std.string : toStringz;

        if (!window.isOpen)
            return err!void("VulkanContext.create: window is not open");

        // SDL loads the platform's loader itself; passing null takes its
        // default, which is what `SDL_Vulkan_GetVkGetInstanceProcAddr` needs.
        auto loaded = check(SDL_Vulkan_LoadLibrary(null), "SDL_Vulkan_LoadLibrary");
        if (loaded.hasError)
            return loaded;

        auto getProc = cast(PFN_vkGetInstanceProcAddr) SDL_Vulkan_GetVkGetInstanceProcAddr();
        if (getProc is null)
            return err!void("SDL_Vulkan_GetVkGetInstanceProcAddr: " ~ sdlError());

        ctx.global = GlobalCommands.load(getProc);
        if (!ctx.global.complete)
            return err!void("Vulkan global commands incomplete: missing "
                ~ ctx.global.firstMissing);

        // The surface extensions SDL requires for this platform — on Linux
        // that is VK_KHR_surface plus one of the xlib/xcb/wayland pair, and
        // guessing which would be wrong on half of them.
        uint extCount;
        const extNames = SDL_Vulkan_GetInstanceExtensions(&extCount);
        if (extNames is null)
            return err!void("SDL_Vulkan_GetInstanceExtensions: " ~ sdlError());

        auto instanceCreated = ctx.createInstance(req, extNames, extCount);
        if (instanceCreated.hasError)
            return instanceCreated;

        auto surfaceCreated = check(
            SDL_Vulkan_CreateSurface(window.handle, ctx.instance.instance, null, &ctx.surface),
            "SDL_Vulkan_CreateSurface");
        if (surfaceCreated.hasError)
        {
            ctx.destroy();
            return surfaceCreated;
        }

        auto deviceCreated = ctx.selectAndCreateDevice(req);
        if (deviceCreated.hasError)
        {
            ctx.destroy();
            return deviceCreated;
        }

        return ok!string();
    }

    private SdlExpected!() createInstance(in ContextRequest req,
        const(char*)* extNames, uint extCount) @trusted nothrow
    {
        import std.string : toStringz;

        auto appInfo = vkInfo(VkApplicationInfo(
            pApplicationName: req.applicationName.toStringz,
            applicationVersion: makeApiVersion(0, 0, 1, 0),
            pEngineName: "sparkles",
            engineVersion: makeApiVersion(0, 0, 1, 0),
            apiVersion: req.apiVersion,
        ));

        static immutable validationLayer = "VK_LAYER_KHRONOS_validation";
        const(char)* layerName = validationLayer.ptr;

        auto createInfo = vkInfo(VkInstanceCreateInfo(
            pApplicationInfo: &appInfo,
            enabledExtensionCount: extCount,
            ppEnabledExtensionNames: extNames,
            enabledLayerCount: req.validation ? 1 : 0,
            ppEnabledLayerNames: req.validation ? &layerName : null,
        ));

        VkInstance handle;
        auto created = global.createInstance(&createInfo, null, &handle).check;
        if (created.hasError)
        {
            // A missing validation layer is the one failure worth retrying
            // without, rather than refusing to start on a machine that simply
            // has no SDK installed.
            if (req.validation && created.error == VkResult.VK_ERROR_LAYER_NOT_PRESENT)
            {
                ContextRequest without = req;
                without.validation = false;
                return createInstance(without, extNames, extCount);
            }
            return err!void("vkCreateInstance: " ~ resultName(created.error));
        }

        instance = InstanceCommands.load(global, handle);
        if (!instance.complete)
            return err!void("Vulkan instance commands incomplete: missing "
                ~ instance.firstMissing);
        if (!instance.has!khrSurface)
            return err!void("VK_KHR_surface commands did not load; SDL asked for "
                ~ "surface extensions but the driver did not provide them");

        return ok!string();
    }

    private SdlExpected!() selectAndCreateDevice(in ContextRequest req) @trusted nothrow
    {
        auto candidates = pickCandidates();
        if (candidates.length == 0)
            return err!void("no Vulkan device can present to this surface");

        auto best = candidates.maxElement!(c => c.score);
        physicalDevice = best.handle;
        queueFamily = best.queueFamily;
        properties = best.props;

        float priority = 1.0f;
        auto queueInfo = vkInfo(VkDeviceQueueCreateInfo(
            queueFamilyIndex: queueFamily,
            queueCount: 1,
            pQueuePriorities: &priority,
        ));

        static immutable swapchainExt = "VK_KHR_swapchain";
        const(char)* swapchainName = swapchainExt.ptr;

        auto deviceInfo = vkInfo(VkDeviceCreateInfo(
            queueCreateInfoCount: 1,
            pQueueCreateInfos: &queueInfo,
            enabledExtensionCount: 1,
            ppEnabledExtensionNames: &swapchainName,
        ));

        VkDevice handle;
        auto created = instance.createDevice(physicalDevice, &deviceInfo, null, &handle).check;
        if (created.hasError)
            return err!void("vkCreateDevice: " ~ resultName(created.error));

        device = DeviceCommands.load(instance, handle);
        if (!device.complete)
            return err!void("Vulkan device commands incomplete: missing "
                ~ device.firstMissing);
        if (!device.has!khrSwapchain)
            return err!void("VK_KHR_swapchain commands did not load");

        device.getDeviceQueue(handle, queueFamily, 0, &queue);
        return ok!string();
    }

    /// Every (device, queue family) pair that can both render and present here.
    private Candidate[] pickCandidates() @trusted nothrow
    {
        Candidate[] found;

        auto devices = queryVkList!VkPhysicalDevice(
            instance.enumeratePhysicalDevices, instance.instance);

        foreach (dev; devices)
        {
            auto families = queryVkList!VkQueueFamilyProperties(
                instance.getPhysicalDeviceQueueFamilyProperties, dev);

            foreach (i, family; families)
            {
                if ((family.queueFlags & VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT) == 0)
                    continue;

                VkBool32 presentable;
                if (instance.getPhysicalDeviceSurfaceSupportKHR(
                        dev, cast(uint) i, surface, &presentable).check.hasError)
                    continue;
                if (!presentable)
                    continue;

                VkPhysicalDeviceProperties props;
                instance.getPhysicalDeviceProperties(dev, &props);
                found ~= Candidate(dev, cast(uint) i, props);
                break; // one family per device is enough
            }
        }

        return found;
    }

    /// The selected device's name, as the driver reports it.
    string deviceName() const @trusted nothrow
        => properties.deviceName.ptr.fromStringz.idup;

    /// Tear down device, surface and instance, in that order.
    void destroy() @trusted nothrow
    {
        if (device.device !is null && device.destroyDevice !is null)
        {
            if (device.deviceWaitIdle !is null)
                cast(void) device.deviceWaitIdle(device.device);
            device.destroyDevice(device.device, null);
            device = DeviceCommands.init;
        }

        if (surface !is null && instance.instance !is null)
        {
            SDL_Vulkan_DestroySurface(instance.instance, surface, null);
            surface = null;
        }

        if (instance.instance !is null && instance.destroyInstance !is null)
        {
            instance.destroyInstance(instance.instance, null);
            instance = InstanceCommands.init;
        }
    }
}

@("ui_sdl3.vulkan_context.candidateScoringPrefersDiscrete")
@safe pure nothrow @nogc unittest
{
    // Device choice is a policy, and the policy is "the fastest thing that can
    // present" — llvmpipe is a valid fallback, never a first choice.
    static Candidate of(VkPhysicalDeviceType t)
    {
        Candidate c;
        c.props.deviceType = t;
        return c;
    }

    with (VkPhysicalDeviceType)
    {
        assert(of(VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU).score
            > of(VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU).score);
        assert(of(VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU).score
            > of(VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU).score);
        assert(of(VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU).score
            > of(VK_PHYSICAL_DEVICE_TYPE_CPU).score);
    }
}

@("ui_sdl3.vulkan_context.destroyIsIdempotent")
@safe nothrow unittest
{
    // Teardown runs both from `destroy()` on a failed `create` and from the
    // destructor, so it must tolerate being called twice on a half-built
    // context — every handle is null here.
    VulkanContext ctx;
    ctx.destroy();
    ctx.destroy();
    assert(ctx.surface is null);
    assert(ctx.queueFamily == uint.max);
}
