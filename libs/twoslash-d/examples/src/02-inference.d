module sample;
import std.algorithm.iteration : map;
import std.range : iota;
// ---cut---
auto squares(int n)
{
    return iota(n).map!(x => x * x);
}

auto tenSquares = squares(10);
//       ^?
