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

import std.algorithm : filter, map;
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
enum VendorId : uint
{
    @WireName("AMD") amd = 0x1002,
    @WireName("NVIDIA") nvidia = 0x10DE,
    @WireName("Intel") intel = 0x8086,
    @WireName("ARM") arm = 0x13B5,
    @WireName("Qualcomm") qualcomm = 0x5143,
    @WireName("Apple") apple = 0x106B,
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
    string type;
    string apiVersion;
    string driverVersion;
    VendorId vendorID;
    string deviceID;
    QueueFamilyReport[] queueFamilies;
    MemoryReport memory;
    string[] extensions;
    string[] supportedFeatures;
}

struct QueueFamilyReport
{
    uint index;
    uint queueCount;
    string[] flags;
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
    string[] flags;
}

struct MemoryTypeReport
{
    uint index;
    uint heapIndex;
    string[] propertyFlags;
}

// -----------------------------------------------------------------------------
// Functional Query & Metaprogramming Helpers
// -----------------------------------------------------------------------------

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
        name: props.deviceName.fromStringz.to!string,
        type: deviceTypeName(props.deviceType),
        apiVersion: formatApiVersion(props.apiVersion),
        // Only `apiVersion` is guaranteed to use this packing — NVIDIA and
        // Intel encode a driver version differently, so this is approximate.
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
                flags: flagNames!VkQueueFlagBits(qf.value.queueFlags),
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
                flags: flagNames!VkMemoryHeapFlagBits(mem.memoryHeaps[h].flags),
            )).array,
            types: iota(mem.memoryTypeCount).map!(t => MemoryTypeReport(
                index: cast(uint) t,
                heapIndex: mem.memoryTypes[t].heapIndex,
                propertyFlags: flagNames!VkMemoryPropertyFlagBits(mem.memoryTypes[t].propertyFlags),
            )).array,
        );
    }

    if (showAll || cli.extensions)
    {
        gpu.extensions = queryVkList!VkExtensionProperties(inst.enumerateDeviceExtensionProperties, gpuDev, null)
            .map!(e => format("%s (v%d)", e.extensionName.fromStringz, e.specVersion))
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

Expected!(VulkanReport, string) queryVulkan(in VulkanInfo cli) @system
{
    auto loaded = loadGetInstanceProcAddr();
    if (loaded.hasError)
        return err!VulkanReport(loaded.error);

    const global = GlobalCommands.load(loaded.value);
    if (!global.complete)
        return err!VulkanReport("Global commands incomplete: missing " ~ global.firstMissing);

    uint rawLoaderVersion;
    global.enumerateInstanceVersion(&rawLoaderVersion);

    auto instExtProps = queryVkList!VkExtensionProperties(global.enumerateInstanceExtensionProperties, null);
    auto instLayerProps = queryVkList!VkLayerProperties(global.enumerateInstanceLayerProperties);

    auto appInfo = vkInfo(VkApplicationInfo(
        pApplicationName: "sparkles-vulkaninfo",
        applicationVersion: makeApiVersion(0, 1, 0, 0),
        apiVersion: rawLoaderVersion ? rawLoaderVersion : apiVersion11,
    ));

    // MoltenVK is a portability ICD, and this is the whole handshake — on a
    // regular desktop loader the answer is "nothing to enable", which matters
    // because asking for an unadvertised extension fails instance creation.
    const portability = instancePortability(instExtProps, null);
    const(char)*[1] portabilityExts = [khrPortabilityEnumeration.ptr];

    auto createInfo = vkInfo(VkInstanceCreateInfo(
        flags: portability.flags,
        pApplicationInfo: &appInfo,
        enabledExtensionCount: portability.addExtension ? 1 : 0,
        ppEnabledExtensionNames: portabilityExts.ptr,
    ));

    VkInstance instance;
    const createRes = global.createInstance(&createInfo, null, &instance).check;
    if (createRes.hasError)
        return err!VulkanReport("vkCreateInstance: " ~ describeResult(createRes.error));

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
            : instExtProps.map!(e => format("%s (v%d)", e.extensionName.fromStringz, e.specVersion)).array,
    );

    if (cli.layers || (!cli.summary && !cli.features && !cli.memory && !cli.queues && !cli.extensions))
    {
        report.layers = instLayerProps.map!(l => LayerReport(
            name: l.layerName.fromStringz.to!string,
            description: l.description.fromStringz.to!string,
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
