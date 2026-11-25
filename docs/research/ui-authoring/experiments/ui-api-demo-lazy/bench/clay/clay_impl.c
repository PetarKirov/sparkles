/*
Clay (rev e6cc369; `clay.h` is fetched beside this file, see ../../README.md),
compiled by ImportC — the D compiler's own C compiler — on LDC and DMD alike. D imports
this file as module `clay_impl`; the bench also compiles it as a source.

Two ImportC workarounds, both without touching clay.h:

1. `CLAY_DISABLE_SIMD`: GCC's <emmintrin.h>/<mmintrin.h> declare 2/4/8-byte
    `vector_size` typedefs, which ImportC rejects ("vector type … is not
    supported on this platform"). The SIMD paths are only Clay__HashData (the
    text-measure cache key) and Clay__MemCmp; the elements this bench declares
    never reach either.

2. LDC (1.43): an all-default compound literal of a wrapper struct, unwrapped
    and passed by value — `f((W){ { } }.wrapped)`, which is what
    `CLAY(id, { })` and `CLAY_AUTO_ID()` expand to — is folded by the frontend
    to `T.init`, and LDC's codegen then fails with "no init symbol for
    zero-initialized struct" (fatal). Clay's own debug view has two such sites.
    DMD is unaffected. Fix: include the header once, then, for the
    implementation pass, redefine CLAY__CONFIG_WRAPPER to unwrap through a
    tiny function, which LDC compiles fine. Same semantics.
*/
#define CLAY_DISABLE_SIMD

#pragma attribute(push, nogc, nothrow)

#include "clay.h"

#define CLAY__UNWRAPPER(type) \
    static inline type Clay__Unwrap_##type(CLAY__WRAPPER_TYPE(type) w) { return w.wrapped; }
CLAY__UNWRAPPER(Clay_Padding)
CLAY__UNWRAPPER(Clay_LayoutConfig)
CLAY__UNWRAPPER(Clay_TextElementConfig)
CLAY__UNWRAPPER(Clay_AspectRatioElementConfig)
CLAY__UNWRAPPER(Clay_ImageElementConfig)
CLAY__UNWRAPPER(Clay_FloatingElementConfig)
CLAY__UNWRAPPER(Clay_CustomElementConfig)
CLAY__UNWRAPPER(Clay_ClipElementConfig)
CLAY__UNWRAPPER(Clay_BorderElementConfig)
CLAY__UNWRAPPER(Clay_TransitionElementConfig)
CLAY__UNWRAPPER(Clay_ElementDeclaration)
#undef CLAY__CONFIG_WRAPPER
#define CLAY__CONFIG_WRAPPER(type, ...) Clay__Unwrap_##type(CLAY__INIT(CLAY__WRAPPER_TYPE(type)) { __VA_ARGS__ })

#define CLAY_IMPLEMENTATION
#include "clay.h"

#pragma attribute(pop)
