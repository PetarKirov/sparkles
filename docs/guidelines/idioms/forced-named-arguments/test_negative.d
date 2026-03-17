/// Negative tests — these must ALL fail to compile.
/// Run: dmd -i -c test_negative.d
/// Expected: compilation errors for every call below.
import lib;

void main()
{
    // Positional function call — cannot pass `int` as `NamedOnly`
    auto r1 = lib.inflateRect(10, 20, 100, 200, 5);

    // Positional struct init — cannot convert `int` to `NamedOnly`
    auto r2 = lib.RectOpts(10, 20, 100, 200);
}
