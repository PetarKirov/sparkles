module sample;
// ---cut---
import std.algorithm.iteration : reduce;
import std.conv : toText = to;

enum total = reduce!((a, b) => a + b)([1, 2, 3, 4]);
//   ^?
enum label = toText!string(total);
//           ^?
