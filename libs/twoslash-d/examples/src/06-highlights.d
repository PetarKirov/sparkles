module sample;
// ---cut---
/// A point in the plane.
struct Point { double x, y; }

auto origin = Point(0, 0);
//            ^^^^^
//   ^^^^^^ the inferred variable
//   ^?
