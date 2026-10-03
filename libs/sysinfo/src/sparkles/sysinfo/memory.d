module sparkles.sysinfo.memory;

import expected : Expected, ok, err;

struct DimmInfo
{
    uint sizeMB;
    string memoryType;
    uint speedMTs;
    string manufacturer;
    string partNumber;
}

struct MemoryInfo
{
    ulong totalKB;
    bool hasDimmDetails;
    DimmInfo[] dimms;
}

/// Format total memory in human-readable form.
string formatMemoryTotal(ulong totalKB) @safe pure
{
    import std.format : format;

    double gb = totalKB / 1_048_576.0;
    return format!"%.1f GB"(gb);
}

/// Map DMI type 17 memory-type byte to string.
string memoryTypeName(ubyte typeCode) @safe pure nothrow @nogc
{
    switch (typeCode)
    {
    case 0x1A:
        return "DDR4";
    case 0x1E:
        return "DDR5";
    case 0x18:
        return "DDR3";
    case 0x14:
        return "DDR2";
    case 0x12:
        return "DDR";
    default:
        return "Unknown";
    }
}

/// Parse a single DMI type 17 binary entry.
Expected!(DimmInfo, string) parseDmiType17(in ubyte[] data) @safe pure
{
    // Minimum formatted section length for type 17 is 0x1C bytes (header + fields)
    if (data.length < 0x1C)
        return err!DimmInfo("DMI type 17 entry too short");

    // Offset 0x0C: size (2 bytes LE)
    uint rawSize = data[0x0C] | (data[0x0D] << 8);
    if (rawSize == 0 || rawSize == 0xFFFF)
        return err!DimmInfo("empty DIMM slot");

    uint sizeMB;
    if (rawSize == 0x7FFF)
    {
        // Extended size at offset 0x1C (4 bytes LE)
        if (data.length < 0x20)
            return err!DimmInfo("extended size field missing");
        sizeMB = data[0x1C] | (data[0x1D] << 8) | (data[0x1E] << 16) | (data[0x1F] << 24);
    }
    else
    {
        sizeMB = rawSize & 0x7FFF;
        if (rawSize & 0x8000)
            sizeMB /= 1024; // size is in KB
    }

    // Offset 0x12: memory type (1 byte)
    ubyte memType = data[0x12];

    // Offset 0x15: speed (2 bytes LE, MT/s)
    uint speedMTs = data[0x15] | (data[0x16] << 8);

    // Offsets 0x17 and 0x18 are 1-based string indices into the string table
    // that follows the formatted section
    ubyte headerLen = data[0x01];
    string manufacturer = extractDmiString(data, headerLen, data[0x17]);
    string partNumber = extractDmiString(data, headerLen, data[0x18]);

    return ok(DimmInfo(
        sizeMB,
        memoryTypeName(memType),
        speedMTs,
        manufacturer,
        partNumber,
    ));
}

/// Extract a 1-based string from the DMI string table.
private string extractDmiString(in ubyte[] data, ubyte headerLen, ubyte index) @safe pure
{
    if (index == 0 || headerLen >= data.length)
        return "";

    size_t pos = headerLen;
    uint current = 1;

    while (pos < data.length)
    {
        // Find end of current string
        size_t strStart = pos;
        while (pos < data.length && data[pos] != 0)
            pos++;

        if (current == index)
        {
            if (strStart == pos)
                return "";
            return (() @trusted {
                return cast(string) data[strStart .. pos];
            })();
        }

        current++;
        pos++; // skip null terminator

        // Double null means end of string table
        if (pos < data.length && data[pos] == 0)
            break;
    }

    return "";
}

/// Query memory info from the system.
Expected!(MemoryInfo, string) queryMemoryInfo() @safe
{
    import sparkles.sysinfo.sysfs : readSysfsFile, readSysfsBinary;
    import std.string : strip, indexOf;
    import std.conv : to;

    MemoryInfo info;

    // Parse /proc/meminfo for total
    auto meminfo = readSysfsFile("/proc/meminfo");
    if (meminfo.hasError)
        return err!MemoryInfo("failed to read /proc/meminfo: " ~ meminfo.error);

    info.totalKB = parseMemTotal(meminfo.value);

    // Try DMI type 17 entries (requires root)
    info.dimms = queryDimmInfo();
    info.hasDimmDetails = info.dimms.length > 0;

    return ok(info);
}

/// Parse MemTotal from /proc/meminfo content.
ulong parseMemTotal(string content) @safe pure
{
    import std.string : indexOf;
    import std.algorithm : splitter;
    import std.conv : to;

    foreach (line; content.splitter('\n'))
    {
        if (line.length > 9 && line[0 .. 9] == "MemTotal:")
        {
            auto rest = line[9 .. $];
            // Strip leading whitespace and trailing " kB"
            size_t start = 0;
            while (start < rest.length && rest[start] == ' ')
                start++;
            size_t end = start;
            while (end < rest.length && rest[end] >= '0' && rest[end] <= '9')
                end++;
            if (end > start)
            {
                try
                    return rest[start .. end].to!ulong;
                catch (Exception)
                    return 0;
            }
        }
    }
    return 0;
}

/// Query DIMM info from DMI type 17 sysfs entries.
private DimmInfo[] queryDimmInfo() @safe
{
    import sparkles.sysinfo.sysfs : readSysfsBinary;

    DimmInfo[] dimms;

    // DMI type 17 entries are at /sys/firmware/dmi/entries/17-*/raw
    (() @trusted {
        import std.file : dirEntries, SpanMode;

        try
        {
            foreach (entry; dirEntries("/sys/firmware/dmi/entries/", "17-*", SpanMode.shallow))
            {
                auto raw = readSysfsBinary(entry.name ~ "/raw");
                if (raw.hasError)
                    continue;
                auto dimm = parseDmiType17(raw.value);
                if (dimm.hasValue)
                    dimms ~= dimm.value;
            }
        }
        catch (Exception)
        {
            // Not root or entries don't exist
        }
    })();

    return dimms;
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("memory.formatMemoryTotal")
@safe pure unittest
{
    assert(formatMemoryTotal(30_529_536) == "29.1 GB");
    assert(formatMemoryTotal(1_048_576) == "1.0 GB");
}

@("memory.memoryTypeName")
@safe pure nothrow @nogc unittest
{
    assert(memoryTypeName(0x1A) == "DDR4");
    assert(memoryTypeName(0x1E) == "DDR5");
    assert(memoryTypeName(0xFF) == "Unknown");
}

@("memory.parseDmiType17.synthetic")
@safe pure unittest
{
    // Build a minimal DMI type 17 entry:
    // Header: type(1) + length(1) + handle(2) = 4 bytes at start
    // We need at least 0x1C bytes for formatted section
    ubyte[0x20] data;
    data[0x00] = 17; // type
    data[0x01] = 0x1C; // header length (formatted section)
    // handle at 0x02-0x03
    // size at 0x0C-0x0D: 16384 MB = 16 GB
    data[0x0C] = 0x00;
    data[0x0D] = 0x40; // 16384
    // memory type at 0x12: DDR5
    data[0x12] = 0x1E;
    // speed at 0x15-0x16: 5600 MT/s
    data[0x15] = 0xE0;
    data[0x16] = 0x15; // 5600
    // string indices: 0 = no string
    data[0x17] = 0;
    data[0x18] = 0;

    auto result = parseDmiType17(data[]);
    assert(result.hasValue);
    assert(result.value.sizeMB == 16384);
    assert(result.value.memoryType == "DDR5");
    assert(result.value.speedMTs == 5600);
}

@("memory.parseDmiType17.emptySlot")
@safe pure unittest
{
    ubyte[0x1C] data;
    data[0x01] = 0x1C;
    data[0x0C] = 0; // size = 0, empty slot
    data[0x0D] = 0;

    auto result = parseDmiType17(data[]);
    assert(result.hasError);
}

@("memory.parseMemTotal")
@safe pure unittest
{
    enum content = "MemTotal:       30529536 kB\nMemFree:        12345678 kB\n";
    assert(parseMemTotal(content) == 30_529_536);
}
