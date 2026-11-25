@safe pure nothrow @nogc:
int sum(scope int delegate() @safe pure nothrow @nogc [] xs...) { int s; foreach (x; xs) s += x(); return s; }
int g(int a, int b) => sum(a, b + 1);                // locals captured
int h(ref int a) => sum(a, 2);                        // ref param captured
int k(int a) => sum(sum(a), 1);                       // nested
void lz(scope lazy int x) {}                           // plain lazy for comparison
void m(int a) { lz(a + 1); }
