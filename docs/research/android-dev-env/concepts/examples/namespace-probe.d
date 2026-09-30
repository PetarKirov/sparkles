#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-namespace-probe"
    platforms "linux"
    targetPath "build"
+/
/**
 * Real namespace syscalls, confined to a disposable child process.
 * Evidence for ../index.md#namespaces-seccomp-and-selinux.
 * Run inside the terminal's actual session for Android app-domain evidence.
 */
module namespace_probe;

import core.sys.posix.unistd : fork, getpid, getuid, getgid, _exit;
import core.sys.posix.sys.wait : waitpid;
import core.stdc.errno : errno;
import std.stdio : writeln, stdout;
import std.file : readText, readLink;
import std.string : splitLines, startsWith;
import std.exception : enforce;

extern(C) int unshare(int flags);

void main()
{
    writeln("uid=", getuid(), " gid=", getgid());
    foreach (line; readText("/proc/self/status").splitLines)
        if (line.startsWith("Seccomp:") || line.startsWith("NoNewPrivs:") || line.startsWith("CapEff:"))
            writeln(line);
    try
        writeln("LSM context: ", readText("/proc/self/attr/current"));
    catch (Exception e)
        writeln("LSM context unavailable: ", e.msg);
    const original = readLink("/proc/self/ns/mnt");
    writeln("parent mount namespace: ", original);
    stdout.flush();
    const child = fork();
    enforce(child >= 0, "fork failed");
    if (child == 0)
    {
        // CLONE_NEWUSER | CLONE_NEWNS. No mounts and no parent state changes.
        const result = unshare(0x10000000 | 0x00020000);
        const error = errno;
        if (result == 0)
        {
            const current = readLink("/proc/self/ns/mnt");
            enforce(current != original, "unshare did not create a distinct mount namespace");
            writeln("child mount namespace: ", current);
            writeln("PASS: unshare succeeded; mount/store access still needs separate validation");
        }
        else
            writeln("SKIP: unshare(CLONE_NEWUSER|CLONE_NEWNS) errno=", error,
                " (does not identify which kernel/security gate rejected it)");
        stdout.flush();
        _exit(0);
    }
    int status;
    enforce(waitpid(child, &status, 0) == child && status == 0, "namespace child failed");
    enforce(readLink("/proc/self/ns/mnt") == original, "parent namespace changed");
    writeln("PASS: parent namespace unchanged");
}
