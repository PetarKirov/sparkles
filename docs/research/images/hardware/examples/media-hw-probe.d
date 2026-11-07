#!/usr/bin/env dub
/+ dub.sdl:
    name "media-hw-probe"
    platforms "linux" "osx"
    dependency "sparkles:vulkan" path="../../../../.."
    dependency "sparkles:core-cli" path="../../../../.."
    dependency "sparkles:base" path="../../../../.."
    dependency "sparkles:wired" path="../../../../.."
    dependency "sparkles:event-horizon-sys" path="../../../../.." platform="linux"
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
 *
 * Every step that can fail — a process, a remote `adb shell` command, a
 * system or library call, a file read — leaves an `Attempt` in the `attempts`
 * of the section it feeds: its argv (or remote shell command, or call, or
 * path), exit status, `errno`, symbolic code and error output. A failed step
 * never stops the rest, and its argv can be run again by hand.
 */
module media_hw_probe;

import std.algorithm : among, canFind, endsWith, filter, map, sort, startsWith, uniq;
import std.array : array, join, split;
import std.conv : to;
import std.file : dirEntries, exists, isFile, readLink, readText, SpanMode;
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

import sparkles.base.expected : Expected, err, ok;

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
    string report;

    @(Option(`adb`, description: "Probe the Android device with this adb serial instead of the host"))
    string adb;

    @(Option(`list-adb`, description: "List attached adb devices and exit"))
    bool listAdb;

    @(Option(`no-libc-reexec`, description: "Stay on the probe's own glibc even when a GPU driver needs a newer one"))
    bool noLibcReexec;

    Expected!(void, string) run()
    {
        if (listAdb)
        {
            Attempt[] log;
            const devices = command(log, "adb devices", ["adb", "devices", "-l"]);
            stdout.write(devices);
            return log[0].status == attemptOk ? ok()
                : err!void("adb devices -l: " ~ log[0].status ~ ": " ~ log[0].message);
        }

        Report report;
        report.probe = ProbeInfo(
            schema: "sparkles.media-hw-probe/3",
            version_: stamp.version_,
            commit: stamp.commit,
        );
        if (adb.length)
            probeAndroid(report, adb);
        else
            probeHost(report, reexec: !noLibcReexec);

        auto file = this.report.length ? File(this.report, "w") : stdout;
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
}

/// The outcome of an `Attempt`.
enum string attemptOk = "ok";                   /// it ran and answered
enum string attemptFailed = "failed";           /// it ran and reported an error
enum string attemptUnsupported = "unsupported"; /// it ran and answered "not supported"
enum string attemptUnavailable = "unavailable"; /// the tool, library or file is absent
enum string attemptWarning = "warning";         /// a warning a library reported (the Vulkan loader)

/**
One fallible step: what it gathers, how it was done, and how it ended.

Exactly one of `argv`, `call` and `path` says how. `argv` is verbatim, so a
failed step can be retried by hand; an `adb shell` step also gives the remote
command line in `shell`, and leaves the device to `ANDROID_SERIAL`, which keeps
the serial out of the report. The error fields are empty on success.
*/
struct Attempt
{
    string what;       /// the fact being gathered
    string status;     /// `ok`, `failed`, `unsupported`, `unavailable` or `warning`
    string[] argv;     /// an external command, verbatim
    string shell;      /// the remote command line of an `adb shell` step
    string call;       /// a system, library or Vulkan call
    string path;       /// a file that was read
    int exitCode;      /// the process exit status; negative: killed by that signal
    int osError;       /// `errno`; 0 when there is none
    string code;       /// symbolic code: `ENOENT`, `VK_ERROR_INITIALIZATION_FAILED`
    string message;    /// standard error, `dlerror()`, `strerror()` or an exception message
    string stdoutTail; /// the end of standard output, kept when a command failed
}

struct ProbeInfo
{
    string schema;
    string version_;
    string commit;
}

struct HostReport
{
    Attempt[] attempts; /// every fallible step behind this section
    string collectedVia; /// `native` or `adb`
    string os;
    string osVersion;
    string kernel;
    string arch;
    string model; /// a phone's or a Mac's model name; empty on a PC
    ulong memoryBytes;
    string libcVersion;    /// the glibc the probe ran on; empty for any other C library
    string libcReexecFrom; /// the glibc it started on, when it re-executed onto a driver's newer one
    DriverManifest[] drivers; /// the Vulkan and EGL driver manifests, and the glibc each driver loads
}

struct CpuReport
{
    Attempt[] attempts; /// every fallible step behind this section
    string model;
    uint logicalCpus;
    string[] coreTypes; /// distinct core descriptions (ARM `CPU part`, Apple perf levels)
    string[] simd;      /// the SIMD and crypto features relevant to image kernels
}

struct IoReport
{
    Attempt[] attempts; /// every fallible step behind this section
    string backend;          /// `io_uring`, `none`, or `unknown`
    string status;           /// `available`, or why not; the details are in `attempts`
    string[] uringOpcodes;   /// every opcode the kernel's probe reports as supported
    string[] uringFeatures;  /// `IORING_FEAT_*` bits from `io_uring_setup`
    string disabled;         /// `kernel.io_uring_disabled`: 0 all, 1 `io_uring_group` and root, 2 nobody
    string group;            /// `kernel.io_uring_group`: the group 1 admits; -1 none
    UringQuery query;        /// `IORING_REGISTER_QUERY` (Linux 6.18), which needs no ring
}

/// What the kernel's io_uring accepts, from the ring-less query.
struct UringQuery
{
    uint requestOpcodes;  /// the number of `IORING_OP_*` opcodes; 0 when not queried
    uint registerOpcodes; /// the number of `IORING_[UN]REGISTER_*` opcodes
    uint queryOpcodes;    /// the number of `IO_URING_QUERY_*` queries
    string[] features;    /// every `IORING_FEAT_*` bit
    string[] setupFlags;  /// every `IORING_SETUP_*` flag
    string[] enterFlags;  /// every `IORING_ENTER_*` flag
    string[] sqeFlags;    /// every `IOSQE_*` flag
}

struct VulkanReport
{
    Attempt[] attempts; /// every fallible step behind this section
    string status;
    string loaderVersion;
    string[] instanceExtensions;
    GpuReport[] devices;
}

/// One Vulkan (ICD) or EGL (libglvnd vendor) driver manifest and the glibc its driver loads.
struct DriverManifest
{
    string api;         /// `vulkan` or `egl`
    string manifest;    /// the JSON file, with the home directory shown as `~`
    string library;     /// its `library_path`, resolved
    string libcDir;     /// the directory of the `libc.so.6` the driver loads
    string libcVersion; /// that glibc's release version
}

struct GpuReport
{
    Attempt[] attempts; /// every fallible step behind this section
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
    bool supported;     /// `vkGetPhysicalDeviceVideoCapabilitiesKHR` succeeded
    Attempt[] attempts; /// the capability query and the two format queries
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
    Attempt[] attempts; /// every fallible step behind this section
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
    Attempt[] attempts; /// every fallible step behind this section
    string soc;
    string board;
    string sdk;
    string vulkanHardware;
    string mediaCodecVariant;
}

// -----------------------------------------------------------------------------
// Host
// -----------------------------------------------------------------------------

void probeHost(ref Report r, bool reexec)
{
    r.host.collectedVia = "native";
    r.host.arch = hostArch;
    r.cpu.logicalCpus = logicalCpus();
    r.host.memoryBytes = hwMemoryBytes();
    if (r.host.memoryBytes == 0)
        r.host.attempts ~= Attempt(what: "total memory", status: attemptFailed,
            call: "sparkles.base.hw_caps.hwMemoryBytes", message: "returned 0");
    r.host.kernel = kernelRelease(r.host.attempts);

    version (linux)
    {
        r.host.os = "linux";
        r.host.osVersion = osReleaseName(r.host.attempts);
        selectLibc(r.host, reexec);
        probeLinuxCpu(r.cpu);
        probeUring(r.io);
        probeVaapi(r.media);
        probeNvidiaSmi(r.media);
    }
    else version (OSX)
    {
        r.host.os = "macos";
        r.host.osVersion = command(r.host.attempts, "macOS version", ["sw_vers", "-productVersion"]).strip;
        r.host.model = command(r.host.attempts, "Mac model", ["sysctl", "-n", "hw.model"]).strip;
        probeMacCpu(r.cpu);
        r.io = IoReport(backend: "none", status: "macOS has no io_uring; kqueue only");
        probeVideoToolbox(r.media);
    }

    probeVulkan(r.vulkan);
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

string kernelRelease(ref Attempt[] log) @trusted
{
    import core.stdc.errno : errno;
    import core.sys.posix.sys.utsname : uname, utsname;

    utsname u;
    Attempt a = { what: "kernel release", call: "uname" };
    if (uname(&u) != 0)
    {
        log ~= errnoAttempt(a, errno);
        return null;
    }
    a.status = attemptOk;
    log ~= a;
    return u.release.ptr.fromStringz.idup;
}

/// `PRETTY_NAME` from the first os-release file that exists, or empty.
string osReleaseName(ref Attempt[] log)
{
    foreach (path; ["/etc/os-release", "/usr/lib/os-release"])
        if (const text = readFile(log, "OS release", path))
        {
            foreach (line; text.lineSplitter)
                if (line.startsWith("PRETTY_NAME="))
                    return line["PRETTY_NAME=".length .. $].strip(`"`);
            return null;
        }
    return null;
}

// -----------------------------------------------------------------------------
// The C library the GPU drivers need (Linux)
// -----------------------------------------------------------------------------

/**
Record the glibc the probe runs on and the one each driver manifest leads to,
and run on the drivers' glibc when it is newer (`sparkles.base.driver_libc`):
a driver built against a newer glibc than the probe's does not load. Returns
only when the probe stays on the glibc it has.
*/
void selectLibc(ref HostReport host, bool reexec) @system
{
    import std.conv : text;
    import sparkles.base.driver_libc : DriverApi, DriverLibc, forEachDriverLibc, reexecOntoDriverGlibc,
        ReexecStatus;

    const outcome = reexecOntoDriverGlibc(allow: reexec);
    if (outcome.status == ReexecStatus.unsupported)
    {
        host.attempts ~= Attempt(what: "C library", status: attemptUnsupported,
            message: "not glibc; the drivers' C library is not checked");
        return;
    }
    host.libcVersion = text(outcome.running);
    host.libcReexecFrom = outcome.startedOn.known ? text(outcome.startedOn) : null;
    host.attempts ~= Attempt(what: "C library", status: attemptOk, call: "gnu_get_libc_version");

    forEachDriverLibc((in DriverLibc d) nothrow {
        try
            host.drivers ~= DriverManifest(
                api: d.api == DriverApi.vulkan ? "vulkan" : "egl",
                manifest: homeAsTilde(d.manifest.idup),
                library: d.library.idup,
                libcDir: d.libcDir.idup,
                libcVersion: d.release.known ? text(d.release) : null,
            );
        catch (Exception)
        {
        }
    });
    host.drivers.sort!((a, b) => a.api < b.api || (a.api == b.api && a.manifest < b.manifest));
    foreach (d; host.drivers)
    {
        Attempt a = { what: d.api ~ " driver manifest", path: d.manifest };
        a.status = d.libcVersion.length ? attemptOk : attemptUnavailable;
        if (!d.library.length)
            a.message = "no driver library found for this manifest";
        else if (!d.libcVersion.length)
            a.message = d.library ~ ": no glibc found in its run path or the system's";
        host.attempts ~= a;
    }

    if (outcome.status == ReexecStatus.declined || outcome.status == ReexecStatus.failed)
    {
        Attempt a = {
            what: "run on the drivers' glibc",
            call: "sparkles.base.driver_libc.reexecOntoDriverGlibc",
            message: text("a driver loads glibc ", outcome.drivers, ", newer than the probe's ",
                outcome.running),
        };
        if (outcome.status == ReexecStatus.declined)
        {
            a.status = attemptWarning;
            a.message ~= "; --no-libc-reexec keeps the probe's, so that driver may not load";
        }
        else if (outcome.error)
            a = errnoAttempt(a, outcome.error);
        else
        {
            a.status = attemptFailed;
            a.message ~= "; the re-execution could not be prepared";
        }
        host.attempts ~= a;
    }
}

/// `path` with the home directory written `~`, which keeps the user name out of the report.
string homeAsTilde(string path)
{
    import std.process : environment;

    const home = environment.get("HOME", null);
    return home.length > 1 && path.startsWith(home ~ "/") ? "~" ~ path[home.length .. $] : path;
}

// -----------------------------------------------------------------------------
// Attempts
// -----------------------------------------------------------------------------

/**
Run `argv`, record it in `log`, and return its standard output — or `null`
unless it exited with 0.

Standard error goes to a temporary file rather than a second pipe, so a chatty
command cannot deadlock against an unread stdout. `env` is added to the
inherited environment; `shell` is the remote command line of an `adb shell`.
*/
string command(ref Attempt[] log, string what, string[] argv,
    string[string] env = null, string shell = null)
{
    import std.process : Config, pipe, ProcessException, spawnProcess, wait;

    Attempt a = { what: what, argv: argv, shell: shell };
    string output;
    try
    {
        auto errors = File.tmpfile();
        auto stdoutPipe = pipe();
        auto pid = spawnProcess(argv, File("/dev/null"), stdoutPipe.writeEnd, errors, env,
            Config.retainStderr);
        output = readAll(stdoutPipe.readEnd);
        a.exitCode = wait(pid);
        if (a.exitCode == 0)
            a.status = attemptOk;
        else
        {
            errors.rewind();
            a.status = attemptFailed;
            a.message = tail(readAll(errors));
            a.stdoutTail = tail(output, 2048);
        }
    }
    catch (ProcessException e)
    {
        // `spawnProcess` reports a missing executable this way, before any exec.
        a.status = attemptUnavailable;
        a.message = e.msg;
    }
    catch (Exception e)
    {
        a.status = attemptFailed;
        a.message = e.msg;
    }
    log ~= a;
    return a.status == attemptOk ? output : null;
}

string readAll(File f)
{
    import std.array : appender;

    auto bytes = appender!(char[]);
    foreach (chunk; f.byChunk(64 * 1024))
        bytes ~= cast(const(char)[]) chunk;
    return bytes[].idup;
}

/// The last `limit` bytes of `s`, trimmed and made valid UTF-8 (a cut can split
/// a sequence, and a tool may print anything).
string tail(string s, size_t limit = 4096)
{
    import std.encoding : sanitize;

    return sanitize(s.length > limit ? s[$ - limit .. $] : s).strip;
}

/// Read `path`, recording the attempt; `null` when it cannot be read.
string readFile(ref Attempt[] log, string what, string path)
{
    import std.file : FileException;

    Attempt a = { what: what, path: path };
    string text;
    try
    {
        text = readText(path);
        a.status = attemptOk;
    }
    catch (FileException e)
    {
        a = errnoAttempt(a, e.errno);
        a.message = e.msg;
    }
    catch (Exception e)
    {
        a.status = attemptFailed;
        a.message = e.msg;
    }
    log ~= a;
    return a.status == attemptOk ? text : null;
}

/// `a` failed with `errno` `e`: a missing file is `unavailable`, anything else `failed`.
Attempt errnoAttempt(Attempt a, int e) @trusted
{
    import core.stdc.errno : ENOENT;
    import core.stdc.string : strerror;

    a.status = e == ENOENT ? attemptUnavailable : attemptFailed;
    a.osError = e;
    a.code = errnoName(e);
    a.message = strerror(e).fromStringz.idup;
    return a;
}

/// The symbolic name of the `errno` values a probe step can meet.
string errnoName(int e) pure nothrow @safe @nogc
{
    import core.stdc.errno;

    switch (e)
    {
        static foreach (name; ["EPERM", "ENOENT", "EIO", "ENXIO", "EACCES", "EBUSY",
            "ENODEV", "EINVAL", "ENOMEM", "ENOSYS", "EAGAIN", "EFAULT", "EMFILE"])
            case mixin(name): return name;
        default: return null;
    }
}

// The x86 features an image kernel can dispatch on; `/proc/cpuinfo` lists only
// those the kernel has enabled the register state for.
immutable string[] x86SimdFlags = [
    "sse2", "ssse3", "sse4_1", "sse4_2", "avx", "avx2", "fma", "f16c", "bmi2",
    "avx512f", "avx512dq", "avx512cd", "avx512bw", "avx512vl", "avx512ifma",
    "avx512vbmi", "avx512_vbmi2", "avx512_vnni", "avx512_bitalg",
    "avx512_vpopcntdq", "avx512_bf16", "avx512_fp16", "avx_vnni", "avx_vnni_int8",
    "avx_ifma", "avx10", "gfni", "vaes", "vpclmulqdq", "sha_ni", "amx_tile",
    "amx_int8", "amx_bf16", "amx_fp16",
];

void probeLinuxCpu(ref CpuReport cpu)
{
    if (const text = readFile(cpu.attempts, "CPU model and features", "/proc/cpuinfo"))
        parseCpuinfo(text, cpu);
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

version (linux) void probeUring(ref IoReport io)
{
    import sparkles.event_horizon.sys.uring : Operation, SetupFeatures, Uring, setup;

    io.backend = "io_uring";
    // Before the ring: the sysctls explain a refused setup, and the query needs none.
    io.disabled = readFile(io.attempts, "io_uring_disabled sysctl", "/proc/sys/kernel/io_uring_disabled").strip;
    io.group = readFile(io.attempts, "io_uring_group sysctl", "/proc/sys/kernel/io_uring_group").strip;
    queryUring(io);

    Uring ring;
    const ret = ring.setup(8);
    Attempt setupAttempt = { what: "io_uring support", call: "io_uring_setup(8, 0)" };
    if (ret < 0)
    {
        io.attempts ~= errnoAttempt(setupAttempt, -ret);
        io.status = "io_uring_setup failed";
        return;
    }
    setupAttempt.status = attemptOk;
    io.attempts ~= setupAttempt;
    io.status = "available";

    const features = ring.params().features;
    static foreach (f; __traits(allMembers, SetupFeatures))
        static if (is(typeof(__traits(getMember, SetupFeatures, f)) == SetupFeatures))
            if (features & __traits(getMember, SetupFeatures, f))
                io.uringFeatures ~= f;

    auto probe = ring.probe();
    Attempt probeAttempt = { what: "io_uring opcodes", call: "io_uring_register(IORING_REGISTER_PROBE)" };
    if (!cast(bool) probe)
    {
        io.attempts ~= errnoAttempt(probeAttempt, -probe.error);
        return;
    }
    probeAttempt.status = attemptOk;
    io.attempts ~= probeAttempt;
    foreach (op; [EnumMembers!Operation].sort.uniq)
        if (probe.isSupported(op))
            io.uringOpcodes ~= op.to!string;
}

/// Ask the kernel what io_uring accepts, without a ring (`IORING_REGISTER_QUERY`, Linux 6.18).
version (linux) void queryUring(ref IoReport io) @trusted
{
    import core.stdc.errno : EBADF, EINVAL, errno;
    import sparkles.event_horizon.sys.uring : EnterFlags, io_uring_query, io_uring_query_hdr,
        io_uring_query_opcode, IO_URING_QUERY_OPCODES, SetupFeatures, SetupFlags, SubmissionEntryFlags;

    io_uring_query_opcode ops;
    io_uring_query_hdr hdr = { query_data: cast(ulong) &ops, query_op: IO_URING_QUERY_OPCODES, size: ops.sizeof };
    Attempt a = { what: "io_uring limits", call: "io_uring_register(-1, IORING_REGISTER_QUERY, IO_URING_QUERY_OPCODES)" };
    if (io_uring_query(&hdr) < 0)
    {
        const e = errno;
        a = errnoAttempt(a, e);
        if (e == EINVAL || e == EBADF)
        {
            a.status = attemptUnsupported;
            a.message = "no IORING_REGISTER_QUERY before Linux 6.18";
        }
    }
    else if (hdr.result < 0)
        a = errnoAttempt(a, -hdr.result);
    else
    {
        a.status = attemptOk;
        io.query = UringQuery(
            requestOpcodes: ops.nr_request_opcodes,
            registerOpcodes: ops.nr_register_opcodes,
            queryOpcodes: ops.nr_query_opcodes,
            features: flagNames!SetupFeatures(ops.feature_flags),
            setupFlags: flagNames!SetupFlags(ops.ring_setup_flags),
            enterFlags: flagNames!EnterFlags(ops.enter_flags),
            sqeFlags: flagNames!SubmissionEntryFlags(ops.sqe_flags),
        );
    }
    io.attempts ~= a;
}

/// The names of the single-bit members of `E` set in `mask`, then `bit N` for
/// each set bit `E` does not name (a flag newer than the binding).
string[] flagNames(E)(ulong mask)
{
    string[] names;
    ulong named;
    static foreach (m; __traits(allMembers, E))
    {{
        enum ulong v = cast(ulong) __traits(getMember, E, m);
        static if (v != 0 && (v & (v - 1)) == 0)
            if ((mask & v) && !(named & v))
            {
                names ~= m;
                named |= v;
            }
    }}
    foreach (bit; 0 .. 64)
        if (mask & ~named & (1UL << bit))
            names ~= "bit " ~ bit.to!string;
    return names;
}

// -----------------------------------------------------------------------------
// Linux: VA-API and NVIDIA
// -----------------------------------------------------------------------------

version (linux) void probeVaapi(ref MediaApiReport media)
{
    media.api = "VA-API";
    string[] nodes;
    try
        nodes = dirEntries("/dev/dri", "renderD*", SpanMode.shallow).map!(e => e.name).array.sort.array;
    catch (Exception e)
    {
        media.attempts ~= Attempt(what: "DRM render nodes", status: attemptUnavailable,
            path: "/dev/dri", message: e.msg);
        return;
    }
    foreach (node; nodes)
    {
        MediaDevice d;
        d.node = node;
        const sys = buildPath("/sys/class/drm", node.baseName, "device");
        d.kernelDriver = linkName(media.attempts, "kernel driver of " ~ node, buildPath(sys, "driver"));
        d.pciId = readFile(media.attempts, "PCI vendor of " ~ node, buildPath(sys, "vendor")).strip
            ~ ":" ~ readFile(media.attempts, "PCI device of " ~ node, buildPath(sys, "device")).strip;
        const output = command(media.attempts, "VA-API profiles of " ~ node,
            ["vainfo", "--display", "drm", "--device", node]);
        parseVainfo(output, d);
        media.devices ~= d;
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

string linkName(ref Attempt[] log, string what, string path)
{
    import std.file : FileException, readLink;

    Attempt a = { what: what, path: path, call: "readlink" };
    try
    {
        const target = readLink(path).baseName;
        a.status = attemptOk;
        log ~= a;
        return target;
    }
    catch (FileException e)
    {
        a = errnoAttempt(a, e.errno);
        a.message = e.msg;
    }
    catch (Exception e)
    {
        a.status = attemptFailed;
        a.message = e.msg;
    }
    log ~= a;
    return null;
}

/// `nvidia-smi` comes with the NVIDIA driver; elsewhere it is `unavailable`.
version (linux) void probeNvidiaSmi(ref MediaApiReport media)
{
    media.nvidia = command(media.attempts, "NVIDIA GPU, driver and memory",
        ["nvidia-smi", "--query-gpu=name,driver_version,memory.total", "--format=csv,noheader"]).strip;
}

// -----------------------------------------------------------------------------
// macOS: CPU and VideoToolbox
// -----------------------------------------------------------------------------

version (OSX) void probeMacCpu(ref CpuReport cpu)
{
    cpu.model = command(cpu.attempts, "CPU model", ["sysctl", "-n", "machdep.cpu.brand_string"]).strip;
    foreach (level; 0 .. 4)
    {
        // `sysctl -n` prints nothing and exits 0 for a level that does not
        // exist, so an empty name ends the list.
        const prefix = "hw.perflevel" ~ level.to!string ~ ".";
        const name = command(cpu.attempts, "core type " ~ level.to!string,
            ["sysctl", "-n", prefix ~ "name"]).strip;
        if (!name.length)
            break;
        cpu.coreTypes ~= name ~ " x" ~ command(cpu.attempts, "core count " ~ level.to!string,
            ["sysctl", "-n", prefix ~ "logicalcpu"]).strip;
    }
    // `hw.optional.arm.FEAT_X: 1` lines; keep the set ones.
    foreach (line; command(cpu.attempts, "CPU features", ["sysctl", "hw.optional"]).lineSplitter)
        if (auto m = line.matchFirst(ctRegex!`^hw\.optional\.(?:arm\.)?(\w+):\s*1$`))
            cpu.simd ~= m[1].idup;
}

version (OSX) void probeVideoToolbox(ref MediaApiReport media)
{
    import core.sys.posix.dlfcn : dlerror, dlopen, dlsym, RTLD_NOW;

    enum framework = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox";
    media.api = "VideoToolbox";

    // `dlerror` describes the last failure; read it at once, before another call.
    Attempt loaded(Attempt a, bool success)
    {
        a.status = success ? attemptOk : attemptUnavailable;
        if (!success)
            if (auto e = dlerror())
                a.message = e.fromStringz.idup;
        return a;
    }

    auto vt = dlopen(framework, RTLD_NOW);
    media.attempts ~= loaded(Attempt(what: "VideoToolbox", call: "dlopen(" ~ framework ~ ")"), vt !is null);
    if (vt is null)
        return;

    alias IsSupported = extern (C) ubyte function(uint) nothrow @nogc;
    auto isHw = cast(IsSupported) dlsym(vt, "VTIsHardwareDecodeSupported");
    media.attempts ~= loaded(Attempt(what: "hardware decode query",
        call: "dlsym(VTIsHardwareDecodeSupported)"), isHw !is null);
    if (isHw is null)
        return;

    // VP9 and AV1 are "supplemental" decoders on Apple silicon: a process
    // must register them before VideoToolbox will report or use them. The
    // registration is per process and changes nothing on the system.
    alias Register = extern (C) void function(uint) nothrow @nogc;
    auto register = cast(Register) dlsym(vt, "VTRegisterSupplementalVideoDecoderIfAvailable");
    media.attempts ~= loaded(Attempt(what: "supplemental decoder registration",
        call: "dlsym(VTRegisterSupplementalVideoDecoderIfAvailable)"), register !is null);

    static immutable string[2][] codecs = [
        ["avc1", "video/avc"], ["hvc1", "video/hevc"], ["av01", "video/av01"],
        ["vp09", "video/x-vnd.on2.vp9"], ["apcn", "video/prores-422"],
        ["ap4h", "video/prores-4444"], ["jpeg", "image/jpeg"], ["mp4v", "video/mp4v-es"],
    ];
    foreach (c; codecs)
    {
        const fourcc = (uint(c[0][0]) << 24) | (uint(c[0][1]) << 16) | (uint(c[0][2]) << 8) | c[0][3];
        if (register !is null)
            register(fourcc);
        media.codecs ~= MediaCodec(
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

/// The outcome of a Vulkan call: `VK_SUCCESS` and the other non-negative
/// results are `ok`, a "not supported" error is `unsupported`.
Attempt vkAttempt(string what, string call, VkResult res)
{
    Attempt a = { what: what, call: call, code: resultName(res) };
    if (res >= 0)
        a.status = attemptOk;
    else
    {
        a.status = res.among(VK_ERROR_FORMAT_NOT_SUPPORTED, VK_ERROR_FEATURE_NOT_PRESENT,
                VK_ERROR_EXTENSION_NOT_PRESENT, VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR,
                VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR,
                VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR,
                VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR,
                VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR,
                VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR)
            ? attemptUnsupported : attemptFailed;
        a.message = describeResult(res);
    }
    return a;
}

/// `VK_ERROR_INITIALIZATION_FAILED`, as the header spells it.
string resultName(VkResult res) pure nothrow @safe @nogc
    => enumMemberNameOr!(CaseStyle.original)(res, "unknown");

void probeVulkan(ref VulkanReport v) @system
{
    auto loaded = loadGetInstanceProcAddr();
    if (loaded.hasError)
    {
        v.status = "no Vulkan loader";
        v.attempts ~= Attempt(what: "Vulkan loader", status: attemptUnavailable,
            call: "dlopen(" ~ loaderLibraryNames.join(", ") ~ ")", message: loaded.error);
        return;
    }
    v.attempts ~= Attempt(what: "Vulkan loader", status: attemptOk,
        call: "dlopen(" ~ loaderLibraryNames.join(", ") ~ ")");
    const global = GlobalCommands.load(loaded.value);
    if (!global.complete)
    {
        v.status = "incomplete Vulkan loader";
        v.attempts ~= Attempt(what: "global commands", status: attemptFailed,
            call: "vkGetInstanceProcAddr", message: "missing " ~ global.firstMissing);
        return;
    }

    uint loaderVersion = apiVersion10;
    if (global.enumerateInstanceVersion !is null)
        v.attempts ~= vkAttempt("loader version", "vkEnumerateInstanceVersion",
            global.enumerateInstanceVersion(&loaderVersion));
    v.loaderVersion = versionText(loaderVersion);

    auto instExts = queryVkList!VkExtensionProperties(global.enumerateInstanceExtensionProperties, null);
    v.instanceExtensions = instExts.map!(e => e.extensionName.ptr.fromStringz.idup).array.sort.array;

    auto appInfo = vkInfo(VkApplicationInfo(
        pApplicationName: "sparkles-media-hw-probe",
        apiVersion: loaderVersion >= apiVersion11 ? loaderVersion : apiVersion11,
    ));
    const portability = instancePortability(instExts, null);
    const(char)*[] enabled;
    if (portability.addExtension)
        enabled ~= khrPortabilityEnumeration.ptr;

    // The loader explains a driver it could not load (a missing library, a
    // newer glibc than this process has) only in its log. A messenger chained
    // into instance creation, then kept for the instance's life, puts that log
    // in the report instead of on a console nobody reads.
    const debugUtils = instExts.hasExtension(extDebugUtils);
    if (debugUtils)
        enabled ~= extDebugUtils.ptr;
    auto messengerInfo = vkInfo(VkDebugUtilsMessengerCreateInfoEXT(
        messageSeverity: VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
            | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        messageType: VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
            | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
            | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        // ImportC types the callback `@nogc`; this one appends to a GC array.
        pfnUserCallback: cast(PFN_vkDebugUtilsMessengerCallbackEXT) &collectLoaderMessage,
    ));

    auto createInfo = vkInfo(VkInstanceCreateInfo(
        pNext: debugUtils ? &messengerInfo : null,
        flags: portability.flags,
        pApplicationInfo: &appInfo,
        enabledExtensionCount: cast(uint) enabled.length,
        ppEnabledExtensionNames: enabled.ptr,
    ));
    if (!debugUtils)
        v.attempts ~= Attempt(what: "Vulkan loader messages", status: attemptUnavailable,
            call: "VK_EXT_debug_utils", message: "the loader does not offer the extension");
    scope (exit)
        v.attempts ~= loaderMessages.sort.uniq
            .map!(m => Attempt(what: "Vulkan loader message", status: m.status,
                call: "VK_EXT_debug_utils", message: m.text))
            .array;

    VkInstance instance;
    const created = global.createInstance(&createInfo, null, &instance);
    v.attempts ~= vkAttempt("Vulkan instance", "vkCreateInstance", created);
    if (created != VK_SUCCESS)
    {
        v.status = "vkCreateInstance failed";
        return;
    }
    const inst = InstanceCommands.load(global, instance);
    VkDebugUtilsMessengerEXT messenger;
    if (debugUtils && inst.createDebugUtilsMessengerEXT !is null)
        v.attempts ~= vkAttempt("Vulkan loader messages", "vkCreateDebugUtilsMessengerEXT",
            inst.createDebugUtilsMessengerEXT(instance, &messengerInfo, null, &messenger));
    scope (exit)
    {
        if (messenger !is null)
            inst.destroyDebugUtilsMessengerEXT(instance, messenger, null);
        inst.destroyInstance(instance, null);
    }
    const extra = ExtraCommands.load(global, instance);

    uint count;
    auto listed = inst.enumeratePhysicalDevices(instance, &count, null);
    auto devices = new VkPhysicalDevice[count];
    if (listed >= 0 && count)
        listed = inst.enumeratePhysicalDevices(instance, &count, devices.ptr);
    v.attempts ~= vkAttempt("physical devices", "vkEnumeratePhysicalDevices", listed);
    v.status = listed >= 0 ? "available" : "vkEnumeratePhysicalDevices failed";
    if (listed >= 0)
        foreach (pd; devices[0 .. count])
            v.devices ~= probeGpu(inst, extra, pd);
}

/// A message the loader (or a layer) sent to the probe's messenger.
struct LoaderMessage
{
    string status; /// `failed` for an error, `warning` for a warning
    string text;

    int opCmp(in LoaderMessage o) const => text < o.text ? -1 : text > o.text;
}

/// What `collectLoaderMessage` has received; the loader calls it on this thread.
__gshared LoaderMessage[] loaderMessages;

extern (C) VkBool32 collectLoaderMessage(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT, const(VkDebugUtilsMessengerCallbackDataEXT)* data, void*) nothrow
{
    try
        loaderMessages ~= LoaderMessage(
            severity >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT ? attemptFailed : attemptWarning,
            data.pMessage.fromStringz.idup.strip);
    catch (Exception)
    {
    }
    return VK_FALSE;
}

string versionText(uint packed) pure @safe
    => i"$(apiVersionMajor(packed)).$(apiVersionMinor(packed)).$(apiVersionPatch(packed))".text;

import std.conv : text;

GpuReport probeGpu(in InstanceCommands inst, in ExtraCommands extra, VkPhysicalDevice pd) @system
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
        g.attempts ~= Attempt(what: "features and properties", status: attemptUnavailable,
            call: "vkGetPhysicalDeviceFeatures2",
            message: "a Vulkan 1.0 device: only the 1.0 structs are reported");

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
    enum call = "vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR";
    uint count;
    auto res = extra.getCoopMatrix(pd, &count, null);
    auto shapes = new VkCooperativeMatrixPropertiesKHR[count];
    foreach (ref s; shapes)
        s = vkInfo(VkCooperativeMatrixPropertiesKHR());
    if (res >= 0 && count)
        res = extra.getCoopMatrix(pd, &count, shapes.ptr);
    g.attempts ~= vkAttempt("cooperative matrix shapes", call, res);
    if (res < 0)
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
    rep.attempts ~= vkAttempt("capabilities", "vkGetPhysicalDeviceVideoCapabilitiesKHR", res);
    if (res != VK_SUCCESS)
        return rep;
    rep.supported = true;
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
        decode ? VK_IMAGE_USAGE_VIDEO_DECODE_DST_BIT_KHR : VK_IMAGE_USAGE_VIDEO_ENCODE_SRC_BIT_KHR,
        decode ? "decode output formats" : "encode input formats", rep.attempts);
    rep.dpbFormats = videoFormats(extra, pd, &list,
        decode ? VK_IMAGE_USAGE_VIDEO_DECODE_DPB_BIT_KHR : VK_IMAGE_USAGE_VIDEO_ENCODE_DPB_BIT_KHR,
        "DPB formats", rep.attempts);
    return rep;
}

/// The formats (with tiling) a video profile accepts for `usage`.
string[] videoFormats(in ExtraCommands extra, VkPhysicalDevice pd,
    VkVideoProfileListInfoKHR* list, uint usage, string what, ref Attempt[] log) @system
{
    enum call = "vkGetPhysicalDeviceVideoFormatPropertiesKHR";
    if (extra.getVideoFormats is null)
    {
        log ~= Attempt(what: what, status: attemptUnavailable, call: call,
            message: "the loader returned no entry point");
        return null;
    }
    auto info = vkInfo(VkPhysicalDeviceVideoFormatInfoKHR(imageUsage: usage));
    info.pNext = list;
    uint count;
    auto res = extra.getVideoFormats(pd, &info, &count, null);
    auto props = new VkVideoFormatPropertiesKHR[count];
    foreach (ref p; props)
        p = vkInfo(VkVideoFormatPropertiesKHR());
    if (res >= 0 && count)
        res = extra.getVideoFormats(pd, &info, &count, props.ptr);
    log ~= vkAttempt(what, call, res);
    if (res < 0)
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
    // adb takes the device from `ANDROID_SERIAL`, so every recorded argv is
    // the same for any phone and the serial never enters the report.
    const string[string] env = ["ANDROID_SERIAL": serial];
    string sh(ref Attempt[] log, string what, string remote)
        => command(log, what, ["adb", "shell", remote], cast(string[string]) env, remote);
    string prop(string name) => sh(r.android.attempts, name, "getprop " ~ name).strip;

    r.host.collectedVia = "adb";
    r.host.os = "android";
    const state = command(r.android.attempts, "adb connection", ["adb", "get-state"],
        cast(string[string]) env).strip;
    if (state != "device")
        return;

    r.host.osVersion = prop("ro.build.version.release");
    r.host.kernel = sh(r.host.attempts, "kernel release", "uname -r").strip;
    r.host.arch = prop("ro.product.cpu.abi");
    r.host.model = prop("ro.product.manufacturer") ~ " " ~ prop("ro.product.model");
    r.android.soc = prop("ro.soc.manufacturer") ~ " " ~ prop("ro.soc.model");
    r.android.board = prop("ro.board.platform");
    r.android.sdk = prop("ro.build.version.sdk");
    r.android.vulkanHardware = prop("ro.hardware.vulkan");
    r.android.mediaCodecVariant = prop("ro.media.xml_variant.codecs");
    if (auto m = sh(r.host.attempts, "total memory", "cat /proc/meminfo")
            .matchFirst(ctRegex!`MemTotal:\s*(\d+) kB`))
        r.host.memoryBytes = m[1].to!ulong * 1024;

    const cpuinfo = sh(r.cpu.attempts, "CPU model and features", "cat /proc/cpuinfo");
    parseCpuinfo(cpuinfo, r.cpu);
    r.cpu.logicalCpus = cast(uint) cpuinfo.matchAll(ctRegex!`(?m)^processor\s*:`).array.length;
    if (!r.cpu.model.length)
        r.cpu.model = r.android.soc;

    // Whether an app may call `io_uring_setup` depends on its own SELinux and
    // seccomp context, which the adb shell does not share.
    r.io = IoReport(backend: "io_uring",
        status: "not probed over adb; needs a run in the app's own context");

    probeAndroidVulkan(r.vulkan, sh(r.vulkan.attempts, "Vulkan devices", "cmd gpu vkjson"));
    probeAndroidCodecs(r.media, r.android.mediaCodecVariant,
        (string what, string remote) => sh(r.media.attempts, what, remote));
}

void probeAndroidVulkan(ref VulkanReport vk, string vkjson)
{
    if (!vkjson.length)
    {
        vk.status = "cmd gpu vkjson failed";
        return;
    }
    JSONValue j;
    try
        j = parseJSON(vkjson);
    catch (Exception e)
    {
        vk.status = "cmd gpu vkjson unparseable";
        vk.attempts ~= Attempt(what: "Vulkan devices", status: attemptFailed,
            call: "std.json.parseJSON", message: e.msg, stdoutTail: tail(vkjson, 2048));
        return;
    }
    vk.status = "available (cmd gpu vkjson)";
    if (auto ver = "apiVersion" in j)
        vk.loaderVersion = versionText(cast(uint) num(*ver));
    if (auto exts = "extensions" in j)
        vk.instanceExtensions = extNames(*exts);

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
        // Drivers of Vulkan 1.2 and later add `core11` … `core13`, the
        // `VkPhysicalDeviceVulkan1xFeatures` and `…Properties` structs.
        static foreach (minor; ["1", "2", "3", "4"])
            if (auto core = "core1" ~ minor in dev)
            {
                if (auto feat = "features" in *core)
                {
                    string[] on;
                    foreach (k, v; feat.object)
                        if (v.type != JSONType.object && v.type != JSONType.array && num(v) != 0)
                            on ~= k;
                    g.features ~= FeatureSet("VkPhysicalDeviceVulkan1" ~ minor ~ "Features", on.sort.array);
                }
                static if (minor == "3")
                    if (auto props = "properties" in *core)
                    {
                        if (auto lo = "minSubgroupSize" in *props)
                            g.subgroup.minSize = cast(uint) num(*lo);
                        if (auto hi = "maxSubgroupSize" in *props)
                            g.subgroup.maxSize = cast(uint) num(*hi);
                    }
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
        vk.devices ~= g;
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
void probeAndroidCodecs(ref MediaApiReport media, string variant,
    scope string delegate(string what, string remote) sh)
{
    media.api = "MediaCodec";
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
        const xml = sh("codec list " ~ path.baseName, "cat " ~ path);
        if (!xml.length)
            continue;
        foreach (m; xml.matchAll(ctRegex!`<Include\s+href="([^"]+)"`))
            queue ~= buildPath(path.dirName, m[1]);
        media.codecs ~= parseCodecXml(xml, path);
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
@system unittest
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
@system unittest
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

@("media_hw_probe.flagNames")
@safe pure unittest
{
    enum Flags : uint { NONE = 0, A = 1, B = 1 << 1, ALSO_B = 1 << 1, AB = 3 }
    assert(flagNames!Flags(0) == null);
    // Aliases and multi-bit members name nothing twice; an unnamed bit is numbered.
    assert(flagNames!Flags(0b1011) == ["A", "B", "bit 3"]);
}
