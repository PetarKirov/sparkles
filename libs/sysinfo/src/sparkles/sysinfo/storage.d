module sparkles.sysinfo.storage;

import expected : Expected, ok, err;

struct StorageDevice
{
    string name;
    string model;
    string serial;
    string firmwareRev;
    string transport;
    ulong sizeBytes;
    bool isNvme;
}

/// Query all storage devices from sysfs.
Expected!(StorageDevice[], string) queryStorageDevices() @safe
{
    StorageDevice[] devices;

    // NVMe devices
    devices ~= queryNvmeDevices();
    // SCSI/SATA/USB block devices
    devices ~= queryBlockDevices();

    return ok(devices);
}

private StorageDevice[] queryNvmeDevices() @safe
{
    import sparkles.sysinfo.sysfs : readSysfsFile, readSysfsFileAsUlong;

    StorageDevice[] devices;

    (() @trusted {
        import std.file : dirEntries, SpanMode, isDir;
        import std.path : baseName;

        try
        {
            foreach (entry; dirEntries("/sys/class/nvme/", SpanMode.shallow))
            {
                auto ctrlName = baseName(entry.name);
                auto ctrlPath = entry.name ~ "/";

                auto model = readSysfsFile(ctrlPath ~ "model");
                auto serial = readSysfsFile(ctrlPath ~ "serial");
                auto firmware = readSysfsFile(ctrlPath ~ "firmware_rev");
                auto transport = readSysfsFile(ctrlPath ~ "transport");

                // Find the namespace block device (e.g. nvme0n1)
                foreach (ns; dirEntries("/sys/block/", ctrlName ~ "n*", SpanMode.shallow))
                {
                    auto nsName = baseName(ns.name);
                    auto sizeBlocks = readSysfsFileAsUlong("/sys/block/" ~ nsName ~ "/size");

                    devices ~= StorageDevice(
                        nsName,
                        model.hasValue ? model.value : "",
                        serial.hasValue ? serial.value : "",
                        firmware.hasValue ? firmware.value : "",
                        transport.hasValue ? transport.value : "",
                        sizeBlocks.hasValue ? sizeBlocks.value * 512 : 0,
                        true,
                    );
                }
            }
        }
        catch (Exception)
        {
        }
    })();

    return devices;
}

private StorageDevice[] queryBlockDevices() @safe
{
    import sparkles.sysinfo.sysfs : readSysfsFile, readSysfsFileAsUlong;

    StorageDevice[] devices;

    (() @trusted {
        import std.file : dirEntries, SpanMode;
        import std.path : baseName;

        try
        {
            foreach (entry; dirEntries("/sys/block/", "sd*", SpanMode.shallow))
            {
                auto name = baseName(entry.name);
                auto devPath = "/sys/block/" ~ name ~ "/device/";

                auto model = readSysfsFile(devPath ~ "model");
                auto vendor = readSysfsFile(devPath ~ "vendor");
                auto serial = readSysfsFile(devPath ~ "serial");
                auto sizeBlocks = readSysfsFileAsUlong("/sys/block/" ~ name ~ "/size");

                // Determine transport from removable + device path heuristics
                auto removable = readSysfsFile("/sys/block/" ~ name ~ "/removable");
                string transport = removable.hasValue && removable.value == "1" ? "USB" : "SATA";

                string vendorStr = vendor.hasValue ? vendor.value : "";
                string modelStr = model.hasValue ? model.value : "";
                // Skip generic vendor names like "USB", "ATA"
                string fullModel = (vendorStr.length > 0
                        && vendorStr != "USB" && vendorStr != "ATA")
                    ? vendorStr ~ " " ~ modelStr
                    : modelStr;

                devices ~= StorageDevice(
                    name,
                    fullModel,
                    serial.hasValue ? serial.value : "",
                    "",
                    transport,
                    sizeBlocks.hasValue ? sizeBlocks.value * 512 : 0,
                    false,
                );
            }
        }
        catch (Exception)
        {
        }
    })();

    return devices;
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("storage.queryStorageDevices.smoke")
@safe unittest
{
    // Smoke test: should not crash regardless of hardware
    auto result = queryStorageDevices();
    assert(result.hasValue);
}
