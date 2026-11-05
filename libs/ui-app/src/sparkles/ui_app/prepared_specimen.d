/// A loaded exact face and reusable metric workspace for interactive previews.
module sparkles.ui_app.prepared_specimen;

version (UiAppGuiVulkan):

import sparkles.font : cellMetrics, charMap, CharMap, Face, instance, Instance,
    InstanceSize, openFace, PointWorkspace, Ppem;
import sparkles.ui_app.specimen_font : sameFallbacks, sameSpecimenRequest, SpecimenFontRequest;
import sparkles.ui_vulkan.painter : TextMetrics;

/**
Owns bytes independently of the canvas. A size/coordinate update does no path
resolution, filesystem access, fallback discovery or content hashing.
*/
struct PreparedSpecimenFont
{
    SpecimenFontRequest request;
    const(ubyte)[] bytes;
    Face face;
    CharMap map;
    Instance inst;
    Ppem ppem;
    TextMetrics metrics;
    int cellW = 1, cellH = 1;
    private PointWorkspace* points;

    /// Failure preserves the last usable preview. Size is conventional em px.
    bool prepare(in SpecimenFontRequest wanted) @system
    {
        import std.file : read;
        if (wanted.path.length == 0 || wanted.px < 1 || wanted.px > 4096)
            return false;
        if (bytes.length && sameSpecimenRequest(wanted, request))
            return true;
        auto nextBytes = bytes;
        auto nextFace = face;
        auto nextMap = map;
        if (wanted.path != request.path || wanted.faceIndex != request.faceIndex || !bytes.length
            || wanted.bytes.ptr != request.bytes.ptr)
        {
            if (wanted.bytes.length)
                nextBytes = wanted.bytes;
            else
            {
                try
                    nextBytes = cast(const(ubyte)[]) read(wanted.path);
                catch (Exception)
                    return false;
            }
            const opened = openFace(nextBytes, wanted.faceIndex);
            if (opened.hasError)
                return false;
            nextFace = opened.value;
            const cmap = charMap(nextFace);
            if (cmap.hasError)
                return false;
            nextMap = cmap.value;
        }
        const size = Ppem.fromInteger(wanted.px);
        if (size.hasError)
            return false;
        const made = instance(nextFace, InstanceSize.pixels(size.value), wanted.coordinates);
        if (made.hasError)
            return false;
        if (points is null)
            points = new PointWorkspace;
        auto retainedFallbacks = request.fallbacks;
        if (!sameFallbacks(wanted.fallbacks, retainedFallbacks))
        {
            foreach (fallback; wanted.fallbacks)
            {
                const opened = openFace(fallback.bytes, fallback.faceIndex);
                if (opened.hasError || charMap(opened.value).hasError)
                    return false;
            }
            retainedFallbacks = wanted.fallbacks.dup;
        }
        const measured = cellMetrics(made.value, nextMap, wanted.px, *points);
        if (measured.hasError)
            return false;
        const m = measured.value;
        auto retainedCoordinates = request.coordinates;
        if (retainedCoordinates != wanted.coordinates)
            retainedCoordinates = wanted.coordinates.dup;
        request = wanted;
        request.coordinates = retainedCoordinates;
        request.fallbacks = retainedFallbacks;
        bytes = nextBytes;
        face = nextFace;
        map = nextMap;
        inst = made.value;
        ppem = size.value;
        cellW = cast(int)(m.width > 0 ? m.width : 1);
        cellH = cast(int)(m.height > 0 ? m.height : 1);
        metrics = TextMetrics(ascent: cast(int) m.baseline,
            underlineY: cast(int)(m.hasUnderline ? m.underlinePosition : m.baseline + 1),
            underlineHeight: cast(int)(m.hasUnderline && m.underlineThickness > 0 ? m.underlineThickness : 1),
            strikeY: cast(int) m.baseline - wanted.px / 3, present: true);
        return true;
    }
}

/// Preloaded data bypasses the filesystem and failed selections preserve the face.
@("ui_app.prepared_specimen.exactFaceAndWarmUpdates")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : Tag, UserCoordinate;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const bytes = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    auto request = SpecimenFontRequest(path: "/preloaded/not-a-real-file.ttf", px: 24, bytes: bytes);
    PreparedSpecimenFont prepared;
    assert(prepared.prepare(request));
    const originalBytes = prepared.bytes.ptr;
    const originalPoints = prepared.points;
    request.coordinates = [UserCoordinate(Tag("wght"), 900 << 16)];
    request.px = 32;
    assert(prepared.prepare(request));
    assert(prepared.bytes.ptr == originalBytes && prepared.points == originalPoints);
    assert(prepared.ppem == Ppem.fromInteger(32).value);
    assert(prepared.inst.coords.length && !prepared.inst.allZero);
    request.faceIndex = uint.max;
    assert(!prepared.prepare(request));
    assert(prepared.request.faceIndex == 0 && prepared.request.px == 32);
    assert(prepared.bytes.ptr == originalBytes);
    request.faceIndex = 0;
    import sparkles.ui_app.specimen_font : SpecimenFallbackFace;
    request.fallbacks = [SpecimenFallbackFace(bytes, 0, 42)];
    assert(prepared.prepare(request));
    const retained = prepared.request.fallbacks.ptr;
    request.px = 28;
    assert(prepared.prepare(request));
    assert(prepared.request.fallbacks.ptr == retained, "size updates retain the fallback set");
    request.fallbacks = [SpecimenFallbackFace(bytes, uint.max, 42)];
    assert(!prepared.prepare(request));
    assert(prepared.request.fallbacks.ptr == retained && prepared.request.px == 28);
}
