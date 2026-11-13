/** Editor document state, independent of its application and rendering host. */
module editor_document;

import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.field : EditorFieldOf;
import sparkles.ui.editor.layout : LayoutContext;
import document_text : DocumentBytes, encodeDocument;

/// A tab owns its reference-counted field; arrays contain tab references, never Text values.
class Document
{
    ulong id;
    string name;
    /// Wrapped, bidi-aware rows: motion, drawing and hits share one layout (`EAP17`).
    EditorFieldOf!LayoutContext field;
    Text saved;
    size_t firstLine;
    /// The first shown visual row of `firstLine`.
    size_t firstRow;
    bool followCaret = true;
    string language = "text";
    bool bom;
    string predominant = "\n";
    string path, savedBytes;
    bool saving;
    string durabilityWarning;

    this(ulong id, string name, string content = "") @safe pure nothrow
    {
        this.id = id;
        this.name = name;
        field = typeof(field).make(content);
        saved = field.state.text;
    }

    bool dirty() const @safe pure nothrow @nogc => field.state.text != saved;

    /// Exact file bytes; the envelope is separate from the editable text.
    string encodedBytes() const @safe pure nothrow
        => encodeDocument(DocumentBytes(field.text, bom, predominant));
}
