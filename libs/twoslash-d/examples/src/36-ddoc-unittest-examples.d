module sample;
// @dflags: -unittest
// ---cut---
/++
Returns the larger of two ints.
Returns: a when it is at least b.
+/
int larger(int a, int b) => a >= b ? a : b;

/// The documented-unittest form: this example belongs to `larger`.
unittest
{
    assert(larger(2, 3) == 3);
}

auto top = larger(10, 20);
//   ^?
//         ^?
