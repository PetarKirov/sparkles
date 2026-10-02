/**
The in-app `am` server (docs/specs/terminal/android.md, `NOD13`): listens on
the socket nix-on-droid's `termux-am` connects to —
`SessionPaths.amSocket`, Termux's layout unless `session.conf` says
otherwise — and answers the requests its
Android-integration tools make, natively (JNI into the framework), since this
app has no Java to run a real `am` in. Decoding is `am_command.d`'s.

Only the app's own uid (and root) can reach the socket: it lives in the app's
private data dir.
*/
module am_server;

version (Android):

import core.atomic : atomicExchange, atomicLoad, atomicStore;

import am_command;
import sparkles.base.logger : info, warning;

/// Set by `termux-reload-settings`; the frame that sees it re-reads
/// `~/.termux` ($(LREF takeReloadRequest)).
private shared bool reloadRequested;

/// Whether a settings reload was requested since the last call.
bool takeReloadRequest() @trusted nothrow @nogc => atomicExchange(&reloadRequested, false);

/// Whether `termux-open` of a file the viewer shows opens it in the app
/// (`open.target` other than `external`, `TDV1`).
private shared bool openInApp = true;

/// ditto
void setOpenInApp(bool yes) @trusted nothrow @nogc
{
    atomicStore(openInApp, yes);
}

/**
Start the server on a thread of its own, listening on `path`
(`SessionPaths.amSocket`); `false` (after a warning) when the socket cannot be
bound. `home` is where `termux-setup-storage` puts `~/storage`.
*/
bool startAmServer(string path, string home)
{
    import core.sys.posix.sys.socket : AF_UNIX, bind, listen, sockaddr, socket,
        SOCK_STREAM;
    import core.sys.posix.sys.un : sockaddr_un;
    import core.sys.posix.unistd : close, unlink;
    import core.thread : Thread;
    import std.file : mkdirRecurse;
    import std.path : dirName;
    import std.string : toStringz;

    try
        mkdirRecurse(path.dirName);
    catch (Exception e)
    {
        warning(i"am: cannot create $(path.dirName): $(e.msg)");
        return false;
    }
    unlink(path.toStringz); // a previous process's socket

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return false;
    sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    if (path.length >= addr.sun_path.length)
    {
        warning(i"am: socket path too long: $(path)");
        close(fd);
        return false;
    }
    addr.sun_path[0 .. path.length] = cast(byte[]) path;
    if (bind(fd, cast(sockaddr*) &addr, addr.sizeof) != 0 || listen(fd, 4) != 0)
    {
        warning(i"am: cannot listen on $(path)");
        close(fd);
        return false;
    }
    info(i"am: listening on $(path)");

    auto t = new Thread({ serve(fd, home); });
    t.isDaemon = true;
    t.start();
    return true;
}

private void serve(int listener, string home)
{
    import core.sys.posix.sys.socket : accept;
    import core.sys.posix.unistd : close;

    for (;;)
    {
        const conn = accept(listener, null, null);
        if (conn < 0)
            continue;
        scope (exit) close(conn);
        try
            answer(conn, home);
        catch (Exception e)
            warning(i"am: request failed: $(e.msg)");
    }
}

private void answer(int conn, string home)
{
    import core.sys.posix.sys.socket : recv;

    // The client sends one quoted command line, then shuts down writing.
    char[] request;
    char[4096] buf = void;
    for (;;)
    {
        const n = recv(conn, buf.ptr, buf.length, 0);
        if (n <= 0)
            break;
        request ~= buf[0 .. n];
        if (request.length > 64 * 1024)
            return reply(conn, 1, "", "am: request too long\n");
    }

    string[] words;
    if (!unquoteShellWords(request, words))
        return reply(conn, 1, "", "am: malformed request\n");
    const r = classify(parseAmCommand(words));
    final switch (r.kind)
    {
        case AmRequestKind.openUrl:
            import sparkles.android.intents : viewUri;

            const err = viewUri(r.target, r.mimeType, r.chooser);
            return err is null ? reply(conn, 0, "", "")
                : reply(conn, 1, "", "am: " ~ err ~ "\n");
        case AmRequestKind.openFile:
            // `TDV1`: a file the viewer shows opens in a pane beside the
            // requesting one; the rest keeps the refusal below (`NOD18`).
            if (atomicLoad(openInApp))
            {
                import open_request : awaitOpen, checkOpen, cwdOf, enqueueOpen, OpenCheck,
                    localPathOf, OpenVerdict, peerProcess;

                const pid = peerProcess(conn);
                const path = localPathOf(r.target, cwdOf(pid));
                const check = path is null ? OpenCheck.init : checkOpen(path);
                if (path !is null && check.verdict == OpenVerdict.refuse)
                    return reply(conn, 1, "", "termux-open: " ~ check.message ~ "\n");
                if (path !is null && check.verdict == OpenVerdict.open)
                {
                    string msg;
                    return awaitOpen(enqueueOpen(path, pid), msg) ? reply(conn, 0, "", "")
                        : reply(conn, 1, "", "termux-open: " ~ msg ~ "\n");
                }
            }
            return reply(conn, 1, "", "termux-open: this app has no content provider "
                ~ "(it ships no Java), so other apps cannot read files from its "
                ~ "private storage; open a URL, or copy the file to ~/storage/shared "
                ~ "first\n");
        case AmRequestKind.reloadSettings:
            atomicStore(reloadRequested, true);
            return reply(conn, 0, "", "");
        case AmRequestKind.setupStorage:
            reply(conn, 0, "", "");
            setupStorage(home);
            return;
        case AmRequestKind.wakeLock:
        case AmRequestKind.wakeUnlock:
            import sparkles.android.power : setWakeLock;

            const err = setWakeLock(r.kind == AmRequestKind.wakeLock);
            return err is null ? reply(conn, 0, "", "")
                : reply(conn, 1, "", "am: " ~ err ~ "\n");
        case AmRequestKind.shareText:
            import sparkles.android.intents : shareText;

            const err = shareText(r.target, r.subject);
            return err is null ? reply(conn, 0, "", "")
                : reply(conn, 1, "", "am: " ~ err ~ "\n");
        case AmRequestKind.unsupported:
            return reply(conn, 1, "", "am: this app answers only the requests of "
                ~ "nix-on-droid's android-integration tools (open a URL, wake lock, "
                ~ "reload settings, setup storage, share text): " ~ cast(string) request ~ "\n");
    }
}

private void reply(int conn, int code, string out_, string err)
{
    import core.sys.posix.sys.socket : send;

    const msg = amReply(code, out_, err);
    size_t sent;
    while (sent < msg.length)
    {
        const n = send(conn, msg.ptr + sent, msg.length - sent, 0);
        if (n <= 0)
            return;
        sent += n;
    }
}

/// `termux-setup-storage`: ask for the storage permission (the system dialog)
/// and, once granted, link `~/storage/{shared,downloads,…}` into it.
private void setupStorage(string home)
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : mkdirRecurse, remove, symlink;
    import std.path : buildPath;

    import sparkles.android.permissions : hasPermission, requestPermissions;
    import storage_links : storageLinks;

    static immutable perms = [
        "android.permission.READ_EXTERNAL_STORAGE",
        "android.permission.WRITE_EXTERNAL_STORAGE",
    ];
    if (!hasPermission(perms[1]))
    {
        requestPermissions(perms);
        // No callback reaches native code: poll, for as long as a person
        // reasonably takes to answer a dialog.
        foreach (_; 0 .. 240)
        {
            Thread.sleep(500.msecs);
            if (hasPermission(perms[1]))
                break;
        }
        if (!hasPermission(perms[1]))
        {
            warning(i"am: storage permission not granted");
            return;
        }
    }
    const dir = buildPath(home, "storage");
    try
    {
        mkdirRecurse(dir);
        foreach (link; storageLinks("/storage/emulated/0"))
        {
            const at = buildPath(dir, link.name);
            // Replace what a previous run left — including a dangling link,
            // which `exists` (following it) would not see.
            try
                remove(at);
            catch (Exception) {}
            symlink(link.target, at);
        }
        info(i"am: linked $(dir)");
    }
    catch (Exception e)
        warning(i"am: storage links failed: $(e.msg)");
}
