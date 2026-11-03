/// Exact font selection for an independent preview, measured in em pixels.
module sparkles.ui_app.specimen_font;

import core.time : Duration, MonoTime;
import sparkles.font : UserCoordinate;

/// Coordinates borrow only during the request; hosts retain their own copy.
struct SpecimenFontRequest
{
    string path;
    uint faceIndex;
    int px = 18;
    const(UserCoordinate)[] coordinates;
    bool uiFollows;
    /// Optional preloaded owned bytes, retained through the next accepted request.
    const(ubyte)[] bytes;
    /// Optional precomputed FNV-1a of bytes, avoiding a foreground scan on load.
    ulong contentHash;
    /// Opt into supplied real bold/italic/bold-italic faces; missing faces use
    /// the exact selected face. Hosts never discover sibling files on resize.
    bool familyStyles;
    const(ubyte)[][3] styleBytes;
    uint[3] styleIndices;
    ulong[3] styleContentHashes;
    /// Monotonic request identity/timestamp supplied by the event handler.
    ulong generation;
    MonoTime requestedAt;
}

/// End-to-end preview timing; submission and observed display are separate.
struct SpecimenLatencyStats
{
    ulong submitted, shown, latestSubmittedGeneration, latestShownGeneration;
    Duration latestSubmitted, latestShown;
    ulong submissionDeadlineMisses, shownDeadlineMisses;
}

/// Tests request identity without scanning potentially large borrowed font bytes.
bool sameSpecimenRequest(in SpecimenFontRequest a, in SpecimenFontRequest b)
    @safe pure nothrow @nogc
    => a.path == b.path && a.faceIndex == b.faceIndex && a.px == b.px
        && a.uiFollows == b.uiFollows && a.coordinates == b.coordinates
        && a.familyStyles == b.familyStyles && sameStyles(a, b)
        && a.bytes.ptr == b.bytes.ptr && a.bytes.length == b.bytes.length;

/// Request timestamps do not force reconstruction; changed backing storage does.
@("ui_app.specimen_font.requestIdentity")
@safe pure nothrow unittest
{
    ubyte[] bytes = [1, 2, 3];
    auto first = SpecimenFontRequest(path: "font.ttf", bytes: bytes);
    auto other = first;
    other.generation = 2;
    assert(sameSpecimenRequest(first, other));
    other.bytes = bytes.dup;
    assert(!sameSpecimenRequest(first, other));
}

private bool sameStyles(in SpecimenFontRequest a, in SpecimenFontRequest b)
    @safe pure nothrow @nogc
{
    foreach (i; 0 .. 3)
        if (a.styleBytes[i].ptr != b.styleBytes[i].ptr
            || a.styleBytes[i].length != b.styleBytes[i].length
            || a.styleIndices[i] != b.styleIndices[i])
            return false;
    return true;
}
