#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkaninfo"
    dependency "sparkles:vulkan" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "expected" version="~>0.4.1"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
 * Super concise Vulkan system information reporter.
 *
 * Demonstrates functional range pipelines, compile-time introspection over
 * Vulkan structs/enums, sparkles:wired serialization & UDAs, core-cli argument
 * parsing, and structured pretty-printing.
 */
module vulkaninfo_example;

import std.algorithm : canFind, endsWith, filter, map, startsWith;
import std.array : appender, array;
import std.conv : to;
import std.format : format;
import std.range : enumerate, iota;
import std.stdio : writeln;
import std.string : fromStringz, strip;
import std.traits : EnumMembers, FieldNameTuple;

import expected : Expected, err, ok;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.base.text : writeBytes;
import sparkles.core_cli.args;
import sparkles.vulkan;
import sparkles.wired;
import sparkles.wired.json.writer : JsonWriteOptions;

int main(string[] args) => runCli!VulkanInfo(args);

@(Command("vulkaninfo",
    shortDescription: "Summarize Vulkan instance, layers, extensions, and GPU capabilities",
))
struct VulkanInfo
{
    @(Option(`s|summary`, description: "Show only high-level summary"))
    bool summary;

    @(Option(`j|json`, description: "Output in JSON format (via sparkles:wired)"))
    bool json;

    @(Option(`g|gpu`, description: "Target specific GPU index (-1 for all)"))
    int gpu = -1;

    @(Option("extensions", description: "Show extensions"))
    bool extensions;

    @(Option("layers", description: "Show instance layers"))
    bool layers;

    @(Option("features", description: "Show physical device features"))
    bool features;

    @(Option("memory", description: "Show memory heaps and types"))
    bool memory;

    @(Option("queues", description: "Show queue families"))
    bool queues;

    @(Option("no-color", description: "Disable colored output"))
    bool noColor;

    Expected!(void, string) run()
    {
        auto report = queryVulkan(this);
        if (report.hasError)
            return err!void(report.error);

        if (json)
        {
            auto buf = appender!string;
            enum opts = JsonWriteOptions(pretty: true);
            writeJSON!opts(report.value, buf);
            writeln(buf[]);
        }
        else
        {
            auto opt = PrettyPrintOptions!void(
                colored: !noColor,
                softMaxWidth: 100,
                maxItems: 256,
            );
            writeln(prettyPrint(report.value, opt));
        }

        return ok();
    }
}

// -----------------------------------------------------------------------------
// Declarative Data Models & Wired Enum UDAs
// -----------------------------------------------------------------------------

@WireCase(CaseStyle.kebabCase)
enum DeviceType
{
    @WireName("other") other = VK_PHYSICAL_DEVICE_TYPE_OTHER,
    @WireName("integrated-gpu") integratedGpu = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU,
    @WireName("discrete-gpu") discreteGpu = VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU,
    @WireName("virtual-gpu") virtualGpu = VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU,
    @WireName("cpu") cpu = VK_PHYSICAL_DEVICE_TYPE_CPU,
}

@WireCase(CaseStyle.kebabCase)
enum VendorId : uint
{
    @WireName("AMD") amd = 0x1002,
    @WireName("NVIDIA") nvidia = 0x10DE,
    @WireName("Intel") intel = 0x8086,
    @WireName("ARM") arm = 0x13B5,
    @WireName("Qualcomm") qualcomm = 0x5143,
    @WireName("Mesa/llvmpipe") mesaLlvmpipe = 0x10005,
}

struct VulkanReport
{
    InstanceSummary instance;
    LayerReport[] layers;
    GpuReport[] gpus;
}

struct InstanceSummary
{
    uint headerVersion;
    string loaderVersion;
    string[] extensions;
}

struct LayerReport
{
    string name;
    string description;
    string specVersion;
    uint implementationVersion;
}

struct GpuReport
{
    uint id;
    string name;
    DeviceType type;
    string apiVersion;
    string driverVersion;
    VendorId vendorID;
    string deviceID;
    QueueFamilyReport[] queueFamilies;
    MemoryReport memory;
    string[] extensions;
    string[] supportedFeatures;
}

/// Generic bitmask flags wrapper with `@WireConvert` value transform at the wire boundary.
@WireConvert!(f => f.toNames)
struct Flags(Enum, string prefix = "")
{
    uint raw;

    string[] toNames() const pure @safe
    {
        string[] result;
        static foreach (member; __traits(allMembers, Enum))
        {
            {
                enum val = cast(uint) __traits(getMember, Enum, member);
                static if (val != 0 && val != uint.max && !member.startsWith("VK_FLAG_VENDOR") && member.endsWith("_BIT"))
                {
                    if ((raw & val) == val)
                        result ~= stripAffixes(member, prefix, "_BIT");
                }
            }
        }
        return result;
    }

    alias toNames this;
}

alias QueueFlags = Flags!(VkQueueFlagBits, "VK_QUEUE_");
alias MemoryHeapFlags = Flags!(VkMemoryHeapFlagBits, "VK_MEMORY_HEAP_");
alias MemoryPropertyFlags = Flags!(VkMemoryPropertyFlagBits, "VK_MEMORY_PROPERTY_");

struct QueueFamilyReport
{
    uint index;
    uint queueCount;
    QueueFlags flags;
    uint timestampValidBits;
}

struct MemoryReport
{
    MemoryHeapReport[] heaps;
    MemoryTypeReport[] types;
}

struct MemoryHeapReport
{
    uint index;
    string size;
    MemoryHeapFlags flags;
}

struct MemoryTypeReport
{
    uint index;
    uint heapIndex;
    MemoryPropertyFlags propertyFlags;
}

// -----------------------------------------------------------------------------
// Functional Query & Metaprogramming Helpers
// -----------------------------------------------------------------------------

/// Strip both prefix and suffix from a string.
string stripAffixes(string s, string prefix, string suffix = "") pure @safe
{
    if (prefix.length && s.startsWith(prefix))
        s = s[prefix.length .. $];
    if (suffix.length && s.endsWith(suffix))
        s = s[0 .. $ - suffix.length];
    return s;
}

/// Extract all enabled features from VkPhysicalDeviceFeatures via compile-time reflection.
string[] extractFeatures(in VkPhysicalDeviceFeatures feat) pure @safe
{
    string[] result;
    static foreach (name; FieldNameTuple!VkPhysicalDeviceFeatures)
    {
        if (__traits(getMember, feat, name))
            result ~= name;
    }
    return result;
}

/// Format bytes into human-readable memory size using sparkles:base writeBytes.
string formatBytes(ulong bytes) pure @safe
{
    auto app = appender!string;
    writeBytes(app, bytes);
    return app.data;
}

/// Format Vulkan packed version (e.g. 1.3.204).
string formatApiVersion(uint v) pure @safe
    => format("%d.%d.%d", apiVersionMajor(v), apiVersionMinor(v), apiVersionPatch(v));

// -----------------------------------------------------------------------------
// Engine / Query Core
// -----------------------------------------------------------------------------

GpuReport queryGpu(in InstanceCommands inst, size_t index, VkPhysicalDevice gpuDev, in VulkanInfo cli) @system
{
    const showAll = !cli.summary && !cli.features && !cli.memory && !cli.queues && !cli.extensions;

    VkPhysicalDeviceProperties props;
    inst.getPhysicalDeviceProperties(gpuDev, &props);

    GpuReport gpu = {
        id: cast(uint) index,
        name: props.deviceName.ptr.fromStringz.to!string,
        type: cast(DeviceType) props.deviceType,
        apiVersion: formatApiVersion(props.apiVersion),
        driverVersion: formatApiVersion(props.driverVersion),
        vendorID: cast(VendorId) props.vendorID,
        deviceID: format("0x%04x", props.deviceID),
    };

    if (showAll || cli.queues)
    {
        gpu.queueFamilies = queryVkList!VkQueueFamilyProperties(inst.getPhysicalDeviceQueueFamilyProperties, gpuDev)
            .enumerate
            .map!(qf => QueueFamilyReport(
                index: cast(uint) qf.index,
                queueCount: qf.value.queueCount,
                flags: QueueFlags(qf.value.queueFlags),
                timestampValidBits: qf.value.timestampValidBits,
            ))
            .array;
    }

    if (showAll || cli.memory)
    {
        VkPhysicalDeviceMemoryProperties mem;
        inst.getPhysicalDeviceMemoryProperties(gpuDev, &mem);

        gpu.memory = MemoryReport(
            heaps: iota(mem.memoryHeapCount).map!(h => MemoryHeapReport(
                index: cast(uint) h,
                size: formatBytes(mem.memoryHeaps[h].size),
                flags: MemoryHeapFlags(mem.memoryHeaps[h].flags),
            )).array,
            types: iota(mem.memoryTypeCount).map!(t => MemoryTypeReport(
                index: cast(uint) t,
                heapIndex: mem.memoryTypes[t].heapIndex,
                propertyFlags: MemoryPropertyFlags(mem.memoryTypes[t].propertyFlags),
            )).array,
        );
    }

    if (showAll || cli.extensions)
    {
        gpu.extensions = queryVkList!VkExtensionProperties(inst.enumerateDeviceExtensionProperties, gpuDev, null)
            .map!(e => format("%s (v%d)", e.extensionName.ptr.fromStringz, e.specVersion))
            .array;
    }

    if (showAll || cli.features)
    {
        VkPhysicalDeviceFeatures feat;
        inst.getPhysicalDeviceFeatures(gpuDev, &feat);
        gpu.supportedFeatures = extractFeatures(feat);
    }

    return gpu;
}

version (Windows)
{
    import core.sys.windows.winbase : LoadLibraryA, GetProcAddress;
}
else version (Posix)
{
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;
}

Expected!(VulkanReport, string) queryVulkan(in VulkanInfo cli) @system
{
    version (Windows)
    {
        auto lib = LoadLibraryA("vulkan-1.dll");
        if (lib is null)
            return err!VulkanReport("Unable to load vulkan-1.dll");

        auto getProc = cast(PFN_vkGetInstanceProcAddr) GetProcAddress(lib, "vkGetInstanceProcAddr");
        if (getProc is null)
            return err!VulkanReport("Loader exports no vkGetInstanceProcAddr");
    }
    else
    {
        auto lib = dlopen("libvulkan.so.1", RTLD_NOW);
        if (lib is null)
            return err!VulkanReport("Unable to load libvulkan.so.1");

        auto getProc = cast(PFN_vkGetInstanceProcAddr) dlsym(lib, "vkGetInstanceProcAddr");
        if (getProc is null)
            return err!VulkanReport("Loader exports no vkGetInstanceProcAddr");
    }

    const global = GlobalCommands.load(getProc);
    if (!global.complete)
        return err!VulkanReport("Global commands incomplete");

    uint rawLoaderVersion;
    global.enumerateInstanceVersion(&rawLoaderVersion);

    auto instExtProps = queryVkList!VkExtensionProperties(global.enumerateInstanceExtensionProperties, null);
    auto instLayerProps = queryVkList!VkLayerProperties(global.enumerateInstanceLayerProperties);

    auto appInfo = vkInfo(VkApplicationInfo(
        pApplicationName: "sparkles-vulkaninfo",
        applicationVersion: makeApiVersion(0, 1, 0, 0),
        apiVersion: rawLoaderVersion ? rawLoaderVersion : apiVersion11,
    ));
    auto createInfo = vkInfo(VkInstanceCreateInfo(pApplicationInfo: &appInfo));

    VkInstance instance;
    const createRes = global.createInstance(&createInfo, null, &instance).check;
    if (createRes.hasError)
        return err!VulkanReport(format("vkCreateInstance failed (%s)", resultName(createRes.error)));

    const inst = InstanceCommands.load(global, instance);
    scope (exit)
        if (inst.destroyInstance !is null)
            inst.destroyInstance(instance, null);

    auto physicalDevices = queryVkList!VkPhysicalDevice(inst.enumeratePhysicalDevices, instance);

    VulkanReport report;
    report.instance = InstanceSummary(
        headerVersion: headerVersion,
        loaderVersion: formatApiVersion(rawLoaderVersion),
        extensions: (cli.summary && !cli.extensions)
            ? [format("%d extensions available (run with --extensions to list)", instExtProps.length)]
            : instExtProps.map!(e => format("%s (v%d)", e.extensionName.ptr.fromStringz, e.specVersion)).array,
    );

    if (cli.layers || (!cli.summary && !cli.features && !cli.memory && !cli.queues && !cli.extensions))
    {
        report.layers = instLayerProps.map!(l => LayerReport(
            name: l.layerName.ptr.fromStringz.to!string,
            description: l.description.ptr.fromStringz.to!string,
            specVersion: formatApiVersion(l.specVersion),
            implementationVersion: l.implementationVersion,
        )).array;
    }

    report.gpus = physicalDevices.enumerate
        .filter!(dev => cli.gpu < 0 || cli.gpu == cast(int) dev.index)
        .map!(dev => queryGpu(inst, dev.index, dev.value, cli))
        .array;

    return ok(report);
}
