module sparkles.sysinfo.pci_ids;

import std.typecons : Nullable;
import expected : Expected, ok, err;

struct PciIdResult
{
    string vendorName;
    Nullable!string deviceName;
}

/// Look up vendor and device names from pci.ids file.
/// `vendorId` and `deviceId` should be lowercase hex without "0x" prefix.
Expected!(PciIdResult, string) lookupPciId(string vendorId, string deviceId) @safe
{
    auto path = findPciIdsFile();
    if (path.hasError)
        return err!PciIdResult(path.error);

    return parsePciIdsFile(path.value, vendorId, deviceId);
}

/// Find the pci.ids file.
private Expected!(string, string) findPciIdsFile() @safe
{
    import sparkles.sysinfo.sysfs : findFile;

    // Check HWDATA_PATH env var first
    auto envPath = (() @trusted {
        import std.process : environment;

        try
            return environment.get("HWDATA_PATH", "");
        catch (Exception)
            return "";
    })();

    if (envPath.length > 0)
    {
        auto candidates = [envPath ~ "/pci.ids"];
        auto result = findFile(candidates);
        if (result.hasValue)
            return result;
    }

    return findFile([
        "/usr/share/hwdata/pci.ids",
        "/usr/share/misc/pci.ids",
    ]);
}

/// Parse pci.ids file looking for vendor and device.
private Expected!(PciIdResult, string) parsePciIdsFile(
    string path, string vendorId, string deviceId,
) @safe
{
    return (() @trusted {
        try
        {
            import std.stdio : File;

            auto f = File(path, "r");
            string vendorName;
            bool inVendor = false;

            foreach (line; f.byLine)
            {
                if (line.length == 0 || line[0] == '#')
                    continue;

                // Vendor line: starts with hex digit (no leading whitespace)
                if (line[0] != '\t' && line.length >= 6)
                {
                    if (inVendor)
                    {
                        // We found the vendor but passed it without finding device
                        return ok(PciIdResult(vendorName, Nullable!string.init));
                    }

                    if (line.length >= 4 && line[0 .. 4] == vendorId[0 .. 4])
                    {
                        // Found vendor — name starts after "XXXX  "
                        vendorName = line[4 .. $].idup;
                        while (vendorName.length > 0 && vendorName[0] == ' ')
                            vendorName = vendorName[1 .. $];
                        inVendor = true;
                    }
                }
                // Device line: starts with single tab + hex
                else if (inVendor && line.length >= 7 && line[0] == '\t' && line[1] != '\t')
                {
                    if (line.length >= 5 && line[1 .. 5] == deviceId[0 .. 4])
                    {
                        string devName = line[5 .. $].idup;
                        while (devName.length > 0 && devName[0] == ' ')
                            devName = devName[1 .. $];
                        return ok(PciIdResult(vendorName, Nullable!string(devName)));
                    }
                }
            }

            if (inVendor)
                return ok(PciIdResult(vendorName, Nullable!string.init));

            return err!PciIdResult("vendor " ~ vendorId ~ " not found");
        }
        catch (Exception e)
        {
            return err!PciIdResult("failed to parse pci.ids: " ~ e.msg.idup);
        }
    })();
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("pci_ids.lookupPciId.smoke")
@safe unittest
{
    // This test will only work if pci.ids is available
    auto result = lookupPciId("1002", "164e");
    // Don't assert success — pci.ids may not be present in test env
}
