/**
Scan seams of the native JSON reader — the free functions a SIMD
iteration replaces without touching the grammar loop (SPEC §11; the six
vectorizable seams are catalogued in the parsing research). Scalar-only
bodies here; signatures are the contract.
*/
module sparkles.wired.json.scan;

@safe pure nothrow @nogc package:

/// Advances `i` past insignificant whitespace (RFC 8259: space, tab,
/// LF, CR). The buffer's zero padding terminates every scan.
void skipWs(scope const(char)[] s, ref size_t i)
{
    while (i < s.length)
    {
        const c = s[i];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
            return;
        i++;
    }
}

/// Scans a string body from `i` (just after the opening quote) to the
/// first quote, backslash, or control byte (< 0x20), returning its
/// index. The pool's zero padding guarantees termination (NUL is a
/// control byte).
size_t scanStringBody(scope const(char)[] s, size_t i)
{
    while (i < s.length)
    {
        const c = s[i];
        if (c == '"' || c == '\\' || c < 0x20)
            break;
        i++;
    }
    return i;
}
