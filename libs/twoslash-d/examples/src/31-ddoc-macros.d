module sample;
// ---cut---
/++
Formats a byte count: $(B bold), $(I italic), $(D code(x)), and a
custom $(UNIT 4096).

Uses $(REF text, std,conv) and $(LREF parseBytes); runs in $(BIGOH 1).
See $(HTTP dlang.org/spec/ddoc.html, the DDoc spec) plus
$(SOMETHING undefined, args), which renders its arguments.

Macros:
    UNIT = $(B $0 bytes)
+/
string formatBytes(size_t n) => "4 KiB";
//     ^?
