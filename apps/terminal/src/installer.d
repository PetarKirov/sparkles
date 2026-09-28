/**
The nix-on-droid bootstrap installer (docs/specs/terminal/android.md, `D4`,
`NOD5`, `NOD6`): a line-mode program that runs on a thread of the app, talking
to the terminal through the $(I slave) side of a pty whose master the
terminal pane adopted. Prompts, the URL answer and the progress are terminal
text; the answer is edited with the tty's own line discipline (canonical
mode, the pty default). When it returns, the caller closes the slave — the
pane sees the session end, and the login session replaces it.

The download is injected (`fetch`): `sparkles.android.http.download` on the
device, a fixture writer in the host test below — which drives this whole
program through a real pty.
*/
module installer;

import session : bootstrapArch, bootstrapZipUrl, SessionPaths;

/// Download `url` to `dest`, reporting progress; `null` or the failure.
alias Fetch = string delegate(string url, string dest,
    scope void delegate(long got, long total) nothrow progress);

/// The prompt the Termux installer's dialog carried; kept, so a test (or a
/// user) that knew the old app finds the same words.
enum promptTitle = "Bootstrap zipball location";

/**
Run the installer on `tty` until the prefix is installed (returns `true`) or
the tty closes under it (`false`: the app is going away). Every failure —
a bad URL, a failed download, a broken archive — is printed and the prompt
comes back; nothing is left half-installed (`NOD6`).
*/
bool runInstaller(int tty, const SessionPaths paths, string defaultUrl, scope Fetch fetch)
{
    import std.file : exists, mkdirRecurse, remove, rename, rmdirRecurse;
    import std.path : buildPath;
    import std.string : strip;

    import bootstrap_zip : extractBootstrap;

    say(tty, "\x1b[1mnix-on-droid\x1b[0m — first start: installing the bootstrap.\n\n");
    for (;;)
    {
        say(tty, promptTitle ~ " [" ~ defaultUrl ~ "]:\n> ");
        string line;
        if (!readLine(tty, line))
            return false;
        const answer = line.strip;
        const base = answer.length ? answer : defaultUrl;
        if (base.length == 0)
        {
            say(tty, "A URL is required.\n\n");
            continue;
        }

        const arch = bootstrapArch();
        const url = bootstrapZipUrl(base, arch);
        const zipPath = buildPath(paths.files, "bootstrap-" ~ arch ~ ".zip");
        say(tty, "Downloading " ~ url ~ "\n");
        auto meter = ProgressMeter(tty);
        const fetchErr = fetch(url, zipPath, (long got, long total) nothrow {
            meter.bytes(got, total);
        });
        say(tty, "\n");
        if (fetchErr !is null)
        {
            say(tty, "\x1b[31mDownload failed:\x1b[0m " ~ fetchErr ~ "\n\n");
            continue;
        }

        say(tty, "Extracting\n");
        const extractErr = extractBootstrap(zipPath, paths.staging,
            (size_t done, size_t total) nothrow { meter.items(done, total); });
        say(tty, "\n");
        try
            remove(zipPath);
        catch (Exception) {}
        if (extractErr !is null)
        {
            say(tty, "\x1b[31mExtraction failed:\x1b[0m " ~ extractErr ~ "\n\n");
            continue;
        }

        try
        {
            // An empty prefix dir (a previous attempt's, or the user's) is
            // not an installation; the staged tree replaces it whole.
            if (paths.prefix.exists)
                rmdirRecurse(paths.prefix);
            rename(paths.staging, paths.prefix);
            mkdirRecurse(paths.tmp);
        }
        catch (Exception e)
        {
            say(tty, "\x1b[31mInstallation failed:\x1b[0m " ~ e.msg ~ "\n\n");
            continue;
        }
        say(tty, "Installed. Starting nix-on-droid…\n");
        return true;
    }
}

/// Write all of `text` to `fd`; errors are ignored (a closed tty ends the
/// installer at its next read).
private void say(int fd, scope const(char)[] text) nothrow @nogc
{
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.unistd : write;

    while (text.length)
    {
        const n = write(fd, text.ptr, text.length);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return;
        text = text[n .. $];
    }
}

/// One line from the tty (canonical mode delivers whole lines); `false` on
/// EOF or error. The newline is not part of `line`.
private bool readLine(int fd, out string line)
{
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.unistd : read;

    char[] buf;
    char[256] chunk = void;
    for (;;)
    {
        const n = read(fd, chunk.ptr, chunk.length);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        foreach (i, c; chunk[0 .. n])
            if (c == '\n' || c == '\r')
            {
                buf ~= chunk[0 .. i];
                line = buf.idup;
                return true;
            }
        buf ~= chunk[0 .. n];
    }
}

/// A single self-overwriting progress line (`\r`), redrawn at most every
/// 1 % so a fast download does not flood the terminal.
private struct ProgressMeter
{
    int fd;
    private long lastPermille = -1;

    void bytes(long got, long total) nothrow
    {
        const permille = total > 0 ? got * 1000 / total : got >> 20;
        if (permille / 10 == lastPermille / 10 && lastPermille >= 0)
            return;
        lastPermille = permille;
        char[96] buf = void;
        say(fd, total > 0
            ? fmt(buf, "\r  %.1f of %.1f MiB (%d%%)", got / 1048576.0, total / 1048576.0,
                cast(int)(permille / 10))
            : fmt(buf, "\r  %.1f MiB", got / 1048576.0, 0.0, 0));
    }

    void items(size_t done, size_t total) nothrow
    {
        const permille = total > 0 ? cast(long)(done * 1000 / total) : 0;
        if (permille / 10 == lastPermille / 10 && done != total)
            return;
        lastPermille = permille;
        char[96] buf = void;
        say(fd, fmt(buf, "\r  %d of %d files", cast(int) done, cast(int) total));
    }

    private static const(char)[] fmt(A...)(return ref char[96] buf, const(char)* f, A args) nothrow @trusted
    {
        import core.stdc.stdio : snprintf;

        const n = snprintf(buf.ptr, buf.length, f, args);
        return buf[0 .. n < 0 ? 0 : n < buf.length ? n : buf.length - 1];
    }
}

@("installer.runInstaller.installsThroughARealPty")
@system unittest
{
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
    import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
    import core.sys.posix.unistd : close, read, write;
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.zip : ArchiveMember, ZipArchive;

    const files = buildPath(tempDir, text("installer-test-", thisProcessID));
    mkdirRecurse(files);
    scope (exit) rmdirRecurse(files);
    const paths = SessionPaths(files);

    // The pty the pane would adopt: the test plays the terminal on the master.
    const master = posix_openpt(O_RDWR | O_NOCTTY);
    assert(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0);
    const slave = open(ptsname(master), O_RDWR | O_NOCTTY);
    assert(slave >= 0);
    scope (exit) close(master);

    string[] fetched;
    int calls;
    Fetch fetch = (string url, string dest, scope void delegate(long, long) nothrow progress) {
        fetched ~= url;
        if (++calls == 1)
            return "HTTP 404"; // the first answer is wrong: the prompt returns
        auto zip = new ZipArchive;
        foreach (e; [["bin/login", "#!/system/bin/sh\n"], ["EXECUTABLES.txt", "bin/login\n"],
                ["SYMLINKS.txt", "/nix/store/x-bash/bin/sh←bin/sh\n"]])
        {
            auto m = new ArchiveMember;
            m.name = e[0];
            m.expandedData(cast(ubyte[]) e[1].dup);
            zip.addMember(m);
        }
        import std.file : write;

        write(dest, zip.build());
        progress(10, 10);
        return null;
    };

    bool installed;
    auto t = new Thread({
        installed = runInstaller(slave, paths, "https://default/boot", fetch);
        close(slave);
    });
    t.start();

    // Answer the first prompt with a typo'd URL, the second with Enter (the
    // default) — typed on the master, as the pane's key encoder would.
    enum typo = "https://typo/boot\r";
    write(master, typo.ptr, typo.length);
    Thread.sleep(50.msecs);
    write(master, "\r".ptr, 1);
    t.join();

    string transcript;
    char[4096] buf = void;
    for (;;)
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;

        pollfd p = pollfd(master, POLLIN, 0);
        if (poll(&p, 1, 0) <= 0)
            break;
        const n = read(master, buf.ptr, buf.length);
        if (n <= 0)
            break;
        transcript ~= buf[0 .. n];
    }

    assert(installed);
    assert(fetched.length == 2);
    assert(fetched[0] == "https://typo/boot/bootstrap-" ~ bootstrapArch() ~ ".zip");
    assert(fetched[1] == "https://default/boot/bootstrap-" ~ bootstrapArch() ~ ".zip");
    assert(transcript.canFind(promptTitle), transcript);
    assert(transcript.canFind("Download failed:") && transcript.canFind("HTTP 404"), transcript);
    assert(readText(paths.login) == "#!/system/bin/sh\n");
    assert(!paths.staging.exists, "staging was renamed into place");
    assert(paths.tmp.exists);
}
