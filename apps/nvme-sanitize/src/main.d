module main;

import std.stdio : writeln, writefln, stdin, stdout;
import std.format : format;
import std.string : strip, indexOf;
import std.array : array;
import std.conv : to, ConvException;
import std.algorithm : map, filter;
import std.json : parseJSON;
import std.process : execute;

import sparkles.core_cli.ui.box : drawBox;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.ui.header : drawHeader;
import sparkles.core_cli.styled_template : styledText, styledWriteln;

import sparkles.sysinfo : SystemInfo, gatherSystemInfo;

import argparse : Command, Default, Description, NamedArgument, CLI;

// ─── Common Types ────────────────────────────────────────────────────────────

struct NvmeDevice
{
    string devicePath;
    string model;
    string serial;
    string size;
    string firmware;
}

// ─── Subcommand Argument Structs ─────────────────────────────────────────────

@(Command("wipe")
    .Description("List devices, then sanitize and format all (default)"))
struct WipeArgs
{
    @(NamedArgument(["dry-run"])
        .Description("Show what would be done without executing"))
    bool dryRun = true;

    @(NamedArgument(["force"])
        .Description("Skip confirmation prompts"))
    bool force = false;

    @(NamedArgument(["sanact"])
        .Description("Sanitize action: 1=block-erase, 2=crypto-erase, 3=overwrite. Default: auto"))
    int sanact = 0;
}

@(Command("list")
    .Description("List all NVMe devices"))
struct ListArgs {}

@(Command("sanitize")
    .Description("Sanitize NVMe device(s) (block erase / crypto erase)"))
struct SanitizeArgs
{
    @(NamedArgument(["device", "d"])
        .Description("Device path (e.g., /dev/nvme0n1). If omitted, interactive selection."))
    string device = null;

    @(NamedArgument(["all"])
        .Description("Operate on all NVMe devices (requires confirmation)"))
    bool all = false;

    @(NamedArgument(["dry-run"])
        .Description("Show what would be done without executing"))
    bool dryRun = true;

    @(NamedArgument(["force"])
        .Description("Skip confirmation prompts"))
    bool force = false;

    @(NamedArgument(["sanact"])
        .Description("Sanitize action: 1=block-erase, 2=crypto-erase, 3=overwrite. Default: auto"))
    int sanact = 0;
}

@(Command("format")
    .Description("Low-level format NVMe device(s)"))
struct FormatArgs
{
    @(NamedArgument(["device", "d"])
        .Description("Device path (e.g., /dev/nvme0n1). If omitted, interactive selection."))
    string device = null;

    @(NamedArgument(["all"])
        .Description("Operate on all NVMe devices (requires confirmation)"))
    bool all = false;

    @(NamedArgument(["dry-run"])
        .Description("Show what would be done without executing"))
    bool dryRun = true;

    @(NamedArgument(["force"])
        .Description("Skip confirmation prompts"))
    bool force = false;
}

// ─── Main ────────────────────────────────────────────────────────────────────

mixin CLI!(Default!WipeArgs, ListArgs, SanitizeArgs, FormatArgs).main!run;

int run(WipeArgs args)
{
    return cmdWipe(args);
}

int run(ListArgs)
{
    return cmdList();
}

int run(SanitizeArgs args)
{
    return cmdSanitize(args);
}

int run(FormatArgs args)
{
    return cmdFormat(args);
}

// ─── Wipe Command (Default) ─────────────────────────────────────────────────

int cmdWipe(WipeArgs args)
{
    showSystemInfo();
    writeln();

    auto devices = listNvmeDevices();
    if (devices.length == 0)
    {
        writeln(styledText(i"{yellow No NVMe devices found.}"));
        return 0;
    }

    // Show device listing
    writeln(drawHeader("NVMe Devices"));
    writeln();
    showDeviceTable(devices);

    // Confirm all devices
    if (!args.force)
    {
        writeln();
        styledWriteln(i"{red.bold WARNING: This will SANITIZE and FORMAT all $(devices.length) NVMe device(s) listed above!}");
        writeln();
        writeln(
            [
                styledText(i"{bold Step 1:} Sanitize (erase all data, including over-provisioned/unmapped areas)"),
                styledText(i"{bold Step 2:} Format (low-level format to reset LBA structure)"),
            ].drawBox("Operation Plan")
        );
        writeln();

        if (!confirm("Type 'YES' to proceed with all devices"))
        {
            styledWriteln(i"{yellow Aborted.}");
            return 0;
        }
        if (!confirm("Are you ABSOLUTELY SURE? Type 'YES' again"))
        {
            styledWriteln(i"{yellow Aborted.}");
            return 0;
        }
    }

    // Phase 1: Sanitize all devices
    writeln();
    writeln(drawHeader("Phase 1: Sanitize"));
    writeln();

    foreach (dev; devices)
    {
        showDeviceInfo(dev);

        int sanact = args.sanact;
        if (sanact == 0)
        {
            sanact = detectSanitizeAction(dev.devicePath);
            if (sanact == 0)
            {
                styledWriteln(i"{red [ERROR] Device $(dev.devicePath) does not support any sanitize action.}");
                continue;
            }
        }

        string sanactName = sanact == 2 ? "Crypto Erase" : sanact == 1 ? "Block Erase" : "Overwrite";

        if (args.dryRun)
        {
            string cmd = format!"nvme sanitize %s --sanact=%d"(dev.devicePath, sanact);
            writeln(
                [
                    styledText(i"{bold Action:}  Sanitize ($(sanactName))"),
                    styledText(i"{bold Device:}  $(dev.devicePath)"),
                    styledText(i"{bold Command:} $(cmd)"),
                ].drawBox(styledText(i"{yellow [DRY RUN]}"))
            );
            continue;
        }

        auto result = runCommand(["nvme", "sanitize", dev.devicePath, format!"--sanact=%d"(sanact)]);
        if (result.status == 0)
        {
            styledWriteln(i"{green [OK] Sanitize started on $(dev.devicePath) ($(sanactName)).}");
            styledWriteln(i"{bold Monitoring progress...}");
            monitorSanitize(dev.devicePath);
        }
        else
        {
            styledWriteln(i"{red [ERROR] Sanitize failed on $(dev.devicePath).}");
            writeln(result.output.drawBox(styledText(i"{red Error Output}")));
        }
    }

    // Phase 2: Format all devices
    writeln();
    writeln(drawHeader("Phase 2: Format"));
    writeln();

    foreach (dev; devices)
    {
        if (args.dryRun)
        {
            string cmd = format!"nvme format %s --ses=1 --force"(dev.devicePath);
            writeln(
                [
                    styledText(i"{bold Action:}  Low-level Format"),
                    styledText(i"{bold Device:}  $(dev.devicePath)"),
                    styledText(i"{bold Command:} $(cmd)"),
                ].drawBox(styledText(i"{yellow [DRY RUN]}"))
            );
            continue;
        }

        auto result = runCommand(["nvme", "format", dev.devicePath, "--ses=1", "--force"]);
        if (result.status == 0)
        {
            styledWriteln(i"{green [OK] Format completed on $(dev.devicePath).}");
        }
        else
        {
            styledWriteln(i"{red [ERROR] Format failed on $(dev.devicePath).}");
            writeln(result.output.drawBox(styledText(i"{red Error Output}")));
        }
    }

    if (!args.dryRun)
    {
        writeln();
        styledWriteln(i"{green.bold All done.}");
    }

    return 0;
}

// ─── List Command ────────────────────────────────────────────────────────────

int cmdList()
{
    showSystemInfo();
    writeln();

    auto devices = listNvmeDevices();
    if (devices.length == 0)
    {
        writeln(styledText(i"{yellow No NVMe devices found.}"));
        return 0;
    }

    writeln(drawHeader("NVMe Devices"));
    writeln();
    showDeviceTable(devices);
    return 0;
}

// ─── Sanitize Command ────────────────────────────────────────────────────────

int cmdSanitize(SanitizeArgs args)
{
    auto devices = resolveDevices(args.device, args.all);
    if (devices is null)
        return 1;

    writeln(drawHeader("NVMe Sanitize"));
    writeln();

    foreach (dev; devices)
    {
        showDeviceInfo(dev);

        int sanact = args.sanact;
        if (sanact == 0)
        {
            sanact = detectSanitizeAction(dev.devicePath);
            if (sanact == 0)
            {
                styledWriteln(i"{red [ERROR] Device $(dev.devicePath) does not support any sanitize action.}");
                continue;
            }
        }

        string sanactName = sanact == 2 ? "Crypto Erase" : sanact == 1 ? "Block Erase" : "Overwrite";

        if (args.dryRun)
        {
            string cmd = format!"nvme sanitize %s --sanact=%d"(dev.devicePath, sanact);
            writeln(
                [
                    styledText(i"{bold Action:}  Sanitize ($(sanactName))"),
                    styledText(i"{bold Device:}  $(dev.devicePath)"),
                    styledText(i"{bold Command:} $(cmd)"),
                ].drawBox(styledText(i"{yellow [DRY RUN]}"))
            );
            continue;
        }

        if (!args.force)
        {
            styledWriteln(i"{red.bold WARNING: This will PERMANENTLY ERASE ALL DATA on $(dev.devicePath)!}");
            if (!confirm(format!"Type 'YES' to confirm sanitize (%s) on %s"(sanactName, dev.devicePath)))
            {
                styledWriteln(i"{yellow Skipped $(dev.devicePath).}");
                continue;
            }
            // Double confirmation for sanitize
            if (!confirm("Are you ABSOLUTELY SURE? Type 'YES' again"))
            {
                styledWriteln(i"{yellow Skipped $(dev.devicePath).}");
                continue;
            }
        }

        auto result = runCommand(["nvme", "sanitize", dev.devicePath, format!"--sanact=%d"(sanact)]);
        if (result.status == 0)
        {
            styledWriteln(i"{green [OK] Sanitize started on $(dev.devicePath) ($(sanactName)).}");
            styledWriteln(i"{bold Monitoring progress...}");
            monitorSanitize(dev.devicePath);
        }
        else
        {
            styledWriteln(i"{red [ERROR] Sanitize failed on $(dev.devicePath).}");
            writeln(result.output.drawBox(styledText(i"{red Error Output}")));
        }
    }
    return 0;
}

// ─── Format Command ──────────────────────────────────────────────────────────

int cmdFormat(FormatArgs args)
{
    auto devices = resolveDevices(args.device, args.all);
    if (devices is null)
        return 1;

    writeln(drawHeader("NVMe Format"));
    writeln();

    foreach (dev; devices)
    {
        showDeviceInfo(dev);

        if (args.dryRun)
        {
            string cmd = format!"nvme format %s --ses=1 --force"(dev.devicePath);
            writeln(
                [
                    styledText(i"{bold Action:}  Low-level Format"),
                    styledText(i"{bold Device:}  $(dev.devicePath)"),
                    styledText(i"{bold Command:} $(cmd)"),
                ].drawBox(styledText(i"{yellow [DRY RUN]}"))
            );
            continue;
        }

        if (!args.force)
        {
            styledWriteln(i"{red.bold WARNING: This will LOW-LEVEL FORMAT $(dev.devicePath)!}");
            if (!confirm(format!"Type 'YES' to confirm format on %s"(dev.devicePath)))
            {
                styledWriteln(i"{yellow Skipped $(dev.devicePath).}");
                continue;
            }
        }

        auto result = runCommand(["nvme", "format", dev.devicePath, "--ses=1", "--force"]);
        if (result.status == 0)
        {
            styledWriteln(i"{green [OK] Format completed on $(dev.devicePath).}");
        }
        else
        {
            styledWriteln(i"{red [ERROR] Format failed on $(dev.devicePath).}");
            writeln(result.output.drawBox(styledText(i"{red Error Output}")));
        }
    }
    return 0;
}

// ─── System Info Display ─────────────────────────────────────────────────────

void showSystemInfo()
{
    import sparkles.sysinfo.memory : formatMemoryTotal;

    auto result = gatherSystemInfo();
    if (result.hasError)
        return;

    auto info = result.value;
    string[] lines;

    // Host
    if (info.board.sysVendor != "unknown" || info.board.productName != "unknown")
        lines ~= styledText(i"{bold Host}     $(info.board.sysVendor) $(info.board.productName)");

    // Board
    if (info.board.boardVendor != "unknown" || info.board.boardName != "unknown")
        lines ~= styledText(i"{bold Board}    $(info.board.boardVendor) $(info.board.boardName)");

    // CPU
    if (info.cpu.modelName.length > 0)
    {
        string cpuFreq = info.cpu.maxMhz > 0 ? format!" @ %.0f MHz"(info.cpu.maxMhz) : "";
        lines ~= styledText(
            i"{bold CPU}      $(info.cpu.modelName) ($(info.cpu.cores)C/$(info.cpu.threads)T)$(cpuFreq)"
        );
    }

    // RAM
    if (info.memory.totalKB > 0)
    {
        string memTotal = formatMemoryTotal(info.memory.totalKB);
        string memDetail;
        if (info.memory.hasDimmDetails && info.memory.dimms.length > 0)
        {
            auto dimms = info.memory.dimms;
            // Summarize: count × size type @ speed
            memDetail = format!"%d×%d GB %s @ %d MT/s"(
                dimms.length,
                dimms[0].sizeMB / 1024,
                dimms[0].memoryType,
                dimms[0].speedMTs,
            );
            memDetail = " (" ~ memDetail ~ ")";
        }
        else
        {
            memDetail = " (run as root for DIMM details)";
        }
        lines ~= styledText(i"{bold RAM}      $(memTotal)$(memDetail)");
    }

    // GPUs
    foreach (i, gpu; info.gpus)
    {
        string label = info.gpus.length == 1 ? "GPU" : format!"GPU #%d"(i + 1);
        string vram = !gpu.vramBytes.isNull
            ? format!" (%.1f GB VRAM)"(cast(double) gpu.vramBytes.get / 1_073_741_824)
            : "";
        lines ~= styledText(
            i"{bold $(label)}    $(gpu.vendorName) $(gpu.deviceName) [$(gpu.vendorId):$(gpu.deviceId)]$(vram)"
        );
    }

    // Storage devices
    uint nvmeIdx, otherIdx;
    foreach (dev; info.storage)
    {
        string label;
        string sizeStr = formatSize(cast(long) dev.sizeBytes);
        if (dev.isNvme)
        {
            nvmeIdx++;
            label = info.storage.length == 1 ? "NVMe" : format!"NVMe #%d"(nvmeIdx);
            string fw = dev.firmwareRev.length > 0 ? format!" [FW: %s]"(dev.firmwareRev) : "";
            lines ~= styledText(i"{bold $(label)}   $(dev.model) ($(sizeStr))$(fw)");
        }
        else
        {
            otherIdx++;
            label = dev.transport == "USB" ? "USB" : format!"Disk #%d"(otherIdx);
            lines ~= styledText(i"{bold $(label)}      $(dev.model) ($(sizeStr))");
        }
    }

    // BIOS
    if (info.board.biosVendor != "unknown")
    {
        lines ~= styledText(
            i"{bold BIOS}     $(info.board.biosVendor) $(info.board.biosVersion) ($(info.board.biosDate))"
        );
    }

    if (lines.length > 0)
        writeln(lines.drawBox("System Info"));
}

// ─── NVMe Device Discovery ──────────────────────────────────────────────────

NvmeDevice[] listNvmeDevices()
{
    auto result = runCommand(["nvme", "list", "-o", "json"]);
    if (result.status != 0)
    {
        styledWriteln(i"{red [ERROR] Failed to list NVMe devices.}");
        return null;
    }

    try
    {
        auto json = parseJSON(result.output);
        auto devicesJson = json["Devices"];
        NvmeDevice[] devices;

        foreach (d; devicesJson.array)
        {
            devices ~= NvmeDevice(
                d["DevicePath"].str,
                d["ModelNumber"].str.strip,
                d["SerialNumber"].str.strip,
                formatSize(d["PhysicalSize"].integer),
                d["Firmware"].str.strip,
            );
        }
        return devices;
    }
    catch (Exception e)
    {
        styledWriteln(i"{red [ERROR] Failed to parse NVMe device list: $(e.msg)}");
        return null;
    }
}

string formatSize(long bytes)
{
    if (bytes >= 1_000_000_000_000)
        return format!"%.1f TB"(cast(double) bytes / 1_000_000_000_000);
    if (bytes >= 1_000_000_000)
        return format!"%.1f GB"(cast(double) bytes / 1_000_000_000);
    if (bytes >= 1_000_000)
        return format!"%.1f MB"(cast(double) bytes / 1_000_000);
    return format!"%d B"(bytes);
}

// ─── Device Resolution ───────────────────────────────────────────────────────

NvmeDevice[] resolveDevices(string device, bool all)
{
    auto devices = listNvmeDevices();
    if (devices is null || devices.length == 0)
    {
        styledWriteln(i"{yellow No NVMe devices found.}");
        return null;
    }

    if (all)
        return devices;

    if (device !is null && device.length > 0)
    {
        auto matches = devices.filter!(d => d.devicePath == device).array;
        if (matches.length == 0)
        {
            styledWriteln(i"{red [ERROR] Device $(device) not found.}");
            return null;
        }
        return matches;
    }

    // Interactive selection
    return interactiveSelect(devices);
}

NvmeDevice[] interactiveSelect(NvmeDevice[] devices)
{
    writeln(drawHeader("Select Device"));
    writeln();

    foreach (i, dev; devices)
    {
        writefln("  %d) %s  %s  %s  %s",
            i + 1, dev.devicePath, dev.model, dev.serial, dev.size);
    }
    writeln();
    stdout.write("Enter device number: ");
    stdout.flush();

    auto line = stdin.readln();
    if (line is null)
        return null;

    try
    {
        auto idx = line.strip.to!size_t - 1;
        if (idx < devices.length)
            return [devices[idx]];
    }
    catch (ConvException)
    {
    }

    styledWriteln(i"{red Invalid selection.}");
    return null;
}

// ─── Device Display ──────────────────────────────────────────────────────────

void showDeviceTable(NvmeDevice[] devices)
{
    string[][] rows = [
        [
            styledText(i"{bold Device}"),
            styledText(i"{bold Model}"),
            styledText(i"{bold Serial}"),
            styledText(i"{bold Size}"),
            styledText(i"{bold FW Rev}"),
        ]
    ];
    foreach (dev; devices)
    {
        rows ~= [dev.devicePath, dev.model, dev.serial, dev.size, dev.firmware];
    }

    writeln(drawTable(rows));
}

void showDeviceInfo(NvmeDevice dev)
{
    writeln(
        [
            styledText(i"{bold Device:}   $(dev.devicePath)"),
            styledText(i"{bold Model:}    $(dev.model)"),
            styledText(i"{bold Serial:}   $(dev.serial)"),
            styledText(i"{bold Size:}     $(dev.size)"),
            styledText(i"{bold Firmware:} $(dev.firmware)"),
        ].drawBox("Device Info")
    );
}

// ─── Sanitize Action Detection ───────────────────────────────────────────────

/// Query the controller to determine which sanitize actions are supported.
/// Returns the best sanitize action (2=crypto-erase preferred, 1=block-erase fallback), or 0 if none.
int detectSanitizeAction(string devicePath)
{
    // Extract the controller path (e.g. /dev/nvme0) from namespace path (e.g. /dev/nvme0n1)
    string ctrlPath = devicePath;
    auto nIdx = devicePath[5 .. $].indexOf('n'); // skip "/dev/" prefix
    if (nIdx >= 0)
    {
        auto fullIdx = nIdx + 5;
        foreach (j; fullIdx .. devicePath.length)
        {
            if (devicePath[j] == 'n' && j > 5 && devicePath[j - 1] >= '0' && devicePath[j - 1] <= '9')
            {
                ctrlPath = devicePath[0 .. j];
                break;
            }
        }
    }

    auto result = runCommand(["nvme", "id-ctrl", ctrlPath, "-o", "json"]);
    if (result.status != 0)
    {
        styledWriteln(i"{yellow [INFO] Could not query controller capabilities, defaulting to block erase.}");
        return 1;
    }

    try
    {
        auto json = parseJSON(result.output);
        auto sanicap = json["sanicap"].integer;

        bool cryptoErase = (sanicap & 0x2) != 0;
        bool blockErase = (sanicap & 0x1) != 0;

        if (cryptoErase)
        {
            styledWriteln(i"{green [INFO] Device supports Crypto Erase — using it.}");
            return 2;
        }
        if (blockErase)
        {
            styledWriteln(i"{green [INFO] Device supports Block Erase — using it.}");
            return 1;
        }

        return 0;
    }
    catch (Exception e)
    {
        styledWriteln(i"{yellow [INFO] Could not parse controller capabilities: $(e.msg). Defaulting to block erase.}");
        return 1;
    }
}

// ─── Sanitize Progress Monitoring ────────────────────────────────────────────

void monitorSanitize(string devicePath)
{
    import core.thread : Thread;
    import core.time : dur;

    for (;;)
    {
        auto result = runCommand(["nvme", "sanitize-log", devicePath, "-o", "json"]);
        if (result.status != 0)
        {
            styledWriteln(i"{yellow [WARN] Could not read sanitize log.}");
            break;
        }

        try
        {
            auto json = parseJSON(result.output);
            auto progress = json["sprog"].integer;
            auto sstat = json["sstat"].integer;

            auto pct = (progress * 100) / 65535;

            auto status = sstat & 0x7;
            if (status == 0 && progress == 0)
            {
                styledWriteln(i"{green [OK] Sanitize complete.}");
                break;
            }
            else if (status == 1)
            {
                styledWriteln(i"{green [OK] Sanitize completed successfully.}");
                break;
            }
            else if (status == 2)
            {
                writefln("  Progress: %d%%", pct);
            }
            else if (status == 3)
            {
                styledWriteln(i"{red [ERROR] Sanitize failed.}");
                break;
            }
            else
            {
                writefln("  Status: %d, Progress: %d%%", status, pct);
            }
        }
        catch (Exception)
        {
            styledWriteln(i"{yellow [WARN] Could not parse sanitize log.}");
            break;
        }

        Thread.sleep(dur!"seconds"(2));
    }
}

// ─── Confirmation Prompt ─────────────────────────────────────────────────────

bool confirm(string prompt)
{
    stdout.write(prompt ~ ": ");
    stdout.flush();
    auto line = stdin.readln();
    if (line is null)
        return false;
    return line.strip == "YES";
}

// ─── Command Execution ──────────────────────────────────────────────────────

struct CmdResult
{
    int status;
    string output;
}

CmdResult runCommand(string[] args)
{
    auto result = execute(args);
    return CmdResult(result.status, result.output);
}
