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
    /// The application's version (`makeApiVersion(0, major, minor, patch)`),
    /// from its `AppIdentity`.
    uint applicationVersion = makeApiVersion(0, 0, 1, 0);
    uint apiVersion = apiVersion11;
    bool validation;
    /// A messenger made as soon as the instance exists, so it hears the
    /// device being chosen and created as well (offscreen devices with
    /// `VK_EXT_debug_utils` only); destroyed with the instance.
    const(VkDebugUtilsMessengerCreateInfoEXT)* messenger;
    /// Enable `VK_EXT_debug_utils` where the instance offers it, so a GPU
    /// profiler's scopes are also labels RenderDoc, Nsight and RGP show
    /// (`PRF12`). Validation asks for it too.
    bool debugLabels;
}

/**
The host clock `MonoTime` reads, as a Vulkan time domain: what a calibrated
timestamp is sampled against so a GPU time lands on the CPU's timeline
(`PRF11`). druntime's `MonoTime` is `CLOCK_MONOTONIC` on Linux and Android
and `QueryPerformanceCounter` on Windows; elsewhere there is no domain to
calibrate against, and `hasMonoTimeDomain` is false.

On macOS MoltenVK offers `CLOCK_MONOTONIC_RAW` and samples
`mach_continuous_time` for it, which counts sleep, where `MonoTime` is
`mach_absolute_time`, which does not: the profiler subtracts the sleep the
two differ by when it calibrates (`hostClockOffsetNanos`).
*/
version (linux)
    enum VkTimeDomainKHR monoTimeDomain = VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR;
else version (Windows)
    enum VkTimeDomainKHR monoTimeDomain =
        VkTimeDomainKHR.VK_TIME_DOMAIN_QUERY_PERFORMANCE_COUNTER_KHR;
else version (OSX)
    enum VkTimeDomainKHR monoTimeDomain = VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_RAW_KHR;
else
    enum VkTimeDomainKHR monoTimeDomain = VkTimeDomainKHR.VK_TIME_DOMAIN_DEVICE_KHR;

/// ditto
enum bool hasMonoTimeDomain = monoTimeDomain != VkTimeDomainKHR.VK_TIME_DOMAIN_DEVICE_KHR;

package struct Candidate
{
    VkPhysicalDevice handle;
    uint queueFamily;
    VkPhysicalDeviceProperties properties;
    uint timestampValidBits;

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
    /// The Vulkan version the device was created at: the lower of the
    /// request's and what the device supports, which decides what a
    /// shader may assume (SPIR-V 1.6 at 1.3, 1.3 below it).
    uint apiVersion;
    bool dynamicRendering;
    /// Whether framebuffers may be created imageless (`VK_KHR_imageless_framebuffer`,
    /// core in 1.2): enabled wherever the device has the feature.
    bool imagelessFramebuffer;
    /// Whether a present can carry an id and its completion be polled
    /// (`VK_KHR_present_id` and `VK_KHR_present_wait`, `PRF13` of the
    /// profiling specification): enabled wherever the device has both
    /// features and presents.
    bool presentWait;
    /// Whether a present can carry an id and the time it reached the display
    /// be read back, with the display's refresh period
    /// (`VK_GOOGLE_display_timing`, `PRF13`): enabled wherever the device has
    /// it and presents.
    bool displayTiming;
    /// Whether each heap's budget and usage can be read
    /// (`VK_EXT_memory_budget`, `PRF15`): enabled wherever the device has it.
    bool memoryBudget;
    /// Built pipelines' compiled form, shared by every pipeline made on this
    /// device; `null` until $(LREF loadPipelineCache).
    VkPipelineCache pipelineCache;
    /// Whether the instance loaded the validation layer, which a request
    /// asks for but the loader may not have.
    bool validationEnabled;
    /// Whether the instance enabled `VK_EXT_debug_utils`, so the layer's
    /// messages can be received by a messenger rather than the console.
    bool debugUtils;
    /// The bits the queue's timestamps count in; 0 when it has none (`PRF10`).
    uint timestampValidBits;
    /// Whether the device enabled `VK_KHR_calibrated_timestamps` or the EXT
    /// and samples both its own clock and $(LREF monoTimeDomain) with it, so
    /// GPU timestamps can be placed on the CPU's timeline (`PRF11`).
    bool calibratedTimestamps;
    private VkDebugUtilsMessengerEXT messenger_;

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
        const wantDebugUtils = (request.validation || request.debugLabels)
            && advertised.hasExtension(extDebugUtils);
        if (wantDebugUtils)
            names[nameCount++] = extDebugUtils.ptr;
        const portability = instancePortability(d.global, names[0 .. nameCount]);
        if (portability.addExtension)
            names[nameCount++] = khrPortabilityEnumeration.ptr;
        auto made = d.createInstanceWith(request, names[0 .. nameCount], portability,
            presents: false);
        if (made.hasError)
            return made;
        d.debugUtils = wantDebugUtils && d.instance.has!extDebugUtils;
        if (request.messenger !is null && d.debugUtils)
        {
            const r = d.instance.createDebugUtilsMessengerEXT(d.instance.instance,
                cast(VkDebugUtilsMessengerCreateInfoEXT*) request.messenger, null, &d.messenger_);
            if (r < 0)
                return d.fail(VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createDevice,
                    r, "vkCreateDebugUtilsMessengerEXT failed");
        }
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
        import std.conv : to;
        import std.file : remove, rename, write;
        import std.process : thisProcessID;

        if (pipelineCache is null || path.length == 0)
            return vulkanWsiOk();
        // `VK_INCOMPLETE` means the cache grew between the two calls: asked
        // again, never written in part.
        ubyte[] bytes;
        size_t size;
        VkResult result;
        foreach (attempt; 0 .. 4)
        {
            result = device.getPipelineCacheData(device.device, pipelineCache, &size, null);
            if (result != VkResult.VK_SUCCESS || size == 0)
                return vulkanWsiOk();
            bytes = new ubyte[size];
            result = device.getPipelineCacheData(device.device, pipelineCache, &size, bytes.ptr);
            if (result != VkResult.VK_INCOMPLETE)
                break;
        }
        if (result != VkResult.VK_SUCCESS)
            return fail(VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createDevice,
                result, "vkGetPipelineCacheData failed");
        // A temporary file of this process's own: two instances saving at
        // once must not write into one another's.
        string temporary;
        try
        {
            temporary = path ~ ".tmp." ~ thisProcessID.to!string;
            write(temporary, bytes[0 .. size]);
            rename(temporary, path);
        }
        catch (Exception)
        {
            try
                if (temporary.length)
                    remove(temporary);
            catch (Exception)
            {
            }
            return fail(VulkanWsiErrorKind.vulkanFailure, VulkanWsiOperation.createDevice,
                VkResult.VK_SUCCESS, "the pipeline cache could not be written");
        }
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
        timestampValidBits = 0;
        calibratedTimestamps = false;
        presentWait = false;
        displayTiming = false;
        memoryBudget = false;
        dynamicRendering = false;
        imagelessFramebuffer = false;
        apiVersion = 0;
    }

    package void releaseInstance() @trusted nothrow
    {
        if (messenger_ !is null)
            instance.destroyDebugUtilsMessengerEXT(instance.instance, messenger_, null);
        messenger_ = null;
        if (instance.instance !is null && instance.destroyInstance !is null)
            instance.destroyInstance(instance.instance, null);
        instance = InstanceCommands.init;
        global = GlobalCommands.init;
        debugUtils = false;
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
            // `VK_EXT_metal_surface` has no presentation query: every queue
            // of a Metal-backed device presents to a `CAMetalLayer`.
            (in AppKitDisplayHandle _) {
                version (OSX)
                    return true;
                else
                    return false;
            },
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

        const(char)*[4] names;
        uint nameCount;
        names[nameCount++] = khrSurface.ptr;
        names[nameCount++] = platform.ptr;
        const wantDebugUtils = (request.validation || request.debugLabels)
            && advertised.hasExtension(extDebugUtils);
        if (wantDebugUtils)
            names[nameCount++] = extDebugUtils.ptr;
        const portability = instancePortability(global, names[0 .. nameCount]);
        if (portability.addExtension)
            names[nameCount++] = khrPortabilityEnumeration.ptr;
        auto made = createInstanceWith(request, names[0 .. nameCount], portability);
        if (!made.hasError)
            debugUtils = wantDebugUtils && instance.has!extDebugUtils;
        return made;
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
        timestampValidBits = best.timestampValidBits;
        apiVersion = request.apiVersion < properties.apiVersion ? request.apiVersion
            : properties.apiVersion;

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
        const plan = planDynamicRendering(request.apiVersion, properties.apiVersion,
            advertised.hasExtension(khrDynamicRendering),
            advertised.hasExtension(khrDepthStencilResolve)
                && advertised.hasExtension(khrCreateRenderpass2));
        const wantDynamicExtension = plan.enableExtension;
        const wantDynamicFeature = plan.chainFeature;
        // The effective version, not the request: a 1.3 request on a 1.1
        // device must not chain features the device does not know.
        const atLeast13 = plan.core;

        // Imageless framebuffers, where the device has them, for a canvas
        // that renders through a render pass instead (`sparkles:ui-vulkan`
        // `UVX10`). The query needs Vulkan 1.1, which every plan that
        // queries implies.
        const imageless = planImageless(request.apiVersion, properties.apiVersion,
            advertised.hasExtension(khrImagelessFramebuffer),
            advertised.hasExtension(khrImageFormatList));
        auto imagelessFeature = vkInfo(VkPhysicalDeviceImagelessFramebufferFeatures());
        if (imageless.query && instance.has!vkVersion11)
        {
            auto features = vkInfo(VkPhysicalDeviceFeatures2(pNext: &imagelessFeature));
            instance.getPhysicalDeviceFeatures2(physicalDevice, &features);
            imagelessFeature.pNext = null;
        }
        const wantImageless = imagelessFeature.imagelessFramebuffer == VK_TRUE;

        // Calibrated timestamps, where the device has them and samples the
        // clock `MonoTime` reads (`PRF11`): the KHR, else the EXT. Both need
        // Vulkan 1.1 (or `VK_KHR_get_physical_device_properties2`).
        const calibration = apiVersion < apiVersion11 ? CalibrationPlan.none
            : planCalibration(advertised.hasExtension(khrCalibratedTimestamps),
                advertised.hasExtension(extCalibratedTimestamps),
                calibrateableDomains(physicalDevice,
                    advertised.hasExtension(khrCalibratedTimestamps),
                    advertised.hasExtension(extCalibratedTimestamps)));

        // Present ids and waits, for when a frame reached the display.
        auto presentIdFeature = vkInfo(VkPhysicalDevicePresentIdFeaturesKHR());
        auto presentWaitFeature = vkInfo(VkPhysicalDevicePresentWaitFeaturesKHR(
            pNext: &presentIdFeature));
        if (presents && advertised.hasExtension(khrPresentId)
            && advertised.hasExtension(khrPresentWait) && apiVersion >= apiVersion11
            && instance.has!vkVersion11)
        {
            auto features = vkInfo(VkPhysicalDeviceFeatures2(pNext: &presentWaitFeature));
            instance.getPhysicalDeviceFeatures2(physicalDevice, &features);
        }
        const wantPresentWait = presentIdFeature.presentId == VK_TRUE
            && presentWaitFeature.presentWait == VK_TRUE;

        // Each heap's budget, where the device reports it through the 1.1
        // memory query (`PRF15`).
        const wantBudget = advertised.hasExtension(extMemoryBudget) && apiVersion >= apiVersion11
            && instance.has!vkVersion11;

        const wantDisplayTiming = presents && advertised.hasExtension(googleDisplayTiming);

        const(char)*[12] deviceExtensions;
        uint extensionCount;
        if (presents)
            deviceExtensions[extensionCount++] = khrSwapchain.ptr;
        if (wantPortability)
            deviceExtensions[extensionCount++] = khrPortabilitySubset.ptr;
        if (wantDynamicExtension)
        {
            if (plan.enableDependencies)
            {
                deviceExtensions[extensionCount++] = khrCreateRenderpass2.ptr;
                deviceExtensions[extensionCount++] = khrDepthStencilResolve.ptr;
            }
            deviceExtensions[extensionCount++] = khrDynamicRendering.ptr;
        }
        if (wantImageless && imageless.enableExtensions)
        {
            deviceExtensions[extensionCount++] = khrImageFormatList.ptr;
            deviceExtensions[extensionCount++] = khrImagelessFramebuffer.ptr;
        }
        if (calibration == CalibrationPlan.khr)
            deviceExtensions[extensionCount++] = khrCalibratedTimestamps.ptr;
        else if (calibration == CalibrationPlan.ext)
            deviceExtensions[extensionCount++] = extCalibratedTimestamps.ptr;
        if (wantPresentWait)
        {
            deviceExtensions[extensionCount++] = khrPresentId.ptr;
            deviceExtensions[extensionCount++] = khrPresentWait.ptr;
        }
        if (wantBudget)
            deviceExtensions[extensionCount++] = extMemoryBudget.ptr;
        if (wantDisplayTiming)
            deviceExtensions[extensionCount++] = googleDisplayTiming.ptr;

        auto dynamicFeature = vkInfo(VkPhysicalDeviceDynamicRenderingFeatures(
            dynamicRendering: VK_TRUE,
        ));
        // At 1.3, what the `vulkan1.3` shader profile assumes besides dynamic
        // rendering: ending and demoting a fragment invocation (`discard`,
        // `demote`). Vulkan 1.3 requires every device to support all three.
        auto features13 = vkInfo(VkPhysicalDeviceVulkan13Features(
            shaderTerminateInvocation: VK_TRUE,
            shaderDemoteToHelperInvocation: VK_TRUE,
            dynamicRendering: VK_TRUE,
        ));
        const(void)* chain = atLeast13 ? cast(const(void)*) &features13
            : wantDynamicExtension ? cast(const(void)*) &dynamicFeature : null;
        if (wantImageless)
        {
            imagelessFeature.pNext = cast(void*) chain;
            chain = &imagelessFeature;
        }
        if (wantPresentWait)
        {
            presentIdFeature.pNext = cast(void*) chain;
            chain = &presentWaitFeature;
        }
        auto info = vkInfo(VkDeviceCreateInfo(
            pNext: chain,
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
        imagelessFramebuffer = wantImageless;
        calibratedTimestamps = calibration == CalibrationPlan.khr
                ? device.has!khrCalibratedTimestamps
            : calibration == CalibrationPlan.ext && device.has!extCalibratedTimestamps;
        presentWait = wantPresentWait && device.has!khrPresentWait;
        memoryBudget = wantBudget;
        displayTiming = wantDisplayTiming && device.has!googleDisplayTiming;
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
            applicationVersion: request.applicationVersion,
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

    // Which of the two domains a calibration needs `physical` can sample:
    // bit 0 its own clock, bit 1 $(LREF monoTimeDomain).
    uint calibrateableDomains(VkPhysicalDevice physical, bool khr, bool ext) @trusted nothrow
    {
        static if (!hasMonoTimeDomain)
            return 0;
        else
        {
            // Only the command of an extension the device has: the loader's
            // trampoline for one it lacks is not callable.
            auto query = khr ? instance.getPhysicalDeviceCalibrateableTimeDomainsKHR
                : ext ? instance.getPhysicalDeviceCalibrateableTimeDomainsEXT : null;
            if (query is null)
                return 0;
            VkTimeDomainKHR[8] domains;
            uint count = domains.length;
            const r = query(physical, &count, domains.ptr);
            if (r < 0)
                return 0;
            // `VK_INCOMPLETE` leaves the count at what the driver has.
            if (count > domains.length)
                count = domains.length;
            uint found;
            foreach (domain; domains[0 .. count])
                found |= domain == VkTimeDomainKHR.VK_TIME_DOMAIN_DEVICE_KHR ? 1
                    : domain == monoTimeDomain ? 2 : 0;
            return found;
        }
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
                found ~= Candidate(physical, cast(uint) index, candidateProperties,
                    family.timestampValidBits);
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

/// How a device gets dynamic rendering, if it does.
package struct DynamicRenderingPlan
{
    bool enableExtension;    /// enable `VK_KHR_dynamic_rendering`
    bool enableDependencies; /// and, below 1.2, the two extensions it needs
    bool chainFeature;       /// chain the dynamic-rendering feature at creation
    bool core;               /// the device is Vulkan 1.3: chain the 1.3 features
}

/**
Dynamic rendering for a device created at `requested` on hardware that
reports `supported`, as Vulkan versions; `advertised` says whether the device
lists `VK_KHR_dynamic_rendering`, and `dependencies` whether it lists the
`VK_KHR_depth_stencil_resolve` and `VK_KHR_create_renderpass2` that need
enabling beside it below 1.2.

The effective version is the lower of the two: a 1.3 request on a 1.1 device
gets a 1.1 device. At 1.3 dynamic rendering is core. Below it, a device that
advertises the extension, and below 1.2 its dependencies, gets it enabled,
whatever was requested, from 1.1 on, where the feature query it needs is core.
*/
package DynamicRenderingPlan planDynamicRendering(uint requested, uint supported,
    bool advertised, bool dependencies) @safe pure nothrow @nogc
{
    const effective = requested < supported ? requested : supported;
    const major = apiVersionMajor(effective);
    const minor = apiVersionMinor(effective);
    const core = major > 1 || (major == 1 && minor >= 3);
    const atLeast12 = major > 1 || (major == 1 && minor >= 2);
    const atLeast11 = major > 1 || (major == 1 && minor >= 1);
    const extension = !core && atLeast11 && advertised && (atLeast12 || dependencies);
    return DynamicRenderingPlan(enableExtension: extension,
        enableDependencies: extension && !atLeast12, chainFeature: core || extension, core: core);
}

@("vulkan_wsi.device.dynamicRenderingFollowsTheEffectiveVersion")
@safe pure nothrow @nogc unittest
{
    enum v10 = apiVersion10, v11 = apiVersion11, v12 = apiVersion12, v13 = apiVersion13;
    alias Plan = DynamicRenderingPlan;
    // Core at 1.3 on both sides.
    assert(planDynamicRendering(v13, v13, true, true) == Plan(false, false, true, true));
    assert(planDynamicRendering(v13, v13, false, false) == Plan(false, false, true, true));
    // A 1.3 request on a 1.1 device that advertises the extension and what it
    // needs: all three enabled.
    assert(planDynamicRendering(v13, v11, true, true) == Plan(true, true, true, false));
    // ... without its dependencies, or without it, as the reference phone: a
    // render pass.
    assert(planDynamicRendering(v13, v11, true, false) == Plan(false, false, false, false));
    assert(planDynamicRendering(v13, v11, false, true) == Plan(false, false, false, false));
    // At 1.2 the dependencies are core.
    assert(planDynamicRendering(v12, v13, true, false) == Plan(true, false, true, false));
    assert(planDynamicRendering(v11, v13, false, true) == Plan(false, false, false, false));
    // Vulkan 1.0 cannot query the feature.
    assert(planDynamicRendering(v13, v10, true, true) == Plan(false, false, false, false));
}

/// How a device gets imageless framebuffers, if it can.
package struct ImagelessPlan
{
    bool query;            /// ask the device whether it has the feature
    bool enableExtensions; /// enable `VK_KHR_imageless_framebuffer` and `VK_KHR_image_format_list`
}

/**
Imageless framebuffers, which let a render pass draw into every swapchain image
of one size through one framebuffer (`sparkles:ui-vulkan` `UVX10`), for a
device created at `requested` on hardware that reports `supported`.
`imageless` and `formatList` say whether the device lists
`VK_KHR_imageless_framebuffer` and the `VK_KHR_image_format_list` it needs
beside it below 1.2.

Core at 1.2, where only the feature query decides; at 1.1, both extensions
must be listed, and the query decides too.
*/
package ImagelessPlan planImageless(uint requested, uint supported, bool imageless,
    bool formatList) @safe pure nothrow @nogc
{
    const effective = requested < supported ? requested : supported;
    const major = apiVersionMajor(effective);
    const minor = apiVersionMinor(effective);
    const core = major > 1 || (major == 1 && minor >= 2);
    const atLeast11 = major > 1 || (major == 1 && minor >= 1);
    const extension = !core && atLeast11 && imageless && formatList;
    return ImagelessPlan(query: core || extension, enableExtensions: extension);
}

@("vulkan_wsi.device.imagelessFollowsTheEffectiveVersion")
@safe pure nothrow @nogc unittest
{
    enum v10 = apiVersion10, v11 = apiVersion11, v12 = apiVersion12, v13 = apiVersion13;
    assert(planImageless(v13, v13, false, false) == ImagelessPlan(true, false), "core");
    assert(planImageless(v12, v13, false, false) == ImagelessPlan(true, false));
    // The reference phone: 1.1 with both extensions.
    assert(planImageless(v13, v11, true, true) == ImagelessPlan(true, true));
    assert(planImageless(v13, v11, true, false) == ImagelessPlan(false, false),
        "without the format list it needs");
    assert(planImageless(v11, v13, false, true) == ImagelessPlan(false, false),
        "a 1.1 request on a 1.3 device that lists neither");
    assert(planImageless(v13, v10, true, true) == ImagelessPlan(false, false));
}

/// Which calibrated-timestamps extension a device gets, if either.
package enum CalibrationPlan : ubyte
{
    none, ///
    khr,  /// `VK_KHR_calibrated_timestamps`
    ext,  /// `VK_EXT_calibrated_timestamps`, on a driver without the KHR
}

/**
Calibrated timestamps for a device advertising the KHR (`khr`) or the EXT
(`ext`) and sampling `domains` (bit 0 its own clock, bit 1
$(LREF monoTimeDomain)): the KHR where it is listed, else the EXT, and neither
unless both clocks can be sampled — a calibration against another clock would
put GPU times on a timeline the CPU's frames are not on.
*/
package CalibrationPlan planCalibration(bool khr, bool ext, uint domains)
    @safe pure nothrow @nogc
    => domains != 3 ? CalibrationPlan.none
        : khr ? CalibrationPlan.khr
        : ext ? CalibrationPlan.ext : CalibrationPlan.none;

@("vulkan_wsi.device.calibrationNeedsBothClocks")
@safe pure nothrow @nogc unittest
{
    with (CalibrationPlan)
    {
        assert(planCalibration(true, true, 3) == khr);
        assert(planCalibration(false, true, 3) == ext);
        assert(planCalibration(true, true, 1) == none, "the device clock alone");
        assert(planCalibration(true, false, 2) == none);
        assert(planCalibration(false, false, 3) == none);
    }
}
