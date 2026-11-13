/**
The Windows backend of $(D sparkles.event_horizon.tree_watch) (design
[BGW14](../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
D50): one non-recursive `ReadDirectoryChangesW` per watched directory.

Each watched directory is opened for listing with every sharing mode, so the
watch never stops anyone from renaming or removing it, and its handle is
bound to one I/O completion port. A thread of the backend's own waits on the
port, decodes each completed read into notes and arms the next read on the
same handle; the caller's thread only opens, arms and cancels.

The kernel's actions map onto $(D WatchNoteKind) as follows:

$(UL
$(LI `FILE_ACTION_ADDED` and `FILE_ACTION_RENAMED_NEW_NAME`: `created`;)
$(LI `FILE_ACTION_REMOVED` and `FILE_ACTION_RENAMED_OLD_NAME`: `removed`;)
$(LI `FILE_ACTION_MODIFIED`: `modified`;)
$(LI a read that completes empty (the kernel's buffer for the handle
    overflowed) or with `ERROR_NOTIFY_ENUM_DIR`: `overflow`;)
$(LI a read that fails for any other reason the caller did not cause (the
    directory was removed, `ERROR_ACCESS_DENIED`; its handle was cleaned
    up, `ERROR_NOTIFY_CLEANUP`; a volume went away), or a read that cannot be
    armed again: `lost`.)
)

A `created` note says `isDir` when the name, looked up with
`GetFileAttributesW` as the note is decoded, is a directory that is not a
reparse point; the lookup is one call that touches no handle. It is false
for a name gone by then, for a symbolic link or junction (as inotify says of
a symbolic link), and for every `removed` or `modified` note, whose name
Windows does not describe.

$(B A watched directory that is renamed or moved) goes on being watched
under its new name: Windows reports nothing on the directory's own handle,
so this backend gives no `lost` for it. The caller learns of it through the
watch on the parent, which sees the name `removed`; BGW14 has a watch of a
set watch every directory it lists, the parent included, and a watched
directory whose name is removed is a loss to it.

A name the kernel reports in a form UTF-8 cannot spell (an unpaired
surrogate) cannot be named to the caller, and becomes an `overflow`.
Notifications may, rarely, carry a file's short (8.3) name.

Paths are converted to UTF-16 without the `\\?\` long-path prefix, as the
VFS's `openRootDir` does, so a path longer than `MAX_PATH` needs a process
that is long-path aware.
*/
module sparkles.event_horizon.tree_watch_windows;

version (Windows):

import core.sys.windows.basetsd : ULONG_PTR;
import core.sys.windows.winbase : BY_HANDLE_FILE_INFORMATION, CancelIoEx, CloseHandle,
    CreateFileW, CreateIoCompletionPort, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OVERLAPPED,
    GetFileAttributesW, GetFileInformationByHandle, GetLastError, GetQueuedCompletionStatus,
    INFINITE, INVALID_HANDLE_VALUE, OPEN_EXISTING, OVERLAPPED,
    PostQueuedCompletionStatus, ReadDirectoryChangesW;
import core.sys.windows.windef : DWORD, HANDLE;
import core.sys.windows.winerror : ERROR_DIRECTORY, ERROR_FILENAME_EXCED_RANGE,
    ERROR_NOTIFY_ENUM_DIR, WAIT_TIMEOUT;
import core.sys.windows.winnt : FILE_ACTION_ADDED, FILE_ACTION_MODIFIED, FILE_ACTION_REMOVED,
    FILE_ACTION_RENAMED_NEW_NAME, FILE_ACTION_RENAMED_OLD_NAME, FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_LIST_DIRECTORY, FILE_NOTIFY_CHANGE_ATTRIBUTES,
    FILE_NOTIFY_CHANGE_CREATION, FILE_NOTIFY_CHANGE_DIR_NAME, FILE_NOTIFY_CHANGE_FILE_NAME,
    FILE_NOTIFY_CHANGE_LAST_WRITE, FILE_NOTIFY_CHANGE_SECURITY, FILE_NOTIFY_CHANGE_SIZE,
    FILE_NOTIFY_INFORMATION, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, INVALID_FILE_ATTRIBUTES;
import core.thread : Thread;

import sparkles.base.text.utf16 : utf16ToUtf8, utf8ToUtf16z;
import sparkles.base.vfs.types : maxSplicedPathLength;

import sparkles.event_horizon.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr,
    ioOk;
import sparkles.event_horizon.sys.error_kinds : win32Kind;
import sparkles.event_horizon.tree_watch : WatchedDir, WatchNote, WatchNoteKind, WatchSink;

/// The `ReadDirectoryChangesW` backend; see the module's documentation.
package(sparkles.event_horizon) struct DirectoryChangesBackend
{
    @disable this(this);

    /// Opens the completion port and starts the thread that serves it.
    IoResult!void start(WatchSink sink)
    {
        auto port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1);
        if (port is null)
            return ioErr!void(lastError(OpKind.none, IoErrorStage.setup,
                "CreateIoCompletionPort failed"));
        state = new Shared;
        state.sink = sink;
        state.port = port;
        auto st = state;
        server = new Thread(() { serve(st); });
        server.isDaemon = true;
        server.start();
        return ioOk();
    }

    /**
    Watches the directory at the absolute `path`. Its identity is the one
    the VFS's `fstat` reports: the volume serial number and the file index
    from `GetFileInformationByHandle`. A directory already watched, by any
    path, returns its token again. `notADirectory` when `path` names
    something else.
    */
    IoResult!WatchedDir add(scope const(char)[] path)
    {
        wchar[maxSplicedPathLength + 1] w = void;
        const converted = utf8ToUtf16z(path, w[]);
        if (converted.hasError)
            return ioErr!WatchedDir(IoError(ErrorKind.nameTooLong, ERROR_FILENAME_EXCED_RANGE,
                OpKind.none, IoErrorStage.submit, "path too long, or not UTF-8"));
        const length = converted.value;

        auto h = (() @trusted => CreateFileW(w.ptr, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null))();
        if (h == INVALID_HANDLE_VALUE)
            return ioErr!WatchedDir(lastError(OpKind.none, IoErrorStage.submit,
                "opening a watched directory failed"));
        BY_HANDLE_FILE_INFORMATION info;
        if (!(() @trusted => GetFileInformationByHandle(h, &info))())
        {
            const e = lastError(OpKind.none, IoErrorStage.submit,
                "querying a watched directory failed");
            CloseHandle(h);
            return ioErr!WatchedDir(e);
        }
        if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
        {
            CloseHandle(h);
            return ioErr!WatchedDir(IoError(ErrorKind.notADirectory, ERROR_DIRECTORY,
                OpKind.none, IoErrorStage.submit, "a watched path is not a directory"));
        }
        const id = Identity(info.dwVolumeSerialNumber,
            (cast(ulong) info.nFileIndexHigh << 32) | info.nFileIndexLow);

        synchronized (state.lock)
        {
            if (auto known = id in state.byIdentity)
            {
                CloseHandle(h);
                return ioOk(WatchedDir(*known, id.device, id.inode));
            }
            auto watch = new Watch;
            watch.handle = h;
            watch.token = state.nextToken++;
            watch.id = id;
            watch.dir = w[0 .. length].dup;
            watch.buffer = new ubyte[](bufferSize);
            if (CreateIoCompletionPort(h, state.port, watch.token, 0) is null)
            {
                const e = lastError(OpKind.none, IoErrorStage.submit,
                    "binding a watched directory to the completion port failed");
                CloseHandle(h);
                return ioErr!WatchedDir(e);
            }
            // Registered before the read is armed, so its completion finds it.
            state.byToken[watch.token] = watch;
            if (!arm(watch))
            {
                const e = lastError(OpKind.none, IoErrorStage.submit,
                    "ReadDirectoryChangesW failed");
                state.byToken.remove(watch.token);
                CloseHandle(h);
                return ioErr!WatchedDir(e);
            }
            state.byIdentity[id] = watch.token;
            return ioOk(WatchedDir(watch.token, id.device, id.inode));
        }
    }

    /// Stops watching `token`: cancels its read and closes its handle. The
    /// cancelled read's completion is swallowed, so no `lost` follows.
    void remove(uint token)
    {
        synchronized (state.lock)
        {
            auto watch = token in state.byToken;
            if (watch !is null && !(*watch).removing)
                retire(state, *watch);
        }
    }

    /// Wakes the thread, which cancels every watch and waits for the
    /// cancelled reads to return; joins it and closes the port.
    void stop()
    {
        if (server is null)
            return;
        cast(void) PostQueuedCompletionStatus(state.port, 0, stopKey, null);
        server.join();
        server = null;
        CloseHandle(state.port);
        state.port = null;
    }

private:
    // The changes a watch reports: names, and a file's content and metadata.
    enum DWORD notifyFilter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME
        | FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE
        | FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_SECURITY;
    // One read's buffer: the most a read over a network share may use.
    enum size_t bufferSize = 64 * 1024;
    // The completion key that wakes the thread to stop; tokens start at 1.
    enum ULONG_PTR stopKey = 0;
    // How long a stopping thread waits for a cancelled read to return.
    enum DWORD drainMsecs = 5_000;

    static struct Identity
    {
        ulong device, inode;
    }

    static final class Watch
    {
        OVERLAPPED ov;      // the outstanding read's; the kernel's while `pending`
        HANDLE handle;      // `INVALID_HANDLE_VALUE` once closed
        uint token;
        Identity id;
        bool pending;       // a read is outstanding: the kernel owns `ov` and `buffer`
        bool removing;      // unwatched, lost or stopping: no note may follow
        wchar[] dir;        // the path, UTF-16 and unterminated, to look names up in
        ubyte[] buffer;     // GC memory: aligned for FILE_NOTIFY_INFORMATION, and never moved
    }

    static final class Shared
    {
        Object lock;
        WatchSink sink;
        HANDLE port;
        // Every watch whose handle or read is still live. A retired watch
        // stays until its cancelled read returns, so its buffer outlives it.
        Watch[uint] byToken;
        uint[Identity] byIdentity; // watches not retired, by directory
        uint nextToken = 1;

        this() { lock = new Object; }
    }

    Thread server;
    Shared state;

    // Watches whose cancelled reads did not return while stopping: kept
    // reachable, as the kernel may still write their buffers.
    __gshared Shared[] abandoned;

    static IoError lastError(OpKind op, IoErrorStage stage, string context) nothrow @nogc
    {
        const code = GetLastError();
        return IoError(win32Kind(code), cast(int) code, op, stage, context);
    }

    // Arms the next read; with `state.lock` held. False with the error in
    // `GetLastError` when the kernel refused it, which queues no completion.
    static bool arm(Watch watch) nothrow @nogc
    {
        watch.ov = OVERLAPPED.init;
        const armed = (() @trusted => ReadDirectoryChangesW(watch.handle, watch.buffer.ptr,
            cast(DWORD) watch.buffer.length, false, notifyFilter, null, &watch.ov, null))();
        watch.pending = armed != 0;
        return watch.pending;
    }

    // Ends `watch` without a note; with `state.lock` held. Closing the
    // handle ends its read too; the read's completion still arrives, and
    // removes the watch then.
    static void retire(Shared st, Watch watch) nothrow
    {
        watch.removing = true;
        if (auto known = watch.id in st.byIdentity)
            if (*known == watch.token)
                st.byIdentity.remove(watch.id);
        if (watch.handle != INVALID_HANDLE_VALUE)
        {
            if (watch.pending)
                cast(void) (() @trusted => CancelIoEx(watch.handle, &watch.ov))();
            CloseHandle(watch.handle);
            watch.handle = INVALID_HANDLE_VALUE;
        }
        if (!watch.pending)
            st.byToken.remove(watch.token);
    }

    // Serves the port until `stop` posts `stopKey`.
    static void serve(Shared st)
    {
        for (;;)
        {
            DWORD bytes;
            ULONG_PTR key;
            OVERLAPPED* ov;
            const ok = (() @trusted => GetQueuedCompletionStatus(st.port, &bytes, &key, &ov,
                INFINITE))();
            const error = ok ? 0 : GetLastError();
            if (ov is null)
            {
                if (ok && key == stopKey)
                {
                    shutDown(st);
                    return;
                }
                // The port itself failed: nothing more will arrive.
                st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
                abandon(st);
                return;
            }
            complete(st, cast(uint) key, ov, bytes, error);
        }
    }

    // One read of the watch `token` completed with `bytes` and `error`.
    static void complete(Shared st, uint token, OVERLAPPED* ov, DWORD bytes, DWORD error)
    {
        Watch watch;
        synchronized (st.lock)
        {
            auto known = token in st.byToken;
            if (known is null || &(*known).ov !is ov)
                return;
            watch = *known;
            watch.pending = false;
            if (watch.removing)
            {
                // A cancelled read, or one that raced its watch's removal.
                st.byToken.remove(token);
                return;
            }
        }
        // Until it is armed again the buffer is this thread's.
        if (error == 0 && bytes > 0)
            decodeAll(st, watch, watch.buffer[0 .. bytes]);
        synchronized (st.lock)
        {
            if (watch.removing)
            {
                st.byToken.remove(token); // retired while decoding
                return;
            }
            if (error == 0 || error == ERROR_NOTIFY_ENUM_DIR)
            {
                // An empty read means the kernel's buffer overflowed. Armed
                // first: a directory removed meanwhile is a loss, not an
                // overflow (the read on a removed directory may end empty).
                if (arm(watch))
                {
                    if (error != 0 || bytes == 0)
                        st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
                    return;
                }
            }
            retire(st, watch);
            st.sink.deliver(WatchNote(token, WatchNoteKind.lost));
        }
    }

    // Retires every watch, then waits for their reads to return.
    static void shutDown(Shared st)
    {
        synchronized (st.lock)
            foreach (watch; st.byToken.values)
                retire(st, watch);
        for (;;)
        {
            synchronized (st.lock)
                if (st.byToken.length == 0)
                    return;
            DWORD bytes;
            ULONG_PTR key;
            OVERLAPPED* ov;
            const ok = (() @trusted => GetQueuedCompletionStatus(st.port, &bytes, &key, &ov,
                drainMsecs))();
            if (ov is null)
            {
                if (ok)
                    continue; // a stray wake-up
                abandon(st); // timed out, or the port failed
                return;
            }
            synchronized (st.lock)
            {
                auto known = cast(uint) key in st.byToken;
                if (known !is null && &(*known).ov is ov)
                    st.byToken.remove(cast(uint) key);
            }
        }
    }

    static void abandon(Shared st)
    {
        bool live;
        synchronized (st.lock)
            live = st.byToken.length != 0;
        if (live)
            synchronized
                abandoned ~= st;
    }

    // Decodes a completed read's records.
    static void decodeAll(Shared st, Watch watch, scope const(ubyte)[] data)
    {
        enum nameAt = FILE_NOTIFY_INFORMATION._FileName.offsetof;
        size_t at;
        for (;;)
        {
            if (at + nameAt > data.length)
            {
                st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
                return;
            }
            const record = (() @trusted => cast(const(FILE_NOTIFY_INFORMATION)*) (data.ptr + at))();
            const end = at + nameAt + record.FileNameLength;
            if (end > data.length)
            {
                st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
                return;
            }
            const name = (() @trusted => (cast(const(wchar)*) (data.ptr + at + nameAt))[
                0 .. record.FileNameLength / 2])();
            decode(st, watch, record.Action, name);
            if (record.NextEntryOffset == 0)
                return;
            at += record.NextEntryOffset;
        }
    }

    static void decode(Shared st, Watch watch, DWORD action, scope const(wchar)[] name)
    {
        WatchNoteKind kind;
        switch (action)
        {
            case FILE_ACTION_ADDED, FILE_ACTION_RENAMED_NEW_NAME:
                kind = WatchNoteKind.created;
                break;
            case FILE_ACTION_REMOVED, FILE_ACTION_RENAMED_OLD_NAME:
                kind = WatchNoteKind.removed;
                break;
            case FILE_ACTION_MODIFIED:
                kind = WatchNoteKind.modified;
                break;
            default:
                return; // a stream's actions, which the filter does not ask for
        }
        if (name.length == 0)
            return;
        // A name is at most 255 UTF-16 units: 765 bytes of UTF-8.
        char[1024] utf8 = void;
        const n = utf16ToUtf8(name, utf8[]);
        if (n.hasError)
        {
            st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
            return;
        }
        const isDir = kind == WatchNoteKind.created && isDirectory(watch.dir, name);
        st.sink.deliver(WatchNote(watch.token, kind, isDir, utf8[0 .. n.value].idup));
    }

    // Whether `name` in `dir` is a directory, and not a reparse point.
    static bool isDirectory(scope const(wchar)[] dir, scope const(wchar)[] name) nothrow @nogc
    {
        wchar[maxSplicedPathLength + 1] path = void;
        const separated = dir.length && (dir[$ - 1] == '\\' || dir[$ - 1] == '/');
        const length = dir.length + (separated ? 0 : 1) + name.length;
        if (length >= path.length)
            return false;
        path[0 .. dir.length] = dir[];
        if (!separated)
            path[dir.length] = '\\';
        path[length - name.length .. length] = name[];
        path[length] = 0;
        const attrs = (() @trusted => GetFileAttributesW(path.ptr))();
        return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)
            && !(attrs & FILE_ATTRIBUTE_REPARSE_POINT);
    }
}
