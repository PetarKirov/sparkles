module sample;
// ---cut---
/++
Parses a decimal byte count with an optional `KB`/`MB` suffix.

The input is trimmed first; a bare number means bytes.

Returns: The size in bytes.
Throws: `Exception` when text is not a number.
See_Also: $(LREF formatBytes)
Deprecated: Prefer `parseSize` — this spelling goes away in 2.0.
Authors: The sparkles authors
Version: 1.3.0
Complexity_Notes: Single pass, $(BIGOH n) in the length of text.
+/
size_t parseBytes(string text) => text.length;
//     ^?
