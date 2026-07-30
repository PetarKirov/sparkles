module sample;
import std.algorithm.iteration : filter, map;
import std.array : array;
// ---cut---
/// Keeps the readings above three, then scales what is left by ten.
int[] scaled(int[] readings)
{
    auto loud = readings.filter!(x => x > 3);
//       ^?
    auto tenfold = loud.map!(x => x * 10);
//       ^?
    return tenfold.array;
//                 ^?
}
