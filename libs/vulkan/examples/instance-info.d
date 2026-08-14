#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_instance_info"
    dependency "sparkles:vulkan" path="../../.."
    targetPath "build"

    // The build this repo ships nix artifacts with: optimised, assertions
    // live, `debug {}` blocks out. Neither `debug` (which turns those blocks
    // on) nor `release` (which deletes every assert expression).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Brings Vulkan up from nothing and reports what it found: loader version,
 * instance extensions, and every physical device with its driver and queue
 * families.
 *
 * The point is the path, not the report. It exercises all three dispatch
 * tiers against a real driver — the global tier from a bare
 * `vkGetInstanceProcAddr`, the instance tier from a live `VkInstance`, and a
 * physical-device query through it — which is the part the unit tests cannot
 * cover, since they only ever see null function pointers.
 *
 * `vkGetInstanceProcAddr` is fetched here with `dlopen`, standing in for what
 * `SDL_Vulkan_GetVkGetInstanceProcAddr` will supply once `sparkles:ui-sdl3`
 * exists. Nothing else about the sequence changes.
 *
 * Prints `SKIP:` and exits 0 where there is no loader or no driver, per the
 * repo's convention for environment-dependent examples: a headless CI runner
 * without an ICD is a degraded environment, not a failure.
 */
module vulkan_instance_info_example;

import core.stdc.stdio : printf;
import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

import sparkles.vulkan;

int main() @system
{
    // The loader is dlopen'd rather than linked: `c.c` defines
    // VK_NO_PROTOTYPES, so there is no link-time dependency to satisfy, and
    // this mirrors how SDL3 will hand us the same pointer at runtime.
    auto lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (lib is null)
        return skip("no libvulkan.so.1 (no Vulkan loader installed)");

    auto getProc = cast(PFN_vkGetInstanceProcAddr) dlsym(lib, "vkGetInstanceProcAddr");
    if (getProc is null)
        return skip("loader exports no vkGetInstanceProcAddr");

    // ---- tier 1: global ---------------------------------------------------
    const global = GlobalCommands.load(getProc);
    if (!global.complete)
    {
        printf("SKIP: global tier incomplete, missing %.*s\n",
            cast(int) global.firstMissing.length, global.firstMissing.ptr);
        return 0;
    }

    uint loaderVersion;
    if (global.enumerateInstanceVersion(&loaderVersion).check.hasError)
        return skip("vkEnumerateInstanceVersion failed");

    printf("headers   : VK_HEADER_VERSION %u\n", headerVersion);
    printf("loader    : %u.%u.%u\n", apiVersionMajor(loaderVersion),
        apiVersionMinor(loaderVersion), apiVersionPatch(loaderVersion));

    uint extensionCount;
    cast(void) global.enumerateInstanceExtensionProperties(null, &extensionCount, null);
    printf("extensions: %u instance extensions available\n", extensionCount);

    // ---- create an instance ----------------------------------------------
    // `vkInfo` supplies both sTypes; neither is written out here, and getting
    // one wrong would be a compile error rather than a validation warning.
    auto appInfo = vkInfo(VkApplicationInfo(
        pApplicationName: "sparkles-vulkan-instance-info",
        applicationVersion: makeApiVersion(0, 0, 1, 0),
        pEngineName: "sparkles",
        engineVersion: makeApiVersion(0, 0, 1, 0),
        apiVersion: apiVersion11,
    ));
    auto createInfo = vkInfo(VkInstanceCreateInfo(pApplicationInfo: &appInfo));

    VkInstance instance;
    const created = global.createInstance(&createInfo, null, &instance).checked;
    if (created.hasError)
    {
        printf("SKIP: vkCreateInstance: %s\n", resultName(created.error).ptr);
        return 0;
    }

    // ---- tier 2: instance -------------------------------------------------
    const inst = InstanceCommands.load(global, instance);
    scope (exit)
        if (inst.destroyInstance !is null)
            inst.destroyInstance(instance, null);

    if (!inst.complete)
    {
        printf("SKIP: instance tier incomplete, missing %.*s\n",
            cast(int) inst.firstMissing.length, inst.firstMissing.ptr);
        return 0;
    }

    // This instance enabled no extensions, so the surface commands are
    // expected to be absent — the table reports that rather than calling
    // itself broken.
    printf("surface   : %s (VK_KHR_surface not enabled by this example)\n",
        inst.has!khrSurface ? "present".ptr : "absent".ptr);

    uint deviceCount;
    if (inst.enumeratePhysicalDevices(instance, &deviceCount, null).check.hasError)
        return skip("vkEnumeratePhysicalDevices failed");
    if (deviceCount == 0)
        return skip("no Vulkan physical devices (no ICD)");

    VkPhysicalDevice[8] devices;
    if (deviceCount > devices.length)
        deviceCount = devices.length;
    cast(void) inst.enumeratePhysicalDevices(instance, &deviceCount, devices.ptr);

    printf("devices   : %u\n", deviceCount);
    foreach (i; 0 .. deviceCount)
    {
        VkPhysicalDeviceProperties props;
        inst.getPhysicalDeviceProperties(devices[i], &props);

        uint families;
        inst.getPhysicalDeviceQueueFamilyProperties(devices[i], &families, null);

        printf("  [%u] %s\n", i, props.deviceName.ptr);
        printf("       type=%s api=%u.%u.%u queueFamilies=%u\n",
            deviceTypeName(props.deviceType).ptr,
            apiVersionMajor(props.apiVersion), apiVersionMinor(props.apiVersion),
            apiVersionPatch(props.apiVersion), families);
    }

    printf("OK\n");
    return 0;
}

int skip(string reason) @system
{
    printf("SKIP: %.*s\n", cast(int) reason.length, reason.ptr);
    return 0;
}

string deviceTypeName(VkPhysicalDeviceType t) @safe pure nothrow @nogc
{
    with (VkPhysicalDeviceType) switch (t)
    {
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated-gpu\0";
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "discrete-gpu\0";
        case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return "virtual-gpu\0";
        case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "cpu\0";
        default:                                     return "other\0";
    }
}
