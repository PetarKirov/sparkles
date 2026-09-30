#!/usr/bin/env dub
/+ dub.sdl:
    name "android-dev-env-probe"
    platforms "linux" "osx"
    dependency "sparkles:core-cli" path="../../../../.."
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Host-side, read-only AVF/NNS evidence collector.
 * See ../contributing.md for the evidence limits and contributor agent prompt.
 * No arguments: portable CI skip, without contacting ADB.
 */
module contributor_probe;

import std.algorithm : canFind;
import std.array : split, replace;
import std.conv : to, octal;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.process : execute, Config;
import std.stdio : stderr, writeln;
import std.string : strip, splitLines, toStringz;
import std.parallelism : task;
import core.thread : Thread;
import core.time : msecs;
import core.sys.posix.sys.stat : chmod;
import sparkles.core_cli.args : Command, Option, parseCli, runParsedCli, reportCliError;
import sparkles.core_cli.term_unstyle : unstyle;
import sparkles.base.term_caps : detectTermCaps, isTerminal, StdStream;
import sparkles.core_cli.prompts : select, SelectOption, PromptPolicy, stdioPromptIo;
import sparkles.ui.components.live : stdoutLiveRegion;
import sparkles.ui.components.tasklist : TaskReporter;
import sparkles.ui.components.theme : makeTheme;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;

string quote(string value)
{
    return "'" ~ value.replace("'", "'\\''") ~ "'";
}

bool identifier(string value, bool packageName = false)
{
    if (!value.length) return false;
    foreach (c; value)
        if (!(c >= '0' && c <= '9') && !(packageName &&
            ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '_')))
            return false;
    return true;
}

struct Collector
{
    string adb, serial, directory;
    JSONValue[] records;
    string report;
    size_t failures;
    TaskReporter* tasks;

    auto host(string[] arguments)
    {
        // GNU timeout is supplied by the flake on both Linux and macOS.
        return execute(["timeout", "--signal=TERM", "--kill-after=2s", "25s", adb] ~ arguments,
            null, Config.none, 2 * 1024 * 1024);
    }

    string collect(string name, string command)
    {
        const taskId = tasks.add(name);
        tasks.start(taskId);
        int status = -1;
        string output;
        try
        {
            auto work = task(() => host(["-s", serial, "shell", command]));
            work.executeInNewThread();
            while (!work.done)
            {
                tasks.tick();
                Thread.sleep(80.msecs);
            }
            const result = work.yieldForce;
            status = result.status;
            output = result.output;
        }
        catch (Exception e) { output = "collector error: " ~ e.msg ~ "\n"; }
        const bounded = output.length >= 2 * 1024 * 1024;
        // Android proc labels can end in NUL; ADB commonly returns CRLF.
        output = output.replace("\r", "").replace("\0", "\n");
        const filename = name ~ ".txt";
        write(buildPath(directory, filename), "command: " ~ command ~ "\nexit: " ~
            status.to!string ~ "\noutput_limit_reached: " ~ bounded.to!string ~ "\n\n" ~ output);
        JSONValue[string] record;
        record["name"] = JSONValue(name);
        record["command"] = JSONValue(command);
        record["exit"] = JSONValue(status);
        record["output_limit_reached"] = JSONValue(bounded);
        record["file"] = JSONValue(filename);
        records ~= JSONValue(record);
        report ~= "| " ~ name ~ " | " ~ status.to!string ~ " | [output](./" ~ filename ~ ") |\n";
        if (status || bounded) failures++;
        if (status == 124 || status == 137 || bounded || status < 0)
            tasks.fail(taskId, "exit " ~ status.to!string ~ (bounded ? "; output bounded" : ""));
        else if (status)
            tasks.skip(taskId, "unavailable/denied; exit " ~ status.to!string ~ "; evidence saved");
        else
            tasks.succeed(taskId, "evidence saved");
        return output;
    }
}

int main(string[] args)
{
    if (args.length == 1)
    {
        writeln("SKIP: explicit --serial required; no Android device contacted");
        args ~= "--help";
    }
    try
    {
        auto parsed = parseCli!ProbeOptions(args);
        if (!parsed)
        {
            auto error = parsed.error;
            if (!isTerminal(StdStream.stdout)) error.help = error.help.unstyle;
            return reportCliError(error);
        }
        auto options = parsed.value;
        return runParsedCli(options);
    }
    catch (Exception e) { stderr.writeln("probe: ", e.msg); return 1; }
}

@(Command("android-dev-env-probe",
    shortDescription: "Collect Android AVF and NNS evidence through read-only ADB"))
struct ProbeOptions
{
    @(Option("serial", description: "Explicit authorized device serial; required for collection"))
    string serial;
    @(Option("out", description: "New local report directory (must not already exist)"))
    string directory;
    @(Option("adb", description: "ADB executable override"))
    string adb = "adb";
    @(Option("list", description: "List devices without collecting a report"))
    bool list;
    @(Option("choose", description: "Choose an online device interactively"))
    bool choose;
    @(Option("pid", description: "Inspect this active process (repeatable; maximum 32)"))
    string[] pids;
    @(Option("package", description: "Inspect this terminal package (repeatable; maximum 16)"))
    string[] packages;

    int run() { return collectDevice(this); }
}

int collectDevice(ProbeOptions options)
{
    Collector collector;
    collector.adb = options.adb;
    collector.serial = options.serial;
    collector.directory = options.directory;
    auto pids = options.pids;
    auto packages = options.packages;
    foreach (pid; pids) enforce(identifier(pid) && pid.to!ulong > 0, "invalid PID");
    foreach (packageName; packages) enforce(identifier(packageName, true), "invalid package name");
    enforce(pids.length <= 32 && packages.length <= 16, "too many process/package selectors");
    if (options.choose)
    {
        enforce(!options.list && !collector.serial.length, "--choose cannot be combined with --list or --serial");
        enforce(isTerminal(StdStream.stdin), "--choose needs a terminal; use explicit --serial for automation");
        const devices = collector.host(["devices", "-l"]);
        enforce(devices.status == 0, devices.output);
        string[] serials;
        SelectOption[] choices;
        foreach (line; devices.output.splitLines)
        {
            const fields = line.split;
            if (fields.length < 2 || fields[1] != "device") continue;
            serials ~= fields[0];
            choices ~= SelectOption(fields[0], line);
        }
        enforce(serials.length, "no authorized online devices; enable USB debugging and authorize this computer");
        auto io = stdioPromptIo();
        const picked = select("Device for AVF + NNS research", choices, 0,
            PromptPolicy.interactive, io, makeTheme(detectTermCaps()));
        enforce(!picked.hasError, picked.hasError ? picked.error : "");
        collector.serial = serials[picked.value];
    }
    if (options.list)
    {
        enforce(!collector.serial.length, "use --list separately from --serial");
        const result = collector.host(["devices", "-l"]);
        writeln(result.output);
        return result.status;
    }
    enforce(collector.serial.length && !collector.serial.canFind('\n') &&
        !collector.serial.canFind('\r'), "explicit --serial required");
    const state = collector.host(["-s", collector.serial, "get-state"]);
    enforce(state.status == 0 && state.output.strip == "device", "device is not authorized/online: " ~ state.output);
    if (!collector.directory.length)
        collector.directory = "android-dev-env-report-" ~ Clock.currTime.toUnixTime.to!string;
    enforce(!exists(collector.directory), "output directory already exists; choose a new --out directory");
    mkdirRecurse(collector.directory);
    enforce(chmod(collector.directory.toStringz, octal!"700") == 0, "cannot make report directory private");
    writeln("Android AVF + NNS research".drawHeader(HeaderProps(style: HeaderStyle.banner)));
    writeln("Read-only collection · no guest boot or policy changes · local report\n");
    auto region = stdoutLiveRegion();
    scope (exit) region.finish();
    auto tasks = TaskReporter(&region, makeTheme(detectTermCaps()));
    collector.tasks = &tasks;
    collector.report = "# Android development environment probe\n\nCollected: " ~
        Clock.currTime.toISOExtString ~ "\n\n" ~
        "Read-only root/shell ADB observations. No guests started, no permissions granted, " ~
        "no NNS launcher executed. ADB serial is deliberately omitted from report metadata. " ~
        "Outputs normalize CRLF to LF and NUL terminators to newlines; all other output is retained. " ~
        "Process observations describe existing contexts; they do not prove that an ordinary app " ~
        "can create them. Missing files, denied reads, failed commands and timeouts remain evidence.\n\n" ~
        "| Probe | Exit | Evidence |\n| --- | --- | --- |\n";

    collector.collect("identity", "for k in ro.product.model ro.product.device ro.soc.model " ~
        "ro.product.cpu.abilist ro.build.version.release ro.build.version.sdk ro.build.fingerprint " ~
        "ro.build.type ro.boot.verifiedbootstate ro.boot.flash.locked; do echo $k=$(getprop $k); done; uname -a; getconf PAGE_SIZE");
    const security = collector.collect("security", "id; getenforce; cat /proc/self/attr/current; " ~
        "grep -E '^(Uid|Gid|Cap|NoNewPrivs|Seccomp)' /proc/self/status");
    collector.collect("resources", "grep -E 'MemTotal:|MemAvailable:' /proc/meminfo; " ~
        "df -h /data; dumpsys battery | grep -E 'level:|temperature:|status:'");
    collector.collect("avf-features", "pm list features | grep -E 'virtualization|hypervisor'; " ~
        "for p in /dev/kvm /dev/gunyah /dev/gzvm /apex/com.android.virt/bin/vm " ~
        "/apex/com.android.virt/etc/fs/microdroid_kernel /apex/com.android.virt/etc/microdroid_initrd_debuggable.img; " ~
        "do ls -ldZ $p; done");
    collector.collect("avf-info", "/apex/com.android.virt/bin/vm info");
    collector.collect("avf-list", "/apex/com.android.virt/bin/vm list");
    collector.collect("avf-cli", "/apex/com.android.virt/bin/vm --help");
    collector.collect("avf-artifacts", "ls -lZ /apex/com.android.virt/etc/; sha256sum " ~
        "/apex/com.android.virt/etc/fs/microdroid_kernel " ~
        "/apex/com.android.virt/etc/microdroid_initrd_debuggable.img " ~
        "/apex/com.android.virt/etc/microdroid_initrd_normal.img");
    collector.collect("avf-permissions", "pm list permissions -f | grep -A 4 -E " ~
        "'MANAGE_VIRTUAL_MACHINE|USE_CUSTOM_VIRTUAL_MACHINE|USE_PROTECTED_VM'; " ~
        "getprop | grep -E '^\\[(ro\\.boot\\.hypervisor|ro\\.boot\\.avf|ro\\.boot\\.pvmfw|ro\\.boot\\.protected_vm|hypervisor\\.)'");
    collector.collect("kernel-config", "zcat /proc/config.gz | grep -E " ~
        "'CONFIG_(USER_NS|NAMESPACES|SECCOMP|CGROUP|FUSE|VIRTIO|KVM|GUNYAH|PROTECTED|EXT4|F2FS|OVERLAY|NET_NS|PID_NS)'");
    collector.collect("namespace-policy", "for p in /proc/sys/kernel/seccomp_bypass_paths " ~
        "/proc/sys/user/max_user_namespaces /proc/sys/user/max_mnt_namespaces; do echo $p; cat $p; done");
    collector.collect("nns-layout", "for p in /data/adb/modules/nix/module.prop " ~
        "/data/nix /data/nix/store /data/nix/bin/nix-enter /data/adb/modules/nix/bin/nix-enter " ~
        "/data/nix/lib /data/nix/etc/nix/nix.conf /data/nix/var/nix/daemon.pid " ~
        "/data/nix/var/nix/daemon-socket/socket /data/nix/var/nix/profiles/profile " ~
        "/data/nix/var/nns/runsvdir.pid /data/ve/etc; do ls -ldZ $p; done; " ~
        "cat /data/adb/modules/nix/module.prop; cat /data/nix/var/nix/daemon.pid; " ~
        "sha256sum /data/nix/bin/nix-enter /data/adb/modules/nix/bin/nix-enter");
    collector.collect("nns-config", "grep -E '^[[:space:]]*(sandbox|build-users-group|experimental-features|store)[[:space:]]*=' " ~
        "/data/nix/etc/nix/nix.conf; ls -lZ /data/nix/lib/libnns* /data/nix/bin/nns-resolver");
    const mounts = "grep -E ' / |/nix|/data/ve|/data/adb/modules/nix' ";
    collector.collect("adb-mounts", mounts ~ "/proc/self/mountinfo; " ~
        "for n in mnt user pid net; do readlink /proc/self/ns/$n; done");
    const processes = collector.collect("processes", "ps -A -o PID,UID,NAME | " ~
        "grep -E 'PID|nix|proot|virtmgr|crosvm|microdroid|runsv|sparkles|termux|shizuku'");
    foreach (line; processes.splitLines)
    {
        const fields = line.split;
        if (fields.length >= 3 && identifier(fields[0]) && !pids.canFind(fields[0]) && pids.length < 32)
            pids ~= fields[0];
    }
    foreach (packageName; packages)
    {
        collector.collect("package-" ~ packageName, "dumpsys package " ~ quote(packageName) ~
            " | grep -E 'versionCode=|versionName=|userId=|targetSdk=|MANAGE_VIRTUAL_MACHINE|USE_CUSTOM_VIRTUAL_MACHINE|USE_PROTECTED_VM'");
        const running = collector.collect("package-pids-" ~ packageName, "pidof " ~ quote(packageName));
        foreach (pid; running.split)
            if (identifier(pid) && !pids.canFind(pid) && pids.length < 32) pids ~= pid;
    }
    foreach (pid; pids)
    {
        const base = "/proc/" ~ pid;
        collector.collect("pid-" ~ pid, "cat " ~ base ~ "/comm; readlink " ~ base ~ "/exe; cat " ~
            base ~ "/attr/current; grep -E '^(Name|Uid|Gid|Cap|NoNewPrivs|Seccomp)' " ~ base ~
            "/status; for n in mnt user pid net; do readlink " ~ base ~ "/ns/$n; done; " ~
            "cat " ~ base ~ "/uid_map " ~ base ~ "/gid_map " ~ base ~ "/cgroup; " ~
            mounts ~ base ~ "/mountinfo; ls -ldZ " ~ base ~ "/root/nix/store " ~
            base ~ "/root/nix/var/nix/daemon-socket/socket");
    }
    collector.report ~= "\nRoot ADB detected: **" ~ security.canFind("uid=0(").to!string ~
        "**. Commands with nonzero status or capped output: **" ~ collector.failures.to!string ~
        "**. Pipelines and compound commands can contain earlier failed subcommands even when their " ~
        "final exit is zero; read the evidence files.\n\n" ~
        "Before publishing: inspect model/build strings, process names, mount paths and module metadata. " ~
        "No complete environment, command lines, package inventory or Nix credentials were requested. " ~
        "Mount paths may still identify applications or local directories. See the contributor guide " ~
        "for application-context tests, source provenance and the PR workflow.\n";
    write(buildPath(collector.directory, "report.md"), collector.report);
    JSONValue[string] manifest;
    manifest["schema_version"] = JSONValue(1);
    manifest["read_only"] = JSONValue(true);
    manifest["root_adb_detected"] = JSONValue(security.canFind("uid=0("));
    manifest["probes"] = JSONValue(collector.records);
    write(buildPath(collector.directory, "manifest.json"), JSONValue(manifest).toPrettyString ~ "\n");
    region.finish();
    writeln("Report: ", buildPath(collector.directory, "report.md"));
    writeln("Partial/unavailable probes are preserved; review before publishing.");
    return 0;
}
