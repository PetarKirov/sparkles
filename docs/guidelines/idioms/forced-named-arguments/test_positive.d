/// Positive tests — these must compile and produce correct results.
/// Run: dmd -i -run test_positive.d
import lib;

void main()
{
    import std.stdio : writefln;

    // Function: named args skip the sentinel
    auto r1 = lib.inflateRect(x: 10, y: 20, width: 100, height: 200, margin: 5);
    assert(r1 == lib.Rect(5, 15, 110, 210));

    // Function: partial named args (rest get defaults)
    auto r2 = lib.inflateRect(width: 50, height: 50);
    assert(r2 == lib.Rect(0, 0, 50, 50));

    // Struct: named field init skips sentinel
    auto r3 = lib.makeRect(lib.RectOpts(x: 10, y: 20, width: 100, height: 200));
    assert(r3 == lib.Rect(10, 20, 100, 200));

    writefln("All positive tests passed.");
}
