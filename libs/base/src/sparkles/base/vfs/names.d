/**
Lexical checks the capability VFS makes before any backend call: entry names
(VFO1), walk paths (VFP3, VFP6) and symbolic-link targets (VFO10).

Every check is pure and allocation-free, so a refusal costs no system call.
*/
module sparkles.base.vfs.names;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, OpKind;
import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, maxNameLength;

/// Whether `c` separates path components on this platform (VFP3).
bool isSeparator(char c) @safe pure nothrow @nogc
{
    version (Windows)
        return c == '/' || c == '\\';
    else
        return c == '/';
}

/**
Checks one directory-entry name (VFO1). Returns `ErrorKind.other` when the
name is valid, otherwise `invalidName` or `nameTooLong`.
*/
ErrorKind checkName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length == 0 || name == "." || name == "..")
        return ErrorKind.invalidName;
    foreach (c; name)
        if (c == '\0' || c == '/')
            return ErrorKind.invalidName;
    version (Windows)
    {
        import sparkles.base.text.utf8 : validateUtf8;

        if (validateUtf8(name).hasError)
            return ErrorKind.invalidName;
        foreach (c; name)
            if (c == '\\' || c == ':')
                return ErrorKind.invalidName;
        if (name[$ - 1] == '.' || name[$ - 1] == ' ')
            return ErrorKind.invalidName;
        if (isReservedDeviceName(name))
            return ErrorKind.invalidName;
        if (utf16Length(name) > maxNameLength)
            return ErrorKind.nameTooLong;
    }
    else
    {
        if (name.length > maxNameLength)
            return ErrorKind.nameTooLong;
    }
    return ErrorKind.other;
}

/// Whether `name` is valid (VFO1).
bool isValidName(scope const(char)[] name) @safe pure nothrow @nogc
    => checkName(name) == ErrorKind.other;

/// `CON`, `PRN`, `AUX`, `NUL`, `COM0`–`COM9` and `LPT0`–`LPT9`, with or
/// without an extension, compared case-insensitively.
bool isReservedDeviceName(scope const(char)[] name) @safe pure nothrow @nogc
{
    size_t stem = 0;
    while (stem < name.length && name[stem] != '.')
        ++stem;
    const s = name[0 .. stem];

    static char lower(char c) => c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
    bool eq(scope const(char)[] a, string b)
    {
        if (a.length != b.length)
            return false;
        foreach (i, c; a)
            if (lower(c) != b[i])
                return false;
        return true;
    }

    if (eq(s, "con") || eq(s, "prn") || eq(s, "aux") || eq(s, "nul"))
        return true;
    if (s.length == 4 && (eq(s[0 .. 3], "com") || eq(s[0 .. 3], "lpt")))
        return s[3] >= '0' && s[3] <= '9';
    return false;
}

/// The number of UTF-16 code units well-formed UTF-8 `s` encodes to.
size_t utf16Length(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t units;
    foreach (c; s)
    {
        if ((c & 0xC0) != 0x80)
            ++units;
        if ((c & 0xF8) == 0xF0)
            ++units; // a supplementary character takes a surrogate pair
    }
    return units;
}

///
@("vfs.names.checkName")
@safe pure nothrow @nogc unittest
{
    assert(isValidName("a"));
    assert(isValidName("a..b"));
    assert(isValidName(".hidden"));
    assert(checkName("") == ErrorKind.invalidName);
    assert(checkName(".") == ErrorKind.invalidName);
    assert(checkName("..") == ErrorKind.invalidName);
    assert(checkName("a/b") == ErrorKind.invalidName);
    assert(checkName("a\0b") == ErrorKind.invalidName);

    char[256] long_ = 'x';
    assert(checkName(long_[]) == ErrorKind.nameTooLong);
    assert(isValidName(long_[0 .. 255]));

    assert(isReservedDeviceName("CON"));
    assert(isReservedDeviceName("com7.txt"));
    assert(isReservedDeviceName("Lpt0"));
    assert(!isReservedDeviceName("COM10"));
    assert(!isReservedDeviceName("console"));
    assert(utf16Length("a\u00e9\U0001F600") == 4);

    version (Windows)
    {
        assert(checkName("CON") == ErrorKind.invalidName);
        assert(checkName("a:b") == ErrorKind.invalidName);
        assert(checkName("x.") == ErrorKind.invalidName);
        assert(checkName("x ") == ErrorKind.invalidName);
        assert(checkName("a\\b") == ErrorKind.invalidName);
        assert(checkName("\xFF") == ErrorKind.invalidName);
    }
    else
    {
        assert(isValidName("CON"));
        assert(isValidName("a:b"));
        assert(isValidName("x."));
    }
}

/**
Whether `path` is absolute by the rules of VFP3: it begins with a separator,
or on Windows with a drive letter (`C:`), which also covers UNC (`\\server`)
and NT (`\??\`) prefixes since those begin with a separator.
*/
bool isAbsolutePath(scope const(char)[] path) @safe pure nothrow @nogc
{
    if (path.length && isSeparator(path[0]))
        return true;
    version (Windows)
    {
        if (path.length >= 2 && path[1] == ':'
            && ((path[0] >= 'a' && path[0] <= 'z') || (path[0] >= 'A' && path[0] <= 'Z')))
            return true;
    }
    return false;
}

/**
The components of a path (VFP3): split on separators, with empty and `.`
components dropped. `..` components are kept.
*/
struct PathComponents
{
    private const(char)[] path;
    private size_t pos, start, end;
    private bool done;

    ///
    this(return scope const(char)[] path) @safe pure nothrow @nogc
    {
        this.path = path;
        popFront();
    }

    ///
    bool empty() const scope @safe pure nothrow @nogc => done;

    ///
    const(char)[] front() const return scope @safe pure nothrow @nogc => path[start .. end];

    ///
    void popFront() scope @safe pure nothrow @nogc
    {
        while (pos < path.length)
        {
            size_t e = pos;
            while (e < path.length && !isSeparator(path[e]))
                ++e;
            const s = pos;
            pos = e < path.length ? e + 1 : e;
            if (e > s && !(e - s == 1 && path[s] == '.'))
            {
                start = s;
                end = e;
                return;
            }
        }
        done = true;
    }
}

/// ditto
PathComponents pathComponents(return scope const(char)[] path) @safe pure nothrow @nogc
    => PathComponents(path);

///
@("vfs.names.pathComponents")
@safe pure nothrow @nogc unittest
{
    auto c = pathComponents("./a//b/./../c/");
    assert(c.front == "a"); c.popFront();
    assert(c.front == "b"); c.popFront();
    assert(c.front == ".."); c.popFront();
    assert(c.front == "c"); c.popFront();
    assert(c.empty);
    assert(pathComponents("").empty);
    assert(pathComponents("./.").empty);
}

/**
Checks a walk path before any backend call (VFP3, VFP6): `escapesRoot` for an
absolute path, then each component in order, `invalidName` or `nameTooLong`
for a bad one and `dotDotRefused` for a `..` under `dotDot = reject`.
Returns `ErrorKind.other` when the path may be walked.
*/
ErrorKind checkWalkPath(scope const(char)[] path, ResolvePolicy policy)
    @safe pure nothrow @nogc
{
    if (isAbsolutePath(path))
        return ErrorKind.escapesRoot;
    foreach (c; pathComponents(path))
    {
        if (c == "..")
        {
            if (policy.dotDot == DotDotPolicy.reject)
                return ErrorKind.dotDotRefused;
            continue;
        }
        const k = checkName(c);
        if (k != ErrorKind.other)
            return k;
    }
    return ErrorKind.other;
}

///
@("vfs.names.checkWalkPath")
@safe pure nothrow @nogc unittest
{
    ResolvePolicy reject, inScope;
    inScope.dotDot = DotDotPolicy.inScope;

    assert(checkWalkPath("a/b", reject) == ErrorKind.other);
    assert(checkWalkPath("./a//b/.", reject) == ErrorKind.other);
    assert(checkWalkPath("", reject) == ErrorKind.other);
    assert(checkWalkPath("/etc", reject) == ErrorKind.escapesRoot);
    assert(checkWalkPath("/etc", inScope) == ErrorKind.escapesRoot);
    assert(checkWalkPath("..", reject) == ErrorKind.dotDotRefused);
    assert(checkWalkPath("a/../c", reject) == ErrorKind.dotDotRefused);
    assert(checkWalkPath("a/../c", inScope) == ErrorKind.other);
    assert(checkWalkPath("a/b\0c", inScope) == ErrorKind.invalidName);
    version (Windows)
    {
        assert(checkWalkPath(`C:\x`, reject) == ErrorKind.escapesRoot);
        assert(checkWalkPath(`\\server\share`, reject) == ErrorKind.escapesRoot);
        assert(checkWalkPath(`\??\C:`, reject) == ErrorKind.escapesRoot);
    }
}

/**
Checks a symbolic-link target before `symlinkAt` (VFO10): `escapesRoot` for an
absolute target, `invalidName` for an empty one or one containing NUL.
Returns `ErrorKind.other` when the target may be stored.
*/
ErrorKind checkLinkTarget(scope const(char)[] target) @safe pure nothrow @nogc
{
    if (target.length == 0)
        return ErrorKind.invalidName;
    foreach (c; target)
        if (c == '\0')
            return ErrorKind.invalidName;
    if (isAbsolutePath(target))
        return ErrorKind.escapesRoot;
    return ErrorKind.other;
}

///
@("vfs.names.checkLinkTarget")
@safe pure nothrow @nogc unittest
{
    assert(checkLinkTarget("../../outside") == ErrorKind.other);
    assert(checkLinkTarget("a/b") == ErrorKind.other);
    assert(checkLinkTarget("/etc") == ErrorKind.escapesRoot);
    assert(checkLinkTarget("") == ErrorKind.invalidName);
    assert(checkLinkTarget("a\0b") == ErrorKind.invalidName);
    version (Windows)
        assert(checkLinkTarget(`C:\x`) == ErrorKind.escapesRoot);
}

/// An `IoError` for a lexical refusal: no backend call was made.
IoError lexicalError(ErrorKind kind, OpKind op) @safe pure nothrow @nogc
    => IoError(kind, 0, op, IoErrorStage.completion, "refused before any backend call");
