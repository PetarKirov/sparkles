/**
File helpers for the SDL backend (SPEC §11): typed read and atomic write.

$(LREF readSDLFile) reads bytes without path expansion, uses the path as the
source name (so lex/parse/decode diagnostics render `path(line:column)`), and
decodes the document root. $(LREF writeSDLFile) canonicalizes first — an
encode failure touches no filesystem state — then recursively creates missing
parent directories, writes a same-directory temporary file, flushes it, and
atomically renames it over the target. Every handled failure removes the
temporary file where the platform permits and leaves an existing target
byte-identical; failures carry stage-specific codes
($(LREF SdlErrorCode.fileReadFailed), $(LREF SdlErrorCode.fileWriteFailed))
plus the OS error code in $(LREF SdlError.cause).

Rename atomicity is POSIX `rename(2)` semantics; Windows `MoveFileEx`
behavior is accepted by `std.file.rename` but not asserted by tests.
*/
module sparkles.wired.sdl.files;

import std.traits : Unqual;

import sparkles.base.buffer : SharedBuffer, checkWriter;
import sparkles.wired.sdl.codec : fromSDL, sdlParserConfigFor, toSDL;
import sparkles.wired.sdl.error : SdlError, SdlErrorCode, SdlErrorStage,
    SdlExpected, sdlErr, sdlOk;
import sparkles.wired.sdl.reader : parseSdlDocument;
import sparkles.wired.sdl.schema_annotations : SdlAttribute, SdlChild,
    SdlTagValue, hasBorrowedSdlExtras;

/** Reads the SDL file at `path`, parses it under `config`, and decodes the
document root as aggregate `T` (SPEC §11).

The path is used verbatim — no expansion — both for I/O and as the parse
result's source name, so diagnostics render as `path(line:column)` with their
own stages and codes. Open/read failures are `fileReadFailed` at stage
`fileRead` with the OS error code carried in $(LREF SdlError.cause).

Like the text overload of $(LREF fromSDL), this function's temporary document
cannot outlive the returned value: aggregates declaring an `@SdlExtra` field
of borrowed $(LREF sparkles.wired.sdl.document.SdlExtras) flavor are a
compile-time error here.
*/
SdlExpected!T readSDLFile(T, alias config = sdlParserConfigFor!T)(
    scope const(char)[] path)
if (is(T == struct))
{
    static assert(!hasBorrowedSdlExtras!(Unqual!T),
        "wired.sdl: " ~ T.stringof ~ ": a borrowed @SdlExtra (SdlExtras) "
        ~ "field cannot outlive readSDLFile's temporary document");

    import std.file : read;

    void[] raw;
    try
        raw = read(path);
    catch (Exception e)
        return sdlErr!T(fileFailure(SdlErrorStage.fileRead,
            SdlErrorCode.fileReadFailed, path,
            "cannot read the file", causeOf(e)));

    auto parsed = parseSdlDocument!config(cast(const(char)[]) raw, path);
    if (!parsed.hasValue)
        return sdlErr!T(parsed.error);

    auto decoded = fromSDL!(Unqual!T)(parsed.document.root);
    if (decoded.hasError)
    {
        // Codec-built errors do not know the path; attach it so diagnostics
        // keep rendering `path(line:column)` through every stage.
        auto failure = decoded.error;
        failure.sourceName ~= path;
        return sdlErr!T(failure);
    }
    return sdlOk(decoded.value);
}

/** Encodes `value` canonically and atomically installs it as the file at
`path` (SPEC §11).

Ordering guarantees:

$(LIST
    * canonicalization happens first — an encode failure propagates before
    any filesystem state is touched;
    * exactly one LF terminates non-empty output (an empty document stays
    empty);
    * missing parent directories are created recursively;
    * the payload lands in a same-directory temporary file first, is flushed,
    and only then atomically renamed over the target;
    * every handled failure removes the temporary file (best-effort, as the
    platform permits) and leaves an existing target byte-identical.
)

Write, flush, and rename failures are `fileWriteFailed` at stage `fileWrite`
with the OS error code in $(LREF SdlError.cause); directory creation failures
carry the same code naming the target's path.
*/
SdlExpected!void writeSDLFile(T)(scope const auto ref T value,
    scope const(char)[] path)
if (is(T == struct))
{
    import std.file : mkdirRecurse, remove, rename;
    import std.stdio : StdioException;

    // Canonicalize before touching the filesystem.
    const rendered = toSDL(value);
    if (rendered.hasError)
        return sdlErr!void(rendered.error);

    // Exactly one LF on non-empty output; empty documents stay empty.
    SharedBuffer!(char, 256) payload;
    payload ~= rendered.value[];
    if (payload.length && payload[$ - 1] != '\n')
        payload ~= '\n';

    // Missing parent directories, recursively.
    try
        mkdirRecurse(dirOf(path));
    catch (Exception e)
        return sdlErr!void(fileFailure(SdlErrorStage.fileWrite,
            SdlErrorCode.fileWriteFailed, path,
            "cannot create the parent directories", causeOf(e)));

    const temp = tempSibling(path);

    try
    {
        import std.stdio : File;

        auto sink = File(temp, "wb");
        scope (failure)
            removeTempBestEffort(temp);
        sink.rawWrite(payload[]);
        sink.flush();
        sink.close();
    }
    catch (StdioException e)
        return sdlErr!void(fileFailure(SdlErrorStage.fileWrite,
            SdlErrorCode.fileWriteFailed, temp,
            "cannot write the temporary file", cast(int) e.errno));
    catch (Exception e)
        return sdlErr!void(fileFailure(SdlErrorStage.fileWrite,
            SdlErrorCode.fileWriteFailed, temp,
            "cannot write the temporary file", causeOf(e)));

    try
        rename(temp, path);
    catch (Exception e)
    {
        removeTempBestEffort(temp);
        return sdlErr!void(fileFailure(SdlErrorStage.fileWrite,
            SdlErrorCode.fileWriteFailed, path,
            "cannot replace the target", causeOf(e)));
    }

    return sdlOk();
}

/// Best-effort temporary-file cleanup: the platform may refuse, and a failed
/// cleanup must not mask the original failure (SPEC §11).
private void removeTempBestEffort(scope const(char)[] path) @safe
{
    import std.file : remove;

    try
        remove(path);
    catch (Exception _)
    {
    }
}

private string dirOf(scope const(char)[] path) @safe pure
{
    import std.path : dirName;

    return dirName(path.idup);
}

/// Process-unique suffix so successive calls never collide on one temporary.
private __gshared uint tempCounter;

/** A unique sibling-path candidate for `path`'s replacement: same directory,
dot-prefixed so directory listings group it away from real targets, derived
from the target's name plus a process counter and a random UUID. */
private string tempSibling(scope const(char)[] path) @safe
{
    import std.format : format;
    import std.path : baseName, buildPath;
    import std.uuid : randomUUID;

    const base = baseName(path.idup);
    return buildPath(dirOf(path), format(".%s.tmp-%s-%s", base,
        bumpCounter(), randomUUID.toString));
}

/// Narrow trust: process-global data is `@system` by default. The random-UUID
/// component already rules out practical name collisions, so a racy increment
/// could at worst pick a different throwaway name.
private uint bumpCounter() @safe
{
    return () @trusted { return ++tempCounter; }();
}

/** Best-effort OS error code from an I/O exception; `0` when the failure did
not originate from an OS call. */
private int causeOf(scope Exception e) @safe pure nothrow @nogc
{
    import std.file : FileException;
    import std.stdio : StdioException;

    if (auto fe = cast(FileException) e)
        return cast(int) fe.errno;
    if (auto se = cast(StdioException) e)
        return cast(int) se.errno;
    return 0;
}

/** Assembles a file-stage failure with its target path and OS cause. */
private SdlError fileFailure(SdlErrorStage stage, SdlErrorCode code,
    scope const(char)[] path, scope const(char)[] reason, int cause) @safe
{
    SdlError error;
    error.stage = stage;
    error.code = code;
    error.filePath ~= path;
    error.reason ~= reason.idup;
    error.cause = cause;
    return error;
}

// ── Tests ────────────────────────────────────────────────────────────────────

version (unittest)
{
    private import std.path : buildPath;

    import sparkles.test_utils.tmpfs : TmpFS;

    private static struct Inner
    {
        @SdlAttribute() string id;
    }

    private static struct Fixture
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool verbose;
        @SdlChild() Inner dep;
    }

    private static struct Doc
    {
        @SdlChild() Fixture config;
    }

    private Fixture sampleFixture() @safe pure
    {
        return Fixture(
            name: "svc",
            verbose: true,
            dep: Inner(id: "d"));
    }

    // What toSDL renders for the fixture: canonical form with exactly one
    // final LF.
    private enum fixtureCanonical =
        `config "svc" verbose=true {` ~ "\n"
        ~ `    dep id="d"` ~ "\n"
        ~ `}` ~ "\n";

    /// Sorted file names directly inside `dir` (no recursion).
    private string[] listDir(string dir) @safe
    {
        return () @trusted {
            import std.algorithm.iteration : map;
            import std.algorithm.sorting : sort;
            import std.array : array;
            import std.file : dirEntries, SpanMode;

            return dirEntries(dir, SpanMode.shallow)
                .map!(e => e.name).array.sort.release;
        }();
    }
}

// Writing through missing parent directories produces the exact canonical
// bytes — one final LF included — and leaves no temporary sibling behind.
@("wired.sdl.files.write.nestedParentsExactBytesNoOrphan")
@system unittest
{
    auto tmp = TmpFS.create();
    const path = buildPath(tmp.dir(), "nested", "deeper", "target.sdl");
    Doc document;
    document.config = sampleFixture();

    const written = writeSDLFile(document, path);
    assert(!written.hasError, written.hasError ? written.error.toString : "");

    import std.file : readText;

    assert(path.readText == fixtureCanonical, path.readText.idup);

    // The directory holds exactly the target: no orphan temporary survived.
    assert(listDir(tmp.dir()) == [buildPath(tmp.dir(), "nested")]);
    assert(listDir(buildPath(tmp.dir(), "nested", "deeper")) == [path]);
}

// write→read closes the loop on typed equality.
@("wired.sdl.files.roundTripTypedEquality")
@system unittest
{
    auto tmp = TmpFS.create();
    const path = buildPath(tmp.dir(), "recipe.sdl");
    Doc document;
    document.config = sampleFixture();

    const written = writeSDLFile(document, path);
    assert(!written.hasError, written.hasError ? written.error.toString : "");

    const back = readSDLFile!Doc(path);
    assert(back.hasValue, back.hasError ? back.error.toString : "?");
    assert(back.value.config.name == "svc");
    assert(back.value.config.verbose);
    assert(back.value.config.dep.id == "d");
}

// Reading a missing file is a structured fileRead failure carrying the path
// and the OS cause (ENOENT), rendered as `path: cannot read the file`.
@("wired.sdl.files.read.missingFile")
@system unittest
{
    auto tmp = TmpFS.create();
    const path = buildPath(tmp.dir(), "absent.sdl");

    const missing = readSDLFile!Doc(path);
    assert(missing.hasError);
    assert(missing.error.stage == SdlErrorStage.fileRead);
    assert(missing.error.code == SdlErrorCode.fileReadFailed);
    assert(missing.error.filePath[] == path);
    version (Posix)
        assert(missing.error.cause == 2); // ENOENT

    import sparkles.base.buffer : SharedBuffer, checkWriter;

    checkWriter!((ref w) => missing.error.toString(w))(
        "Cannot read SDL file '" ~ path ~ "': cannot read the file");
}

// Lex/parse/decode failures propagate with their own stages, codes, and the
// path as source name — diagnostics render `path(line:column)`.
@("wired.sdl.files.read.parseAndDecodeErrorsCarryPath")
@system unittest
{
    import std.array : appender;

    auto tmp = TmpFS.create();

    enum broken = `config "unterminated`;
    const brokenPath = tmp.writeFile(broken, 1);
    const lexical = readSDLFile!Doc(brokenPath);
    assert(lexical.hasError);
    assert(lexical.error.stage == SdlErrorStage.lex);
    assert(lexical.error.code == SdlErrorCode.unterminatedString);
    assert(lexical.error.sourceName[] == brokenPath);

    auto rendered = appender!string;
    lexical.error.toString(rendered);
    import std.algorithm.searching : startsWith;

    assert(rendered[].startsWith(brokenPath ~ "(1:"), rendered[].idup);

    // A well-formed document violating the schema fails at decode.
    enum mistyped = `config 5 verbose=true {` ~ "\n" ~ `dep id="d"` ~ "\n}";
    const mistypedPath = tmp.writeFile(mistyped, 2);
    const decodeCase = readSDLFile!Doc(mistypedPath);
    assert(decodeCase.hasError);
    assert(decodeCase.error.stage == SdlErrorStage.decode);
    assert(decodeCase.error.code == SdlErrorCode.unexpectedKind);
    assert(decodeCase.error.sourceName[] == mistypedPath);
}

// An encode failure propagates before any filesystem state is touched: no
// target appears and no temporary orphan is left behind.
@("wired.sdl.files.write.encodeFailureTouchesNothing")
@system unittest
{
    static struct Broken
    {
        @SdlTagValue(0) double bad;
    }
    static struct BrokenDoc
    {
        @SdlChild() Broken b;
    }

    auto tmp = TmpFS.create();
    tmp.ensureDir();
    const path = buildPath(tmp.dir(), "out.sdl");

    BrokenDoc broken;
    broken.b.bad = double.nan;

    const failed = writeSDLFile(broken, path);
    assert(failed.hasError);
    assert(failed.error.stage == SdlErrorStage.encode);
    assert(failed.error.code == SdlErrorCode.valueOutOfRange);

    import std.file : exists;

    assert(!path.exists);
    assert(listDir(tmp.dir()).length == 0);
}

// A rename that cannot succeed (target is a non-empty directory) is a
// structured fileWrite failure; the temporary is cleaned up and the target's
// previous contents stay untouched.
@("wired.sdl.files.write.renameFailureCleansUp")
@system unittest
{
    import std.file : exists, mkdirRecurse, readText, remove, write;

    auto tmp = TmpFS.create();
    const path = buildPath(tmp.dir(), "occupied.sdl");

    // Occupy the target with a non-empty directory: rename(2) must refuse.
    mkdirRecurse(path);
    const occupant = buildPath(path, "inside.txt");
    write(occupant, "previous contents");

    Doc document;
    document.config = sampleFixture();
    const failed = writeSDLFile(document, path);
    assert(failed.hasError);
    assert(failed.error.stage == SdlErrorStage.fileWrite);
    assert(failed.error.code == SdlErrorCode.fileWriteFailed);
    assert(failed.error.filePath[] == path);
    version (Posix)
        assert(failed.error.cause != 0);

    // The occupied target is unchanged and no temporary orphan remains.
    assert(occupant.readText == "previous contents");
    const siblings = listDir(tmp.dir());
    import std.conv : to;

    assert(siblings == [path], siblings.to!string);
}

// An unwritable directory fails the write while an existing sibling target
// stays byte-identical. Skipped where the environment cannot express the
// precondition (root ignores permissions; non-POSIX platforms).
@("wired.sdl.files.write.unwritableDirectoryKeepsTarget")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    version (Posix)
    {
        import core.sys.posix.unistd : getuid;

        if (getuid() == 0)
            skipTest("running as root ignores directory permissions");
    }
    else
        skipTest("directory-permission semantics are POSIX-only");

    import std.conv : octal, to;
    import std.file : mkdirRecurse, readText, write;
    import std.string : toStringz;
    version (Posix)
        import core.sys.posix.sys.stat : chmod;

    auto tmp = TmpFS.create();
    tmp.ensureDir();
    const lockedDir = buildPath(tmp.dir(), "locked");
    mkdirRecurse(lockedDir);
    const path = buildPath(lockedDir, "target.sdl");
    write(path, "sentinel bytes");
    chmod(lockedDir.toStringz, cast(int) octal!555);
    scope (exit)
        chmod(lockedDir.toStringz, cast(int) octal!755); // let cleanup work

    // Confirm the lock is real before attributing the failure to it.
    {
        import std.file : FileException, remove;

        const probe = buildPath(lockedDir, ".probe");
        try
        {
            write(probe, "x");
            remove(probe);
            skipTest("directory permissions are not enforced here");
        }
        catch (FileException _)
        {
        }
    }

    Doc document;
    document.config = sampleFixture();
    const failed = writeSDLFile(document, path);
    assert(failed.hasError);
    assert(failed.error.stage == SdlErrorStage.fileWrite);
    assert(failed.error.code == SdlErrorCode.fileWriteFailed);
    assert(readText(path) == "sentinel bytes");
}

// An empty canonical document writes zero bytes — no trailing LF.
@("wired.sdl.files.write.emptyDocumentStaysEmpty")
@system unittest
{
    import std.file : readText;

    import std.typecons : Nullable;

    static struct Empty
    {
        @SdlAttribute() Nullable!int absent;
    }

    auto tmp = TmpFS.create();
    const path = buildPath(tmp.dir(), "empty.sdl");
    const written = writeSDLFile(Empty.init, path);
    assert(!written.hasError, written.hasError ? written.error.toString : "");

    import std.file : exists, readText;

    assert(path.exists && path.readText.length == 0);
}

// Borrowed extras cannot survive this module's temporary documents either.
@("wired.sdl.files.read.rejectsBorrowedExtras")
@system unittest
{
    import sparkles.wired.sdl.document : SdlExtras;
    import sparkles.wired.sdl.schema_annotations : SdlExtra;

    static struct Borrowing
    {
        @SdlTagValue(0) string name;
        @SdlExtra() SdlExtras extras;
    }

    static assert(!__traits(compiles, readSDLFile!Borrowing("any.sdl")));
}
