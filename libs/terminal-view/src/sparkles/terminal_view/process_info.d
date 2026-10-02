/**
What runs in the foreground of a pane (`TPR3`, `TPG9`): the pty's foreground
process group, its leader's executable name, and the Nerd Font icon a tab
shows for it when the program set none (OSC 1, [D21]).

The icon table is small and hand-picked: the code points were read from
Nerd Fonts 3.4.0's `glyphnames.json` (the names are kept beside each entry).
The generated `nf-*` table the design system owns ([`GLY4`]) replaces it
once it exists.
*/
module sparkles.terminal_view.process_info;

import core.sys.posix.sys.types : pid_t;

/**
The leader of the pty's foreground process group — the program the user is
talking to (`vim`, not the shell that launched it) — or `-1` when there is
none (`tcgetpgrp` failed: the pty is closed, or nothing holds its slave).
*/
pid_t foregroundProcess(int ptyFd) @system nothrow @nogc
{
    import core.sys.posix.unistd : tcgetpgrp;

    if (ptyFd < 0)
        return -1;
    const pgrp = tcgetpgrp(ptyFd);
    return pgrp > 0 ? pgrp : -1;
}

/// How the program on a pty reads its input (`ptyReading`).
enum PtyReading : ubyte
{
    unknown, /// the modes could not be read (no pty, or the call is refused)
    echoing, /// line by line, echoed: a shell's plain `read`, `cat`
    password, /// line by line, not echoed: `sudo`, `ssh`, `gpg` asking for a secret
    raw, /// character by character: a line editor, a full-screen program
}

/**
How the program on the pty `ptyFd` reads its input, from the line discipline's
modes (`tcgetattr` on the master reads the pair's modes, which the program
sets on its slave): canonical mode with echo off is a password prompt
(`TSE10`). A shell at its prompt reads raw (its line editor echoes itself).
*/
PtyReading ptyReading(int ptyFd) @system nothrow @nogc
{
    if (ptyFd < 0)
        return PtyReading.unknown;
    version (CRuntime_Bionic)
    {
        // druntime declares no termios functions for Bionic; `tcgetattr` is
        // this ioctl there. The kernel's `struct termios` starts with four
        // `tcflag_t` (uint) words, `c_lflag` the fourth.
        import core.sys.posix.sys.ioctl : ioctl;

        enum TCGETS = 0x5401, ECHO = 0x8, ICANON = 0x2;
        uint[16] t; // 4 words + c_line + c_cc[19], with room to spare
        if (ioctl(ptyFd, TCGETS, t.ptr) != 0)
            return PtyReading.unknown;
        const lflag = t[3];
    }
    else
    {
        import core.sys.posix.termios : ECHO, ICANON, tcgetattr, termios;

        termios t;
        if (tcgetattr(ptyFd, &t) != 0)
            return PtyReading.unknown;
        const lflag = t.c_lflag;
    }
    if (!(lflag & ICANON))
        return PtyReading.raw;
    return lflag & ECHO ? PtyReading.echoing : PtyReading.password;
}

///
@("process_info.ptyReading.seesTheSlavesModesThroughTheMaster")
@system unittest
{
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
    import core.sys.posix.termios : ECHO, ICANON, tcgetattr, tcsetattr, TCSANOW, termios;
    import core.sys.posix.unistd : close;
    import sparkles.terminal_view.protocol_oracle : openTestPty;

    char[128] slaveName = 0;
    const master = openTestPty(slaveName);
    scope (exit) close(master);
    const slave = open(slaveName.ptr, O_RDWR | O_NOCTTY);
    assert(slave >= 0);
    scope (exit) close(slave);

    void set(bool echo, bool canonical)
    {
        termios t;
        assert(tcgetattr(slave, &t) == 0);
        t.c_lflag = echo ? t.c_lflag | ECHO : t.c_lflag & ~ECHO;
        t.c_lflag = canonical ? t.c_lflag | ICANON : t.c_lflag & ~ICANON;
        assert(tcsetattr(slave, TCSANOW, &t) == 0);
    }

    // What `stty -echo` / `sudo` sets on its side, read from ours.
    set(echo: true, canonical: true);
    assert(ptyReading(master) == PtyReading.echoing);
    set(echo: false, canonical: true);
    assert(ptyReading(master) == PtyReading.password);
    set(echo: false, canonical: false);
    assert(ptyReading(master) == PtyReading.raw);
    assert(ptyReading(-1) == PtyReading.unknown);
}

/**
The executable name of `pid` (its `comm`: at most 15 bytes on Linux, 32 on
macOS), written to `dst`; returns its length, `0` when unknown.
*/
size_t processName(pid_t pid, ref char[64] dst) @system nothrow @nogc
{
    if (pid <= 0)
        return 0;
    version (OSX)
    {
        extern (C) int proc_name(int pid, void* buffer, uint size) nothrow @nogc;

        const n = proc_name(pid, dst.ptr, cast(uint) dst.length);
        return n > 0 ? cast(size_t) n : 0;
    }
    else version (linux)
    {
        import core.stdc.stdio : snprintf;
        import core.sys.posix.fcntl : O_RDONLY, open;
        import core.sys.posix.unistd : close, read;

        char[32] path;
        snprintf(path.ptr, path.length, "/proc/%d/comm", pid);
        const fd = open(path.ptr, O_RDONLY);
        if (fd < 0)
            return 0;
        scope (exit) close(fd);
        const n = read(fd, dst.ptr, dst.length);
        if (n <= 0)
            return 0;
        size_t len = cast(size_t) n;
        while (len > 0 && (dst[len - 1] == '\n' || dst[len - 1] == '\0'))
            --len;
        return len;
    }
    else
        return 0;
}

/// The generic terminal glyph (`nf-dev-terminal`, U+E795).
enum string genericTerminalIcon = "";

private struct IconEntry
{
    string process;
    string icon;
}

// Nerd Fonts 3.4.0 glyphnames.json; the name follows each code point.
private static immutable IconEntry[] iconTable = [
    IconEntry("vim", ""),      // custom-vim
    IconEntry("vi", ""),       // custom-vim
    IconEntry("nvim", ""),     // custom-neovim
    IconEntry("emacs", ""),    // custom-emacs
    IconEntry("git", ""),      // dev-git
    IconEntry("lazygit", ""),  // dev-git
    IconEntry("python", ""),   // dev-python
    IconEntry("python3", ""),  // dev-python
    IconEntry("node", ""),     // dev-nodejs_small
    IconEntry("cargo", ""),    // dev-rust
    IconEntry("rustc", ""),    // dev-rust
    IconEntry("docker", ""),   // dev-docker
    IconEntry("go", ""),       // dev-go
    IconEntry("lua", ""),      // dev-lua
    IconEntry("ruby", ""),     // dev-ruby
    IconEntry("java", ""),     // dev-java
    IconEntry("man", ""),      // fa-book
    IconEntry("less", ""),     // fa-book
    IconEntry("ssh", "\U000F08C0"),  // md-ssh
    IconEntry("mosh", "\U000F08C0"), // md-ssh
    IconEntry("htop", "\U000F0379"), // md-monitor
    IconEntry("btop", "\U000F0379"), // md-monitor
    IconEntry("top", "\U000F0379"),  // md-monitor
    IconEntry("psql", ""),     // fa-database
    IconEntry("sqlite3", ""),  // fa-database
];

/**
The icon a tab shows for a pane running `process` (`TPR3`): the table's
entry, else the generic terminal glyph; with no Nerd Font on the target
(`nerdFont` false, [`CAP`]), no icon at all — the private-use code points
would draw as tofu.
*/
string iconForProcess(scope const(char)[] process, bool nerdFont) @safe pure nothrow @nogc
{
    if (!nerdFont)
        return null;
    foreach (e; iconTable)
        if (e.process == process)
            return e.icon;
    return genericTerminalIcon;
}

///
@("process_info.iconForProcess")
@safe pure nothrow @nogc unittest
{
    assert(iconForProcess("nvim", true) == "");
    assert(iconForProcess("git", true) == "");
    assert(iconForProcess("bash", true) == genericTerminalIcon);
    assert(iconForProcess("", true) == genericTerminalIcon);
    assert(iconForProcess("nvim", false) is null);
}

@("process_info.foregroundProcess.namesTheForegroundChild")
@system unittest
{
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : _exit, close, execvp, setsid;
    import core.sys.posix.sys.ioctl : ioctl, TIOCSCTTY;
    import core.sys.posix.fcntl : O_RDWR, open;
    import core.thread : Thread;
    import core.time : msecs;
    import sparkles.terminal_view.protocol_oracle : openTestPty;

    // A real session on a fresh pty: `sleep` becomes its foreground group,
    // and the master names it.
    char[128] slaveName = 0;
    const master = openTestPty(slaveName);
    scope (exit) close(master);

    static immutable(char)*[3] argv = ["sleep", "5", null];
    import core.sys.posix.unistd : fork;

    const child = fork();
    assert(child >= 0);
    if (child == 0)
    {
        setsid();
        const slave = open(slaveName.ptr, O_RDWR);
        ioctl(slave, TIOCSCTTY, 0);
        execvp("sleep", cast(char**) argv.ptr);
        _exit(127);
    }
    scope (exit)
    {
        kill(child, SIGKILL);
        waitpid(child, null, 0);
    }

    pid_t fg = -1;
    char[64] name;
    size_t len;
    foreach (_; 0 .. 200)
    {
        fg = foregroundProcess(master);
        len = processName(fg, name);
        if (len && name[0 .. len] == "sleep")
            break;
        Thread.sleep(5.msecs);
    }
    assert(fg == child, "the session leader leads the foreground group");
    assert(name[0 .. len] == "sleep");
    assert(foregroundProcess(-1) == -1);
}
