// The official C implementation's API (libblake3), imported through ImportC.
// `nothrow @nogc` on the D side; not `pure`, the hasher is caller state.
#pragma attribute(push, nogc, nothrow)
#include <blake3.h>
#pragma attribute(pop)
