#!/usr/bin/env dub
/+ dub.sdl:
    name "media-hw-probe"
    platforms "linux" "osx"
    dependency "sparkles:vulkan" path="../../../../.."
    dependency "sparkles:core-cli" path="../../../../.."
    dependency "sparkles:base" path="../../../../.."
    dependency "sparkles:wired" path="../../../../.."
    dependency "expected" version="~>0.4.1"
    dependency "during" version="~>0.5.0" platform="linux"
    stringImportPaths "."
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
 * Read-only image and video capability probe for the `sparkles:{image,video}`
 * research catalog (`docs/research/images/hardware/`).
 *
 * One JSON report per machine: CPU SIMD features, `io_uring` opcodes, every
 * Vulkan device (features, limits, texture and YCbCr format support, Vulkan
 * Video decode and encode capabilities per codec profile, cooperative matrix
 * shapes, memory decompression) and the platform media API (VA-API on Linux,
 * VideoToolbox on macOS). `--adb SERIAL` reports an Android device instead,
 * from the host, through `getprop`, `cmd gpu vkjson` and the codec lists.
 *
 * Nothing is written to the device or the host except the report itself.
 * Host names, serial numbers, user names and device UUIDs are never read.
 * A probe that fails records why in `notes` and the rest still runs.
 */
module media_hw_probe;

import std.algorithm : among, canFind, filter, map, sort, startsWith, uniq;
import std.array : array, join, split;
import std.conv : to;
import std.file : dirEntries, exists, isFile, readText, SpanMode;
import std.json : JSONType, JSONValue, parseJSON;
import std.meta : AliasSeq;
import std.path : baseName, buildPath, dirName;
import std.process : execute;
import std.range : iota;
import std.range.primitives : put;
import std.regex : ctRegex, matchAll, matchFirst;
import std.stdio : File, stdout;
import std.string : fromStringz, indexOf, lineSplitter, strip;
import std.traits : EnumMembers, FieldNameTuple, Unqual;

import expected : Expected, err, ok;

import sparkles.base.build_stamp : buildStampOf;
import sparkles.base.hw_caps : hwMemoryBytes;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.enums : enumMemberNameOr;
import sparkles.core_cli.args;
import sparkles.vulkan;
import sparkles.wired;
import sparkles.wired.json.writer : JsonWriteOptions;

int main(string[] args) => runCli!MediaHwProbe(args);

@(Command("media-hw-probe",
    shortDescription: "Report image and video hardware capabilities as JSON",
))
struct MediaHwProbe
{
    @(Option(`o|out`, description: "Write the JSON report to this file instead of stdout"))
    string out_;

    @(Option(`adb`, description: "Probe the Android device with this adb serial instead of the host"))
    string adb;

    @(Option(`list-adb`, description: "List attached adb devices and exit"))
    bool listAdb;

    Expected!(void, string) run()
    {
        if (listAdb)
        {
            const r = execute(["adb", "devices", "-l"]);
            stdout.write(r.output);
            return r.status == 0 ? ok() : err!void("adb devices failed");
        }

        Report report;
        report.probe = ProbeInfo(
            schema: "sparkles.media-hw-probe/1",
            version_: stamp.version_,
            commit: stamp.commit,
        );
        if (adb.length)
            probeAndroid(report, adb);
        else
            probeHost(report);

        auto file = out_.length ? File(out_, "w") : stdout;
        auto w = file.lockingTextWriter;
        enum opts = JsonWriteOptions(pretty: true);
        const wrote = writeJSON!opts(report, w);
        if (wrote.hasError)
            return err!void("JSON encoding failed; the report on disk is incomplete");
        put(w, '\n');
        return ok();
    }
}

enum stamp = buildStampOf!();

// -----------------------------------------------------------------------------
// Report model
// -----------------------------------------------------------------------------

struct Report
{
    ProbeInfo probe;
    HostReport host;
    CpuReport cpu;
    IoReport io;
    VulkanReport vulkan;
    MediaApiReport media;
    AndroidReport android;
    string[] notes; /// probes that could not run, and why
}

struct ProbeInfo
{
    string schema;
    string version_;
    string commit;
}

struct HostReport
{
    string collectedVia; /// `native` or `adb`
    string os;
    string osVersion;
    string kernel;
    string arch;
    string model; /// a phone's or a Mac's model name; empty on a PC
    ulong memoryBytes;
}

struct CpuReport
{
    string model;
    uint logicalCpus;
    string[] coreTypes; /// distinct core descriptions (ARM `CPU part`, Apple perf levels)
    string[] simd;      /// the SIMD and crypto features relevant to image kernels
}

struct IoReport
{
    string backend;          /// `io_uring`, `none`, or `unknown`
    string status;           /// `available`, or why not
    string[] uringOpcodes;   /// every opcode the kernel's probe reports as supported
    string[] uringFeatures;  /// `IORING_FEAT_*` bits from `io_uring_setup`
}

struct VulkanReport
{
    string status;
    string loaderVersion;
    string[] instanceExtensions;
    GpuReport[] devices;
}

struct GpuReport
{
    string name;
    string type;
    string vendor;
    string deviceId;
    string apiVersion;
    string driverName;
    string driverInfo;
    string driverId;
    string conformanceVersion;
    string[] extensions;
    FeatureSet[] features;
    Limits limits;
    SubgroupReport subgroup;
    MemoryHeap[] memoryHeaps;
    QueueFamily[] queueFamilies;
    FormatSupport[] formats;
    VideoProfileReport[] video;
    string[] cooperativeMatrix;
    DecompressionReport memoryDecompression;
    ulong minImportedHostPointerAlignment; /// `VK_EXT_external_memory_host`; 0 when absent
}

/// The `VkBool32` members of one feature struct that the driver reports as true.
struct FeatureSet
{
    string struct_;
    string[] enabled;
}

struct Limits
{
    uint maxImageDimension2D;
    uint maxImageDimension3D;
    uint maxImageArrayLayers;
    uint maxStorageBufferRange;
    uint maxPushConstantsSize;
    uint maxComputeSharedMemorySize;
    uint maxComputeWorkGroupInvocations;
    uint[3] maxComputeWorkGroupSize;
    uint[3] maxComputeWorkGroupCount;
    ulong minMemoryMapAlignment;
    ulong optimalBufferCopyOffsetAlignment;
    ulong optimalBufferCopyRowPitchAlignment;
    ulong nonCoherentAtomSize;
    ulong minStorageBufferOffsetAlignment;
    uint maxSamplerAnisotropy;
    float timestampPeriod = 0; /// NaN, the default, has no JSON spelling
}

struct SubgroupReport
{
    uint size;
    uint minSize; /// subgroup size control; 0 when unknown
    uint maxSize;
    string[] stages;
    string[] operations;
}

struct MemoryHeap
{
    ulong size;
    string[] flags;
    string[][] typeFlags; /// the property flags of each memory type in this heap
}

struct QueueFamily
{
    uint index;
    uint count;
    string[] flags;
    string[] videoCodecs;
}

struct FormatSupport
{
    string format;
    string[] optimal; /// optimal-tiling features
    string[] linear;
    string[] buffer;
}

struct VideoProfileReport
{
    string operation;   /// `decode-h264`, `encode-av1`, …
    string profile;     /// `high`, `main-10`, …
    string chroma;
    uint bitDepth;
    string status;      /// `supported`, or the `VkResult` that refused it
    string[] flags;
    uint[2] minCodedExtent;
    uint[2] maxCodedExtent;
    uint[2] pictureAccessGranularity;
    uint maxDpbSlots;
    uint maxActiveReferencePictures;
    string maxLevel;
    string[] codecFlags;      /// decode or encode capability flags
    string[] rateControlModes;
    uint maxQualityLevels;
    ulong maxBitrate;
    string[] outputFormats;   /// formats for the decode output / encode input
    string[] dpbFormats;
}

struct DecompressionReport
{
    string extension;
    string[] methods;
    ulong maxIndirectCount;
}

struct MediaApiReport
{
    string api;          /// `VA-API`, `VideoToolbox`, `MediaCodec`
    MediaDevice[] devices;
    MediaCodec[] codecs; /// VideoToolbox and MediaCodec list codecs, not devices
    string nvidia;       /// `nvidia-smi` summary when present
}

struct MediaDevice
{
    string node;
    string kernelDriver;
    string pciId;
    string driver;
    string[] profiles; /// `VAProfileH264High: VLD, EncSliceLP`
}

struct MediaCodec
{
    string name;
    string mime;
    string direction;   /// `decode` / `encode`
    string kind;        /// `hardware` / `software` / `unknown`
    string maxSize;
    string[] features;
    string source;
}

struct AndroidReport
{
    string soc;
    string board;
    string sdk;
    string vulkanHardware;
    string mediaCodecVariant;
}

// -----------------------------------------------------------------------------
// Host
// -----------------------------------------------------------------------------

void probeHost(ref Report r)
{
    r.host.collectedVia = "native";
    r.host.memoryBytes = hwMemoryBytes();
    r.host.arch = hostArch;
    r.cpu.logicalCpus = logicalCpus();
    r.host.kernel = unameField!"release";

    version (linux)
    {
        r.host.os = "linux";
        r.host.osVersion = osReleaseName();
        probeLinuxCpu(r.cpu);
        probeUring(r);
        probeVaapi(r);
        probeNvidiaSmi(r);
    }
    else version (OSX)
    {
        r.host.os = "macos";
        r.host.osVersion = run(["sw_vers", "-productVersion"]).strip;
        r.host.model = run(["sysctl", "-n", "hw.model"]).strip;
        probeMacCpu(r.cpu);
        r.io = IoReport(backend: "none", status: "macOS has no io_uring; kqueue only");
        probeVideoToolbox(r);
    }

    probeVulkan(r);
}

string hostArch() pure nothrow @safe
{
    version (X86_64) return "x86_64";
    else version (AArch64) return "aarch64";
    else return "other";
}

uint logicalCpus() nothrow @safe
{
    import std.parallelism : totalCPUs;
    return totalCPUs;
}

string unameField(string field)() @trusted
{
    import core.sys.posix.sys.utsname : uname, utsname;

    utsname u;
    if (uname(&u) != 0)
        return null;
    return mixin("u." ~ field).ptr.fromStringz.idup;
}

/// `PRETTY_NAME` from `/etc/os-release`, or empty.
string osReleaseName()
{
    foreach (path; ["/etc/os-release", "/usr/lib/os-release"])
        if (path.exists)
            foreach (line; readText(path).lineSplitter)
                if (line.startsWith("PRETTY_NAME="))
                    return line["PRETTY_NAME=".length .. $].strip(`"`);
    return null;
}

/// Run a command and return its stdout, or `null` when it is missing or fails.
string run(string[] cmd) nothrow
{
    try
    {
        const res = execute(cmd);
        return res.status == 0 ? res.output : null;
    }
    catch (Exception)
        return null;
}

// The x86 features an image kernel can dispatch on; `/proc/cpuinfo` lists only
// those the kernel has enabled the register state for.
immutable string[] x86SimdFlags = [
    "sse2", "ssse3", "sse4_1", "sse4_2", "avx", "avx2", "fma", "f16c", "bmi2",
    "avx512f", "avx512dq", "avx512cd", "avx512bw", "avx512vl", "avx512ifma",
    "avx512vbmi", "avx512vbmi2", "avx512_vnni", "avx512_bitalg",
    "avx512_vpopcntdq", "avx512_bf16", "avx512_fp16", "avx_vnni", "avx_vnni_int8",
    "avx_ifma", "avx10", "gfni", "vaes", "vpclmulqdq", "sha_ni", "amx_tile",
    "amx_int8", "amx_bf16", "amx_fp16",
];

void probeLinuxCpu(ref CpuReport cpu)
{
    if (!"/proc/cpuinfo".exists)
        return;
    parseCpuinfo(readText("/proc/cpuinfo"), cpu);
}

void parseCpuinfo(string text, ref CpuReport cpu)
{
    string[] parts;
    foreach (line; text.lineSplitter)
    {
        const colon = line.indexOf(':');
        if (colon < 0)
            continue;
        const key = line[0 .. colon].strip;
        const value = line[colon + 1 .. $].strip;
        if (key.among("model name", "Hardware") && cpu.model.length == 0)
            cpu.model = value.idup;
        else if (key == "flags" && cpu.simd.length == 0)
            cpu.simd = value.split.filter!(f => x86SimdFlags.canFind(f)).map!(f => f.idup).array;
        else if (key == "Features" && cpu.simd.length == 0)
            cpu.simd = value.split.map!(f => f.idup).array; // ARM: already a short list
        else if (key == "CPU part")
            parts ~= value.idup;
    }
    cpu.coreTypes = parts.sort.uniq.map!(p => "CPU part " ~ p).array;
}

version (linux) void probeUring(ref Report r)
{
    import during : Operation, SetupFeatures, Uring, setup;

    r.io.backend = "io_uring";
    Uring io;
    const ret = io.setup(8);
    if (ret < 0)
    {
        r.io.status = "io_uring_setup failed: errno " ~ (-ret).to!string;
        return;
    }
    r.io.status = "available";

    const features = io.params().features;
    static foreach (f; __traits(allMembers, SetupFeatures))
        static if (is(typeof(__traits(getMember, SetupFeatures, f)) == SetupFeatures))
            if (features & __traits(getMember, SetupFeatures, f))
                r.io.uringFeatures ~= f;

    auto probe = io.probe();
    if (!cast(bool) probe)
    {
        r.notes ~= "io_uring opcode probe failed: errno " ~ (-probe.error).to!string;
        return;
    }
    foreach (op; [EnumMembers!Operation].sort.uniq)
        if (probe.isSupported(op))
            r.io.uringOpcodes ~= op.to!string;
}

// -----------------------------------------------------------------------------
// Linux: VA-API and NVIDIA
// -----------------------------------------------------------------------------

version (linux) void probeVaapi(ref Report r)
{
    r.media.api = "VA-API";
    if (!"/dev/dri".exists)
    {
        r.notes ~= "no /dev/dri: VA-API not probed";
        return;
    }
    auto nodes = dirEntries("/dev/dri", "renderD*", SpanMode.shallow).map!(e => e.name).array.sort.array;
    foreach (node; nodes)
    {
        MediaDevice d;
        d.node = node;
        const sys = buildPath("/sys/class/drm", node.baseName, "device");
        d.kernelDriver = linkName(buildPath(sys, "driver"));
        d.pciId = (readSmall(buildPath(sys, "vendor")) ~ ":" ~ readSmall(buildPath(sys, "device")));

        string output;
        try
        {
            const res = execute(["vainfo", "--display", "drm", "--device", node]);
            output = res.output;
            if (res.status != 0)
                r.notes ~= "vainfo " ~ node ~ ": exit " ~ res.status.to!string;
        }
        catch (Exception e)
        {
            r.notes ~= "vainfo not found: VA-API not probed";
            return;
        }
        parseVainfo(output, d);
        r.media.devices ~= d;
    }
}

/// `vainfo` lines: `Driver version: …` and `VAProfileX : VAEntrypointY`.
void parseVainfo(string output, ref MediaDevice d)
{
    string[][string] byProfile;
    string[] order;
    foreach (line; output.lineSplitter)
    {
        if (auto m = line.matchFirst(ctRegex!`Driver version:\s*(.*)$`))
            d.driver = m[1].strip.idup;
        else if (auto m = line.matchFirst(ctRegex!`^\s*(VAProfile\w+)\s*:\s*VAEntrypoint(\w+)`))
        {
            const p = m[1].idup;
            if (p !in byProfile)
                order ~= p;
            byProfile[p] ~= m[2].idup;
        }
    }
    d.profiles = order.map!(p => p ~ ": " ~ byProfile[p].join(", ")).array;
}

string linkName(string path)
{
    import std.file : readLink;

    try
        return readLink(path).baseName;
    catch (Exception)
        return null;
}

string readSmall(string path)
{
    try
        return readText(path).strip;
    catch (Exception)
        return null;
}

version (linux) void probeNvidiaSmi(ref Report r)
{
    const s = run(["nvidia-smi", "--query-gpu=name,driver_version,memory.total",
        "--format=csv,noheader"]);
    if (s.length)
        r.media.nvidia = s.strip;
}

// -----------------------------------------------------------------------------
// macOS: CPU and VideoToolbox
// -----------------------------------------------------------------------------

version (OSX) void probeMacCpu(ref CpuReport cpu)
{
    cpu.model = run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip;
    foreach (level; 0 .. 4)
    {
        const prefix = "hw.perflevel" ~ level.to!string ~ ".";
        const name = run(["sysctl", "-n", prefix ~ "name"]).strip;
        if (!name.length)
            break;
        cpu.coreTypes ~= name ~ " x" ~ run(["sysctl", "-n", prefix ~ "logicalcpu"]).strip;
    }
    // `hw.optional.arm.FEAT_X: 1` lines; keep the set ones.
    foreach (line; run(["sysctl", "hw.optional"]).lineSplitter)
        if (auto m = line.matchFirst(ctRegex!`^hw\.optional\.(?:arm\.)?(\w+):\s*1$`))
            cpu.simd ~= m[1].idup;
}

version (OSX) void probeVideoToolbox(ref Report r)
{
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

    r.media.api = "VideoToolbox";
    auto vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW);
    if (vt is null)
    {
        r.notes ~= "VideoToolbox could not be loaded";
        return;
    }
    alias IsSupported = extern (C) ubyte function(uint) nothrow @nogc;
    auto isHw = cast(IsSupported) dlsym(vt, "VTIsHardwareDecodeSupported");
    if (isHw is null)
    {
        r.notes ~= "VTIsHardwareDecodeSupported missing";
        return;
    }
    static immutable string[2][] codecs = [
        ["avc1", "video/avc"], ["hvc1", "video/hevc"], ["av01", "video/av01"],
        ["vp09", "video/x-vnd.on2.vp9"], ["apcn", "video/prores-422"],
        ["ap4h", "video/prores-4444"], ["jpeg", "image/jpeg"], ["mp4v", "video/mp4v-es"],
    ];
    foreach (c; codecs)
    {
        const fourcc = (uint(c[0][0]) << 24) | (uint(c[0][1]) << 16) | (uint(c[0][2]) << 8) | c[0][3];
        r.media.codecs ~= MediaCodec(
            name: c[0],
            mime: c[1],
            direction: "decode",
            kind: isHw(fourcc) ? "hardware" : "software",
            source: "VTIsHardwareDecodeSupported",
        );
    }
}

// -----------------------------------------------------------------------------
// Vulkan
// -----------------------------------------------------------------------------

/// Textures, YCbCr planes and HDR formats an image library meets.
immutable VkFormat[] probedFormats = [
    VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM, VK_FORMAT_R8G8B8A8_UNORM,
    VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB,
    VK_FORMAT_R16_UNORM, VK_FORMAT_R16G16_UNORM, VK_FORMAT_R16G16B16A16_UNORM,
    VK_FORMAT_R16G16B16A16_SFLOAT, VK_FORMAT_R32G32B32A32_SFLOAT,
    VK_FORMAT_A2B10G10R10_UNORM_PACK32, VK_FORMAT_B10G11R11_UFLOAT_PACK32,
    VK_FORMAT_E5B9G9R9_UFLOAT_PACK32,
    VK_FORMAT_BC1_RGBA_UNORM_BLOCK, VK_FORMAT_BC3_UNORM_BLOCK, VK_FORMAT_BC4_UNORM_BLOCK,
    VK_FORMAT_BC5_UNORM_BLOCK, VK_FORMAT_BC6H_UFLOAT_BLOCK, VK_FORMAT_BC7_UNORM_BLOCK,
    VK_FORMAT_BC7_SRGB_BLOCK,
    VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, VK_FORMAT_EAC_R11G11_UNORM_BLOCK,
    VK_FORMAT_ASTC_4x4_UNORM_BLOCK, VK_FORMAT_ASTC_4x4_SRGB_BLOCK,
    VK_FORMAT_ASTC_4x4_SFLOAT_BLOCK, VK_FORMAT_ASTC_8x8_UNORM_BLOCK,
    VK_FORMAT_ASTC_12x12_UNORM_BLOCK,
    VK_FORMAT_G8B8G8R8_422_UNORM, VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
    VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM, VK_FORMAT_G8_B8R8_2PLANE_422_UNORM,
    VK_FORMAT_G8_B8R8_2PLANE_444_UNORM, VK_FORMAT_G8_B8_R8_3PLANE_444_UNORM,
    VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16,
    VK_FORMAT_G10X6_B10X6R10X6_2PLANE_444_UNORM_3PACK16,
    VK_FORMAT_G12X4_B12X4R12X4_2PLANE_420_UNORM_3PACK16,
    VK_FORMAT_G16_B16R16_2PLANE_420_UNORM,
];

/// A feature struct, and what must be present before it may be chained.
struct FeatureGate
{
    uint minApi;      /// a core version, or 0
    string extension; /// an extension name, or empty
    string orExtension;
}

alias FeatureStructs = AliasSeq!(
    VkPhysicalDeviceVulkan11Features,
    VkPhysicalDeviceVulkan12Features,
    VkPhysicalDeviceVulkan13Features,
    VkPhysicalDeviceVulkan14Features,
    VkPhysicalDeviceTextureCompressionASTCHDRFeatures,
    VkPhysicalDeviceTextureCompressionASTC3DFeaturesEXT,
    VkPhysicalDeviceYcbcr2Plane444FormatsFeaturesEXT,
    VkPhysicalDeviceRGBA10X6FormatsFeaturesEXT,
    VkPhysicalDeviceCooperativeMatrixFeaturesKHR,
    VkPhysicalDeviceShaderBfloat16FeaturesKHR,
    VkPhysicalDeviceShaderFloat8FeaturesEXT,
    VkPhysicalDeviceMemoryDecompressionFeaturesEXT,
    VkPhysicalDeviceVideoMaintenance1FeaturesKHR,
    VkPhysicalDeviceVideoMaintenance2FeaturesKHR,
    VkPhysicalDeviceVideoDecodeVP9FeaturesKHR,
    VkPhysicalDeviceVideoEncodeAV1FeaturesKHR,
    VkPhysicalDeviceVideoEncodeQuantizationMapFeaturesKHR,
    VkPhysicalDeviceVideoEncodeIntraRefreshFeaturesKHR,
);

immutable FeatureGate[] featureGates = [
    FeatureGate(apiVersion12),
    FeatureGate(apiVersion12),
    FeatureGate(apiVersion13),
    FeatureGate(apiVersion14),
    FeatureGate(0, "VK_EXT_texture_compression_astc_hdr"),
    FeatureGate(0, "VK_EXT_texture_compression_astc_3d"),
    FeatureGate(0, "VK_EXT_ycbcr_2plane_444_formats"),
    FeatureGate(0, "VK_EXT_rgba10x6_formats"),
    FeatureGate(0, "VK_KHR_cooperative_matrix"),
    FeatureGate(0, "VK_KHR_shader_bfloat16"),
    FeatureGate(0, "VK_EXT_shader_float8"),
    FeatureGate(0, "VK_EXT_memory_decompression", "VK_NV_memory_decompression"),
    FeatureGate(0, "VK_KHR_video_maintenance1"),
    FeatureGate(0, "VK_KHR_video_maintenance2"),
    FeatureGate(0, "VK_KHR_video_decode_vp9"),
    FeatureGate(0, "VK_KHR_video_encode_av1"),
    FeatureGate(0, "VK_KHR_video_encode_quantization_map"),
    FeatureGate(0, "VK_KHR_video_encode_intra_refresh"),
];

static assert(FeatureStructs.length == featureGates.length);

/// Instance-level entry points the shared dispatch table does not carry.
struct ExtraCommands
{
    PFN_vkGetPhysicalDeviceFeatures2 getFeatures2;
    PFN_vkGetPhysicalDeviceProperties2 getProperties2;
    PFN_vkGetPhysicalDeviceFormatProperties getFormatProperties;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties2 getQueueFamilies2;
    PFN_vkGetPhysicalDeviceVideoCapabilitiesKHR getVideoCaps;
    PFN_vkGetPhysicalDeviceVideoFormatPropertiesKHR getVideoFormats;
    PFN_vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR getCoopMatrix;

    static ExtraCommands load(in GlobalCommands g, VkInstance instance) @system
    {
        ExtraCommands c;
        static foreach (field, name; [
            "getFeatures2": "vkGetPhysicalDeviceFeatures2",
            "getProperties2": "vkGetPhysicalDeviceProperties2",
            "getFormatProperties": "vkGetPhysicalDeviceFormatProperties",
            "getQueueFamilies2": "vkGetPhysicalDeviceQueueFamilyProperties2",
            "getVideoCaps": "vkGetPhysicalDeviceVideoCapabilitiesKHR",
            "getVideoFormats": "vkGetPhysicalDeviceVideoFormatPropertiesKHR",
            "getCoopMatrix": "vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR",
        ])
            mixin("c." ~ field ~ " = cast(typeof(c." ~ field ~ ")) g.getInstanceProcAddr(instance, \""
                ~ name ~ "\");");
        return c;
    }
}

void probeVulkan(ref Report r) @system
{
    auto loaded = loadGetInstanceProcAddr();
    if (loaded.hasError)
    {
        r.vulkan.status = loaded.error;
        return;
    }
    const global = GlobalCommands.load(loaded.value);
    if (!global.complete)
    {
        r.vulkan.status = "global commands incomplete: " ~ global.firstMissing;
        return;
    }

    uint loaderVersion = apiVersion10;
    if (global.enumerateInstanceVersion !is null)
        global.enumerateInstanceVersion(&loaderVersion);
    r.vulkan.loaderVersion = versionText(loaderVersion);

    auto instExts = queryVkList!VkExtensionProperties(global.enumerateInstanceExtensionProperties, null);
    r.vulkan.instanceExtensions = instExts.map!(e => e.extensionName.ptr.fromStringz.idup).array.sort.array;

    auto appInfo = vkInfo(VkApplicationInfo(
        pApplicationName: "sparkles-media-hw-probe",
        apiVersion: loaderVersion >= apiVersion11 ? loaderVersion : apiVersion11,
    ));
    const portability = instancePortability(instExts, null);
    const(char)*[1] portabilityExts = [khrPortabilityEnumeration.ptr];
    auto createInfo = vkInfo(VkInstanceCreateInfo(
        flags: portability.flags,
        pApplicationInfo: &appInfo,
        enabledExtensionCount: portability.addExtension ? 1 : 0,
        ppEnabledExtensionNames: portabilityExts.ptr,
    ));

    VkInstance instance;
    const created = global.createInstance(&createInfo, null, &instance).check;
    if (created.hasError)
    {
        r.vulkan.status = "vkCreateInstance: " ~ describeResult(created.error);
        return;
    }
    const inst = InstanceCommands.load(global, instance);
    scope (exit)
        inst.destroyInstance(instance, null);
    const extra = ExtraCommands.load(global, instance);

    r.vulkan.status = "available";
    foreach (pd; queryVkList!VkPhysicalDevice(inst.enumeratePhysicalDevices, instance))
        r.vulkan.devices ~= probeGpu(inst, extra, pd, r.notes);
}

string versionText(uint packed) pure @safe
    => i"$(apiVersionMajor(packed)).$(apiVersionMinor(packed)).$(apiVersionPatch(packed))".text;

import std.conv : text;

GpuReport probeGpu(in InstanceCommands inst, in ExtraCommands extra, VkPhysicalDevice pd,
    ref string[] notes) @system
{
    VkPhysicalDeviceProperties props;
    inst.getPhysicalDeviceProperties(pd, &props);

    GpuReport g;
    g.name = props.deviceName.ptr.fromStringz.idup;
    g.type = deviceTypeName(props.deviceType);
    g.vendor = vendorName(props.vendorID);
    g.deviceId = i"0x$(props.deviceID.to!string(16))".text;
    g.apiVersion = versionText(props.apiVersion);

    auto exts = queryVkList!VkExtensionProperties(inst.enumerateDeviceExtensionProperties, pd, null);
    g.extensions = exts.map!(e => e.extensionName.ptr.fromStringz.idup).array.sort.array;
    bool has(string name) => g.extensions.canFind(name);

    with (props.limits)
        g.limits = Limits(
            maxImageDimension2D: maxImageDimension2D,
            maxImageDimension3D: maxImageDimension3D,
            maxImageArrayLayers: maxImageArrayLayers,
            maxStorageBufferRange: maxStorageBufferRange,
            maxPushConstantsSize: maxPushConstantsSize,
            maxComputeSharedMemorySize: maxComputeSharedMemorySize,
            maxComputeWorkGroupInvocations: maxComputeWorkGroupInvocations,
            maxComputeWorkGroupSize: maxComputeWorkGroupSize,
            maxComputeWorkGroupCount: maxComputeWorkGroupCount,
            minMemoryMapAlignment: minMemoryMapAlignment,
            optimalBufferCopyOffsetAlignment: optimalBufferCopyOffsetAlignment,
            optimalBufferCopyRowPitchAlignment: optimalBufferCopyRowPitchAlignment,
            nonCoherentAtomSize: nonCoherentAtomSize,
            minStorageBufferOffsetAlignment: minStorageBufferOffsetAlignment,
            maxSamplerAnisotropy: cast(uint) maxSamplerAnisotropy,
            timestampPeriod: timestampPeriod,
        );

    const api = props.apiVersion;
    if (extra.getFeatures2 !is null && extra.getProperties2 !is null && api >= apiVersion11)
    {
        probeFeatures(extra, pd, api, &has, g);
        probeProperties(extra, pd, api, &has, g);
    }
    else
        notes ~= g.name ~ ": Vulkan 1.0 device, no *2 queries";

    probeMemory(inst, pd, g);
    probeQueues(inst, extra, pd, has("VK_KHR_video_queue"), g);
    probeFormats(extra, pd, g);
    if (has("VK_KHR_video_queue") && extra.getVideoCaps !is null)
        probeVideo(extra, pd, &has, g);
    if (has("VK_KHR_cooperative_matrix") && extra.getCoopMatrix !is null)
        probeCoopMatrix(extra, pd, g);
    return g;
}

/// `VK_FORMAT_G8_B8R8_2PLANE_420_UNORM` → `G8_B8R8_2PLANE_420_UNORM`: the
/// header's grouping of planes and packing survives, which kebab-case loses.
string formatName(VkFormat f) pure nothrow @safe @nogc
    => enumMemberNameOr!(CaseStyle.original, "VK_FORMAT_")(f, "unknown");

string vendorName(uint id) pure @safe
{
    switch (id)
    {
        case 0x1002: return "AMD";
        case 0x10DE: return "NVIDIA";
        case 0x8086: return "Intel";
        case 0x13B5: return "ARM";
        case 0x5143: return "Qualcomm";
        case 0x106B: return "Apple";
        case 0x10005: return "Mesa";
        default: return i"0x$(id.to!string(16))".text;
    }
}

/// The names of the `VkBool32` members of `s` that are set.
string[] trueBools(T)(in T s)
{
    string[] r;
    static foreach (name; FieldNameTuple!T)
        static if (name != "sType" && is(Unqual!(typeof(__traits(getMember, s, name))) == VkBool32))
            if (__traits(getMember, s, name))
                r ~= name;
    return r;
}

void probeFeatures(in ExtraCommands extra, VkPhysicalDevice pd, uint api,
    scope bool delegate(string) has, ref GpuReport g) @system
{
    FeatureStructs structs;
    bool[FeatureStructs.length] chained;
    auto f2 = vkInfo(VkPhysicalDeviceFeatures2());
    void* head;
    static foreach (i, T; FeatureStructs)
    {{
        const gate = featureGates[i];
        const ok = (gate.minApi != 0 && api >= gate.minApi)
            || (gate.extension.length && has(gate.extension))
            || (gate.orExtension.length && has(gate.orExtension));
        if (ok)
        {
            structs[i] = vkInfo(T());
            structs[i].pNext = head;
            head = &structs[i];
            chained[i] = true;
        }
    }}
    f2.pNext = head;
    extra.getFeatures2(pd, &f2);

    g.features ~= FeatureSet("VkPhysicalDeviceFeatures", trueBools(f2.features));
    static foreach (i, T; FeatureStructs)
        if (chained[i])
            g.features ~= FeatureSet(T.stringof, trueBools(structs[i]));
}

void probeProperties(in ExtraCommands extra, VkPhysicalDevice pd, uint api,
    scope bool delegate(string) has, ref GpuReport g) @system
{
    auto p2 = vkInfo(VkPhysicalDeviceProperties2());
    auto subgroup = vkInfo(VkPhysicalDeviceSubgroupProperties());
    auto driver = vkInfo(VkPhysicalDeviceDriverProperties());
    auto sizeControl = vkInfo(VkPhysicalDeviceSubgroupSizeControlProperties());
    auto hostMem = vkInfo(VkPhysicalDeviceExternalMemoryHostPropertiesEXT());
    auto decompress = vkInfo(VkPhysicalDeviceMemoryDecompressionPropertiesEXT());

    void* head;
    void chain(S)(ref S s)
    {
        s.pNext = head;
        head = &s;
    }

    chain(subgroup);
    const hasDriver = api >= apiVersion12 || has("VK_KHR_driver_properties");
    if (hasDriver)
        chain(driver);
    const hasSizeControl = api >= apiVersion13 || has("VK_EXT_subgroup_size_control");
    if (hasSizeControl)
        chain(sizeControl);
    const hasHostMem = has("VK_EXT_external_memory_host");
    if (hasHostMem)
        chain(hostMem);
    const decompressExt = has("VK_EXT_memory_decompression") ? "VK_EXT_memory_decompression"
        : has("VK_NV_memory_decompression") ? "VK_NV_memory_decompression" : null;
    if (decompressExt.length)
        chain(decompress);
    p2.pNext = head;
    extra.getProperties2(pd, &p2);

    g.subgroup = SubgroupReport(
        size: subgroup.subgroupSize,
        minSize: hasSizeControl ? sizeControl.minSubgroupSize : 0,
        maxSize: hasSizeControl ? sizeControl.maxSubgroupSize : 0,
        stages: flagNames!VkShaderStageFlagBits(subgroup.supportedStages),
        operations: flagNames!VkSubgroupFeatureFlagBits(subgroup.supportedOperations),
    );
    if (hasDriver)
    {
        g.driverName = driver.driverName.ptr.fromStringz.idup;
        g.driverInfo = driver.driverInfo.ptr.fromStringz.idup;
        g.driverId = vkName(driver.driverID);
        with (driver.conformanceVersion)
            g.conformanceVersion = i"$(major).$(minor).$(subminor).$(patch)".text;
    }
    if (hasHostMem)
        g.minImportedHostPointerAlignment = hostMem.minImportedHostPointerAlignment;
    if (decompressExt.length)
        g.memoryDecompression = DecompressionReport(
            extension: decompressExt,
            methods: flagNames64!"VK_MEMORY_DECOMPRESSION_METHOD_"(decompress.decompressionMethods),
            maxIndirectCount: decompress.maxDecompressionIndirectCount,
        );
}

/// Names for a 64-bit flag type, whose bits ImportC exposes as module-level
/// constants rather than as an enum.
string[] flagNames64(string prefix)(ulong raw)
{
    string[] r;
    static foreach (m; __traits(allMembers, sparkles.vulkan.vulkan_c))
        static if (m.length > prefix.length && m[0 .. prefix.length] == prefix
            && is(typeof(__traits(getMember, sparkles.vulkan.vulkan_c, m)) : ulong))
            if (raw & __traits(getMember, sparkles.vulkan.vulkan_c, m))
                r ~= m[prefix.length .. $];
    return r;
}

void probeMemory(in InstanceCommands inst, VkPhysicalDevice pd, ref GpuReport g) @system
{
    VkPhysicalDeviceMemoryProperties mem;
    inst.getPhysicalDeviceMemoryProperties(pd, &mem);
    foreach (h; 0 .. mem.memoryHeapCount)
    {
        MemoryHeap heap = {
            size: mem.memoryHeaps[h].size,
            flags: flagNames!VkMemoryHeapFlagBits(mem.memoryHeaps[h].flags),
        };
        foreach (t; 0 .. mem.memoryTypeCount)
            if (mem.memoryTypes[t].heapIndex == h)
                heap.typeFlags ~= flagNames!VkMemoryPropertyFlagBits(mem.memoryTypes[t].propertyFlags);
        g.memoryHeaps ~= heap;
    }
}

void probeQueues(in InstanceCommands inst, in ExtraCommands extra, VkPhysicalDevice pd,
    bool videoQueue, ref GpuReport g) @system
{
    if (!videoQueue || extra.getQueueFamilies2 is null)
    {
        foreach (i, qf; queryVkList!VkQueueFamilyProperties(inst.getPhysicalDeviceQueueFamilyProperties, pd))
            g.queueFamilies ~= QueueFamily(cast(uint) i, qf.queueCount, flagNames!VkQueueFlagBits(qf.queueFlags));
        return;
    }
    uint count;
    extra.getQueueFamilies2(pd, &count, null);
    auto families = new VkQueueFamilyProperties2[count];
    auto video = new VkQueueFamilyVideoPropertiesKHR[count];
    foreach (i; 0 .. count)
    {
        video[i] = vkInfo(VkQueueFamilyVideoPropertiesKHR());
        families[i] = vkInfo(VkQueueFamilyProperties2());
        families[i].pNext = &video[i];
    }
    extra.getQueueFamilies2(pd, &count, families.ptr);
    foreach (i; 0 .. count)
        g.queueFamilies ~= QueueFamily(
            index: i,
            count: families[i].queueFamilyProperties.queueCount,
            flags: flagNames!VkQueueFlagBits(families[i].queueFamilyProperties.queueFlags),
            videoCodecs: flagNames!VkVideoCodecOperationFlagBitsKHR(video[i].videoCodecOperations),
        );
}

void probeFormats(in ExtraCommands extra, VkPhysicalDevice pd, ref GpuReport g) @system
{
    if (extra.getFormatProperties is null)
        return;
    foreach (f; probedFormats)
    {
        VkFormatProperties p;
        extra.getFormatProperties(pd, f, &p);
        g.formats ~= FormatSupport(
            format: formatName(f),
            optimal: flagNames!VkFormatFeatureFlagBits(p.optimalTilingFeatures),
            linear: flagNames!VkFormatFeatureFlagBits(p.linearTilingFeatures),
            buffer: flagNames!VkFormatFeatureFlagBits(p.bufferFeatures),
        );
    }
}

void probeCoopMatrix(in ExtraCommands extra, VkPhysicalDevice pd, ref GpuReport g) @system
{
    uint count;
    if (extra.getCoopMatrix(pd, &count, null) != VK_SUCCESS || count == 0)
        return;
    auto shapes = new VkCooperativeMatrixPropertiesKHR[count];
    foreach (ref s; shapes)
        s = vkInfo(VkCooperativeMatrixPropertiesKHR());
    if (extra.getCoopMatrix(pd, &count, shapes.ptr) != VK_SUCCESS)
        return;
    foreach (s; shapes[0 .. count])
    {
        // `scope` is a D keyword, so the C field is reached by name.
        const scopeName = vkName(__traits(getMember, s, "scope"));
        g.cooperativeMatrix ~= i"$(s.MSize)x$(s.NSize)x$(s.KSize) $(vkName(s.AType))*$(vkName(s.BType))+$(vkName(s.CType))->$(vkName(s.ResultType))$(s.saturatingAccumulation ? " sat" : "") $(scopeName)".text;
    }
}

// -----------------------------------------------------------------------------
// Vulkan Video
// -----------------------------------------------------------------------------

/// One codec profile to ask the driver about.
struct VideoQuery
{
    string extension;
    VkVideoCodecOperationFlagBitsKHR op;
    string operation;
    string profile;
    int stdProfile;
    uint bitDepth;
}

immutable VideoQuery[] videoQueries = [
    VideoQuery("VK_KHR_video_decode_h264", VK_VIDEO_CODEC_OPERATION_DECODE_H264_BIT_KHR, "decode-h264", "high", STD_VIDEO_H264_PROFILE_IDC_HIGH, 8),
    VideoQuery("VK_KHR_video_decode_h265", VK_VIDEO_CODEC_OPERATION_DECODE_H265_BIT_KHR, "decode-h265", "main", STD_VIDEO_H265_PROFILE_IDC_MAIN, 8),
    VideoQuery("VK_KHR_video_decode_h265", VK_VIDEO_CODEC_OPERATION_DECODE_H265_BIT_KHR, "decode-h265", "main-10", STD_VIDEO_H265_PROFILE_IDC_MAIN_10, 10),
    VideoQuery("VK_KHR_video_decode_av1", VK_VIDEO_CODEC_OPERATION_DECODE_AV1_BIT_KHR, "decode-av1", "main", STD_VIDEO_AV1_PROFILE_MAIN, 8),
    VideoQuery("VK_KHR_video_decode_av1", VK_VIDEO_CODEC_OPERATION_DECODE_AV1_BIT_KHR, "decode-av1", "main", STD_VIDEO_AV1_PROFILE_MAIN, 10),
    VideoQuery("VK_KHR_video_decode_vp9", VK_VIDEO_CODEC_OPERATION_DECODE_VP9_BIT_KHR, "decode-vp9", "profile-0", STD_VIDEO_VP9_PROFILE_0, 8),
    VideoQuery("VK_KHR_video_decode_vp9", VK_VIDEO_CODEC_OPERATION_DECODE_VP9_BIT_KHR, "decode-vp9", "profile-2", STD_VIDEO_VP9_PROFILE_2, 10),
    VideoQuery("VK_KHR_video_encode_h264", VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR, "encode-h264", "high", STD_VIDEO_H264_PROFILE_IDC_HIGH, 8),
    VideoQuery("VK_KHR_video_encode_h265", VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR, "encode-h265", "main", STD_VIDEO_H265_PROFILE_IDC_MAIN, 8),
    VideoQuery("VK_KHR_video_encode_h265", VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR, "encode-h265", "main-10", STD_VIDEO_H265_PROFILE_IDC_MAIN_10, 10),
    VideoQuery("VK_KHR_video_encode_av1", VK_VIDEO_CODEC_OPERATION_ENCODE_AV1_BIT_KHR, "encode-av1", "main", STD_VIDEO_AV1_PROFILE_MAIN, 8),
    VideoQuery("VK_KHR_video_encode_av1", VK_VIDEO_CODEC_OPERATION_ENCODE_AV1_BIT_KHR, "encode-av1", "main", STD_VIDEO_AV1_PROFILE_MAIN, 10),
];

void probeVideo(in ExtraCommands extra, VkPhysicalDevice pd,
    scope bool delegate(string) has, ref GpuReport g) @system
{
    foreach (q; videoQueries)
        if (has(q.extension))
            g.video ~= probeVideoProfile(extra, pd, q);
}

VideoProfileReport probeVideoProfile(in ExtraCommands extra, VkPhysicalDevice pd, in VideoQuery q) @system
{
    const decode = q.operation.startsWith("decode");
    VideoProfileReport rep = {
        operation: q.operation,
        profile: q.profile,
        chroma: "420",
        bitDepth: q.bitDepth,
    };

    // The codec-specific profile struct each operation chains.
    auto h264d = vkInfo(VkVideoDecodeH264ProfileInfoKHR(
        stdProfileIdc: cast(StdVideoH264ProfileIdc) q.stdProfile,
        pictureLayout: VK_VIDEO_DECODE_H264_PICTURE_LAYOUT_PROGRESSIVE_KHR));
    auto h265d = vkInfo(VkVideoDecodeH265ProfileInfoKHR(stdProfileIdc: cast(StdVideoH265ProfileIdc) q.stdProfile));
    auto av1d = vkInfo(VkVideoDecodeAV1ProfileInfoKHR(stdProfile: cast(StdVideoAV1Profile) q.stdProfile));
    auto vp9d = vkInfo(VkVideoDecodeVP9ProfileInfoKHR(stdProfile: cast(StdVideoVP9Profile) q.stdProfile));
    auto h264e = vkInfo(VkVideoEncodeH264ProfileInfoKHR(stdProfileIdc: cast(StdVideoH264ProfileIdc) q.stdProfile));
    auto h265e = vkInfo(VkVideoEncodeH265ProfileInfoKHR(stdProfileIdc: cast(StdVideoH265ProfileIdc) q.stdProfile));
    auto av1e = vkInfo(VkVideoEncodeAV1ProfileInfoKHR(stdProfile: cast(StdVideoAV1Profile) q.stdProfile));

    const depth = q.bitDepth == 10 ? VK_VIDEO_COMPONENT_BIT_DEPTH_10_BIT_KHR : VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR;
    auto profile = vkInfo(VkVideoProfileInfoKHR(
        videoCodecOperation: q.op,
        chromaSubsampling: VK_VIDEO_CHROMA_SUBSAMPLING_420_BIT_KHR,
        lumaBitDepth: depth,
        chromaBitDepth: depth,
    ));

    // Capabilities: generic → decode/encode → codec-specific.
    auto caps = vkInfo(VkVideoCapabilitiesKHR());
    auto decCaps = vkInfo(VkVideoDecodeCapabilitiesKHR());
    auto encCaps = vkInfo(VkVideoEncodeCapabilitiesKHR());
    auto h264dCaps = vkInfo(VkVideoDecodeH264CapabilitiesKHR());
    auto h265dCaps = vkInfo(VkVideoDecodeH265CapabilitiesKHR());
    auto av1dCaps = vkInfo(VkVideoDecodeAV1CapabilitiesKHR());
    auto vp9dCaps = vkInfo(VkVideoDecodeVP9CapabilitiesKHR());
    auto h264eCaps = vkInfo(VkVideoEncodeH264CapabilitiesKHR());
    auto h265eCaps = vkInfo(VkVideoEncodeH265CapabilitiesKHR());
    auto av1eCaps = vkInfo(VkVideoEncodeAV1CapabilitiesKHR());

    void* codecCaps;
    switch (q.op)
    {
        case VK_VIDEO_CODEC_OPERATION_DECODE_H264_BIT_KHR: profile.pNext = &h264d; codecCaps = &h264dCaps; break;
        case VK_VIDEO_CODEC_OPERATION_DECODE_H265_BIT_KHR: profile.pNext = &h265d; codecCaps = &h265dCaps; break;
        case VK_VIDEO_CODEC_OPERATION_DECODE_AV1_BIT_KHR: profile.pNext = &av1d; codecCaps = &av1dCaps; break;
        case VK_VIDEO_CODEC_OPERATION_DECODE_VP9_BIT_KHR: profile.pNext = &vp9d; codecCaps = &vp9dCaps; break;
        case VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR: profile.pNext = &h264e; codecCaps = &h264eCaps; break;
        case VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR: profile.pNext = &h265e; codecCaps = &h265eCaps; break;
        case VK_VIDEO_CODEC_OPERATION_ENCODE_AV1_BIT_KHR: profile.pNext = &av1e; codecCaps = &av1eCaps; break;
        default: assert(0, q.operation);
    }
    if (decode)
    {
        caps.pNext = &decCaps;
        decCaps.pNext = codecCaps;
    }
    else
    {
        caps.pNext = &encCaps;
        encCaps.pNext = codecCaps;
    }

    const res = extra.getVideoCaps(pd, &profile, &caps);
    if (res != VK_SUCCESS)
    {
        rep.status = describeResult(res);
        return rep;
    }
    rep.status = "supported";
    rep.flags = flagNames!VkVideoCapabilityFlagBitsKHR(caps.flags);
    rep.minCodedExtent = [caps.minCodedExtent.width, caps.minCodedExtent.height];
    rep.maxCodedExtent = [caps.maxCodedExtent.width, caps.maxCodedExtent.height];
    rep.pictureAccessGranularity = [caps.pictureAccessGranularity.width, caps.pictureAccessGranularity.height];
    rep.maxDpbSlots = caps.maxDpbSlots;
    rep.maxActiveReferencePictures = caps.maxActiveReferencePictures;

    switch (q.op)
    {
        case VK_VIDEO_CODEC_OPERATION_DECODE_H264_BIT_KHR: rep.maxLevel = vkName(h264dCaps.maxLevelIdc); break;
        case VK_VIDEO_CODEC_OPERATION_DECODE_H265_BIT_KHR: rep.maxLevel = vkName(h265dCaps.maxLevelIdc); break;
        case VK_VIDEO_CODEC_OPERATION_DECODE_AV1_BIT_KHR: rep.maxLevel = vkName(av1dCaps.maxLevel); break;
        case VK_VIDEO_CODEC_OPERATION_DECODE_VP9_BIT_KHR: rep.maxLevel = vkName(vp9dCaps.maxLevel); break;
        case VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR: rep.maxLevel = vkName(h264eCaps.maxLevelIdc); break;
        case VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR: rep.maxLevel = vkName(h265eCaps.maxLevelIdc); break;
        case VK_VIDEO_CODEC_OPERATION_ENCODE_AV1_BIT_KHR: rep.maxLevel = vkName(av1eCaps.maxLevel); break;
        default: break;
    }
    if (decode)
        rep.codecFlags = flagNames!VkVideoDecodeCapabilityFlagBitsKHR(decCaps.flags);
    else
    {
        rep.codecFlags = flagNames!VkVideoEncodeCapabilityFlagBitsKHR(encCaps.flags);
        rep.rateControlModes = flagNames!VkVideoEncodeRateControlModeFlagBitsKHR(encCaps.rateControlModes);
        rep.maxQualityLevels = encCaps.maxQualityLevels;
        rep.maxBitrate = encCaps.maxBitrate;
    }

    auto list = vkInfo(VkVideoProfileListInfoKHR(profileCount: 1, pProfiles: &profile));
    rep.outputFormats = videoFormats(extra, pd, &list,
        decode ? VK_IMAGE_USAGE_VIDEO_DECODE_DST_BIT_KHR : VK_IMAGE_USAGE_VIDEO_ENCODE_SRC_BIT_KHR);
    rep.dpbFormats = videoFormats(extra, pd, &list,
        decode ? VK_IMAGE_USAGE_VIDEO_DECODE_DPB_BIT_KHR : VK_IMAGE_USAGE_VIDEO_ENCODE_DPB_BIT_KHR);
    return rep;
}

/// The formats (with tiling) a video profile accepts for `usage`.
string[] videoFormats(in ExtraCommands extra, VkPhysicalDevice pd,
    VkVideoProfileListInfoKHR* list, uint usage) @system
{
    if (extra.getVideoFormats is null)
        return null;
    auto info = vkInfo(VkPhysicalDeviceVideoFormatInfoKHR(imageUsage: usage));
    info.pNext = list;
    uint count;
    if (extra.getVideoFormats(pd, &info, &count, null) != VK_SUCCESS || count == 0)
        return null;
    auto props = new VkVideoFormatPropertiesKHR[count];
    foreach (ref p; props)
        p = vkInfo(VkVideoFormatPropertiesKHR());
    if (extra.getVideoFormats(pd, &info, &count, props.ptr) != VK_SUCCESS)
        return null;
    return props[0 .. count]
        .map!(p => formatName(p.format) ~ " (" ~ vkName(p.imageTiling) ~ ")")
        .array.sort.uniq.array;
}

// -----------------------------------------------------------------------------
// Android, from the host
// -----------------------------------------------------------------------------

void probeAndroid(ref Report r, string serial)
{
    string sh(string cmd) => run(["adb", "-s", serial, "shell", cmd]);

    if (run(["adb", "-s", serial, "get-state"]).strip != "device")
    {
        r.notes ~= "adb device not reachable";
        return;
    }
    string prop(string name) => sh("getprop " ~ name).strip;

    r.host = HostReport(
        collectedVia: "adb",
        os: "android",
        osVersion: prop("ro.build.version.release"),
        kernel: sh("uname -r").strip,
        arch: prop("ro.product.cpu.abi"),
        model: prop("ro.product.manufacturer") ~ " " ~ prop("ro.product.model"),
    );
    r.android = AndroidReport(
        soc: prop("ro.soc.manufacturer") ~ " " ~ prop("ro.soc.model"),
        board: prop("ro.board.platform"),
        sdk: prop("ro.build.version.sdk"),
        vulkanHardware: prop("ro.hardware.vulkan"),
        mediaCodecVariant: prop("ro.media.xml_variant.codecs"),
    );
    if (auto m = sh("cat /proc/meminfo").matchFirst(ctRegex!`MemTotal:\s*(\d+) kB`))
        r.host.memoryBytes = m[1].to!ulong * 1024;

    const cpuinfo = sh("cat /proc/cpuinfo");
    parseCpuinfo(cpuinfo, r.cpu);
    r.cpu.logicalCpus = cast(uint) cpuinfo.matchAll(ctRegex!`(?m)^processor\s*:`).array.length;
    if (!r.cpu.model.length)
        r.cpu.model = r.android.soc;

    // App processes are confined by seccomp; the shell reports kernel support only.
    r.io = IoReport(backend: "io_uring",
        status: "not probed over adb; Android's app seccomp policy blocks io_uring_setup");

    probeAndroidVulkan(r, sh("cmd gpu vkjson"));
    probeAndroidCodecs(r, &sh);
}

void probeAndroidVulkan(ref Report r, string vkjson)
{
    JSONValue j;
    try
        j = parseJSON(vkjson);
    catch (Exception e)
    {
        r.vulkan.status = "cmd gpu vkjson unparseable";
        return;
    }
    r.vulkan.status = "available (cmd gpu vkjson)";
    if (auto v = "apiVersion" in j)
        r.vulkan.loaderVersion = versionText(cast(uint) num(*v));
    if (auto exts = "extensions" in j)
        r.vulkan.instanceExtensions = extNames(*exts);

    foreach (dev; j["devices"].array)
    {
        GpuReport g;
        const p = dev["properties"];
        g.name = p["deviceName"].str;
        g.type = deviceTypeName(cast(VkPhysicalDeviceType) num(p["deviceType"]));
        g.vendor = vendorName(cast(uint) num(p["vendorID"]));
        g.deviceId = i"0x$((cast(uint) num(p["deviceID"])).to!string(16))".text;
        g.apiVersion = versionText(cast(uint) num(p["apiVersion"]));
        g.extensions = extNames(dev["extensions"]);
        if (auto d = "VK_KHR_driver_properties" in dev)
        {
            const dp = (*d)["driverPropertiesKHR"];
            g.driverName = dp["driverName"].str;
            g.driverInfo = dp["driverInfo"].str;
            g.driverId = vkName(cast(VkDriverId) num(dp["driverID"]));
        }
        g.limits = limitsFromJson(p["limits"]);
        if (auto s = "subgroupProperties" in dev)
            g.subgroup = SubgroupReport(
                size: cast(uint) num((*s)["subgroupSize"]),
                stages: flagNames!VkShaderStageFlagBits(cast(uint) num((*s)["supportedStages"])),
                operations: flagNames!VkSubgroupFeatureFlagBits(cast(uint) num((*s)["supportedOperations"])),
            );

        // vkjson formats: [[format, {linearTilingFeatures, optimalTilingFeatures, bufferFeatures}], …]
        if (auto fs = "formats" in dev)
            foreach (entry; fs.array)
            {
                const f = cast(VkFormat) num(entry[0]);
                if (!probedFormats.canFind(f))
                    continue;
                const fp = entry[1];
                g.formats ~= FormatSupport(
                    format: formatName(f),
                    optimal: flagNames!VkFormatFeatureFlagBits(cast(uint) num(fp["optimalTilingFeatures"])),
                    linear: flagNames!VkFormatFeatureFlagBits(cast(uint) num(fp["linearTilingFeatures"])),
                    buffer: flagNames!VkFormatFeatureFlagBits(cast(uint) num(fp["bufferFeatures"])),
                );
            }
        if (auto feat = "features" in dev)
        {
            string[] on;
            foreach (k, v; feat.object)
                if (v.type != JSONType.object && num(v) != 0)
                    on ~= k;
            g.features ~= FeatureSet("VkPhysicalDeviceFeatures", on.sort.array);
        }
        if (auto mem = "memory" in dev)
            foreach (h; (*mem)["memoryHeaps"].array)
                g.memoryHeaps ~= MemoryHeap(
                    size: cast(ulong) num(h["size"]),
                    flags: flagNames!VkMemoryHeapFlagBits(cast(uint) num(h["flags"])),
                );
        if (auto qs = "queues" in dev)
            foreach (i, q; qs.array)
                g.queueFamilies ~= QueueFamily(cast(uint) i, cast(uint) num(q["queueCount"]),
                    flagNames!VkQueueFlagBits(cast(uint) num(q["queueFlags"])));
        r.vulkan.devices ~= g;
    }
}

/// `Limits`, field by field, from vkjson's `limits` object (same member names).
Limits limitsFromJson(in JSONValue l)
{
    Limits r;
    static foreach (name; FieldNameTuple!Limits)
        if (auto v = name in l.object)
        {
            alias F = typeof(__traits(getMember, r, name));
            static if (is(F == E[n], E, size_t n))
                foreach (i; 0 .. n)
                    __traits(getMember, r, name)[i] = cast(E) num((*v)[i]);
            else
                __traits(getMember, r, name) = cast(F) num(*v);
        }
    return r;
}

double num(in JSONValue v)
{
    switch (v.type)
    {
        case JSONType.float_: return v.floating;
        case JSONType.integer: return v.integer;
        case JSONType.uinteger: return v.uinteger;
        case JSONType.true_: return 1;
        // 64-bit values (heap sizes, alignments) are written as hex strings.
        case JSONType.string:
            return v.str.startsWith("0x") ? v.str[2 .. $].to!ulong(16) : v.str.to!double;
        default: return 0;
    }
}

string[] extNames(in JSONValue list)
    => list.array.map!(e => e["extensionName"].str).array.sort.array;

/// The codec lists the media framework loads: the vendor list (or its
/// `ro.media.xml_variant.codecs` variant) with its includes, plus the
/// software-codec APEX.
void probeAndroidCodecs(ref Report r, scope string delegate(string) sh)
{
    r.media.api = "MediaCodec";
    const variant = r.android.mediaCodecVariant;
    string[] queue = ["/vendor/etc/media_codecs" ~ variant ~ ".xml",
        "/apex/com.android.media.swcodec/etc/media_codecs.xml"];
    string[] seen;
    while (queue.length)
    {
        const path = queue[0];
        queue = queue[1 .. $];
        if (seen.canFind(path))
            continue;
        seen ~= path;
        const xml = sh("cat " ~ path);
        if (!xml.length)
        {
            r.notes ~= "codec list missing: " ~ path;
            continue;
        }
        foreach (m; xml.matchAll(ctRegex!`<Include\s+href="([^"]+)"`))
            queue ~= buildPath(path.dirName, m[1]);
        r.media.codecs ~= parseCodecXml(xml, path);
    }
}

MediaCodec[] parseCodecXml(string xml, string source)
{
    MediaCodec[] result;
    foreach (m; xml.matchAll(ctRegex!(`<MediaCodec\b([^>]*?)(/>|>([\s\S]*?)</MediaCodec>)`)))
    {
        const attrs = m[1];
        const body = m[3];
        const name = attr(attrs, "name");
        string[] mimes;
        if (const t = attr(attrs, "type"))
            mimes ~= t;
        foreach (t; body.matchAll(ctRegex!`<Type\s+name="([^"]+)"`))
            mimes ~= t[1].idup;
        string maxSize;
        if (auto s = body.matchFirst(ctRegex!`<Limit\s+name="size"[^>]*max="([^"]+)"`))
            maxSize = s[1].idup;
        string[] features = body.matchAll(ctRegex!`<Feature\s+name="([^"]+)"`).map!(f => f[1].idup).array;
        foreach (mime; mimes.filter!(t => t.startsWith("video/") || t.startsWith("image/")))
            result ~= MediaCodec(
                name: name,
                mime: mime,
                direction: name.canFind("encoder") ? "encode" : "decode",
                kind: codecKind(name),
                maxSize: maxSize,
                features: features,
                source: source,
            );
    }
    return result;
}

string attr(string attrs, string key)
{
    foreach (m; attrs.matchAll(ctRegex!`(\w+)="([^"]*)"`))
        if (m[1] == key)
            return m[2].idup;
    return null;
}

/// `c2.android.*` and `OMX.google.*` are the platform's software codecs;
/// vendor prefixes are hardware.
string codecKind(string name)
    => name.startsWith("c2.android.", "OMX.google.") ? "software"
        : name.startsWith("c2.", "OMX.") ? "hardware" : "unknown";

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

@("media_hw_probe.parseVainfo")
@safe unittest
{
    MediaDevice d;
    parseVainfo("vainfo: Driver version: Mesa Gallium driver 25.1.0 for AMD\n"
        ~ "      VAProfileH264High               : VAEntrypointVLD\n"
        ~ "      VAProfileH264High               : VAEntrypointEncSlice\n"
        ~ "      VAProfileAV1Profile0            : VAEntrypointVLD\n", d);
    assert(d.driver == "Mesa Gallium driver 25.1.0 for AMD");
    assert(d.profiles == ["VAProfileH264High: VLD, EncSlice", "VAProfileAV1Profile0: VLD"]);
}

@("media_hw_probe.parseCodecXml")
@safe unittest
{
    const xml = `<Decoders>
        <MediaCodec name="c2.qti.avc.decoder" type="video/avc">
            <Limit name="size" min="96x96" max="4096x2304" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
        <MediaCodec name="c2.android.vp9.decoder">
            <Type name="video/x-vnd.on2.vp9" />
        </MediaCodec>
        <MediaCodec name="c2.qti.aac.decoder" type="audio/mp4a-latm" />
    </Decoders>`;
    const codecs = parseCodecXml(xml, "test.xml");
    assert(codecs.length == 2);
    assert(codecs[0].name == "c2.qti.avc.decoder" && codecs[0].kind == "hardware");
    assert(codecs[0].maxSize == "4096x2304" && codecs[0].features == ["adaptive-playback"]);
    assert(codecs[1].mime == "video/x-vnd.on2.vp9" && codecs[1].kind == "software");
}
