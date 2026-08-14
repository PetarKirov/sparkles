/**
The release manifest (`FDR8`).

The packaging pipeline's rule is that a manifest is generated from the actual
bytes, after signing — signing changes them — and never duplicated from
configuration. This is that record: what was published, from which source, and
with which signature.

It exists so the APK served from object storage can be matched against the one
attached to the GitHub Release, and both against the tag they claim to be.
*/
module sparkles.release.store.manifest;

@safe:

/// One published artifact.
struct ReleaseManifest
{
    string applicationId;
    string tag;
    string versionName;
    uint versionCode;
    string fileName;
    ulong size;
    /// Lowercase hex SHA-256 of the signed file.
    string sha256;
    /// SHA-256 of the signing certificate, as `AllowedAPKSigningKeys` spells it.
    string signerFingerprint;
    /// Store path of the unsigned input, which pins the whole build closure.
    string unsignedStorePath;
}

/// Renders the manifest as JSON.
///
/// Hand-rolled rather than reflected: the field order is part of what makes two
/// manifests diffable, and every value here is a string or an integer.
string toJson(const ReleaseManifest m) pure
{
    import std.array : appender;
    import std.conv : text;

    auto w = appender!string;

    void field(string key, string value, bool last = false)
    {
        w ~= "  \"" ~ key ~ "\": \"" ~ escape(value) ~ "\"";
        w ~= last ? "\n" : ",\n";
    }

    w ~= "{\n";
    field("applicationId", m.applicationId);
    field("tag", m.tag);
    field("versionName", m.versionName);
    w ~= text("  \"versionCode\": ", m.versionCode, ",\n");
    field("fileName", m.fileName);
    w ~= text("  \"size\": ", m.size, ",\n");
    field("sha256", m.sha256);
    field("signerFingerprint", m.signerFingerprint);
    field("unsignedStorePath", m.unsignedStorePath, true);
    w ~= "}\n";
    return w[];
}

/// Escapes the characters JSON requires. Store paths and version strings never
/// contain control characters, but a manifest that silently emitted invalid
/// JSON would be worse than one that refused to.
private string escape(string s) pure
{
    import std.array : appender;
    import std.format : format;

    auto w = appender!string;
    foreach (char c; s)
    {
        switch (c)
        {
        case '"': w ~= `\"`; break;
        case '\\': w ~= `\\`; break;
        case '\n': w ~= `\n`; break;
        case '\r': w ~= `\r`; break;
        case '\t': w ~= `\t`; break;
        default:
            if (c < 0x20)
                w ~= format(`\u%04x`, c);
            else
                w ~= c;
        }
    }
    return w[];
}

@("store.manifest.rendersParseableJson")
@safe unittest
{
    import std.json : parseJSON;

    const m = ReleaseManifest(
        applicationId: "dev.sparkles.hue",
        tag: "v0.4.0",
        versionName: "0.4.0",
        versionCode: 1024,
        fileName: "dev.sparkles.hue_1024.apk",
        size: 64_439_784,
        sha256: "a".replicated(64),
        signerFingerprint: "b".replicated(64),
        unsignedStorePath: "/nix/store/xxx-hue-unsigned-0.4.0",
    );

    const parsed = parseJSON(toJson(m));
    assert(parsed["applicationId"].str == "dev.sparkles.hue");
    assert(parsed["tag"].str == "v0.4.0");
    assert(parsed["versionCode"].integer == 1024);
    assert(parsed["size"].integer == 64_439_784);
    assert(parsed["sha256"].str.length == 64);
    assert(parsed["unsignedStorePath"].str == "/nix/store/xxx-hue-unsigned-0.4.0");
}

@("store.manifest.escapesRatherThanEmittingInvalidJson")
@safe unittest
{
    import std.json : parseJSON;

    ReleaseManifest m;
    m.tag = `he said "hi"\` ~ "\n\t";
    // The point is that this parses at all.
    const parsed = parseJSON(toJson(m));
    assert(parsed["tag"].str == m.tag);
}

version (unittest)
{
    private string replicated(string s, size_t n) pure
    {
        import std.array : replicate;

        return s.replicate(n);
    }
}
