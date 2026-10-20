/**
The process-scoped half of Vulkan presentation: the loader, the instance, the
physical device, the device, its queue and its pipeline cache (§10.1 of the
window-system-integration specification).

A `VulkanDevice` is made once per process from the WSI's display handle, before
any window has a surface: a device is chosen by queue capability and the
platform's own presentation support, so a surface is not needed to choose it.
Each surface a window has is then a `WindowSurface` on this device, which costs
a `VkSurfaceKHR` and a present-support check. Keeping the device while a window
has no surface makes a return from the background cost only a surface and a
swapchain; it is released on memory pressure, or by an application that prefers
the least background memory, whenever its surface goes.

The pipeline cache is loaded from and saved to a path the application chooses
(Android: the activity's `internalDataPath`), so a launch after the process was
killed still finds its pipelines compiled.

A `VulkanDevice` is address-pinned while surfaces made on it exist: each
`WindowSurface` refers to it.
*/
module sparkles.vulkan_wsi.device;

import std.algorithm : maxElement;
import std.string : fromStringz;

import sparkles.base.text.cstring : CString, tryToCString;
import sparkles.vulkan;
import sparkles.vulkan_wsi.error;
import sparkles.vulkan_wsi.surface : platformSurfaceExtension;
import sparkles.wsi : AndroidDisplayHandle, AppKitDisplayHandle, BackendKind,
    DisplayHandle, match, WaylandDisplayHandle, Win32DisplayHandle, X11DisplayHandle;

@safe:

struct ContextRequest
{
    string applicationName = "sparkles";
    uint apiVersion = apiVersion11;
    bool validation;
}

package struct Candidate
{
    VkPhysicalDevice handle;
    uint queueFamily;
    VkPhysicalDeviceProperties properties;

    int score() const pure nothrow @nogc
    {
        with (VkPhysicalDeviceType) switch (properties.deviceType)
        {
            case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return 3;
            case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 2;
            case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return 1;
            default:                                     return 0;
        }
    }
}

/// The process-scoped Vulkan objects; see the module documentation.
struct VulkanDevice
{
    GlobalCommands global;
    InstanceCommands instance;
    DeviceCommands device;

    BackendKind backend;
    VkPhysicalDevice physicalDevice;
    uint queueFamily = uint.max;
    VkQueue queue;
    VkPhysicalDeviceProperties properties;
    bool dynamicRendering;
    /// Built pipelines' compiled form, shared by every pipeline made on this
    /// device; `null` until $(LREF loadPipelineCache).
    VkPipelineCache pipelineCache;
    /// Whether the instance loaded the validation layer, which a request
    /// asks for but the loader may not have.
    bool validationEnabled;
    /// Whether the instance enabled `VK_EXT_debug_utils`, so the layer's
    /// messages can be received by a messenger rather than the console.
    bool debugUtils;

    @disable this(this);

    ~this() @trusted nothrow
    {
        destroy();
    }

    /**
    Makes the device for the WSI whose display handle is `display`: an
    instance with the platform's surface extension, and a device whose
    graphics queue can present on that platform, preferring a discrete GPU.
    */
    static VulkanWsiResult!void create(out VulkanDevice d, in DisplayHandle display,
        in ContextRequest request = ContextRequest.init) @trusted nothrow
    {
        const backend = display.match!(
            (in WaylandDisplayHandle _) => BackendKind.wayland,
            (in X11DisplayHandle _) => BackendKind.x11,
            (in Win32DisplayHandle _) => BackendKind.win32,
            (in AppKitDisplayHandle _) => BackendKind.appkit,
            (in AndroidDisplayHandle _) => BackendKind.android);
        auto made = d.createInstance(backend, request);
        if (made.hasError)
            return made;
        return d.selectAndCreateDevice(request,
            (VkPhysicalDevice physical, uint family) => d.presentable(display, physical, family));
    }

    /**
    Makes a device for offscreen rendering: an instance without surface
    extensions, and a device whose graphics queue draws into images it never
    presents, with no swapchain. With `request.validation`, the instance also
    enables `VK_EXT_debug_utils` where it is offered ($(LREF debugUtils)).
    */
    static VulkanWsiResult!void createHeadless(out VulkanDevice d,
        in ContextRequest request = ContextRequest.init) @trusted nothrow
    {
        auto loaded = loadGetInstanceProcAddr();
        if (loaded.hasError)
            return d.fail(VulkanWsiErrorKind.loaderUnavailable,
                VulkanWsiOperation.load, VkResult.VK_SUCCESS,
                "Vulkan loader is unavailable");
        d.global = GlobalCommands.load(loaded.value);
        if (!d.global.complete)
            return d.fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.load, VkResult.VK_SUCCESS,
                "Vulkan global commands are incomplete");

        auto advertised = queryVkList!VkExtensionProperties(
            d.global.enumerateInstanceExtensionProperties, null);
        const(char)*[2] names;
        uint nameCount;
        if (request.validation && advertised.hasExtension(extDebugUtils))
            names[nameCount++] = extDebugUtils.ptr;
        const portability = instancePortability(d.global, names[0 .. nameCount]);
        if (portability.addExtension)
            names[nameCount++] = khrPortabilityEnumeration.ptr;
        auto made = d.createInstanceWith(request, names[0 .. nameCount], portability,
            presents: false);
        if (made.hasError)
            return made;
        d.debugUtils = nameCount > 0 && names[0] is extDebugUtils.ptr
            && d.instance.has!extDebugUtils;
        return d.selectAndCreateDevice(request, (VkPhysicalDevice, uint) => true,
            presents: false);
    }

    string deviceName() const nothrow
        => properties.deviceName.fromStringz.idup;

    /**
    Creates the pipeline cache from the bytes saved at `path`, or empty when
    there are none. A cache another driver or device wrote is ignored by the
    driver itself (its header names both), so a stale file costs only the
    compilation it would have saved.
    */
    VulkanWsiResult!void loadPipelineCache(string path) @trusted nothrow
    {
        import std.file : exists, read;

        if (pipelineCache !is null)
            return vulkanWsiOk();
        const(void)[] saved;
        try
            if (path.length != 0 && exists(path))
                saved = read(path);
        catch (Exception)
            saved = null;
        auto info = vkInfo(VkPipelineCacheCreateInfo(
            initialDataSize: saved.length,
            pInitialData: saved.ptr,
        ));
        const result = device.createPipelineCache(device.device, &info, null, &pipelineCache);
        if (result < 0)
            return fail(VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createDevice,
                result, "vkCreatePipelineCache failed");
        return vulkanWsiOk();
    }

    /**
    Writes the pipeline cache to `path`, through a temporary file renamed
    over it, so a crash mid-write never leaves a torn cache. Call it after
    building pipelines, and before releasing the device.
    */
    VulkanWsiResult!void savePipelineCache(string path) @trusted nothrow
    {
        import std.file : rename, write;

        if (pipelineCache is null || path.length == 0)
            return vulkanWsiOk();
        size_t size;
        auto result = device.getPipelineCacheData(device.device, pipelineCache, &size, null);
        if (result < 0 || size == 0)
            return vulkanWsiOk();
        auto bytes = new ubyte[size];
        result = device.getPipelineCacheData(device.device, pipelineCache, &size, bytes.ptr);
        if (result < 0)
            return fail(VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createDevice,
                result, "vkGetPipelineCacheData failed");
        try
        {
            write(path ~ ".tmp", bytes[0 .. size]);
            rename(path ~ ".tmp", path);
        }
        catch (Exception)
            return fail(VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createDevice,
                VkResult.VK_SUCCESS, "the pipeline cache could not be written");
        return vulkanWsiOk();
    }

    /// Releases everything, the device first; idempotent.
    void destroy() @trusted nothrow
    {
        releaseDevice();
        releaseInstance();
    }

    package void releaseDevice() @trusted nothrow
    {
        if (device.device is null || device.destroyDevice is null)
            return;
        if (device.deviceWaitIdle !is null)
            device.deviceWaitIdle(device.device);
        if (pipelineCache !is null)
            device.destroyPipelineCache(device.device, pipelineCache, null);
        pipelineCache = null;
        device.destroyDevice(device.device, null);
        device = DeviceCommands.init;
        physicalDevice = null;
        queueFamily = uint.max;
        queue = null;
        properties = VkPhysicalDeviceProperties.init;
        dynamicRendering = false;
    }

    package void releaseInstance() @trusted nothrow
    {
        if (instance.instance !is null && instance.destroyInstance !is null)
            instance.destroyInstance(instance.instance, null);
        instance = InstanceCommands.init;
        global = GlobalCommands.init;
    }

    // Whether `physical`'s queue `family` can present on the display, asked
    // the platform's way. Android presents from every graphics queue.
    private bool presentable(in DisplayHandle display, VkPhysicalDevice physical,
        uint family) @trusted nothrow
    {
        return display.match!(
            (in WaylandDisplayHandle h) {
                version (Android)
                    return false;
                else version (linux)
                    return instance.getPhysicalDeviceWaylandPresentationSupportKHR is null
                        || instance.getPhysicalDeviceWaylandPresentationSupportKHR(
                            physical, family, cast(wl_display*) h.display) != 0;
                else
                    return false;
            },
            (in X11DisplayHandle h) {
                version (Android)
                    return false;
                else version (linux)
                {
                    if (instance.getPhysicalDeviceXcbPresentationSupportKHR is null)
                        return true;
                    auto connection = cast(xcb_connection_t*) h.connection;
                    auto screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
                    foreach (_; 0 .. h.screen)
                        xcb_screen_next(&screens);
                    return instance.getPhysicalDeviceXcbPresentationSupportKHR(physical,
                        family, connection, screens.data.root_visual) != 0;
                }
                else
                    return false;
            },
            (in Win32DisplayHandle _) {
                version (Windows)
                    return instance.getPhysicalDeviceWin32PresentationSupportKHR is null
                        || instance.getPhysicalDeviceWin32PresentationSupportKHR(physical, family) != 0;
                else
                    return false;
            },
            (in AppKitDisplayHandle _) => false,
            (in AndroidDisplayHandle _) {
                version (Android)
                    return true;
                else
                    return false;
            });
    }

package:
    VulkanWsiResult!void createInstance(BackendKind kind, in ContextRequest request)
        @trusted nothrow
    {
        backend = kind;
        const platform = platformSurfaceExtension(kind);
        if (platform.length == 0)
            return fail(VulkanWsiErrorKind.unsupported, VulkanWsiOperation.createInstance,
                VkResult.VK_SUCCESS, "no Vulkan surface for this backend on this target");

        auto loaded = loadGetInstanceProcAddr();
        if (loaded.hasError)
            return fail(VulkanWsiErrorKind.loaderUnavailable,
                VulkanWsiOperation.load, VkResult.VK_SUCCESS,
                "Vulkan loader is unavailable");

        global = GlobalCommands.load(loaded.value);
        if (!global.complete)
            return fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.load, VkResult.VK_SUCCESS,
                "Vulkan global commands are incomplete");

        auto advertised = queryVkList!VkExtensionProperties(
            global.enumerateInstanceExtensionProperties, null);
        if (!advertised.hasExtension(khrSurface) || !advertised.hasExtension(platform[]))
            return fail(VulkanWsiErrorKind.missingExtension,
                VulkanWsiOperation.createInstance, VkResult.VK_ERROR_EXTENSION_NOT_PRESENT,
                "required native surface extension is unavailable");

        const(char)*[3] names;
        uint nameCount;
        names[nameCount++] = khrSurface.ptr;
        names[nameCount++] = platform.ptr;
        const portability = instancePortability(global, names[0 .. nameCount]);
        if (portability.addExtension)
            names[nameCount++] = khrPortabilityEnumeration.ptr;
        return createInstanceWith(request, names[0 .. nameCount], portability);
    }

    VulkanWsiResult!void selectAndCreateDevice(in ContextRequest request,
        scope bool delegate(VkPhysicalDevice, uint) nothrow presentable,
        bool presents = true) @trusted nothrow
    {
        auto candidates = pickCandidates(presentable);
        if (candidates.length == 0)
            return fail(VulkanWsiErrorKind.noPresentDevice,
                VulkanWsiOperation.selectDevice, VkResult.VK_SUCCESS,
                "no graphics queue can present on this platform");

        auto best = candidates.maxElement!(candidate => candidate.score);
        physicalDevice = best.handle;
        queueFamily = best.queueFamily;
        properties = best.properties;

        float priority = 1.0f;
        auto queueInfo = vkInfo(VkDeviceQueueCreateInfo(
            queueFamilyIndex: queueFamily,
            queueCount: 1,
            pQueuePriorities: &priority,
        ));

        auto advertised = queryVkList!VkExtensionProperties(
            instance.enumerateDeviceExtensionProperties, physicalDevice, null);
        if (presents && !advertised.hasExtension(khrSwapchain))
            return fail(VulkanWsiErrorKind.missingExtension,
                VulkanWsiOperation.createDevice, VkResult.VK_ERROR_EXTENSION_NOT_PRESENT,
                "VK_KHR_swapchain is unavailable");

        const wantPortability = advertised.hasExtension(khrPortabilitySubset);
        const major = apiVersionMajor(request.apiVersion);
        const minor = apiVersionMinor(request.apiVersion);
        const atLeast12 = major > 1 || (major == 1 && minor >= 2);
        const atLeast13 = major > 1 || (major == 1 && minor >= 3);
        const wantDynamicExtension = !atLeast13 && atLeast12
            && advertised.hasExtension(khrDynamicRendering);
        const wantDynamicFeature = atLeast13 || wantDynamicExtension;

        const(char)*[3] deviceExtensions;
        uint extensionCount;
        if (presents)
            deviceExtensions[extensionCount++] = khrSwapchain.ptr;
        if (wantPortability)
            deviceExtensions[extensionCount++] = khrPortabilitySubset.ptr;
        if (wantDynamicExtension)
            deviceExtensions[extensionCount++] = khrDynamicRendering.ptr;

        auto dynamicFeature = vkInfo(VkPhysicalDeviceDynamicRenderingFeatures(
            dynamicRendering: VK_TRUE,
        ));
        auto info = vkInfo(VkDeviceCreateInfo(
            pNext: wantDynamicFeature ? &dynamicFeature : null,
            queueCreateInfoCount: 1,
            pQueueCreateInfos: &queueInfo,
            enabledExtensionCount: extensionCount,
            ppEnabledExtensionNames: deviceExtensions.ptr,
        ));

        VkDevice handle;
        const result = instance.createDevice(physicalDevice, &info, null, &handle);
        if (result < 0)
            return fail(VulkanWsiErrorKind.vulkanFailure,
                VulkanWsiOperation.createDevice, result, "vkCreateDevice failed");

        device = DeviceCommands.load(instance, handle);
        if (!device.complete || (presents && !device.has!khrSwapchain))
            return fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.createDevice, VkResult.VK_SUCCESS,
                "Vulkan device commands are incomplete");

        dynamicRendering = wantDynamicFeature
            && (device.has!vkVersion13 || device.has!khrDynamicRendering);
        device.getDeviceQueue(handle, queueFamily, 0, &queue);
        return vulkanWsiOk();
    }

    VulkanWsiResult!void fail(VulkanWsiErrorKind kind,
        VulkanWsiOperation operation, VkResult result,
        scope const(char)[] diagnostic) const pure nothrow @nogc
        => vulkanWsiErr!void(vulkanWsiError(
            kind, operation, backend, result, diagnostic));

private:
    VulkanWsiResult!void createInstanceWith(in ContextRequest request,
        scope const(char*)[] extensionNames,
        in InstancePortability portability, bool presents = true) @trusted nothrow
    {
        CString!256 appName;
        if (!tryToCString(appName, [request.applicationName]))
            return fail(VulkanWsiErrorKind.vulkanFailure,
                VulkanWsiOperation.createInstance, VkResult.VK_SUCCESS,
                "application name exceeds 255 bytes");

        auto appInfo = vkInfo(VkApplicationInfo(
            pApplicationName: appName.ptr,
            applicationVersion: makeApiVersion(0, 0, 1, 0),
            pEngineName: "sparkles",
            engineVersion: makeApiVersion(0, 0, 1, 0),
            apiVersion: request.apiVersion,
        ));

        const(char)* layerName = "VK_LAYER_KHRONOS_validation".ptr;
        auto info = vkInfo(VkInstanceCreateInfo(
            flags: portability.flags,
            pApplicationInfo: &appInfo,
            enabledExtensionCount: cast(uint) extensionNames.length,
            ppEnabledExtensionNames: extensionNames.ptr,
            enabledLayerCount: request.validation ? 1 : 0,
            ppEnabledLayerNames: request.validation ? &layerName : null,
        ));

        VkInstance handle;
        const result = global.createInstance(&info, null, &handle);
        if (result == VkResult.VK_ERROR_LAYER_NOT_PRESENT && request.validation)
        {
            ContextRequest withoutValidation = request;
            withoutValidation.validation = false;
            return createInstanceWith(withoutValidation, extensionNames, portability, presents);
        }
        if (result < 0)
            return fail(VulkanWsiErrorKind.vulkanFailure,
                VulkanWsiOperation.createInstance, result,
                "vkCreateInstance failed");

        instance = InstanceCommands.load(global, handle);
        validationEnabled = request.validation;
        if (!instance.complete || (presents && !instance.has!khrSurface))
            return fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.createInstance, VkResult.VK_SUCCESS,
                "Vulkan instance commands are incomplete");
        return vulkanWsiOk();
    }

    Candidate[] pickCandidates(scope bool delegate(VkPhysicalDevice, uint) nothrow presentable)
        @trusted nothrow
    {
        Candidate[] found;
        auto devices = queryVkList!VkPhysicalDevice(
            instance.enumeratePhysicalDevices, instance.instance);
        foreach (physical; devices)
        {
            auto families = queryVkList!VkQueueFamilyProperties(
                instance.getPhysicalDeviceQueueFamilyProperties, physical);
            foreach (index, family; families)
            {
                if ((family.queueFlags & VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT) == 0
                    || !presentable(physical, cast(uint) index))
                    continue;
                VkPhysicalDeviceProperties candidateProperties;
                instance.getPhysicalDeviceProperties(physical, &candidateProperties);
                found ~= Candidate(physical, cast(uint) index, candidateProperties);
                break;
            }
        }
        return found;
    }
}

@("vulkan_wsi.device.deviceScoringPrefersDiscrete")
@safe pure nothrow @nogc unittest
{
    static Candidate candidate(VkPhysicalDeviceType type)
    {
        Candidate result;
        result.properties.deviceType = type;
        return result;
    }

    with (VkPhysicalDeviceType)
    {
        assert(candidate(VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU).score
            > candidate(VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU).score);
        assert(candidate(VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU).score
            > candidate(VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU).score);
    }
}

@("vulkan_wsi.device.destroyIsIdempotentWithoutHandles")
@system nothrow unittest
{
    VulkanDevice device;
    device.destroy();
    device.destroy();
    assert(device.queueFamily == uint.max && device.pipelineCache is null);
}
