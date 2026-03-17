module lib;

/// Sentinel type — private to this module, impossible to name or construct
/// from the outside.
private struct NamedOnly {}

struct Rect
{
    int x, y, width, height;
}

/// Free function with sentinel — forces named args from other modules.
Rect inflateRect(NamedOnly _ = NamedOnly.init, int x = 0, int y = 0, int width = 0, int height = 0, int margin = 0)
{
    return Rect(x - margin, y - margin, width + 2 * margin, height + 2 * margin);
}

/// Struct with sentinel field.
struct RectOpts
{
    private struct NamedOnly {}

    NamedOnly _ = NamedOnly.init;
    int x, y, width, height;
}

Rect makeRect(RectOpts o)
{
    return Rect(o.x, o.y, o.width, o.height);
}
