/++
Input/output helpers for the `age` CLI: stdin/file readers, atomic file
writers (temp-then-rename), mode 0600 + refuse-overwrite support, and the
binary-to-TTY guard.

These mirror the behaviour of rage's `age/src/cli_common/file_io.rs`:

$(LIST
    $(ITEM A positional input of `-` or an absent input means standard input;
        any other value is opened as a file.)
    $(ITEM An output of `-` or an absent output means standard output; any
        other value is written to a file.)
    $(ITEM File output is $(I atomic): bytes are written to a temporary file in
        the same directory as the destination, then `rename`d into place on
        $(LREF OutputWriter.finish). A failure (or a dropped writer that was
        never finished) leaves the destination untouched and removes the temp.)
    $(ITEM File output may be created with mode `0600` and may refuse to
        overwrite an existing file (used by `age-keygen`).)
    $(ITEM Writing $(I binary) data to a terminal is refused unless an explicit
        `-o -` forced standard output, matching age/rage's safety guard.)
)

POSIX-specific calls (`isatty`, `fchmod`) are isolated in `@trusted` wrappers;
everything else stays `@safe`.
+/
module sparkles.age_cli.io;

import std.stdio : File, stdin, stdout;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

/++
Error raised by the I/O layer. Its message mirrors the wording produced by the
rage reference implementation (`age/i18n/en-US/age.ftl`) so the CLI reproduces
the same diagnostics.
+/
class IoError : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// POSIX wrappers
// ─────────────────────────────────────────────────────────────────────────────

/++
Returns `true` if the file descriptor `fd` refers to a terminal.

On non-POSIX platforms this is always `false` (the binary-to-TTY guard is a
no-op, as in rage which only enables the protection behind `cfg(unix)` /
`console::user_attended`).
+/
bool fdIsTty(int fd) @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;

        return isatty(fd) == 1;
    }
    else
        return false;
}

/// `true` if standard input is connected to a terminal.
bool stdinIsTty() @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : STDIN_FILENO;

        return fdIsTty(STDIN_FILENO);
    }
    else
        return false;
}

/// `true` if standard output is connected to a terminal.
bool stdoutIsTty() @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : STDOUT_FILENO;

        return fdIsTty(STDOUT_FILENO);
    }
    else
        return false;
}

// Flush the process standard-output stream. Isolated in @trusted because the
// `stdout` global is @system (it is backed by a __gshared FILE*).
private void flushStdout() @trusted
{
    stdout.flush();
}

// Set permission bits on an already-open `File`. POSIX only; a no-op
// elsewhere. Isolated in @trusted because it reaches the raw fd via fileno.
private void setFileMode(ref File f, uint mode) @trusted
{
    version (Posix)
    {
        import core.sys.posix.sys.stat : fchmod, mode_t;

        // `mode` is a plain octal value (e.g. octal!600 for owner rw).
        if (fchmod(f.fileno, cast(mode_t) mode) != 0)
            throw new IoError("failed to set file permissions");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Input
// ─────────────────────────────────────────────────────────────────────────────

/++
Reads bytes from either a named file or standard input.

Constructed via $(LREF InputReader.open): a `path` of `null` (absent) or the
single-dash sentinel `"-"` selects standard input, anything else opens that
file for reading. Use $(LREF readAll) to slurp the whole input into a freshly
allocated `ubyte[]`.
+/
struct InputReader
{
    private File _file;          // closed/invalid when reading from stdin
    private bool _isStdin;
    private string _filename;    // null when reading from stdin

    @disable this(this);

    /++
    Opens `path` for reading, or selects standard input when `path` is `null`
    or `"-"`.

    Throws: $(LREF IoError) wrapping the underlying error if the file cannot be
    opened.
    +/
    static InputReader open(string path)
    {
        InputReader r;
        if (path is null || path == "-")
        {
            r._isStdin = true;
            return r;
        }

        try
            r._file = File(path, "rb");
        catch (Exception e)
            throw new IoError("failed to open input '" ~ path ~ "': " ~ e.msg);

        r._filename = path;
        return r;
    }

    /// `true` when this reader is bound to standard input rather than a file.
    bool isStdin() const nothrow @nogc => _isStdin;

    /++
    The filename this reader was opened with, or `null` for standard input.
    +/
    string filename() const nothrow @nogc => _filename;

    /++
    `true` if this input is an interactive terminal (i.e. standard input and a
    TTY). Used by the caller to decide whether to buffer output that would
    otherwise interleave with typed input.
    +/
    bool isTerminal() const nothrow @nogc @trusted
        => _isStdin && stdinIsTty();

    /++
    Reads the entire input into a freshly allocated buffer.

    For files this reads to EOF; for standard input it consumes everything
    available until EOF.

    Throws: $(LREF IoError) on a read error.
    +/
    ubyte[] readAll() @trusted
    {
        import std.array : appender;

        auto app = appender!(ubyte[]);
        // Heap-allocated so the chunk buffer never escapes a stack frame via
        // byChunk's non-scope parameter (dip1000).
        auto chunk = new ubyte[64 * 1024];

        try
        {
            auto src = _isStdin ? stdin : _file;
            foreach (ubyte[] read; src.byChunk(chunk))
                app.put(read);
        }
        catch (Exception e)
            throw new IoError("failed to read input: " ~ e.msg);

        return app[];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Output
// ─────────────────────────────────────────────────────────────────────────────

/++
Classifies the data an $(LREF OutputWriter) will carry, which decides whether
sending it to a terminal is allowed.
+/
enum OutputFormat
{
    /// Binary data; refused on a TTY unless `-o -` explicitly forced stdout.
    binary,
    /// Text data; always acceptable on a TTY.
    text,
}

/++
Writes bytes to either a named file or standard output.

Constructed via $(LREF OutputWriter.create):

$(LIST
    $(ITEM A `path` of `null` (absent) or `"-"` selects standard output. When
        `-` was passed explicitly the output is treated as forced — the
        binary-to-TTY guard is suppressed, matching rage.)
    $(ITEM Any other `path` is written $(I atomically): bytes accumulate in a
        sibling temporary file, and $(LREF finish) `rename`s it into place. The
        destination is never partially written. If the writer is destroyed
        without `finish`, the temporary file is removed and the destination is
        left untouched.)
    $(ITEM When `mode` is non-zero (POSIX) the temp file's permission bits are
        set to it (e.g. `0x180` == octal `600`) before the rename.)
    $(ITEM When `refuseOverwrite` is `true` and the destination already exists,
        construction throws — mirroring `age-keygen`'s refusal to clobber an
        existing key file. The check is also re-applied at `finish` to narrow
        the TOCTOU window.)
)
+/
struct OutputWriter
{
    private File _file;          // the temp file (when writing to a real file)
    private bool _isStdout;
    private bool _forcedStdout;  // user passed "-" explicitly
    private bool _finished;
    private string _destPath;    // final destination (null for stdout)
    private string _tempPath;    // temp file path (null for stdout)
    private OutputFormat _format;
    private bool _refuseOverwrite;
    private uint _mode;

    @disable this(this);

    /++
    Constructs an `OutputWriter`.

    Params:
        path = Destination file path; `null` or `"-"` selects standard output.
        format = Whether the payload is binary or text (drives the TTY guard).
        refuseOverwrite = If `true`, refuse to overwrite an existing file.
        mode = POSIX permission bits for the created file (`0` leaves the
            default; `0x180` == octal `600`).

    Throws:
        $(LREF IoError) if a binary payload would be written to a terminal with
        no explicit `-o -`, if `refuseOverwrite` is set and the destination
        exists, if the destination's parent directory is missing, or if the
        temporary file cannot be created.
    +/
    static OutputWriter create(
        string path,
        OutputFormat format = OutputFormat.binary,
        bool refuseOverwrite = false,
        uint mode = 0,
    )
    {
        import std.path : dirName;
        import std.file : exists;

        OutputWriter w;
        w._format = format;
        w._refuseOverwrite = refuseOverwrite;
        w._mode = mode;

        // Standard output: either absent/"-".
        if (path is null || path == "-")
        {
            w._isStdout = true;
            // An explicit "-" forces stdout: rage treats forced stdout as
            // binary and skips the TTY guard.
            w._forcedStdout = (path == "-");

            if (!w._forcedStdout
                && format == OutputFormat.binary
                && stdoutIsTty())
            {
                throw new IoError(
                    "refusing to output binary to a terminal. "
                    ~ "Use -a/--armor or -o to write to a file.");
            }

            return w;
        }

        // File output.
        auto dir = path.dirName;
        if (dir != "." && dir != "" && !dir.exists)
            throw new IoError("directory '" ~ dir ~ "' does not exist.");

        if (refuseOverwrite && path.exists)
            throw new IoError(
                "refusing to overwrite existing file '" ~ path ~ "'.");

        w._destPath = path;
        w._tempPath = makeTempPath(path);

        try
            w._file = File(w._tempPath, "wb");
        catch (Exception e)
            throw new IoError(
                "failed to create output '" ~ path ~ "': " ~ e.msg);

        if (mode != 0)
        {
            try
                setFileMode(w._file, mode);
            catch (Exception e)
            {
                w.discardTemp();
                throw e;
            }
        }

        return w;
    }

    // Build a temp path in the same directory as `dest`, so the eventual
    // rename stays on the same filesystem (and is therefore atomic).
    private static string makeTempPath(string dest)
    {
        import std.path : dirName, baseName, buildPath;
        import std.uuid : randomUUID;

        const dir = dest.dirName;
        const base = dest.baseName;
        return buildPath(dir, "." ~ base ~ ".age-tmp-" ~ randomUUID.toString());
    }

    ~this()
    {
        // A writer dropped without finish() must not leave a temp file behind
        // nor touch the destination.
        if (!_finished && !_isStdout && _tempPath !is null)
            discardTemp();
    }

    private void discardTemp() @trusted nothrow
    {
        import std.file : exists, remove;

        try
        {
            if (_file.isOpen)
                _file.close();
        }
        catch (Exception) { /* best effort */ }

        try
        {
            if (_tempPath !is null && _tempPath.exists)
                remove(_tempPath);
        }
        catch (Exception) { /* best effort */ }
    }

    /// `true` when writing to standard output rather than a file.
    bool isStdout() const nothrow @nogc => _isStdout;

    /// `true` if this output is an interactive terminal a user will see.
    bool isTerminal() const nothrow @nogc @trusted
        => _isStdout && stdoutIsTty();

    /++
    Appends `data` to the output.

    For binary output to a forced/non-TTY stdout, and for files, this writes
    directly. The constructor already rejected binary-to-TTY, so reaching
    `write` means the destination is acceptable.

    Throws: $(LREF IoError) on a write error.
    +/
    void write(scope const(ubyte)[] data) @trusted
    {
        try
        {
            if (_isStdout)
                stdout.rawWrite(data);
            else
                _file.rawWrite(data);
        }
        catch (Exception e)
            throw new IoError("failed to write output: " ~ e.msg);
    }

    /// Convenience overload for textual payloads.
    void write(scope const(char)[] data) @trusted
    {
        write(cast(const(ubyte)[]) data);
    }

    /++
    Commits the output.

    For standard output this flushes. For a file this closes the temporary
    file and atomically `rename`s it onto the destination. After a successful
    `finish`, the destructor will not touch the destination.

    Throws: $(LREF IoError) if the destination was created concurrently while
    `refuseOverwrite` is set, or if the rename fails.
    +/
    void finish()
    {
        if (_finished)
            return;

        if (_isStdout)
        {
            try
                flushStdout();
            catch (Exception e)
                throw new IoError("failed to flush output: " ~ e.msg);
            _finished = true;
            return;
        }

        import std.file : exists, rename;

        try
            _file.close();
        catch (Exception e)
        {
            discardTemp();
            throw new IoError("failed to finalize output: " ~ e.msg);
        }

        // Re-check the overwrite guard to narrow the TOCTOU window between
        // create() and finish().
        if (_refuseOverwrite && _destPath.exists)
        {
            discardTemp();
            throw new IoError(
                "refusing to overwrite existing file '" ~ _destPath ~ "'.");
        }

        try
            rename(_tempPath, _destPath);
        catch (Exception e)
        {
            discardTemp();
            throw new IoError(
                "failed to write output '" ~ _destPath ~ "': " ~ e.msg);
        }

        _finished = true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stdin guard
// ─────────────────────────────────────────────────────────────────────────────

/++
RAII guard ensuring standard input is claimed for at most one purpose.

The `age` CLI may take its plaintext/ciphertext from stdin $(I and) read an
identity file given as `-i -`; both cannot consume the single real standard
input. The first $(LREF StdinGuard.claim) succeeds; a second (anywhere in the
process, while the first guard is still alive) throws so the caller can
surface rage's "Standard input can't be used for multiple purposes."
diagnostic.

The claim is process-global (a `__gshared` flag) because there is only one
standard input. The guard releases the claim on destruction, so a fresh claim
can be taken once the previous consumer is done — and so tests stay isolated.

---
auto g1 = StdinGuard.claim("input");        // ok
auto g2 = StdinGuard.claim("identity");      // throws IoError
---
+/
struct StdinGuard
{
    private bool _active;

    @disable this();
    @disable this(this);

    private this(bool active) nothrow @nogc
    {
        _active = active;
    }

    /++
    Claims standard input, returning a guard that releases the claim when it
    goes out of scope.

    Params:
        purpose = A human label for the claim (e.g. `"input"` or
            `"identity"`); reserved for future diagnostics.

    Throws: $(LREF IoError) ("Standard input can't be used for multiple
    purposes.") if standard input is already claimed.
    +/
    static StdinGuard claim(string purpose = "input") @trusted
    {
        import core.atomic : cas;

        // A single flag suffices: the CLI is single-threaded, but the atomic
        // compare-and-set keeps the claim honest if that ever changes.
        if (!cas(&_stdinClaimed, false, true))
            throw new IoError(
                "Standard input can't be used for multiple purposes.");

        return StdinGuard(true);
    }

    /// Releases the claim so a later consumer may take it.
    ~this() @trusted nothrow @nogc
    {
        import core.atomic : atomicStore;

        if (_active)
            atomicStore(_stdinClaimed, false);
    }
}

private shared bool _stdinClaimed;

/++
Forcibly resets the process-global stdin claim. Intended for tests that need
to recover from a leaked claim; normal code should rely on $(LREF StdinGuard)'s
destructor instead.
+/
void resetStdinClaim() @trusted nothrow @nogc
{
    import core.atomic : atomicStore;

    atomicStore(_stdinClaimed, false);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // A throwaway directory under tempDir for file-based tests, removed on
    // scope exit. Kept local so io.d's tests don't depend on test-utils.
    private struct ScratchDir
    {
        import std.file : mkdirRecurse, rmdirRecurse, tempDir;
        import std.path : buildPath;
        import std.uuid : randomUUID;

        string path;
        @disable this(this);

        static ScratchDir create()
        {
            ScratchDir s;
            s.path = buildPath(tempDir, "age-cli-io-test-" ~ randomUUID.toString());
            mkdirRecurse(s.path);
            return s;
        }

        string file(string name) => buildPath(path, name);

        ~this()
        {
            import std.file : exists;

            if (path !is null && path.exists)
                rmdirRecurse(path);
        }
    }
}

@("cli.io.writeThenReadFile")
@system
unittest
{
    auto scratch = ScratchDir.create();
    const target = scratch.file("roundtrip.bin");

    {
        auto w = OutputWriter.create(target, OutputFormat.binary);
        w.write(cast(const(ubyte)[]) "hello, age");
        w.finish();
    }

    auto r = InputReader.open(target);
    assert(!r.isStdin);
    assert(r.filename == target);
    assert(cast(string) r.readAll == "hello, age");
}

@("cli.io.atomicWriteCreatesNoTempLeftover")
@system
unittest
{
    import std.algorithm : filter, startsWith;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;
    import std.range : walkLength;

    auto scratch = ScratchDir.create();
    const target = scratch.file("clean.txt");

    {
        auto w = OutputWriter.create(target, OutputFormat.text);
        w.write("payload");
        w.finish();
    }

    // Only the destination should remain — no ".age-tmp-" sibling.
    auto temps = dirEntries(scratch.path, SpanMode.shallow)
        .filter!(e => e.name.baseName.startsWith("."))
        .walkLength;
    assert(temps == 0);
}

@("cli.io.droppedWriterLeavesNoDestination")
@system
unittest
{
    import std.file : exists;

    auto scratch = ScratchDir.create();
    const target = scratch.file("never.txt");

    {
        auto w = OutputWriter.create(target, OutputFormat.text);
        w.write("partial");
        // No finish(): the destination must not appear, temp must be cleaned.
    }

    assert(!target.exists);
    import std.algorithm : filter, startsWith;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;
    import std.range : walkLength;
    auto entries = dirEntries(scratch.path, SpanMode.shallow)
        .filter!(e => e.name.baseName.startsWith("."))
        .walkLength;
    assert(entries == 0);
}

@("cli.io.dashMapsToStdInOut")
@system
unittest
{
    auto r = InputReader.open("-");
    assert(r.isStdin);
    assert(r.filename is null);

    auto rAbsent = InputReader.open(null);
    assert(rAbsent.isStdin);

    // "-" forces stdout and suppresses the binary-to-TTY guard even when
    // attached to a terminal, so construction must always succeed.
    auto w = OutputWriter.create("-", OutputFormat.binary);
    assert(w.isStdout);

    auto wAbsentText = OutputWriter.create(null, OutputFormat.text);
    assert(wAbsentText.isStdout);
}

@("cli.io.refuseOverwriteErrorsOnExistingFile")
@system
unittest
{
    import std.file : write;

    auto scratch = ScratchDir.create();
    const target = scratch.file("existing.key");
    write(target, "old contents");

    // refuseOverwrite=true must reject the pre-existing file at construction.
    bool threw = false;
    try
        cast(void) OutputWriter.create(target, OutputFormat.text, /*refuseOverwrite*/ true);
    catch (IoError)
        threw = true;
    assert(threw, "refuseOverwrite must reject an existing file");

    // refuseOverwrite=false must replace it atomically.
    {
        auto w = OutputWriter.create(target, OutputFormat.text, false);
        w.write("new contents");
        w.finish();
    }
    auto r = InputReader.open(target);
    assert(cast(string) r.readAll == "new contents");
}

version (Posix)
@("cli.io.mode0600FileHas0600Perms")
@system
unittest
{
    import std.file : getAttributes;
    import std.conv : octal;

    auto scratch = ScratchDir.create();
    const target = scratch.file("secret.key");

    {
        auto w = OutputWriter.create(
            target, OutputFormat.text, /*refuseOverwrite*/ true, /*mode*/ octal!600);
        w.write("identity material");
        w.finish();
    }

    // Mask off the file-type bits; only the permission bits should be 0600.
    const perms = getAttributes(target) & octal!777;
    assert(perms == octal!600,
        "expected mode 0600, got octal " ~ formatOctal(perms));
}

version (unittest)
private string formatOctal(uint v) @safe
{
    import std.format : format;

    return format("%o", v);
}

@("cli.io.stdinGuardRejectsSecondClaim")
@system
unittest
{
    resetStdinClaim();
    scope (exit) resetStdinClaim();

    auto first = StdinGuard.claim("input");

    // A second claim — e.g. input from stdin AND `-i -` — must be rejected
    // while the first guard is still alive.
    bool threw = false;
    try
        cast(void) StdinGuard.claim("identity");
    catch (IoError)
        threw = true;
    assert(threw, "second stdin claim must be rejected");
}

@("cli.io.stdinGuardReleasesOnScopeExit")
@system
unittest
{
    resetStdinClaim();
    scope (exit) resetStdinClaim();

    {
        auto g = StdinGuard.claim("input");
    } // released here

    // A fresh claim now succeeds because the previous guard was destroyed.
    auto again = StdinGuard.claim("input");
}

@("cli.io.missingOutputDirectoryIsRejected")
@system
unittest
{
    auto scratch = ScratchDir.create();
    const target = scratch.file("no-such-dir/file.txt");

    bool threw = false;
    try
        cast(void) OutputWriter.create(target, OutputFormat.text);
    catch (IoError)
        threw = true;
    assert(threw, "missing output directory must be rejected");
}
