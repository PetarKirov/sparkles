module sparkles.sysinfo.cpu;

import expected : Expected, ok, err;

struct CpuInfo
{
    string modelName;
    string vendorId;
    uint cores;
    uint threads;
    double maxMhz;
}

/// Parse `/proc/cpuinfo` content into `CpuInfo`.
CpuInfo parseCpuInfo(string content) @safe pure
{
    import std.string : strip, indexOf;
    import std.conv : to;
    import std.algorithm : splitter;

    CpuInfo info;
    uint processorCount;
    bool[string] coreIdsSeen;

    foreach (line; content.splitter('\n'))
    {
        auto colonIdx = line.indexOf(':');
        if (colonIdx < 0)
            continue;

        auto key = line[0 .. colonIdx].strip;
        auto value = line[colonIdx + 1 .. $].strip;

        switch (key)
        {
        case "model name":
            if (info.modelName.length == 0)
                info.modelName = value;
            break;
        case "vendor_id":
            if (info.vendorId.length == 0)
                info.vendorId = value;
            break;
        case "processor":
            processorCount++;
            break;
        case "core id":
            coreIdsSeen[value] = true;
            break;
        default:
            break;
        }
    }

    info.threads = processorCount;
    info.cores = coreIdsSeen.length > 0 ? cast(uint) coreIdsSeen.length : processorCount;

    return info;
}

/// Query CPU info from the system.
Expected!(CpuInfo, string) queryCpuInfo() @safe
{
    import sparkles.sysinfo.sysfs : readSysfsFile, readSysfsFileAsUlong;

    auto cpuinfoText = readSysfsFile("/proc/cpuinfo");
    if (cpuinfoText.hasError)
        return err!CpuInfo("failed to read /proc/cpuinfo: " ~ cpuinfoText.error);

    auto info = parseCpuInfo(cpuinfoText.value);

    auto maxFreq = readSysfsFileAsUlong("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq");
    if (maxFreq.hasValue)
        info.maxMhz = maxFreq.value / 1000.0;

    return ok(info);
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("cpu.parseCpuInfo.synthetic")
@safe pure unittest
{
    enum content = `processor	: 0
vendor_id	: AuthenticAMD
model name	: AMD Ryzen 9 7940HX with Radeon Graphics
core id		: 0

processor	: 1
vendor_id	: AuthenticAMD
model name	: AMD Ryzen 9 7940HX with Radeon Graphics
core id		: 1

processor	: 2
vendor_id	: AuthenticAMD
model name	: AMD Ryzen 9 7940HX with Radeon Graphics
core id		: 0

processor	: 3
vendor_id	: AuthenticAMD
model name	: AMD Ryzen 9 7940HX with Radeon Graphics
core id		: 1
`;

    auto info = parseCpuInfo(content);
    assert(info.modelName == "AMD Ryzen 9 7940HX with Radeon Graphics");
    assert(info.vendorId == "AuthenticAMD");
    assert(info.threads == 4);
    assert(info.cores == 2);
}

@("cpu.parseCpuInfo.noCoreId")
@safe pure unittest
{
    enum content = `processor	: 0
model name	: Some CPU

processor	: 1
model name	: Some CPU
`;

    auto info = parseCpuInfo(content);
    assert(info.threads == 2);
    assert(info.cores == 2); // falls back to thread count
}
