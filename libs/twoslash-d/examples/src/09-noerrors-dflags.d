module sample;
// @noErrors
// @dflags: -preview=dip1000
// ---cut---
/// Returns the first byte; `scope` promises the slice never escapes.
ubyte head(scope const(ubyte)[] bytes) @safe
in (bytes.length > 0)
=> bytes[0];

immutable ubyte[3] buf = [1, 2, 3];
auto first = head(buf[]);
//   ^?
//           ^?
