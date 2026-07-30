module sample;
// @dflags: -preview=dip1000
// @errors: escapes
// ---cut---
/// Slices a stack buffer and returns it — dip1000 rejects the escape.
int[] leak() @safe
{
    int[4] local = [1, 2, 3, 4];
    return local[];
//         ^?
}
