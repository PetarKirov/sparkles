// ImportC shim for ICU (icu4c) grapheme segmentation — scoped to the
// text-conformance harness. File stem `icu_c` ⇒ module `icu_c` (unique; see the
// ImportC guideline's stem-collision note).
//
// ICU renames its C symbols with a version suffix (`ubrk_open` → `ubrk_open_76`)
// via macros in <unicode/urename.h>, so we don't expose `ubrk_*` to D directly.
// Instead this shim *defines* one stable wrapper function (ImportC compiles C
// function bodies); the renaming macros resolve the ICU calls inside the body at
// preprocess time. The wrapper also hides ICU's UTF-16 / UChar types from D.
//
// `nogc nothrow` (no D GC, no D throw); not `pure` (ICU has global state).
#pragma attribute(push, nogc, nothrow)
#include <unicode/utypes.h>
#include <unicode/ubrk.h>
#include <unicode/ustring.h>
#include <unicode/utf16.h>

// Segment `utf8[0..nbytes)` into grapheme clusters (UBRK_CHARACTER) and write
// each cluster's length **in code points** into `outBuf[0..outcap)`. Returns the
// cluster count, or -1 on error / if the count would exceed `outcap`.
int sp_icu_grapheme_lengths(const char* utf8, int nbytes, int* outBuf, int outcap)
{
    UErrorCode ec = U_ZERO_ERROR;
    UChar u16[8192];
    int32_t ulen = 0;
    u_strFromUTF8(u16, 8192, &ulen, utf8, nbytes, &ec);
    if (U_FAILURE(ec))
        return -1;

    UBreakIterator* bi = ubrk_open(UBRK_CHARACTER, "", u16, ulen, &ec);
    if (U_FAILURE(ec))
        return -1;

    int count = 0;
    int32_t a = ubrk_first(bi);
    for (int32_t b = ubrk_next(bi); b != UBRK_DONE; a = b, b = ubrk_next(bi))
    {
        int cps = 0;
        for (int32_t i = a; i < b;)
        {
            UChar32 c;
            U16_NEXT(u16, i, b, c);
            (void) c;
            cps++;
        }
        if (count >= outcap)
        {
            ubrk_close(bi);
            return -1;
        }
        outBuf[count++] = cps;
    }
    ubrk_close(bi);
    return count;
}
#pragma attribute(pop)
