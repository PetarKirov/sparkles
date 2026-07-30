module sample;
import std.algorithm.iteration : filter, map;
import std.range : iota;
// ---cut---
/// The even perfect squares below n * n, lazily.
auto evenSquares(int n)
{
    return iota(n).map!(x => x * x).filter!(x => x % 2 == 0);
}

auto xs = evenSquares(10);
//   ^?
