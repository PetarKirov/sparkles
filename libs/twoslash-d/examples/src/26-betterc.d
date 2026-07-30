module sample;
// @dflags: -betterC
// @errors: throw
// ---cut---
/// `-betterC` drops the exception machinery, so the `throw` is rejected.
extern (C) int main()
{
    if (compute() < 0)
        throw new Exception("negative");
    return 0;
}

int compute() => 7;
//  ^?
