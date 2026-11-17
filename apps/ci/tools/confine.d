/**
Runs a program confined, for the build graph's isolation spike (D39): its
writes go only beneath the directories `--write` names (and to `/dev`, for
`/dev/null`), through Landlock, and with `--no-network` it runs in a network
namespace of its own, which holds only a loopback interface that is down.
Reads are not restricted: manifests record them.

    confine [--write=<dir>]... [--no-network] -- <program> <argument>...

`<program>` is a path; nothing is searched for. A write outside the
directories fails with `EACCES` in the program, which reports it as its own
error. Exits 125 when it cannot confine (a kernel without Landlock, or one
that refuses an unprivileged user namespace), so a caller tells that apart
from the program's own failures.

Linux only, and Phobos only: the build graph builds it with the compiler it
builds with.
*/
module confine;

version (linux):

import core.stdc.errno : errno;
import core.stdc.stdio : fprintf, stderr;
import core.sys.linux.sched : CLONE_NEWNET, CLONE_NEWUSER, unshare;
import core.sys.posix.fcntl : O_CLOEXEC, O_RDONLY, open;
import core.sys.posix.unistd : close, execv, getgid, getuid;
import std.string : toStringz;

extern (C) long syscall(long number, ...) nothrow @nogc;
extern (C) int prctl(int option, ulong arg2, ulong arg3, ulong arg4, ulong arg5) nothrow @nogc;

enum sysLandlockCreateRuleset = 444;
enum sysLandlockAddRule = 445;
enum sysLandlockRestrictSelf = 446;
enum landlockCreateRulesetVersion = 1;
enum landlockRulePathBeneath = 1;
enum prSetNoNewPrivs = 38;
enum oPath = 0x200000; // O_PATH

// The filesystem rights that change the tree, by the ABI that adds them.
enum ulong accessWriteFile = 1 << 1, accessRemoveDir = 1 << 4, accessRemoveFile = 1 << 5,
    accessMakeChar = 1 << 6, accessMakeDir = 1 << 7, accessMakeReg = 1 << 8, accessMakeSock = 1 << 9,
    accessMakeFifo = 1 << 10, accessMakeBlock = 1 << 11, accessMakeSym = 1 << 12, accessRefer = 1 << 13,
    accessTruncate = 1 << 14;

struct RulesetAttr
{
    ulong handledAccessFs;
}

align(1) struct PathBeneathAttr
{
align(1):
    ulong allowedAccess;
    int parentFd;
}

int main(string[] args)
{
    string[] writable;
    bool noNetwork;
    size_t at = 1;
    for (; at < args.length && args[at] != "--"; ++at)
    {
        if (args[at].length > 8 && args[at][0 .. 8] == "--write=")
            writable ~= args[at][8 .. $];
        else if (args[at] == "--no-network")
            noNetwork = true;
        else
            return fail("unknown option " ~ args[at]);
    }
    if (at + 1 >= args.length)
        return fail("no program after --");
    const program = args[at + 1 .. $];

    if (noNetwork)
    {
        // A user namespace lets an unprivileged process own the network one;
        // the user keeps its own ids inside it.
        const uid = getuid(), gid = getgid();
        if (unshare(CLONE_NEWUSER | CLONE_NEWNET) != 0)
            return cannot("unshare(CLONE_NEWUSER | CLONE_NEWNET)");
        import std.conv : text;
        import std.file : write;

        try
        {
            write("/proc/self/setgroups", "deny");
            write("/proc/self/uid_map", text(uid, " ", uid, " 1"));
            write("/proc/self/gid_map", text(gid, " ", gid, " 1"));
        }
        catch (Exception e)
            return cannot("map the user's ids: " ~ e.msg);
    }

    const abi = syscall(sysLandlockCreateRuleset, null, 0, landlockCreateRulesetVersion);
    if (abi < 1)
        return cannot("Landlock");
    ulong handled = accessWriteFile | accessRemoveDir | accessRemoveFile | accessMakeChar | accessMakeDir
        | accessMakeReg | accessMakeSock | accessMakeFifo | accessMakeBlock | accessMakeSym;
    if (abi >= 2)
        handled |= accessRefer;
    if (abi >= 3)
        handled |= accessTruncate;
    auto attr = RulesetAttr(handled);
    const ruleset = cast(int) syscall(sysLandlockCreateRuleset, &attr, RulesetAttr.sizeof, 0);
    if (ruleset < 0)
        return cannot("landlock_create_ruleset");
    bool allow(string path, ulong rights)
    {
        const fd = open(path.toStringz, oPath | O_CLOEXEC);
        if (fd < 0)
            return false;
        auto beneath = PathBeneathAttr(rights & handled, fd);
        const ok = syscall(sysLandlockAddRule, ruleset, landlockRulePathBeneath, &beneath, 0) == 0;
        close(fd);
        return ok;
    }
    foreach (dir; writable)
        if (!allow(dir, handled))
            return cannot("allow writes beneath " ~ dir);
    cast(void) allow("/dev", accessWriteFile | accessTruncate);
    if (prctl(prSetNoNewPrivs, 1, 0, 0, 0) != 0)
        return cannot("PR_SET_NO_NEW_PRIVS");
    if (syscall(sysLandlockRestrictSelf, ruleset, 0) != 0)
        return cannot("landlock_restrict_self");
    close(ruleset);

    const(char)*[] argv;
    foreach (a; program)
        argv ~= a.toStringz;
    argv ~= null;
    execv(argv[0], argv.ptr);
    return cannot("execute " ~ program[0]);
}

int fail(string why)
{
    fprintf(stderr, "confine: %.*s\n", cast(int) why.length, why.ptr);
    return 2;
}

int cannot(string what)
{
    import core.stdc.string : strerror;

    const e = errno;
    fprintf(stderr, "confine: cannot %.*s: %s\n", cast(int) what.length, what.ptr, strerror(e));
    return 125;
}
