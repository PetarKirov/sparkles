/** Vulkan instance, native surface, present device, and queue ownership. */
module sparkles.vulkan_wsi.context;

import std.algorithm : maxElement;
import std.string : fromStringz;

import sparkles.base.text.cstring : CString, tryToCString;
import sparkles.vulkan;
import sparkles.vulkan_wsi.error;
import sparkles.vulkan_wsi.surface;
import sparkles.wsi : BackendKind, NativeHandles;

@safe:

struct ContextRequest
{
    string applicationName = "sparkles";
    uint apiVersion = apiVersion11;
    bool validation;
}

private struct Candidate
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

/**
The Vulkan objects whose selection depends on a native surface.

The window/display remain owned by `sparkles:wsi`. This object owns the Vulkan
surface and destroys it before the instance, so WSI must outlive the context.
On Wayland, creation and every surface/swapchain query must run between
`WaylandWsi.beginNativeIo` and `WaylandWsi.endNativeIo`: Vulkan drivers may
perform a private round trip on the shared display.
*/
struct VulkanContext
{
    GlobalCommands global;
    InstanceCommands instance;
    DeviceCommands device;

    BackendKind backend;
    VkPhysicalDevice physicalDevice;
    VkSurfaceKHR surface;
    uint queueFamily = uint.max;
    VkQueue queue;
    VkPhysicalDeviceProperties properties;
    bool dynamicRendering;

    @disable this(this);

    ~this() @trusted nothrow
    {
        destroy();
    }

    static VulkanWsiResult!void create(out VulkanContext context,
        in NativeHandles handles,
        in ContextRequest request = ContextRequest.init) @trusted nothrow
    {
        auto planned = planNativeSurface(handles);
        if (planned.hasError)
            return vulkanWsiErr!void(planned.error);
        context.backend = planned.value.backend;

        auto loaded = loadGetInstanceProcAddr();
        if (loaded.hasError)
            return context.fail(VulkanWsiErrorKind.loaderUnavailable,
                VulkanWsiOperation.load, VkResult.VK_SUCCESS,
                "Vulkan loader is unavailable");

        context.global = GlobalCommands.load(loaded.value);
        if (!context.global.complete)
            return context.fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.load, VkResult.VK_SUCCESS,
                "Vulkan global commands are incomplete");

        auto advertised = queryVkList!VkExtensionProperties(
            context.global.enumerateInstanceExtensionProperties, null);
        if (!advertised.hasExtension(khrSurface)
            || !advertised.hasExtension(planned.value.platformExtension))
            return context.fail(VulkanWsiErrorKind.missingExtension,
                VulkanWsiOperation.createInstance, VkResult.VK_ERROR_EXTENSION_NOT_PRESENT,
                "required native surface extension is unavailable");

        const(char)*[3] names;
        uint nameCount;
        names[nameCount++] = khrSurface.ptr;
        names[nameCount++] = planned.value.platformExtension.ptr;

        const portability = instancePortability(context.global, names[0 .. nameCount]);
        if (portability.addExtension)
            names[nameCount++] = khrPortabilityEnumeration.ptr;

        auto madeInstance = context.createInstance(
            request, names[0 .. nameCount], portability);
        if (madeInstance.hasError)
        {
            context.destroy();
            return madeInstance;
        }

        auto madeSurface = createNativeSurface(context.instance, handles);
        if (madeSurface.hasError)
        {
            context.destroy();
            return vulkanWsiErr!void(madeSurface.error);
        }
        context.surface = madeSurface.value;

        auto madeDevice = context.selectAndCreateDevice(request);
        if (madeDevice.hasError)
        {
            context.destroy();
            return madeDevice;
        }
        return vulkanWsiOk();
    }

    string deviceName() const nothrow
        => properties.deviceName.fromStringz.idup;

    void destroy() @trusted nothrow
    {
        if (device.device !is null && device.destroyDevice !is null)
        {
            if (device.deviceWaitIdle !is null)
                device.deviceWaitIdle(device.device);
            device.destroyDevice(device.device, null);
            device = DeviceCommands.init;
        }

        if (surface !is null && instance.instance !is null
            && instance.destroySurfaceKHR !is null)
        {
            instance.destroySurfaceKHR(instance.instance, surface, null);
            surface = null;
        }

        if (instance.instance !is null && instance.destroyInstance !is null)
        {
            instance.destroyInstance(instance.instance, null);
            instance = InstanceCommands.init;
        }

        global = GlobalCommands.init;
        physicalDevice = null;
        queueFamily = uint.max;
        queue = null;
        properties = VkPhysicalDeviceProperties.init;
        dynamicRendering = false;
    }

private:
    VulkanWsiResult!void createInstance(in ContextRequest request,
        scope const(char*)[] extensionNames,
        in InstancePortability portability) @trusted nothrow
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

        static immutable validationLayer = "VK_LAYER_KHRONOS_validation";
        const(char)* layerName = validationLayer.ptr;
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
            return createInstance(withoutValidation, extensionNames, portability);
        }
        if (result < 0)
            return fail(VulkanWsiErrorKind.vulkanFailure,
                VulkanWsiOperation.createInstance, result,
                "vkCreateInstance failed");

        instance = InstanceCommands.load(global, handle);
        if (!instance.complete || !instance.has!khrSurface)
            return fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.createInstance, VkResult.VK_SUCCESS,
                "Vulkan instance commands are incomplete");
        return vulkanWsiOk();
    }

    VulkanWsiResult!void selectAndCreateDevice(in ContextRequest request)
        @trusted nothrow
    {
        auto candidates = pickCandidates();
        if (candidates.length == 0)
            return fail(VulkanWsiErrorKind.noPresentDevice,
                VulkanWsiOperation.selectDevice, VkResult.VK_SUCCESS,
                "no graphics queue can present to the native surface");

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
        if (!advertised.hasExtension(khrSwapchain))
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
        if (!device.complete || !device.has!khrSwapchain)
            return fail(VulkanWsiErrorKind.incompleteDispatch,
                VulkanWsiOperation.createDevice, VkResult.VK_SUCCESS,
                "Vulkan device commands are incomplete");

        dynamicRendering = wantDynamicFeature
            && (device.has!vkVersion13 || device.has!khrDynamicRendering);
        device.getDeviceQueue(handle, queueFamily, 0, &queue);
        return vulkanWsiOk();
    }

    Candidate[] pickCandidates() @trusted nothrow
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
                if ((family.queueFlags
                        & VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT) == 0)
                    continue;

                VkBool32 presentable;
                if (instance.getPhysicalDeviceSurfaceSupportKHR(
                        physical, cast(uint) index, surface, &presentable) < 0
                    || !presentable)
                    continue;

                VkPhysicalDeviceProperties candidateProperties;
                instance.getPhysicalDeviceProperties(
                    physical, &candidateProperties);
                found ~= Candidate(physical, cast(uint) index,
                    candidateProperties);
                break;
            }
        }
        return found;
    }

    VulkanWsiResult!void fail(VulkanWsiErrorKind kind,
        VulkanWsiOperation operation, VkResult result,
        scope const(char)[] diagnostic) const pure nothrow @nogc
        => vulkanWsiErr!void(vulkanWsiError(
            kind, operation, backend, result, diagnostic));
}

@("vulkan_wsi.context.deviceScoringPrefersDiscrete")
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

@("vulkan_wsi.context.destroyIsIdempotentWithoutHandles")
@system nothrow unittest
{
    VulkanContext context;
    context.destroy();
    context.destroy();
    assert(context.surface is null);
    assert(context.queueFamily == uint.max);
}
