/**
Hue's layering vocabulary over `sparkles.wired.overlay` (`CFG2`, resolving open
question 3 by deriving): every configuration layer decodes into `Sparse!HueConfig`
— the schema with each leaf rewritten to `Nullable` — so $(I unset) differs from
$(I set to the default value), and the compiled defaults stay the schema's field
initialisers with no second declaration anywhere.

$(B The generator itself is not here.) `Mapped`, `Sparse`, `applyOverlay` and
`mergeSparse` moved to `sparkles.wired.overlay` once a second consumer appeared:
they are defined in terms of `@WireOptional`, `Nullable`, and wired's rule that a
missing key decodes to a field's initialiser, none of which is hue's to own. What
stays is the part that genuinely is hue's — what a $(I layer) means here.

Resolution is `applyOverlay` called once per layer in `CFG2` order onto
`HueConfig.init`; a field a layer leaves null inherits. `@Compose` list fields
(`CFG14`/`CFG20`) $(B prepend) instead of replace, so a higher layer's entries are
searched first. The environment's `SPARKLES_TS_GRAMMAR_PATH` is deliberately
$(B not) a layer for these fields: `CFG14` places configured paths ahead of the
environment's (the variable is packaging — the nix bundle's store path — while a
file entry is user intent), so that composition happens where the grammar registry
is built, not in the merge.

NOTE: no module-level `@safe:` — `Sparse!T` feeds straight into wired's
decode/encode, which infers `@system` for aggregates.
*/
module settings_overlay;

public import sparkles.wired.overlay : applyOverlay, mergeSparse, Sparse;

import sparkles.wired.overlay : WiredOrigins = Origins;

import settings : HueConfig;

// ─────────────────────────────────────────────────────────────────────────────
// What a layer is, here.
// ─────────────────────────────────────────────────────────────────────────────

/// Where each effective value came from (`CFG10`), lowest to highest.
enum OriginKind : ubyte
{
    /// The schema's field initialiser.
    default_,
    /// `$XDG_CONFIG_HOME/hue/config.json` (or `--config`'s path).
    userFile,
    /// The nearest `.hue.json` walking up from the target.
    projectFile,
    /// An environment variable.
    env,
    /// A command-line flag.
    cli,
}

/// One field's provenance: the layer kind plus the human detail
/// (`file:<path>`, `env:HUE_GUI_FONTSIZE`, `cli:--tree-width`).
struct Origin
{
    OriginKind kind;
    string detail;
}

/// The per-field provenance mirror of `T`, same shape as `Sparse!T`. Pins
/// wired's origin-type parameter to $(LREF Origin) once, so every call site in
/// hue keeps spelling it `Origins!HueConfig`.
alias Origins(T) = WiredOrigins!(T, Origin);

// ─────────────────────────────────────────────────────────────────────────────
// Tests. Serde-touching ones are `@system` (wired infers it for aggregates);
// the pure merge tests stay `@safe`.
// ─────────────────────────────────────────────────────────────────────────────

@("settings_overlay.Sparse.decodesSparsely")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    // `{}` is the empty layer: everything unset.
    auto empty = fromJSON!(Sparse!HueConfig)(`{}`);
    assert(!empty.hasError, empty.error.toString);
    assert(empty.value.appearance.theme.isNull);
    assert(empty.value.panes.viewer.tabWidth.isNull);

    // A partial file sets exactly what it names.
    auto part = fromJSON!(Sparse!HueConfig)(
        `{"appearance":{"theme":"builtin-dark","fonts":{"size":13}},` ~
        `"panes":{"viewer":{"lineNumbers":false}}}`);
    assert(!part.hasError, part.error.toString);
    assert(part.value.appearance.theme.get == "builtin-dark");
    assert(part.value.appearance.fonts.size.get == 13);
    assert(part.value.panes.viewer.lineNumbers.get == false);
    assert(part.value.panes.viewer.tabWidth.isNull);
    assert(part.value.diff.layout.isNull);

    // Encode is sparse too: unset fields are omitted, so a saved overlay
    // round-trips without inventing values (empty sections shrink to `{}`).
    auto text = toJSON(part.value);
    assert(!text.hasError);
    auto back = fromJSON!(Sparse!HueConfig)(text.value[]);
    assert(!back.hasError, back.error.toString);
    assert(back.value == part.value);
}

@("settings_overlay.applyOverlay.layering")
@safe unittest
{
    import settings : TableCopyMode;

    HueConfig resolved;
    Origins!HueConfig origins;

    // The CFG2 IMPORTANT case: the user file sets a bool to its default
    // (true), the project file turns it OFF — "set to the default" must be a
    // real setting, or the project file could never disable it.
    Sparse!HueConfig user;
    user.panes.viewer.lineNumbers = true;
    user.appearance.theme = "builtin-dark";
    user.behaviour.tableCopy = TableCopyMode.tsv;

    Sparse!HueConfig project;
    project.panes.viewer.lineNumbers = false;
    project.panes.viewer.tabWidth = 8;

    Sparse!HueConfig cli;
    cli.behaviour.tableCopy = TableCopyMode.markdown;

    applyOverlay(resolved, origins, user,
        Origin(OriginKind.userFile, "file:user.json"));
    applyOverlay(resolved, origins, project,
        Origin(OriginKind.projectFile, "file:.hue.json"));
    applyOverlay(resolved, origins, cli,
        Origin(OriginKind.cli, "cli:--table-copy"));

    assert(resolved.panes.viewer.lineNumbers == false);
    assert(resolved.panes.viewer.tabWidth == 8);
    assert(resolved.appearance.theme == "builtin-dark");
    assert(resolved.behaviour.tableCopy == TableCopyMode.markdown);

    // Untouched fields keep the schema defaults and a default_ origin.
    assert(resolved.appearance.fonts.size == HueConfig.init.appearance.fonts.size);
    assert(origins.appearance.fonts.size.kind == OriginKind.default_);

    // Origins land on the winning layer.
    assert(origins.panes.viewer.lineNumbers.kind == OriginKind.projectFile);
    assert(origins.appearance.theme.kind == OriginKind.userFile);
    assert(origins.behaviour.tableCopy.detail == "cli:--table-copy");
}

@("settings_overlay.applyOverlay.composePrepends")
@safe unittest
{
    HueConfig resolved;
    Origins!HueConfig origins;

    Sparse!HueConfig user;
    user.behaviour.grammarPaths = ["/home/u/grammars"];

    Sparse!HueConfig project;
    project.behaviour.grammarPaths = ["/repo/grammars"];

    applyOverlay(resolved, origins, user,
        Origin(OriginKind.userFile, "file:user.json"));
    applyOverlay(resolved, origins, project,
        Origin(OriginKind.projectFile, "file:.hue.json"));

    // CFG14: layers compose, higher layer searched first — the project's
    // grammar shadows the user's, and nothing is lost.
    assert(resolved.behaviour.grammarPaths ==
        ["/repo/grammars", "/home/u/grammars"]);
    assert(origins.behaviour.grammarPaths.kind == OriginKind.projectFile);
}
