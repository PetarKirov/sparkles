module sample;
// ---cut---
int square(int x) => x * x;

int function(int) fp = &square;
//                ^?
/// Captures by, so the result is a delegate rather than a function pointer.
auto makeShift(int by)
{
    return delegate int(int x) => x + by;
}

int useShift()
{
    auto shift = makeShift(10);
//       ^?
    return shift(5);
}
