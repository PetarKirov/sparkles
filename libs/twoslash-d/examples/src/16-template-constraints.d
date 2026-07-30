module sample;
import std.traits : isIntegral;
// ---cut---
/// Doubles only integral values — the constraint rides along into the tip.
T twice(T)(T x)
if (isIntegral!T)
    => cast(T)(x * 2);

auto n = twice(21);
//   ^?
//       ^?
