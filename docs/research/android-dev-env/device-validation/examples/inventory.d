#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-device-inventory"
    targetPath "build"
+/
/**
 * Read-only Android inventory. No implicit device selection or permission grants.
 * Evidence and interpretation: ../index.md#reproduce-the-inventory.
 * CI invokes with no arguments and gets SKIP; use --serial SERIAL --adb PATH.
 */
import std.process : execute;
import std.stdio : writeln, stderr;
import std.exception : enforce;

int main(string[] args)
{
    string serial;
    string adb = "adb";
    foreach (i; 1 .. args.length)
    {
        if (i > 1 && (args[i - 1] == "--serial" || args[i - 1] == "--adb"))
            continue;
        enforce(i + 1 < args.length, "expected --serial SERIAL or --adb PATH");
        if (args[i] == "--serial")
            serial = args[i + 1];
        else if (args[i] == "--adb")
            adb = args[i + 1];
        else
            throw new Exception("unknown argument: " ~ args[i]);
    }
    if (!serial.length)
    {
        writeln("SKIP: explicit --serial required; no Android device contacted");
        return 0;
    }
    const commands = [
        ["identity", "getprop ro.product.model; getprop ro.product.device; getprop ro.soc.model; " ~
            "getprop ro.product.cpu.abilist; getprop ro.build.version.release; getprop ro.build.version.sdk; " ~
            "getprop ro.build.fingerprint; getprop ro.build.type; uname -r"],
        ["security", "id; getenforce; getprop ro.boot.verifiedbootstate; getprop ro.boot.flash.locked; " ~
            "cat /proc/self/attr/current; grep -E 'Seccomp:|NoNewPrivs:|CapEff:' /proc/self/status"],
        ["virtualization", "pm list features | grep virtualization; " ~
            "for p in /dev/kvm /dev/gunyah /dev/gzvm /apex/com.android.virt/bin/vm " ~
            "/proc/sys/kernel/seccomp_bypass_paths /proc/sys/user/max_user_namespaces; " ~
            "do if test -e $p; then ls -l $p; else echo absent:$p; fi; done"],
        ["resources", "grep -E 'MemTotal:|MemAvailable:' /proc/meminfo; " ~
            "dumpsys battery | grep -E 'level:|temperature:|status:'; df -h /data"],
        ["applications", "pm list packages | grep -E 'sparkles|termux|virtualization|shizuku'; " ~
            "ps -A | grep -E 'sparkles|proot|nix|sshd'"],
    ];
    int failed;
    foreach (command; commands)
    {
        writeln("[", command[0], "]");
        try
        {
            const result = execute([adb, "-s", serial, "shell", command[1]]);
            writeln(result.output);
            if (result.status)
            {
                writeln("probe exit status: ", result.status);
                failed = 1;
            }
        }
        catch (Exception e)
        {
            stderr.writeln("inventory failed: ", e.msg);
            return 1;
        }
    }
    return failed;
}
