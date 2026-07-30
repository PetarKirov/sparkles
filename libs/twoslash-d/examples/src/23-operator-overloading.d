module sample;
// ---cut---
/// A 2-D vector with component-wise arithmetic.
struct Vec2
{
    double x, y;

    /// Adds or subtracts component-wise.
    Vec2 opBinary(string op)(Vec2 rhs) const
    //   ^?
    if (op == "+" || op == "-")
        => Vec2(mixin("x " ~ op ~ " rhs.x"), mixin("y " ~ op ~ " rhs.y"));
}

auto sum = Vec2(1, 2) + Vec2(3, 4);
//   ^?
