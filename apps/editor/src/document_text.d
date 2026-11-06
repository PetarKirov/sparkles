/** UTF-8 document bytes and convention-aware insertion policy. */
module document_text;

import sparkles.text_buffer.text : Text;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.utf8 : validateUtf8;

/// File envelope stays separate from editable text so a BOM cannot become an editable glyph.
struct DocumentBytes
{
    string content;
    bool bom;
    string predominant = "\n";
}

/// Validate with the shared SIMD-capable UTF-8 validator and retain exact source bytes.
Expected!DocumentBytes decodeDocument(string bytes) @safe pure nothrow @nogc
{
    if (validateUtf8(bytes).hasError) return err!DocumentBytes("The document is not valid UTF-8.");
    DocumentBytes result;
    result.bom = bytes.length >= 3 && bytes[0 .. 3] == "\xef\xbb\xbf";
    result.content = result.bom ? bytes[3 .. $] : bytes;
    size_t lf, crlf;
    foreach (i, char byte_; result.content)
        if (byte_ == '\n')
        {
            if (i && result.content[i - 1] == '\r') ++crlf;
            else ++lf;
        }
    result.predominant = crlf > lf ? "\r\n" : "\n";
    return ok(result);
}

/// Reattach only the envelope; authored line-ending bytes are never normalized.
string encodeDocument(DocumentBytes document) @safe pure nothrow
    => document.bom ? "\xef\xbb\xbf" ~ document.content : document.content;

/// Byte fixtures retain the BOM and mixed endings and reject invalid UTF-8.
@("editor.documentText.decodeExactBytes")
@safe pure nothrow unittest
{
    const decoded = decodeDocument("\xef\xbb\xbffirst\r\nsecond\nlast\r\n");
    assert(decoded.hasValue && decoded.value.bom);
    assert(decoded.value.content == "first\r\nsecond\nlast\r\n");
    assert(decoded.value.predominant == "\r\n");
    assert(encodeDocument(decoded.value) == "\xef\xbb\xbffirst\r\nsecond\nlast\r\n");
    assert(decodeDocument("bad\xff").hasError);
    assert(decodeDocument("").value.predominant == "\n");
}

/// Enter follows this line's LF/CRLF, then the document convention, then LF.
string enterEnding(in Text content, size_t position, string predominant)
    @safe pure nothrow @nogc
{
    const line = content.lineOf(position < content.length ? position : content.length);
    const end = content.lineEnd(line);
    if (end < content.length)
    {
        if (content.byteAt(end) == '\r' && end + 1 < content.length && content.byteAt(end + 1) == '\n')
            return "\r\n";
        if (content.byteAt(end) == '\n') return "\n";
    }
    return predominant == "\r\n" ? "\r\n" : "\n";
}

/// Current-line endings win over the predominant ending; supplied paste bytes stay exact.
@("editor.documentText.enterPreservesMixedEndings")
@safe pure nothrow @nogc unittest
{
    const content = Text("first\r\nsecond\nlast");
    assert(enterEnding(content, 3, "\n") == "\r\n");
    assert(enterEnding(content, 9, "\r\n") == "\n");
    assert(enterEnding(content, content.length, "\r\n") == "\r\n");
    assert(enterEnding(Text.init, 0, null) == "\n");
}
