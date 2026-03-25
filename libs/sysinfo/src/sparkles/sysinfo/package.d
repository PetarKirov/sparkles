module sparkles.sysinfo;

public import sparkles.sysinfo.cpu : CpuInfo;
public import sparkles.sysinfo.board : BoardInfo;
public import sparkles.sysinfo.memory : MemoryInfo, DimmInfo;
public import sparkles.sysinfo.storage : StorageDevice;
public import sparkles.sysinfo.gpu : GpuInfo;
public import sparkles.sysinfo.pci_ids : PciIdResult;

import expected : Expected, ok, err;

struct SystemInfo
{
    CpuInfo cpu;
    BoardInfo board;
    MemoryInfo memory;
    StorageDevice[] storage;
    GpuInfo[] gpus;
}

/// Gather all available system hardware information.
Expected!(SystemInfo, string) gatherSystemInfo() @safe
{
    import sparkles.sysinfo.cpu : queryCpuInfo;
    import sparkles.sysinfo.board : queryBoardInfo;
    import sparkles.sysinfo.memory : queryMemoryInfo;
    import sparkles.sysinfo.storage : queryStorageDevices;
    import sparkles.sysinfo.gpu : queryGpuInfo;

    SystemInfo info;

    auto cpu = queryCpuInfo();
    if (cpu.hasValue)
        info.cpu = cpu.value;

    auto board = queryBoardInfo();
    if (board.hasValue)
        info.board = board.value;

    auto mem = queryMemoryInfo();
    if (mem.hasValue)
        info.memory = mem.value;

    auto storage = queryStorageDevices();
    if (storage.hasValue)
        info.storage = storage.value;

    auto gpus = queryGpuInfo();
    if (gpus.hasValue)
        info.gpus = gpus.value;

    return ok(info);
}

// ─── Unit Tests ──────────────────────────────────────────────────────────────

@("sysinfo.gatherSystemInfo.smoke")
@safe unittest
{
    auto result = gatherSystemInfo();
    assert(result.hasValue);
}
