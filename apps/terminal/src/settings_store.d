/**
The settings page's model over `TerminalConfig` (`TSP1`–`TSP4`): the shared
settings pane (`sparkles.ui.components.settings_pane`, the component hue
mounts) bound to the terminal's layers.

$(UL
    $(LI $(B The subject) is the resolved configuration — every layer, the
    command line included — which the page edits live (`TSP2`).)
    $(LI $(B The file seed) is layers 1–3 (defaults, the Termux files,
    `config.json`) without the command line, so a flag's value is never
    baked into the file (`TSP3`).)
    $(LI $(B Each autosave) writes `config.json` as it was when the page opened
    plus the paths the user changed (`TSP3`).)
    $(LI $(B Each leaf's origin) is the layer `config show` names; a leaf the
    Termux files supplied, once edited, says which file it now overrides
    (`TSP4`).)
)

The page's layout is M8's; this is the part that is not visual.

NOTE: no module-level `@safe:` — the save path fronts wired's serde.
*/
module settings_store;

import sparkles.ui.components.settings_pane : ApplyRule, LayerPlacement,
    LeafOrigin, SettingsGeometry, SettingsPane;
import sparkles.wired.overlay : mergeSparse, originAt, sparseAt, Sparse;

import keymap : KeysConfig;
import settings : TerminalConfig;
import settings_io : saveConfig;
import settings_load : LoadedConfig, Origin, OriginKind, Origins;

/// The page over the terminal's configuration, with the toolkit's default
/// keys (the terminal's own binding table takes them over with the page, M8).
alias TerminalSettingsPane = SettingsPane!TerminalConfig;

/// What a committed edit obliges the running app to do (`TCF8`): the bits of
/// `SettingsResult.apply`.
enum TerminalApply : uint
{
    none = 0,
    colors = 1,    /// recolour every pane and the chrome
    font = 2,      /// reload the font (at the next start for now, `TCF8`)
    extraKeys = 4, /// rebuild the extra-keys row
    lantern = 8,   /// re-read the guide's settings
    keys = 16,     /// rebuild the binding table (`TKM8`)
    chrome = 32,   /// the button labels, overlay style, pane chrome and opener
    behaviour = 64, /// the exit policy and the scrollback
    policy = 128,  /// the paste, clipboard, notification and link policy
}

/// The live-apply table, longest prefix wins.
immutable ApplyRule[] terminalApplyRules = [
    ApplyRule("appearance.colors.", TerminalApply.colors),
    ApplyRule("appearance.followSystem", TerminalApply.colors),
    ApplyRule("appearance.chromeTheme", TerminalApply.colors),
    ApplyRule("appearance.font.", TerminalApply.font),
    ApplyRule("extraKeys.", TerminalApply.extraKeys),
    ApplyRule("lantern.", TerminalApply.lantern | TerminalApply.keys),
    ApplyRule("keys", TerminalApply.keys),
    ApplyRule("ui.", TerminalApply.chrome),
    ApplyRule("behaviour.", TerminalApply.behaviour),
    ApplyRule("paste.", TerminalApply.policy),
    ApplyRule("clipboard.", TerminalApply.policy),
    ApplyRule("notifications.", TerminalApply.policy),
    ApplyRule("links.", TerminalApply.policy),
    ApplyRule("open.", TerminalApply.policy),
];

/// The configuration the page edits, and where it came from.
struct TerminalSettingsStore
{
    /// The running value: the app reads it, the page mutates it.
    TerminalConfig resolved;
    /// Layers 1–3 — the file seed.
    TerminalConfig fileValue;
    /// `config.json`'s own sparse content, as last written.
    Sparse!TerminalConfig fileOverlay;
    /// The file as it was when the page opened: every autosave rewrites
    /// this plus the session's changed paths.
    Sparse!TerminalConfig sessionOverlay;
    /// Where each loaded value came from (`TCF5`).
    Origins!TerminalConfig origins;
    /// `config.json`'s path.
    string filePath;
    /// Bumped on every write, for consumers that cache.
    ulong generation;

    /// The store over a resolved load (the command line already applied).
    static TerminalSettingsStore from(LoadedConfig lc)
    {
        TerminalSettingsStore s;
        s.resolved = lc.effective;
        s.fileValue = lc.fileValue;
        s.fileOverlay = lc.fileOverlay;
        s.origins = lc.origins;
        s.filePath = lc.filePath;
        return s;
    }

    /// Opens `pane` over this store: the apply table, the autosave seam,
    /// the origin lookup, the session's base.
    void mount(ref TerminalSettingsPane pane,
        SettingsGeometry g = SettingsGeometry())
    {
        auto self = &this;
        sessionOverlay = fileOverlay;
        pane.applyRules = terminalApplyRules.dup;
        keysEdited = false;
        // The binding overlay is no leaf the property tree edits: once the
        // capture editor wrote it, every save carries it (`TSP8`).
        pane.doSave = (ref const TerminalConfig d, const(string)[] changed)
            => self.save(d, self.keysEdited ? changed ~ "keys" : changed);
        pane.originOf = (string path) @safe => self.originOf(path);
        pane.fileLayer = "file:" ~ filePath;
        pane.open(&resolved, fileValue, g);
    }

    /**
    The autosave seam: the session's base with `changed` taken from the
    draft, written strictly (a hand-commented file is refused with the
    snippet to paste). Returns `null` on success, the refusal otherwise.
    */
    string save(ref const TerminalConfig draft, const(string)[] changed)
    {
        // Un-const snapshot: `keys` is an associative array, which blocks the
        // implicit const copy; the draft is a value nothing else aliases.
        auto snap = (() @trusted => cast(TerminalConfig) draft)();
        auto deltas = sparseAt(snap, changed);
        auto r = saveConfig(filePath, sessionOverlay, deltas);
        if (r.hasError)
            return r.error.message;
        fileOverlay = mergeSparse!TerminalConfig(sessionOverlay, deltas);
        fileValue = snap;
        generation++;
        return null;
    }

    /// The capture editor wrote the `keys` overlay this session.
    bool keysEdited;

    /**
    The capture editor's write (`TSP8`): `keys` becomes the binding overlay —
    live in the running value and in the pane's file draft — and is saved at
    once with the session's other changes. Returns `null` on success, the
    refusal otherwise (the binding stays live).
    */
    string bindKeys(ref TerminalSettingsPane pane, KeysConfig keys)
    {
        resolved.keys = keys;
        pane.fileDraft.keys = keys;
        keysEdited = true;
        return save(pane.fileDraft, pane.changedPaths ~ "keys");
    }

    /// The layer that supplied `path`'s loaded value, placed against the
    /// file the page writes (`TSP4`).
    LeafOrigin originOf(string path) @safe
    {
        Origin o;
        if (!originAt(origins, path, o))
            return LeafOrigin.init;
        final switch (o.kind)
        {
            case OriginKind.default_:
                return LeafOrigin("default", LayerPlacement.belowFile);
            case OriginKind.termux:
                // `termux:colors.properties` → what an edit overrides.
                enum tag = "termux:";
                const file = o.detail.length > tag.length
                    ? o.detail[tag.length .. $] : o.detail;
                return LeafOrigin(o.detail, LayerPlacement.belowFile, file);
            case OriginKind.file:
                return LeafOrigin(o.detail, LayerPlacement.file);
            case OriginKind.cli:
                return LeafOrigin(o.detail, LayerPlacement.aboveFile);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: hand-written layer fixtures, the real schema, the default keys.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.path : buildPath;

    import sparkles.input.events : Key, KeyEvent;
    import sparkles.test_utils.tmpfs : TmpFS;

    import settings_load : loadTerminalConfig;

    /// Puts the cursor on `path`, opening its ancestors first.
    private void selectPath(ref TerminalSettingsPane p, string path)
    {
        p.tv.open = typeof(p.tv.open).allOpen;
        p.refresh();
        foreach (i, ref const r; p.tv.rows)
            if (p.tree.data.nodes[r.node].value.path == path)
            {
                p.tv.sel = cast(long) i;
                p.tv.clamp();
                return;
            }
        assert(false, "no visible row for " ~ path);
    }

    private Sparse!TerminalConfig readBack(string file)
    {
        import sparkles.wired.json.jsonc : readJsoncFile;

        auto r = readJsoncFile!(Sparse!TerminalConfig)(file);
        assert(!r.hasError, r.error.toString);
        return r.value;
    }
}

@("settings_store.TerminalSettingsPane.materialisesTheWholeSchema")
@system unittest
{
    // The real thing: every section of `TerminalConfig` is a row, in the
    // struct's declaration order.
    auto store = new TerminalSettingsStore;
    TerminalSettingsPane p;
    store.mount(p);
    string[] top;
    foreach (ref const r; p.tv.rows)
        top ~= p.tree.data.nodes[r.node].value.path;
    assert(top[0 .. 4] == ["appearance", "extraKeys", "behaviour", "links"], top[0]);
}

@("settings_store.autosave.aTermuxValueEditedOverridesItsFile")
@system unittest
{
    import std.algorithm.searching : canFind;

    import sparkles.ui.components.settings_pane : SettingsResult, SettingsToast;

    auto fixture = TmpFS.create();
    fixture.writeFileAt(".termux/colors.properties", "foreground=#ffffff\n");
    const file = buildPath(fixture.dir, "config.json");
    auto lc = loadTerminalConfig(file, buildPath(fixture.dir, ".termux"));
    auto store = new TerminalSettingsStore;
    *store = TerminalSettingsStore.from(lc);

    TerminalSettingsPane p;
    store.mount(p);

    // Before the edit the leaf says where its value is from.
    const before = p.provenance("appearance.followSystem");
    assert(before.layer == "termux:colors.properties", before.layer);
    assert(before.note.length == 0, "nothing is overridden yet");

    // colors.properties pinned followSystem off; the user turns it back on.
    selectPath(p, "appearance.followSystem");
    const r = p.handleKey(KeyEvent(Key.char_, '+'));
    assert(r.kind == SettingsResult.Kind.saved);
    assert(r.apply == TerminalApply.colors);
    assert(store.resolved.appearance.followSystem, "applied live");
    assert(p.toast.kind == SettingsToast.Kind.saved && p.toast.offersUndo);

    // The file holds exactly the edit — the Termux colours stay the Termux
    // layer's, never baked in.
    auto written = readBack(file);
    assert(written.appearance.followSystem.get == true);
    assert(written.appearance.colors.dark.foreground.isNull);

    // …and the leaf says what the edit did to the Termux file.
    const after = p.provenance("appearance.followSystem");
    assert(after.layer == "file:" ~ file, after.layer);
    assert(after.note == "overrides colors.properties", after.note);
    assert(!after.shadowed);

    // A leaf the user did not touch still names its own layer.
    assert(p.provenance("appearance.colors.dark.foreground").layer
        == "termux:colors.properties");

    // Undo — the toast's — writes the file back to what it said (nothing).
    cast(void) p.undoLast();
    assert(!store.resolved.appearance.followSystem);
    assert(readBack(file) == Sparse!TerminalConfig.init);
    assert(!p.provenance("appearance.followSystem").note.canFind("overrides"));
}

@("settings_store.autosave.aFlagIsNeverBakedInAndShadowsItsLeaf")
@system unittest
{
    auto fixture = TmpFS.create();
    const file = fixture.writeFileAt("config.json", `{"paste":{"confirm":"never"}}`);
    auto lc = loadTerminalConfig(file, null);
    Sparse!TerminalConfig cli;
    cli.appearance.font.size = 9;
    lc.applyCli(cli, "--font-size");

    auto store = new TerminalSettingsStore;
    *store = TerminalSettingsStore.from(lc);
    TerminalSettingsPane p;
    store.mount(p);
    assert(store.resolved.appearance.font.size == 9);

    // An edit elsewhere writes only itself, beside what the file said.
    selectPath(p, "lantern.delayMs");
    cast(void) p.handleKey(KeyEvent(Key.char_, '+'));
    auto written = readBack(file);
    assert(written.lantern.delayMs.get == 450);
    assert(written.paste.confirm.get == lc.fileOverlay.paste.confirm.get,
        "the file's own value stays");
    assert(written.appearance.font.size.isNull, "the flag's 9 is not baked in");

    // The flag's leaf says that a flag wins over anything the page writes.
    const shadow = p.provenance("appearance.font.size");
    assert(shadow.shadowed && shadow.layer == "cli:--font-size");
    assert(shadow.note == "cli:--font-size overrides this at next launch",
        shadow.note);
}

@("settings_store.autosave.aRangeRefusalWritesNothing")
@system unittest
{
    import sparkles.ui.property_tree : RefusalKind;

    auto fixture = TmpFS.create();
    const file = buildPath(fixture.dir, "config.json");
    auto store = new TerminalSettingsStore;
    *store = TerminalSettingsStore.from(loadTerminalConfig(file, null));
    store.resolved.lantern.delayMs = 5000; // the declared maximum
    TerminalSettingsPane p;
    store.mount(p);

    selectPath(p, "lantern.delayMs");
    cast(void) p.handleKey(KeyEvent(Key.char_, '+'));
    assert(store.resolved.lantern.delayMs == 5000, "range-checked (TSP2)");
    assert(p.edits.refusalFor("lantern.delayMs").kind == RefusalKind.outOfRange);

    import std.file : exists;

    assert(!file.exists, "a refused edit is not a commit: nothing written");
}
