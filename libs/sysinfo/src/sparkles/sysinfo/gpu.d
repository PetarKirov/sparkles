module sparkles.sysinfo.gpu;

import std.typecons : Nullable;
import expected : Expected, ok, err;

struct GpuInfo
{
    string vendorId;
    string deviceId;
    string vendorName;
    string deviceName;
    Nullable!ulong vramBytes;
}

/// Query GPU info from /sys/class/drm/.
Expected!(GpuInfo[], string) queryGpuInfo() @safe
{
    GpuInfo[] gpus;
    bool[string] seenPciPaths;

    (() @trusted {
        import std.file : dirEntries, SpanMode, readLink, exists;
        import std.path : baseName, dirName;
        import std.string : startsWith;
        import sparkles.sysinfo.sysfs : readSysfsFile, readSysfsFileAsUlong;

        try
        {
            foreach (entry; dirEntries("/sys/class/drm/", "card[0-9]*", SpanMode.shallow))
            {
                auto cardName = baseName(entry.name);
                // Skip render nodes (card0-render, etc.)
                foreach (c; cardName["card".length .. $])
                {
                    if (c < '0' || c > '9')
                        goto nextEntry;
                }

                auto deviceDir = entry.name ~ "/device/";
                if (!exists(deviceDir))
                    continue;

                // Deduplicate by PCI path (resolve symlink)
                string pciPath;
                try
                    pciPath = readLink(entry.name ~ "/device");
                catch (Exception)
                    continue;

                if (pciPath in seenPciPaths)
                    continue;
                seenPciPaths[pciPath] = true;

                // Check display class (0x03xxxx)
                auto classVal = readSysfsFile(deviceDir ~ "class");
                if (classVal.hasError)
                    continue;
                if (classVal.value.length < 4 || classVal.value[0 .. 4] != "0x03")
                    continue;

                auto vendor = readSysfsFile(deviceDir ~ "vendor");
                auto device = readSysfsFile(deviceDir ~ "device");
                if (vendor.hasError || device.hasError)
                    continue;

                // Strip "0x" prefix
                string vid = stripHexPrefix(vendor.value);
                string did = stripHexPrefix(device.value);

                // Look up names from pci.ids
                string vendorName = vid;
                string deviceName = did;

                {
                    import sparkles.sysinfo.pci_ids : lookupPciId;

                    auto pciResult = lookupPciId(vid, did);
                    if (pciResult.hasValue)
                    {
                        vendorName = pciResult.value.vendorName;
                        if (!pciResult.value.deviceName.isNull)
                            deviceName = pciResult.value.deviceName.get;
                    }
                }

                // Try to read VRAM (AMD exposes this)
                auto vram = readSysfsFileAsUlong(deviceDir ~ "mem_info_vram_total");

                gpus ~= GpuInfo(vid, did, vendorName, deviceName,
                    vram.hasValue ? Nullable!ulong(vram.value) : Nullable!ulong.init);

                nextEntry:
            }
        }
        catch (Exception)
        {
        }
    })();

    return ok(gpus);
}

private string stripHexPrefix(string s) @safe pure nothrow @nogc
{
    if (s.length >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        return s[2 .. $];
    return s;
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("gpu.queryGpuInfo.smoke")
@safe unittest
{
    auto result = queryGpuInfo();
    assert(result.hasValue);
}

@("gpu.stripHexPrefix")
@safe pure nothrow @nogc unittest
{
    assert(stripHexPrefix("0x1002") == "1002");
    assert(stripHexPrefix("1002") == "1002");
    assert(stripHexPrefix("0X1002") == "1002");
}
