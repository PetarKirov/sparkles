/**
`ci --gc-r2` — garbage-collect the R2 binary cache (`sparkles-nix-cache`,
served at cache.sparkles.petar-kirov.dev).

Nix cannot collect a binary cache, and R2 never evicts, so this does what
`cachix pin --keep-revisions` does for Cachix, with git history as the
revision list. The roots are objects in the bucket, `gc-roots/<tree>/<label>`
(one store path per line, written by `ci/gc-root.sh` and
`ci/push-pin-set-r2.sh`), keyed by the git tree a build saw. A collection:

$(OL
    $(LI lists the bucket;)
    $(LI keeps the roots of the trees of the last `--keep-commits` commits on
        `HEAD`'s first-parent history, and every root younger than the grace
        period;)
    $(LI marks the closure of the kept roots' paths, and of every narinfo
        younger than the grace period, by walking narinfo `References`;)
    $(LI deletes the narinfos, listings and NARs nothing marked: narinfos
        before the NARs they name, so a client never sees a narinfo whose NAR
        is gone, then expired roots.)
)

The grace period covers open pull requests and uploads still in flight: `nix
copy` writes a NAR before its narinfo, so an unreferenced NAR may be one whose
narinfo is a second away.

Objects it does not recognise (`nix-cache-info`, `log/`, `realisations/`) are
never deleted. It refuses to collect when no root survives, rather than read
an empty root set as "everything is garbage".

The planning is pure and tested here; the S3 calls are `std.net.curl` with
libcurl's own SigV4 signing (`CURLOPT_AWS_SIGV4`).
*/
module r2_gc;

import core.time : Duration, days;
import std.algorithm.iteration : filter, map, splitter;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : array;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.format : format;
import std.string : indexOf, lineSplitter, strip;

import sparkles.base.expected : Expected, err, ok;

/// One object of a bucket listing.
struct S3Object
{
    string key;
    ulong size;
    SysTime lastModified;
}

/// One page of `ListObjectsV2`.
struct ListPage
{
    S3Object[] objects;
    string nextToken; /// Empty on the last page.
}

/// What an object is to the collector.
enum Kind : ubyte
{
    narinfo, /// `<hash>.narinfo`
    listing, /// `<hash>.ls`, the NAR listing Nix may write beside it
    nar,     /// `nar/<file hash>.nar[.<compression>]`
    root,    /// `gc-roots/<tree>/<label>`
    other,   /// Anything else; never deleted.
}

private enum nixBase32 = "0123456789abcdfghijklmnpqrsvwxyz";

private bool isStoreHash(in char[] s) @safe pure nothrow @nogc
{
    if (s.length != 32)
        return false;
    foreach (char c; s)
    {
        bool found;
        foreach (char d; nixBase32)
            found |= c == d;
        if (!found)
            return false;
    }
    return true;
}

/// The kind of the object at `key`.
Kind kindOf(string key) @safe pure nothrow @nogc
{
    if (key.startsWith("gc-roots/"))
        return Kind.root;
    if (key.startsWith("nar/"))
        return Kind.nar;
    if (key.length == 32 + ".narinfo".length && key.endsWith(".narinfo") && isStoreHash(key[0 .. 32]))
        return Kind.narinfo;
    if (key.length == 32 + ".ls".length && key.endsWith(".ls") && isStoreHash(key[0 .. 32]))
        return Kind.listing;
    return Kind.other;
}

///
@("r2_gc.kindOf.classifiesTheCacheLayout")
@safe pure nothrow @nogc
unittest
{
    assert(kindOf("0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv.narinfo") == Kind.narinfo);
    assert(kindOf("0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv.ls") == Kind.listing);
    assert(kindOf("nar/1kd3hj2xa0g9v4q2fz5y3bwc9gk4zb8r.nar.zst") == Kind.nar);
    assert(kindOf("gc-roots/4b825dc642cb6eb9a060e54bf8d69288fbee4904/pin-set") == Kind.root);
    assert(kindOf("nix-cache-info") == Kind.other);
    assert(kindOf("log/0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv-hello.drv") == Kind.other);
    // `e`, `o`, `u` and `t` are not nix-base32.
    assert(kindOf("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.narinfo") == Kind.other);
}

/// The 32-character hash of a store path or store path basename.
Expected!(string, string) storeHash(string path) @safe pure
{
    import std.path : baseName;

    const base = path.baseName;
    if (base.length < 33 || base[32] != '-' || !isStoreHash(base[0 .. 32]))
        return err!string(format("not a store path: %s", path));
    return ok(base[0 .. 32]);
}

///
@("r2_gc.storeHash.pathsAndBasenames")
@safe pure
unittest
{
    assert(storeHash("/nix/store/0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv-hello-2.12").value
        == "0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv");
    assert(storeHash("0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv-hello").value == "0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv");
    assert(storeHash("/nix/store/short-hello").hasError);
}

/// The tree a root belongs to: `gc-roots/<tree>/<label>` → `<tree>`.
string rootTree(string key) @safe pure nothrow @nogc
{
    const rest = key["gc-roots/".length .. $];
    const slash = rest.indexOf('/');
    return slash < 0 ? null : rest[0 .. slash];
}

///
@("r2_gc.rootTree.splitsTheKey")
@safe pure nothrow @nogc
unittest
{
    assert(rootTree("gc-roots/abc123/all-desktop-x86_64-linux") == "abc123");
    assert(rootTree("gc-roots/abc123") is null);
}

private string xmlUnescape(string s) @safe pure
{
    import std.array : replace;

    if (s.indexOf('&') < 0)
        return s;
    return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
        .replace("&apos;", "'").replace("&amp;", "&");
}

private string element(string xml, string name) @safe pure
{
    const open = "<" ~ name ~ ">", close = "</" ~ name ~ ">";
    const start = xml.indexOf(open);
    if (start < 0)
        return null;
    const from = start + open.length;
    const end = xml.indexOf(close, from);
    return end < 0 ? null : xml[from .. end];
}

/// Parse one `ListObjectsV2` response body.
Expected!(ListPage, string) parseListPage(string xml) @safe
{
    if (xml.indexOf("<ListBucketResult") < 0)
        return err!ListPage("not a ListObjectsV2 response: " ~ xml[0 .. $ < 200 ? $ : 200]);

    ListPage page;
    string rest = xml;
    while (true)
    {
        const start = rest.indexOf("<Contents>");
        if (start < 0)
            break;
        const end = rest.indexOf("</Contents>", start);
        if (end < 0)
            return err!ListPage("unterminated <Contents>");
        const item = rest[start .. end];
        rest = rest[end + "</Contents>".length .. $];

        const key = item.element("Key");
        const size = item.element("Size");
        const modified = item.element("LastModified");
        if (key is null || size is null || modified is null)
            return err!ListPage("a <Contents> without Key, Size or LastModified");
        try
            page.objects ~= S3Object(key.xmlUnescape, size.to!ulong, SysTime.fromISOExtString(modified));
        catch (Exception e)
            return err!ListPage(format("unreadable <Contents> for %s: %s", key, e.msg));
    }
    if (xml.element("IsTruncated") == "true")
    {
        page.nextToken = xml.element("NextContinuationToken").xmlUnescape;
        if (page.nextToken.length == 0)
            return err!ListPage("a truncated listing without a NextContinuationToken");
    }
    return ok(page);
}

///
@("r2_gc.parseListPage.objectsAndContinuation")
@safe
unittest
{
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>
<Contents><Key>nix-cache-info</Key><LastModified>2026-11-07T10:00:00.000Z</LastModified><ETag>"x"</ETag><Size>47</Size></Contents>
<Contents><Key>gc-roots/t/a&amp;b</Key><LastModified>2026-11-08T16:06:23.000Z</LastModified><Size>120</Size></Contents>
<IsTruncated>true</IsTruncated><NextContinuationToken>abc=</NextContinuationToken></ListBucketResult>`;
    const page = parseListPage(xml).value;
    assert(page.objects.length == 2);
    assert(page.objects[0].key == "nix-cache-info" && page.objects[0].size == 47);
    assert(page.objects[1].key == "gc-roots/t/a&b");
    assert(page.objects[1].lastModified == SysTime.fromISOExtString("2026-11-08T16:06:23Z"));
    assert(page.nextToken == "abc=");

    const last = parseListPage(`<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>`).value;
    assert(last.objects.length == 0 && last.nextToken.length == 0);
    assert(parseListPage("<Error><Code>AccessDenied</Code></Error>").hasError);
}

/// What the collector needs from a narinfo.
struct Narinfo
{
    string url;          /// The NAR's key, relative to the bucket (`nar/…`).
    string[] references; /// Hashes of the store paths it references.
}

/// Parse a narinfo's `URL` and `References`.
Expected!(Narinfo, string) parseNarinfo(string text) @safe pure
{
    Narinfo info;
    foreach (line; text.lineSplitter)
    {
        const colon = line.indexOf(": ");
        if (colon < 0)
            continue;
        const field = line[0 .. colon], value = line[colon + 2 .. $].strip;
        if (field == "URL")
            info.url = value;
        else if (field == "References")
        {
            foreach (reference; value.splitter(' ').filter!(r => r.length))
            {
                auto hash = storeHash(reference);
                if (hash.hasError)
                    return err!Narinfo(hash.error);
                info.references ~= hash.value;
            }
        }
    }
    if (info.url.length == 0)
        return err!Narinfo("a narinfo without a URL");
    return ok(info);
}

///
@("r2_gc.parseNarinfo.urlAndReferenceHashes")
@safe pure
unittest
{
    const text = "StorePath: /nix/store/0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv-hello\n"
        ~ "URL: nar/1kd3hj2xa0g9v4q2fz5y3bwc9gk4zb8r.nar.zst\nCompression: zstd\n"
        ~ "References: 0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv-hello 1b6h99dw7bk4wbn77kbalih42zbc67m1-elfutils\n";
    const info = parseNarinfo(text).value;
    assert(info.url == "nar/1kd3hj2xa0g9v4q2fz5y3bwc9gk4zb8r.nar.zst");
    assert(info.references == ["0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrv", "1b6h99dw7bk4wbn77kbalih42zbc67m1"]);

    assert(parseNarinfo("StorePath: /nix/store/x\nReferences: \n").hasError, "no URL");
    assert(parseNarinfo("URL: nar/a.nar\nReferences: \n").value.references.length == 0);
}

/**
The live set: every store path reachable from `seeds` through narinfo
references, and the NARs their narinfos name.

`fetch` takes a batch of hashes (one frontier of the walk) and returns, per
hash, its narinfo's text, `null` when the bucket has no such narinfo, or an
error. An error ends the walk: deleting on a partial read could delete what a
narinfo the walk failed to read still needs. A seed or reference the bucket
lacks is recorded in `missing` and does not end it.
*/
struct LiveSet
{
    bool[string] paths; /// Store hashes.
    bool[string] nars;  /// NAR keys.
    string[] missing;   /// Store hashes named but absent.
}

/// ditto
Expected!(LiveSet, string) markLive(alias fetch)(string[] seeds)
{
    LiveSet live;
    string[] frontier;
    foreach (hash; seeds)
        if (hash !in live.paths)
        {
            live.paths[hash] = true;
            frontier ~= hash;
        }

    while (frontier.length)
    {
        Expected!(string, string)[] texts = fetch(frontier);
        string[] next;
        foreach (i, hash; frontier)
        {
            if (texts[i].hasError)
                return err!LiveSet(format("reading %s.narinfo: %s", hash, texts[i].error));
            if (texts[i].value is null)
            {
                live.missing ~= hash;
                continue;
            }
            auto info = parseNarinfo(texts[i].value);
            if (info.hasError)
                return err!LiveSet(format("%s.narinfo: %s", hash, info.error));
            live.nars[info.value.url] = true;
            foreach (reference; info.value.references)
                if (reference !in live.paths)
                {
                    live.paths[reference] = true;
                    next ~= reference;
                }
        }
        frontier = next;
    }
    return ok(live);
}

version (unittest)
{
    private enum hA = "0a4clw4kzxwvs3h0xgd4rsqvzhbbrxra";
    private enum hB = "0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrb";
    private enum hC = "0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrc";
    private enum hD = "0a4clw4kzxwvs3h0xgd4rsqvzhbbrxrd";

    private string narinfoText(string hash, string[] references...) @safe pure
    {
        import std.algorithm.iteration : joiner;
        import std.conv : text;

        return text("StorePath: /nix/store/", hash, "-p\nURL: nar/", hash, ".nar.zst\nReferences: ",
            references.map!(r => r ~ "-p").joiner(" "), "\n");
    }

    private Expected!(string, string)[] fetchFrom(string[string] bucket, string[] hashes) @safe pure
    {
        Expected!(string, string)[] result;
        foreach (hash; hashes)
            result ~= ok(cast(string)(hash in bucket ? bucket[hash] : null));
        return result;
    }
}

///
@("r2_gc.markLive.walksReferencesAndRecordsMissing")
@safe pure
unittest
{
    // A → B → C, and A names D, which the bucket lacks.
    auto bucket = [
        hA: narinfoText(hA, hA, hB, hD),
        hB: narinfoText(hB, hC),
        hC: narinfoText(hC),
    ];
    const live = markLive!(hashes => fetchFrom(bucket, hashes))([hA]).value;
    assert(live.paths.length == 4);
    assert(hC in live.paths && "nar/" ~ hC ~ ".nar.zst" in live.nars);
    assert(live.missing == [hD]);
}

///
@("r2_gc.markLive.aReadErrorEndsTheWalk")
@safe pure
unittest
{
    const res = markLive!(hashes => [err!string("timeout")])([hA]);
    assert(res.hasError);
}

/// What a collection keeps and deletes.
struct Plan
{
    string[] deleteNarinfos; /// Narinfos and listings, deleted first.
    string[] deleteNars;     /// Then the NARs.
    string[] deleteRoots;    /// Then the expired roots.
    ulong freedBytes;
    ulong keptBytes;
    size_t keptObjects;
}

/// Whether an object is younger than the grace period at `now`.
bool isYoung(in S3Object o, SysTime now, Duration grace) @safe
    => now - o.lastModified < grace;

/// The roots a collection keeps: those of `keepTrees`, and young ones.
S3Object[] keptRoots(S3Object[] objects, in string[] keepTrees, SysTime now, Duration grace) @safe
    => objects
        .filter!(o => o.key.kindOf == Kind.root)
        .filter!(o => keepTrees.canFind(o.key.rootTree) || o.isYoung(now, grace))
        .array;

/// Hashes of the narinfos younger than the grace period: seeds of the walk.
string[] youngNarinfos(S3Object[] objects, SysTime now, Duration grace) @safe
    => objects
        .filter!(o => o.key.kindOf == Kind.narinfo && o.isYoung(now, grace))
        .map!(o => o.key[0 .. 32])
        .array;

/// Sort every listed object into kept and deleted, given the live set.
Plan plan(S3Object[] objects, in LiveSet live, in string[] keepTrees, SysTime now, Duration grace) @safe
{
    Plan p;
    foreach (o; objects)
    {
        bool keep = o.isYoung(now, grace);
        string[]* bin;
        final switch (o.key.kindOf)
        {
            case Kind.narinfo:
            case Kind.listing:
                keep = keep || (o.key[0 .. 32] in live.paths) !is null;
                bin = &p.deleteNarinfos;
                break;
            case Kind.nar:
                keep = keep || (o.key in live.nars) !is null;
                bin = &p.deleteNars;
                break;
            case Kind.root:
                keep = keep || keepTrees.canFind(o.key.rootTree);
                bin = &p.deleteRoots;
                break;
            case Kind.other:
                keep = true;
                break;
        }
        if (keep)
        {
            p.keptBytes += o.size;
            p.keptObjects++;
        }
        else
        {
            *bin ~= o.key;
            p.freedBytes += o.size;
        }
    }
    return p;
}

///
@("r2_gc.plan.keepsLiveYoungAndUnknown")
@safe
unittest
{
    const now = SysTime.fromISOExtString("2026-12-01T00:00:00Z");
    const old = SysTime.fromISOExtString("2026-10-01T00:00:00Z");
    const recent = SysTime.fromISOExtString("2026-11-28T00:00:00Z");
    auto objects = [
        S3Object(hA ~ ".narinfo", 1, old),            // live
        S3Object("nar/" ~ hA ~ ".nar.zst", 100, old), // live
        S3Object(hB ~ ".narinfo", 1, old),            // dead
        S3Object(hB ~ ".ls", 1, old),                 // dead
        S3Object("nar/" ~ hB ~ ".nar.zst", 200, old), // dead
        S3Object("nar/orphan.nar.zst", 300, recent),  // young: an upload in flight
        S3Object("gc-roots/kept/pin-set", 5, old),
        S3Object("gc-roots/gone/pin-set", 5, old),
        S3Object("nix-cache-info", 47, old),
    ];
    LiveSet live;
    live.paths[hA] = true;
    live.nars["nar/" ~ hA ~ ".nar.zst"] = true;

    const p = plan(objects, live, ["kept"], now, 14.days);
    assert(p.deleteNarinfos == [hB ~ ".narinfo", hB ~ ".ls"]);
    assert(p.deleteNars == ["nar/" ~ hB ~ ".nar.zst"]);
    assert(p.deleteRoots == ["gc-roots/gone/pin-set"]);
    assert(p.freedBytes == 1 + 1 + 200 + 5);
    assert(p.keptObjects == 5);
}

///
@("r2_gc.keptRoots.treesAndYoung")
@safe
unittest
{
    const now = SysTime.fromISOExtString("2026-12-01T00:00:00Z");
    const old = SysTime.fromISOExtString("2026-10-01T00:00:00Z");
    auto objects = [
        S3Object("gc-roots/main1/all-desktop-x86_64-linux", 1, old),
        S3Object("gc-roots/pr/all-desktop-x86_64-linux", 1, SysTime.fromISOExtString("2026-11-30T00:00:00Z")),
        S3Object("gc-roots/stale/all-desktop-x86_64-linux", 1, old),
        S3Object(hA ~ ".narinfo", 1, SysTime.fromISOExtString("2026-11-30T00:00:00Z")),
        S3Object(hB ~ ".narinfo", 1, old),
    ];
    assert(keptRoots(objects, ["main1"], now, 14.days).map!(o => o.key.rootTree).array == ["main1", "pr"]);
    assert(youngNarinfos(objects, now, 14.days) == [hA]);
}

// ---------------------------------------------------------------------------
// The bucket, through R2's S3 API.

/// R2 credentials and the bucket's S3 endpoint.
struct Bucket
{
    string endpoint; /// `https://<account>.r2.cloudflarestorage.com`
    string name;
    string keyId;
    string secret;

    /// From `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID` and
    /// `R2_BUCKET` (default `sparkles-nix-cache`). `R2_ENDPOINT` replaces the
    /// account's endpoint, to point a test at a local S3 server.
    static Expected!(Bucket, string) fromEnvironment() @safe
    {
        import std.process : environment;

        Bucket b;
        b.keyId = environment.get("R2_ACCESS_KEY_ID", "");
        b.secret = environment.get("R2_SECRET_ACCESS_KEY", "");
        const account = environment.get("R2_ACCOUNT_ID", "");
        const endpoint = environment.get("R2_ENDPOINT", "");
        b.name = environment.get("R2_BUCKET", "sparkles-nix-cache");
        if (b.keyId.length == 0 || b.secret.length == 0 || (account.length == 0 && endpoint.length == 0))
            return err!Bucket("R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_ACCOUNT_ID are required");
        b.endpoint = endpoint.length ? endpoint : "https://" ~ account ~ ".r2.cloudflarestorage.com";
        return ok(b);
    }
}

/// A response: status and body.
struct Response
{
    ushort status;
    string body;
}

/// One signed request. `pathAndQuery` starts with `/` (the object key) or `?`.
Expected!(Response, string) request(in Bucket bucket, string method, string pathAndQuery) @system
{
    import std.net.curl : CurlOption, HTTP;

    // CURLOPT_AWS_SIGV4 (libcurl 7.75): CURLOPTTYPE_STRINGPOINT + 305. Phobos'
    // bindings predate it.
    enum awsSigV4 = cast(CurlOption) 10_305;
    try
    {
        auto http = HTTP(bucket.endpoint ~ "/" ~ bucket.name ~ pathAndQuery);
        switch (method)
        {
            case "GET": http.method = HTTP.Method.get; break;
            case "DELETE": http.method = HTTP.Method.del; break;
            default: return err!Response("unsupported method " ~ method);
        }
        http.handle.set(awsSigV4, "aws:amz:auto:s3");
        http.setAuthentication(bucket.keyId, bucket.secret);
        http.addRequestHeader("User-Agent", "sparkles-ci-gc-r2");
        ubyte[] received;
        http.onReceive = (ubyte[] data) { received ~= data; return data.length; };
        http.perform();
        return ok(Response(http.statusLine.code, cast(string) received));
    }
    catch (Exception e)
        return err!Response(e.msg);
}

/// Every object in the bucket.
Expected!(S3Object[], string) listAll(in Bucket bucket) @system
{
    import std.uri : encodeComponent;

    S3Object[] objects;
    string token;
    do
    {
        auto query = "?list-type=2&max-keys=1000";
        if (token.length)
            query ~= "&continuation-token=" ~ token.encodeComponent;
        auto response = request(bucket, "GET", query);
        if (response.hasError)
            return err!(S3Object[])(response.error);
        if (response.value.status != 200)
            return err!(S3Object[])(format("listing the bucket: HTTP %d: %s",
                response.value.status, response.value.body));
        auto page = parseListPage(response.value.body);
        if (page.hasError)
            return err!(S3Object[])(page.error);
        objects ~= page.value.objects;
        token = page.value.nextToken;
    }
    while (token.length);
    return ok(objects);
}

/// An object's body; `null` for a 404.
Expected!(string, string) getObject(in Bucket bucket, string key) @system
{
    auto response = request(bucket, "GET", "/" ~ key);
    if (response.hasError)
        return err!string(response.error);
    if (response.value.status == 404)
        return ok(cast(string) null);
    if (response.value.status != 200)
        return err!string(format("HTTP %d", response.value.status));
    // A present but empty body is still present.
    return ok(response.value.body is null ? "" : response.value.body);
}

/// Delete one object. S3 answers 204 whether or not it existed.
Expected!(void, string) deleteObject(in Bucket bucket, string key) @system
{
    auto response = request(bucket, "DELETE", "/" ~ key);
    if (response.hasError)
        return err!void(response.error);
    if (response.value.status != 204 && response.value.status != 200)
        return err!void(format("HTTP %d deleting %s", response.value.status, key));
    return ok();
}
