/**
Registry sources without Nix (build-graph SPEC BGR4): the packages the dub
lockfiles pin, fetched by the lockfile's URL into the build store and
verified by the lockfile's hash.

$(LREF fetchLockedSources) fills `<store>/sources/` in the layout the
flake's `dub-sources` output has, `.dub/packages/<name>/<version>/<name>/`,
so $(REF nixRegistrySources, sparkles,build_primitives,resolve,registry)
serves either tree. A registry package is code.dlang.org's archive, checked
against its flat SHA-256 and unpacked without its top directory; a
repository package is a git checkout of the pinned commit, checked against
the SHA-256 of its NAR serialisation ($(LREF narDigest)) without `.git`, as
Nix's `fetchgit` hashes it. Each is unpacked into a staging entry and
published by one rename, so a reader sees a whole source or none.

The network is the caller's: a $(LREF Fetcher) downloads a URL to a path and
checks out a commit into a directory. Everything else goes through the VFS.
*/
module sparkles.build_graph.fetch;

import std.algorithm.searching : startsWith;
import std.conv : text;

import sparkles.base.vfs.types : EntryKind, StatMask;
import sparkles.build_primitives.resolve.registry : LockedPackage;

/// What fetching needs of the network, by absolute paths (BGR4).
struct Fetcher
{
    /// Downloads `url` to the file `destination`; false on failure.
    bool delegate(string url, string destination) download;
    /// Clones `url` and checks out `commit` into the directory `destination`.
    bool delegate(string url, string commit, string destination) checkout;
    /**
    Places the verified registry archive `archive` of `name` at `version_`
    as the new directory `destination` holds it, the way dub's own fetch
    does (it rewrites the recipe it places). Null unpacks the archive
    instead: its members without their top directory.
    */
    bool delegate(string name, string version_, string archive, string destination) place;
}

/// Nix's base-32 alphabet: digits and letters, without `e`, `o`, `u` and `t`.
private enum nixAlphabet = "0123456789abcdfghijklmnpqrsvwxyz";

/// A SHA-256 digest in Nix's base 32, as lockfiles and `nix-hash` write it.
string nixBase32(const ubyte[32] digest) @safe pure nothrow
{
    enum length = (32 * 8 - 1) / 5 + 1; // 52
    char[length] s;
    foreach (k; 0 .. length)
    {
        const n = length - 1 - k;
        const b = n * 5, i = b / 8, j = b % 8;
        uint c = digest[i] >> j;
        if (i + 1 < 32)
            c |= digest[i + 1] << (8 - j);
        s[k] = nixAlphabet[c & 0x1f];
    }
    return s[].idup;
}

/// Parses a SHA-256 digest in Nix's base 32; false if it is not one.
bool parseNixBase32(scope const(char)[] s, out ubyte[32] digest) @safe pure nothrow @nogc
{
    enum length = 52;
    if (s.length != length)
        return false;
    foreach (k, ch; s)
    {
        int c = -1;
        foreach (v, a; nixAlphabet)
            if (a == ch)
                c = cast(int) v;
        if (c < 0)
            return false;
        const n = length - 1 - k;
        const b = n * 5, i = b / 8, j = b % 8;
        digest[i] |= cast(ubyte)(c << j);
        if (i + 1 < 32)
            digest[i + 1] |= cast(ubyte)(c >> (8 - j));
        else if (c >> (8 - j))
            return false; // bits beyond the digest
    }
    return true;
}

/// A lockfile's SHA-256, in Nix's base 32 or as an SRI hash (`sha256-<base64>`).
bool parseLockHash(scope const(char)[] s, out ubyte[32] digest) @safe pure
{
    import std.base64 : Base64, Base64Exception;

    if (!s.startsWith("sha256-"))
        return parseNixBase32(s, digest);
    try
    {
        const bytes = Base64.decode(s["sha256-".length .. $]);
        if (bytes.length != 32)
            return false;
        digest[] = bytes[];
        return true;
    }
    catch (Base64Exception)
        return false;
}

/**
The SHA-256 of the NAR serialisation of the directory `dir`, Nix's
recursive hash of a tree: its entries in name order, each a regular file
(with its executable bit), a link (with its target) or a directory.
*/
bool narDigest(D)(ref D dir, out ubyte[32] digest)
{
    import std.digest.sha : SHA256;

    SHA256 h;
    h.start();
    void str(scope const(ubyte)[] bytes)
    {
        ulong n = bytes.length;
        ubyte[8] le;
        foreach (i; 0 .. 8)
            le[i] = cast(ubyte)(n >> (8 * i));
        h.put(le[]);
        h.put(bytes);
        static immutable ubyte[8] zeros;
        if (n % 8)
            h.put(zeros[0 .. 8 - n % 8]);
    }
    void s(scope const(char)[] t) => str(cast(const(ubyte)[]) t);

    bool directory(E)(ref E d)
    {
        import std.algorithm.sorting : sort;

        string[] names;
        auto listing = d.list();
        if (listing.hasError)
            return false;
        while (true)
        {
            auto more = listing.value.next();
            if (more.hasError)
                return false;
            if (!more.value)
                break;
            names ~= listing.value.front.name.idup;
        }
        s("type");
        s("directory");
        foreach (name; names.sort)
        {
            auto st = d.statAt(name, StatMask.basic);
            if (st.hasError)
                return false;
            s("entry");
            s("(");
            s("name");
            s(name);
            s("node");
            s("(");
            if (st.value.kind == EntryKind.directory)
            {
                auto sub = d.walk(name);
                if (sub.hasError || !directory(sub.value))
                    return false;
            }
            else if (st.value.kind == EntryKind.symlink)
            {
                char[4096] buffer;
                auto target = d.readlinkAt(name, buffer[]);
                if (target.hasError)
                    return false;
                s("type");
                s("symlink");
                s("target");
                s(target.value);
            }
            else
            {
                import sparkles.build_graph.store : readBytes;

                ubyte[] bytes;
                if (!readBytes(d, name, bytes))
                    return false;
                s("type");
                s("regular");
                if (st.value.executable)
                {
                    s("executable");
                    s("");
                }
                s("contents");
                str(bytes);
            }
            s(")");
            s(")");
        }
        return true;
    }

    s("nix-archive-1");
    s("(");
    if (!directory(dir))
        return false;
    s(")");
    digest = h.finish();
    return true;
}

/**
Fetches each of `packages` not already in the sources tree `sources` (a
directory handle on `<store>/sources`, at the absolute `sourcesPath`) by the
lockfile's URL, verifies it by the lockfile's hash, and publishes it there.

Returns: null when every package is in place, or why one is not.
*/
string fetchLockedSources(D)(const LockedPackage[] packages, ref D sources, string sourcesPath, Fetcher fetcher)
{
    import std.digest.sha : sha256Of;
    import sparkles.build_graph.store : readBytes, statPath;

    if (sources.walkAll("staging").hasError)
        return "cannot create " ~ sourcesPath ~ "/staging";
    foreach (ref p; packages)
    {
        const place = ".dub/packages/" ~ p.name ~ "/" ~ p.version_;
        if (!statPath(sources, place ~ "/" ~ p.name).hasError)
            continue; // published whole, or not at all
        ubyte[32] expected;
        if (!parseLockHash(p.sha256, expected))
            return text("`", p.name, "` (", p.lock, "): its sha256 is neither Nix base 32 nor an SRI hash");
        const stage = p.name ~ "-" ~ p.version_;
        auto staging = sources.walk("staging");
        cast(void) staging.value.removeTree(stage);
        cast(void) staging.value.removeTree(stage ~ ".zip");

        if (p.repository.length)
        {
            if (!fetcher.checkout(p.repository, p.version_, sourcesPath ~ "/staging/" ~ stage))
                return text("`", p.name, "`: cannot check out ", p.version_, " of ", p.repository);
            auto tree = staging.value.walk(stage);
            if (tree.hasError)
                return text("`", p.name, "`: the checkout is missing");
            cast(void) tree.value.removeTree(".git");
            ubyte[32] digest;
            if (!narDigest(tree.value, digest))
                return text("`", p.name, "`: cannot read the checkout");
            if (digest != expected)
                return text("`", p.name, "` ", p.version_, ": the checkout's NAR hash is ", nixBase32(digest),
                    ", the lock pins ", p.sha256);
        }
        else
        {
            const url = "https://code.dlang.org/packages/" ~ p.name ~ "/" ~ p.version_ ~ ".zip";
            if (!fetcher.download(url, sourcesPath ~ "/staging/" ~ stage ~ ".zip"))
                return text("`", p.name, "`: cannot download ", url);
            ubyte[] archive;
            if (!readBytes(staging.value, stage ~ ".zip", archive))
                return text("`", p.name, "`: the download is missing");
            const digest = sha256Of(archive);
            if (digest != expected)
                return text("`", p.name, "` ", p.version_, ": the archive's SHA-256 is ", nixBase32(digest),
                    ", the lock pins ", p.sha256);
            if (fetcher.place !is null)
            {
                if (!fetcher.place(p.name, p.version_, sourcesPath ~ "/staging/" ~ stage ~ ".zip",
                        sourcesPath ~ "/staging/" ~ stage))
                    return text("`", p.name, "`: cannot place the archive");
            }
            else if (const why = unpack(archive, staging.value, stage))
                return text("`", p.name, "`: ", why);
            cast(void) staging.value.unlinkAt(stage ~ ".zip");
        }
        auto parent = sources.walkAll(place);
        if (parent.hasError || staging.value.renameAt(stage, parent.value, p.name).hasError)
            return text("`", p.name, "`: cannot publish the source");
    }
    return null;
}

// Unpacks the zip `archive`'s members beneath `top` into the new directory
// `name` in `dir`, their executable bits kept; why not, or null.
private string unpack(D)(scope const(ubyte)[] archive, ref D dir, string name)
{
    import std.zip : ZipArchive, ZipException;
    import sparkles.base.vfs.types : Access, Disposition, OpenMode;

    ZipArchive zip;
    try
        zip = new ZipArchive(cast(void[]) archive.dup);
    catch (ZipException e)
        return "not a zip archive: " ~ e.msg;
    if (dir.mkdirAt(name).hasError)
        return "cannot create the staging entry";
    auto root = dir.walk(name);
    // The one top directory every member lies beneath (`<name>-<version>/`,
    // or a repository's own spelling), which the source does not keep.
    string top;
    foreach (memberName, _; zip.directory)
    {
        size_t slash = 0;
        while (slash < memberName.length && memberName[slash] != '/')
            ++slash;
        top = memberName[0 .. slash] ~ "/";
        break;
    }
    foreach (memberName, member; zip.directory)
    {
        if (!memberName.startsWith(top))
            return "a member outside " ~ top ~ ": " ~ memberName;
        const rest = memberName[top.length .. $];
        if (!rest.length || rest[$ - 1] == '/')
        {
            if (rest.length && root.value.walkAll(rest[0 .. $ - 1]).hasError)
                return "cannot create " ~ rest;
            continue;
        }
        size_t slash = rest.length;
        while (slash > 0 && rest[slash - 1] != '/')
            --slash;
        ubyte[] bytes;
        try
            bytes = cast(ubyte[]) zip.expand(member);
        catch (ZipException e)
            return "cannot expand " ~ rest ~ ": " ~ e.msg;
        const executable = ((member.fileAttributes >> 6) & 1) != 0;
        bool put(E)(ref E into, scope const(char)[] leaf)
        {
            enum plain = OpenMode(Access.write, Disposition.createNew);
            enum runnable = OpenMode(Access.write, Disposition.createNew, executable: true);
            if (executable)
            {
                auto file = into.openFile!runnable(leaf);
                return !file.hasError && !file.value.write(bytes).hasError;
            }
            auto file = into.openFile!plain(leaf);
            return !file.hasError && !file.value.write(bytes).hasError;
        }
        bool written;
        if (slash == 0)
            written = put(root.value, rest);
        else
        {
            auto into = root.value.walkAll(rest[0 .. slash - 1]);
            written = !into.hasError && put(into.value, rest[slash .. $]);
        }
        if (!written)
            return "cannot write " ~ rest;
    }
    return null;
}

/// Nix's base 32, both ways, on the digest `nix-hash` prints for `hello\n`.
@("build_graph.fetch.nixBase32")
@safe pure unittest
{
    import std.digest.sha : sha256Of;

    const digest = sha256Of("hello\n");
    assert(nixBase32(digest) == "00xyyr3fi8l6hb839bv3f7yb86yjv7xi1cgh1xnhipym4asvb4aq");
    ubyte[32] back;
    assert(parseNixBase32("00xyyr3fi8l6hb839bv3f7yb86yjv7xi1cgh1xnhipym4asvb4aq", back) && back == digest);
    assert(!parseNixBase32("00xyyr3fi8l6hb839bv3f7yb86yjv7xi1cgh1xnhipym4asvb4ae", back)); // `e` is not in it
    assert(!parseNixBase32("short", back));
}

/// A lock's hash in either spelling.
@("build_graph.fetch.parseLockHash")
@safe pure unittest
{
    import std.digest.sha : sha256Of;

    ubyte[32] a, b;
    assert(parseLockHash("00xyyr3fi8l6hb839bv3f7yb86yjv7xi1cgh1xnhipym4asvb4aq", a));
    assert(parseLockHash("sha256-WJG1tSLV3whtD/CxEPvZ0hu0/HFjrzTQgoai6Eb2vgM=", b));
    assert(a == b && a == sha256Of("hello\n"));
    assert(!parseLockHash("sha256-short", a));
}
