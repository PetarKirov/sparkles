/**
Layered configuration over a wire schema: the sparse form of a type, and the
merge that resolves a stack of them.

The problem this solves is one sentence long, and the sentence is why it cannot
be done with the schema type alone. A configuration read from a file must
distinguish $(I unset) from $(I set to the default value) — otherwise a lower
layer can never turn off something whose default is on, because "false" and
"didn't say" look identical. Decoding straight into `T` collapses that
distinction on the first field that happens to hold its own default.

$(LREF Sparse) is `T` with every leaf rewritten to `Nullable` and every field
marked `@WireOptional`, so a decoded layer says exactly what its document said
and nothing more. $(LREF applyOverlay) folds a stack of those onto a starting
value — which is `T.init`, so the compiled defaults stay the schema's field
initialisers with no second declaration anywhere.

$(B One generator, several instantiations.) $(LREF Mapped) rewrites a schema's
leaves through any type function: `Nullable` for a layer, a constant for the
per-field provenance mirror ($(LREF Origins)) an application renders when asked
where a value came from. Field names are preserved, so the wire spelling of a
sparse document is the schema's.

$(B It lives here, and not in an application.) The transform is defined in terms
of `@WireOptional`, `Nullable`, and this package's decode semantics: a missing
key decodes to the field's declared initialiser, and an unset field is omitted
on encode. Those are wired's rules, not a caller's, and every consumer of this
module already depends on wired to decode a layer at all.

$(B What this module does not decide.) It has no opinion on where layers come
from, what order they stack in, or whether a malformed one is fatal. Those are
policy, they differ per application — a settings file that warns and continues,
a test fixture that must abort — and they belong at the call site that knows.
*/
module sparkles.wired.overlay;

import std.traits : FieldNameTuple, hasUDA;
import std.typecons : Nullable;

import sparkles.wired.policy : WireOptional;

// ─────────────────────────────────────────────────────────────────────────────
// Marker UDAs.
// ─────────────────────────────────────────────────────────────────────────────

/**
Marks a struct-typed field as a nested section: $(LREF Mapped) recurses into it
rather than treating it as one leaf.

Without it a `struct`-valued field would become a single `Nullable!Section`, and
a layer could only replace the whole section — the very collapse this module
exists to avoid, one level up.
*/
enum WireSection;

/**
Marks a list-valued field whose layers $(B compose) instead of override: a
higher layer's entries are $(B prepended), so they are searched first, and the
lower layers' are still there behind them.

The documented exception to higher-layer-wins. It is what lets a user shadow a
bundled entry with their own build of it without having to restate the bundle.
*/
enum WireCompose;

// ─────────────────────────────────────────────────────────────────────────────
// The generator.
// ─────────────────────────────────────────────────────────────────────────────

/**
`T` with every leaf field's type rewritten to `Map!(...)`; $(LREF WireSection)
struct fields recurse.

Every derived field carries `@WireOptional()`, which is what makes the result a
$(I sparse) document in both directions: a missing key decodes to the mapped
type's own empty value, and a field still at that value is omitted on encode. A
layer therefore round-trips without inventing the fields it did not mention.
*/
struct Mapped(T, alias Map)
if (is(T == struct))
{
    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), WireSection))
            mixin("@(WireOptional()) Mapped!(typeof(T.tupleof[", i, "]), Map) ",
                name, ";");
        else
            mixin("@(WireOptional()) Map!(typeof(T.tupleof[", i, "])) ",
                name, ";");
    }
}

/// The sparse layer form: unset = inherit from the layer below.
alias Sparse(T) = Mapped!(T, Nullable);

/// A `Map` that ignores the field type — every leaf becomes `Leaf`. Private:
/// it exists to spell $(LREF Origins), and $(LREF applyOverlay)'s constraint
/// resolves it in this module's scope rather than the caller's.
private template Just(Leaf)
{
    alias Just(F) = Leaf;
}

/**
The per-field provenance mirror of `T`: the same shape as `Sparse!T`, but every
leaf is an `Origin` — whatever the application uses to describe a layer.

Generic over that type on purpose. What counts as a provenance differs by
application (a file path, a command-line flag, a fixture name) and this module
has no way to enumerate them; an application typically pins it once:

---
alias Origins(T) = sparkles.wired.overlay.Origins!(T, MyOrigin);
---
*/
alias Origins(T, Origin) = Mapped!(T, Just!Origin);

// ─────────────────────────────────────────────────────────────────────────────
// The merge.
// ─────────────────────────────────────────────────────────────────────────────

/**
Applies one layer onto the resolved value, recording `origin` for every field
the layer sets.

Call it once per layer, lowest first, onto a `T` that starts at `T.init`. A
field a layer leaves null inherits whatever the layers below it resolved to —
including the schema's own initialiser, when no layer spoke at all.

$(LREF WireCompose) fields prepend and record the last contributing layer;
everything else replaces.

`overlay` is taken by value on purpose: a `const`/`in` view would make
`Nullable.get`'s payload `const` and so unassignable into the resolved value —
and a layer struct is all `Nullable`s, cheap to copy once per load.
*/
void applyOverlay(T, O, S, Origin)(ref T resolved, ref O origins,
    S overlay, Origin origin) @safe
if (is(O == Mapped!(T, Just!Origin)) && is(S == Mapped!(T, Nullable)))
{
    static foreach (i, _; T.init.tupleof)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), WireSection))
        {
            applyOverlay(resolved.tupleof[i], origins.tupleof[i],
                overlay.tupleof[i], origin);
        }
        else static if (hasUDA!(T.tupleof[i], WireCompose))
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

/**
Field-wise union of two sparse overlays: where `deltas` speaks it wins,
everywhere else `base` stands.

The shape of "this session's changes applied to what the file already said" —
and the reason it is not $(LREF applyOverlay) is that the result is still
$(I sparse). Merging a layer into a resolved value loses which fields were
actually set; this keeps that, so what gets written back stays the union of
what was deliberately said, not a full snapshot of everything.

Unlike `applyOverlay`, $(LREF WireCompose) fields replace here rather than
prepending: two overlays of the same list are alternative statements of one
layer's intent, not two layers to be searched in turn.
*/
Sparse!T mergeSparse(T)(Sparse!T base, Sparse!T deltas) @safe
{
    Sparse!T merged = base;
    static foreach (i, _; base.tupleof)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), WireSection))
            merged.tupleof[i] = mergeSparse!(typeof(T.tupleof[i]))(
                base.tupleof[i], deltas.tupleof[i]);
        else
        {
            if (!deltas.tupleof[i].isNull)
                merged.tupleof[i] = deltas.tupleof[i];
        }
    }
    return merged;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests. The serde-touching ones are `@system` — wired infers that for
// aggregates; the pure merge tests stay `@safe`.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private enum Mode : ubyte { off, on, auto_ }

    @WireSection
    private struct Pane
    {
        bool lineNumbers = true;
        int tabWidth = 4;
    }

    private struct Cfg
    {
        string theme = "default";
        Mode mode = Mode.auto_;
        Pane pane;
        @(WireCompose) string[] searchPaths;
    }

    private enum Layer : ubyte { none, user, project, cli }
}

///
@("wired.overlay.Sparse.decodesSparsely")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    // `{}` is the empty layer: everything unset.
    auto empty = fromJSON!(Sparse!Cfg)(`{}`);
    assert(!empty.hasError, empty.error.toString);
    assert(empty.value.theme.isNull);
    assert(empty.value.pane.tabWidth.isNull);

    // A partial document sets exactly what it names.
    auto part = fromJSON!(Sparse!Cfg)(`{"theme":"dark","pane":{"tabWidth":8}}`);
    assert(!part.hasError, part.error.toString);
    assert(part.value.theme.get == "dark");
    assert(part.value.pane.tabWidth.get == 8);
    assert(part.value.pane.lineNumbers.isNull);
    assert(part.value.mode.isNull);

    // Encode is sparse too, so a saved overlay round-trips without inventing
    // values — an untouched section shrinks back to `{}`.
    auto text = toJSON(part.value);
    assert(!text.hasError);
    auto back = fromJSON!(Sparse!Cfg)(text.value[]);
    assert(!back.hasError, back.error.toString);
    assert(back.value == part.value);
}

///
@("wired.overlay.applyOverlay.layering")
@safe unittest
{
    Cfg resolved;
    Origins!(Cfg, Layer) origins;

    // The case the whole module exists for: the user layer sets a bool to its
    // own default (true), and the project layer turns it OFF. "Set to the
    // default" has to be a real setting, or the project layer could never
    // disable it.
    Sparse!Cfg user;
    user.pane.lineNumbers = true;
    user.theme = "dark";
    user.mode = Mode.on;

    Sparse!Cfg project;
    project.pane.lineNumbers = false;
    project.pane.tabWidth = 8;

    Sparse!Cfg cli;
    cli.mode = Mode.off;

    applyOverlay(resolved, origins, user, Layer.user);
    applyOverlay(resolved, origins, project, Layer.project);
    applyOverlay(resolved, origins, cli, Layer.cli);

    assert(resolved.pane.lineNumbers == false);
    assert(resolved.pane.tabWidth == 8);
    assert(resolved.theme == "dark");
    assert(resolved.mode == Mode.off);

    // A field no layer mentioned keeps the schema's initialiser, and says so.
    assert(origins.theme == Layer.user);
    assert(origins.pane.lineNumbers == Layer.project);
    assert(origins.mode == Layer.cli);
}

@("wired.overlay.applyOverlay.unsetFieldsKeepTheSchemaDefault")
@safe unittest
{
    Cfg resolved;
    Origins!(Cfg, Layer) origins;

    applyOverlay(resolved, origins, Sparse!Cfg.init, Layer.user);

    // An empty layer changes nothing and claims nothing — the starting value is
    // `T.init`, so the defaults are the schema's own field initialisers and are
    // written down exactly once, in the schema.
    assert(resolved == Cfg.init);
    assert(origins.theme == Layer.none);
    assert(origins.pane.tabWidth == Layer.none);
}

///
@("wired.overlay.applyOverlay.composePrepends")
@safe unittest
{
    Cfg resolved;
    Origins!(Cfg, Layer) origins;

    Sparse!Cfg user;
    user.searchPaths = ["/home/u/grammars"];

    Sparse!Cfg project;
    project.searchPaths = ["/repo/grammars"];

    applyOverlay(resolved, origins, user, Layer.user);
    applyOverlay(resolved, origins, project, Layer.project);

    // The higher layer is searched first and the lower one is still there —
    // so a user can shadow a bundled entry without restating the bundle.
    assert(resolved.searchPaths == ["/repo/grammars", "/home/u/grammars"]);
    assert(origins.searchPaths == Layer.project);
}

///
@("wired.overlay.mergeSparse.deltasWinAndTheResultStaysSparse")
@safe unittest
{
    Sparse!Cfg base;
    base.theme = "dark";
    base.pane.tabWidth = 8;

    Sparse!Cfg deltas;
    deltas.pane.tabWidth = 2;

    const merged = mergeSparse!Cfg(base, deltas);

    assert(merged.theme.get == "dark");        // base stands where deltas is silent
    assert(merged.pane.tabWidth.get == 2);     // deltas wins where it speaks
    assert(merged.mode.isNull);                // and neither invented a value
    assert(merged.pane.lineNumbers.isNull);
}

@("wired.overlay.Mapped.preservesFieldNamesAndNesting")
@safe unittest
{
    import std.traits : FieldNameTuple;

    // The wire spelling of a layer is the schema's: same names, same order, so
    // a sparse document and a full one read the same to a human.
    static assert([FieldNameTuple!(Sparse!Cfg)] == [FieldNameTuple!Cfg]);
    static assert([FieldNameTuple!(Sparse!Pane)] == [FieldNameTuple!Pane]);

    // A `@WireSection` field recurses; a leaf does not.
    static assert(is(typeof(Sparse!Cfg.pane) == Sparse!Pane));
    static assert(is(typeof(Sparse!Cfg.theme) == Nullable!string));

    // And the same generator produces the provenance mirror.
    static assert(is(typeof(Origins!(Cfg, Layer).pane) == Origins!(Pane, Layer)));
    static assert(is(typeof(Origins!(Cfg, Layer).theme) == Layer));
}
