/**
The derived sparse overlay (`CFG2`, resolving open question 3 by deriving):
every configuration layer decodes into `Sparse!HueConfig` — the schema with
each leaf rewritten to `Nullable` — so $(I unset) differs from $(I set to the
default value), and the compiled defaults stay the schema's field
initialisers with no second declaration anywhere.

`Mapped` is the one generator, instantiated twice: `Sparse!T` for the layers
and `Origins!T` for the per-field provenance mirror `hue config show`
renders (`CFG10`). Resolution is `applyOverlay` called once per layer in
`CFG2` order onto `HueConfig.init`; a field a layer leaves null inherits.

`@Compose` list fields (`CFG14`/`CFG20`) $(B prepend) instead of replace, so
a higher layer's entries are searched first. The environment's
`SPARKLES_TS_GRAMMAR_PATH` is deliberately $(B not) a layer for these
fields: `CFG14` places configured paths ahead of the environment's (the
variable is packaging — the nix bundle's store path — while a file entry is
user intent), so that composition happens where the grammar registry is
built, not in the merge.

Lives in hue, not a library: `DCK2` already rules that encoding is the
application's, and this generator has exactly one consumer.

NOTE: no module-level `@safe:` — `Sparse!T` feeds straight into wired's
decode/encode, which infers `@system` for aggregates.
*/
module settings_overlay;

import std.traits : FieldNameTuple, hasUDA;
import std.typecons : Nullable;

import sparkles.wired.policy : WireOptional;

import settings : Compose, ConfigSection, HueConfig;

// ─────────────────────────────────────────────────────────────────────────────
// The generator.
// ─────────────────────────────────────────────────────────────────────────────

/**
`T` with every leaf field's type rewritten to `Map!(...)`; `@ConfigSection`
struct fields recurse. Field names are preserved, so the wire spelling is the
schema's; every derived field carries `@WireOptional()`, so a missing key
decodes to "unset" and an unset field is omitted on encode — which is what
makes a saved user file a sparse overlay rather than a full snapshot.
*/
struct Mapped(T, alias Map)
if (is(T == struct))
{
    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), ConfigSection))
            mixin("@(WireOptional()) Mapped!(typeof(T.tupleof[", i, "]), Map) ",
                name, ";");
        else
            mixin("@(WireOptional()) Map!(typeof(T.tupleof[", i, "])) ",
                name, ";");
    }
}

/// The sparse layer form: unset = inherit from the layer below.
alias Sparse(T) = Mapped!(T, Nullable);

/// A `Map` that ignores the field type — every leaf becomes `Leaf`.
private template Just(Leaf)
{
    alias Just(F) = Leaf;
}

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

/// The per-field provenance mirror of `T`, same shape as `Sparse!T`.
alias Origins(T) = Mapped!(T, Just!Origin);

// ─────────────────────────────────────────────────────────────────────────────
// The merge.
// ─────────────────────────────────────────────────────────────────────────────

/**
Applies one layer onto the resolved value, recording `origin` for every field
the layer sets. `@Compose` fields prepend (higher layer searched first) and
record the last contributing layer; everything else replaces.

`overlay` is taken by value on purpose: a `const`/`in` view would make
`Nullable.get`'s payload `const` and unassignable into the resolved value —
and a layer struct is all `Nullable`s, cheap to copy once per startup.
*/
void applyOverlay(T, O, S)(ref T resolved, ref O origins,
    S overlay, Origin origin) @safe
if (is(O == Mapped!(T, Just!Origin)) && is(S == Mapped!(T, Nullable)))
{
    static foreach (i, _; T.init.tupleof)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), ConfigSection))
        {
            applyOverlay(resolved.tupleof[i], origins.tupleof[i],
                overlay.tupleof[i], origin);
        }
        else static if (hasUDA!(T.tupleof[i], Compose))
        {
            if (!overlay.tupleof[i].isNull)
            {
                resolved.tupleof[i] = overlay.tupleof[i].get ~ resolved.tupleof[i];
                origins.tupleof[i] = origin;
            }
        }
        else
        {
            if (!overlay.tupleof[i].isNull)
            {
                resolved.tupleof[i] = overlay.tupleof[i].get;
                origins.tupleof[i] = origin;
            }
        }
    }
}

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
