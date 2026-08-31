/**
The runtime home of the configuration (`SET*` + `CFG11`): one heap value
both hosts share, holding the resolved config the frame loops read and the
settings pane mutates, the file-layer seed the pane's save draft starts
from, and the save/provenance adapters that bind the generic pane to the
config core.

NOTE: no module-level `@safe:` — the save path fronts wired's serde.
*/
module settings_store;

import std.algorithm.searching : canFind, startsWith;
import std.traits : FieldNameTuple, hasUDA;

import settings : ConfigSection, HueConfig;
import settings_io : saveUserConfig;
import settings_load : LoadedConfig;
import settings_overlay : applyOverlay, mergeSparse, Origin, OriginKind,
    Origins, Sparse;
import settings_pane : ApplyMask, ApplyRule, SettingsPaneT;

/// The concrete pane both hosts mount.
alias SettingsPane = SettingsPaneT!HueConfig;

/// The live-apply table (`settings_pane.ApplyRule`, longest prefix wins):
/// what a committed edit obliges the host to do right now. `none` is the
/// common case — hosts read `resolved` per frame already.
immutable ApplyRule[] hueApplyRules = [
    ApplyRule("appearance.theme", ApplyMask.theme),
    ApplyRule("appearance.background", ApplyMask.theme),
    ApplyRule("appearance.groupThemes", ApplyMask.theme),
    ApplyRule("appearance.fonts.", ApplyMask.font),
    ApplyRule("panes.", ApplyMask.layout),
];

/// ditto
struct ConfigStore
{
    /// The running value: hosts READ per frame, the pane MUTATES.
    HueConfig resolved;

    /// Defaults + the user file only — BELOW env and CLI. The pane's save
    /// draft seeds from this, which is what makes `CFG11` structural.
    HueConfig fileValue;

    /// The user file's own sparse content, kept beside the resolved value so
    /// a save rewrites the overlay, never the resolved state.
    Sparse!HueConfig userOverlay;

    /// The per-field provenance (`CFG10`), for the pane's shadow footer.
    Origins!HueConfig origins;

    string userFilePath; ///

    /// Bumped on every committed change, for consumers that cache.
    ulong generation;

    /// Builds the store from the resolved layers.
    static ConfigStore from(LoadedConfig lc)
    {
        ConfigStore s;
        s.resolved = lc.effective;
        s.userOverlay = lc.userOverlay;
        s.origins = lc.origins;
        s.userFilePath = lc.userFilePath;
        s.fileValue = HueConfig.init;
        Origins!HueConfig scratch;
        applyOverlay(s.fileValue, scratch, lc.userOverlay,
            Origin(OriginKind.userFile, "file"));
        return s;
    }

    /**
    The pane's save seam: serializes the draft's $(B touched) paths merged
    onto the existing user overlay (`settings_io.saveUserConfig` — sparse,
    atomic, refusing a human-owned file). Returns `null` on success, the
    rendered refusal otherwise.
    */
    string save(ref const HueConfig draft, const(string)[] touched)
    {
        // Un-const snapshot: HueConfig carries an AA (`keys`), which blocks
        // the implicit const copy; the pane's draft is a value snapshot
        // nothing else aliases mutably.
        auto snap = (() @trusted => cast(HueConfig) draft)();
        auto deltas = deltasFor(snap, touched);
        auto r = saveUserConfig(userFilePath, userOverlay, deltas);
        if (r.hasError)
            return r.error.message;
        userOverlay = mergeSparse!HueConfig(userOverlay, deltas);
        fileValue = snap;
        generation++;
        return null;
    }

    /// The pane's shadow footer: non-empty when `path`'s effective value
    /// came from a layer ABOVE the user file — the save would be masked at
    /// the next launch by that env var or flag.
    string shadowOrigin(string path) @safe
        => shadowOriginIn(origins, path);
}

/// The touched paths of `draft`, as a sparse overlay — the property tree's
/// dotted paths are exactly the schema's field paths, so a compile-time walk
/// pairs them without a second declaration.
Sparse!HueConfig deltasFor(HueConfig draft, const(string)[] touched) @safe
{
    Sparse!HueConfig o;
    fillDeltas(o, draft, touched, null);
    return o;
}

private void fillDeltas(S, T)(ref S o, T part, const(string)[] touched,
    string prefix) @safe
{
    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), ConfigSection))
            fillDeltas(o.tupleof[i], part.tupleof[i], touched,
                prefix ~ name ~ ".");
        else
        {
            if (touched.canFind(prefix ~ name))
                o.tupleof[i] = part.tupleof[i];
        }
    }
}

// By value: an `in` view would scope the details it returns.
private string shadowOriginIn(Origins!HueConfig origins, string path) @safe
{
    string found;
    findOriginImpl(origins, path, null, found);
    return found;
}

private void findOriginImpl(O)(O origins, string path, string prefix,
    ref string found) @safe
{
    static foreach (i, name; FieldNameTuple!O)
    {
        // `O.init.tupleof`: the declared field type, free of the `in`
        // view's const — a const(Origin) must still take the leaf branch.
        static if (is(typeof(O.init.tupleof[i]) == Origin))
        {
            if (prefix ~ name == path)
            {
                const o = origins.tupleof[i];
                if (o.kind == OriginKind.env || o.kind == OriginKind.cli)
                    found = o.detail.length ? o.detail : "a flag";
            }
        }
        else
        {
            if (path.startsWith(prefix ~ name ~ "."))
                findOriginImpl(origins.tupleof[i], path, prefix ~ name ~ ".",
                    found);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — including the first `PropertyTree!HueConfig` instantiation.
// ─────────────────────────────────────────────────────────────────────────────

@("settings_store.paneOverHueConfig")
@system unittest
{
    import sparkles.input.events : Key, KeyEvent;
    import settings : TableCopyMode;

    // The real thing: the pane over the whole HueConfig — the walk, the
    // rows, an edit, the draft mirror.
    auto store = new ConfigStore;
    store.resolved = HueConfig.init;
    store.fileValue = HueConfig.init;

    SettingsPane p;
    p.applyRules = hueApplyRules.dup;
    p.open(&store.resolved, store.fileValue);
    assert(p.tree.data.nodes.length > 10, "the schema materialised");

    // Sections are composite rows; `keys` is @hidden and absent.
    bool sawKeys;
    foreach (ref n; p.tree.data.nodes)
        if (n.value.path.startsWith("keys"))
            sawKeys = true;
    assert(!sawKeys, "the keys map stays out of the pane in v1");

    // Toggle a real leaf through the key path; the theme rule answers.
    foreach (i, ref const r; p.tv.rows)
        if (p.tree.data.nodes[r.node].value.path == "appearance")
        {
            p.tv.sel = cast(long) i;
            break;
        }
    cast(void) p.handleKey(KeyEvent(Key.right)); // expand appearance
    foreach (i, ref const r; p.tv.rows)
        if (p.tree.data.nodes[r.node].value.path == "appearance.groupThemes")
        {
            p.tv.sel = cast(long) i;
            p.tv.clamp();
            break;
        }
    const res = p.handleKey(KeyEvent(Key.char_, '+'));
    assert(store.resolved.appearance.groupThemes == false);
    assert(p.fileDraft.appearance.groupThemes == false);
    assert(res.apply == ApplyMask.theme);
}

@("settings_store.deltasAndShadow")
@system unittest
{
    // deltasFor picks exactly the touched paths from the draft.
    HueConfig draft;
    draft.appearance.theme = "builtin-dark";
    draft.panes.viewer.tabWidth = 8;
    draft.behaviour.liveTypes = false;
    auto d = deltasFor(draft,
        ["appearance.theme", "panes.viewer.tabWidth"]);
    assert(d.appearance.theme.get == "builtin-dark");
    assert(d.panes.viewer.tabWidth.get == 8);
    assert(d.behaviour.liveTypes.isNull, "untouched stays absent");

    // The shadow footer names env/CLI origins only.
    Origins!HueConfig origins;
    origins.appearance.fonts.size = Origin(OriginKind.env,
        "env:HUE_GUI_FONTSIZE");
    origins.appearance.theme = Origin(OriginKind.userFile, "file:x");
    ConfigStore s;
    s.origins = origins;
    assert(s.shadowOrigin("appearance.fonts.size") == "env:HUE_GUI_FONTSIZE");
    assert(s.shadowOrigin("appearance.theme").length == 0);
    assert(s.shadowOrigin("panes.viewer.tabWidth").length == 0);
}

@("settings_store.saveRoundTrip")
@system unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import settings_io : readJsoncFile;

    const dir = buildPath(tempDir, text("hue-store-save-", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    ConfigStore s;
    s.userFilePath = buildPath(dir, "config.json");
    s.resolved = HueConfig.init;
    s.fileValue = HueConfig.init;

    HueConfig draft;
    draft.appearance.theme = "builtin-dark";
    assert(s.save(draft, ["appearance.theme"]) is null);

    auto back = readJsoncFile!(Sparse!HueConfig)(s.userFilePath);
    assert(!back.hasError);
    assert(back.value.appearance.theme.get == "builtin-dark");
    assert(back.value.panes.viewer.tabWidth.isNull, "sparse: only touched");
    assert(s.userOverlay.appearance.theme.get == "builtin-dark");
    assert(s.fileValue.appearance.theme == "builtin-dark");
}
