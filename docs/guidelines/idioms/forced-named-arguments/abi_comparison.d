// Compare ABI codegen: normal vs NamedOnly sentinel
// Compile with: ldc2 -O2 -release -output-s abi_comparison.d
//
// Finding: free-function sentinel is zero-overhead (identical asm).
// Struct-field sentinel adds sizeof/alignment overhead (1 byte + padding).

private struct NamedOnly {}

struct Rect
{
    int x, y, width, height;
}

// NamedOnly is 1 byte => 4 bytes with alignment padding before the first int.
// RectNamed.sizeof == 20, Rect.sizeof == 16.
struct RectNamed
{
    NamedOnly _ = NamedOnly.init;
    int x, y, width, height;
}

pragma(msg, "NamedOnly.sizeof = ", NamedOnly.sizeof);
pragma(msg, "Rect.sizeof      = ", Rect.sizeof);
pragma(msg, "RectNamed.sizeof = ", RectNamed.sizeof);

// --- Free functions: zero overhead ---

export Rect withSentinel(
    NamedOnly _ = NamedOnly.init,
    int x = 0, int y = 0, int width = 0, int height = 0, int margin = 0,
)
{
    return Rect(x - margin, y - margin, width + 2 * margin, height + 2 * margin);
}

export Rect withoutSentinel(int x, int y, int width, int height, int margin)
{
    return Rect(x - margin, y - margin, width + 2 * margin, height + 2 * margin);
}

// --- Call sites ---

export Rect callSentinel(int x, int y, int w, int h, int m)
{
    return withSentinel(x: x, y: y, width: w, height: h, margin: m);
}

export Rect callPlain(int x, int y, int w, int h, int m)
{
    return withoutSentinel(x, y, w, h, m);
}
