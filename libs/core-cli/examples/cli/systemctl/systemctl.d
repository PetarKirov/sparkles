#!/usr/bin/env dub
/+ dub.sdl:
    name "systemctl"
    dependency "sparkles:core-cli" path="../../../../.."
    targetPath "build"
+/
// ci: build-only

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import std.sumtype;

private enum string[] unitTypes = [
    "service", "socket", "target", "device", "mount", "automount",
    "swap", "timer", "path", "slice", "scope", "snapshot",
];

@(Command("start")
    .shortDescription("Start (activate) one or more units")
    .helpSections!("description")())
struct Start
{
    @(Option(`no-block`, "Do not synchronously wait for the requested operation to finish"))
    bool noBlock;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl start with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("stop")
    .shortDescription("Stop (deactivate) one or more units")
    .helpSections!("description")())
struct Stop
{
    @(Option(`no-block`, "Do not synchronously wait for the requested operation to finish"))
    bool noBlock;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl stop with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("restart")
    .shortDescription("Start or restart one or more units")
    .helpSections!("description")())
struct Restart
{
    @(Option(`no-block`, "Do not synchronously wait for the requested operation to finish"))
    bool noBlock;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl restart with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("reload")
    .shortDescription("Reload one or more units")
    .helpSections!("description")())
struct Reload
{
    @(Option(`no-block`, "Do not synchronously wait for the requested operation to finish"))
    bool noBlock;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl reload with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("enable")
    .shortDescription("Enable one or more unit files")
    .helpSections!("description")())
struct Enable
{
    @(Option(`now`, "Start the unit(s) immediately after enabling them"))
    bool now;

    @(Option(`runtime`, "Make changes only temporarily, lost on the next reboot"))
    bool runtime;

    @(Option(`force`, "When linking unit files, override existing symlinks"))
    bool force;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl enable with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("disable")
    .shortDescription("Disable one or more unit files")
    .helpSections!("description")())
struct Disable
{
    @(Option(`now`, "Stop the unit(s) immediately after disabling them"))
    bool now;

    @(Option(`runtime`, "Make changes only temporarily, lost on the next reboot"))
    bool runtime;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl disable with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("mask")
    .shortDescription("Mask one or more units, rendering them impossible to start")
    .helpSections!("description")())
struct Mask
{
    @(Option(`now`, "Stop the unit(s) immediately after masking them"))
    bool now;

    @(Option(`runtime`, "Make changes only temporarily, lost on the next reboot"))
    bool runtime;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl mask with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("unmask")
    .shortDescription("Unmask one or more units, allowing them to be started again")
    .helpSections!("description")())
struct Unmask
{
    @(Option(`runtime`, "Make changes only temporarily, lost on the next reboot"))
    bool runtime;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl unmask with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("status")
    .shortDescription("Show runtime status of one or more units")
    .helpSections!("description")())
struct Status
{
    @(Option(`l|full`, "Don't ellipsize unit names or process trees"))
    bool full;

    @(Option(`n|lines`, "Number of journal lines to show"))
    int lines = 10;

    @(Option(`no-pager`, "Do not pipe output into a pager"))
    bool noPager;

    @(Argument("units").optional())
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl status with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("is-active")
    .shortDescription("Check whether units are active")
    .helpSections!("description")())
struct IsActive
{
    @(Option(`q|quiet`, "Suppress textual output, only signal via exit code"))
    bool quiet;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl is-active with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("is-enabled")
    .shortDescription("Check whether unit files are enabled in the system")
    .helpSections!("description")())
struct IsEnabled
{
    @(Option(`q|quiet`, "Suppress textual output, only signal via exit code"))
    bool quiet;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl is-enabled with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("list-units")
    .shortDescription("List units currently in memory")
    .helpSections!("description")())
struct ListUnits
{
    @(Option(`a|all`, "Show all loaded units regardless of state"))
    bool all;

    @(Option(`reverse`, "Show reverse dependencies"))
    bool reverse;

    @(Argument("patterns").optional())
    string[] patterns;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl list-units with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("list-unit-files")
    .shortDescription("List installed unit files")
    .helpSections!("description")())
struct ListUnitFiles
{
    @(Option(`a|all`, "Show all unit files regardless of enabled-state"))
    bool all;

    @(Argument("patterns").optional())
    string[] patterns;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl list-unit-files with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("daemon-reload")
    .shortDescription("Reload systemd manager configuration")
    .helpSections!("description")())
struct DaemonReload
{
    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl daemon-reload with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("cat")
    .shortDescription("Show files and drop-ins of specified units")
    .helpSections!("description")())
struct Cat
{
    @(Option(`no-pager`, "Do not pipe output into a pager"))
    bool noPager;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl cat with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("show")
    .shortDescription("Show properties of one or more units, jobs, or the manager itself")
    .helpSections!("description")())
struct Show
{
    @(Option(`p|property`, "Show only properties matching the given name. Can be specified multiple times."))
    string[] properties;

    @(Option(`a|all`, "Show all properties, including those with empty values"))
    bool all;

    @(Option(`value`, "Print only the property values, omitting names"))
    bool value;

    @(Argument("units").optional())
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl show with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("edit")
    .shortDescription("Edit one or more unit files")
    .helpSections!("description")())
struct Edit
{
    @(Option(`full`, "Edit the full unit file rather than creating an override drop-in"))
    bool full;

    @(Option(`force`, "Create the unit file even if it does not exist"))
    bool force;

    @(Option(`runtime`, "Apply edits only at runtime, lost on the next reboot"))
    bool runtime;

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl edit with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("kill")
    .shortDescription("Send a signal to processes of a unit")
    .helpSections!("description")())
struct Kill
{
    @(Option(`s|signal`, "Signal name to send (default: SIGTERM)"))
    string signal = "SIGTERM";

    @(Option(`kill-whom`).allowedValues("main", "control", "all"))
    string killWhom = "all";

    @(Argument("units"))
    string[] units;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running systemctl kill with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("systemctl")
    .shortDescription("Control the systemd system and service manager")
    .helpSections!("description", "examples")())
struct Systemctl
{
    @(Option(`system`, "Operate on the system service manager (the default when run as root)"))
    bool system_;

    @(Option(`user`, "Operate on the user service manager of the calling user"))
    bool user;

    @(Option(`global`, "Operate on the global default user-unit configuration"))
    bool global;

    @(Option(`t|type`).allowedValues(unitTypes))
    string type;

    @(Option(`state`, "Filter units by load/sub/active state, e.g. 'failed' or 'active,running'"))
    string state;

    @(Option(`no-pager`, "Do not pipe output into a pager"))
    bool noPager;

    @(Option(`no-block`, "Do not synchronously wait for the requested operation to finish"))
    bool noBlock;

    @(Option(`q|quiet`, "Suppress informational output, only print errors"))
    bool quiet;

    @(Option(`v|verbose`).counter())
    uint verbose;

    @Subcommands
    SumType!(
        Cat,
        DaemonReload,
        Disable,
        Edit,
        Enable,
        IsActive,
        IsEnabled,
        Kill,
        ListUnitFiles,
        ListUnits,
        Mask,
        Reload,
        Restart,
        Show,
        Start,
        Status,
        Stop,
        Unmask,
    ) command;
}

int main(string[] args)
{
    return runCli!Systemctl(args, HelpInfo("systemctl", "Control the systemd system and service manager"));
}
