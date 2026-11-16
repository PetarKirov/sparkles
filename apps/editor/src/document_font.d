/**
The document font (`EAP16`): discovery, the family list the picker offers,
and loading the chosen family's real members for a host that can draw them.
Interface typography is the host's own and never changes here; a terminal
has no font to set, so the setting is kept and reported as not applying.
Discovery and loading run on `FontLibrary`'s workers; `poll` only publishes.
*/
module document_font;

import sparkles.font.families : ControlState, DocumentFont, FontControl, FontControls;
import sparkles.ui_app.font_library : documentFontRequest, DocumentFontLoads, FontLibrary;
import sparkles.ui_app.specimen_font : SpecimenFontRequest;

/// One app's document-font state.
final class DocumentFontService
{
    private FontLibrary library;
    private bool started;
    private DocumentFont applied;
    private bool haveApplied, loading;
    private string loadingFamily;
    private DocumentFontLoads loads;
    /// What the chosen family supports, once its regular member is loaded.
    FontControls controls;
    /// A one-line state for the inspector and status bar.
    string state = "Default document font";

    /// Start discovery; the default font draws meanwhile.
    void start() @safe
    {
        if (started) return;
        started = true;
        library = new FontLibrary;
        (() @trusted => library.start([], null))(); // workers own discovery; no cache across runs
        state = "Listing fonts…";
    }

    /// Discovery or a load is outstanding: the host should wake again.
    bool busy() const @safe pure nothrow @nogc => started && (!library.ready || loading);

    /// The families the picker lists, monospace ones unless `all`; names index `names`.
    string[] familyNames(bool all) @safe
    {
        string[] names;
        if (!started || !library.ready) return names;
        foreach (i, family; library.families)
            if (all || family.monospace) names ~= library.familyNames[i];
        return names;
    }

    /**
    Publish finished work and, when `font` differs from what the host draws,
    advance its load. Returns true with `request` filled once the chosen
    family is ready to hand to the host's `specimenFont`.
    */
    bool poll(const DocumentFont font, ref SpecimenFontRequest request) @safe
    {
        if (!started) return false;
        (() @trusted => cast(void) library.poll())();
        if (!library.ready) return false;
        if (haveApplied && applied == font) return false;
        if (!font.family.length)
        {
            loading = false; // an earlier family's load is no longer wanted
            state = "Default document font";
            return false; // the host's own cell font is the default
        }
        const family = library.familyIndex(font.family);
        if (family == size_t.max)
        {
            loading = false;
            state = "Font not found: " ~ font.family;
            haveApplied = true;
            applied = font;
            return false;
        }
        if (!loading || loadingFamily != font.family)
        {
            loads = (() @trusted => library.requestDocumentFont(family))();
            loading = true;
            loadingFamily = font.family;
            state = "Loading " ~ font.family ~ "…";
        }
        controls = (() @trusted => library.controls(family, loads))();
        const fitted = font.fitTo(controls);
        if (!(() @trusted => documentFontRequest(library.families[family], loads, fitted, request))())
            return false;
        (() @trusted => library.retain(loads.regular, loads.styles))();
        loading = false;
        haveApplied = true;
        applied = font;
        state = font.family ~ unsupported(controls) ~ "; loaded, not yet drawn: the document uses the interface's cell font";
        return true;
    }

    /// Stop the workers; their storage outlives them until joined.
    void stop() @safe
    {
        if (started) (() @trusted => library.stop())();
        started = false;
    }
}

/// The controls a family lacks, as " (no italic, no weight axis)": visible, not hidden.
string unsupported(in FontControls controls) @safe pure
{
    string missing;
    void note(FontControl control, string label)
    {
        if (controls.state(control) == ControlState.available) return;
        missing ~= (missing.length ? ", " : "") ~ (controls.state(control) == ControlState.unknown
            ? label ~ " unknown" : "no " ~ label);
    }
    note(FontControl.bold, "bold");
    note(FontControl.italic, "italic");
    note(FontControl.ligatures, "ligatures");
    note(FontControl.weight, "weight axis");
    note(FontControl.opticalSize, "optical-size axis");
    return missing.length ? " (" ~ missing ~ ")" : "";
}

/// What a family lacks is named; what it has is not.
@("editor.documentFont.unsupported")
@safe pure unittest
{
    import sparkles.font.families : DeclaredAxis, LigatureSupport;
    FontControls controls;
    controls.styles = [true, true, false, false];
    controls.ligatures = LigatureSupport.none;
    const text = unsupported(controls);
    assert(text == " (no italic, no ligatures, no weight axis, no optical-size axis)", text);
    controls.styles = [true, true, true, true];
    controls.ligatures = LigatureSupport.declared;
    controls.weightAxis = DeclaredAxis(true, 100 << 16, 400 << 16, 900 << 16);
    controls.opticalSizeAxis = DeclaredAxis(true, 8 << 16, 14 << 16, 72 << 16);
    assert(unsupported(controls) == "");
}

/// Discovery lists monospace families by default and every family on request,
/// and a chosen family loads into a request for the host's cell font.
@("editor.documentFont.discoverAndLoad")
@safe unittest
{
    import core.time : MonoTime, seconds;
    import sparkles.test_runner.skip : skipTest;
    auto service = new DocumentFontService;
    scope (exit) service.stop();
    service.start();
    const deadline = MonoTime.currTime + 20.seconds;
    SpecimenFontRequest request;
    while (!service.familyNames(true).length && MonoTime.currTime < deadline)
        service.poll(DocumentFont.init, request);
    const all = service.familyNames(true), mono = service.familyNames(false);
    if (!mono.length) skipTest("no monospace font family is installed here");
    assert(mono.length <= all.length);
    DocumentFont font;
    font.family = mono[0];
    bool loaded;
    while (!loaded && MonoTime.currTime < deadline)
        loaded = service.poll(font, request);
    assert(loaded && request.path.length && request.bytes.length, service.state);
    assert(service.state[0 .. font.family.length] == font.family && service.state[$ - 9 .. $] == "cell font");
    assert(!service.poll(font, request), "an applied font is not requested again");
    font.family = "No Such Family 1234";
    assert(!service.poll(font, request) && service.state == "Font not found: No Such Family 1234");
}
