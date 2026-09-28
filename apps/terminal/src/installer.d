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

/// Copy a bootstrap the APK bundles to `dest`; `null` or the failure.
alias CopyBundled = string delegate(string dest,
    scope void delegate(long got, long total) nothrow progress);

/// The prompt the Termux installer's dialog carried; kept, so a test (or a
/// user) that knew the old app finds the same words.
enum promptTitle = "Bootstrap zipball location";

/**
Run the installer on `tty` until the prefix is installed (returns `true`) or
the tty closes under it (`false`: the app is going away). Every failure —
a bad URL, a failed download, a broken archive — is printed and the prompt
comes back; nothing is left half-installed (`NOD6`).

With `bundled` (the APK carries a bootstrap for this ABI), an empty answer
installs that one — offline, and exactly the bootstrap the APK was built
with; a typed URL still downloads.
*/
bool runInstaller(int tty, const SessionPaths paths, string defaultUrl, scope Fetch fetch,
    scope CopyBundled bundled = null)
{
    import std.file : exists, mkdirRecurse, remove, rename, rmdirRecurse;
    import std.path : buildPath;
    import std.string : strip;

    import bootstrap_zip : extractBootstrap;

    say(tty, "\x1b[1mnix-on-droid\x1b[0m — first start: installing the bootstrap.\n\n");
    for (;;)
    {
        const defaultLabel = bundled !is null ? "the bundled bootstrap" : defaultUrl;
        say(tty, promptTitle ~ " [" ~ defaultLabel ~ "]:\n> ");
        string line;
        if (!readLine(tty, line))
            return false;
        const answer = line.strip;
        const useBundled = answer.length == 0 && bundled !is null;
        const base = answer.length ? answer : defaultUrl;
        if (!useBundled && base.length == 0)
        {
            say(tty, "A URL is required.\n\n");
            continue;
        }

        const arch = bootstrapArch();
        const zipPath = buildPath(paths.files, "bootstrap-" ~ arch ~ ".zip");
        auto meter = ProgressMeter(tty);
        string fetchErr;
        if (useBundled)
        {
            say(tty, "Unpacking the bundled bootstrap\n");
            fetchErr = bundled(zipPath, (long got, long total) nothrow {
                meter.bytes(got, total);
            });
        }
        else
        {
            const url = bootstrapZipUrl(base, arch);
            say(tty, "Downloading " ~ url ~ "\n");
            fetchErr = fetch(url, zipPath, (long got, long total) nothrow {
                meter.bytes(got, total);
            });
        }
        say(tty, "\n");
        if (fetchErr !is null)
        {
            say(tty, "\x1b[31mCould not get the bootstrap:\x1b[0m " ~ fetchErr ~ "\n\n");
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

version (unittest)
{
    /// A bootstrap-shaped zip (login, lists, one symlink) at `dest`.
    private void writeFakeBootstrap(string dest) @system
    {
        import std.file : write;
        import std.zip : ArchiveMember, ZipArchive;

        auto zip = new ZipArchive;
        foreach (e; [["bin/login", "#!/system/bin/sh\n"], ["EXECUTABLES.txt", "bin/login\n"],
                ["SYMLINKS.txt", "/nix/store/x-bash/bin/sh\u2190bin/sh\n"]])
        {
            auto m = new ArchiveMember;
            m.name = e[0];
            m.expandedData(cast(ubyte[]) e[1].dup);
            zip.addMember(m);
        }
        write(dest, zip.build());
    }

    /// Run the installer on a real pty, typing `answers` on the master (one
    /// per prompt, 50 ms apart) as the pane's key encoder would; returns
    /// whether it installed, and everything it printed.
    private bool onPty(const SessionPaths paths, string defaultUrl, string[] answers,
        Fetch fetch, CopyBundled bundled, out string transcript) @system
    {
        import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
        import core.sys.posix.unistd : close, read, write;
        import core.thread : Thread;
        import core.time : MonoTime, msecs;

        const master = posix_openpt(O_RDWR | O_NOCTTY);
        assert(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0);
        const slave = open(ptsname(master), O_RDWR | O_NOCTTY);
        assert(slave >= 0);
        // The slave stays open until the transcript is read: macOS discards
        // what the master has not read once the last slave descriptor closes.
        scope (exit) close(master);
        scope (exit) close(slave);

        bool installed;
        auto t = new Thread({
            installed = runInstaller(slave, paths, defaultUrl, fetch, bundled);
        });
        t.start();

        // Read while the installer runs, so a small pty buffer never blocks it.
        char[4096] buf = void;
        bool drain(int timeoutMs)
        {
            pollfd p = pollfd(master, POLLIN, 0);
            if (poll(&p, 1, timeoutMs) <= 0 || !(p.revents & POLLIN))
                return false;
            const n = read(master, buf.ptr, buf.length);
            if (n <= 0)
                return false;
            transcript ~= buf[0 .. n];
            return true;
        }

        foreach (a; answers)
        {
            write(master, a.ptr, a.length);
            const until = MonoTime.currTime + 50.msecs;
            while (MonoTime.currTime < until)
                drain(10);
        }
        while (t.isRunning)
            drain(10);
        t.join();
        while (drain(0)) {}
        return installed;
    }

    private SessionPaths scratchPaths(string tag) @system
    {
        import std.conv : text;
        import std.file : mkdirRecurse, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        const files = buildPath(tempDir, text("installer-", tag, "-", thisProcessID));
        mkdirRecurse(files);
        return SessionPaths(files);
    }
}

@("installer.runInstaller.retriesAFailedDownloadThenTakesTheDefault")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists, readText, rmdirRecurse;

    const paths = scratchPaths("download");
    scope (exit) rmdirRecurse(paths.files);

    string[] fetched;
    Fetch fetch = (string url, string dest, scope void delegate(long, long) nothrow progress) {
        fetched ~= url;
        if (fetched.length == 1)
            return "HTTP 404"; // the first answer is wrong: the prompt returns
        writeFakeBootstrap(dest);
        progress(10, 10);
        return null;
    };

    string transcript;
    // A typo'd URL, then Enter (the default) — typed on the master, as the
    // pane's key encoder would.
    const installed = onPty(paths, "https://default/boot",
        ["https://typo/boot\r", "\r"], fetch, null, transcript);

    assert(installed);
    assert(fetched == [
        "https://typo/boot/bootstrap-" ~ bootstrapArch() ~ ".zip",
        "https://default/boot/bootstrap-" ~ bootstrapArch() ~ ".zip",
    ]);
    assert(transcript.canFind(promptTitle), transcript);
    assert(transcript.canFind("Could not get the bootstrap:") && transcript.canFind("HTTP 404"), transcript);
    assert(readText(paths.login) == "#!/system/bin/sh\n");
    assert(!paths.staging.exists, "staging was renamed into place");
    assert(paths.tmp.exists);
}

@("installer.runInstaller.enterTakesTheBundledBootstrap")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists, rmdirRecurse;

    const paths = scratchPaths("bundled");
    scope (exit) rmdirRecurse(paths.files);

    bool downloaded, copied;
    Fetch fetch = (string url, string dest, scope void delegate(long, long) nothrow progress) {
        downloaded = true;
        return "no network in this test";
    };
    CopyBundled bundled = (string dest, scope void delegate(long, long) nothrow progress) {
        copied = true;
        writeFakeBootstrap(dest);
        return null;
    };

    string transcript;
    assert(onPty(paths, "https://default/boot", ["\r"], fetch, bundled, transcript));
    assert(copied && !downloaded, "an empty answer is the bundled bootstrap");
    assert(transcript.canFind("[the bundled bootstrap]"), transcript);
    assert(paths.login.exists);
}
