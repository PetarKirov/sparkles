// ---cut-start---
module sample;
import std.math : abs;
// ---cut-end---
/// The distance between two bounds, in either order.
double spread(double lo, double hi) => abs(hi - lo);

auto width = spread(2.5, -1.0);
//   ^?
//           ^?
// ---cut-after---
unittest { assert(width == 3.5); }
