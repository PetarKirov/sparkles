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

/// ditto
unittest
{
    // A second example needs no second write-up — that is what the idiom is
    // for, so the word `ditto` must not reach the popup as prose.
    assert(larger(-1, -5) == -1);
}

auto top = larger(10, 20);
//   ^?
//         ^?
