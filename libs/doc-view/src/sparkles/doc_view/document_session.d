/**
The seam a host's per-document session plugs into the viewer model through
(`UIA14`).

The model owns the document, so it is the one place that knows when the
document changes; a session that holds state derived from the old document
(hue's format preview, `FMV4`) must hear about it. The session itself is the
host's: the library names only this notification, so it carries no formatter,
no worker thread and no `dmd` frontend.
*/
module sparkles.doc_view.document_session;

/// A host session attached to a $(REF ViewerModel, sparkles,doc_view,viewer_model).
interface DocumentSession
{
    /// The viewed document was replaced: drop anything derived from the old one.
    void documentChanged() @safe pure nothrow @nogc;
}
