module sample;
// ---cut---
/// Rounds x toward zero.
int truncate(double x) => cast(int) x;
/// ditto
long truncate(real x) => cast(long) x;

int wide(double x) => cast(int) x; /// A postfix doc comment.

auto a = truncate(2.7);
//       ^?
auto b = truncate(2.7L);
//       ^?
auto c = wide(2.7);
//       ^?
