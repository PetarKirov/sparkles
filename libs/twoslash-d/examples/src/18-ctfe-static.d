module sample;
// ---cut---
/// Sums 1 .. n inclusive — an ordinary function, usable at compile time.
size_t triangular(size_t n)
{
    size_t acc;
    foreach (i; 1 .. n + 1)
        acc += i;
    return acc;
}

enum tenth = triangular(10);
//   ^?
static immutable size_t[3] firstThree = [triangular(1), triangular(2), triangular(3)];
//                         ^?
