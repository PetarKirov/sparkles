module sparkles.sysinfo.board;

import std.typecons : Nullable;
import expected : Expected, ok, err;

struct BoardInfo
{
    string boardVendor;
    string boardName;
    string biosVendor;
    string biosVersion;
    string biosDate;
    string sysVendor;
    string productName;
    Nullable!string boardSerial;
    Nullable!string productSerial;
}

/// Query board/BIOS info from DMI sysfs.
Expected!(BoardInfo, string) queryBoardInfo() @safe
{
    import sparkles.sysinfo.sysfs : readSysfsFile;

    enum dmiBase = "/sys/devices/virtual/dmi/id/";

    auto info = BoardInfo(
        readSysfsFile(dmiBase ~ "board_vendor").orDefault("unknown"),
        readSysfsFile(dmiBase ~ "board_name").orDefault("unknown"),
        readSysfsFile(dmiBase ~ "bios_vendor").orDefault("unknown"),
        readSysfsFile(dmiBase ~ "bios_version").orDefault("unknown"),
        readSysfsFile(dmiBase ~ "bios_date").orDefault("unknown"),
        readSysfsFile(dmiBase ~ "sys_vendor").orDefault("unknown"),
        readSysfsFile(dmiBase ~ "product_name").orDefault("unknown"),
        toNullable(readSysfsFile(dmiBase ~ "board_serial")),
        toNullable(readSysfsFile(dmiBase ~ "product_serial")),
    );

    return ok(info);
}

/// Extract the value from an Expected, or return a default.
private string orDefault(Expected!(string, string) exp, string def) @safe
{
    return exp.hasValue ? exp.value : def;
}

/// Convert an Expected to a Nullable, discarding the error.
private Nullable!string toNullable(Expected!(string, string) exp) @safe
{
    return exp.hasValue ? Nullable!string(exp.value) : Nullable!string.init;
}
